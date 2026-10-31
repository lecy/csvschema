# parse.R -------------------------------------------------------------------
#
# Read packets back out of cells and rebuild the schema. The cell is first
# reduced to printable ASCII, which strips BOMs, zero-width and invisible
# characters, padding, and any whitespace a tool may have inserted. Packets are
# then located by brace pair, CRC-checked, deduplicated, reassembled, and the
# whole-schema hash is recomputed.

# Reduce a cell to printable ASCII (0x21-0x7E): removes BOM, non-ASCII bytes,
# control characters, and all whitespace. Valid packets use only these bytes.
.cs_clean_cell <- function(x) {
  gsub("[^\\x21-\\x7E]", "", x, perl = TRUE)
}

.cs_empty_parsed <- function() {
  data.frame(
    type = character(0), index = integer(0), frag = integer(0),
    nfrag = integer(0), total = integer(0), payload = character(0),
    crc_ok = logical(0), stringsAsFactors = FALSE
  )
}

#' Parse packets out of character cells
#'
#' Extracts every well-formed packet from a character vector of cells
#' (a `_schema` or `_canary` column, or several), verifies each CRC, and parses
#' the id. Cells are cleaned to printable ASCII first, so BOMs, invisible
#' characters, and whitespace do not defeat the match.
#'
#' @param x A character vector of cell contents.
#' @return A data frame with one row per packet found: `type` (lowercased),
#'   `index`, `frag`, `nfrag`, `total`, `payload`, and `crc_ok`.
#' @export
cs_parse_packets <- function(x) {
  x <- x[!is.na(x)]
  if (!length(x)) return(.cs_empty_parsed())
  cleaned <- .cs_clean_cell(x)
  tokens <- unlist(regmatches(cleaned, gregexpr(CS_PACKET_RE, cleaned)))
  if (!length(tokens)) return(.cs_empty_parsed())

  m <- regmatches(tokens, regexec(CS_PACKET_RE, tokens))
  ids <- vapply(m, function(z) z[2], character(1))
  payloads <- vapply(m, function(z) z[3], character(1))
  crcs <- vapply(m, function(z) z[4], character(1))

  crc_ok <- tolower(cs_crc32(paste0(ids, CS_PART_SEP, payloads))) == tolower(crcs)

  idlow <- tolower(ids)
  idm <- regmatches(idlow, regexec(CS_ID_RE, idlow))
  field <- function(i) vapply(idm, function(z) {
    if (length(z) >= i && nzchar(z[i])) z[i] else NA_character_
  }, character(1))
  type <- field(2L)
  index <- suppressWarnings(as.integer(field(3L)))
  frag <- suppressWarnings(as.integer(field(4L)))
  nfrag <- suppressWarnings(as.integer(field(5L)))
  total <- suppressWarnings(as.integer(field(6L)))

  out <- data.frame(
    type = type, index = index, frag = frag, nfrag = nfrag, total = total,
    payload = payloads, crc_ok = crc_ok, stringsAsFactors = FALSE
  )
  # Drop tokens whose id did not parse (malformed, unusable).
  out[!is.na(out$type) & !is.na(out$index) & !is.na(out$total), , drop = FALSE]
}

# Parse the header (packet 0) payload into a named list.
.cs_payload_to_header <- function(payload) {
  h <- list()
  if (length(payload) == 0L || is.na(payload) || !nzchar(payload)) return(h)
  for (a in .cs_split_items(payload, CS_ATTR_SEP)) {
    if (!grepl(CS_KV_SEP, a, fixed = TRUE)) next
    key <- sub(paste0(CS_KV_SEP, ".*$"), "", a)
    val <- sub(paste0("^[^", CS_KV_SEP, "]*", CS_KV_SEP), "", a)
    if (key %in% c("enc", "dialect", "side")) {
      h[[key]] <- cs_decode_token(val)
    } else if (key %in% c("fields", "rows", "mtu")) {
      h[[key]] <- suppressWarnings(as.integer(val))
    } else {
      h[[key]] <- val
    }
  }
  h
}

.cs_new_recovery <- function(status, schema = NULL, header = NULL,
                             missing = integer(0), conflicts = list(),
                             dropped_crc = 0L, P = NA_integer_,
                             source = "inband", hash_ok = NA) {
  structure(
    list(status = status, schema = schema, header = header,
         missing = missing, conflicts = conflicts, dropped_crc = dropped_crc,
         P = P, source = source, hash_ok = hash_ok),
    class = "cs_recovery"
  )
}

# Build an cs_schema (possibly partial) from the reassembled per-index payloads.
.cs_schema_from_reassembled <- function(reassembled, P, header) {
  table_payload <- reassembled[P]                 # index P-1
  field_payloads <- if (P > 2L) reassembled[2:(P - 1L)] else character(0)
  field_payloads <- field_payloads[nzchar(field_payloads)]
  fields <- lapply(field_payloads, .cs_payload_to_field)
  table <- .cs_payload_to_table(table_payload)
  meta <- list(
    enc = header$enc, dialect = header$dialect, rows = header$rows,
    mtu = header$mtu, wire_version = header$cs, hash = header$hash,
    side = header$side, sidehash = header$sidehash
  )
  structure(list(fields = fields, table = table, meta = meta),
            class = "cs_schema")
}

#' Recover a schema from parsed packets
#'
#' Deduplicates replicas, detects conflicts between differing copies of the
#' same packet, checks completeness across all indices and fragments,
#' reassembles each index, rebuilds the schema, and recomputes the whole-schema
#' hash to detect version mixing.
#'
#' @param parsed A data frame from [cs_parse_packets()].
#' @param type Packet type to recover (`"s"` for schema).
#' @return An object of class `cs_recovery` with `status` (one of `verified`,
#'   `conflict`, `incomplete`, `absent`), the recovered `schema` (possibly
#'   partial), the `header`, `missing` indices, `conflicts`, the count of
#'   CRC-dropped packets, and `source`.
#' @export
cs_recover <- function(parsed, type = CS_TYPE_SCHEMA) {
  type <- tolower(type)
  of_type <- parsed[!is.na(parsed$type) & parsed$type == type, , drop = FALSE]
  dropped_crc <- sum(!of_type$crc_ok)
  good <- of_type[of_type$crc_ok, , drop = FALSE]

  if (nrow(good) == 0L) {
    return(.cs_new_recovery("absent", dropped_crc = dropped_crc))
  }

  # Most common declared total is the design P.
  tt <- sort(table(good$total), decreasing = TRUE)
  P <- as.integer(names(tt)[1])

  reassembled <- rep("", P)
  missing <- integer(0)
  conflicts <- list()

  for (idx in seq_len(P) - 1L) {
    rows <- good[good$index == idx, , drop = FALSE]
    if (nrow(rows) == 0L) {
      missing <- c(missing, idx)
      next
    }
    if (all(is.na(rows$frag))) {
      u <- unique(rows$payload)
      if (length(u) > 1L) {
        conflicts[[length(conflicts) + 1L]] <- list(index = idx, payloads = u)
        next
      }
      reassembled[idx + 1L] <- u[1]
    } else {
      J <- max(rows$nfrag, na.rm = TRUE)
      parts <- rep(NA_character_, J)
      ok <- TRUE
      for (j in seq_len(J)) {
        fr <- rows[!is.na(rows$frag) & rows$frag == j, , drop = FALSE]
        if (nrow(fr) == 0L) {
          missing <- c(missing, idx)
          ok <- FALSE
          break
        }
        uj <- unique(fr$payload)
        if (length(uj) > 1L) {
          conflicts[[length(conflicts) + 1L]] <-
            list(index = idx, frag = j, payloads = uj)
          ok <- FALSE
          break
        }
        parts[j] <- uj[1]
      }
      if (ok) reassembled[idx + 1L] <- paste(parts, collapse = CS_ATTR_SEP)
    }
  }
  missing <- sort(unique(missing))

  # Schema reconstruction and hash verification apply only to the schema type;
  # other types (canary) are recovered for completeness/conflict only.
  is_schema <- identical(type, tolower(CS_TYPE_SCHEMA))
  header <- if (is_schema) .cs_payload_to_header(reassembled[1]) else list()
  schema <- if (is_schema) {
    .cs_schema_from_reassembled(reassembled, P, header)
  } else {
    NULL
  }

  if (length(conflicts) > 0L) {
    return(.cs_new_recovery("conflict", schema = schema, header = header,
                            missing = missing, conflicts = conflicts,
                            dropped_crc = dropped_crc, P = P))
  }
  if (length(missing) > 0L) {
    return(.cs_new_recovery("incomplete", schema = schema, header = header,
                            missing = missing, dropped_crc = dropped_crc, P = P))
  }
  if (!is_schema) {
    return(.cs_new_recovery("verified", schema = schema, header = header,
                            dropped_crc = dropped_crc, P = P, hash_ok = NA))
  }

  # Complete schema: verify the whole-schema hash against the header.
  recomputed <- .cs_schema_hash(schema)
  hash_ok <- !is.null(header$hash) && identical(recomputed, header$hash)
  if (hash_ok) {
    .cs_new_recovery("verified", schema = schema, header = header,
                     dropped_crc = dropped_crc, P = P, hash_ok = TRUE)
  } else {
    .cs_new_recovery("conflict", schema = schema, header = header,
                     dropped_crc = dropped_crc, P = P, hash_ok = FALSE)
  }
}

#' @export
print.cs_recovery <- function(x, ...) {
  cat("<cs_recovery>", x$status, "\n")
  if (!is.na(x$P)) cat("  packets (indices):", x$P, "\n")
  if (length(x$missing)) {
    cat("  missing indices:", paste(x$missing, collapse = ", "), "\n")
  }
  if (length(x$conflicts)) {
    cat("  conflicts at indices:",
        paste(vapply(x$conflicts, function(c) c$index, integer(1)),
              collapse = ", "), "\n")
  }
  if (isFALSE(x$hash_ok)) cat("  whole-schema hash mismatch (version mixing)\n")
  cat("  dropped (CRC fail):", x$dropped_crc, "\n")
  if (!is.null(x$schema)) {
    cat("  recovered", length(x$schema$fields), "fields\n")
  }
  invisible(x)
}
