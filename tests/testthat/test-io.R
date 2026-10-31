# End-to-end write/read

expect_col_equal <- function(a, b, nm) {
  if (is.character(a) || is.character(b)) {
    expect_equal(enc2utf8(as.character(a)), enc2utf8(as.character(b)),
                 info = nm)
  } else if (is.factor(a) || is.factor(b)) {
    expect_identical(as.character(a), as.character(b), info = nm)
    expect_identical(levels(a), levels(b), info = nm)
    expect_identical(is.ordered(a), is.ordered(b), info = nm)
  } else {
    expect_equal(a, b, info = nm)
  }
}

test_that("a data frame round-trips through cs_write and cs_read_csv", {
  df <- data.frame(
    id = 1:6,
    amount = c(1.5, 2.25, NA, 4.0, -9, 100000),
    flag = c(TRUE, FALSE, NA, TRUE, FALSE, TRUE),
    grp = factor(c("a", "b", "a", "c", "b", "a")),
    size = factor(c("lo", "hi", "lo", "hi", "lo", "hi"),
                  levels = c("lo", "mid", "hi"), ordered = TRUE),
    when = as.Date(c("2001-01-01", "2002-02-02", NA, "2004-04-04",
                     "2005-05-05", "2006-06-06")),
    # NA (not "") here: with default missingValues = [""], an empty cell is
    # read back as NA, so "" and NA are indistinguishable once written.
    name = c("x", "Café", "a,b", "with\"quote", NA, "tab\tchar"),
    stringsAsFactors = FALSE
  )
  tmp <- tempfile(fileext = ".csv")
  cs_write(df, tmp, sidecar = FALSE, verbose = FALSE)
  out <- cs_read_csv(tmp, verbose = FALSE)

  rep <- cs_report(out)
  expect_identical(rep$status, "verified")
  expect_identical(names(out), names(df))
  for (nm in names(df)) expect_col_equal(out[[nm]], df[[nm]], nm)
})

test_that("the states fixture round-trips and canaries are intact", {
  tmp <- tempfile(fileext = ".csv")
  cs_write(dg_states, tmp, sidecar = FALSE, verbose = FALSE)
  out <- cs_read_csv(tmp, verbose = FALSE)
  rep <- cs_report(out)
  expect_identical(rep$status, "verified")
  expect_true(all(rep$canary$verdict %in% c("intact", "rows changed, values intact")))
  expect_identical(names(out), names(dg_states))
  for (nm in names(dg_states)) expect_col_equal(out[[nm]], dg_states[[nm]], nm)
})

test_that("a sidecar is written and reconciled on read", {
  tmp <- tempfile(fileext = ".csv")
  s <- cs_write(dg_states, tmp, sidecar = TRUE, verbose = FALSE)
  side <- file.path(dirname(tmp), "datapackage.json")
  expect_true(file.exists(side))
  js <- jsonlite::fromJSON(side, simplifyVector = FALSE)
  expect_identical(js$resources[[1]]$csvschema$schema_hash, .cs_schema_hash(s))
  expect_true(grepl("^sha1:", js$resources[[1]]$hash))

  out <- cs_read_csv(tmp, verbose = FALSE, verify_file = TRUE)
  rep <- cs_report(out)
  expect_identical(rep$status, "verified")
  expect_true(isTRUE(rep$file_hash_ok))
  unlink(side)
})

test_that("keep_meta retains the packet columns", {
  tmp <- tempfile(fileext = ".csv")
  cs_write(data.frame(a = 1:5, b = letters[1:5], stringsAsFactors = FALSE),
           tmp, sidecar = FALSE, verbose = FALSE)
  out <- cs_read_csv(tmp, keep_meta = TRUE, verbose = FALSE)
  expect_true(CS_SCHEMA_COL %in% names(out))
  expect_true(CS_CANARY_COL %in% names(out))
})

test_that("a file with the schema column deleted reads as character, absent", {
  tmp <- tempfile(fileext = ".csv")
  cs_write(data.frame(a = 1:5, b = factor(letters[1:5]), stringsAsFactors = FALSE),
           tmp, sidecar = FALSE, verbose = FALSE)
  raw <- utils::read.csv(tmp, colClasses = "character", check.names = FALSE)
  meta <- grep("^_", names(raw), value = TRUE)
  plain <- raw[, setdiff(names(raw), meta), drop = FALSE]
  tmp2 <- tempfile(fileext = ".csv")
  utils::write.csv(plain, tmp2, row.names = FALSE)
  out <- cs_read_csv(tmp2, sidecar = FALSE, verbose = FALSE)
  rep <- cs_report(out)
  expect_identical(rep$status, "absent")
  expect_true(all(vapply(out, is.character, logical(1))))
})

test_that("cs_read_csv without apply returns character columns", {
  tmp <- tempfile(fileext = ".csv")
  cs_write(data.frame(a = 1:5, b = 1.5 * (1:5)), tmp, sidecar = FALSE,
           verbose = FALSE)
  out <- cs_read_csv(tmp, apply = FALSE, verbose = FALSE)
  expect_true(all(vapply(out, is.character, logical(1))))
})
