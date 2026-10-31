# canary.R ------------------------------------------------------------------
#
# A recovered schema is worthless if the data it describes was altered in
# transit. The `_canary` column stores, per variable, a purposeful sample of
# the values most likely to be damaged plus a fingerprint of the whole column.
# On read the sampled values are checked against the raw column text; absent
# values are mapped back to the detector that would have selected them, so the
# report names the kind of damage.

# Detectors: predicates on a character vector, in the order they are tried.
# Each catches a specific corruption vector; the name is the damage label.
.CS_DETECTORS <- list(
  leading_zero = function(v) grepl("^0[0-9]+$", v),
  long_digits  = function(v) grepl("^[0-9]{16,}$", v),
  date_like    = function(v) {
    grepl("^(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|SEPT|OCT|NOV|DEC)[0-9]+$",
          v, ignore.case = TRUE) |
      grepl("^[0-9]{1,2}[-/][0-9]{1,2}([-/][0-9]{2,4})?$", v) |
      grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", v)
  },
  time_like    = function(v) grepl("^[0-9]{1,2}:[0-9]{1,2}(:[0-9]{1,2})?$", v),
  scientific   = function(v) grepl("^[-+]?[0-9]*\\.?[0-9]+[eE][-+]?[0-9]+$", v),
  decimal_edge = function(v) grepl("^-?\\.[0-9]+$", v),
  formula      = function(v) grepl("^[=+@-]", v),
  non_ascii    = function(v) grepl("[^\u0001-\u007F]", v, perl = TRUE),
  whitespace   = function(v) grepl("^\\s|\\s$", v),
  boolean_like = function(v) {
    grepl("^(TRUE|FALSE|T|F|YES|NO|Y|N)$", v, ignore.case = TRUE)
  }
)

# Classify a value by the first detector (in order) that matches it; returns
# the detector name, or "other".
.cs_classify_value <- function(v, sentinels = character(0)) {
  for (nm in names(.CS_DETECTORS)) {
    if (isTRUE(.CS_DETECTORS[[nm]](v))) return(nm)
  }
  if (length(sentinels) && v %in% sentinels) return("sentinel")
  "other"
}

#' Purposeful canary sample for one variable
#'
#' Selects up to `k` values from a character column by trying each corruption
#' detector in order and taking the first match not already chosen, then adds
#' the longest and shortest strings and the numeric min and max, and finally
#' fills any remainder deterministically from the remaining distinct values.
#'
#' @param x A character vector (the on-disk strings of one column).
#' @param k Number of samples to aim for.
#' @param field Optional `cs_schema` field, used for its missing-value
#'   sentinels.
#' @return A character vector of up to `k` sampled values.
#' @examples
#' cs_canary_sample(c("00123", "1", "SEPT1", "x", "999999999999999999"))
#' @export
cs_canary_sample <- function(x, k = CS_DEFAULT_CANARY_K, field = NULL) {
  xx <- x[!is.na(x) & nzchar(x)]
  if (!length(xx)) return(character(0))
  chosen <- character(0)
  take <- function(cands) {
    cands <- cands[!cands %in% chosen]
    if (length(cands) && length(chosen) < k) {
      chosen[[length(chosen) + 1L]] <<- cands[1]
    }
  }
  for (nm in names(.CS_DETECTORS)) {
    if (length(chosen) >= k) break
    take(xx[.CS_DETECTORS[[nm]](xx)])
  }
  sentinels <- setdiff(unlist(field$missingValues), "")
  if (length(sentinels)) take(xx[xx %in% sentinels])
  take(xx[which.max(nchar(xx))])
  take(xx[which.min(nchar(xx))])
  nums <- suppressWarnings(as.numeric(xx))
  if (any(is.finite(nums))) {
    take(xx[which.min(nums)])
    take(xx[which.max(nums)])
  }
  if (length(chosen) < k) {
    remaining <- setdiff(unique(xx), chosen)
    if (length(remaining)) {
      need <- k - length(chosen)
      chosen <- c(chosen, utils::head(sort(remaining), need))
    }
  }
  chosen
}

# Fingerprint: first 8 hex of SHA-1 over the sorted distinct raw strings. NA is
# normalized to "" so the write-time and read-time fingerprints agree (a written
# NA is an empty cell, which reads back as "").
.cs_fingerprint <- function(x) {
  x <- ifelse(is.na(x), "", x)
  d <- sort(unique(x))
  .cs_sha1(paste(d, collapse = "\n"), CS_FINGERPRINT_LEN)
}

# Canary payload for one variable.
.cs_canary_payload <- function(name, x, k, field = NULL) {
  n <- length(x)
  na <- sum(is.na(x) | !nzchar(x))
  nd <- length(unique(x[!is.na(x)]))
  fp <- .cs_fingerprint(x)
  samples <- cs_canary_sample(x, k, field)
  v <- paste(vapply(samples, cs_encode_token, character(1)),
             collapse = CS_ITEM_SEP)
  paste0(cs_encode_token(name), CS_ATTR_SEP,
         "n", CS_KV_SEP, n, CS_ATTR_SEP,
         "na", CS_KV_SEP, na, CS_ATTR_SEP,
         "nd", CS_KV_SEP, nd, CS_ATTR_SEP,
         "fp", CS_KV_SEP, fp, CS_ATTR_SEP,
         "v", CS_KV_SEP, v)
}

#' Build canary packets for every variable
#'
#' @param df A character data frame (the exact on-disk strings).
#' @param s An `cs_schema`, used for per-field sentinels.
#' @param k Canary samples per variable.
#' @param mtu Maximum packet length.
#' @return A character vector of canary packets (class `cs_packets`, type `C`).
#' @export
cs_canary <- function(df, s = NULL, k = CS_DEFAULT_CANARY_K, mtu = CS_DEFAULT_MTU) {
  fbn <- if (!is.null(s)) {
    stats::setNames(s$fields, vapply(s$fields, function(f) f$name, character(1)))
  } else {
    list()
  }
  header <- paste0("cs", CS_KV_SEP, CS_WIRE_VERSION, CS_ATTR_SEP,
                   "vars", CS_KV_SEP, ncol(df), CS_ATTR_SEP,
                   "recipe", CS_KV_SEP, "1")
  var_payloads <- lapply(names(df), function(nm) {
    .cs_canary_payload(nm, df[[nm]], k, fbn[[nm]])
  })
  index_payloads <- c(list(header), var_payloads)
  mand_fun <- function(idx) if (idx >= 1L) 1L else 0L
  .cs_pack(index_payloads, CS_TYPE_CANARY, mtu, mand_fun, splittable = c("v"))
}

# Parse recovered canary packets into a per-variable list.
cs_parse_canaries <- function(x) {
  .cs_canaries_from_parsed(cs_parse_packets(x))
}

.cs_canaries_from_parsed <- function(parsed) {
  rec <- cs_recover(parsed, type = CS_TYPE_CANARY)
  if (is.null(rec$P) || is.na(rec$P)) return(list())
  # Reassemble each index payload the same way cs_recover does, then parse.
  good <- parsed[!is.na(parsed$type) & parsed$type == tolower(CS_TYPE_CANARY) &
                   parsed$crc_ok, , drop = FALSE]
  if (nrow(good) == 0L) return(list())
  P <- rec$P
  out <- list()
  for (idx in seq_len(P) - 1L) {
    if (idx == 0L) next # header
    rows <- good[good$index == idx, , drop = FALSE]
    if (nrow(rows) == 0L) next
    if (all(is.na(rows$frag))) {
      payload <- unique(rows$payload)[1]
    } else {
      J <- max(rows$nfrag, na.rm = TRUE)
      parts <- character(J)
      ok <- TRUE
      for (j in seq_len(J)) {
        fr <- rows[!is.na(rows$frag) & rows$frag == j, , drop = FALSE]
        if (nrow(fr) == 0L) { ok <- FALSE; break }
        parts[j] <- unique(fr$payload)[1]
      }
      if (!ok) next
      payload <- paste(parts, collapse = CS_ATTR_SEP)
    }
    out[[length(out) + 1L]] <- .cs_payload_to_canary(payload)
  }
  out
}

.cs_payload_to_canary <- function(payload) {
  attrs <- .cs_split_items(payload, CS_ATTR_SEP)
  canary <- list(name = cs_decode_token(attrs[1]), values = character(0))
  for (a in attrs[-1]) {
    if (!grepl(CS_KV_SEP, a, fixed = TRUE)) next
    key <- sub(paste0(CS_KV_SEP, ".*$"), "", a)
    val <- sub(paste0("^[^", CS_KV_SEP, "]*", CS_KV_SEP), "", a)
    if (key == "v") {
      items <- .cs_split_items(val, CS_ITEM_SEP)
      canary$values <- c(canary$values, vapply(items, cs_decode_token,
                                               character(1), USE.NAMES = FALSE))
    } else if (key %in% c("n", "na", "nd")) {
      canary[[key]] <- suppressWarnings(as.integer(val))
    } else {
      canary[[key]] <- val
    }
  }
  canary
}

#' Verify data columns against their canaries
#'
#' For each variable, recomputes the column fingerprint and checks whether every
#' sampled value is still present verbatim. Returns a per-variable verdict:
#' `intact`, `rows changed, values intact`, `corrupted`, or `unverifiable`. For
#' corrupted variables, absent values are classified by detector so the damage
#' is named.
#'
#' @param raw_df A character data frame (every column read as text).
#' @param canaries A list of parsed canaries from `cs_parse_canaries()`.
#' @param typed Logical; `TRUE` when checking re-serialized typed values (used
#'   by the two-level check to attribute damage to the reader).
#' @return A data frame, one row per canaried variable.
#' @export
cs_canary_check <- function(raw_df, canaries, typed = FALSE) {
  rows <- lapply(canaries, function(cn) {
    name <- cn$name
    present_col <- name %in% names(raw_df)
    if (!present_col) {
      return(data.frame(variable = name, verdict = "unverifiable",
                        n_written = cn$n %||% NA_integer_, n_now = NA_integer_,
                        canaries = length(cn$values), lost = NA_integer_,
                        damage = "", stringsAsFactors = FALSE))
    }
    col <- as.character(raw_df[[name]])
    col[is.na(col)] <- ""
    fp_now <- .cs_fingerprint(col)
    n_now <- length(col)
    vals <- cn$values
    absent <- vals[!vals %in% col]
    if (length(cn$fp) && identical(fp_now, cn$fp)) {
      verdict <- "intact"
      damage <- ""
    } else if (length(absent) == 0L) {
      # fingerprint differs but all samples present: rows changed, not values
      verdict <- "rows changed, values intact"
      damage <- ""
    } else {
      verdict <- "corrupted"
      cats <- vapply(absent, .cs_classify_value, character(1))
      tab <- table(cats)
      damage <- paste(sprintf("%s (%d)", names(tab), as.integer(tab)),
                      collapse = "; ")
    }
    data.frame(variable = name, verdict = verdict,
               n_written = cn$n %||% NA_integer_, n_now = n_now,
               canaries = length(vals), lost = length(absent),
               damage = damage, stringsAsFactors = FALSE)
  })
  if (!length(rows)) {
    return(data.frame(variable = character(0), verdict = character(0),
                      n_written = integer(0), n_now = integer(0),
                      canaries = integer(0), lost = integer(0),
                      damage = character(0), stringsAsFactors = FALSE))
  }
  do.call(rbind, rows)
}
