# csvschema wire format, version 1

This is the normative specification of the csvschema wire format. It is
independent of the R implementation: a conforming reader or writer can be
written in any language from this document alone. The R package `csvschema` is
the reference implementation.

Key words **MUST**, **MUST NOT**, **SHOULD**, and **MAY** are used in the sense
of RFC 2119.

## 1. Overview

A csvschema file is an ordinary CSV file with one or more extra character
columns that carry the table's schema, and optionally extra columns that carry
a corruption *canary*. The schema is cut into small, self-contained, pure-ASCII
**packets** that are repeated and spread across the rows, so the schema can be
rebuilt from any sufficiently large surviving subset of rows and verified
against a whole-schema hash.

The design assumes a hostile, one-way channel (any CSV dialect, any locale, any
spreadsheet, any editor) and borrows three mechanisms from internet protocols:
fragmentation metadata, per-piece integrity (a CRC per packet), and
whole-object verification (a hash over the reassembled schema).

The canonical schema model is **Frictionless Table Schema v2**. This format
specifies a wire *encoding* of that model, not a new schema language.

## 2. Character model and token encoding

All packets are pure ASCII. A **token** is a string of data (a field name, a
value, a label) encoded so that it contains no CSV delimiter, no quote, no
whitespace, and none of the format's separator or wrapper characters.

Encoding a token, byte by byte over its UTF-8 representation:

* A space (U+0020) **MUST** be encoded as `+`.
* A byte whose character is in the **unreserved set** **MUST** be left literal.
  The unreserved set is the ASCII letters `A`–`Z` and `a`–`z`, the digits `0`–
  `9`, and the four marks `_` `-` `.` `(` `)`.
* Every other byte **MUST** be encoded as `%` followed by its two uppercase
  hexadecimal digits.

Decoding reverses this: `+` becomes a space, each `%XX` becomes the byte with
that value, and the resulting byte string is interpreted as UTF-8. A reader
**MUST NOT** percent-decode a packet's contents until that packet's CRC has been
verified (Section 5).

Because `+`, `%`, and every reserved character are either encoded or reserved,
an encoded token can contain only the unreserved set, `+`, and `%`.

## 3. Separators and wrapper

The format uses a fixed set of single-character separators, chosen because none
is a CSV delimiter in any common dialect, none triggers spreadsheet value
coercion, and none is a default Text-to-Columns split character. Inside a token
each of these is reserved and therefore percent-encoded.

| Role | Character |
| --- | --- |
| Packet wrapper, open / close | `{{` / `}}` |
| Part separator (id, payload, crc) | `~` |
| Attribute separator | `^` |
| List-item separator | `!` |
| Key–value separator | `=` |
| Code–label separator | `:` |
| Fragment separator (in id) | `.` |
| Packet-total separator (in id) | `/` |
| Space, inside a token | `+` |

## 4. Packet structure

A packet is a single CSV token of the form:

```
{{ <id> ~ <payload> ~ <crc> }}
```

with no spaces; the spaces above are only for readability. A packet **MUST NOT**
exceed the MTU (Section 10) in length, including the braces.

### 4.1 Grammar

```
packet   = "{{" id "~" payload "~" crc "}}"
id       = type index [ "." frag "of" nfrag ] "/" total
type     = "S" / "C"            ; S = schema, C = canary; "E" reserved
index    = 1*DIGIT              ; 0 = header packet
frag     = 1*DIGIT              ; present only when fragmented
nfrag    = 1*DIGIT
total    = 1*DIGIT              ; number of distinct indices of this type
payload  = [ attr *( "^" attr ) ]
attr     = key [ "=" value ] / bareword
value    = item *( "!" item )
item     = token / code ":" token
crc      = 8HEXDIG              ; lowercase on write
```

The `id` and the `crc` contain no `~`, and the `payload` contains no `~`, `{`,
or `}` (a literal `~` in data is percent-encoded). A reader locating packets
**MUST** therefore be able to find each packet by its brace pair even when
several packets are concatenated in one cell, e.g. `{{...}}{{...}}`.

Parsing is case-insensitive for the `id`, the `crc`, and attribute keys; a
reader **MUST** lowercase them before interpreting. Token *values* keep their
case, which the CRC protects.

### 4.2 Identifiers

* `type` is `S` for schema packets and `C` for canary packets. `E` is reserved
  for a future erasure-coded packet type and **MUST NOT** be emitted by a
  version-1 writer.
* `index` 0 is the header. Indices `1 … total-1` are content packets.
* `total` is the number of distinct indices of this type, **including** the
  header. It is carried in every packet (rather than a last-packet flag) so the
  loss of the highest-indexed packet is still detectable.
* When a payload is fragmented, each fragment carries `.frag "of" nfrag`; `frag`
  runs `1 … nfrag`. Fragments share one `index` and do **not** change `total`.

## 5. Per-packet integrity: CRC-32

Every packet ends with a CRC-32 over the ASCII bytes of `id "~" payload` (the
text between the opening `{{` and the final `~crc}}`, i.e. excluding the braces
and the CRC itself). It is written as exactly 8 lowercase hexadecimal digits.

The CRC-32 is the standard ISO-HDLC / zlib CRC-32 (polynomial 0xEDB88320).
Conformance vector: the CRC-32 of the ASCII string `123456789` is `cbf43926`.

On read, a packet whose recomputed CRC does not equal its stated CRC
(compared case-insensitively) **MUST** be discarded, exactly as if its row had
been deleted. A reader **MUST NOT** attempt to repair a packet.

## 6. Header packet (index 0)

The header payload is a sequence of `key=value` attributes:

| Key | Meaning |
| --- | --- |
| `cs` | wire-format version (`1`) |
| `enc` | intended encoding of the data columns (e.g. `utf-8`) |
| `dialect` | CSV dialect name (e.g. `rfc4180`) |
| `fields` | number of data fields (excludes the added columns) |
| `rows` | row count at write time |
| `mtu` | the MTU used, so a reader can explain truncation |
| `hash` | first 12 hex of the whole-schema hash (Section 9) |
| `side` | sidecar filename or URL (optional) |
| `sidehash` | first 8 hex of the canonical sidecar hash (optional) |

`enc`, `dialect`, and `side` values are tokens (percent-encoded). `cs`,
`fields`, `rows`, `mtu`, `hash`, and `sidehash` are literal (digits or hex).

## 7. Field packets and the table packet

Content packets `1 … total-2` describe fields in column order. The last content
packet, index `total-1`, is the **table packet** and is always present (even
when empty) so the completeness check needs no special case.

### 7.1 Field attributes

The first two attributes of a field payload are barewords: the field **name**,
then its **type**. Remaining attributes follow in this canonical order (absent
attributes are simply omitted): `fmt`, `na`, `nalab`, `lev`, `ord`, `pat`,
`uniq`, `req`, `min`, `max`, `lab`, `desc`.

| Key | Frictionless property | Notes |
| --- | --- | --- |
| 1st bareword | `name` | encoded token |
| 2nd bareword | `type` | `str` `int` `num` `bool` `date` `datetime` `year` |
| `fmt` | `format` | e.g. `fmt=%25Y-%25m-%25d` |
| `na` | `missingValues` | item list; omitted when it is just `[""]` |
| `nalab` | labelled missingness | `code:label` items |
| `lev` | `categories` | bare `label` items, or `code:label` items |
| `ord` | `categoriesOrdered` | bareword |
| `pat` | `constraints.pattern` | encoded token |
| `uniq` | `constraints.unique` | bareword |
| `req` | `constraints.required` | bareword |
| `min` / `max` | `constraints.minimum/maximum` | e.g. `min=0` |
| `lab` | `title` | encoded token |
| `desc` | `description` | encoded token |

A reader **MUST** preserve, and pass through, attribute keys it does not
recognize, so that a newer writer stays readable by an older reader.

Type codes map to Frictionless types as: `str`=string, `int`=integer,
`num`=number, `bool`=boolean, `date`=date, `datetime`=datetime, `year`=year.

### 7.2 Table packet

The table payload carries table-level properties as `key=value` attributes:
`pk` (primary-key field list), `fk` (foreign keys, each `field:resource.field`),
and `fm` (Frictionless `fieldsMatch`). Any may be absent; an all-absent table
payload is the empty string.

## 8. Canary packets (type C)

Canary packets use the same envelope with `type = C` and an independent
numbering (`C0 … C(total-1)`). Index 0 is a canary header
(`cs=1^vars=<n>^recipe=1`). Content packet *i* describes data column *i*:

| Key | Meaning |
| --- | --- |
| 1st bareword | variable name (encoded) |
| `n` | row count at write time |
| `na` | count of missing values |
| `nd` | count of distinct values |
| `fp` | fingerprint: first 8 hex of SHA-1 over the sorted distinct raw strings of the column (NA normalized to the empty string) |
| `v` | sampled values, encoded, in the exact string form written to the CSV |

### 8.1 Sampling recipe (version 1)

The writer **SHOULD** choose up to *k* (default 6) sample values per column by
trying these detectors in order and taking the first match not already chosen,
then adding the longest and shortest strings and the numeric minimum and
maximum, then filling any remainder deterministically from the remaining
distinct values: leading zero; long digit string (> 15 digits); date-like;
time-like; scientific/decimal-edge; formula (`= + - @` first); non-ASCII;
leading/trailing whitespace; schema missing-value sentinels; boolean-like.

### 8.2 Verification

A reader checks each sampled value against the raw text of its column (every
column read as character, before type conversion), and recomputes `fp`:

* `fp` matches → **intact**.
* `fp` differs but every sample is still present → **rows changed, values
  intact** (expected after row loss or filtering).
* at least one sample absent → **corrupted**; each absent value is classified by
  the same detectors so the damage is named.
* variable or canary packets missing → **unverifiable**.

A reader **MAY** repeat the check on re-serialized typed values; a value present
in the raw check but absent in the typed check indicates reader-induced damage,
not file damage.

## 9. Whole-schema hash

The **canonical schema text** is the field payloads (indices `1 … total-2`) and
the table payload (index `total-1`), each rendered in canonical form (Section
7.1 order, lists whole), joined by a single `\n` in index order. The header
payload is excluded.

The whole-schema hash is SHA-1 over the UTF-8 bytes of the canonical schema
text; the header carries its first 12 hex digits in `hash`. Because the hash is
over the reassembled canonical payloads, not over the fragments, refragmenting
the same schema at a different MTU does not change it.

After reassembly a reader recomputes the hash and compares. A mismatch means
version mixing (two different schemas were bound together, or a field was edited
in only some copies) and **MUST** be reported as a conflict, not silently
accepted.

## 10. Fragmentation

A writer **MUST NOT** emit a packet longer than the MTU (default 200
characters, including braces). A payload that would exceed the MTU is split into
fragments that are themselves complete packets:

* Fragment ids are `type index "." frag "of" nfrag "/" total`.
* Fragment 1 **MUST** carry the field `name` and `type`, so a partially
  recovered field is still identifiable.
* A list-valued attribute (`lev`, `na`, `nalab`, and `pk`/`fk` for the table
  packet) **MAY** be split at item boundaries; on reassembly the lists are
  concatenated in fragment order. Every other attribute appears whole in exactly
  one fragment.
* A single token that, with packet overhead, exceeds the MTU **MUST** cause a
  write-time error; it **MUST NOT** be split mid-token or mid-escape.
* Splitting **MUST** be deterministic (first-fit over the canonical attribute
  order), so the same schema at the same MTU always yields byte-identical
  packets.

Fragments count as separate packets for redundancy and striping.

## 11. Redundancy

Let *P* be the number of distinct packets to place (envelopes, after
fragmentation), *N* the number of rows, and *f* the fraction of rows the layout
is designed to survive at random. Repetition coding makes survival a
coupon-collector problem. The minimum copies per packet is

```
r = ceil( ln(P / eps) / -ln(1 - f) )
```

for a target per-packet loss probability `eps`. The achieved probability that
all *P* packets survive, given *r* effective copies each, is `(1 - (1-f)^r)^P`.

A layout is a number of schema columns *c* and packets per cell *p* with
`p * c * N / P >= r`, subject to `p × (packet length) <= MTU`. A writer
**SHOULD** prefer larger *p* (invisible) over larger *c* (an added column).

## 12. Striping and column placement

Added columns are named `_schema`, `_schema2`, … and `_canary`, `_canary2`, …
All begin with `_` and **MUST** be documented as ignorable; a reader that drops
them loses nothing but those character columns.

Packets are placed by a deterministic rotating stripe. With packets numbered
`0 … P-1`, row *i* (0-based) in block `b = floor(i / P)`, and column *j*
(0-based) with offset `floor(j * P / c)`, the base index is

```
base(i, j) = ( i + b + floor(j * P / c) ) mod P
```

and the cell holds the *p* consecutive indices `(base + 0 … p-1) mod P`,
concatenated as packet tokens.

This stripe guarantees that the first *P* rows contain every packet (so a
prefix / `head()` recovers), that any `2P − 1` consecutive rows do, that a full
read does, and that the systematic every-*P*-th-row sample cycles through all
packets. A single period-*P* stripe cannot additionally guarantee every
arbitrary strided sample in its first *P* terms — that is incompatible with the
contiguous guarantee — so heavy arbitrary strides rely on the redundancy *r*.

## 13. Reading and recovery

A reader **MUST**:

1. Read every column as character text.
2. Reduce each candidate cell to printable ASCII (`0x21`–`0x7E`), which removes
   BOMs, invisible characters, control characters, and all whitespace. Locate
   packet-bearing columns by content (a cell matching `{{[SsCc][0-9]`), never by
   header.
3. Extract every packet by its brace pair and verify its CRC; discard failures.
4. Deduplicate identical copies. If two *different* payloads verify for the same
   `(index, frag)`, record a **conflict**.
5. Reassemble each index from its fragments in order.
6. Determine completeness against `total` and `nfrag`.
7. For schema packets, rebuild the schema, recompute the whole-schema hash, and
   compare to the header.

Recovery status is exactly one of:

* **verified** — complete and the hash matches;
* **conflict** — two differing valid payloads at one index, or a hash mismatch;
* **incomplete** — some index or fragment missing;
* **absent** — no usable packets of this type.

A reader **MUST NOT** silently repair data; it reports what was recovered, what
is missing, what conflicts, and which variables fail their canaries and why.

## 14. Sidecar

A writer **MAY** also emit a Frictionless `datapackage.json` (Data Package v2,
Table Schema v2) with one resource per CSV. The resource carries `path`,
`dialect`, `schema`, a `hash` of the CSV file bytes as `sha1:<hex>`, and a
`csvschema` extension object with `wire_version`, `mtu`, the added column names,
`c`, `p`, a redundancy sentence, and `schema_hash` (equal to the header `hash`).

The in-band packets and the sidecar authenticate each other: the header's
`side`/`sidehash` point to the sidecar, and the sidecar's `schema_hash` equals
the whole-schema hash. Neither is required for the other to work. The sidecar's
file-byte `hash` is checked only on request, since any row operation changes it.

Canonical sidecar JSON for hashing: keys sorted recursively, no insignificant
whitespace, UTF-8.

## 15. Conformance and limits

A version-1 reader **MUST** accept any version-1 file, preserve unknown
attribute keys, and never emit the reserved `E` type. Two vectors cannot be
mitigated in band and **MUST** be documented: deletion of every schema column,
and bit-level damage to a compressed container. Case-folding every cell is
detected (folded payloads fail their CRC), not recovered. With the default
`missingValues = [""]`, an empty cell and `NA` are indistinguishable once
written with `na = ""`.
