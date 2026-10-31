# csvschema

<!-- badges: start -->
[![R-CMD-check](https://github.com/lecy/csvschema/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/lecy/csvschema/actions/workflows/R-CMD-check.yaml)
<!-- badges: end -->

**Self-describing CSV files with embedded, loss-tolerant schemas.**

`csvschema` writes and reads CSV files that carry their own schema *inside
ordinary data columns*, so the file opens as a plain CSV in every tool and the
schema survives sorting, filtering, row loss, encoding changes, and spreadsheet
round-trips. The name is the joke: the file looks schemaless and is not.

It does four things:

1. **Packetize** a table schema (field names, types, formats, missing codes,
   factor levels, keys) into short ASCII tokens and spread redundant copies
   through one or more `_schema` columns.
2. **Recover** the schema from any surviving subset of rows, verify it, and
   apply it (types, factors, NA codes) on read.
3. **Canary** the data: store a purposeful sample of fragile values per
   variable in a `_canary` column and report, after a round-trip, whether each
   variable is still intact and, if not, *how* it was damaged.
4. **Point** to an optional Frictionless `datapackage.json` sidecar and
   cross-check hashes in both directions.

The schema is encoded the way the internet survives a hostile channel: every
packet is one unquoted, pure-ASCII token (`{{S1/8~ein^str^uniq^req~c41d9a02}}`)
with its own index, total, and CRC-32, plus a whole-schema hash, spread
redundantly so it survives heavy row loss.

## Installation

```r
# install.packages("remotes")
remotes::install_github("lecy/csvschema")
```

## Quick start

```r
library(csvschema)

path <- tempfile(fileext = ".csv")

# Write a self-describing CSV (dg_states ships with the package).
cs_write(dg_states, path)
#> csvschema: 18 packets, c=6, p=5; survives random loss of 80% of rows ...
# (50 rows need more copies to survive 80% loss; a 2,000-row table needs c=1, p=1.)

# The file is a perfectly ordinary CSV with two extra character columns.
# Read it back: the schema is recovered and applied automatically.
out <- cs_read_csv(path)
#> csvschema: schema verified (inband); 16/16 variables intact

str(out[, c("region", "south", "motto_year")])
#> 'data.frame':  50 obs. of  3 variables:
#>  $ region    : Factor w/ 4 levels "Northeast","South",..
#>  $ south     : logi  TRUE FALSE FALSE TRUE ...
#>  $ motto_year: int  1923 1967 1863 1907 ...
```

`region` comes back as the original factor, `south` as logical, `motto_year`
as integer — none of which a plain `read.csv()` would restore.

## Surviving damage

The schema survives losing most of the rows, because each packet is repeated
and striped across the file:

```r
few <- read.csv(path)[sample(50, 10), ]          # keep 10 of 50 rows
tmp <- tempfile(fileext = ".csv"); write.csv(few, tmp, row.names = FALSE)
cs_read_csv(tmp)
#> csvschema: schema verified (inband); ...
```

The `cs_corrupt_*()` family simulates every vector in the threat model, so you
can test your own pipeline:

```r
out <- cs_read_csv(path)
rep <- cs_report(out)       # the recovery + canary report
rep$status                  # "verified"
rep$canary                  # per-variable: verdict and named damage
```

## How much redundancy?

```r
cs_copies(20, f = 0.2)                 # 76 copies to survive 80% row loss
cs_redundancy(20, 2000, f = 0.2)$sentence
#> "survives random loss of 80% of rows with failure probability ..."
```

## What it does not do

* **Delete every `_schema` column** and the in-band schema is gone; use the
  sidecar (`cs_write(..., sidecar = TRUE)`), which is independent.
* **Case-folding every cell** (some mainframe/SQL loaders) is *detected, not
  recovered*: the per-packet CRC covers the exact-case payload, so folded
  payloads fail their check and are dropped. Recovery reports the loss rather
  than returning a silently wrong schema.
* **Numeric precision and `NA` vs `""`**: doubles are written at R's default
  precision, and with the default `missingValues = [""]` an empty cell reads
  back as `NA`.
* Erasure coding, non-CSV containers, and encryption are out of scope for v0.1.

## Compatibility

A fixture is round-tripped through common CSV tools and the recovery and
data-damage results recorded in
[`inst/compat/`](https://github.com/lecy/csvschema/blob/main/inst/compat/README.md).
Every scriptable tool tested so far --- base R, readr, data.table, arrow,
vroom, and line-based row subsets --- recovers the schema (`verified`); the
canary names what each one did to the data (the zero-padded 9-digit ID and the
17-digit ID are the usual casualties, read as an integer and a double). Other
tools (Python, DuckDB, SQLite, spreadsheets, …) are listed there as not yet
tested.

## Specification

The wire format is specified normatively, and independently of R, in
[`inst/specs/wire-format.md`](https://github.com/lecy/csvschema/blob/main/inst/specs/wire-format.md)
--- complete enough to write a conforming reader or writer in another language.

## Relationship to Frictionless

The canonical schema model is Frictionless Table Schema v2. `csvschema` adds a
*wire encoding*, not a new schema language: `cs_schema_to_frictionless()` and
`cs_schema_from_frictionless()` convert losslessly for the supported subset,
and the sidecar is a standard Data Package.

## License

MIT © Jesse Lecy. The `dg_states` fixture derives from the `datagoodr` package.
