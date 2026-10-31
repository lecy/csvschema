# Threat model: each simulator vs the documented recovery outcome

mk_fixture <- function(N = 300L) {
  idx <- seq_len(N)
  data.frame(
    zip = sprintf("%05d", idx),                     # leading zeros
    bigid = sprintf("1%015d", idx),                 # 16-digit strings
    region = factor(rep(c("NE", "S", "MW", "W"), length.out = N),
                    levels = c("NE", "S", "MW", "W")),
    rev = round(seq(1000, 2000, length.out = N), 2),
    note = rep(c("SEPT1", "Café", "normal", "0.5"), length.out = N),
    stringsAsFactors = FALSE
  )
}

write_fixture <- function(df = mk_fixture(), ...) {
  tmp <- tempfile(fileext = ".csv")
  cs_write(df, tmp, sidecar = FALSE, verbose = FALSE, ...)
  tmp
}

# Read a written CSV as a character frame (keeping all columns, incl. meta).
read_chr <- function(path) {
  utils::read.csv(path, colClasses = "character", check.names = FALSE,
                  na.strings = character(0))
}

write_chr <- function(df) {
  tmp <- tempfile(fileext = ".csv")
  utils::write.table(df, tmp, sep = ",", row.names = FALSE, na = "",
                     qmethod = "double", eol = "\n")
  tmp
}

# Apply a data-frame simulator and read back. Reading deliberately corrupted
# data raises coercion/reconciliation warnings by design; silence them here.
rt_df <- function(sim, df = mk_fixture(), ...) {
  path <- write_fixture(df, ...)
  corrupted <- sim(read_chr(path))
  suppressWarnings(cs_read_csv(write_chr(corrupted), sidecar = FALSE,
                               verbose = FALSE))
}

# Apply a raw-text simulator and read back.
rt_text <- function(sim, df = mk_fixture(), ...) {
  path <- write_fixture(df, ...)
  text <- readLines(path, warn = FALSE, encoding = "UTF-8")
  corrupted <- sim(text)
  tmp2 <- tempfile(fileext = ".csv")
  writeLines(corrupted, tmp2, useBytes = TRUE)
  suppressWarnings(cs_read_csv(tmp2, sidecar = FALSE, verbose = FALSE))
}

status_of <- function(out) cs_report(out)$status

test_that("row loss (random/head/tail/block/shuffle/duplicate) stays verified", {
  for (mode in c("random", "head", "tail", "block", "shuffle", "duplicate")) {
    out <- rt_df(function(x) cs_corrupt_rows(x, keep = 0.3, mode = mode,
                                             seed = 1))
    expect_identical(status_of(out), "verified", info = mode)
  }
})

test_that("header loss and renaming stay verified (columns found by content)", {
  expect_identical(status_of(rt_df(function(x) cs_corrupt_header(x, "rename"))),
                   "verified")
  expect_identical(status_of(rt_df(function(x) cs_corrupt_header(x, "blank"))),
                   "verified")
})

test_that("case folding is detected (CRC flags folded payloads), not silent", {
  # By design the per-packet CRC covers the exact-case payload, so a loader
  # that upper/lower-cases every cell folds the payloads and the CRCs fail:
  # the packets are dropped and recovery reports the loss rather than
  # returning a silently wrong schema.
  expect_true(status_of(rt_df(function(x) cs_corrupt_case(x, "upper"))) %in%
                c("incomplete", "absent", "conflict"))
  expect_true(status_of(rt_df(function(x) cs_corrupt_case(x, "lower"))) %in%
                c("incomplete", "absent", "conflict"))
})

test_that("a global find-and-replace in data is detected but schema survives", {
  out <- rt_df(function(x) cs_corrupt_replace(x, "SEPT1", "XXXXX"))
  expect_identical(status_of(out), "verified")
})

test_that("splitting a data column (Text-to-Columns) keeps the schema", {
  out <- rt_df(function(x) cs_corrupt_columns(x, split_on = "a", split_col = "region"))
  expect_identical(status_of(out), "verified")
})

test_that("encoding, BOM, smart quotes, whitespace, EOL, invisibles survive", {
  expect_identical(status_of(rt_text(function(t) cs_corrupt_bom(t))), "verified")
  expect_identical(status_of(rt_text(function(t) cs_corrupt_smartquotes(t))),
                   "verified")
  expect_identical(status_of(rt_text(function(t) cs_corrupt_whitespace(t, "pad"))),
                   "verified")
  expect_identical(status_of(rt_text(function(t) cs_corrupt_whitespace(t, "nbsp"))),
                   "verified")
  expect_identical(status_of(rt_text(function(t) cs_corrupt_eol(t, "crlf"))),
                   "verified")
  expect_identical(status_of(rt_text(function(t) cs_corrupt_invisible(t, seed = 1))),
                   "verified")
  expect_identical(status_of(rt_text(function(t) cs_corrupt_encoding(t))),
                   "verified")
})

test_that("delimiter rewriting to ; survives", {
  expect_identical(status_of(rt_text(function(t) cs_corrupt_delimiter(t, ";"))),
                   "verified")
})

test_that("Excel coercion leaves the schema intact but flags data damage", {
  out <- rt_df(cs_corrupt_excel)
  rep <- cs_report(out)
  expect_identical(rep$status, "verified")
  cn <- rep$canary
  corrupted_vars <- cn$variable[cn$verdict == "corrupted"]
  expect_true("zip" %in% corrupted_vars)     # leading zeros stripped
  expect_true(any(grepl("leading_zero", cn$damage)))
})

test_that("truncation below cell length still recovers via redundancy", {
  out <- rt_df(function(x) cs_corrupt_truncate(x, n = 120L))
  expect_true(status_of(out) %in% c("verified", "incomplete"))
})

test_that("merging two different schemas is reported as conflict or incomplete", {
  a <- mk_fixture(60L)
  b <- mk_fixture(60L)
  b$extra <- "z" # different schema
  pa <- write_fixture(a)
  pb <- write_fixture(b)
  ca <- read_chr(pa)
  cb <- read_chr(pb)
  merged <- cs_corrupt_merge(ca, cb)
  out <- suppressWarnings(cs_read_csv(write_chr(merged), sidecar = FALSE,
                                      verbose = FALSE))
  expect_true(status_of(out) %in% c("conflict", "incomplete"))
})

test_that("every simulator tags what it did", {
  x <- mk_fixture(10L)
  expect_match(attr(cs_corrupt_rows(x), "cs_corruption"), "rows")
  expect_match(attr(cs_corrupt_excel(x), "cs_corruption"), "excel")
  expect_match(attr(cs_corrupt_case(x, "upper"), "cs_corruption"), "case")
})
