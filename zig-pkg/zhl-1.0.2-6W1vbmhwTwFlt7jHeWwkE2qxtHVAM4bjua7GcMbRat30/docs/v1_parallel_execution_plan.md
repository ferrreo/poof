# v1 Parallel Execution Plan

This plan is based on the current repository state, not on desired status.
`docs/v1_status.md` remains the source of evidence. This file is the remaining
work breakdown to make a defensible v1 claim.

## Current Evidence Snapshot

- Hand-written native `.zhl` grammars: Bash, C, C++, C#, CSS, Go, HTML, Java,
  JavaScript, JSX, JSON, Kotlin, Markdown, PHP, Python, Ruby, Rust, SQL, Swift,
  TOML, TSX, TypeScript, XML, YAML, Zig 0.16.
- Checked TextMate JSON grammars: 271, with generated `.zhlb` packs.
- Checked Sublime source syntaxes: 113 syntaxes split across 212 chunks, with
  generated `.zhlb` packs.
- Current v1 gate shape: `zig build check-v1 -Doptimize=ReleaseFast` aggregates
  build, tests, visual/differential checks, Shiki ecosystem conversion,
  Oniguruma cases, native/WASM benchmark gates, Tree-sitter parser-backed
  overlay proof, and benchmark comparisons.
- Current open status by `docs/v1_status.md`: TextMate, Sublime, and Oniguruma
  compatibility are still corpus-bounded, not ecosystem-complete.
- Current Oniguruma conformance gate shape: 1324 Zig table rows plus 4 generated
  long-repeat rows, with 1318 rows checked by Shiki and 10 explicitly skipped.
- Tree-sitter support includes a dependency-free overlay adapter API plus a
  benchmark/dev JavaScript parser-backed proof route.

## Execution Update - 2026-07-03

Completed in commit `ee2095c` and merged to `main`:

- G0.2 CSS, G0.7 Go, G0.12 SQL, and G0.13 XML native grammars, packs,
  generated Zig modules, fixtures, registry wiring, visual routes, and
  differential routes.
- Go raw multiline strings are stateful.
- SQL and XML no longer rely on smoke-only visual/differential carve-outs; full
  visual coverage and differential checks run with the other native routes.
- The registered `zhlc --grammar sql/xml` routes no longer crash in the
  installed ReleaseFast CLI.
- R4.5/R4.9 narrow callout/unsupported syntax coverage: unsupported Oniguruma
  callout spellings are rejected and covered by tests.
- Regex VM stack-risk cleanup for simple non-capturing repeats, native
  regex-start guarding, and CLI heap-backed native dump buffers.
- T5.1/T5.3/T5.6 adapter-level Tree-sitter overlay proof updates: optional
  dependency ownership documented, overlay boundary tests added, and docs
  refreshed.

Verified after the merge worktree implementation:

- `zig build test --summary all`
- `zig build check-diff-native -Doptimize=ReleaseFast --summary all`
- `zig build check-visual -Doptimize=ReleaseFast --summary all`
- `zig build check-oniguruma-cases --summary all`
- `sh tools/check_corpus_counts.sh`
- `sh tools/check_release_docs.sh`
- `sh tools/check_integrations.sh all ./zig-out/bin/zhlc`
- Fresh compile/pack comparisons for CSS, Go, SQL, and XML.

Still not complete for full v1:

- Remaining P0 native grammars: none for first-pass native route coverage; the
  new HTML, Markdown, C++, C#, Java, PHP, Ruby, Swift, Kotlin, JSX, and TSX
  routes are still intentionally shallow and need embedded/interpolation/fence
  infrastructure hardening before a quality-complete v1 claim.
- Embedded language states, interpolation, generic regex literal handling,
  annotation rules, here-doc/raw-string generalization, and Markdown fence
  routing remain open.
- Final `zig build check-v1 -Doptimize=ReleaseFast --summary all` has been run
  clean after the first-pass P0 native route and Tree-sitter proof expansion,
  but it is not a whole plan completion proof while deeper regex evidence and
  P0 quality hardening remain open.

## V1 Definition

V1 is done only when all of these are true:

- Runtime stays native Zig and data-driven: no language-specific engine logic.
- Major languages have high-quality hand-written `.zhl` grammars.
- Niche and long-tail languages can be generated from TextMate/Sublime sources.
- TextMate and Sublime support is offline import/report/convert/pack only.
- No runtime TextMate interpreter exists.
- Optional Tree-sitter path has real parser-backed integration proof.
- Regex VM has broad Oniguruma behavior evidence, with skipped-oracle cases
  clearly explained.
- Visual, differential, integration, benchmark, WASM, docs, public API, runtime
  boundary, license, file-line, and corpus gates all pass from a clean tree.

## Global Rules

- Keep every non-test file under 750 lines.
- Add no `regex_special_*` or language-specific runtime branches.
- Prefer improving generic grammar features, regex features, or conversion rules
  over adding per-language code.
- Every grammar task adds fixtures, differential checks, and visual coverage
  where the language is user-facing.
- Every converter task proves `missing=0`, `external_missing=0`, and
  `skipped=0` for its target corpus.
- Every benchmark task reports setup, hot path, total allocations, memory, and
  throughput where the harness can measure them.

## Parallel Track 0: Cleanup And Baseline

These tasks block final v1 validation. Do them before broad parallel work.

| id | task | output | acceptance |
|---|---|---|---|
| T0.1 | Confirm clean baseline | No parent-thread leftovers or stale generated outputs | `git status --short` clean or only intended docs |
| T0.2 | Re-run focused baseline | Fresh baseline notes in `docs/v1_status.md` if counts changed | complete 2026-07-03 |
| T0.3 | Re-run full local baseline | Known starting point for parallel work | complete 2026-07-03 |
| T0.4 | Freeze task board | IDs in this plan updated as complete/blocked | complete 2026-07-03 |

## Parallel Track 1: Hand-Written Major `.zhl` Grammars

Goal: hand-written native grammars for major languages. Existing converted packs
remain useful references, but v1 should not rely on conversion for common daily
languages.

Each grammar task follows the same acceptance:

- Add `grammars/<language>.zhl` and matching `.zhlb`.
- Add or update `src/grammars/<language>.zig` only if native checked module is
  part of current project pattern.
- Add fixture snippets covering comments, strings, escapes, keywords, types,
  functions, numbers, operators, interpolation/templates, and nested states.
- Add visual case if language is in the major visual set.
- Add differential case against Shiki or syntect where comparable.
- Run `zig build test --summary all`, `zig build check-diff-native
  -Doptimize=ReleaseFast --summary all`, and `zig build check-visual
  -Doptimize=ReleaseFast --summary all` when visual routes change.

### P0 Native Grammars

These should be hand-written before v1:

| id | language | reason | dependencies |
|---|---|---|---|
| G0.1 | HTML | core web, embedded CSS/JS route proof | embedded grammar state support |
| G0.2 | CSS | core web, selectors/at-rules/string/url coverage | complete 2026-07-03 |
| G0.3 | Markdown | docs ecosystem, fenced-code embedding | embedded grammar state support |
| G0.4 | C++ | major systems language, C overlap | C grammar reuse by data include only |
| G0.5 | C# | major app/game/server language | partial: common attribute/type probes covered 2026-07-04 |
| G0.6 | Java | major JVM language | partial: common annotation/type probes covered 2026-07-04 |
| G0.7 | Go | major backend language | complete 2026-07-03 |
| G0.8 | PHP | major web language, HTML embedding | embedded grammar state support |
| G0.9 | Ruby | major scripting language, interpolation | generic interpolation support |
| G0.10 | Swift | major Apple language, regex literals | regex literal coverage |
| G0.11 | Kotlin | major JVM/mobile language | partial: common annotation/type probes covered 2026-07-04 |
| G0.12 | SQL | core data language, dialect-neutral base | complete 2026-07-03 |
| G0.13 | XML | core markup/config language | complete 2026-07-03 |
| G0.14 | JSX | web major variant | JavaScript plus HTML embedding |
| G0.15 | TSX | web major variant | TypeScript plus HTML embedding |

### P1 Native Grammars

These are strong v1 candidates if time permits:

| id | language | reason |
|---|---|---|
| G1.1 | PowerShell | common shell/admin language |
| G1.2 | Lua | common embedding/game/config language |
| G1.3 | R | common data language |
| G1.4 | Julia | growing data/science language |
| G1.5 | Scala | JVM ecosystem |
| G1.6 | Dart | Flutter ecosystem |
| G1.7 | Objective-C | Apple legacy/native ecosystem |
| G1.8 | Elixir | common BEAM web language |
| G1.9 | Erlang | BEAM legacy/system language |
| G1.10 | Haskell | common functional language |
| G1.11 | Dockerfile | common deployment file |
| G1.12 | Makefile | common build file |
| G1.13 | HCL/Terraform | common infra language |
| G1.14 | Nix | common package/config language |
| G1.15 | Vue | major web single-file component format |
| G1.16 | Svelte | major web single-file component format |

### P2 Converted-Only Is Acceptable

Long-tail languages can remain generated from TextMate/Sublime if their route is
fully checked: examples include Ada, ANTLR, APL, Coq, Fortran, GLSL, GraphQL,
Haxe, OCaml, Pascal, Prolog, Racket, SAS, Smalltalk, Solidity, VHDL, Vim Script,
WAT, Wenyan, Wolfram, and similar niche or lower-volume grammars.

## Parallel Track 2: Native Grammar Infrastructure

These tasks unblock many grammar authors and avoid language-specific engine code.

| id | task | output | acceptance |
|---|---|---|---|
| N2.1 | Embedded language states | Generic include/enter/exit data model for HTML, Markdown, PHP, JSX, TSX | HTML+JS+CSS fixture passes |
| N2.2 | Interpolation spans | Generic nested interpolation for Ruby, Swift, Kotlin, PHP, JS templates | fixtures for nested interpolation |
| N2.3 | Regex literal spans | Generic regex-literal handling for JS, TS, Swift, Ruby where syntax allows | differential samples match references |
| N2.4 | Attribute/annotation rules | Generic data rules for Java, C#, Kotlin, Swift, Python decorators | partial: simple and dotted annotation/decorator names covered 2026-07-04; call arguments and full language-specific attribute semantics remain open |
| N2.5 | Here-doc/raw strings | Generic delimited multiline support for Ruby, PHP, Bash, Swift, Kotlin | partial: generic heredoc and tab-indented terminators covered 2026-07-03 |
| N2.6 | Fenced code routing | Markdown fence maps to embedded grammar by info string | visual fixtures for common fences |
| N2.7 | Grammar metadata registry | Stable language id, aliases, extensions, MIME where relevant | complete for bundled native registry 2026-07-03 |

## Parallel Track 3: TextMate And Sublime Ecosystem Expansion

Goal: keep common languages hand-written, but prove conversion for wide ecosystem
coverage and user-supplied grammars.

| id | task | output | acceptance |
|---|---|---|---|
| C3.1 | Add more independent TextMate sources | Additional non-Shiki/non-current-VS-Code grammar sets | every root reports `missing=0`, `external_missing=0`, `skipped=0` |
| C3.2 | Add more plist bundles | More original `.tmLanguage` plist grammars | report/convert/check-native/generate Zig |
| C3.3 | Add more Sublime packages | More public `.sublime-syntax` packages | report/convert/check-native/pack |
| C3.4 | Dependency graph stress set | Grammars with includes, injections, embeds, cross-file deps | no unresolved external includes |
| C3.5 | Converter negative tests | Known unsupported malformed grammars fail clearly | partial: TextMate JSON/plist malformed diagnostics covered 2026-07-03 |
| C3.6 | User conversion docs | Document offline conversion commands and required gates | complete 2026-07-03 |

## Parallel Track 4: Regex VM And Oniguruma Evidence

Goal: shrink "not proven" by adding behavior coverage and external oracle checks
where possible. Do not add language-specific regex code.

### Immediate Regex Cleanup

| id | task | output | acceptance |
|---|---|---|---|
| R4.0 | Classify skipped oracle rows | `\x{41 42}{2}` and regex-condition rows are Shiki-skipped and not falsely claimed as native-onig checked | complete 2026-07-03 |

### Behavior Matrix Tasks

| id | area | examples | acceptance |
|---|---|---|---|
| R4.1 | Remaining skipped Shiki cases | regex-condition rows, braced sequence repeat, bounded possessive rows | partial: bounded possessive VM rows covered 2026-07-03 |
| R4.2 | Backtracking controls | atomic, possessive, absent, nested combinations | complete 2026-07-03 |
| R4.3 | Recursive/subexp calls | non-left-recursive nested calls, option scopes, forward calls | complete 2026-07-03 |
| R4.4 | Conditional variants | named/numeric/relative/regex conditions, empty branches | oracle rows where reference supports them |
| R4.5 | Callouts and unsupported syntax | reject unsupported Oniguruma callout forms | complete 2026-07-03 |
| R4.6 | Unicode properties | fill script/category/property aliases not currently covered | partial: long category aliases plus `gc`/`General_Category`/`sc`/`Script` scalar aliases covered |
| R4.7 | Grapheme clusters | more UAX-style emoji/Indic/Hangul/RI cases | complete 2026-07-04 |
| R4.8 | Search semantics | nonzero starts, `\G`, `\K`, lookbehind interactions | complete 2026-07-04 |
| R4.9 | Invalid syntax parity | malformed groups, repeats, refs, properties | partial: malformed group/class, descending bounded repeats, and callout rejection covered |
| R4.10 | Catastrophic cases | nested repeats, ambiguous alternatives, step limits | complete 2026-07-03 |

### Regex Acceptance Gates

- `zig test src/regex/vm.zig`
- `zig build check-oniguruma-cases --summary all`
- Native `onig` skipped-case checker where reference accepts the pattern.
- No new runtime allocations in benchmark gates.

## Parallel Track 5: Tree-sitter Real Integration

Tree-sitter proof now includes a real JavaScript parser-backed route while
keeping parser dependencies out of the core runtime dependency graph.

| id | task | output | acceptance |
|---|---|---|---|
| T5.1 | Choose parser integration shape | Optional build path or external adapter binary; core stays dependency-free | complete 2026-07-03 |
| T5.2 | Add one real parser route | JavaScript parser-backed captures | complete 2026-07-03 |
| T5.3 | Add overlay merger tests | Parser captures refine native tokens without overlap bugs | boundary/unordered tests complete 2026-07-03 |
| T5.4 | Add visual route | Native-only vs Tree-sitter-overlay comparison page | complete 2026-07-03 |
| T5.5 | Add perf route | Parser+overlay benchmark row separated from native lexical row | complete 2026-07-03 |
| T5.6 | Add docs | Document optional dependency model and capture mapping | complete 2026-07-03 |

## Parallel Track 6: Visual And Differential Coverage

| id | task | output | acceptance |
|---|---|---|---|
| V6.1 | Expand visual languages | Add P0 grammars as native visual cases | screenshots manually inspected once, then assertions |
| V6.2 | Add embedded visual cases | HTML with CSS/JS, Markdown fences, JSX/TSX | partial: JSX/TSX expression probes covered 2026-07-03 |
| V6.3 | Add capture probes | Assertions for strings, comments, keywords, types, functions, punctuation | complete 2026-07-03 |
| V6.4 | Differential snippets | Shiki/syntect comparisons for every P0 grammar | complete 2026-07-03 |
| V6.5 | Golden token fixtures | Stable token output per P0 language | complete 2026-07-03 |

## Parallel Track 7: Benchmarks And Allocation Proof

| id | task | output | acceptance |
|---|---|---|---|
| B7.1 | Add P0 benchmark corpus | Real-world snippets for each P0 grammar | partial: real rows for Bash/C/JS/JSON/Markdown/Python/Rust/TOML/TS/YAML/Zig; remaining P0 rows still fixture-based |
| B7.2 | All-allocation accounting | setup, load, compile, hot, total shown for zhl and refs where measurable | complete 2026-07-03 |
| B7.3 | WASM coverage expansion | WASM zhl rows for native P0 corpus | complete 2026-07-03 |
| B7.4 | Tree-sitter benchmark | optional overlay benchmark row | complete 2026-07-03 |
| B7.5 | Regression thresholds | Throughput/allocation gates by route | complete 2026-07-03 |

## Parallel Track 8: Docs, API, Release Hardening

| id | task | output | acceptance |
|---|---|---|---|
| D8.1 | Update public API docs | Public exports, grammar ABI, `.zhlb` format updated | complete 2026-07-03 |
| D8.2 | Update migration docs | Native, TextMate, Sublime, Tree-sitter, WASM routes | complete 2026-07-03 |
| D8.3 | Update status doc | Evidence counts and remaining bounds accurate | complete 2026-07-03 |
| D8.4 | License audit | Committed third-party grammar/corpus sources have licenses | complete 2026-07-03 |
| D8.5 | File-line audit | Split cohesive files before they exceed cap | complete 2026-07-03 |
| D8.6 | Runtime boundary audit | No converter/parser dependencies in runtime | complete 2026-07-03 |
| D8.7 | Editor integration example | Minimal token adapter example using `TokenBuffer` and language ids | complete 2026-07-04 |

## Suggested Parallel Scheduling

Phase A, baseline:

- T0.1 through T0.4.

Phase B, unlock grammar authors:

- N2.1, N2.2, N2.3, N2.6 can run in parallel if each uses separate fixtures.
- R4.0 and R4.9 can run independently.
- T5.1 can run independently.

Phase C, native grammar quality hardening:

- HTML, Markdown, PHP, JSX, and TSX hardening follows embedded and fence
  infrastructure work.
- Ruby, Swift, Kotlin, PHP, JavaScript, and TypeScript hardening follows
  interpolation and regex-literal work.
- C++, C#, Java, Kotlin, Swift, and Python quality polish follows generic
  attribute/annotation work.

Phase D, ecosystem proof:

- C3.1 through C3.4 can run in parallel by corpus.
- V6.1 through V6.5 follow grammar completion batches.
- B7.1 through B7.5 follow grammar and tree-sitter route completion.

Phase E, release:

- D8.1 through D8.6.
- Final clean `zig build check-v1 -Doptimize=ReleaseFast --summary all`.

## Final V1 Checklist

- Worktree clean.
- No uncommitted generated packs or docs.
- `zig build check-v1 -Doptimize=ReleaseFast --summary all` passes.
- Visual output inspected for every P0 native grammar and embedded route.
- Benchmark comparison output includes zhl native, zhl WASM, Shiki,
  `vscode-textmate`, syntect onig, syntect fancy-regex, and optional
  Tree-sitter overlay route.
- `docs/v1_status.md` no longer lists unresolved v1 blockers, or explicitly
  defines accepted corpus boundaries.
- No push until reviewed.
