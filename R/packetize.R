# packetize.R ---------------------------------------------------------------
#
# Turn a schema into complete, fragmented packets. One copy of each packet is
# produced here; replication and striping across rows happen in the layout
# layer. Fragmentation is deterministic first-fit so the same schema at the
# same MTU always yields byte-identical packets (stable hashes and tests).

# Assemble `{{id~payload~crc}}` with the CRC over `id~payload`.
.cs_make_packet <- function(id, payload) {
  crc <- cs_crc32(paste0(id, CS_PART_SEP, payload))
  paste0(CS_WRAP_OPEN, id, CS_PART_SEP, payload, CS_PART_SEP, crc, CS_WRAP_CLOSE)
}

# Fixed per-packet cost that is not the id or the payload:
# `{{` + `}}` + two `~` + 8 hex CRC.
.CS_STRUCT_OVERHEAD <- 2L + 2L + 2L + 8L

# Header (packet 0) payload.
.cs_header_payload <- function(s, mtu, hash, side = NULL, sidehash = NULL) {
  parts <- c(
    paste0("cs", CS_KV_SEP, CS_WIRE_VERSION),
    paste0("enc", CS_KV_SEP, cs_encode_token(s$meta$enc %||% "utf-8")),
    paste0("dialect", CS_KV_SEP, cs_encode_token(s$meta$dialect %||% "rfc4180")),
    paste0("fields", CS_KV_SEP, length(s$fields)),
    paste0("rows", CS_KV_SEP, s$meta$rows %||% 0L),
    paste0("mtu", CS_KV_SEP, mtu),
    paste0("hash", CS_KV_SEP, hash)
  )
  if (!is.null(side)) {
    parts <- c(parts, paste0("side", CS_KV_SEP, cs_encode_token(side)))
  }
  if (!is.null(sidehash)) {
    parts <- c(parts, paste0("sidehash", CS_KV_SEP, sidehash))
  }
  paste(parts, collapse = CS_ATTR_SEP)
}

#' Fragment a payload's attributes into packet-sized pieces
#'
#' Deterministic first-fit splitter. Scalar attributes are kept whole; the
#' list-valued attributes named in `splittable` may be broken at item
#' boundaries, never inside a token or percent-escape. The first
#' `mandatory_first` attributes (a field's `name` and `type`) are forced into
#' fragment 1 so a partially recovered field is still identifiable.
#'
#' @param attrs Character vector of serialized attribute strings.
#' @param mtu Maximum packet length including braces.
#' @param overhead Fixed per-packet cost (braces, the longest id, separators,
#'   CRC) reserved from the MTU.
#' @param splittable Attribute keys whose value lists may be split.
#' @param mandatory_first Number of leading attributes pinned to fragment 1.
#' @return A list of fragment payload strings, in order.
#' @export
cs_fragment <- function(attrs, mtu, overhead,
                        splittable = c("lev", "na", "nalab", "pk", "fk"),
                        mandatory_first = 0L) {
  budget <- mtu - overhead
  if (budget < 1L) stop("MTU is too small for the packet overhead.", call. = FALSE)

  frags <- list()
  cur <- character(0)
  cur_len <- 0L

  flush <- function() {
    if (length(cur)) {
      frags[[length(frags) + 1L]] <<- paste(cur, collapse = CS_ATTR_SEP)
      cur <<- character(0)
      cur_len <<- 0L
    }
  }
  push <- function(a) {
    sep <- if (length(cur)) 1L else 0L
    cur <<- c(cur, a)
    cur_len <<- cur_len + sep + nchar(a)
  }
  fits <- function(a) (cur_len + (if (length(cur)) 1L else 0L) + nchar(a)) <= budget

  attr_key <- function(a) if (grepl(CS_KV_SEP, a, fixed = TRUE)) {
    sub(paste0(CS_KV_SEP, ".*$"), "", a)
  } else {
    a
  }

  if (mandatory_first > 0L) {
    lead <- attrs[seq_len(mandatory_first)]
    for (a in lead) push(a)
    if (cur_len > budget) {
      stop("field 'name' and 'type' exceed the MTU; raise mtu.", call. = FALSE)
    }
    attrs <- attrs[-seq_len(mandatory_first)]
  }

  for (a in attrs) {
    if (fits(a)) {
      push(a)
      next
    }
    key <- attr_key(a)
    if (key %in% splittable && grepl(CS_KV_SEP, a, fixed = TRUE)) {
      prefix <- paste0(key, CS_KV_SEP)
      val <- sub(paste0("^[^", CS_KV_SEP, "]*", CS_KV_SEP), "", a)
      items <- .cs_split_items(val, CS_ITEM_SEP)
      if (any(nchar(prefix) + nchar(items) > budget)) {
        stop(sprintf("a single item of '%s' exceeds the MTU; move it to the sidecar.",
                     key), call. = FALSE)
      }
      i <- 1L
      n <- length(items)
      while (i <= n) {
        sep <- if (length(cur)) 1L else 0L
        avail <- budget - cur_len - sep
        if (nchar(prefix) + nchar(items[i]) > avail) {
          flush()
          next
        }
        chunk <- character(0)
        piece_len <- nchar(prefix)
        while (i <= n) {
          extra <- (if (length(chunk)) 1L else 0L) + nchar(items[i])
          if (piece_len + extra <= avail) {
            chunk <- c(chunk, items[i])
            piece_len <- piece_len + extra
            i <- i + 1L
          } else {
            break
          }
        }
        push(paste0(prefix, paste(chunk, collapse = CS_ITEM_SEP)))
      }
    } else {
      flush()
      if (nchar(a) > budget) {
        hint <- if (identical(key, "desc")) {
          " Move 'desc' to the sidecar."
        } else {
          ""
        }
        stop(sprintf("attribute '%s' alone exceeds the MTU.%s", key, hint),
             call. = FALSE)
      }
      push(a)
    }
  }
  flush()
  frags
}

# Assemble packets from ordered per-index payloads, fragmenting any that would
# exceed the MTU. `mand_fun(idx)` gives the number of leading attributes pinned
# to fragment 1 for that index; `splittable` names the list-valued attributes
# that may be split across fragments. Shared by the schema and canary
# packetizers so the two stay byte-for-byte consistent.
.cs_pack <- function(index_payloads, type, mtu, mand_fun, splittable) {
  P_idx <- length(index_payloads)
  idx_digits <- nchar(as.character(P_idx - 1L))
  total_digits <- nchar(as.character(P_idx))
  id_nofrag <- 1L + idx_digits + 1L + total_digits
  lmax <- max(nchar(unlist(index_payloads)))
  budget_nofrag <- mtu - .CS_STRUCT_OVERHEAD - id_nofrag
  max_j <- if (budget_nofrag > 0L) {
    as.integer(ceiling(lmax / budget_nofrag)) + 1L
  } else {
    lmax
  }
  frag_digits <- nchar(as.character(max(max_j, 1L)))
  id_frag <- 1L + idx_digits + 1L + frag_digits + 2L + frag_digits + 1L +
    total_digits
  overhead_frag <- .CS_STRUCT_OVERHEAD + id_frag

  packets <- character(0)
  for (idx in seq_len(P_idx) - 1L) {
    payload <- index_payloads[[idx + 1L]]
    single_id <- paste0(type, idx, CS_TOTAL_SEP, P_idx)
    if (.CS_STRUCT_OVERHEAD + nchar(single_id) + nchar(payload) <= mtu) {
      packets <- c(packets, .cs_make_packet(single_id, payload))
    } else {
      attrs <- .cs_split_items(payload, CS_ATTR_SEP)
      frags <- cs_fragment(attrs, mtu, overhead_frag, splittable = splittable,
                           mandatory_first = mand_fun(idx))
      J <- length(frags)
      for (j in seq_len(J)) {
        id <- paste0(type, idx, CS_FRAG_SEP, j, CS_FRAG_OF, J, CS_TOTAL_SEP,
                     P_idx)
        packets <- c(packets, .cs_make_packet(id, frags[[j]]))
      }
    }
  }
  structure(packets, class = "cs_packets", P = P_idx, mtu = mtu, type = type)
}

#' Packetize a schema
#'
#' Produces one complete copy of every schema packet: the header (packet 0),
#' one packet per field, and the table-level packet last, fragmenting any
#' payload that would exceed the MTU. The whole-schema hash is carried in the
#' header. Replication and striping are applied later by the layout layer.
#'
#' @param s An `cs_schema`.
#' @param mtu Maximum packet length in characters, including braces.
#' @param side,sidehash Optional sidecar filename/URL and its hash for the
#'   header.
#' @return A character vector of packets with class `cs_packets` and attributes
#'   `P` (number of indices, including the header), `mtu`, and `type`.
#' @examples
#' cs_packetize(cs_schema(data.frame(id = 1:3, g = factor(c("a", "b", "a")))))
#' @export
cs_packetize <- function(s, mtu = CS_DEFAULT_MTU, side = NULL, sidehash = NULL) {
  field_table_payloads <- .cs_schema_payloads(s) # indices 1..P-1
  hash <- .cs_schema_hash(s)
  header <- .cs_header_payload(s, mtu, hash, side, sidehash)

  # index 0 = header, 1..nf = fields, nf+1 = table packet
  index_payloads <- c(list(header), as.list(field_table_payloads))
  nf <- length(s$fields)
  mand_fun <- function(idx) if (idx >= 1L && idx <= nf) 2L else 0L
  .cs_pack(index_payloads, CS_TYPE_SCHEMA, mtu, mand_fun,
           splittable = c("lev", "na", "nalab", "pk", "fk"))
}

#' @export
print.cs_packets <- function(x, ...) {
  cat("<cs_packets>", length(x), "packets, P =", attr(x, "P"),
      "indices, type", attr(x, "type"), ", mtu", attr(x, "mtu"), "\n")
  for (p in x) cat("  ", p, "\n", sep = "")
  invisible(x)
}
