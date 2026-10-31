#' csvschema: Self-Describing CSV Files with Embedded, Loss-Tolerant Schemas
#'
#' csvschema writes and reads CSV files that carry their own schema inside
#' ordinary data columns, so the file opens as a plain CSV in every tool and the
#' schema survives sorting, filtering, row loss, encoding changes, and
#' spreadsheet round-trips. The name is the joke: the file looks schemaless and
#' is not.
#'
#' The package does four things:
#' \enumerate{
#'   \item \strong{Packetize} a table schema into short ASCII tokens spread
#'     redundantly through one or more `_schema` columns.
#'   \item \strong{Recover} the schema from any surviving subset of rows, verify
#'     it, and apply it on read.
#'   \item \strong{Canary} the data: store fragile sample values per variable in
#'     a `_canary` column and detect, after a round-trip, whether each variable
#'     is still intact and how it was damaged.
#'   \item \strong{Point} to an optional Frictionless `datapackage.json` sidecar
#'     and cross-check hashes in both directions.
#' }
#'
#' All exported functions use the `cs_` prefix.
#'
#' @keywords internal
"_PACKAGE"
