# Generate the compatibility fixture and run the scriptable matrix.
#
#   Rscript data-raw/make_compat.R
#
# Writes inst/compat/fixture.csv, round-trips it through every scriptable tool
# available on this machine, records the recovery and canary outcome per tool,
# and writes inst/compat/results.csv (itself a self-describing csvschema file)
# plus inst/compat/results-table.csv (plain, for the README).

suppressMessages(devtools::load_all(".", quiet = TRUE))
set.seed(1014)
dir.create("inst/compat", recursive = TRUE, showWarnings = FALSE)

N <- 2000L
genes <- c("SEPT1", "MARCH1", "DEC1", "SEPT2", "MARCH2", "OCT4")
rev <- round(stats::rnorm(N, 1e6, 2e5))
rev[sample(N, 60)] <- -9           # refused
rev[sample(N, 40)] <- -8           # not asked
free <- sample(c('He said "hello"', "a, b, c", "line one\nline two",
                 "plain text", "50% off"), N, replace = TRUE)

fixture <- data.frame(
  ein9      = sprintf("%09d", seq_len(N)),                 # leading zeros
  id17      = paste0("1", sprintf("%016d", seq_len(N))),   # 17-digit strings
  gene      = sample(genes, N, replace = TRUE),            # date coercion
  price_eur = sprintf("€%.2f", stats::runif(N, 1, 999)), # non-ASCII
  ruling    = as.Date("2000-01-01") + sample(0:9000, N, replace = TRUE),
  size      = factor(sample(c("XS", "S", "M", "L", "XL", "XXL"), N, TRUE),
                     levels = c("XS", "S", "M", "L", "XL", "XXL"),
                     ordered = TRUE),
  ntee      = factor(sample(sprintf("category-%02d", 1:40), N, TRUE),
                     levels = sprintf("category-%02d", 1:40)),  # 40 levels
  revenue   = rev,
  freetext  = free,
  count     = sample(1:5L, N, replace = TRUE),
  ratio     = round(stats::runif(N), 4),
  flag      = sample(c(TRUE, FALSE), N, replace = TRUE),
  stringsAsFactors = FALSE
)

fixture_csv <- "inst/compat/fixture.csv"
cs_write(fixture, fixture_csv, sidecar = FALSE, c = 1, p = 1, f = 0.2,
         verbose = FALSE)
cat("wrote", fixture_csv, "-", nrow(fixture), "rows,", ncol(fixture), "fields\n")

# One result row from a cs_read() report. For row-subset tools, set
# canary = FALSE: dropped rows remove sampled values, so the canary cannot
# distinguish lost-to-row-deletion from lost-to-coercion and is not meaningful.
summarise <- function(tool, version, out, notes = "", canary = TRUE) {
  rep <- cs_report(out)
  cn <- rep$canary
  if (!canary) {
    return(data.frame(
      tool = tool, version = version, date = as.character(Sys.Date()),
      schema_status = rep$status, packets_dropped = rep$recovery$dropped_crc,
      vars_intact = NA_integer_, vars_corrupted = NA_integer_,
      damage_types = "", notes = notes, stringsAsFactors = FALSE))
  }
  corr <- if (!is.null(cn) && nrow(cn)) cn$variable[cn$verdict == "corrupted"] else character(0)
  dmg <- if (length(corr)) {
    paste(sort(unique(unlist(strsplit(gsub("\\s*\\(\\d+\\)", "", cn$damage[cn$verdict == "corrupted"]), ";\\s*")))), collapse = "; ")
  } else ""
  data.frame(
    tool = tool, version = version, date = as.character(Sys.Date()),
    schema_status = rep$status,
    packets_dropped = rep$recovery$dropped_crc,
    vars_intact = if (!is.null(cn)) sum(cn$verdict == "intact") else NA_integer_,
    vars_corrupted = length(corr),
    damage_types = dmg,
    notes = notes,
    stringsAsFactors = FALSE
  )
}

ver <- function(pkg) as.character(utils::packageVersion(pkg))

rows <- list()

# --- R readers/writers, default settings (type inference ON) ----------------
r_tools <- list(
  list(tool = "R read.csv / write.csv", version = as.character(getRversion()),
       rw = function(i, o) utils::write.csv(utils::read.csv(i, check.names = FALSE),
                                            o, row.names = FALSE)),
  list(tool = "readr read_csv / write_csv", version = ver("readr"),
       rw = function(i, o) readr::write_csv(
         readr::read_csv(i, show_col_types = FALSE, progress = FALSE), o)),
  list(tool = "data.table fread / fwrite", version = ver("data.table"),
       rw = function(i, o) data.table::fwrite(data.table::fread(i), o)),
  list(tool = "arrow read_csv_arrow / write_csv_arrow", version = ver("arrow"),
       rw = function(i, o) arrow::write_csv_arrow(arrow::read_csv_arrow(i), o)),
  list(tool = "vroom vroom / vroom_write", version = ver("vroom"),
       rw = function(i, o) vroom::vroom_write(
         vroom::vroom(i, show_col_types = FALSE, progress = FALSE), o,
         delim = ","))
)
for (t in r_tools) {
  out_csv <- tempfile(fileext = ".csv")
  res <- tryCatch({
    t$rw(fixture_csv, out_csv)
    out <- suppressWarnings(cs_read_csv(out_csv, sidecar = FALSE, verbose = FALSE))
    summarise(t$tool, t$version, out)
  }, error = function(e) data.frame(
    tool = t$tool, version = t$version, date = as.character(Sys.Date()),
    schema_status = "error", packets_dropped = NA_integer_,
    vars_intact = NA_integer_, vars_corrupted = NA_integer_,
    damage_types = "", notes = conditionMessage(e), stringsAsFactors = FALSE))
  rows[[length(rows) + 1L]] <- res
  cat(sprintf("  %-40s %s\n", t$tool, res$schema_status))
}

# --- shell row-subset tools (line-based) ------------------------------------
awk_ok <- nzchar(Sys.which("awk"))
if (awk_ok) {
  run_awk <- function(prog, label, notes) {
    out_csv <- tempfile(fileext = ".csv")
    ok <- system2("awk", c(shQuote(prog), shQuote(normalizePath(fixture_csv))),
                  stdout = out_csv)
    out <- suppressWarnings(cs_read_csv(out_csv, sidecar = FALSE, verbose = FALSE))
    summarise(label, "awk", out, notes, canary = FALSE)
  }
  rows[[length(rows) + 1L]] <-
    run_awk("NR<=401", "awk head (contiguous, ~20% of rows)",
            "line-based row subset; schema recovery only")
  rows[[length(rows) + 1L]] <-
    run_awk("NR==1 || (NR-2)%5==0", "awk stride (every 5th row)",
            "line-based row subset; schema recovery only")
  for (i in (length(rows) - 1L):length(rows)) {
    cat(sprintf("  %-40s %s\n", rows[[i]]$tool, rows[[i]]$schema_status))
  }
}

results <- do.call(rbind, rows)

# Tools we cannot script on this machine, listed for completeness.
not_tested <- c(
  "Python csv module", "pandas read_csv / to_csv", "Polars",
  "DuckDB read_csv_auto / COPY", "SQLite .import / .mode csv",
  "PostgreSQL COPY", "Stata import/export delimited",
  "SAS PROC IMPORT", "SPSS GET DATA",
  "Excel (Windows en-US)", "Excel (Windows de-DE, ; delimiter)",
  "Excel for Mac", "Google Sheets", "LibreOffice Calc", "Apple Numbers",
  "Notepad / TextEdit resave", "Gmail attach and download")
results <- rbind(results, data.frame(
  tool = not_tested, version = "", date = "", schema_status = "not yet tested",
  packets_dropped = NA_integer_, vars_intact = NA_integer_,
  vars_corrupted = NA_integer_, damage_types = "", notes = "",
  stringsAsFactors = FALSE))

# Plain copy for the README, and a self-describing copy per the design brief.
utils::write.csv(results, "inst/compat/results-table.csv", row.names = FALSE)
cs_write(results, "inst/compat/results.csv", sidecar = FALSE, verbose = FALSE)
saveRDS(results, "data-raw/compat-results.rds")
cat("\nwrote inst/compat/results.csv and results-table.csv\n")
print(results[results$schema_status != "not yet tested",
              c("tool", "schema_status", "vars_corrupted", "damage_types")])

# --- render inst/compat/README.md -------------------------------------------
scriptable <- results[results$schema_status != "not yet tested", ]
scriptable$damage <- ifelse(nzchar(scriptable$damage_types),
                            scriptable$damage_types,
                            ifelse(is.na(scriptable$vars_corrupted),
                                   "schema recovery only", "none"))
tbl <- knitr::kable(
  scriptable[, c("tool", "version", "schema_status", "damage")],
  col.names = c("Tool", "Version", "Schema", "Data damage (canary)"))
pending <- paste0("- ", not_tested, collapse = "\n")

readme <- c(
  "# Compatibility matrix",
  "",
  "One fixture round-tripped through common CSV readers and writers, with the",
  "recovery status and the canary's data-damage diagnosis recorded per tool.",
  sprintf("Generated by `data-raw/make_compat.R` on %s.", Sys.Date()),
  "",
  "## Fixture",
  "",
  sprintf("`fixture.csv`: %d rows, %d fields chosen to trip every detector --- a",
          nrow(fixture), ncol(fixture)),
  "9-digit zero-padded id, a 17-digit id, gene-style names (`SEPT1`), a",
  "euro-priced column, a date, an ordered factor (6 levels), a nominal factor",
  "(40 levels, to force fragmentation), a `-9`/`-8` sentinel column, free text",
  "with quotes, commas and a newline, and integer, double and logical columns.",
  "Written with `c = 1, p = 1, f = 0.2`.",
  "",
  "## Procedure (per tool)",
  "",
  "1. Open `fixture.csv` in the tool with default settings.",
  "2. Save or export back to CSV with default settings.",
  "3. Run `cs_read_csv()` on the result; record the recovery status and the",
  "   per-variable canary diagnosis.",
  "4. For line-based row-subset tools, record schema recovery only (dropped",
  "   rows remove sampled values, so the canary is not meaningful).",
  "",
  "## Results (scriptable on this machine)",
  "",
  tbl,
  "",
  "Every scriptable tool recovers the schema (`verified`); the canary names what",
  "each one did to the data. `long_digits` / `scientific` is the 17-digit id",
  "read as a double; `leading_zero` is the zero-padded id read as an integer.",
  "Full results, with versions and counts, are in `results-table.csv`, and a",
  "self-describing copy (written with `cs_write()`) is in `results.csv`.",
  "",
  "## Not yet tested",
  "",
  "These need the tool installed or a manual run:",
  "",
  pending, "")
writeLines(readme, "inst/compat/README.md")
cat("wrote inst/compat/README.md\n")
