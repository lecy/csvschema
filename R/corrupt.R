# corrupt.R -----------------------------------------------------------------
#
# Corruption simulators, one per threat-model vector. Each applies a named
# corruption to a CSV, as a data frame or as raw text, and records what it did
# in a "cs_corruption" attribute, so round-trips through them can be shown and
# tested. These are exported because users want to probe their own pipelines.

.cs_tag <- function(x, tag) {
  attr(x, "cs_corruption") <- c(attr(x, "cs_corruption"), tag)
  x
}

#' Drop, reorder, or duplicate rows
#'
#' @param x A data frame.
#' @param keep Fraction of rows to keep (for `random`, `head`, `tail`,
#'   `block`), or the extra fraction to duplicate (for `duplicate`).
#' @param mode One of `random`, `head`, `tail`, `block`, `stride`, `shuffle`,
#'   `duplicate`.
#' @param k Stride for `mode = "stride"`; defaults to `round(1/keep)`.
#' @param seed Optional RNG seed for reproducible `random`/`shuffle`.
#' @return The row-corrupted data frame.
#' @export
cs_corrupt_rows <- function(x, keep = 0.2, mode = c("random", "head", "tail",
                                                     "block", "stride",
                                                     "shuffle", "duplicate"),
                            k = NULL, seed = NULL) {
  mode <- match.arg(mode)
  N <- nrow(x)
  m <- max(1L, floor(keep * N))
  if (!is.null(seed)) set.seed(seed)
  idx <- switch(mode,
    random = sort(sample.int(N, m)),
    head = seq_len(m),
    tail = seq.int(N - m + 1L, N),
    block = {
      start <- max(1L, (N - m) %/% 2L)
      seq.int(start, length.out = m)
    },
    stride = {
      k <- k %||% max(2L, round(1 / keep))
      seq.int(1L, N, by = k)
    },
    shuffle = sample.int(N),
    duplicate = c(seq_len(N), sample.int(N, m, replace = TRUE))
  )
  out <- x[idx, , drop = FALSE]
  rownames(out) <- NULL
  .cs_tag(out, sprintf("rows(mode=%s, keep=%g)", mode, keep))
}

#' Drop columns or split a column (Text-to-Columns)
#'
#' @param x A data frame.
#' @param drop Character vector of column names to remove.
#' @param split_on A single character to split a column on; with `split_col`,
#'   simulates a spreadsheet Text-to-Columns.
#' @param split_col Name of the column to split.
#' @return The column-corrupted data frame.
#' @export
cs_corrupt_columns <- function(x, drop = NULL, split_on = NULL,
                               split_col = NULL) {
  if (!is.null(drop)) x <- x[, setdiff(names(x), drop), drop = FALSE]
  if (!is.null(split_on) && !is.null(split_col) && split_col %in% names(x)) {
    pieces <- strsplit(as.character(x[[split_col]]), split_on, fixed = TRUE)
    maxp <- max(lengths(pieces))
    mat <- t(vapply(pieces, function(p) {
      length(p) <- maxp
      p
    }, character(maxp)))
    newcols <- as.data.frame(mat, stringsAsFactors = FALSE)
    names(newcols) <- paste0(split_col, "_", seq_len(maxp))
    j <- match(split_col, names(x))
    x <- cbind(x[, seq_len(j - 1L), drop = FALSE], newcols,
               x[, setdiff(seq_len(ncol(x)), seq_len(j)), drop = FALSE])
  }
  .cs_tag(x, sprintf("columns(drop=%s, split=%s)",
                     paste(drop, collapse = "+") %||% "", split_col %||% ""))
}

#' Remove or regenerate the header
#'
#' @param x A data frame.
#' @param mode `"rename"` to `V1..Vn`, or `"blank"` for empty names.
#' @return The data frame with mangled column names.
#' @export
cs_corrupt_header <- function(x, mode = c("rename", "blank")) {
  mode <- match.arg(mode)
  names(x) <- switch(mode,
    rename = paste0("V", seq_len(ncol(x))),
    blank = rep("", ncol(x))
  )
  .cs_tag(x, sprintf("header(mode=%s)", mode))
}

# Transform one data cell the way a spreadsheet would on import.
.cs_excel_cell <- function(s) {
  if (is.na(s)) return(s)
  s <- trimws(s)
  if (grepl("^0[0-9]+$", s)) return(as.character(as.integer(s))) # leading zeros
  if (grepl("^[0-9]{16,}$", s)) {                                 # long -> sci
    return(formatC(as.numeric(s), format = "e", digits = 2))
  }
  if (grepl("^(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|SEPT|OCT|NOV|DEC)[0-9]+$",
            s, ignore.case = TRUE)) {
    return(paste0("2024-", toupper(substr(s, 1, 3)), "-01"))      # date coercion
  }
  if (grepl("^[0-9]{1,2}[-/][0-9]{1,2}$", s)) {                    # 1/12, 3-4
    return(gsub("[-/]", "-", paste0("2024-", s)))
  }
  if (grepl("^[=+@-]", s)) return(paste0("#NAME?"))               # formula
  s
}

#' Simulate a spreadsheet's import coercions
#'
#' Strips leading zeros, renders long digit strings in scientific notation,
#' coerces date- and fraction-like strings to dates, replaces formula cells
#' with `#NAME?`, and trims whitespace. Packet cells (which begin with `{{`)
#' match none of these and pass through untouched.
#'
#' @param x A data frame.
#' @return The data frame with data cells coerced.
#' @export
cs_corrupt_excel <- function(x) {
  for (nm in names(x)) {
    col <- as.character(x[[nm]])
    x[[nm]] <- vapply(col, .cs_excel_cell, character(1), USE.NAMES = FALSE)
  }
  .cs_tag(x, "excel()")
}

#' Truncate every cell to `n` characters
#' @param x A data frame.
#' @param n Maximum characters per cell.
#' @return The truncated data frame.
#' @export
cs_corrupt_truncate <- function(x, n = 200L) {
  for (nm in names(x)) x[[nm]] <- substr(as.character(x[[nm]]), 1L, n)
  .cs_tag(x, sprintf("truncate(n=%d)", n))
}

#' Change the case of every cell
#' @param x A data frame.
#' @param mode `"upper"`, `"lower"`, or `"title"`.
#' @return The case-folded data frame.
#' @export
cs_corrupt_case <- function(x, mode = c("upper", "lower", "title")) {
  mode <- match.arg(mode)
  f <- switch(mode, upper = toupper, lower = tolower,
              title = function(s) tools::toTitleCase(tolower(s)))
  for (nm in names(x)) x[[nm]] <- f(as.character(x[[nm]]))
  .cs_tag(x, sprintf("case(mode=%s)", mode))
}

#' Bind two data frames with different schemas (version mixing)
#' @param a,b Data frames.
#' @return Their row-bind, with columns unioned.
#' @export
cs_corrupt_merge <- function(a, b) {
  cols <- union(names(a), names(b))
  fill <- function(d) {
    for (nm in setdiff(cols, names(d))) d[[nm]] <- NA
    d[, cols, drop = FALSE]
  }
  out <- rbind(fill(a), fill(b))
  rownames(out) <- NULL
  .cs_tag(out, "merge()")
}

#' Global find-and-replace across all cells
#' @param x A data frame.
#' @param pattern,replacement Passed to [gsub()].
#' @param fixed Treat `pattern` as a fixed string.
#' @return The edited data frame.
#' @export
cs_corrupt_replace <- function(x, pattern, replacement, fixed = TRUE) {
  for (nm in names(x)) {
    x[[nm]] <- gsub(pattern, replacement, as.character(x[[nm]]), fixed = fixed)
  }
  .cs_tag(x, sprintf("replace(%s->%s)", pattern, replacement))
}

# --- raw-text simulators ----------------------------------------------------

#' Re-encode text (mojibake)
#' @param text A character vector.
#' @param from,to Source and target encodings.
#' @return The re-encoded text.
#' @export
cs_corrupt_encoding <- function(text, from = "UTF-8", to = "latin1") {
  out <- iconv(text, from = from, to = to, sub = "byte")
  .cs_tag(out, sprintf("encoding(%s->%s)", from, to))
}

#' Prepend a UTF-8 BOM
#' @param text A character vector (first element gets the BOM).
#' @return The text with a BOM.
#' @export
cs_corrupt_bom <- function(text) {
  if (length(text)) text[1] <- paste0("\ufeff", text[1])
  .cs_tag(text, "bom()")
}

#' Rewrite the delimiter with correct requoting
#' @param text A character vector of CSV lines, or one string.
#' @param to New delimiter: `";"`, `"\t"`, or `"|"`.
#' @return CSV text using the new delimiter.
#' @export
cs_corrupt_delimiter <- function(text, to = ";") {
  df <- utils::read.csv(text = paste(text, collapse = "\n"),
                        colClasses = "character", check.names = FALSE,
                        na.strings = character(0))
  tf <- tempfile()
  on.exit(unlink(tf))
  utils::write.table(df, tf, sep = to, row.names = FALSE, na = "",
                     qmethod = "double", eol = "\n")
  out <- readLines(tf, warn = FALSE)
  .cs_tag(out, sprintf("delimiter(to=%s)", if (to == "\t") "tab" else to))
}

#' Straight quotes to curly, `--` to em dash
#' @param text A character vector.
#' @return The smart-quoted text.
#' @export
cs_corrupt_smartquotes <- function(text) {
  out <- gsub("--", "\u2014", text, fixed = TRUE)
  out <- gsub('"', "\u201d", out, fixed = TRUE)
  out <- gsub("'", "\u2019", out, fixed = TRUE)
  .cs_tag(out, "smartquotes()")
}

#' Trim, pad, or non-breaking-space the text
#' @param text A character vector.
#' @param mode `"trim"`, `"pad"`, or `"nbsp"`.
#' @return The whitespace-altered text.
#' @export
cs_corrupt_whitespace <- function(text, mode = c("trim", "pad", "nbsp")) {
  mode <- match.arg(mode)
  out <- switch(mode,
    trim = trimws(text),
    pad = paste0("  ", text, "  "),
    nbsp = gsub(" ", "\u00a0", text, fixed = TRUE)
  )
  .cs_tag(out, sprintf("whitespace(mode=%s)", mode))
}

#' Swap line endings or drop the trailing newline
#' @param text A character vector of lines, or one string.
#' @param mode `"crlf"`, `"lf"`, or `"no_trailing"`.
#' @return A single string with altered line endings.
#' @export
cs_corrupt_eol <- function(text, mode = c("crlf", "lf", "no_trailing")) {
  mode <- match.arg(mode)
  lines <- unlist(strsplit(paste(text, collapse = "\n"), "\n", fixed = TRUE))
  out <- switch(mode,
    crlf = paste0(paste(lines, collapse = "\r\n"), "\r\n"),
    lf = paste0(paste(lines, collapse = "\n"), "\n"),
    no_trailing = paste(lines, collapse = "\n")
  )
  .cs_tag(out, sprintf("eol(mode=%s)", mode))
}

#' Insert zero-width spaces and soft hyphens
#' @param text A character vector.
#' @param n Roughly how many invisible characters to insert per element.
#' @param seed Optional RNG seed.
#' @return The text with invisible characters inserted.
#' @export
cs_corrupt_invisible <- function(text, n = 3L, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)
  invis <- c("\u200b", "\u00ad") # zero-width space, soft hyphen
  out <- vapply(text, function(s) {
    if (is.na(s) || nchar(s) < 2L) return(s)
    for (i in seq_len(n)) {
      pos <- sample.int(nchar(s) - 1L, 1L)
      s <- paste0(substr(s, 1L, pos), sample(invis, 1L),
                  substr(s, pos + 1L, nchar(s)))
    }
    s
  }, character(1), USE.NAMES = FALSE)
  .cs_tag(out, sprintf("invisible(n=%d)", n))
}
