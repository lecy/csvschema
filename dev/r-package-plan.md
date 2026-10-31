# schemaless — R package plan

Oct 30, 2026 · @Jesse Lecy

## Purpose and scope

`schemaless` writes and reads CSV files that carry their own schema inside ordinary data columns, so the file opens as a plain CSV in every tool and the schema survives sorting, filtering, row loss, and spreadsheet round-trips. The name is the joke: the file looks schemaless and is not.

The package does four things:

1. **Packetize** a table schema (field names, types, formats, missing codes, factor levels, keys) into short ASCII tokens and spread redundant copies through one or more `_schema` columns.
2. **Recover** the schema from any surviving subset of rows, verify it, and apply it (types, factors, NA codes) when reading.
3. **Canary** the data: store a purposeful sample of fragile values per variable in a `_canary` column and check after a round-trip whether each variable is still intact, and if not, how it was damaged.
4. **Point** to an optional Frictionless `datapackage.json` sidecar and cross-check hashes in both directions.

Out of scope for v0.1: erasure coding (Reed-Solomon, fountain codes), non-CSV containers, encrypting or compressing the schema, and schema *inference* beyond what a data frame already carries. The canonical schema model is Frictionless Table Schema v2; `schemaless` adds a wire encoding, not a new schema language.

This document is the brief for a coding agent. Decisions marked **(decide)** are defaults the agent should implement as configurable constants and flag for review; everything else is settled.

## Design principles

The wire format assumes a hostile channel: any CSV dialect, any locale, any spreadsheet, any human with find-and-replace. The internet solved the same problem by assuming a 7-bit channel and encoding everything else (MIME, Punycode, percent-encoding). Every rule below follows from that assumption.

1. **A packet is one unquoted token.** No comma, semicolon, tab, pipe, double or single quote, newline, or whitespace anywhere inside it. Then no dialect ever needs to quote it and delimiter rewriting cannot change it.
2. **Pure ASCII.** Non-ASCII bytes in labels are percent-encoded (`%E2%82%AC` for the euro sign). The checksum is computed over ASCII bytes, so no encoding conversion can alter it. Spaces become `+`.
3. **Wrapped and letter-led.** Every packet is `{{...}}` and the first character inside is a letter. `{` is text in every spreadsheet; nothing inside may begin with `=`, `+`, `-`, `@`, or look like a number, date, fraction, or time.
4. **Self-locating.** Every packet carries its own index and the total count. Row order, row position, and column name are never relied on; the schema column is found by regex, not by header.
5. **Self-checking at two levels.** Each packet has a CRC-32; the set has a whole-schema hash in packet 0. A damaged packet is dropped; a plausible mix of two versions is rejected.
6. **Short.** Maximum packet length is a tunable MTU, default 200 characters, chosen to clear a 255-character `VARCHAR`. Longer definitions are fragmented.
7. **Case-tolerant grammar.** Keywords lowercase, hashes lowercase hex, parsing case-insensitive; payload case is preserved and protected by the CRC.
8. **Redundant by arithmetic, not by hope.** The number of copies is computed from row count, packet count, and a stated retention threshold.
9. **Readable without the package.** A person opening the raw CSV should be able to read `org_type int levels 1=Public charity ...` from a cell. Readability loses to rules 1-3 only where they conflict.
10. **Belt and suspenders.** In-band packets and an out-of-band sidecar authenticate each other; neither is required for the other to work.
11. **Drop-safe.** All added columns begin with `_` and are documented as ignorable. `sl_read_csv()` removes them by default; a reader who knows nothing of the package loses nothing but two character columns.
12. **Detect, then diagnose.** The package never silently repairs data. It reports what was recovered, what is missing, what conflicts, and which variables fail their canaries and why.

## Threat model: corruption vectors

The format must survive every vector below without silent failure. Each row names the mitigation and which test simulator (section on testing) exercises it. Vectors marked *data* damage the data columns rather than the packets; the canary column exists for those.

| Vector | What happens | Mitigation | Simulator |
| --- | --- | --- | --- |
| Encoding conversion | Excel writes system code page, reads BOM-less files as ANSI; euro, accents, dashes become mojibake; NFC/NFD normalization changes bytes | Packets pure ASCII; labels percent-encoded; CRC over ASCII bytes; packet 0 declares intended data encoding | `corrupt_encoding()` |
| UTF-8 BOM | First header name becomes `\ufeffein`; some readers choke | Locate schema column by content regex; strip BOM on read | `corrupt_bom()` |
| Delimiter rewriting | Excel in decimal-comma locales writes `;`; PSV tools use `\|`; `,`-files read as one column | No delimiter characters inside packets | `corrupt_delimiter()` |
| Quote rewriting | `""` vs `\"` escaping; smart quotes from Word, Outlook, Slack, Google Docs | No quotes inside packets | `corrupt_smartquotes()` |
| Whitespace | Trimming, padding, tabs to spaces, spaces to U+00A0 on paste | No whitespace inside packets; strip non-ASCII and whitespace before parse | `corrupt_whitespace()` |
| Truncation | 255-char `VARCHAR`, Access text; 2,045 Stata `str`; 200 SAS default; 32,767 Excel/SPSS; MIME line wrap at 76-998 | MTU default 200; fragmentation; CRC catches partial cells | `corrupt_truncate()` |
| Case folding | Mainframe/SQL loaders uppercase; proper-case autoformat | Case-insensitive grammar; hex checksums; CRC flags folded payloads | `corrupt_case()` |
| Leading zeros stripped (*data*) | `00123` becomes `123` | Canary: leading-zero values sampled per variable | `corrupt_excel()` |
| Precision loss (*data*) | 16+ digit IDs rounded to 15 sig. figs, shown as `1.23E+15` | Canary: longest digit strings sampled; schema declares string type and pattern | `corrupt_excel()` |
| Date coercion (*data*) | `SEPT1`, `1/12`, `3-4` become dates; `1:7` becomes a time | Canary: date-like and fraction-like strings sampled | `corrupt_excel()` |
| Formula injection (*data*) | Cells starting `= + - @` evaluated | Packets never start with these; canary samples such values | `corrupt_excel()` |
| Row deletion | Random, contiguous (`head`, pages), or strided (every k-th row) | Redundancy sizing; rotating stripe so strides cannot alias | `corrupt_rows()` |
| Row duplication / reorder | `rbind`, sort, shuffle | Index in every packet; dedupe on parse | `corrupt_rows()` |
| Version mixing | Two edited files bound together; every packet valid, set inconsistent | Whole-schema hash in packet 0; conflict detection per index | `corrupt_merge()` |
| Header loss | Header deleted or regenerated as `V1..Vn` | Column located by regex `^\{\{[SC]\d+` | `corrupt_header()` |
| Column deletion | `_schema` dropped | Fatal for in-band; second column or sidecar; report clearly | `corrupt_columns()` |
| Text-to-Columns | Cell split on an internal separator | Separators chosen outside common split characters (see packet design) | `corrupt_columns()` |
| Line endings | CRLF/LF conversion; stray `\r` in quoted cell; last line dropped without trailing newline | Nothing essential depends on a single row | `corrupt_eol()` |
| Human edits | Global find-and-replace hits payload labels | CRC turns silent edit into detected failure | `corrupt_replace()` |
| Invisible characters | Zero-width space, soft hyphen, bidi marks inserted by editors | Strip all non-ASCII before parse | `corrupt_invisible()` |
| Transport | gzip bit flips, FTP ASCII mode, Markdown renderers eating `_` and `*` | Out of scope except CRC detection; document | none |

Two vectors cannot be mitigated in-band and must be stated in the README: deletion of every schema column, and bit-level damage to a compressed container.

## Internet protocol mechanisms, translated

A CSV passed between programs is a one-way broadcast over an erasure channel: rows vanish, cells get damaged, and there is no way to ask the sender for a resend. The internet separates three problems that are easy to conflate, and `schemaless` needs all three.

### 1. Fragmentation metadata: which piece is this, and how many are there?

When an IP packet is too large for a link it is cut into fragments. Each fragment carries three things in its header: an **identification** number shared by all fragments of the same original (so fragments of two different packets are never mixed), a **fragment offset** saying where this piece belongs in the reassembled whole, and a **more-fragments flag** that is 1 on every fragment except the last. The receiver can therefore reassemble in any arrival order, detect that a piece is missing, and know when it has the last one.

Translation: every schema packet carries `S<k>/<P>`: *k* is the offset (which field definition this is), *P* is the total. We carry the total in every packet rather than a last-piece flag because a flag fails when the last piece is the one lost: indices 1..11 with a missing 12 look complete. The identification number becomes the whole-schema hash in packet 0, which is what lets the reader tell two schema versions apart.

### 2. Per-piece integrity: is this piece intact?

IP, UDP, and TCP headers each carry a checksum; Ethernet frames carry a CRC-32. The receiver recomputes the checksum over the bytes it received and compares. On mismatch the piece is **discarded**, never repaired or trusted. The point is to convert *silent* corruption into *detected* loss, which the next layer can handle.

Translation: each packet ends with a CRC-32 (8 hex characters) over `id~payload`. A packet that fails is dropped as if the row had been deleted. Excel stripping a label, a find-and-replace, or a truncated cell all become ordinary erasures that redundancy absorbs.

### 3. Whole-object verification: is the reassembled thing the right thing?

A BitTorrent `.torrent` file lists a SHA-1 hash for every piece *and* an info-hash over the whole piece list. A client can download pieces from dozens of peers, each piece individually verified, and still confirm at the end that the assembled file is the one the publisher released. Without the whole-object hash, a set of individually valid pieces from two different versions would pass.

Translation: packet 0 carries a hash over the canonical schema text (all payloads 1..P joined in order). After reassembly `sl_recover()` recomputes it. Mismatch means version mixing: two files with different schemas were bound together, or a field was edited in only some copies.

### What the internet does that we cannot

TCP recovers lost segments by retransmission: the receiver acknowledges what it has, the sender resends the rest. There is no back-channel in a CSV. The relevant precedents are forward-error-correction systems that never hear from the receiver: PAR2 recovery blocks for Usenet binaries, Reed-Solomon in QR codes, fountain codes (LT, Raptor) in broadcast and DNA storage. All of them work by sending more than the minimum and letting integrity checks sort good pieces from bad.

`schemaless` uses the simplest form, repetition coding: every packet appears *r* times. Erasure codes would recover from fewer surviving rows but destroy human readability and add a dependency. The redundancy math below shows repetition is sufficient for realistic row counts. Leave an extension point for an erasure-coded packet type (`E<k>/<P>`) but do not build it.

| Internet mechanism | Purpose | `schemaless` analogue |
| --- | --- | --- |
| IP identification | Group fragments of one datagram | Schema hash in packet 0 |
| IP fragment offset | Position of this piece | `k` in `S<k>/<P>` |
| IP more-fragments flag | Know when all pieces are in | `P` carried in every packet |
| TCP/UDP checksum, Ethernet CRC | Discard damaged pieces | CRC-32 suffix per packet |
| BitTorrent info-hash | Reject mixed versions | Whole-schema hash recomputed after reassembly |
| TCP retransmission | Recover loss via back-channel | Not available; repetition coding instead |
| PAR2 / Raptor codes | Recover loss without back-channel | Repetition now; erasure-coded packet type reserved |
| Path MTU | Max piece size the link accepts | `mtu` argument, default 200 chars |

## Packet design: the wire format

A packet is a single ASCII token of the form `{{<id>~<payload>~<crc>}}`. The id says which piece it is, the payload is the content, the crc is CRC-32 over `<id>~<payload>` as 8 lowercase hex characters.

### Grammar

```
packet   := "{{" id "~" payload "~" crc "}}"
id       := type index ["." frag "of" nfrag] "/" total
type     := "S" | "C"            ; S = schema, C = canary; E reserved
index    := digits                  ; 0 = header packet
frag     := digits  nfrag := digits ; only when a payload was fragmented
total    := digits                  ; number of packets of this type
payload  := attr ("^" attr)*
attr     := key ["=" value] | bareword
value    := item ("!" item)*        ; list items
item     := token | code ":" token  ; code:label pairs for levels
token    := ASCII, percent-encoded  ; no ~ ^ ! = : % { } whitespace or CSV chars
crc      := 8 lowercase hex
```

Separator choice **(decide)**: `~` between parts, `^` between attributes, `!` between list items, `=` for key-value, `:` for code-label. None of these is a CSV delimiter in any dialect, none triggers Excel coercion, and none is a Text-to-Columns default. The literal characters `~ ^ ! = : % + { }` and space inside a token are percent-encoded; space is `+`. Keep all five separators as named constants in one file so they can be swapped before v1.0.

### Packet 0: the header

```
{{S0/8~sl=1^enc=utf-8^dialect=rfc4180^fields=6^rows=10000^hash=3fa9c2e17b04^side=datapackage.json^sidehash=9f2e1c0a~7a3b11d2}}
```

| Attribute | Meaning |
| --- | --- |
| `sl` | wire format version |
| `enc` | intended encoding of the data columns, for diagnosing mojibake |
| `dialect` | `rfc4180` or a short dialect name; delimiter and quote char if nonstandard |
| `fields` | number of data fields (excludes `_schema`, `_canary`) |
| `rows` | row count at write time, for row-loss reporting |
| `hash` | first 12 hex of SHA-1 over the canonical schema text (payloads 1..P joined by `\n`) |
| `side`, `sidehash` | sidecar filename or URL and first 8 hex of its SHA-1; optional |

### Field packets 1..P-1

One packet per field, in column order. Attribute keys map one-to-one onto Frictionless Table Schema v2 field properties so the sidecar can be generated from the packets and vice versa.

| Key | Frictionless | Example |
| --- | --- | --- |
| first bareword | `name` | `org_type` |
| second bareword | `type` | `str`, `int`, `num`, `bool`, `date`, `datetime`, `year` |
| `fmt` | `format` | `fmt=%25Y-%25m-%25d` |
| `na` | `missingValues` | `na=!-9!-8` (empty item = empty string) |
| `nalab` | labeled missingness | `nalab=-9:Refused!-8:Not+asked` |
| `lev` | `categories` | `lev=1:Public+charity!2:Private+foundation` or `lev=small!medium!large` |
| `ord` | `categoriesOrdered` | bareword `ord` |
| `pat` | `constraints.pattern` | `pat=%5E%5B0-9%5D%7B9%7D%24` |
| `uniq`, `req` | `constraints.unique`, `constraints.required` | barewords |
| `min`, `max` | `constraints.minimum/maximum` | `min=0` |
| `lab` | `title` | `lab=Organization+type` |
| `desc` | `description` | `desc=...` (fragmented if long) |

Example field packets for the running schema:

```
{{S1/8~ein^str^pat=%5E%5B0-9%5D%7B9%7D%24^uniq^req~c41d9a02}}
{{S2/8~fiscal_year^year~0e88b7f1}}
{{S3/8~total_revenue^num^na=!-9~b2f0a3c7}}
{{S4/8~org_type^int^lev=1:Public+charity!2:Private+foundation!3:Other+501(c)~5d19e4aa}}
{{S5/8~size_class^str^lev=small!medium!large^ord~e7a26b30}}
{{S6/8~ruling_date^date^fmt=%25Y-%25m-%25d~1c4f88d5}}
{{S7/8~pk=ein!fiscal_year~88a0c3ee}}
```

### Table-level packet P-1

The last schema packet carries table-level properties: `pk=` primary key fields, `fk=` foreign keys as `field:resource.field`, `fm=` the Frictionless `fieldsMatch` mode. It is a normal packet with index P-1 so the completeness check needs no special case.

### Rules

- The CRC covers `id~payload`, not the braces or the crc itself. Compute over the ASCII bytes after percent-encoding.
- Hashes are lowercase hex. Parsing lowercases the id and keys; payload values keep their case.
- Percent-decode only after the CRC check passes.
- A reader must accept, and a writer must never emit, a packet longer than `mtu` characters including braces.
- Unknown attribute keys are preserved and passed through, never an error, so newer writers stay readable by older readers.
- A canary packet (`C`) uses the same envelope with a different payload grammar (see canary section).

## Redundancy math and striping

The number of copies of each packet is set so that the schema survives, with stated probability, when only a fraction *f* of rows is retained at random. Repetition coding makes this a coupon-collector problem.

### Notation

- *P* packets, *N* rows, *c* schema columns, *p* packets per cell
- *r* = *pcN / P* copies of each packet (the writer rounds so every packet has at least this many)
- *f* = fraction of rows retained; *m* = *fN* rows survive
- *ε* = acceptable probability that at least one packet is lost

### Loss probability

A given packet is lost when none of its *r* copies lands in the *m* surviving rows. With independent retention that is (1 − *f*)^*r*; sampling without replacement is slightly more favorable, so this is conservative. A union bound over *P* packets gives the design constraint:

```latex
P \,(1-f)^{r} \le \varepsilon
\quad\Longrightarrow\quad
r \;\ge\; \frac{\ln(P/\varepsilon)}{-\ln(1-f)}
```

and the exact survival probability under the independence model, for reporting:

```latex
\Pr[\text{all } P \text{ recovered}] \;=\; \bigl(1-(1-f)^{r}\bigr)^{P}
```

### Worked table

Copies per packet required for *P* = 20 and *ε* = 10⁻⁶, and the total packet slots *pcN* that implies:

| Retained *f* | Copies *r* | Slots *pcN* | Rows needed at c=1, p=1 | Rows needed at c=2, p=4 |
| --- | --- | --- | --- | --- |
| 50% | 25 | 500 | 500 | 63 |
| 20% | 76 | 1,520 | 1,520 | 190 |
| 10% | 160 | 3,200 | 3,200 | 400 |
| 5% | 328 | 6,560 | 6,560 | 820 |
| 1% | 1,673 | 33,460 | 33,460 | 4,183 |

The three knobs fail differently, which is why all three exist. Column copies (*c*) survive heavy row loss and the loss of one schema column. Row copies survive column deletion. Packets per cell (*p*) is bounded by the MTU and buys nothing against column deletion. For small *N* the writer raises *p* first (cheap, invisible), then *c*.

### Functions

- `sl_copies(P, f, eps = 1e-6)` returns the minimum *r* from the formula above.
- `sl_redundancy(P, N, f = 0.2, eps = 1e-6, mtu = 200, packet_len)` chooses the smallest `(c, p)` with *pcN/P* ≥ *r*, subject to *p* × mean packet length ≤ `mtu`, preferring *p* over *c*. Returns a list with `c`, `p`, `r`, `achieved_eps`, and a human-readable sentence ("survives loss of 80% of rows with failure probability 3e-7").
- `sl_survival(P, N, c, p, f)` reports the achieved failure probability for a given layout, used by `print()` on written files and in the compatibility report.

### Striping

Random retention is the benign case. Two structured cases matter more:

1. **Contiguous retention** (`head()`, a page of a paginated export, a sorted file then filtered on the sort key). Striping handles it: if row *i* carries packet (*i* mod *P*), any *P* consecutive rows contain the whole schema.
2. **Strided retention** (every k-th row, systematic samples). Plain striping aliases: keep every 20th row of a 20-packet stripe and the same single packet is recovered forever.

The stripe therefore rotates per block. With blocks of *P* rows numbered *b* = 0, 1, 2, ..., row *i* in block *b* carries packet (*i* + *b*) mod *P*. Any stride *k* then cycles through all residues within *P* blocks. When *c* > 1, column *j* is offset by *jP/c* so a single row carries packets from different parts of the schema. When *p* > 1, a cell carries *p* consecutive indices.

`sl_stripe(P, N, c, p)` returns an *N* × *c* list-matrix of packet index vectors. It is pure arithmetic with no randomness, so it is reproducible and testable. Guarantee to document and test: any *P/p* consecutive rows, and any arithmetic progression of rows with stride *k* < *N/P*, contain every packet index.

## Fragmentation: MTU and atomizing long definitions

A packet must fit the smallest cell any realistic reader will preserve. The default `mtu` is 200 characters including braces, which clears a 255-character `VARCHAR` with room for a reader to add quotes. A field with forty levels or a long description will not fit, so field payloads are split into fragments that are themselves complete packets.

### Fragment envelope

```
{{S4.1of3/8~org_type^int^lev=1:Public+charity!2:Private+foundation~a1b2c3d4}}
{{S4.2of3/8~lev=3:Other+501(c)!4:Government!5:Religious~e5f60718}}
{{S4.3of3/8~lev=6:Unknown^lab=Organization+type~9a0b1c2d}}
```

Rules:

- Fragment ids are `S<k>.<j>of<J>/<P>`. `J` is carried in every fragment for the same reason `P` is.
- Fragment 1 always carries `name` and `type` so a partially recovered field is still identifiable.
- A list-valued attribute (`lev`, `na`, `nalab`) may be split across fragments; on reassembly the lists are concatenated in fragment order. Every other attribute appears in exactly one fragment, whole.
- A single token (one level label, one description) that exceeds the MTU on its own is an error at write time, not something to split mid-token. Suggest `desc` be moved to the sidecar in the error message.
- Each fragment has its own CRC; the whole-schema hash is over the reassembled payload for field *k*, not over the fragments, so refragmenting at a different MTU does not change the hash.
- Fragments count as separate packets for redundancy and striping: the effective packet count is the number of envelopes, not the number of fields. `sl_redundancy()` is called after fragmentation.

### Splitting algorithm

`sl_fragment(payload_attrs, mtu, overhead)` where `overhead` is the fixed cost of braces, id, separators and crc for the longest id string in this schema.

1. Serialize each attribute to its encoded string. Compute each list item's encoded length.
2. Open fragment 1 with `name` and `type`.
3. For each remaining attribute in canonical key order: if it is scalar and fits in the current fragment, append it; if scalar and does not fit, close the fragment and open a new one; if list-valued, greedily pack items into the current fragment, splitting the list at item boundaries and continuing in new fragments as needed.
4. Never split inside a token or a percent-escape.
5. If a single token plus overhead exceeds `mtu`, stop with an informative error.

This is first-fit on a fixed order, not an optimal bin packer. Fragment count is rarely more than one above optimal and the determinism matters more: the same schema at the same MTU must always produce byte-identical fragments so hashes and tests are stable.

### Choosing the MTU

| Target reader | Limit | Recommended `mtu` |
| --- | --- | --- |
| Default `VARCHAR`, Access, many ETL tools | 255 | 200 (default) |
| MIME e-mail line wrap | 76-998 per line | 200, and keep rows short |
| Stata `import delimited` string | 2,045 | 200 is fine; 1,000 if Stata-only |
| SAS character default | 200 | 180 |
| Excel, SPSS, SAS max | 32,767 | any |

`sl_write_csv(mtu = )` exposes it; the chosen value is recorded in packet 0 as `mtu=` so a reader can explain truncation failures.

## Canary column: detecting data corruption

A recovered schema is worthless if the data it describes was altered in transit. The `_canary` column stores, per variable, a small purposeful sample of the values most likely to be damaged plus a fingerprint of the whole column. After a round-trip the reader checks whether the sampled values still exist verbatim. The test is the one you wrote: `all(canary_values %in% column)`, run on the raw text of the column before any type conversion.

### Canary packet

Same envelope as schema packets, type `C`:

```
{{C3/7~ein^n=10000^na=0^nd=9871^fp=4c1e9a2b^v=001234567!090000001!123456789~7b2c1d0e}}
{{C5/7~total_revenue^n=10000^na=312^fp=88ad0f31^v=0.1!1234567890123456!-9!1e5~0d3e4f5a}}
{{C6/7~org_name^n=10000^na=0^fp=a9b8c7d6^v=SEPT1!Caf%C3%A9+Soci%C3%A9t%C3%A9!=SUM(A1)!+1+555~1f2e3d4c}}
```

| Key | Meaning |
| --- | --- |
| bareword | variable name |
| `n` | row count at write time |
| `na` | count of missing values |
| `nd` | count of distinct values |
| `fp` | fingerprint: first 8 hex of SHA-1 over the sorted distinct raw strings of the column |
| `v` | sampled values, percent-encoded, in the exact string form written to the CSV |

Canary packets are striped and replicated with the same machinery as schema packets. `C0` is a header carrying the canary count and the sampling recipe version.

### Purposeful sampling

`sl_canary_sample(x, k = 6)` selects values per variable by trying each detector in order and taking the first match it has not already taken, then fills the remainder at random. Detectors are the corruption vectors stated as predicates on the raw string:

| Detector | Catches | Example value |
| --- | --- | --- |
| leading zero | zero stripping | `00123` |
| long digit string (>15 digits) | 15-significant-figure rounding, `1.23E+15` | `1234567890123456` |
| date-like (`SEPT1`, `MAR3`, `1/12`, `3-4`, `2024-01-05`) | date coercion | `SEPT1` |
| time-like (`1:7`, `12:30`) | time coercion | `1:7` |
| scientific notation / decimal edge | precision and format change | `1e5`, `0.1`, `.5` |
| formula trigger (`= + - @` first) | formula evaluation, sign stripping | `=SUM(A1)`, `+1 555` |
| non-ASCII | mojibake, normalization | `Café` |
| leading or trailing whitespace | trimming | `" x"` |
| sentinel codes from the schema | NA handling | `-9` |
| longest and shortest strings | truncation, padding |  |
| empty string vs explicit `NA` token | NA collapsing |  |
| min and max (numeric) | range and sign |  |
| boolean-like (`TRUE`, `T`, `yes`, `1`) | boolean coercion |  |

If a variable has none of these, the canary is a random sample plus min and max, and the fingerprint does the heavy lifting.

### Verification and diagnosis

`sl_canary_check(raw_df, canaries)` runs on the data frame read with every column as character. Per variable it returns one of:

- **intact**: fingerprint matches.
- **rows changed, values intact**: fingerprint differs but every canary value present and `n` differs. Expected after filtering; reported, not flagged.
- **corrupted**: at least one canary value absent. The absent values are mapped back to the detector that selected them, so the report says *which kind* of damage: "leading zeros stripped (2 of 2 canaries lost)", "date coercion (SEPT1 missing)", "encoding (Café missing)".
- **unverifiable**: variable absent or canary packets not recovered.

Two-level check: the same test is run once more after the reader has applied the schema types, on the re-serialized values. A value that survives the raw check but fails the typed check was damaged by *this* reader, not by the file, and the report says so. This separates "the file is corrupt" from "your CSV reader is coercing things".

A failed canary never blocks reading. `sl_read_csv()` attaches the report as an attribute, prints a one-line summary, and provides `sl_report()` for the full table. Repair is the user's job; the package only makes the damage visible and nameable.

## Sidecar pointer and checksums

In-band packets and an out-of-band sidecar are complements, not alternatives. The sidecar is the canonical, human-editable, tool-standard form; the packets are the copy that cannot get lost. Each carries a hash of the other so a reader can tell which is stale.

### The sidecar

A Frictionless `datapackage.json` (Data Package v2, Table Schema v2) with one resource per CSV. `sl_write_sidecar()` generates it from the same `sl_schema` object that produced the packets, so the two never disagree at write time. The resource entry carries:

- `path`, `type: "table"`, `dialect`, `schema` (fields with `categories`, `missingValues`, constraints, `primaryKey`)
- `hash`: `sha1:<hex>` of the CSV file bytes, as Frictionless specifies
- `schemaless`: an extension object with `wire_version`, `mtu`, `columns` (names of the `_schema` and `_canary` columns), `c`, `p`, `redundancy` (the `sl_survival()` sentence), and `schema_hash` (the same value as packet 0's `hash`)

### Pointers in both directions

| Where | Points to | Hash of |
| --- | --- | --- |
| packet `S0` `side=` | sidecar filename or URL |  |
| packet `S0` `sidehash=` |  | first 8 hex of SHA-1 over the canonical sidecar JSON |
| sidecar `schemaless.schema_hash` |  | canonical schema text, equals `S0` `hash=` |
| sidecar `hash` |  | the CSV file bytes |

Canonical sidecar JSON for hashing: keys sorted, no whitespace, UTF-8, as `jsonlite::toJSON(auto_unbox = TRUE, pretty = FALSE)` on a key-sorted list. Document the exact procedure so other implementations match.

### Reader behavior

`sl_read_csv(path, sidecar = NULL)` resolves in this order and reports which source it used:

1. Recover packets. If complete and verified, that is the schema.
2. If a sidecar is given or named in `S0` and exists, read it. Compare `schema_hash` to the recovered hash. Equal: fine. Different: warn, prefer **(decide)** the in-band schema by default because it traveled with the data, and show a field-level diff.
3. If packets are incomplete, fill missing fields from the sidecar when `schema_hash` matches the partially recovered `S0`; otherwise use the sidecar alone and warn.
4. If neither is available, return the data as character columns with a report saying so.

The sidecar's `hash` of the file bytes is checked only when `verify_file = TRUE`, since any row operation legitimately changes it. When it does match, every other check is redundant and the reader says so in one line.

### Writing

`sl_write(df, path, schema = NULL, sidecar = TRUE, ...)` is the one-call entry point: builds the schema from `df` (factors become `categories`, `haven::labelled` becomes code-label categories, `Date` becomes `date`), packetizes, computes redundancy, stripes, appends `_schema` and `_canary`, writes the CSV with `readr::write_csv()` or base `write.csv` (RFC 4180, UTF-8, no BOM, `na = ""`), then writes `datapackage.json` beside it with the file hash. Returns the `sl_schema` object invisibly with the layout summary printed.

## Package architecture

Five layers, each testable alone: schema model, wire codec, layout, canary, I/O. Lower layers never import higher ones. All exported functions use the `sl_` prefix.

### Write path

`df` → `sl_schema()` → `sl_packetize()` → `sl_fragment()` → `sl_redundancy()` + `sl_stripe()` → `sl_canary()` → `sl_write_csv()` + `sl_write_sidecar()`

### Read path

`sl_read_csv()` → read all columns as character → `sl_detect_columns()` → `sl_parse_packets()` → `sl_recover()` → `sl_canary_check()` (raw) → `sl_apply_schema()` → `sl_canary_check()` (typed) → drop `_` columns → data frame + `sl_report`

### Exported functions

| Layer | Function | Role |
| --- | --- | --- |
| schema | `sl_schema(df, ...)` | Build an `sl_schema` from a data frame; honors factors, `labelled`, `Date`, `POSIXct`, integer-vs-double, and user overrides |
| schema | `sl_schema_from_frictionless(json)`, `sl_schema_to_frictionless(s)` | Lossless conversion both ways for the supported subset |
| schema | `sl_to_readr_spec(s)`, `sl_to_coltypes(s)` | Emit `readr::cols()` and base `colClasses` so users can read without the package |
| codec | `sl_encode_token(x)`, `sl_decode_token(x)` | Percent-encoding with the package's reserved set; space to `+` |
| codec | `sl_crc32(x)` | CRC-32 as 8 lowercase hex over ASCII bytes |
| codec | `sl_packetize(s, mtu)` | Schema to character vector of complete packets, fragmented |
| codec | `sl_fragment(attrs, mtu, overhead)` | First-fit splitter |
| codec | `sl_parse_packets(x)` | Character vector to tibble of `type, index, frag, nfrag, total, payload, crc_ok` |
| codec | `sl_recover(parsed)` | Dedupe, conflict check, completeness, reassembly, whole-hash verify; returns `sl_recovery` |
| layout | `sl_copies(P, f, eps)`, `sl_redundancy(P, N, f, eps, mtu, packet_len)`, `sl_survival(P, N, c, p, f)` | The math |
| layout | `sl_stripe(P, N, c, p)` | Rotating stripe assignment |
| layout | `sl_lay(packets, N, c, p)` | Materialize stripe into `N` × `c` character columns |
| canary | `sl_canary_sample(x, k)` | Purposeful value sampler, one variable |
| canary | `sl_canary(df, k)` | Canary packets for all variables |
| canary | `sl_canary_check(raw_df, canaries, typed_df = NULL)` | Verification and diagnosis |
| io | `sl_write(df, path, ...)` | One-call writer |
| io | `sl_write_csv()`, `sl_write_sidecar()` | Pieces of the above |
| io | `sl_read_csv(path, sidecar, keep_meta = FALSE, apply = TRUE)` | One-call reader |
| io | `sl_apply_schema(df, s)` | Types, factors, NA codes onto a character data frame |
| io | `sl_detect_columns(df)` | Find packet columns by regex regardless of header |
| report | `sl_report(x)`, `print.sl_recovery`, `print.sl_report` | Human-readable status |
| test | `sl_corrupt_*()` family | Corruption simulators, exported because users want them too |

### S3 classes

- `sl_schema`: list of `fields` (each a list of Frictionless-named properties), `table` (pk, fk, fieldsMatch), `meta` (enc, dialect, rows). Methods: `print`, `as.list`, `format` (the wire text), `digest` (canonical hash).
- `sl_packets`: character vector with attributes `P`, `mtu`, `type`.
- `sl_recovery`: `status` (`verified`, `conflict`, `incomplete`, `absent`), `schema` (possibly partial), `missing` indices, `conflicts` (index, payloads), `dropped_crc` count, `source` (`inband`, `sidecar`, `merged`).
- `sl_report`: per-variable canary table plus the recovery object; `print` gives the one-line summary and a table.

### Dependencies

Keep Imports minimal so the package is easy to vendor: `jsonlite` (sidecar), `digest` (CRC-32 and SHA-1), `utils`. Suggests: `readr`, `data.table`, `frictionless`, `haven`, `testthat`, `knitr`. Base `read.csv(colClasses = "character")` is the default reader so the read path has no hard dependency; `readr` is used when installed.

### Repository layout

```
schemaless/
  DESCRIPTION  NAMESPACE  LICENSE  README.Rmd
  R/
    constants.R       # separators, MTU default, regexes, wire version
    schema.R          # sl_schema, frictionless conversion, readr spec
    encode.R          # percent-encoding, crc32
    packetize.R       # sl_packetize, sl_fragment
    parse.R           # sl_parse_packets, sl_recover
    layout.R          # sl_copies, sl_redundancy, sl_survival, sl_stripe, sl_lay
    canary.R          # sampler, canary packets, check
    io_write.R        # sl_write, sl_write_csv, sl_write_sidecar
    io_read.R         # sl_read_csv, sl_detect_columns, sl_apply_schema
    report.R          # classes, print methods, sl_report
    corrupt.R         # sl_corrupt_* simulators
  inst/
    specs/wire-format.md        # normative spec, generated from this plan
    compat/                     # fixture CSVs and the matrix results
  tests/testthat/
  vignettes/
    schemaless.Rmd              # quick start
    corruption.Rmd              # round-trip demos through simulators
    design.Rmd                  # the math and the protocol analogy
```

## Compatibility matrix

The matrix is what makes the format trustworthy: one fixture file round-tripped through every common reader and writer, with recovery and canary results recorded per tool. It ships in `inst/compat/` and is reproduced in the README.

### Fixture

`inst/compat/fixture.csv`: 2,000 rows, 12 fields chosen to trip every detector (a 9-digit zero-padded ID, a 17-digit ID, gene-style names, a euro-priced column, a date column, an ordered factor with 6 levels, a nominal factor with 40 levels to force fragmentation, a column with `-9`/`-8` sentinels, a free-text column with quotes, commas and newlines). Written with `c = 1, p = 1, f = 0.2`.

### Procedure per tool

1. Open `fixture.csv` in the tool with default settings.
2. Save or export back to CSV with default settings as `fixture.<tool>.csv`.
3. Run `sl_read_csv()` on the result; record the recovery status, dropped-CRC count, and per-variable canary diagnosis.
4. Also record what the tool did to the *data* columns, from the canary report, because that is what users want to know about the tool.

Automated in CI where the tool is scriptable; manual with a recorded checklist otherwise.

### Tools

| Tool | Scriptable | Columns to record |
| --- | --- | --- |
| R `read.csv` / `write.csv` | yes | schema recovered, canaries, data damage |
| R `readr` | yes |  |
| R `data.table::fread/fwrite` | yes |  |
| R `arrow::read_csv_arrow` | yes |  |
| R `vroom` | yes |  |
| Python `csv` module | yes |  |
| pandas `read_csv` / `to_csv` | yes |  |
| Polars | yes |  |
| DuckDB `read_csv_auto` / `COPY` | yes |  |
| SQLite `.import` / `.mode csv` | yes |  |
| PostgreSQL `COPY` | yes, Docker |  |
| `awk` / `cut` / `sort` | yes | strided and contiguous subsets |
| Stata `import delimited` / `export delimited` | if licensed | 2,045 string limit |
| SAS `PROC IMPORT` | if licensed | 200-char default |
| SPSS `GET DATA` | if licensed |  |
| Excel for Windows, en-US | manual |  |
| Excel for Windows, de-DE (`;` delimiter) | manual |  |
| Excel for Mac | manual |  |
| Google Sheets import/export | manual |  |
| LibreOffice Calc | manual |  |
| Apple Numbers | manual |  |
| Notepad / TextEdit resave | manual | encoding, BOM |
| Gmail attach and download | manual | transport |

### Result table shape

One row per tool with columns: `tool`, `version`, `date`, `schema_status` (verified / incomplete / conflict / absent), `packets_dropped`, `fragments_dropped`, `vars_intact`, `vars_corrupted`, `damage_types` (semicolon list from the diagnosis), `notes`. Stored as `inst/compat/results.csv`, itself written with `sl_write()`.

## Testing: corruption simulators and test plan

The simulators are the heart of the test suite and a user-facing feature: each one applies a named corruption to a CSV (as text or as a data frame) so that `sl_read_csv()` can be shown recovering from it. Every vector in the threat model has a simulator; every simulator has a test asserting the documented outcome.

### Simulator family

| Function | Operates on | What it does |
| --- | --- | --- |
| `sl_corrupt_rows(x, keep, mode)` | data frame | Drop rows: `random` fraction, `head`/`tail`/`block` contiguous, `stride` every k-th, `shuffle`, `duplicate` |
| `sl_corrupt_columns(x, drop, split_on)` | data frame | Drop named columns; split a column on a character (Text-to-Columns) |
| `sl_corrupt_header(x, mode)` | data frame | Remove header or rename to `V1..Vn` |
| `sl_corrupt_excel(x)` | data frame | Strip leading zeros from digit strings; round numerics to 15 sig figs and format large ones as `1.23E+15`; convert `SEPT1`, `1/12`, `3-4` to dates; evaluate nothing but prefix `=`-cells with `#NAME?`; trim whitespace |
| `sl_corrupt_encoding(text, from, to)` | raw text | Re-encode UTF-8 as Windows-1252 and back (mojibake); NFC to NFD |
| `sl_corrupt_bom(text)` | raw text | Prepend UTF-8 BOM |
| `sl_corrupt_delimiter(text, to)` | raw text | Rewrite delimiter to `;`, tab, or pipe with dialect-correct requoting |
| `sl_corrupt_smartquotes(text)` | raw text | Straight to curly quotes, `--` to em dash |
| `sl_corrupt_whitespace(text, mode)` | raw text | Trim, pad, spaces to U+00A0 |
| `sl_corrupt_truncate(x, n)` | data frame | Truncate every cell to `n` characters |
| `sl_corrupt_case(x, mode)` | data frame | Upper, lower, title case |
| `sl_corrupt_merge(a, b)` | two data frames | `rbind` two files with different schemas |
| `sl_corrupt_eol(text, mode)` | raw text | CRLF/LF swap, drop trailing newline |
| `sl_corrupt_replace(x, pattern, replacement)` | data frame | Global find-and-replace across all cells |
| `sl_corrupt_invisible(text)` | raw text | Insert zero-width spaces and soft hyphens at random |

Each returns the corrupted object plus an attribute recording what was done, so tests and vignettes can print "applied: rows(stride=20); excel()".

### Unit tests by layer

- **encode**: percent-encoding round-trips every byte 0-255 and every reserved separator; CRC-32 matches known vectors (`"123456789"` → `cbf43926`).
- **packetize/parse**: every packet matches the grammar regex; parse(packetize(s)) recovers `s` exactly for schemas with 1, 7, 50, and 500 fields; fragmentation at MTU 60, 200, 1000 yields identical reassembled payloads and identical whole-schema hashes; a token longer than MTU errors with the documented message.
- **recover**: missing last packet is reported as incomplete, not verified; two valid payloads for one index report `conflict`; a packet with one flipped character is dropped and counted; duplicates collapse.
- **layout**: `sl_copies()` matches the table in this document to the integer; `sl_stripe()` satisfies both guarantees (any `P/p` consecutive rows, any stride `k < N/P`) by exhaustive check on small `P, N`; `sl_survival()` agrees with a Monte Carlo of 10,000 random retentions to within sampling error.
- **canary**: each detector selects its target value from a constructed column; `sl_corrupt_excel()` on the fixture produces exactly the diagnoses expected per variable; the two-level check attributes damage to the reader when `apply = TRUE` with a deliberately wrong type.
- **io**: `sl_read_csv(sl_write(df))` is identical to `df` for a data frame with every supported column class; a file with `_schema` deleted returns character columns and `status = absent`; sidecar-only and in-band-only reads agree; a stale sidecar triggers the diff warning.
- **end-to-end**: for every simulator, with the fixture written at `f = 0.2`, assert the documented recovery status; for `sl_corrupt_rows(keep = 0.2, mode = "random")` repeat 200 times and assert the empirical failure rate is below `eps` with margin.

### Property tests

Use `hedgehog` or a small hand-rolled generator: random schemas (field counts 1-100, random level counts 0-80, random label strings including non-ASCII and reserved characters) must round-trip through packetize/parse at random MTUs in 60-2000. This is where separator and escaping bugs surface.

## Build order for the agent

Work bottom-up so every layer has passing tests before the next depends on it. Each milestone ends with `devtools::check()` clean and a short NEWS entry.

1. **Skeleton.** `usethis::create_package("schemaless")`, MIT license, `constants.R` with every separator, regex, default and wire version in one place, `testthat` set up, GitHub Actions `R-CMD-check`.
2. **Codec.** `encode.R`: percent-encoding with the reserved set, `+` for space, `sl_crc32()` via `digest`. Tests against known vectors. Nothing else may touch encoding directly.
3. **Schema model.** `schema.R`: `sl_schema()` from data frames (factor, ordered, `labelled`, `Date`, `POSIXct`, integer, double, logical, character), Frictionless import/export, `sl_to_readr_spec()`. Canonical text and hash defined here.
4. **Packetize and parse.** `packetize.R`, `parse.R`: packets, fragmentation, parsing, `sl_recover()` with all four statuses. Property tests for round-trips.
5. **Layout.** `layout.R`: the math, `sl_stripe()` with both guarantees tested exhaustively on small cases, Monte Carlo agreement test.
6. **I/O without canaries.** `io_write.R`, `io_read.R`: `sl_write()`, `sl_read_csv()`, column detection, schema application, sidecar write and read with cross-hashes. First end-to-end round-trip test.
7. **Simulators.** `corrupt.R`: the full family. Threat-model tests: one per simulator asserting the documented outcome.
8. **Canary.** `canary.R`: sampler, packets, two-level check with diagnosis. Wire canaries into write and read paths; extend the end-to-end tests.
9. **Reporting.** `report.R`: classes, `print` methods, `sl_report()`. Make the one-line summary good; it is what users see first.
10. **Compatibility fixture and automated matrix.** Generate `fixture.csv`; script the R, Python, DuckDB, SQLite and shell rows; write `results.csv` and the README table. Leave manual rows marked "not yet tested".
11. **Spec and vignettes.** `inst/specs/wire-format.md` as a normative document independent of R (another language could implement it); three vignettes; pkgdown site.
12. **Review pass.** Rename, tighten the API, decide the open questions below, tag v0.1.0.

### Open decisions

| Decision | Default in this plan | Alternatives | Decide by |
| --- | --- | --- | --- |
| Separator set | `~ ^ ! = :` | `\|` for parts (more readable, but a PSV delimiter); `;` for lists (readable, but a CSV delimiter in European locales) | milestone 4 |
| Wrapper | `{{ }}` | `[[ ]]` avoids Jinja/Mustache expansion in templating pipelines | milestone 2 |
| Hash for whole schema | SHA-1 truncated to 12 hex | CRC-32 (shorter, weaker), SHA-256 | milestone 3 |
| Conflict resolution when sidecar and in-band disagree | prefer in-band, warn, show diff | prefer sidecar; refuse and require the user to choose | milestone 6 |
| Canary sample size `k` | 6 per variable | scale with `nd`; cap total canary bytes per row | milestone 8 |
| Store codes or labels for nominal factors | labels when every label is short and ASCII, else codes with `lev=code:label` | always codes; user flag only | milestone 3 |
| Package name | `schemaless` | check CRAN and GitHub for collisions before milestone 1 | milestone 1 |
| Erasure-coded packet type `E` | reserved, not built | build LT codes in v0.2 if the compatibility matrix shows row loss beyond what repetition handles | after v0.1 |

### Definition of done for v0.1.0

- A data frame with every supported column class round-trips through `sl_write()` and `sl_read_csv()` unchanged.
- Every simulator in the threat model has a passing test with the documented outcome.
- The fixture survives all scriptable tools in the compatibility matrix with schema status `verified`, and the canary report correctly names the damage each tool inflicts on the data columns.
- The wire-format spec is complete enough that a Python implementation could be written from it alone.
- `R CMD check` passes with no notes on the three major platforms.
