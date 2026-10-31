#' US state facts (test fixture)
#'
#' A 50-row table of United States state facts, used throughout the examples
#' and tests because its columns exercise every supported column class: a
#' character key (`state`), an unordered factor (`region`), logicals
#' (`south`, `west`), an integer (`motto_year`), several doubles, free text
#' with non-ASCII characters (`motto`, e.g. the Greek in California's motto),
#' and missing values (`motto_english`). Derived from the `datagoodr` package.
#'
#' @format A data frame with 50 rows and 16 variables:
#' \describe{
#'   \item{state}{State name (character).}
#'   \item{region}{Census region (factor: Northeast, South, North Central, West).}
#'   \item{south}{Whether the state is in the South (logical).}
#'   \item{west}{Whether the state is in the West (logical).}
#'   \item{population}{Population in thousands, 1975 (numeric).}
#'   \item{income}{Per-capita income, 1974 (numeric).}
#'   \item{illiteracy}{Illiteracy percent, 1970 (numeric).}
#'   \item{life_exp}{Life expectancy in years, 1969-71 (numeric).}
#'   \item{murder}{Murder rate per 100,000, 1976 (numeric).}
#'   \item{hs_grad}{High-school graduation percent, 1970 (numeric).}
#'   \item{frost}{Mean days below freezing, 1931-60 (numeric).}
#'   \item{area}{Land area in square miles (numeric).}
#'   \item{motto}{State motto, original language (character, non-ASCII).}
#'   \item{motto_english}{English translation of the motto (character, has NAs).}
#'   \item{motto_year}{Year the motto was adopted (integer).}
#'   \item{id}{A 32-character hexadecimal identifier (character).}
#' }
#' @source The \pkg{datagoodr} package.
"dg_states"
