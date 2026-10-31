# csvschema 0.0.0.9000

Initial implementation, built bottom-up from the design brief.

* **Codec** (`encode.R`): percent-encoding to a pure-ASCII, separator-safe token
  form (`cs_encode_token()`/`cs_decode_token()`) and `cs_crc32()`.
* **Schema model** (`schema.R`): `cs_schema()` from data frames (factors,
  ordered factors, `haven::labelled`, `Date`, `POSIXct`, integer/double,
  logical, character), one-to-one mapping to Frictionless Table Schema v2,
  lossless conversion both ways, and `cs_to_coltypes()` / `cs_to_readr_spec()`.
* **Wire format** (`packetize.R`, `parse.R`): `cs_packetize()` with deterministic
  first-fit fragmentation, `cs_parse_packets()`, and `cs_recover()` with the
  four statuses (`verified`, `conflict`, `incomplete`, `absent`), a per-packet
  CRC-32 and a whole-schema SHA-1.
* **Layout** (`layout.R`): the redundancy math (`cs_copies()`,
  `cs_redundancy()`, `cs_survival()`) and a reproducible rotating stripe
  (`cs_stripe()`, `cs_lay()`).
* **Canary** (`canary.R`): a purposeful value sampler, canary packets, and a
  two-level check (`cs_canary_check()`) that names the kind of data damage.
* **I/O** (`io_write.R`, `io_read.R`): `cs_write()` and `cs_read_csv()`, column
  detection by content, schema application, and a Frictionless
  `datapackage.json` sidecar with cross-hashes.
* **Simulators** (`corrupt.R`): the `cs_corrupt_*()` family, one per
  threat-model vector.
* **Reporting** (`report.R`): the `cs_report` object, one-line summaries and
  tables.

## Design notes and known limits

* The package name is `csvschema` and the API prefix is `cs_` (the brief used
  the working name `schemaless` / `sl_`).
* The rotating stripe guarantees recovery from a `head()`/prefix, from any
  window of at least `2P - 1` consecutive rows, from full-file reads, and from
  the systematic every-`P`-th-row sample. A single period-`P` stripe cannot
  also guarantee every arbitrary strided sample in its first `P` terms; heavy
  arbitrary strides rely on the redundancy `r`, not the stripe.
* Case folding of every cell is **detected, not recovered**: the per-packet CRC
  covers the exact-case payload, so folded payloads fail their CRC and are
  dropped. Recovery reports the loss rather than returning a silently wrong
  schema.
* With the default `missingValues = [""]`, an empty cell reads back as `NA`;
  `""` and `NA` are indistinguishable once written with `na = ""`.
* Two vectors cannot be mitigated in-band: deletion of every schema column, and
  bit-level damage to a compressed container.
