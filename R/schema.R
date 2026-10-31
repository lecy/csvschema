# schema.R ------------------------------------------------------------------
#
# The schema model and the one-to-one mapping between Frictionless Table Schema
# v2 field properties and the wire payload grammar. An `cs_schema` object stores
# Frictionless-named properties; the canonical payload text (and therefore the
# whole-schema hash) is produced here and consumed by the codec layer.

# Small helpers ---------------------------------------------------------------

# Split a separated string into items, preserving leading AND trailing empty
# items (base strsplit() drops trailing empties). All separators are single
# characters.
.cs_split_items <- function(s, sep) {
  if (length(s) == 0L) return(character(0))
  parts <- strsplit(s, sep, fixed = TRUE)[[1]]
  nsep <- nchar(s) - nchar(gsub(sep, "", s, fixed = TRUE))
  expected <- nsep + 1L
  if (length(parts) < expected) {
    parts <- c(parts, rep("", expected - length(parts)))
  }
  parts
}

.cs_num <- function(x) suppressWarnings(as.numeric(x))

# Build a code:label item list string from a list of list(value=, label=).
.cs_codelabels_to_items <- function(cl) {
  vapply(cl, function(e) {
    paste0(cs_encode_token(as.character(e$value)), CS_CODE_SEP,
           cs_encode_token(as.character(e$label)))
  }, character(1))
}

.cs_categories_to_value <- function(categories) {
  items <- vapply(categories, function(c) {
    if (is.list(c)) {
      paste0(cs_encode_token(as.character(c$value)), CS_CODE_SEP,
             cs_encode_token(as.character(c$label)))
    } else {
      cs_encode_token(as.character(c))
    }
  }, character(1))
  paste(items, collapse = CS_ITEM_SEP)
}

.cs_parse_categories <- function(val) {
  items <- .cs_split_items(val, CS_ITEM_SEP)
  lapply(items, function(it) {
    if (grepl(CS_CODE_SEP, it, fixed = TRUE)) {
      code <- sub(paste0(CS_CODE_SEP, ".*$"), "", it)
      lab  <- sub(paste0("^[^", CS_CODE_SEP, "]*", CS_CODE_SEP), "", it)
      list(value = cs_decode_token(code), label = cs_decode_token(lab))
    } else {
      cs_decode_token(it)
    }
  })
}

# Type inference --------------------------------------------------------------

.cs_infer_field <- function(x, name) {
  field <- list(name = name)

  if (inherits(x, "haven_labelled")) {
    labs <- attr(x, "labels")
    field$type <- if (is.character(x) || is.character(labs)) "string" else "integer"
    if (length(labs)) {
      field$categories <- lapply(seq_along(labs), function(i) {
        list(value = unname(labs[i]), label = names(labs)[i])
      })
    }
    na_values <- attr(x, "na_values")
    if (length(na_values)) {
      field$missingValues <- as.list(as.character(na_values))
    }
    if (!is.null(attr(x, "label"))) field$title <- attr(x, "label")
    return(field)
  }

  if (inherits(x, "Date")) {
    field$type <- "date"
    field$format <- CS_DATE_FORMAT
    return(field)
  }
  if (inherits(x, c("POSIXct", "POSIXlt"))) {
    field$type <- "datetime"
    field$format <- CS_DATETIME_FORMAT
    return(field)
  }
  if (is.factor(x)) {
    field$type <- "string"
    field$categories <- as.list(levels(x))
    if (is.ordered(x)) field$categoriesOrdered <- TRUE
    return(field)
  }
  if (is.logical(x)) {
    field$type <- "boolean"
    return(field)
  }
  if (is.integer(x)) {
    field$type <- "integer"
    return(field)
  }
  if (is.numeric(x)) {
    field$type <- "number"
    return(field)
  }

  # Carry a column label if one is present (Hmisc/labelled style).
  lab <- attr(x, "label")
  if (!is.null(lab)) field$title <- lab
  field$type <- "string"
  field
}

# Constructor -----------------------------------------------------------------

#' Build a schema from a data frame
#'
#' Infers a Frictionless Table Schema v2 from a data frame, honoring factors
#' (ordered and unordered), `haven::labelled` vectors, `Date`, `POSIXct`,
#' integer-versus-double, logical, and character columns. Per-field overrides
#' and table-level keys may be supplied.
#'
#' @param df A data frame.
#' @param overrides Named list; each name is a column and each value a list of
#'   Frictionless field properties to merge over the inferred field (for
#'   example `list(ein = list(constraints = list(pattern = "^[0-9]{9}$",
#'   unique = TRUE)))`).
#' @param primary_key Character vector of field names forming the primary key.
#' @param foreign_keys List of foreign keys, each
#'   `list(fields =, reference = list(resource =, fields =))`.
#' @param fields_match Frictionless `fieldsMatch` mode, or `NULL`.
#' @param enc Intended encoding of the data columns, recorded for diagnosis.
#' @param dialect CSV dialect name recorded in packet 0.
#' @return An object of class `cs_schema`.
#' @examples
#' cs_schema(data.frame(id = 1:3, grp = factor(c("a", "b", "a"))))
#' @export
cs_schema <- function(df, overrides = NULL, primary_key = NULL,
                      foreign_keys = NULL, fields_match = NULL,
                      enc = "utf-8", dialect = "rfc4180") {
  if (!is.data.frame(df)) stop("`df` must be a data frame.", call. = FALSE)
  nms <- names(df)
  fields <- lapply(nms, function(nm) .cs_infer_field(df[[nm]], nm))
  names(fields) <- nms

  if (!is.null(overrides)) {
    for (nm in names(overrides)) {
      if (!nm %in% nms) {
        stop(sprintf("override for unknown column '%s'", nm), call. = FALSE)
      }
      fields[[nm]] <- utils::modifyList(fields[[nm]], overrides[[nm]])
    }
  }
  names(fields) <- NULL

  structure(
    list(
      fields = fields,
      table = list(
        primaryKey = primary_key,
        foreignKeys = foreign_keys,
        fieldsMatch = fields_match
      ),
      meta = list(
        enc = enc,
        dialect = dialect,
        rows = nrow(df),
        wire_version = CS_WIRE_VERSION
      )
    ),
    class = "cs_schema"
  )
}

#' @export
#' @rdname cs_schema
#' @param x An object to test with `is_cs_schema()`.
is_cs_schema <- function(x) inherits(x, "cs_schema")

# Field <-> payload -----------------------------------------------------------

.cs_field_to_payload <- function(field) {
  type_short <- CS_TYPE_ABBR[[field$type]]
  if (is.null(type_short) || is.na(type_short)) type_short <- field$type
  parts <- c(cs_encode_token(field$name), type_short)

  co <- field$constraints
  if (!is.null(field$format)) {
    parts <- c(parts, paste0("fmt", CS_KV_SEP, cs_encode_token(field$format)))
  }
  if (!is.null(field$missingValues) &&
      !identical(field$missingValues, CS_DEFAULT_MISSING)) {
    items <- vapply(field$missingValues,
                    function(v) cs_encode_token(as.character(v)), character(1))
    parts <- c(parts, paste0("na", CS_KV_SEP, paste(items, collapse = CS_ITEM_SEP)))
  }
  if (!is.null(field$naLabels)) {
    parts <- c(parts, paste0("nalab", CS_KV_SEP,
                             paste(.cs_codelabels_to_items(field$naLabels),
                                   collapse = CS_ITEM_SEP)))
  }
  if (!is.null(field$categories)) {
    parts <- c(parts, paste0("lev", CS_KV_SEP,
                             .cs_categories_to_value(field$categories)))
  }
  if (isTRUE(field$categoriesOrdered)) parts <- c(parts, "ord")
  if (!is.null(co$pattern)) {
    parts <- c(parts, paste0("pat", CS_KV_SEP, cs_encode_token(co$pattern)))
  }
  if (isTRUE(co$unique)) parts <- c(parts, "uniq")
  if (isTRUE(co$required)) parts <- c(parts, "req")
  if (!is.null(co$minimum)) {
    parts <- c(parts, paste0("min", CS_KV_SEP,
                             cs_encode_token(as.character(co$minimum))))
  }
  if (!is.null(co$maximum)) {
    parts <- c(parts, paste0("max", CS_KV_SEP,
                             cs_encode_token(as.character(co$maximum))))
  }
  if (!is.null(field$title)) {
    parts <- c(parts, paste0("lab", CS_KV_SEP, cs_encode_token(field$title)))
  }
  if (!is.null(field$description)) {
    parts <- c(parts, paste0("desc", CS_KV_SEP, cs_encode_token(field$description)))
  }
  # Unknown keys preserved verbatim, in a stable order.
  if (!is.null(field$extra)) {
    for (k in sort(names(field$extra))) {
      parts <- c(parts, paste0(k, CS_KV_SEP, cs_encode_token(field$extra[[k]])))
    }
  }
  paste(parts, collapse = CS_ATTR_SEP)
}

.cs_payload_to_field <- function(payload) {
  attrs <- .cs_split_items(payload, CS_ATTR_SEP)
  field <- list(name = cs_decode_token(attrs[1]))
  type_short <- if (length(attrs) >= 2L) attrs[2] else ""
  full <- if (type_short %in% names(CS_TYPE_FULL)) CS_TYPE_FULL[[type_short]] else NA
  field$type <- if (is.na(full)) type_short else full
  constraints <- list()
  extra <- list()
  rest <- if (length(attrs) > 2L) attrs[-(1:2)] else character(0)
  for (a in rest) {
    if (grepl(CS_KV_SEP, a, fixed = TRUE)) {
      key <- sub(paste0(CS_KV_SEP, ".*$"), "", a)
      val <- sub(paste0("^[^", CS_KV_SEP, "]*", CS_KV_SEP), "", a)
      if (key == "fmt") {
        field$format <- cs_decode_token(val)
      } else if (key == "na") {
        # Append so a list split across fragments reassembles in order.
        field$missingValues <- c(field$missingValues,
                                 lapply(.cs_split_items(val, CS_ITEM_SEP),
                                        cs_decode_token))
      } else if (key == "nalab") {
        field$naLabels <- c(field$naLabels, .cs_parse_categories(val))
      } else if (key == "lev") {
        field$categories <- c(field$categories, .cs_parse_categories(val))
      } else if (key == "pat") {
        constraints$pattern <- cs_decode_token(val)
      } else if (key == "min") {
        constraints$minimum <- .cs_num(cs_decode_token(val))
      } else if (key == "max") {
        constraints$maximum <- .cs_num(cs_decode_token(val))
      } else if (key == "lab") {
        field$title <- cs_decode_token(val)
      } else if (key == "desc") {
        field$description <- cs_decode_token(val)
      } else {
        extra[[key]] <- cs_decode_token(val)
      }
    } else {
      if (a == "ord") {
        field$categoriesOrdered <- TRUE
      } else if (a == "uniq") {
        constraints$unique <- TRUE
      } else if (a == "req") {
        constraints$required <- TRUE
      } else {
        field$flags <- c(field$flags, a)
      }
    }
  }
  if (length(constraints)) field$constraints <- constraints
  if (length(extra)) field$extra <- extra
  field
}

# Table <-> payload -----------------------------------------------------------

.cs_table_to_payload <- function(table) {
  parts <- character(0)
  if (length(table$primaryKey)) {
    pk <- paste(vapply(table$primaryKey, cs_encode_token, character(1)),
                collapse = CS_ITEM_SEP)
    parts <- c(parts, paste0("pk", CS_KV_SEP, pk))
  }
  if (length(table$foreignKeys)) {
    fks <- vapply(table$foreignKeys, function(fk) {
      local <- cs_encode_token(paste(fk$fields, collapse = ","))
      res <- cs_encode_token(fk$reference$resource %||% "")
      rem <- cs_encode_token(paste(fk$reference$fields, collapse = ","))
      paste0(local, CS_CODE_SEP, res, ".", rem)
    }, character(1))
    parts <- c(parts, paste0("fk", CS_KV_SEP, paste(fks, collapse = CS_ITEM_SEP)))
  }
  if (!is.null(table$fieldsMatch)) {
    parts <- c(parts, paste0("fm", CS_KV_SEP, cs_encode_token(table$fieldsMatch)))
  }
  paste(parts, collapse = CS_ATTR_SEP)
}

.cs_payload_to_table <- function(payload) {
  table <- list(primaryKey = NULL, foreignKeys = NULL, fieldsMatch = NULL)
  if (identical(payload, "") || length(payload) == 0L) return(table)
  attrs <- .cs_split_items(payload, CS_ATTR_SEP)
  for (a in attrs) {
    if (!grepl(CS_KV_SEP, a, fixed = TRUE)) next
    key <- sub(paste0(CS_KV_SEP, ".*$"), "", a)
    val <- sub(paste0("^[^", CS_KV_SEP, "]*", CS_KV_SEP), "", a)
    if (key == "pk") {
      table$primaryKey <- c(table$primaryKey,
                            vapply(.cs_split_items(val, CS_ITEM_SEP),
                                   cs_decode_token, character(1),
                                   USE.NAMES = FALSE))
    } else if (key == "fk") {
      table$foreignKeys <- c(table$foreignKeys,
                             lapply(.cs_split_items(val, CS_ITEM_SEP), function(it) {
        local <- sub(paste0(CS_CODE_SEP, ".*$"), "", it)
        tgt <- sub(paste0("^[^", CS_CODE_SEP, "]*", CS_CODE_SEP), "", it)
        res <- sub("\\..*$", "", tgt)
        rem <- sub("^[^.]*\\.", "", tgt)
        list(
          fields = strsplit(cs_decode_token(local), ",", fixed = TRUE)[[1]],
          reference = list(
            resource = cs_decode_token(res),
            fields = strsplit(cs_decode_token(rem), ",", fixed = TRUE)[[1]]
          )
        )
      }))
    } else if (key == "fm") {
      table$fieldsMatch <- cs_decode_token(val)
    }
  }
  table
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# Canonical payloads, text, and hash ------------------------------------------

# Ordered canonical payloads for indices 1..P-1: one per field, then the
# table-level packet last.
.cs_schema_payloads <- function(s) {
  field_payloads <- vapply(s$fields, .cs_field_to_payload, character(1))
  c(field_payloads, .cs_table_to_payload(s$table))
}

# Rebuild an cs_schema from an ordered vector of canonical payloads (indices
# 1..P-1); the final payload is the table-level packet.
.cs_schema_from_payloads <- function(payloads, meta = NULL) {
  n <- length(payloads)
  field_payloads <- if (n > 1L) payloads[-n] else character(0)
  fields <- lapply(field_payloads, .cs_payload_to_field)
  table <- .cs_payload_to_table(payloads[n])
  structure(
    list(
      fields = fields,
      table = table,
      meta = meta %||% list(wire_version = CS_WIRE_VERSION)
    ),
    class = "cs_schema"
  )
}

# Canonical schema text used for the whole-schema hash: payloads 1..P-1 joined
# by newlines. Excludes packet 0 (which carries the hash itself).
.cs_canonical_text <- function(s) {
  paste(.cs_schema_payloads(s), collapse = "\n")
}

.cs_schema_hash <- function(s) {
  .cs_sha1(.cs_canonical_text(s), CS_SCHEMA_HASH_LEN)
}

#' @export
format.cs_schema <- function(x, ...) {
  .cs_schema_payloads(x)
}

#' @export
as.list.cs_schema <- function(x, ...) {
  unclass(x)
}

#' @export
print.cs_schema <- function(x, ...) {
  cat("<cs_schema>", length(x$fields), "fields",
      if (!is.null(x$meta$rows)) paste0("(", x$meta$rows, " rows)") else "",
      "\n")
  for (f in x$fields) {
    extra <- character(0)
    if (!is.null(f$categories)) {
      extra <- c(extra, sprintf("%d levels%s", length(f$categories),
                                if (isTRUE(f$categoriesOrdered)) ", ordered" else ""))
    }
    if (!is.null(f$format)) extra <- c(extra, paste0("fmt=", f$format))
    if (!is.null(f$missingValues)) {
      extra <- c(extra, paste0("na=", paste(unlist(f$missingValues), collapse = ",")))
    }
    if (isTRUE(f$constraints$unique)) extra <- c(extra, "unique")
    if (isTRUE(f$constraints$required)) extra <- c(extra, "required")
    if (!is.null(f$constraints$pattern)) extra <- c(extra, "pattern")
    cat(sprintf("  %-20s %-9s %s\n", f$name, f$type,
                if (length(extra)) paste0("[", paste(extra, collapse = "; "), "]") else ""))
  }
  if (length(x$table$primaryKey)) {
    cat("  primary key:", paste(x$table$primaryKey, collapse = ", "), "\n")
  }
  cat("  hash:", .cs_schema_hash(x), "\n")
  invisible(x)
}

# Frictionless conversion -----------------------------------------------------

.cs_field_to_frictionless <- function(field) {
  out <- list(name = field$name, type = field$type)
  if (!is.null(field$format)) out$format <- field$format
  if (!is.null(field$title)) out$title <- field$title
  if (!is.null(field$description)) out$description <- field$description
  if (!is.null(field$missingValues)) {
    out$missingValues <- as.list(vapply(field$missingValues, as.character,
                                        character(1)))
  }
  if (!is.null(field$categories)) {
    out$categories <- lapply(field$categories, function(c) {
      if (is.list(c)) list(value = c$value, label = c$label) else c
    })
  }
  if (isTRUE(field$categoriesOrdered)) out$categoriesOrdered <- TRUE
  if (!is.null(field$constraints)) out$constraints <- field$constraints
  out
}

#' Convert an `cs_schema` to a Frictionless Table Schema list
#'
#' @param s An `cs_schema`.
#' @return A list matching Frictionless Table Schema v2 (`fields`, and, when
#'   present, `primaryKey` and `foreignKeys`), ready for [jsonlite::toJSON()].
#' @export
cs_schema_to_frictionless <- function(s) {
  out <- list(fields = lapply(s$fields, .cs_field_to_frictionless))
  if (length(s$table$primaryKey)) out$primaryKey <- as.list(s$table$primaryKey)
  if (length(s$table$foreignKeys)) out$foreignKeys <- s$table$foreignKeys
  if (!is.null(s$table$fieldsMatch)) out$fieldsMatch <- s$table$fieldsMatch
  out
}

.cs_field_from_frictionless <- function(fr) {
  field <- list(name = fr$name, type = fr$type %||% "string")
  if (!is.null(fr$format)) field$format <- fr$format
  if (!is.null(fr$title)) field$title <- fr$title
  if (!is.null(fr$description)) field$description <- fr$description
  if (!is.null(fr$missingValues)) {
    field$missingValues <- as.list(vapply(fr$missingValues, as.character,
                                          character(1)))
  }
  if (!is.null(fr$categories)) {
    field$categories <- lapply(fr$categories, function(c) {
      if (is.list(c)) list(value = c$value, label = c$label) else c
    })
  }
  if (isTRUE(fr$categoriesOrdered)) field$categoriesOrdered <- TRUE
  if (!is.null(fr$constraints)) field$constraints <- fr$constraints
  field
}

#' Build an `cs_schema` from a Frictionless schema
#'
#' @param json A parsed Frictionless list, a JSON string, or a path to a
#'   `datapackage.json`/schema file. A Data Package is reduced to its first
#'   resource's schema.
#' @param meta Optional meta list to attach.
#' @return An `cs_schema`.
#' @export
cs_schema_from_frictionless <- function(json, meta = NULL) {
  if (is.character(json) && length(json) == 1L) {
    if (file.exists(json)) {
      json <- jsonlite::fromJSON(json, simplifyVector = FALSE)
    } else {
      json <- jsonlite::fromJSON(json, simplifyVector = FALSE)
    }
  }
  schema <- json
  if (!is.null(json$resources)) schema <- json$resources[[1]]$schema
  fields <- lapply(schema$fields, .cs_field_from_frictionless)
  table <- list(
    primaryKey = if (!is.null(schema$primaryKey)) unlist(schema$primaryKey) else NULL,
    foreignKeys = schema$foreignKeys,
    fieldsMatch = schema$fieldsMatch
  )
  structure(
    list(fields = fields, table = table,
         meta = meta %||% list(wire_version = CS_WIRE_VERSION)),
    class = "cs_schema"
  )
}

# Reader specs for use without the package ------------------------------------

#' Emit base `colClasses` for `utils::read.csv()`
#'
#' @param s An `cs_schema`.
#' @return A named character vector mapping each field to a base R class, so a
#'   user can read the file correctly without csvschema installed.
#' @export
cs_to_coltypes <- function(s) {
  map <- c(string = "character", integer = "integer", number = "numeric",
           boolean = "logical", date = "Date", datetime = "POSIXct",
           year = "integer")
  out <- vapply(s$fields, function(f) {
    cls <- map[[f$type]]
    if (is.null(cls) || is.na(cls)) "character" else cls
  }, character(1))
  stats::setNames(out, vapply(s$fields, function(f) f$name, character(1)))
}

#' Emit a `readr::cols()` specification
#'
#' @param s An `cs_schema`.
#' @return A `readr::cols` specification. Requires the readr package.
#' @export
cs_to_readr_spec <- function(s) {
  if (!requireNamespace("readr", quietly = TRUE)) {
    stop("cs_to_readr_spec() requires the 'readr' package.", call. = FALSE)
  }
  specs <- lapply(s$fields, function(f) {
    if (!is.null(f$categories) && f$type == "string") {
      levs <- vapply(f$categories, function(c) {
        if (is.list(c)) as.character(c$label) else as.character(c)
      }, character(1))
      return(readr::col_factor(levels = levs, ordered = isTRUE(f$categoriesOrdered)))
    }
    switch(f$type,
      string   = readr::col_character(),
      integer  = readr::col_integer(),
      number   = readr::col_double(),
      boolean  = readr::col_logical(),
      date     = readr::col_date(format = f$format %||% CS_DATE_FORMAT),
      datetime = readr::col_datetime(format = f$format %||% CS_DATETIME_FORMAT),
      year     = readr::col_integer(),
      readr::col_character()
    )
  })
  names(specs) <- vapply(s$fields, function(f) f$name, character(1))
  do.call(readr::cols, specs)
}
