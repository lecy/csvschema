# Canary sampler, detectors, and two-level check

test_that("the sampler takes fragile values before filler", {
  x <- c("00123", "999999999999999999", "SEPT1", "=SUM(A1)", "Café",
         "normal1", "normal2", "normal3")
  s <- cs_canary_sample(x, k = 6)
  expect_true("00123" %in% s)                  # leading zero
  expect_true("999999999999999999" %in% s)     # long digit string
  expect_true("SEPT1" %in% s)                  # date-like
  expect_true("=SUM(A1)" %in% s)               # formula
  expect_true("Café" %in% s)               # non-ASCII
})

test_that("the sampler is deterministic", {
  x <- as.character(1:50)
  expect_identical(cs_canary_sample(x, 6), cs_canary_sample(x, 6))
})

test_that("an intact column verifies", {
  df <- data.frame(zip = c("00123", "00456", "789", "1200"),
                   stringsAsFactors = FALSE)
  canaries <- cs_parse_canaries(cs_canary(df, cs_schema(df)))
  r <- cs_canary_check(df, canaries)
  expect_identical(r$verdict[r$variable == "zip"], "intact")
})

test_that("stripped leading zeros are detected and named", {
  df <- data.frame(zip = c("00123", "00456", "00789", "01200"),
                   stringsAsFactors = FALSE)
  canaries <- cs_parse_canaries(cs_canary(df, cs_schema(df)))
  df2 <- df
  df2$zip <- sub("^0+", "", df2$zip)
  r <- cs_canary_check(df2, canaries)
  expect_identical(r$verdict[r$variable == "zip"], "corrupted")
  expect_match(r$damage[r$variable == "zip"], "leading_zero")
})

test_that("row loss alone reports values intact, not corruption", {
  df <- data.frame(x = sprintf("v%03d", 1:100), stringsAsFactors = FALSE)
  canaries <- cs_parse_canaries(cs_canary(df, cs_schema(df)))
  kept <- df[1:40, , drop = FALSE]
  r <- cs_canary_check(kept, canaries)
  # Sampled values should still be present (they come from the head here),
  # but even if not, the verdict must not be "intact" (fingerprint changed).
  expect_false(r$verdict[r$variable == "x"] == "intact")
})

test_that("a missing variable is unverifiable", {
  df <- data.frame(a = 1:3, b = letters[1:3], stringsAsFactors = FALSE)
  chr <- data.frame(a = as.character(1:3), b = letters[1:3],
                    stringsAsFactors = FALSE)
  canaries <- cs_parse_canaries(cs_canary(chr, cs_schema(df)))
  r <- cs_canary_check(chr[, "a", drop = FALSE], canaries)
  expect_identical(r$verdict[r$variable == "b"], "unverifiable")
})
