# Codec: percent-encoding and CRC-32

test_that("CRC-32 matches the known vector", {
  expect_identical(cs_crc32("123456789"), "cbf43926")
})

test_that("CRC-32 is eight lowercase hex characters", {
  cr <- cs_crc32(c("", "a", "org_type^int"))
  expect_true(all(grepl("^[0-9a-f]{8}$", cr)))
})

test_that("unreserved characters pass through literally", {
  x <- c("org_type", "datapackage.json", "0-9", "501(c)", "ein")
  expect_identical(cs_encode_token(x), x)
})

test_that("separators, wrapper, percent and plus are escaped", {
  expect_identical(cs_encode_token("~"), "%7E")
  expect_identical(cs_encode_token("^"), "%5E")
  expect_identical(cs_encode_token("!"), "%21")
  expect_identical(cs_encode_token("="), "%3D")
  expect_identical(cs_encode_token(":"), "%3A")
  expect_identical(cs_encode_token("%"), "%25")
  expect_identical(cs_encode_token("{"), "%7B")
  expect_identical(cs_encode_token("}"), "%7D")
  expect_identical(cs_encode_token("+"), "%2B")
})

test_that("space becomes plus", {
  expect_identical(cs_encode_token("Public charity"), "Public+charity")
})

test_that("regex metacharacters are encoded as in the spec example", {
  # ^[0-9]{9}$  ->  %5E%5B0-9%5D%7B9%7D%24
  expect_identical(cs_encode_token("^[0-9]{9}$"), "%5E%5B0-9%5D%7B9%7D%24")
})

test_that("non-ASCII is encoded as UTF-8 bytes", {
  expect_identical(cs_encode_token("Café"), "Caf%C3%A9")
  expect_identical(cs_encode_token("€"), "%E2%82%AC") # euro sign
})

test_that("an encoded token uses only safe characters", {
  x <- c("Café Société", "=SUM(A1)", "a,b;c\td|e\"f'g", " x ")
  enc <- cs_encode_token(x)
  # Only unreserved chars, the '+' space marker, and '%' escapes may appear.
  expect_true(all(grepl("^[A-Za-z0-9_.()+%-]*$", enc)))
  # None of the CSV delimiters, quotes, whitespace, separators, or wrapper.
  expect_false(any(grepl("[,;\t|\"'{}~^!=: ]", enc)))
})

test_that("encode/decode round-trips every byte 0-255", {
  # build strings from each byte that can stand alone
  for (b in 0:255) {
    if (b == 0L) next # NUL cannot live in an R string
    s <- rawToChar(as.raw(b))
    Encoding(s) <- "UTF-8"
    expect_identical(cs_decode_token(cs_encode_token(s)), s)
  }
})

test_that("encode/decode round-trips reserved separators and mixed strings", {
  x <- c("~", "^", "!", "=", ":", "%", "+", "{", "}", " ",
         "a~b^c!d=e:f%g+h", "Café Société", "=SUM(A1)",
         "00123", "1.23E+15", "-9", "SEPT1")
  expect_identical(cs_decode_token(cs_encode_token(x)), x)
})

test_that("NA maps to NA in both directions", {
  expect_true(is.na(cs_encode_token(NA_character_)))
  expect_true(is.na(cs_decode_token(NA_character_)))
})
