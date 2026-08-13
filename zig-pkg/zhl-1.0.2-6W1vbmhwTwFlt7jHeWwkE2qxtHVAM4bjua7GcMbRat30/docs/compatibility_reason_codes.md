# Compatibility Reason Codes

Phase 0 reason codes classify compatibility results without promising full
ecosystem coverage.

## Schema

Reason codes are stable strings:

```text
ZHL-COMPAT-<AREA>-<NNN>
```

- `AREA` is `TEXTMATE`, `SUBLIME`, `ONIG`, or `BENCH`.
- `NNN` is a zero-padded decimal number.
- Once published, a code's meaning does not change. Add a new code when the
  reason changes.
- Reason details may include source file, grammar name, pattern, fixture, and
  oracle, but those details are not part of the stable code.

## Result States

| state | meaning |
| --- | --- |
| `supported` | Input converts, compiles, packs, or matches the selected oracle within the documented corpus. |
| `accepted-divergence` | Behavior differs from an oracle by design or by a documented oracle limitation. |
| `oracle-skipped` | Case is not checked against that oracle because the oracle cannot represent or reliably report it. |
| `unsupported` | Input is valid upstream syntax but is rejected by zhl with a deterministic diagnostic. |

## Initial Codes

| code | state | reason |
| --- | --- | --- |
| `ZHL-COMPAT-TEXTMATE-001` | `supported` | Checked-in TextMate JSON/plist corpus and listed external fixtures convert offline with `missing=0`, `external_missing=0`, and executable `skipped=0`. Broader ecosystem coverage is not implied. |
| `ZHL-COMPAT-TEXTMATE-002` | `unsupported` | Runtime TextMate interpretation is intentionally absent; TextMate JSON/plist support is offline import/report/convert/pack only. |
| `ZHL-COMPAT-SUBLIME-001` | `supported` | Current Sublime fixture and packaged corpus subset converts offline with executable `skipped=0`. Full public Sublime ecosystem coverage is not implied. |
| `ZHL-COMPAT-ONIG-001` | `supported` | Current regex VM coverage includes checked-in grammar patterns, focused compatibility tests, and checked Oniguruma conformance rows. Full Oniguruma behavior matrix is not implied. |
| `ZHL-COMPAT-ONIG-002` | `oracle-skipped` | Shiki Oniguruma oracle skips regex-condition rows: `(?(?=a)yes\|no)`, `(?(?<=a)b\|c)`, and `(?(?<!a)b\|c)`. |
| `ZHL-COMPAT-ONIG-003` | `oracle-skipped` | Shiki Oniguruma oracle skips scalar-sequence escape row: `\x{41 42}{2}`. |
| `ZHL-COMPAT-ONIG-004` | `oracle-skipped` | Shiki Oniguruma oracle skips six bounded possessive-repeat rows across `a{2,3}+b`, `a{,2}+a`, and `a{2,3}+a`; bounded-plus behavior is covered by Zig tests and the native `onig` skipped-case checker. |
| `ZHL-COMPAT-ONIG-005` | `unsupported` | Oniguruma callout/callback syntaxes are rejected instead of implemented: PCRE-style `(?C...)`, interpolation-style `(?{...})`, and named `(*name...)` forms. |
| `ZHL-COMPAT-BENCH-001` | `supported` | Current P0 benchmark gate is valid for checked fixtures, but several first-pass rows still use committed fixtures instead of licensed external or repo-owned real-world snippets. |
