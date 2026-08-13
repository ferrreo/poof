# Universal Offline Compatibility Plan

This plan defines the path from the current v1 boundary to a defensible
"universal" offline compatibility claim for TextMate, Sublime, and Oniguruma.
Runtime stays native Zig. TextMate JSON, TextMate plist, and Sublime YAML remain
offline inputs only: import, report, convert, pack, then execute native data.

## Goal

Universal offline compatibility means:

- Any valid TextMate JSON or plist grammar can be loaded, reported, converted,
  and packed, or rejected with a precise unsupported-feature diagnostic.
- Any valid Sublime `.sublime-syntax` grammar can be loaded, reported,
  converted, and packed, or rejected with a precise unsupported-feature
  diagnostic.
- Converted packs either match the chosen reference tokenization, or document an
  accepted divergence with a stable reason code.
- Runtime does not parse TextMate, plist, or Sublime source files.
- Runtime stays data-driven and generic: no `regex_special_*`, no
  language-specific runtime branches, no production runtime imports from offline
  parsers or converters.
- Third-party grammar/template corpora are not vendored as split files in the
  repository. Build and test gates fetch or materialize them into a cache.

## Non-Goals

- No runtime TextMate interpreter.
- No dependency on Oniguruma at runtime.
- No checked-in copies of large third-party grammar packs, split templates, or
  generated third-party packs.
- No guarantee that malformed grammars are repaired. Malformed inputs fail with
  deterministic diagnostics.

## Success Criteria

- `zig build check-universal-offline -Doptimize=ReleaseFast --summary all`
  passes from a clean tree.
- The gate fetches third-party corpora into a deterministic cache, verifies
  lockfile hashes, converts all selected corpora, packs outputs, and compares
  selected tokenization fixtures against oracles.
- TextMate report output has `missing=0`, `external_missing=0`, and `skipped=0`
  for all supported corpus targets.
- Sublime report output has `missing=0` and `skipped=0` for all supported corpus
  targets.
- Unsupported syntax has stable reason codes and tests.
- Runtime boundary gate proves source runtime does not depend on offline parser,
  converter, corpus cache, or source grammar modules.
- Source layout is package-based, with regex, TextMate, Sublime, native DSL,
  runtime, theme, renderer, and tools split into directories instead of many
  loose files in `src/`.

## Hard Rules

- Cache external corpora. Do not add more split third-party grammar/template
  files to `grammars/` or `tests/fixtures/`.
- Check in only small first-party fixtures, lockfiles, manifests, and expected
  summaries.
- Keep generated conversion outputs out of the repo unless they are first-party
  native grammar packs.
- Prefer one generic fallback representation over special-case lowering.
- Every new unsupported feature gets one negative test and one diagnostic code.
- Every new supported feature gets one oracle case and one converter fixture.

## Target Layout

Current loose-file groups should move behind package roots without changing
public API names.

```text
src/
  root.zig
  runtime/
    root.zig
    engine.zig
    scan.zig
    document.zig
    token.zig
    sinks.zig
    native_runtime.zig
    binary.zig
    wasm.zig
    wasm_export.zig
  regex/
    root.zig
    parser.zig
    vm.zig
    vm_char.zig
    vm_meta.zig
    vm_types.zig
    match.zig
    scan.zig
    scratch.zig
    unicode.zig
    property.zig
    classes.zig
    groups.zig
    repeat.zig
    absent.zig
    refs.zig
    validate.zig
  native/
    root.zig
    dsl.zig
    dsl_emit.zig
    format.zig
    grammar_ir.zig
    fallback_ir.zig
  textmate/
    root.zig
    import.zig
    plist.zig
    types.zig
    include.zig
    injection.zig
    captures.zig
    convert.zig
    convert_blocks.zig
    convert_regex.zig
    dynamic/
      root.zig
      anchor.zig
      class.zig
      layout.zig
      line_start.zig
      literal.zig
      prefix.zig
      storage.zig
  sublime/
    root.zig
    import.zig
    convert.zig
    marker.zig
  theme/
    root.zig
    style.zig
  render/
    root.zig
    ansi.zig
    html.zig
  tree_sitter/
    root.zig
  tools/
    zhlc.zig
    zig_emit.zig
```

Migration rule: move files first, preserve names through package `root.zig`
re-exports, then update imports in small batches. Do not combine reorg with
semantic changes.

## Phase 0: Baseline And Definitions

| id | task | output | acceptance |
|---|---|---|---|
| U0.1 | Define supported-source contract | `docs/universal_offline_compatibility_plan.md` and reason-code list | Contract names exact success, divergence, and unsupported states |
| U0.2 | Add reason-code schema | `docs/compatibility_reason_codes.md` | Every unsupported or accepted-divergence result has stable code |
| U0.3 | Add baseline gate alias | `zig build check-universal-offline` initially depends on current v1 gates | Existing `check-v1` remains green |
| U0.4 | Freeze current corpus counts | Small generated summary file, not corpus content | Summary records current checked-in and external-cache corpus counts |

## Phase 1: Third-Party Corpus Cache

Replace checked-in split third-party grammar corpora with deterministic cached
inputs.

| id | task | output | acceptance |
|---|---|---|---|
| C1.1 | Add corpus manifest | `corpus/manifest.json` or `.zon` with URL, revision, hash, license metadata | Manifest is enough to reproduce current TextMate/Sublime corpora |
| C1.2 | Add fetch script | `tools/fetch_corpus_cache.*` | Fetches to `$ZHL_CORPUS_CACHE` or `.zig-cache/zhl-corpus` without writing repo files |
| C1.3 | Add offline mode | `ZHL_OFFLINE=1` uses existing cache only | CI can run without network after cache restore |
| C1.4 | Replace split-file readers | Integration scripts read cache paths from manifest output | No new `.partNN` source grammar files are required |
| C1.5 | Add cache integrity gate | `zig build check-corpus-cache` | Missing, changed, or unlicensed cached source fails clearly |
| C1.6 | Remove vendored third-party splits | Delete tracked split TextMate/Sublime source chunks after cache gate is stable | Repo keeps licenses, manifests, and summaries only |

Notes:

- Keep first-party minimal fixtures in `tests/fixtures`.
- Keep generated first-party native `.zhlb` packs if they are release artifacts.
- For third-party generated packs, prefer cache outputs plus hash summaries.

## Phase 2: Generic Native Fallback IR

Universal conversion needs a fallback lower than TextMate/Sublime source but
more expressive than current native matchers.

| id | task | output | acceptance |
|---|---|---|---|
| I2.1 | Define fallback IR | `src/native/fallback_ir.zig` | Represents regex program id, stack ops, capture emit ops, scope ops, and state transitions |
| I2.2 | Add pack format records | `.zhlb` extension for fallback IR | Old packs still load, new packs round-trip |
| I2.3 | Add runtime executor | Generic executor over fallback IR | Executes without allocation and without source grammar data |
| I2.4 | Lower TextMate non-native rules | Converter emits fallback IR instead of skipping | Existing corpus still has `skipped=0`; fewer broad lowerings |
| I2.5 | Lower Sublime non-native contexts | Sublime converter emits fallback IR for context ops | Push/set/pop/embed/escape fixtures pass |
| I2.6 | Add debug dump | `zhlc dump-ir` | Oracle failures can be traced without reading source grammars |

This is the shortest path. Without fallback IR, each "universal" gap becomes
another special-case lowering rule.

## Phase 3: Oniguruma Coverage

Goal: support Oniguruma behavior needed by real TextMate grammars, with exact
unsupported diagnostics for the rest.

| id | area | acceptance |
|---|---|---|
| R3.1 | Import upstream Oniguruma cases into cache | Cases are fetched by manifest, not vendored |
| R3.2 | Classify cases | Every row is `supported`, `accepted-divergence`, `oracle-skipped`, or `unsupported` |
| R3.3 | Finish lookaround semantics | Variable/fixed lookbehind, lookahead, `\G`, `\K` covered |
| R3.4 | Finish subexp calls and recursion | Numeric, named, forward, nested, and rejected-left-recursive cases covered |
| R3.5 | Finish conditionals | Numeric, named, relative, regex-condition variants covered or rejected with codes |
| R3.6 | Finish backtracking controls | Atomic, possessive, absent, nested combinations covered |
| R3.7 | Finish Unicode | Script/category aliases, grapheme clusters, properties, invalid ranges covered |
| R3.8 | Add catastrophic-pattern limits | Step limits produce deterministic error, not hangs |
| R3.9 | Add corpus pattern extraction | Every regex from cached TextMate/Sublime corpora is compiled in a standalone gate |

## Phase 4: TextMate Exact Offline Semantics

| id | task | output | acceptance |
|---|---|---|---|
| T4.1 | Include graph resolver | Generic resolver with bounded visited set | External scopes, repositories, and self/base includes resolve from cache corpus |
| T4.2 | Injection planner | Deterministic injection ordering | Oracle fixtures cover selector priority and embedded languages |
| T4.3 | Stack semantics compiler | Begin/end/while stack compiles to fallback IR | Dynamic backrefs, `contentName`, boundary captures match oracle |
| T4.4 | Capture planner | Capture emit ops preserve scope order | `captures`, `beginCaptures`, `endCaptures`, `whileCaptures` covered |
| T4.5 | Rule priority oracle | Differential token spans vs `vscode-textmate` | Selected fixtures match or produce accepted divergence code |
| T4.6 | Full report mode | `zhlc report-textmate-* --json` | Machine-readable missing/skipped/divergence output |
| T4.7 | Full pack mode | `convert -> pack -> load -> dump` round-trip | No source grammar file needed after pack creation |

## Phase 5: Sublime Exact Offline Semantics

| id | task | output | acceptance |
|---|---|---|---|
| S5.1 | Variables and prototype compiler | Variables/prototypes become fallback IR inputs | Variable expansion tests pass |
| S5.2 | Context graph compiler | `push`, `set`, `pop`, nested contexts | Context stack fixtures pass |
| S5.3 | Embed/escape compiler | Generic embedded language transitions | Embedded fixtures pass without language-specific branches |
| S5.4 | Branch/fail support | Branch state in fallback IR if corpus requires it | Either supported by oracle cases or rejected with stable code |
| S5.5 | Sublime oracle harness | Compare against selected reference snapshots | Every selected package is exact or accepted-divergence |
| S5.6 | Full report mode | `zhlc report-sublime --json` | Machine-readable missing/skipped/divergence output |

## Phase 6: Oracle Gates

| id | task | output | acceptance |
|---|---|---|---|
| O6.1 | TextMate oracle | `vscode-textmate` plus Oniguruma over cached corpora | Converted native spans match selected oracle snippets |
| O6.2 | Shiki oracle | Shiki packaged languages fetched by lockfile | All packaged routes convert and selected spans match |
| O6.3 | VS Code extension corpus | Cached extension grammar set | All valid grammars report/convert/pack or coded reject |
| O6.4 | GitHub Linguist corpus | Cached grammar set | All valid grammars report/convert/pack or coded reject |
| O6.5 | Package Control corpus | Cached Sublime package set | All valid syntaxes report/convert/pack or coded reject |
| O6.6 | Summary artifact | `zig-out/compatibility/summary.json` | Counts exact, reason codes stable, CI diff readable |

## Phase 7: Package Reorg

Do this after cache work starts but before fallback IR grows further.

| id | task | output | acceptance |
|---|---|---|---|
| P7.1 | Create package roots | `src/regex/root.zig`, `src/textmate/root.zig`, etc. | Existing imports still compile through re-exports |
| P7.2 | Move regex files | `src/regex/*` | `zig build test` passes after move only |
| P7.3 | Move TextMate files | `src/textmate/*` and `src/textmate/dynamic/*` | `check-integrations` passes after move only |
| P7.4 | Move Sublime files | `src/sublime/*` | Sublime integration phase passes after move only |
| P7.5 | Move native DSL/format files | `src/native/*` | Native grammar compile/pack checks pass |
| P7.6 | Move render/theme/runtime files | `src/render/*`, `src/theme/*`, `src/runtime/*` | Public API docs gate updated and passing |
| P7.7 | Tighten boundary checks | Runtime boundary checks directory packages, not filename prefixes | Converter imports cannot leak into runtime |

Move-only commits should not alter behavior. Semantic changes land after the
new package root compiles.

## Phase 8: Release Gates

| id | task | output | acceptance |
|---|---|---|---|
| G8.1 | Add `check-universal-offline` | Aggregates cache, oracle, conversion, pack, runtime boundary, benchmark gates | Single command proves claim |
| G8.2 | Add cache CI job | Restores corpus cache by manifest hash | CI does not commit fetched files |
| G8.3 | Add compatibility dashboard | Summary JSON and Markdown report | Shows exact, divergence, unsupported, skipped-oracle counts |
| G8.4 | Add docs | Public docs for offline conversion contract | Users know runtime does not load source grammars |
| G8.5 | Add migration note | Explains removal of vendored third-party splits | Existing contributors know how to refresh cache |

## Final Acceptance

- `git status --short` is clean.
- No checked-in split third-party grammar/template corpora remain.
- `zig build check-universal-offline -Doptimize=ReleaseFast --summary all`
  passes.
- `zig build check-runtime-boundary -Doptimize=ReleaseFast --summary all`
  proves runtime source does not import offline parser/converter/cache modules.
- Compatibility summary has zero silent skips.
- Any remaining unsupported features have stable reason codes and explicit
  docs.
- Package layout matches this plan or a documented smaller equivalent.
