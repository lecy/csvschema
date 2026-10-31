# layout.R ------------------------------------------------------------------
#
# How many copies of each packet, and where they go. Repetition coding sized by
# a coupon-collector bound, then a deterministic rotating stripe so that
# structured row loss (a head(), a page, a systematic every-k-th sample) still
# leaves a full set of packets behind.

#' Minimum copies per packet
#'
#' The union-bound solution to the repetition-coding design constraint
#' \eqn{P(1-f)^r \le \varepsilon}: the smallest number of copies `r` of each of
#' `P` packets so that, when only a fraction `f` of rows is retained at random,
#' the probability that any packet is lost is at most `eps`.
#'
#' @param P Number of distinct packets.
#' @param f Fraction of rows retained.
#' @param eps Acceptable probability that at least one packet is lost.
#' @return An integer, the minimum copies per packet.
#' @examples
#' cs_copies(20, f = 0.2) # 76
#' @export
cs_copies <- function(P, f, eps = CS_DEFAULT_EPS) {
  if (f <= 0 || f >= 1) stop("`f` must be in (0, 1).", call. = FALSE)
  r <- ceiling(log(P / eps) / -log(1 - f))
  as.integer(max(r, 1L))
}

#' Achieved failure probability for a layout
#'
#' The probability that at least one packet is lost under independent random
#' row retention, given \eqn{r = pcN/P} copies of each of `P` packets:
#' \eqn{1 - (1 - (1-f)^r)^P}.
#'
#' @param P Number of distinct packets.
#' @param N Number of rows.
#' @param c Number of schema columns.
#' @param p Packets per cell.
#' @param f Fraction of rows retained.
#' @return The failure probability (a scalar between 0 and 1).
#' @examples
#' cs_survival(20, 2000, c = 1, p = 1, f = 0.2)
#' @export
cs_survival <- function(P, N, c = 1L, p = 1L, f = CS_DEFAULT_F) {
  r_eff <- p * c * N / P
  pr_all <- (1 - (1 - f)^r_eff)^P
  1 - pr_all
}

.cs_survival_sentence <- function(P, N, c, p, f) {
  fp <- cs_survival(P, N, c, p, f)
  sprintf("survives random loss of %.0f%% of rows with failure probability %.1e",
          (1 - f) * 100, fp)
}

#' Choose a redundancy layout
#'
#' Picks the smallest `(c, p)` whose copies-per-packet `pcN/P` meets the
#' required `r` from [cs_copies()], subject to `p` times the packet length not
#' exceeding the MTU, preferring extra packets-per-cell (`p`, invisible) over
#' extra columns (`c`).
#'
#' @param P Number of distinct packets.
#' @param N Number of rows.
#' @param f Fraction of rows the layout is designed to survive.
#' @param eps Acceptable packet-loss probability.
#' @param mtu Maximum packet length (bounds `p`).
#' @param packet_len Representative packet length; defaults to `mtu`.
#' @return A list with `c`, `p`, `r` (required copies), `r_eff` (achieved
#'   copies), `achieved_eps` (failure probability), and a human-readable
#'   `sentence`.
#' @examples
#' cs_redundancy(20, 2000, f = 0.2, packet_len = 50)
#' @export
cs_redundancy <- function(P, N, f = CS_DEFAULT_F, eps = CS_DEFAULT_EPS,
                          mtu = CS_DEFAULT_MTU, packet_len = NULL) {
  if (N < 1) stop("`N` must be at least 1.", call. = FALSE)
  r <- cs_copies(P, f, eps)
  if (is.null(packet_len)) packet_len <- mtu
  p_max <- max(1L, as.integer(floor(mtu / max(packet_len, 1))))
  prod_min <- r * P / N                       # need p * c >= prod_min
  p <- min(p_max, max(1L, as.integer(ceiling(prod_min))))
  c <- max(1L, as.integer(ceiling(prod_min / p)))
  r_eff <- p * c * N / P
  list(
    c = c, p = p, r = r, r_eff = r_eff,
    achieved_eps = cs_survival(P, N, c, p, f),
    sentence = .cs_survival_sentence(P, N, c, p, f)
  )
}

#' Rotating stripe assignment
#'
#' Returns, for each row and schema column, the vector of packet indices
#' (0-based) that cell carries. Pure arithmetic, no randomness, so it is
#' reproducible and testable. Row `i` (0-based) in block `b = floor(i / P)`
#' carries base index `(i + b + offset_j) mod P`, where `offset_j =
#' floor(j * P / c)` spreads columns across the schema; a cell carries `p`
#' consecutive indices from its base.
#'
#' Guarantees (verified by tests): the first `P` rows contain every index (so
#' `head()` and any block-aligned window recover); any `2P - 1` consecutive
#' rows contain every index; every index appears across the whole file; and the
#' systematic every-`P`-th-row sample cycles through all indices. A general
#' arithmetic stride is not guaranteed in its first `P` terms (that cannot hold
#' simultaneously with the contiguous guarantee); heavy arbitrary strides are
#' covered by the redundancy `r`, not by the stripe.
#'
#' @param P Number of distinct packets.
#' @param N Number of rows.
#' @param c Number of schema columns.
#' @param p Packets per cell.
#' @return An `N` x `c` list-matrix; each element is an integer vector of `p`
#'   packet indices.
#' @examples
#' cs_stripe(4, 8, c = 1, p = 1)
#' @export
cs_stripe <- function(P, N, c = 1L, p = 1L) {
  st <- vector("list", N * c)
  dim(st) <- c(N, c)
  offsets <- floor((seq_len(c) - 1L) * P / c)
  for (i in seq_len(N)) {
    i0 <- i - 1L
    b <- i0 %/% P
    for (j in seq_len(c)) {
      base <- (i0 + b + offsets[j]) %% P
      st[[i, j]] <- as.integer((base + (seq_len(p) - 1L)) %% P)
    }
  }
  st
}

#' Materialize a stripe into schema columns
#'
#' Places packet strings into an `N` x `c` character matrix according to
#' [cs_stripe()]. Each cell holds the concatenation of the `p` packets assigned
#' to it; packets are brace-delimited, so concatenation stays parseable.
#'
#' @param packets A character vector of packets (as from [cs_packetize()] or a
#'   canary packet set).
#' @param N Number of rows.
#' @param c Number of columns.
#' @param p Packets per cell.
#' @return An `N` x `c` character matrix.
#' @export
cs_lay <- function(packets, N, c = 1L, p = 1L) {
  P <- length(packets)
  st <- cs_stripe(P, N, c, p)
  out <- matrix("", nrow = N, ncol = c)
  for (j in seq_len(c)) {
    for (i in seq_len(N)) {
      out[i, j] <- paste0(packets[st[[i, j]] + 1L], collapse = "")
    }
  }
  out
}
