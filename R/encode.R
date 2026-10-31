# encode.R ------------------------------------------------------------------
#
# The only place in the package that touches percent-encoding and checksums.
# Tokens are encoded to a pure-ASCII, separator-safe form; the CRC and the
# whole-schema hash are computed over those ASCII bytes so no encoding
# conversion downstream can alter them.

# Byte value of every unreserved character (all ASCII, single byte).
.cs_unreserved_bytes <- function() {
  utf8ToInt(paste(CS_UNRESERVED, collapse = ""))
}

.cs_encode_one <- function(s) {
  if (is.na(s)) return(NA_character_)
  bytes <- as.integer(charToRaw(enc2utf8(as.character(s))))
  unreserved <- .cs_unreserved_bytes()
  pieces <- vapply(bytes, function(b) {
    if (b == 32L) return(CS_SPACE_PLUS)       # space -> '+'
    if (b %in% unreserved) return(intToUtf8(b))
    sprintf("%%%02X", b)                        # everything else -> %XX
  }, character(1))
  paste(pieces, collapse = "")
}

.cs_decode_one <- function(s) {
  if (is.na(s)) return(NA_character_)
  s <- gsub("+", " ", s, fixed = TRUE)          # '+' -> space
  b <- as.integer(charToRaw(s))
  n <- length(b)
  out <- integer(n)
  j <- 0L
  i <- 1L
  while (i <= n) {
    if (b[i] == 37L && i + 2L <= n) {           # '%'
      val <- strtoi(paste0(intToUtf8(b[i + 1L]), intToUtf8(b[i + 2L])), 16L)
      j <- j + 1L
      out[j] <- val
      i <- i + 3L
    } else {
      j <- j + 1L
      out[j] <- b[i]
      i <- i + 1L
    }
  }
  res <- rawToChar(as.raw(out[seq_len(j)]))
  Encoding(res) <- "UTF-8"
  res
}

#' Percent-encode a token
#'
#' Encodes each string to the package's pure-ASCII token form: every character
#' outside the unreserved set (`A-Z a-z 0-9 _ - . ( )`) becomes a `%XX` escape
#' and spaces become `+`. The result contains no CSV delimiter, no quote, no
#' whitespace, and no separator or wrapper character, so it is always a single
#' unquoted CSV token.
#'
#' @param x A character vector.
#' @return A character vector of encoded tokens, same length as `x`. `NA` maps
#'   to `NA`.
#' @seealso [cs_decode_token()]
#' @examples
#' cs_encode_token("Public charity")
#' cs_encode_token("Café")
#' @export
cs_encode_token <- function(x) {
  vapply(x, .cs_encode_one, character(1), USE.NAMES = FALSE)
}

#' Percent-decode a token
#'
#' Inverse of [cs_encode_token()]: `+` becomes a space and each `%XX` escape
#' becomes its byte, with the result interpreted as UTF-8. Decode only after a
#' packet's CRC check has passed.
#'
#' @param x A character vector of encoded tokens.
#' @return A character vector of decoded strings, same length as `x`.
#' @seealso [cs_encode_token()]
#' @examples
#' cs_decode_token("Public+charity")
#' cs_decode_token(cs_encode_token("Café"))
#' @export
cs_decode_token <- function(x) {
  vapply(x, .cs_decode_one, character(1), USE.NAMES = FALSE)
}

#' CRC-32 of a string as eight lowercase hex digits
#'
#' Computed over the raw bytes of the input. Packets carry this over
#' `id~payload` so that any edit, truncation, or case fold turns silent
#' corruption into a detected, droppable error.
#'
#' @param x A character vector.
#' @return A character vector of 8-character lowercase hex strings.
#' @examples
#' cs_crc32("123456789") # cbf43926
#' @export
cs_crc32 <- function(x) {
  vapply(
    x,
    function(s) digest::digest(s, algo = "crc32", serialize = FALSE),
    character(1),
    USE.NAMES = FALSE
  )
}

# SHA-1 over UTF-8 bytes; truncated by callers for the schema hash and
# fingerprints. Internal.
.cs_sha1 <- function(x, len = NULL) {
  h <- digest::digest(enc2utf8(x), algo = "sha1", serialize = FALSE)
  if (is.null(len)) h else substr(h, 1L, len)
}
