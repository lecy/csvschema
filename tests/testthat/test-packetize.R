# Packetize, parse, recover

mk_schema <- function() {
  df <- data.frame(
    ein = c("001234567", "123456789"),
    fiscal_year = c(2019L, 2020L),
    total_revenue = c(1.5, -9),
    org_type = factor(c("Public charity", "Private foundation")),
    size_class = factor(c("small", "large"),
                        levels = c("small", "medium", "large"), ordered = TRUE),
    ruling_date = as.Date(c("2001-03-04", "2010-11-12")),
    stringsAsFactors = FALSE
  )
  cs_schema(df, primary_key = c("ein", "fiscal_year"),
            overrides = list(ein = list(
              constraints = list(pattern = "^[0-9]{9}$", unique = TRUE,
                                 required = TRUE))))
}

test_that("every packet matches the grammar and stays within the MTU", {
  pk <- cs_packetize(mk_schema(), mtu = 200)
  expect_true(all(grepl(CS_PACKET_RE, pk)))
  expect_true(all(nchar(pk) <= 200))
  # a header packet (index 0) is present
  parsed <- cs_parse_packets(pk)
  expect_true(any(parsed$index == 0L))
})

test_that("packetize -> parse -> recover is verified and preserves the schema", {
  s <- mk_schema()
  rec <- cs_recover(cs_parse_packets(cs_packetize(s, mtu = 200)))
  expect_identical(rec$status, "verified")
  expect_identical(.cs_schema_hash(rec$schema), .cs_schema_hash(s))
  expect_identical(vapply(rec$schema$fields, function(f) f$name, character(1)),
                   vapply(s$fields, function(f) f$name, character(1)))
  expect_identical(vapply(rec$schema$fields, function(f) f$type, character(1)),
                   vapply(s$fields, function(f) f$type, character(1)))
  expect_identical(rec$schema$table$primaryKey, c("ein", "fiscal_year"))
  expect_identical(rec$header$fields, 6L)
})

test_that("fragmentation is stable: same hash and recovery across MTUs", {
  big <- data.frame(
    grp = factor(sprintf("category_label_number_%02d", 1:40)),
    stringsAsFactors = FALSE
  )
  s <- cs_schema(big)
  h <- .cs_schema_hash(s)
  for (mtu in c(60, 200, 1000)) {
    pk <- cs_packetize(s, mtu = mtu)
    expect_true(all(nchar(pk) <= mtu),
                info = paste("mtu", mtu, "max", max(nchar(pk))))
    rec <- cs_recover(cs_parse_packets(pk))
    expect_identical(rec$status, "verified")
    expect_identical(.cs_schema_hash(rec$schema), h)
    expect_length(rec$schema$fields[[1]]$categories, 40L)
  }
})

test_that("a token longer than the MTU is a write-time error", {
  long_desc <- paste(rep("z", 400), collapse = "")
  s1 <- cs_schema(data.frame(x = "a", stringsAsFactors = FALSE),
                  overrides = list(x = list(description = long_desc)))
  expect_error(cs_packetize(s1, mtu = 200), "desc")

  long_lab <- paste(rep("q", 400), collapse = "")
  s2 <- cs_schema(data.frame(x = factor(long_lab)))
  expect_error(cs_packetize(s2, mtu = 200), "exceeds the MTU")
})

test_that("recover reports incomplete when the last packet is missing", {
  pk <- cs_packetize(mk_schema(), mtu = 200)
  rec <- cs_recover(cs_parse_packets(pk[-length(pk)]))
  expect_identical(rec$status, "incomplete")
  expect_true(length(rec$missing) >= 1L)
})

test_that("recover reports conflict for two valid payloads at one index", {
  pk <- cs_packetize(mk_schema(), mtu = 200)
  P <- attr(pk, "P")
  rogue <- .cs_make_packet(paste0("S1", CS_TOTAL_SEP, P), "whoops^str")
  rec <- cs_recover(cs_parse_packets(c(pk, rogue)))
  expect_identical(rec$status, "conflict")
})

test_that("recover flags version mixing by whole-schema hash", {
  s1 <- mk_schema()
  s2 <- cs_schema(data.frame(
    ein = "x", fiscal_year = 1L, total_revenue = 1,
    org_type = factor("a"), size_class = factor("b"),
    ruling_date = as.Date("2000-01-01"), stringsAsFactors = FALSE))
  p1 <- cs_packetize(s1, mtu = 200)
  p2 <- cs_packetize(s2, mtu = 200)
  # org_type (index 4) has different levels in the two schemas. Keep s1's
  # header (and its hash) but swap in s2's org_type packet.
  swap_idx <- 4L
  p2_field <- p2[grepl(paste0("\\{\\{S", swap_idx, CS_TOTAL_SEP), p2)]
  p1_kept <- p1[!grepl(paste0("\\{\\{S", swap_idx, CS_TOTAL_SEP), p1)]
  expect_length(p2_field, 1L)
  rec <- cs_recover(cs_parse_packets(c(p1_kept, p2_field)))
  expect_identical(rec$status, "conflict")
  expect_false(isTRUE(rec$hash_ok))
})

test_that("a CRC-broken packet is dropped and counted; duplicates collapse", {
  pk <- cs_packetize(mk_schema(), mtu = 200)
  P <- attr(pk, "P")
  broken <- paste0("{{S1", CS_TOTAL_SEP, P, "~tampered^str~00000000}}")
  rec <- cs_recover(cs_parse_packets(c(pk, broken)))
  expect_identical(rec$status, "verified") # the real S1 is still present
  expect_true(rec$dropped_crc >= 1L)

  rec2 <- cs_recover(cs_parse_packets(c(pk, pk)))
  expect_identical(rec2$status, "verified")
  expect_length(rec2$conflicts, 0L)
})

test_that("round-trips for schemas with 1, 7, and 50 fields", {
  for (nf in c(1L, 7L, 50L)) {
    df <- as.data.frame(
      stats::setNames(
        lapply(seq_len(nf), function(i) {
          switch(((i - 1L) %% 4L) + 1L,
            seq_len(2L),                       # integer
            c(1.5, 2.5),                        # double
            c("a", "b"),                        # character
            factor(c("x", "y")))                # factor
        }),
        paste0("v", seq_len(nf))
      ),
      stringsAsFactors = FALSE
    )
    s <- cs_schema(df)
    rec <- cs_recover(cs_parse_packets(cs_packetize(s, mtu = 200)))
    expect_identical(rec$status, "verified")
    expect_identical(.cs_schema_hash(rec$schema), .cs_schema_hash(s))
  }
})
