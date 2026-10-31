# constants.R ---------------------------------------------------------------
#
# Every separator, wrapper, regex, default, and the wire-format version live
# here so they can be reviewed and swapped in one place before v1.0. Nothing
# elsewhere in the package should hard-code a separator or a magic number.

# Wire-format version ---------------------------------------------------------

#' Wire-format version carried in packet 0 as `cs=`.
#' @keywords internal
CS_WIRE_VERSION <- "1"

# Packet wrapper --------------------------------------------------------------
# `{` and `}` are plain text in every spreadsheet and never trigger coercion.
# Open decision (milestone 2): `[[ ]]` would avoid Jinja/Mustache expansion in
# templating pipelines.

#' @keywords internal
CS_WRAP_OPEN <- "{{"
#' @keywords internal
CS_WRAP_CLOSE <- "}}"

# Separators ------------------------------------------------------------------
# None of these is a CSV delimiter in any dialect, none triggers Excel
# coercion, and none is a Text-to-Columns default. All are in the reserved set
# below, so they can never appear unescaped inside a token.
# Open decision (milestone 4): the whole set is provisional.

#' @keywords internal
CS_PART_SEP <- "~" # between id, payload, crc
#' @keywords internal
CS_ATTR_SEP <- "^" # between attributes in a payload
#' @keywords internal
CS_ITEM_SEP <- "!" # between list items in a value
#' @keywords internal
CS_KV_SEP <- "=" # between key and value
#' @keywords internal
CS_CODE_SEP <- ":" # between code and label in a level
#' @keywords internal
CS_FRAG_SEP <- "." # between index and fragment number in an id
#' @keywords internal
CS_FRAG_OF <- "of" # between fragment number and fragment total
#' @keywords internal
CS_TOTAL_SEP <- "/" # between index and packet total in an id

# Percent-encoding ------------------------------------------------------------
# Space becomes `+`. Everything outside the unreserved set becomes `%XX` (two
# uppercase hex digits per byte). The unreserved set is deliberately small:
# ASCII letters and digits plus the four punctuation marks that are safe in
# every CSV dialect, never coerced by a spreadsheet mid-token, and wanted for
# readability (`org_type`, `datapackage.json`, `0-9`, `501(c)`).

#' Characters left literal by the token encoder.
#' @keywords internal
CS_UNRESERVED <- c(
  LETTERS, letters, as.character(0:9),
  "_", "-", ".", "(", ")"
)

#' Space sentinel in encoded tokens.
#' @keywords internal
CS_SPACE_PLUS <- "+"

# Packet types ----------------------------------------------------------------

#' @keywords internal
CS_TYPE_SCHEMA <- "S"
#' @keywords internal
CS_TYPE_CANARY <- "C"
#' Reserved, not built: erasure-coded packet type.
#' @keywords internal
CS_TYPE_ERASURE <- "E"

# Added column names ----------------------------------------------------------
# Both begin with `_` and are documented as ignorable; `cs_read_csv()` drops
# them by default. A reader who knows nothing of the package loses nothing but
# two character columns.

#' @keywords internal
CS_SCHEMA_COL <- "_schema"
#' @keywords internal
CS_CANARY_COL <- "_canary"

# Defaults --------------------------------------------------------------------

#' Default maximum packet length in characters, including braces. Chosen to
#' clear a 255-character VARCHAR with room for a reader to add quotes.
#' @keywords internal
CS_DEFAULT_MTU <- 200L

#' Default fraction of rows the redundancy math designs to survive.
#' @keywords internal
CS_DEFAULT_F <- 0.2

#' Default acceptable probability that at least one packet is lost.
#' @keywords internal
CS_DEFAULT_EPS <- 1e-6

#' Default number of purposeful canary samples per variable.
#' @keywords internal
CS_DEFAULT_CANARY_K <- 6L

#' Truncation length for the whole-schema hash (hex characters).
#' @keywords internal
CS_SCHEMA_HASH_LEN <- 12L

#' Truncation length for the sidecar and canary fingerprints (hex characters).
#' @keywords internal
CS_FINGERPRINT_LEN <- 8L

# Regexes ---------------------------------------------------------------------
# The schema/canary columns are located by content, never by header, so a lost
# or regenerated header (V1..Vn) cannot hide them.

#' Locate a packet-bearing column: a cell beginning with `{{S<d>` or `{{C<d>`.
#' Case-insensitive to survive case-folding loaders.
#' @keywords internal
CS_COL_DETECT_RE <- "\\{\\{[SsCc][0-9]"

#' Match (and capture) a single well-formed packet anywhere in a string.
#' Groups: 1 = id, 2 = payload, 3 = crc. The id and payload classes forbid `~`
#' and the braces, so the match cannot cross from one packet into the next when
#' several packets are concatenated in one cell (`{{...}}{{...}}`). Both the id
#' and the payload are free of literal `~`: it is the part separator and is
#' percent-encoded everywhere else.
#' @keywords internal
CS_PACKET_RE <- "\\{\\{([^~{}]+)~([^~{}]*)~([0-9a-fA-F]{8})\\}\\}"

#' Parse the structured id `type index[.frag of nfrag]/total`.
#' Groups: 1 = type, 2 = index, 3 = frag, 4 = nfrag, 5 = total.
#' @keywords internal
CS_ID_RE <- paste0(
  "^([SsCcEe])([0-9]+)",
  "(?:\\.([0-9]+)of([0-9]+))?",
  "/([0-9]+)$"
)

# Schema <-> wire mappings ----------------------------------------------------

#' Frictionless type name -> short wire type code.
#' @keywords internal
CS_TYPE_ABBR <- c(
  string   = "str",
  integer  = "int",
  number   = "num",
  boolean  = "bool",
  date     = "date",
  datetime = "datetime",
  year     = "year"
)

#' Short wire type code -> Frictionless type name.
#' @keywords internal
CS_TYPE_FULL <- stats::setNames(names(CS_TYPE_ABBR), unname(CS_TYPE_ABBR))

#' Canonical order of field attribute keys after the two leading barewords
#' (name, type). The order is fixed so fragmentation and the whole-schema hash
#' are deterministic.
#' @keywords internal
CS_FIELD_KEY_ORDER <- c(
  "fmt", "na", "nalab", "lev", "ord",
  "pat", "uniq", "req", "min", "max", "lab", "desc"
)

#' Default Frictionless `missingValues`: the empty string only. Omitted from
#' the wire when unchanged.
#' @keywords internal
CS_DEFAULT_MISSING <- list("")

#' Default output formats for temporal types.
#' @keywords internal
CS_DATE_FORMAT <- "%Y-%m-%d"
#' @keywords internal
CS_DATETIME_FORMAT <- "%Y-%m-%dT%H:%M:%S"
