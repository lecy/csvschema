# Layout: copies, redundancy, survival, stripe

test_that("cs_copies matches the worked table exactly", {
  # P = 20, eps = 1e-6
  expect_identical(cs_copies(20, 0.50), 25L)
  expect_identical(cs_copies(20, 0.20), 76L)
  expect_identical(cs_copies(20, 0.10), 160L)
  expect_identical(cs_copies(20, 0.05), 328L)
  expect_identical(cs_copies(20, 0.01), 1673L)
})

test_that("cs_copies rejects degenerate f", {
  expect_error(cs_copies(20, 0))
  expect_error(cs_copies(20, 1))
})

test_that("cs_redundancy prefers p, then c, and meets the required copies", {
  # Large N: one copy per packet per block is plenty -> c = 1, p = 1.
  r1 <- cs_redundancy(20, 2000, f = 0.2, packet_len = 50)
  expect_identical(r1$c, 1L)
  expect_identical(r1$p, 1L)
  expect_true(r1$r_eff >= r1$r)

  # Small N forces more slots; p is raised within the MTU before c.
  r2 <- cs_redundancy(20, 100, f = 0.2, packet_len = 50, mtu = 200)
  expect_true(r2$p >= 1L && r2$p <= 4L)
  expect_true(r2$p * r2$c * 100 / 20 >= r2$r)
})

test_that("cs_survival agrees with a Monte Carlo of random retention", {
  set.seed(1)
  P <- 8L; N <- 400L; c <- 1L; p <- 1L; f <- 0.2
  predicted <- cs_survival(P, N, c, p, f)
  st <- cs_stripe(P, N, c, p)
  trials <- 10000L
  fails <- 0L
  for (t in seq_len(trials)) {
    keep <- which(stats::runif(N) < f)
    present <- unique(unlist(st[keep, , drop = FALSE]))
    if (length(present) < P) fails <- fails + 1L
  }
  empirical <- fails / trials
  # Both are small; agree within a few standard errors.
  se <- sqrt(max(empirical, 1e-4) * (1 - empirical) / trials)
  expect_lt(abs(empirical - predicted), 5 * se + 0.01)
})

test_that("stripe: first P rows and any 2P-1 window cover every index", {
  for (P in 2:8) {
    for (N in c(P, 2 * P, 3 * P + 1)) {
      st <- cs_stripe(P, N, 1L, 1L)
      idx <- function(rows) unique(unlist(st[rows, , drop = FALSE]))
      # head()/prefix: first P rows
      expect_setequal(idx(seq_len(P)), 0:(P - 1))
      # any 2P-1 consecutive rows, where they fit
      if (N >= 2 * P - 1) {
        for (start in seq_len(N - (2 * P - 1) + 1)) {
          win <- start:(start + 2 * P - 2)
          expect_setequal(idx(win), 0:(P - 1))
        }
      }
      # full-file coverage
      expect_setequal(idx(seq_len(N)), 0:(P - 1))
    }
  }
})

test_that("stripe: every-P-th-row systematic sample cycles through all indices", {
  for (P in 2:8) {
    N <- P * P
    st <- cs_stripe(P, N, 1L, 1L)
    rows <- seq(1L, N, by = P)
    present <- unique(unlist(st[rows, , drop = FALSE]))
    expect_setequal(present, 0:(P - 1))
  }
})

test_that("stripe is deterministic and reproducible", {
  expect_identical(cs_stripe(5, 23, 2L, 3L), cs_stripe(5, 23, 2L, 3L))
})

test_that("columns carry different parts of the schema; cells carry p indices", {
  P <- 8L
  st <- cs_stripe(P, 4L, c = 2L, p = 3L)
  # p = 3 consecutive indices per cell
  expect_length(st[[1, 1]], 3L)
  expect_identical(st[[1, 1]], as.integer((0:2) %% P))
  # column 2 is offset by floor(P/2) = 4 from column 1
  expect_identical(st[[1, 2]][1], (st[[1, 1]][1] + 4L) %% P)
})

test_that("cs_lay places packets and the result parses back to them", {
  s <- cs_schema(data.frame(a = 1:3, b = factor(c("x", "y", "x")),
                            stringsAsFactors = FALSE))
  pk <- cs_packetize(s, mtu = 200)
  cols <- cs_lay(pk, N = 30L, c = 1L, p = 1L)
  expect_identical(dim(cols), c(30L, 1L))
  rec <- cs_recover(cs_parse_packets(cols[, 1]))
  expect_identical(rec$status, "verified")
  expect_identical(.cs_schema_hash(rec$schema), .cs_schema_hash(s))
})
