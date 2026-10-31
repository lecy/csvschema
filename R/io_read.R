# io_read.R -----------------------------------------------------------------
#
# The read path: read every column as text, locate the packet columns by
# content, recover and (optionally) reconcile with the sidecar, run the raw
# canary check, apply the schema, run the typed canary check, drop the meta
# columns, and attach a report.

.cs_read_all_character <- function(path, reader = c("auto", "base", "readr")) {
  reader <- match.arg(reader)
  use_readr <- (reader == "readr") ||
    (reader == "auto" && requireNamespace("readr", quietly = TRUE))
  if (use_readr) {
    df <- readr::read_csv(
      path,
      col_types = readr::cols(.default = readr::col_character()),
      na = character(0), progress = FALSE, show_col_types = FALSE,
      name_repair = "minimal"
    )
    df <- as.data.frame(df, stringsAsFactors = FALSE, check.names = FALSE)
  } else {
    df <- utils::read.csv(
      path, colClasses = "character", check.names = FALSE,
      stringsAsFactors = FALSE, na.strings = character(0),
      encoding = "UTF-8"
    )
  }
  names(df) <- sub("^\ufeff", "", names(df))
  df
}

#' Detect packet-bearing columns by content
#'
#' Finds columns that hold packets regardless of their header, classifying each
#' as schema or canary by the dominant packet type.
#'
#' @param df A data frame (columns coerced to character as needed).
#' @return A list with `schema` and `canary` column-name vectors.
#' @export
cs_detect_columns <- function(df) {
  schema_cols <- character(0)
  canary_cols <- character(0)
  for (nm in names(df)) {
    col <- as.character(df[[nm]])
    if (!any(grepl(CS_COL_DETECT_RE, col))) next
    parsed <- cs_parse_packets(col)
    if (nrow(parsed) == 0L) next
    types <- table(parsed$type)
    dom <- names(types)[which.max(types)]
    if (identical(dom, tolower(CS_TYPE_SCHEMA))) {
      schema_cols <- c(schema_cols, nm)
    } else if (identical(dom, tolower(CS_TYPE_CANARY))) {
      canary_cols <- c(canary_cols, nm)
    }
  }
  list(schema = schema_cols, canary = canary_cols)
}

# Apply one field's type/categories/missing values to a character column.
.cs_apply_col <- function(x, f) {
  x <- as.character(x)
  x[x == ""] <- NA
  mv <- setdiff(unlist(f$missingValues), "")
  if (length(mv)) x[x %in% mv] <- NA
  if (!is.null(f$categories)) {
    cats <- f$categories
    if (any(vapply(cats, is.list, logical(1)))) {
      codes <- vapply(cats, function(e) as.character(e$value), character(1))
      labs <- vapply(cats, function(e) as.character(e$label), character(1))
      return(factor(x, levels = codes, labels = labs,
                    ordered = isTRUE(f$categoriesOrdered)))
    }
    levs <- vapply(cats, as.character, character(1))
    return(factor(x, levels = levs, ordered = isTRUE(f$categoriesOrdered)))
  }
  switch(f$type %||% "string",
    integer  = as.integer(x),
    year     = as.integer(x),
    number   = as.numeric(x),
    boolean  = as.logical(x),
    date     = as.Date(x, format = f$format %||% CS_DATE_FORMAT),
    datetime = as.POSIXct(x, format = f$format %||% CS_DATETIME_FORMAT,
                          tz = "UTC"),
    x
  )
}

#' Apply a schema to a character data frame
#'
#' Converts each column to its declared type, rebuilds factors from categories,
#' and maps missing-value sentinels to `NA`. Columns with no matching field are
#' left as character.
#'
#' @param df A character data frame of data columns.
#' @param s An `cs_schema`.
#' @return A typed data frame.
#' @export
cs_apply_schema <- function(df, s) {
  fbn <- stats::setNames(s$fields, vapply(s$fields, function(f) f$name,
                                          character(1)))
  for (nm in names(df)) {
    f <- fbn[[nm]]
    if (is.null(f)) next
    df[[nm]] <- .cs_apply_col(df[[nm]], f)
  }
  df
}

# Resolve in-band recovery against a sidecar, if present.
.cs_resolve_sidecar <- function(path, sidecar, rec) {
  side_path <- NULL
  if (is.character(sidecar)) {
    side_path <- sidecar
  } else if (isFALSE(sidecar)) {
    side_path <- NULL
  } else {
    cand <- if (!is.null(rec$header$side)) {
      file.path(dirname(path), rec$header$side)
    } else {
      .cs_sidecar_path(path)
    }
    if (file.exists(cand)) side_path <- cand
  }
  if (is.null(side_path) || !file.exists(side_path)) {
    return(list(schema = rec$schema, source = "inband", sidecar = NULL,
                warning = NULL))
  }

  json <- jsonlite::fromJSON(side_path, simplifyVector = FALSE)
  scar <- tryCatch(cs_schema_from_frictionless(json), error = function(e) NULL)
  side_hash <- NULL
  if (!is.null(json$resources) && length(json$resources)) {
    side_hash <- json$resources[[1]]$csvschema$schema_hash
  }
  if (is.null(side_hash) && !is.null(scar)) side_hash <- .cs_schema_hash(scar)

  if (rec$status == "verified") {
    rec_hash <- .cs_schema_hash(rec$schema)
    if (!is.null(side_hash) && !identical(rec_hash, side_hash)) {
      return(list(schema = rec$schema, source = "inband", sidecar = side_path,
                  warning = "in-band schema and sidecar disagree; using in-band"))
    }
    return(list(schema = rec$schema, source = "inband", sidecar = side_path,
                warning = NULL))
  }
  if (rec$status %in% c("incomplete", "absent") && !is.null(scar)) {
    return(list(schema = scar, source = "sidecar", sidecar = side_path,
                warning = sprintf("in-band schema %s; using sidecar",
                                  rec$status)))
  }
  list(schema = rec$schema, source = "inband", sidecar = side_path,
       warning = if (rec$status == "conflict") "in-band conflict; using in-band" else NULL)
}

#' Read a self-describing CSV
#'
#' Reads every column as text, recovers the embedded schema (reconciling with a
#' sidecar when present), checks the data against its canaries both before and
#' after type conversion, applies the schema, and drops the meta columns. The
#' recovery and canary results are attached as a `cs_report` and summarized in
#' one line.
#'
#' @param path CSV path.
#' @param sidecar Sidecar path, `NULL` to auto-detect, or `FALSE` to ignore.
#' @param keep_meta Keep the `_schema`/`_canary` columns in the result.
#' @param apply Apply the recovered schema (types, factors, NA codes).
#' @param verify_file Check the sidecar's file-byte hash.
#' @param reader CSV reader backend: `"auto"`, `"base"`, or `"readr"`.
#' @param verbose Print the one-line summary.
#' @return A data frame with a `cs_report` attribute. Fetch the report with
#'   [cs_report()].
#' @examples
#' tmp <- tempfile(fileext = ".csv")
#' cs_write(data.frame(id = 1:5, g = factor(c("a", "b", "a", "b", "a"))),
#'          tmp, sidecar = FALSE, verbose = FALSE)
#' out <- cs_read_csv(tmp, verbose = FALSE)
#' attr(out, "cs_report")$status
#' @export
cs_read_csv <- function(path, sidecar = NULL, keep_meta = FALSE, apply = TRUE,
                        verify_file = FALSE, reader = "auto", verbose = TRUE) {
  raw <- .cs_read_all_character(path, reader)
  nc <- length(raw)

  # Locate packet-bearing columns by content, by position (robust to lost,
  # blank, or duplicate headers). Gather every packet cell and recover both
  # schema and canary from the combined set, so a collapsed file (e.g. a
  # delimiter change that mashes all columns into one) still yields both.
  is_packet <- vapply(seq_len(nc), function(j) {
    any(grepl(CS_COL_DETECT_RE, as.character(raw[[j]])))
  }, logical(1))
  packet_idx <- which(is_packet)
  data_idx <- which(!is_packet)

  packet_cells <- if (length(packet_idx)) {
    unlist(lapply(packet_idx, function(j) as.character(raw[[j]])),
           use.names = FALSE)
  } else {
    character(0)
  }
  parsed_all <- cs_parse_packets(packet_cells)
  rec <- cs_recover(parsed_all, type = CS_TYPE_SCHEMA)

  resolved <- .cs_resolve_sidecar(path, sidecar, rec)
  s <- resolved$schema
  if (!is.null(resolved$warning)) warning(resolved$warning, call. = FALSE)

  raw_data <- raw[data_idx]
  raw_data <- as.data.frame(raw_data, stringsAsFactors = FALSE,
                            check.names = FALSE)

  # If the header was lost or mangled, map schema fields to data columns by
  # position (meta columns are always appended last, so order is preserved).
  if (!is.null(s) && length(s$fields)) {
    fn <- vapply(s$fields, function(f) f$name, character(1))
    if (ncol(raw_data) == length(fn) && !all(fn %in% names(raw_data))) {
      names(raw_data) <- fn
    }
  }

  canaries <- .cs_canaries_from_parsed(parsed_all)
  canary_raw <- cs_canary_check(raw_data, canaries)

  typed <- raw_data
  canary_typed <- NULL
  if (apply && !is.null(s) && length(s$fields)) {
    typed <- cs_apply_schema(raw_data, s)
    if (length(canaries)) {
      reser <- .cs_format_columns(typed, s)
      for (nm in names(reser)) reser[[nm]][is.na(reser[[nm]])] <- ""
      canary_typed <- cs_canary_check(reser, canaries, typed = TRUE)
    }
  }

  file_hash_ok <- NA
  if (verify_file && !is.null(resolved$sidecar)) {
    json <- jsonlite::fromJSON(resolved$sidecar, simplifyVector = FALSE)
    stored <- json$resources[[1]]$hash
    if (!is.null(stored)) {
      stored <- sub("^sha1:", "", stored)
      file_hash_ok <- identical(digest::digest(file = path, algo = "sha1"),
                                stored)
    }
  }

  report <- .cs_make_report(rec, resolved$source, canary_raw, canary_typed,
                            rows_read = nrow(raw), file_hash_ok = file_hash_ok,
                            schema = s)

  result <- if (apply) typed else raw_data
  if (keep_meta) {
    meta_names <- names(raw)[packet_idx]
    for (j in seq_along(packet_idx)) {
      result[[meta_names[j]]] <- raw[[packet_idx[j]]]
    }
  }
  attr(result, "cs_report") <- report
  if (verbose) message(.cs_report_oneline(report))
  result
}
