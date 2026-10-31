# report.R ------------------------------------------------------------------
#
# The status object a reader sees first. It joins the schema-recovery result
# with the two-level canary check and tells the user, in one line and then in a
# table, what was recovered, what changed, and which variables were damaged and
# how. The package never silently repairs; it makes damage visible and nameable.

.cs_make_report <- function(rec, source, canary_raw, canary_typed,
                            rows_read = NA_integer_, file_hash_ok = NA,
                            schema = NULL) {
  canary <- canary_raw
  if (nrow(canary)) {
    reader_damage <- rep(FALSE, nrow(canary))
    if (!is.null(canary_typed) && nrow(canary_typed)) {
      for (i in seq_len(nrow(canary))) {
        v <- canary$variable[i]
        tv <- canary_typed[canary_typed$variable == v, , drop = FALSE]
        if (nrow(tv) == 1L && canary$verdict[i] != "corrupted" &&
            tv$verdict == "corrupted") {
          reader_damage[i] <- TRUE
        }
      }
    }
    canary$reader_damage <- reader_damage
  }
  structure(
    list(
      status = rec$status,
      source = source,
      recovery = rec,
      rows_written = rec$header$rows %||% NA_integer_,
      rows_read = rows_read,
      canary = canary,
      file_hash_ok = file_hash_ok,
      schema = schema
    ),
    class = "cs_report"
  )
}

.cs_report_oneline <- function(x) {
  schema_part <- sprintf("schema %s (%s)", x$status, x$source)
  canary_part <- ""
  if (!is.null(x$canary) && nrow(x$canary)) {
    n <- nrow(x$canary)
    intact <- sum(x$canary$verdict == "intact")
    corrupted <- sum(x$canary$verdict == "corrupted")
    if (corrupted > 0L) {
      dmg <- paste(unique(x$canary$damage[x$canary$verdict == "corrupted"]),
                   collapse = "; ")
      canary_part <- sprintf("; %d/%d variables corrupted (%s)",
                             corrupted, n, dmg)
    } else {
      canary_part <- sprintf("; %d/%d variables intact", intact, n)
    }
  }
  paste0("csvschema: ", schema_part, canary_part)
}

#' Extract the csvschema report
#'
#' @param x A data frame returned by [cs_read_csv()] (carrying a `cs_report`
#'   attribute) or a `cs_report` itself.
#' @return The `cs_report` object.
#' @export
cs_report <- function(x) {
  if (inherits(x, "cs_report")) return(x)
  r <- attr(x, "cs_report")
  if (is.null(r)) stop("no csvschema report attached to `x`.", call. = FALSE)
  r
}

#' @export
print.cs_report <- function(x, ...) {
  cat(.cs_report_oneline(x), "\n")
  if (!is.na(x$rows_written) && !is.na(x$rows_read)) {
    cat(sprintf("  rows: %s written, %s read\n",
                x$rows_written, x$rows_read))
  }
  if (!is.na(x$file_hash_ok)) {
    cat("  file-byte hash:", if (x$file_hash_ok) "matches" else "differs", "\n")
  }
  if (length(x$recovery$missing)) {
    cat("  missing packet indices:",
        paste(x$recovery$missing, collapse = ", "), "\n")
  }
  if (x$recovery$dropped_crc > 0L) {
    cat("  packets dropped (CRC fail):", x$recovery$dropped_crc, "\n")
  }
  if (!is.null(x$canary) && nrow(x$canary)) {
    cat("  canary:\n")
    cn <- x$canary
    for (i in seq_len(nrow(cn))) {
      line <- sprintf("    %-20s %s", cn$variable[i], cn$verdict[i])
      if (nzchar(cn$damage[i])) line <- paste0(line, " [", cn$damage[i], "]")
      if (isTRUE(cn$reader_damage[i])) line <- paste0(line, " (reader-induced)")
      cat(line, "\n")
    }
  }
  invisible(x)
}

#' Full csvschema report table
#'
#' @param x A data frame from [cs_read_csv()] or a `cs_report`.
#' @return The per-variable canary data frame, invisibly, after printing the
#'   report.
#' @export
cs_report_table <- function(x) {
  r <- cs_report(x)
  print(r)
  invisible(r$canary)
}
