# io_write.R ----------------------------------------------------------------
#
# The write path: format columns to their exact on-disk strings, build canary
# packets from those strings, packetize and lay out the schema, append the
# `_schema` and `_canary` columns, write the CSV, and (optionally) write a
# Frictionless sidecar carrying cross-hashes.

# Column names for c replicated meta columns: base, base2, base3, ...
.cs_col_names <- function(base, n) {
  if (n <= 1L) base else c(base, paste0(base, 2:n))
}

# Format one column to the exact character form written to the CSV.
.cs_format_col <- function(x, field) {
  type <- field$type %||% "string"
  if (inherits(x, "Date")) {
    out <- format(x, format = field$format %||% CS_DATE_FORMAT)
  } else if (inherits(x, c("POSIXct", "POSIXlt"))) {
    out <- format(x, format = field$format %||% CS_DATETIME_FORMAT)
  } else if (inherits(x, "haven_labelled")) {
    v <- unclass(x)
    attributes(v) <- NULL
    out <- as.character(v)
  } else if (is.factor(x)) {
    out <- as.character(x)
  } else {
    out <- as.character(x)
  }
  out[is.na(x)] <- NA_character_
  out
}

# Format all data columns; returns a character data frame, NA preserved.
.cs_format_columns <- function(df, s) {
  fbn <- stats::setNames(s$fields, vapply(s$fields, function(f) f$name,
                                          character(1)))
  cols <- lapply(names(df), function(nm) .cs_format_col(df[[nm]], fbn[[nm]]))
  names(cols) <- names(df)
  as.data.frame(cols, stringsAsFactors = FALSE, optional = TRUE,
                check.names = FALSE)
}

.cs_sidecar_path <- function(path) {
  file.path(dirname(path), "datapackage.json")
}

# Recursively sort list keys for a canonical JSON serialization.
.cs_sort_keys <- function(x) {
  if (is.list(x)) {
    x <- lapply(x, .cs_sort_keys)
    nm <- names(x)
    if (!is.null(nm) && length(nm) == length(x)) x <- x[order(nm)]
  }
  x
}

.cs_canonical_sidecar_json <- function(obj) {
  as.character(jsonlite::toJSON(.cs_sort_keys(obj), auto_unbox = TRUE,
                                pretty = FALSE, null = "null"))
}

.cs_sidecar_object <- function(s, csv_path, csv_hash = NULL, layout = NULL,
                               meta_cols = NULL, mtu = CS_DEFAULT_MTU) {
  resource <- list(
    name = tolower(gsub("[^A-Za-z0-9]+", "-",
                        tools::file_path_sans_ext(basename(csv_path)))),
    path = basename(csv_path),
    type = "table",
    scheme = "file",
    format = "csv",
    mediatype = "text/csv",
    dialect = list(delimiter = ",", quoteChar = "\""),
    schema = cs_schema_to_frictionless(s)
  )
  if (!is.null(csv_hash)) resource$hash <- paste0("sha1:", csv_hash)
  resource$csvschema <- list(
    wire_version = CS_WIRE_VERSION,
    mtu = mtu,
    columns = as.list(meta_cols %||% character(0)),
    c = layout$c %||% 1L,
    p = layout$p %||% 1L,
    redundancy = layout$sentence %||% "",
    schema_hash = .cs_schema_hash(s)
  )
  list(
    `$schema` = "https://datapackage.org/profiles/2.0/datapackage.json",
    name = resource$name,
    resources = list(resource)
  )
}

# Write a data frame to CSV: RFC 4180, UTF-8, no BOM, NA as empty.
.cs_write_csv <- function(df, path, writer = c("auto", "readr", "base")) {
  writer <- match.arg(writer)
  use_readr <- (writer == "readr") ||
    (writer == "auto" && requireNamespace("readr", quietly = TRUE))
  if (use_readr) {
    readr::write_csv(df, path, na = "", eol = "\n")
  } else {
    utils::write.table(df, path, sep = ",", row.names = FALSE, na = "",
                       qmethod = "double", fileEncoding = "UTF-8",
                       eol = "\n", quote = TRUE)
  }
  invisible(path)
}

#' Write a self-describing CSV
#'
#' One-call writer. Builds a schema from `df` (unless one is supplied),
#' packetizes it, sizes and stripes the redundancy, appends the `_schema`
#' (and, by default, `_canary`) columns, and writes the CSV. When `sidecar` is
#' not `FALSE`, also writes a Frictionless `datapackage.json` beside it with the
#' file hash.
#'
#' @param df A data frame.
#' @param path Output CSV path.
#' @param schema An `cs_schema`; built from `df` if `NULL`.
#' @param sidecar `TRUE` to write `datapackage.json` beside the CSV, `FALSE` for
#'   none, or a path.
#' @param mtu Maximum packet length in characters.
#' @param f Fraction of rows the redundancy is designed to survive.
#' @param eps Acceptable packet-loss probability.
#' @param c,p Override the chosen number of schema columns / packets per cell.
#' @param canary Whether to add the `_canary` column.
#' @param k Canary samples per variable.
#' @param writer CSV writer backend: `"auto"`, `"readr"`, or `"base"`.
#' @param verbose Print the layout summary.
#' @return The `cs_schema`, invisibly, with a `layout` attribute.
#' @examples
#' tmp <- tempfile(fileext = ".csv")
#' cs_write(data.frame(id = 1:5, g = factor(c("a", "b", "a", "b", "a"))),
#'          tmp, sidecar = FALSE, verbose = FALSE)
#' @export
cs_write <- function(df, path, schema = NULL, sidecar = TRUE,
                     mtu = CS_DEFAULT_MTU, f = CS_DEFAULT_F, eps = CS_DEFAULT_EPS,
                     c = NULL, p = NULL, canary = TRUE, k = CS_DEFAULT_CANARY_K,
                     writer = "auto", verbose = TRUE) {
  if (!is.data.frame(df)) stop("`df` must be a data frame.", call. = FALSE)
  s <- schema %||% cs_schema(df)
  s$meta$rows <- nrow(df)
  s$meta$mtu <- mtu
  N <- nrow(df)
  if (N < 1L) stop("`df` has no rows.", call. = FALSE)

  chr <- .cs_format_columns(df, s)

  # Canary packets from the exact on-disk strings.
  canary_packets <- character(0)
  if (canary) canary_packets <- cs_canary(chr, s, k = k)

  side_name <- NULL
  if (isTRUE(sidecar)) {
    side_name <- .cs_sidecar_path(path)
  } else if (is.character(sidecar)) {
    side_name <- sidecar
  }

  sidehash <- NULL
  if (!is.null(side_name)) {
    obj0 <- .cs_sidecar_object(s, path, csv_hash = NULL, mtu = mtu)
    sidehash <- .cs_sha1(.cs_canonical_sidecar_json(obj0), CS_FINGERPRINT_LEN)
  }

  sp <- cs_packetize(s, mtu = mtu,
                     side = if (!is.null(side_name)) basename(side_name) else NULL,
                     sidehash = sidehash)
  P_s <- length(sp)
  red_s <- cs_redundancy(P_s, N, f = f, eps = eps, mtu = mtu,
                         packet_len = mean(nchar(sp)))
  cc <- c %||% red_s$c
  pp <- p %||% red_s$p
  schema_cols <- cs_lay(sp, N, cc, pp)
  scol_names <- .cs_col_names(CS_SCHEMA_COL, ncol(schema_cols))

  canary_cols <- NULL
  ccol_names <- character(0)
  if (canary && length(canary_packets)) {
    P_c <- length(canary_packets)
    red_c <- cs_redundancy(P_c, N, f = f, eps = eps, mtu = mtu,
                           packet_len = mean(nchar(canary_packets)))
    canary_cols <- cs_lay(canary_packets, N, red_c$c, red_c$p)
    ccol_names <- .cs_col_names(CS_CANARY_COL, ncol(canary_cols))
  }

  out <- chr
  for (j in seq_len(ncol(schema_cols))) out[[scol_names[j]]] <- schema_cols[, j]
  if (!is.null(canary_cols)) {
    for (j in seq_len(ncol(canary_cols))) out[[ccol_names[j]]] <- canary_cols[, j]
  }

  .cs_write_csv(out, path, writer)

  if (!is.null(side_name)) {
    csv_hash <- digest::digest(file = path, algo = "sha1")
    obj <- .cs_sidecar_object(
      s, path, csv_hash = csv_hash,
      layout = list(c = cc, p = pp, sentence = red_s$sentence),
      meta_cols = c(scol_names, ccol_names), mtu = mtu
    )
    writeLines(jsonlite::toJSON(obj, auto_unbox = TRUE, pretty = TRUE,
                                null = "null"),
               side_name, useBytes = TRUE)
  }

  attr(s, "layout") <- list(c = cc, p = pp, P = P_s, redundancy = red_s,
                            schema_cols = scol_names, canary_cols = ccol_names)
  if (verbose) {
    message(sprintf("csvschema: %d packets, c=%d, p=%d; %s",
                    P_s, cc, pp, red_s$sentence))
  }
  invisible(s)
}

#' @rdname cs_write
#' @param out A fully-assembled character data frame (data plus meta columns).
#' @export
cs_write_csv <- function(out, path, writer = "auto") {
  .cs_write_csv(out, path, writer)
}

#' Write a Frictionless sidecar for a schema
#'
#' @param s An `cs_schema`.
#' @param csv_path Path of the CSV the sidecar describes.
#' @param sidecar_path Output path; defaults to `datapackage.json` beside the
#'   CSV.
#' @param mtu MTU to record.
#' @return The sidecar path, invisibly.
#' @export
cs_write_sidecar <- function(s, csv_path, sidecar_path = NULL,
                             mtu = CS_DEFAULT_MTU) {
  sidecar_path <- sidecar_path %||% .cs_sidecar_path(csv_path)
  csv_hash <- if (file.exists(csv_path)) {
    digest::digest(file = csv_path, algo = "sha1")
  } else {
    NULL
  }
  obj <- .cs_sidecar_object(s, csv_path, csv_hash = csv_hash, mtu = mtu)
  writeLines(jsonlite::toJSON(obj, auto_unbox = TRUE, pretty = TRUE,
                              null = "null"),
             sidecar_path, useBytes = TRUE)
  invisible(sidecar_path)
}
