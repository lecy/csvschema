# Schema model and the wire payload mapping

test_that("types are inferred from a data frame", {
  df <- data.frame(
    i = 1:3,
    x = c(1.5, 2.5, 3.5),
    b = c(TRUE, FALSE, NA),
    s = c("a", "b", "c"),
    f = factor(c("lo", "hi", "lo")),
    o = factor(c("lo", "hi", "lo"), levels = c("lo", "hi"), ordered = TRUE),
    d = as.Date(c("2024-01-01", "2024-02-02", "2024-03-03")),
    stringsAsFactors = FALSE
  )
  s <- cs_schema(df)
  types <- vapply(s$fields, function(f) f$type, character(1))
  names(types) <- vapply(s$fields, function(f) f$name, character(1))
  expect_identical(types[["i"]], "integer")
  expect_identical(types[["x"]], "number")
  expect_identical(types[["b"]], "boolean")
  expect_identical(types[["s"]], "string")
  expect_identical(types[["f"]], "string")
  expect_identical(types[["o"]], "string")
  expect_identical(types[["d"]], "date")
  expect_identical(s$fields[[7]]$format, "%Y-%m-%d")
  expect_true(isTRUE(s$fields[[6]]$categoriesOrdered))
  expect_false(isTRUE(s$fields[[5]]$categoriesOrdered))
})

test_that("field payloads match the specification examples", {
  ein <- list(name = "ein", type = "string",
              constraints = list(pattern = "^[0-9]{9}$", unique = TRUE,
                                 required = TRUE))
  expect_identical(.cs_field_to_payload(ein),
                   "ein^str^pat=%5E%5B0-9%5D%7B9%7D%24^uniq^req")

  fy <- list(name = "fiscal_year", type = "year")
  expect_identical(.cs_field_to_payload(fy), "fiscal_year^year")

  rev <- list(name = "total_revenue", type = "number",
              missingValues = list("", "-9"))
  expect_identical(.cs_field_to_payload(rev), "total_revenue^num^na=!-9")

  org <- list(name = "org_type", type = "integer",
              categories = list(
                list(value = 1, label = "Public charity"),
                list(value = 2, label = "Private foundation"),
                list(value = 3, label = "Other 501(c)")
              ))
  expect_identical(
    .cs_field_to_payload(org),
    "org_type^int^lev=1:Public+charity!2:Private+foundation!3:Other+501(c)"
  )

  size <- list(name = "size_class", type = "string",
               categories = list("small", "medium", "large"),
               categoriesOrdered = TRUE)
  expect_identical(.cs_field_to_payload(size),
                   "size_class^str^lev=small!medium!large^ord")

  rd <- list(name = "ruling_date", type = "date", format = "%Y-%m-%d")
  expect_identical(.cs_field_to_payload(rd),
                   "ruling_date^date^fmt=%25Y-%25m-%25d")
})

test_that("table payload matches the specification example", {
  tbl <- list(primaryKey = c("ein", "fiscal_year"))
  expect_identical(.cs_table_to_payload(tbl), "pk=ein!fiscal_year")
  expect_identical(.cs_table_to_payload(list()), "")
})

test_that("field payload round-trips through parse", {
  fields <- list(
    list(name = "ein", type = "string",
         constraints = list(pattern = "^[0-9]{9}$", unique = TRUE, required = TRUE)),
    list(name = "total_revenue", type = "number", missingValues = list("", "-9")),
    list(name = "org_type", type = "integer",
         categories = list(list(value = 1, label = "Public charity"),
                           list(value = 2, label = "Private foundation"))),
    list(name = "size_class", type = "string",
         categories = list("small", "medium", "large"),
         categoriesOrdered = TRUE),
    list(name = "ruling_date", type = "date", format = "%Y-%m-%d"),
    list(name = "café résumé", type = "string")
  )
  # Category codes come back as text (the wire is text); compare as strings.
  as_chr_cats <- function(cats) {
    lapply(cats, function(c) {
      if (is.list(c)) list(value = as.character(c$value),
                           label = as.character(c$label)) else as.character(c)
    })
  }
  for (f in fields) {
    rt <- .cs_payload_to_field(.cs_field_to_payload(f))
    expect_identical(rt$name, f$name)
    expect_identical(rt$type, f$type)
    expect_equal(as_chr_cats(rt$categories), as_chr_cats(f$categories))
    expect_equal(rt$constraints, f$constraints)
    expect_equal(rt$missingValues, f$missingValues)
    expect_identical(rt$format, f$format)
    expect_identical(isTRUE(rt$categoriesOrdered), isTRUE(f$categoriesOrdered))
  }
})

test_that("empty and trailing-empty list items survive splitting", {
  expect_identical(.cs_split_items("!-9", "!"), c("", "-9"))
  expect_identical(.cs_split_items("-9!", "!"), c("-9", ""))
  expect_identical(.cs_split_items("!", "!"), c("", ""))
  expect_identical(.cs_split_items("a!b!c", "!"), c("a", "b", "c"))
  # a missing-value set with a trailing empty string round-trips
  f <- list(name = "v", type = "string", missingValues = list("-9", ""))
  rt <- .cs_payload_to_field(.cs_field_to_payload(f))
  expect_equal(rt$missingValues, list("-9", ""))
})

test_that("schema payloads rebuild an equivalent schema", {
  df <- data.frame(
    id = 1:4,
    grp = factor(c("a", "b", "a", "c")),
    val = c(1.1, 2.2, NA, 4.4),
    ok = c(TRUE, FALSE, TRUE, NA),
    stringsAsFactors = FALSE
  )
  s <- cs_schema(df, primary_key = "id")
  payloads <- .cs_schema_payloads(s)
  expect_length(payloads, length(df) + 1L) # fields + table packet
  s2 <- .cs_schema_from_payloads(payloads)
  expect_identical(vapply(s2$fields, function(f) f$name, character(1)),
                   names(df))
  expect_identical(vapply(s2$fields, function(f) f$type, character(1)),
                   vapply(s$fields, function(f) f$type, character(1)))
  expect_identical(s2$table$primaryKey, c("id"))
  # canonical text and hash are stable across the round-trip
  expect_identical(.cs_canonical_text(s), .cs_canonical_text(s2))
  expect_identical(.cs_schema_hash(s), .cs_schema_hash(s2))
})

test_that("the whole-schema hash is 12 lowercase hex and deterministic", {
  s <- cs_schema(data.frame(a = 1L, b = "x", stringsAsFactors = FALSE))
  h <- .cs_schema_hash(s)
  expect_match(h, "^[0-9a-f]{12}$")
  expect_identical(h, .cs_schema_hash(s))
})

test_that("Frictionless conversion round-trips the supported subset", {
  df <- data.frame(
    ein = c("001234567", "123456789"),
    grp = factor(c("a", "b")),
    rev = c(1.5, 2.5),
    stringsAsFactors = FALSE
  )
  s <- cs_schema(df, overrides = list(
    ein = list(constraints = list(pattern = "^[0-9]{9}$", unique = TRUE))
  ), primary_key = "ein")
  fr <- cs_schema_to_frictionless(s)
  js <- jsonlite::toJSON(fr, auto_unbox = TRUE)
  s2 <- cs_schema_from_frictionless(js)
  expect_identical(vapply(s2$fields, function(f) f$name, character(1)),
                   c("ein", "grp", "rev"))
  expect_identical(vapply(s2$fields, function(f) f$type, character(1)),
                   c("string", "string", "number"))
  expect_identical(s2$fields[[1]]$constraints$pattern, "^[0-9]{9}$")
  expect_true(isTRUE(s2$fields[[1]]$constraints$unique))
  expect_identical(s2$table$primaryKey, "ein")
})

test_that("base colClasses are emitted", {
  df <- data.frame(i = 1L, x = 1.5, s = "a", d = as.Date("2024-01-01"),
                   stringsAsFactors = FALSE)
  ct <- cs_to_coltypes(cs_schema(df))
  expect_identical(ct[["i"]], "integer")
  expect_identical(ct[["x"]], "numeric")
  expect_identical(ct[["s"]], "character")
  expect_identical(ct[["d"]], "Date")
})

test_that("the states fixture infers a sensible schema", {
  s <- cs_schema(dg_states)
  ty <- stats::setNames(vapply(s$fields, function(f) f$type, character(1)),
                        vapply(s$fields, function(f) f$name, character(1)))
  expect_identical(ty[["state"]], "string")
  expect_identical(ty[["region"]], "string")      # factor -> string + categories
  expect_identical(ty[["south"]], "boolean")
  expect_identical(ty[["population"]], "number")
  expect_identical(ty[["motto_year"]], "integer")
  region <- s$fields[[which(names(ty) == "region")]]
  expect_length(region$categories, 4L)
})
