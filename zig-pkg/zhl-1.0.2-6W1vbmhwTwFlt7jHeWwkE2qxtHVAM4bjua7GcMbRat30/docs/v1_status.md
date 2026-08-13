# v1 Status

This file tracks evidence for the v1.0 goal. It is not a release checklist
completion claim.

## Proven By Current Gates

- 2026-07-04 local validation reran
  `zig build check-v1 -Doptimize=ReleaseFast --summary all`, reporting `46/46`
  build steps and `331/331` tests passed. The same run covered visual,
  differential, Shiki ecosystem, Oniguruma cases, native/WASM benchmark gates,
  Tree-sitter parser-backed overlay proof, benchmark comparisons, and
  integration checks over 26 native grammars and 469 grammar files.
- Native `.zhl` grammars exist for Bash, C, C++, C#, CSS, Go, HTML, Java,
  JavaScript, JSX, JSON, Kotlin, Log, Markdown, PHP, Python, Ruby, Rust, SQL, Swift,
  TOML, TSX, TypeScript, XML, YAML, and Zig 0.16 in `grammars/`, with matching
  `.zhlb` packs.
- `zhl_grammars` exports a native language metadata registry with stable ids,
  canonical names, display names, TextMate-style scopes, aliases, extensions,
  and MIME types for the 26 bundled native routes. `zhlc --grammar` resolves
  canonical names and aliases through that registry, and the integration gate
  smoke-tests representative aliases.
- `zig build test` runs unit, golden, fuzz, generated grammar, file line, and
  integration checks.
- `zig build check-v1 -Doptimize=ReleaseFast` aggregates the release validation
  gates used by CI: install/build, `zig build test`, visual and differential
  checks, Shiki ecosystem conversion, Oniguruma oracle checks, native and WASM
  benchmark gates, Tree-sitter parser-backed overlay proof, and external
  benchmark comparisons.
- `zig build check-integrations -Doptimize=ReleaseFast` checks native, binary,
  TextMate JSON/plist import and offline conversion, independent external
  TextMate corpora, Sublime import and offline conversion, theme, renderer,
  and checked-in grammar routes. Conversion checks fail if a fixture emits zero
  native rules. The integration gate now runs as one bounded shell command; the
  native smoke, native corpus, fixtures, external TextMate/Sublime, packaged
  TextMate/Sublime, and theme phases run concurrently. Large corpus phases run
  auto-capped parallel workers, share one Zig global cache across generated-Zig
  compile checks, and print per-worker logs only on failure.
- 271 checked-in TextMate JSON grammars report `missing=0` and
  `external_missing=0`, convert to native `.zhl`, pass `check-native`, generate
  native Zig modules, and compile as generated modules when loaded as a bundle from
  `grammars/textmate`. Generated `.zhlb` native packs for the same checked-in
  TextMate corpus are tracked in `grammars/textmate-packs` and compared against
  fresh conversion output by integration checks.
- TextMate JSON and plist match rules without a top-level `name` can convert
  through their first numeric `captures` scope. TextMate plist fixtures also
  cover external grammar includes and embedded content conversion through
  `--include-grammar`.
- TextMate JSON and plist begin/end line-comment rules with literal starts and
  line-end patterns convert to native `line_comment` rules.
- TextMate JSON begin/end line-comment rules with a literal marker followed by
  whitespace regex/detail, such as `#\s*(...)`, lower to that native
  `line_comment` marker while guarded marker patterns such as `//[!/]` are not
  broadened.
- TextMate JSON begin/end line-comment rules with a regex opener lower to
  `regex_line_comment` or `regex_vm_line_comment`, preserving guarded opener
  patterns such as `//[!/](?=[^/])`.
- TextMate JSON comment match rules with literal markers inside simple capture
  groups and `.*` line tails convert to native `line_comment` rules.
- TextMate JSON and plist single-line string begin/end rules that capture a
  delimiter byte class and end on that backreference or newline convert to
  native `string` rules.
- TextMate JSON begin/end string rules with line-end closers lower to
  `multiline_prefix`; string closers with a literal delimiter alternative plus
  a line-end alternative lower to native string delimiters; and string-like
  rules with literal but distinct open and close delimiters lower to native
  `delimited` rules.
- TextMate JSON and plist simple `begin`/`while` line rules with the same
  literal prefix convert offline to native regex rules, including anchored and
  punctuation-start prefixes.
- TextMate JSON begin/end rules with styled boundary captures over literal
  delimiters lower those captured delimiters offline to native regex rules. In
  the checked-in TextMate corpus this reduces executable conversion skips to
  1C 0, 1C Query 0, ABAP 0, Ada 0, ActionScript 3 0,
  Angular Expression 0, Angular HTML 0, Angular Inline Style 0, Angular Inline Template 0,
  Angular Let Declaration 0, Angular Template 0, Angular Template Blocks 0,
  Angular TS 0, Apache 0, Apex 0, APL 0, AppleScript 0, Ara 0, Assembly 0, Astro 0,
  Ballerina 0, Bash 0, BAT 0, Blade 0,
  Batch 0, Beancount 0, Berry 0, BibTeX 0, Bicep 0, BIRD 2 0, BSL 0,
  C 0, C++ 0, C++ Macro 0, C# 0, C3 0, Cadence 0, Cairo 0, CMake 0,
  Clarity 0, Clojure 0, Closure Templates 0, CodeOwners 0, CodeQL 0,
  CoffeeScript 0, Common Lisp 0, Coq 0, CSS 0, CSV 0, Cue 0, Cypher 0, D 0, Dart 0, DAX 0,
  Desktop 0, Diff 0, Dockerfile 0, dotenv 0, Dream Maker 0, Edge 0,
  Emacs Lisp 0, Elixir 0, Elixir text bridge 0, Elm 0, ES Tag XML 0, Fennel 0, Fish 0, Fluent 0, Fortran Fixed Form 0, Fortran Free Form 0, GDResource 0,
  GDScript 0, GDShader 0, Genie 0, Gherkin 0, Git Commit 0, Git rebase 0,
  Gleam 0, Glimmer JS 0, Glimmer TS 0, GLSL 0, GN 0, Go 0, Gnuplot 0, GraphQL 0, Groovy 0, Hack 0, Handlebars 0, Haskell 0, Haxe 0, HCL 0, HJSON 0, HLSL 0, HTTP 0,
  HTML 0, HTML Derivative 0, Javadoc 0,
  Hy 0, HXML 0, Ignore 0, Imba 0, INI 0, Java 0, JavaScript 0, Jinja 0, Jinja HTML 0, JSON 0, JSON5 0, JSONC 0, JSONL 0,
  Julia 0,
  Jsonnet 0, JSSM 0, JSX 0, KDL 0, Kotlin 0, Kusto 0, less 0, Less bridge 0, Liquid 0, LLVM 0, Logo 0, Log 0,
  Lua 0, Luau 0, Make 0, Makefile 0, Markdown Nix 0, Marko 0, MATLAB 0, Mermaid 0, MIPS Assembly 0, Mojo 0,
  MoonBit 0, Move 0, Narrat 0, Narrat Language 0, Nextflow 0, Nextflow Groovy 0, Nginx 0, Nushell 0,
  Nix 0, Objective-C 0, Objective-C++ 0, OCaml 0, Odin 0, OpenSCAD 0,
  Pascal 0, php 0, Pkl 0, PL/SQL 0, PO 0, Polar 0, PostCSS 0, PowerQuery 0, PowerShell 0, Prisma 0,
  Prolog 0, Properties 0, Proto 0, Protocol Buffer 3 0, Pug 0, Puppet 0, PureScript 0, Python 0, QML 0, QMLDir 0, QSS 0,
  R 0, Racket 0, Raku 0, Razor 0, RegExp 0, Reg 0, Rel 0, RISC-V 0, Ron 0,
  ROS msg 0, Rust 0, SAS 0, Sass 0, SassDoc 0, Scala 0, SCSS 0, Scheme 0, ShaderLab 0, Smalltalk 0, Solidity 0, Splunk 0, SQL 0, SurrealQL 0,
  SSH config 0, Stata 0, Stylus 0, Swift 0, SystemVerilog 0, systemd 0,
  TalonScript 0, TASL 0, Tcl 0, Templ 0, Terraform 0, TeX 0, TOML 0, TSV 0, TSX 0, TypeScript 0,
  TypeScript with Tags 0, TypeSpec 0, Typst 0, V 0, Vala 0, VB 0, Verilog 0, VHDL 0, Vim Script 0, Vyper 0, Vue SFC Style Variable Injection 0,
  WAT 0, Wenyan 0, WGSL 0, Wikitext 0, WIT 0, Wolfram 0, XML 0, XSL 0, YAML 0, ZenScript 0, Zig 0,
  and Zsh 0 while preserving
  structural counts.
- Native DSL/runtime support `regex_capture` and `regex_vm_capture` rules that
  match the full regex but emit only the requested capture group. TextMate
  conversion uses this for constrained non-punctuation captures instead of
  broadening them to global literal or identifier rules.
- Native DSL/runtime support `regex_vm_after_line_block` for contextual
  begin/end rules whose child body starts after the opener line and closes on a
  regex lookahead. TextMate conversion uses this for checked-in disabled
  preprocessor branch bodies without adding language-specific logic.
- Native DSL/runtime support `regex_vm_block` for generic stateful begin/end
  blocks whose opener or closer must preserve regex guards. TextMate conversion
  uses this for checked-in guarded string spans without stripping lookarounds or
  adding language-specific logic. Same-delimiter styled blocks lower to the
  generic `delimited` rule when their opener and closer are literal.
- TextMate begin/end rules with only plain or unmapped boundary captures can
  still lower to native block rules. Captures only block these lowerings when
  they require distinct non-plain styling.
- Native DSL accepts up to 16384 generated native rules per grammar so large
  offline conversions such as AsciiDoc and GraphQL can be checked and packed
  without truncating the grammar.
- `zhlc` uses bounded 8 MiB offline output buffers for native conversion,
  packing, and generated Zig emission so large generated grammars do not fail
  the compiler CLI's fixed 1 MiB buffer before reaching runtime validation.
- TextMate begin/end rules that close at line end can lower offline to a
  bounded regex line-span rule when no boundary captures need separate scopes.
- TextMate begin/end rules that open with a zero-width positive lookahead over
  a bounded span and close with a zero-width negative lookahead for the same
  repeated tail class lower offline to that span regex.
- TextMate JSON begin/end comment rules with a native-regex opener and literal
  closer lower to `regex_block_comment`, preserving opener guards such as
  negative lookahead instead of broadening to a literal prefix.
- TextMate JSON begin/end comment rules with a regex-VM-only opener and literal
  closer lower to `regex_vm_block`, preserving opener guards while still
  converting offline.
- TextMate JSON begin/end rules with supported dynamic backreference end
  patterns lower offline to native `dynamic_block` rules. Runtime highlighting
  stores the captured delimiter marker in `Engine.State` and closes the block
  with the same generic `textmate_dynamic` matcher used by the converter
  report path. Runtime tests cover plain heredoc ends and tab-indented heredoc
  terminators. Dynamic ends can use the first non-empty capture from a pair of
  alternate begin-capture slots and optional case-insensitive keyword/backref
  semicolon terminators, including anchored grouped backreference terminators
  such as `^(\\1)$`, plus literal-prefix backreference ends with a literal
  suffix and literal alternate terminator such as `</\\1\\s*>|/>`, and
  literal-prefix backreference ends with a literal suffix such as `}\\1"`.
  Plain backreference ends with literal suffixes such as `\\1"` are covered
  too, along with line-contains-marker ends such as `^.*?\\2.*?$` and
  whitespace-guarded marker suffix ends such as `(?<=\\s)(\\2>)`,
  whitespace-prefixed marker boundary ends such as `\\s*\\2\\b`, and
  concatenated captured delimiters such as `\\2\\1`.
  Line-start grouped marker ends with identifier/Unicode negative lookahead
  such as `^\\s*(\\3)(?![0-9A-Z_a-z\\x7F-\\x{10FFFF}])` are covered too.
  Anchored grouped backreferences with optional-semicolon end lookahead such
  as `^(\\2)(?=;?$)` are also covered.
  Literal-prefix backreference ends with a literal suffix and trailing
  horizontal-space tail such as `(]\\2])[\\t ]*` and `]\\1][\\t ]*` are covered,
  as are optional whitespace-newline tails after literal suffixes such as
  `\\\\end\\{\\1}(?:\\s*\\n)?`, and case-insensitive zero-width line-start or
  semicolon-delimited marker lookaheads such as
  `(?i)(?:^|(?<=;))(?=\\s*\\b\\2\\b)`.
  grouped line-start whitespace marker ends such as `^(\\s*(\\2))(?!\\")`
  and `^(\\s*(\\7))\\s*(\\)\\s*)?(\\.)`.
  Sublime pop-context dynamic ends also support exact repeated backreferences
  such as `\\1{4}` and backreference terminators with trailing byte-class
  flags such as `\\1[eimnosux]*`, plus escaped-delimiter backreferences such as
  `(?<![^\\\\]\\\\)(?<![^\\\\][\\\\]{3})\\1` and the zero-width lookahead form
  `(?=(?<![^\\\\]\\\\)(?<![^\\\\][\\\\]{3})\\2)`. Generic anchored negative
  line-start backreference exits such as `^(?!\\1(?=\\S))`,
  `^(?!\\1\\s+)(?=\\s*\\S+)`, `^(?!\\s*(?:--|$)|\\1\\s)`, and
  `^(?!\\1[\\t ]|[\\t ]*$)` are covered without adding language-specific
  rules. Generic layout/offside dynamic ends with optional keyword lookahead,
  `;`/`}` zero-width closers, and line-start continuation/comment guards such
  as `(?=[;}])|^(?!\\1\\s+\\S|...)` are covered without runtime TextMate
  interpretation. Generic line-start guarded whitespace backreference ends
  such as `^((?!\\5)\\s+)?((\\6))$` and zero-width class lookahead backreference
  ends such as `\\1(?=[acdegilmoprsu]*x[acdegilmoprsu]*)\\b` are covered, as
  are prefixed backreference lookbehind alternates such as
  `/>|(?<=</>)|(?<=</\\2>)` and `\\G` anchored negative-lookbehind alternates
  such as `\\G((?<!\\5[^-\\w]))|}|$`. Generic marker fence-line ends such as
  `^(?: {0,3}\\1-*[\\t ]*|[\\t ]*\\.{3})$` and the matching negative form are
  covered. Positive and negative split-alternation spellings such as
  `^ {,3}\\1-*[ \\t]*$|^[ \\t]*\\.{3}$` and
  `^(?! {,3}\\1-*[ \\t]*$|[ \\t]*\\.{3}$)` are covered too, including
  anchored zero-width positive-lookahead openers such as `\\A(?=(-{3,}))`.
  Generic line-start marker/blank dynamic ends such as
  `^(?:\\1(?=\\s)|\\s*$)`, `^(?!\\1[\\t ]|$)`, and
  `^(?!\\1\\s|\\s*$)` are covered, as are line-start marker-space/empty
  lookahead forms such as `^(?=\\1\\s+|$\\n*)`,
  `^(?!\\1\\s+|$\\n*)`, `^(?!\\1\\s+|\\n)`, and the equivalent
  multiline wrapper `(?m:(?<=\\n)(?!\\1\\s+|$\\n*))`. Generic
  line-start comment marker dynamic ends such as
  `^(?!\\s*#\\3\\s{2,}|\\s*#\\s*$)` are covered.
- TextMate external include reachability uses a bounded visited set so large
  embedded-language graphs do not repeatedly traverse the same external scopes
  during report and conversion passes.
- TextMate and Sublime offline converters emit native `regex_vm` rules for
  supported patterns that cannot be lowered to faster native regex matchers.
  Native DSL and `.zhlb` v4 rule strings retain supported patterns up to 8192
  bytes during offline conversion.
- `zig build check-runtime-boundary` fails if runtime code imports offline
  TextMate/Sublime parsers, converters, or import helper modules, if language-specific
  `regex_special_*.zig` runtime files are reintroduced, if packaged language
  implementation filenames appear outside `src/grammars`, or if production
  runtime core files contain language-specific scope strings instead of
  generic rule handling.
- TextMate regex VM class parsing supports bounded Unicode scalar ranges and
  exact scalar exclusions, including HTML-style custom element and attribute
  name classes with raw UTF-8 ranges and `\x{...}` endpoints.
- Regex VM Unicode property matching supports scalar script ranges for
  class-form and direct `\p{Greek}` checks, covering shell-session prompt
  markers without treating non-ASCII script properties as byte masks.
- Regex VM Unicode property matching also supports Unicode Format (`Cf`)
  scalar ranges in class-form and direct `\p{Cf}` checks, covering identifier
  regexes that admit zero-width format characters without broadening them to
  all non-ASCII bytes.
- Regex VM Unicode property matching supports Unicode Math Symbol (`Sm`) and
  Other Symbol (`So`) scalar ranges in class-form and direct property checks,
  covering operator-heavy grammars without treating every non-ASCII byte as a
  symbol.
- Unicode Word properties (`\p{Word}`/`\P{Word}`) are scalar-aware in direct
  and bracket class forms across the fast compiler and regex VM, sharing the
  same non-ASCII word membership behavior as `\w`/`\W`.
- Corpus-backed broad Unicode properties `\p{L}`, `\p{N}`, `\p{M}`, and
  `\p{Pc}` now use scalar ranges in direct and bracket class forms, including
  inverse `\P{L}` classes, so Swift-style identifier patterns do not collapse
  to ASCII-only matching.
- TextMate conversion splits oversized top-level noncapturing alternation
  patterns into multiple native `regex_vm` rules when each split chunk has the
  same prefix and suffix and compiles within native DSL limits. Unsupported
  split chunks are reported as skipped rules instead of aborting the report.
- TextMate conversion also splits oversized alternation groups that appear
  after earlier prefix groups, and the regex VM validator accepts plain groups
  whose body starts with lazy optional syntax such as `(D??ot)` without
  misclassifying them as repeated isolated option groups.
- TextMate conversion splits oversized positive-lookahead alternation groups
  while preserving active extended-mode comments from `(?x)`, covering
  TypeScript function-assignment lookahead rules from the external VS Code
  grammar without language-specific branches.
- TextMate conversion splits oversized begin/end alternation blocks and falls
  back to splitting captured subpatterns when a styled boundary capture is too
  large for a single contextual capture rule. This covers CSS-style property
  lists nested behind optional vendor-prefix groups without adding
  language-specific lowering.
- Bundled native Java, C#, Kotlin, Swift, and Python grammar routes use a
  generic dotted-prefix data matcher for simple and dotted annotation/decorator
  names, with no language-specific runtime branch. Call arguments and full
  language-specific attribute/decorator semantics are not claimed.
- TextMate JSON capture maps may be object maps or array-style capture lists;
  array entries are imported with their index as the capture slot.
- TextMate begin/end rules whose end pattern is the generic next-line start
  zero-width form lower offline to regex line rules instead of requiring a
  runtime TextMate interpreter.
- TextMate and Sublime conversion reports split `structural` grammar graph and
  context-control entries such as includes, repository containers, no-style
  TextMate blocks, plain metadata/source TextMate wrappers, capture-free
  `meta.*` TextMate wrappers, and no-scope Sublime control rules from
  `skipped` executable rules, so skip counts describe unlowered executable
  conversion work rather than importer bookkeeping.
- `zhlc report-textmate-json --skipped` prints exact unlowered TextMate rule
  shapes and parent indices. Current checked-in TextMate grammar routes report
  zero executable skipped rules.
- `zhlc report-textmate-json --missing` and `report-textmate-plist --missing`
  print unresolved external TextMate scopes as concrete `missing external ...`
  lines instead of only reporting an aggregate count.
- The integration fixture gate asserts malformed TextMate JSON and plist
  grammars are rejected with deterministic `MalformedGrammar` diagnostics.
- Sublime Syntax import and offline conversion is checked against local
  feature fixtures plus 113 packaged upstream `sublimehq/Packages` source
  syntaxes in 212 split corpus files
  across shell, C-family, web, Git, SQL, markup, scripting, regex, and build
  output syntaxes. The external corpus is reconstructed in
  `/tmp`, reported with `missing=0` executable `match`/`escape` pattern
  support, converted to `.zhl`, validated as native grammar input, generated as
  Zig modules, and compiled as generated modules, including hidden parent syntaxes used
  by `extends`, such as Diff Basic and HTML Plain. Rules without a direct `scope` can
  convert through their first numeric `captures` scope. Literal `push`/`set`
  openers with matching literal `pop` closers in string/character scopes lower
  offline to native delimited rules, independent of context declaration order.
  Openers that capture a repeated marker byte and close with a literal-prefix
  backreference, such as Rust raw strings, lower to native `marker_string`
  rules.
  Named context `meta_scope` is preserved for conversion, and literal
  push/pop comment contexts lower offline to native `block_comment` rules.
  Inline anonymous `push`/`set` contexts with `meta_scope` are preserved too,
  including nested anonymous context-list entries such as `- - meta_scope:`.
  Numeric `pop: 1` rules are treated as pop actions, and captured opener
  contexts with dynamic backreference pops lower to native `dynamic_block`
  rules. Sublime variables can be declared after contexts and can reference
  other variables, while contexts named `variables` are kept as normal
  contexts; bracketed push/set target lists resolve to the active target
  context for offline pair lowering.
  No-style match consume rules are reported as structural rather than
  executable skips. Integration checks now fail when offline conversion reports
  nonzero executable skips and derive external Sublime roots from locked cache
  `*.sublime-syntax.part00` chunks. Current external Sublime conversion skips
  are C 0, CSS 0, Diff 0, Diff Basic 0, Git Config 0, Go 0, HTML 0, HTML Plain 0, JavaProperties 0,
  JSON 0, JavaScript 0, Lua 0, Markdown 0, Python 0, Rust 0, TOML 0, TypeScript 0, XML 0, and
  YAML 0.
- Packaged Sublime source chunks are materialized into the corpus cache with
  locked hashes and license text. Their offline converted native `.zhlb` packs
  are tracked in `grammars/sublime-packs`; integration checks
  reconstruct each source, verify `missing=0`, convert to native `.zhl`,
  compile generated Zig modules, and compare regenerated packs against the
  checked-in packs. `tools/check_corpus_counts.sh` pins the packaged Sublime
  dependency graph evidence at 42 scalar/list-form `extends` edges across
  25 parent syntaxes and 38 external syntax includes across 19 syntax targets;
  it also pins TSX's list-form `extends` edges to JSX and TypeScript parent
  scopes.
- Independent external TextMate ASP VB.NET, Batch, BibTeX, Clojure, CSS, Dart, Diff, Docker, Dotenv, Git Commit, Git Rebase, Go, HLSL, HTML, INI, Ignore, Java, JavaScript, JavaScriptReact, JSON, JSONC, JSONL, MagicRegExp, Makefile,
  Objective-C, PowerShell, Python, R, Rust, SassDoc, SCSS, ShaderLab, Shell, SQL, Swift, TeX, TypeScript, TypeScriptReact, XML, and XSL grammars from Microsoft VS Code commit
  `7207f731a477434811e61ca70e6c66ee4dc393fd` are materialized into the corpus
  cache as split fixture parts; Git Commit includes
  `source.diff`, Git Rebase includes `source.shell`, ShaderLab includes `source.hlsl`, TeX includes `source.r`, XSL includes `text.xml`, XML includes `source.java`,
  SCSS includes `source.sassdoc` and `source.css`, SassDoc includes
  `source.css.scss` and `source.js`, and HTML includes `source.css`, `source.js`, and `text.html.basic`, so the
  gate covers independent external dependency graphs. All forty roots report
  `missing=0` and `external_missing=0`, convert to native `.zhl`, pass
  `check-native`, and compile as generated Zig through
  `textmate-external-parallel`. The integration gate derives those roots from
  locked cache `*.tmLanguage.json.part00` fixture chunks so added external
  TextMate grammars cannot be omitted by a stale hand-written list.
- Focused Oniguruma compatibility tests cover newline/super-dot escapes
  `\N`, `\O`, `\R` including CRLF, LF, CR, VT, FF, NEL, U+2028, and U+2029 rows,
  text-segment escapes `\X`/`\y`/`\Y`,
  absolute start/end anchors `\A`/`\z` plus EOF and final-linebreak end anchor `\Z`,
  internal fast-regex `\A`, `\G`, `\z`, and `\Z` zero-width anchor atoms,
  escaped `\Q`/`\E` literal marker bytes including adjacent regex
  metacharacters, ASCII control escapes, ASCII hex
  byte escapes `\xNN`/`\x{NN}`, line-aware `^`/`$`,
  and byte whitespace
  class behavior plus UTF-8 line/paragraph separators in scalar whitespace
  escapes in the fast regex compiler and VM path. `.` and `\N` exclude LF
  only, while CR, VT, NEL, and UTF-8 U+2028/U+2029 are consumed as Oniguruma
  does. The fast regex compiler consumes full UTF-8 scalars for `.`, `\N`,
  `\O`, and `\S`, and backtracks greedy `*`/`+` quantifiers in greedy order on
  valid atom boundaries. The regex VM
  consumes full UTF-8 scalars for `.`, `\N`, `\O`, inverse shorthand
  escapes, inverse shorthand bracket classes, inverse Unicode properties,
  and negated bracket classes instead of splitting continuation bytes. `\X`,
  `\y`, and `\Y` cover CRLF, combining-mark clusters, spacing-mark clusters,
  prepend scalars, Hangul syllable clusters, regional-indicator pairs, emoji
  ZWJ sequences, emoji modifier sequences, keycap sequences, and emoji tag
  sequences.
  The regex VM
  honors zero-prefixed ASCII octal byte escapes, byte-range `\o{...}` octal
  and `\uHHHH` Unicode escapes, UTF-8 codepoint escapes such as `\x{200C}`,
  `\u2028`, and `\o{20015}` in scalar terms plus positive and negated bracket classes,
  braced codepoint sequences such as `\x{41 42}` and `\o{101 102}`,
  `\cX`/`\C-X` control escapes in terms and classes,
  `\M-X`/`\M-\C-X` meta escapes in terms and classes, Oniguruma/Ruby inline `(?m:...)` dot-all
  groups plus named
  capture/backreference forms `(?<name>...)`, `(?'name'...)`, `\k<name>`,
  `\k'name'`, relative numeric backreferences such as `\k<-1>`,
  same-recursion-level suffixes such as `\k<name+0>` and `\k<1+0>`,
  quote-delimited numeric recursion-level backreferences such as `\k'1+0'`,
  case-insensitive numbered, named, and relative backreferences,
  duplicate named backreference search from latest capture to earlier
  captures, mixed named/numeric backreferences in the same pattern,
  and named conditional forms `(?(<name>)yes|no)` and
  `(?('name')yes|no)`, quote-delimited numeric forms such as
  `(?('1')yes|no)` and `(?('1+0')yes|no)`, with both yes/no branch coverage for
  quote-delimited named and numeric forms, relative conditional forms such as
  `(?(-1)yes|no)`, `(?(<-1>)yes|no)`, and `(?('-1')yes|no)`, wrapped
  numeric conditionals such as `(?(<1>)yes|no)`, plus regex-condition forms such as
  `(?(?=a)a|b)`. Numeric, named, relative, forward, and same-recursion-level
  subexp calls such as `\g<1>`, `\g<name>`, `\g<-1>`, `\g<+1>`,
  `\g<type.name>`, and
  `\g<name+0>` are covered. Quote-delimited numeric, named, and forward
  relative call spellings such as `\g'1'`, `\g'word'`, and `\g'+1'`
  are covered, including mixed named/numeric calls in the same pattern.
  Whole-pattern calls `\g<0>` and `\g'0'`
  are covered in non-left-recursive positions, zero-width named group
  definitions such as `(?<path>...){0}\g<path>` are covered, and
  called-group option status is honored.
  Oniguruma range quantifiers with omitted minimum counts
  (`{,n}` as `{0,n}`) and exact reluctant counts (`{n}?` as optional
  exact-repeat) are covered.
  Invalid numeric/named backreferences and subexp calls are rejected at compile
  time, including duplicate-name subexp calls. Dotted/hyphen capture names are
  accepted for capture definitions and subexp calls; the native Rust `onig`
  checker pins dotted and hyphenated backreference and named-condition
  references as libonig compile errors, and those references stay rejected.
  The same native oracle
  pins repeated lookahead/lookbehind assertions and repeated isolated option
  groups as compile errors.
  Unsupported Oniguruma callout syntaxes, including PCRE-style `(?C...)`,
  interpolation-style `(?{...})`, and named `(*name...)` forms, are rejected
  at compile time by focused VM tests rather than implemented as callbacks.
  Focused VM tests also reject malformed group and class delimiters plus
  descending bounded repeats such as `a{3,2}`.
  Named backreference and named-condition identifiers are rejected when they contain
  bytes outside `[A-Za-z0-9_-]`. Unnamed groups keep numeric capture slots when
  named groups are present, including validation that rejects plain capture
  groups inside negative lookbehind even when another named group exists.
  Direct left-most recursive subexp calls are rejected for whole-pattern,
  numeric, and named-group calls.
  Oniguruma `\K` keep/reset is routed to the regex VM and emitted from the
  reset match start.
  Escaped `\Q` and `\E` markers follow default Oniguruma syntax as literal
  `Q` and `E` bytes; Perl/Java quote-mode semantics are not enabled.
  Oniguruma absent repeater forms such as `(?~345)`, absent expression
  forms such as `(?~|345|\d*)`, absent stopper forms such as `(?~|345)`,
  and absent range clear `(?~|)` are covered in the regex VM, and offline
  TextMate conversion routes these absent forms to native `regex_vm` rules.
  End anchors `$`, `\Z`, and `\z` honor absent expression right bounds.
  Oniguruma nested byte-class unions such as `[[a-c][x-z]]` and set
  intersections such as `[a-w&&[^c-g]z]` are covered in both regex paths, with
  shared parsing for nested/negated classes.
  Focused compatibility tests cover isolated option groups such as `(?i)`,
  `(?-i)`, `(?x)`, and `(?-x)`, `(?y{g})` and `(?y{w})` text-segment mode spellings, including option effects
  across following alternatives, Oniguruma ASCII/segment option letters `W`,
  `D`, `S`, `P`, and `y`, inline `(?#...)`
  comments, extended-mode whitespace and line comments, `(?S)`/`(?P)`
  ASCII-space option effects for `\s`/`\S`, `[[:space:]]`, and
  `\p{Space}`/`\P{Space}`, shorthand and anchor
  lookaround in both regex paths, negative shorthand byte classes
  `\D`/`\W`/`\H` inside and outside bracket classes, positive hex-digit
  `\h` shorthand inside and outside bracket classes, scalar-aware
  `\w`/`\W` and `\p{Word}`/`\P{Word}` word membership plus
  `\b`/`\m`/`\M` word boundaries in the
  fast compiler and VM, Oniguruma word-start and word-end anchors while
  preserving `\M-X` meta escapes,
  rejected repeated
  lookahead/lookbehind and repeated isolated option groups, and unpaired left braces
  as literal bytes. Negative lookbehind
  capture rejection, positive lookbehind capture/backreference propagation, and
  variable-width lookbehind execution are covered in the regex VM, while shy
  groups remain allowed. Regex VM group alternatives retry before following
  suffix terms for plain capturing, named, and shy groups, while atomic groups
  stay non-backtracking. Focused zero-length infinite-repeat cases cover
  progress after capture state changes and retry of empty group alternatives
  before the stable empty-repeat stop.
  Possessive
  quantifiers use no-backtrack semantics in the fast compiler and regex VM for
  simple `?+`/`*+`/`++` forms. Bounded `+` suffix forms are accepted with
  default Oniguruma greedy bounded semantics. The fast compiler also covers
  Oniguruma bounded question suffixes, including omitted-min
  `{,n}`, lazy bounded `{n,m}?`, and exact `{n}?` as optional exact repeat
  rather than lazy exact repeat. ASCII Unicode
  property aliases such as `\p{upper}`/`\p{alnum}`, Oniguruma spellings such
  as `\p{Alpha}`/`\p{XDigit}`/`\p{ASCII}`/`\p{Alnum}`,
  `\p{Blank}`/`\p{Graph}`/`\p{Print}`/`\p{Punct}`, byte-wide properties
  `\p{Any}`/`\p{Assigned}`, scalar category aliases
  `\p{Cc}`/`\p{Control}`, `\p{Co}`/`\p{Private_Use}`,
  `\p{Zs}`/`\p{Space_Separator}`/`\p{Zl}`/`\p{Zp}`/`\p{Separator}`, and
  table-driven Oniguruma conformance cases that combine anchors, dot-all,
  extended mode, inline flag disable, numeric and named backreferences,
  duplicate names, set and regex-expression conditionals, relative condition
  slots, variable lookbehind, absent expressions, scalar sequences, escaped and
  class shorthand hex/digit/space/word classes, non-boundaries, fixed and variable lookbehind,
  lookbehind anchor/property/bounded-repeat edges,
  POSIX class aliases including Oniguruma-pinned `[:punct:]` bytes,
  non-ASCII scalar properties such as `\p{Greek}`, `\p{Cf}`, `\p{Sm}`,
  `\p{So}`, and non-ASCII `\p{Word}`, inverse Unicode properties, class
  intersections, nested class unions, inverse POSIX word classes, nested
  class intersections, Oniguruma `D`/`P`/`W`/`S` ASCII option behavior for
  shorthand classes, POSIX classes, and Unicode property aliases, `\K`,
  nonzero-start `\G`, atomic groups, possessive quantifiers, broader Latin
  Extended-A/B, Greek/Coptic, Cyrillic extended, Armenian, Georgian, Cherokee,
  supplementary-plane scripts, fullwidth Latin, German sharp-s, long-s, and
  micro-sign folding, exact zero-count repeats, escaped extended-mode spaces, a
  VM step-limit case for ambiguous nested repeats, and `gc=`/`General_Category=`
  plus `sc=`/`Script=` scalar property aliases in VM terms and classes.
  `zig build check-oniguruma-cases` parses those same 1324 Zig table rows plus 4 generated long-repeat rows and verifies the 1318 rows
  against Shiki's Oniguruma engine. The same gate runs a native Rust `onig`
  checker for bounded-plus rows and selected `\K` rows.
  Checked cases include selected capture-group set/unset spans for
  backreferences including non-ASCII named backreferences, duplicate names,
  conditionals, relative slots, subexp calls, non-ASCII byte offsets, and
  nonzero UTF-8 byte starts, positive/negative lookahead capture propagation, and
  repeated-group capture overwrite/unset/stale nested-capture behavior, greedy,
  lazy, empty, and unmatched optional repeated-capture spans, plus lowercase/uppercase/titlecase/cased/modifier/other-letter,
  lowercase/uppercase aliases, Unicode space/blank/whitespace/newline aliases, control/private-use/symbol/currency/modifier/enclosing-mark/nonspacing-mark/spacing-mark/letter-number/other-number/separator/punctuation
  Unicode properties, negative property syntax, direct/class-form common and inherited script properties,
  and four-letter script property aliases
  for Latin, Cyrillic, Han, Hiragana, Katakana, Hebrew, Arabic, Common, Inherited,
  Devanagari, Thai, Hangul, Bopomofo, Armenian, Georgian, Runic, Ethiopic,
  Khmer, Lao, Myanmar, Sinhala, Tamil, Telugu, Kannada, Malayalam,
  Bengali, Gurmukhi, Gujarati, Oriya, Tibetan, Syriac, Thaana, Nko,
  Cherokee, Canadian Aboriginal, Ogham, Mongolian, Coptic, Gothic, Deseret,
  Old Italic, Tagalog, Hanunoo, Buhid, and Tagbanwa,
  Balinese, Batak, Buginese, Cham, Javanese, Lepcha, Limbu,
  New Tai Lue, Tai Le, and Rejang,
  Adlam, Ahom, Avestan, Bassa Vah, Bhaiksuki, Brahmi, Carian,
  Caucasian Albanian, Chakma, and Cuneiform,
  Dives Akuru, Dogra, Duployan, Egyptian Hieroglyphs, and Elbasan,
  Elymaic, Glagolitic, Grantha, Gunjala Gondi, Hanifi Rohingya, and
  Imperial Aramaic,
  Inscriptional Parthian, Inscriptional Pahlavi, Kaithi, Khojki, and
  Khitan Small Script,
  Lycian, Lydian, Mahajani, Makasar, and Mandaic,
  Manichaean, Marchen, Masaram Gondi, Medefaidrin, and Mende Kikakui,
  Meroitic Cursive, Meroitic Hieroglyphs, Miao, Modi, and Multani,
  Nabataean, Nandinagari, Newa, Nushu, Old North Arabian, Old Permic,
  Old Persian, and Old Sogdian,
  Yi, Braille, Tifinagh, Vai, Lisu, Bamum, Syloti Nagri, Phags Pa,
  Saurashtra, and Kayah Li,
  plus Unicode block properties for Basic Latin, Latin-1 Supplement,
  Latin Extended-A/B, IPA Extensions, Spacing Modifier Letters,
  Combining Diacritical Marks,
  Greek and Coptic, Cyrillic, Hebrew, Arabic, Devanagari, Thai, Hangul Jamo,
  Hiragana, Katakana, Bopomofo, Hangul Compatibility Jamo,
  Katakana Phonetic Extensions, CJK Symbols and Punctuation,
  CJK Compatibility, CJK Unified Ideographs, Hangul Syllables,
  CJK Compatibility Ideographs, CJK Compatibility Forms,
  and Halfwidth and Fullwidth Forms,
  and one-scalar Unicode case folds for Latin-1, Latin Extended-B,
  Latin Extended Additional/D, Latin Extended-C, titlecase Latin digraphs,
  Greek, Greek Extended, Glagolitic, Coptic, Cyrillic, Cyrillic Extended-B,
  Medefaidrin, Adlam, Vithkuqi, Roman/enclosed/letterlike symbols, and folded
  ASCII-mask classes, literals, classes, and backreferences, plus Shiki-checked Unicode text-segment byte
  spans, absolute/search-start/end anchor success and failure edges, bounded
  repeat counts past 64 up to the VM's 1024-repeat scratch budget, omitted-branch
  backreference validity checks, then-only conditionals with empty else branches,
  forward-reference conditionals, and over-cap
  bounded repeat rejection instead of silent clamping;
  10 skipped rows remain limited to regex-condition, scalar-sequence, and
  bounded-plus Shiki skips, while `\K` and bounded-plus rows are covered by Zig tests and the native `onig` skipped-case
  checker. The oracle check fails if total, checked, skipped row
  counts, or the explicit skipped pattern set drift unexpectedly.
  `\p{Connector_Punctuation}`, `\p{Sc}`/`\p{Currency_Symbol}`,
  `\p{Sk}`/`\p{Modifier_Symbol}`, `\p{Me}`/`\p{Enclosing_Mark}`,
  `\p{Ll}`/`\p{Lowercase_Letter}`, `\p{Lu}`/`\p{Uppercase_Letter}`,
  `\p{Lt}`/`\p{Titlecase_Letter}`, `\p{Lm}`/`\p{Modifier_Letter}`,
  `\p{Lo}`/`\p{Other_Letter}`, `\p{Nl}`/`\p{Letter_Number}`,
  `\p{No}`/`\p{Other_Number}`, loose Unicode category name matching such as
  `\p{General_Category=lowercase-letter}` and `\p{gc=Lu}`,
  `\p{^...}` negative property syntax, short
  `\pX`/`\PX` category properties, and `\p`/`\P` inside
  bracket classes are covered. Nested bracket classes can union scalar ranges
  with negated scalar classes without dropping to a language-specific path.
  POSIX bracket class coverage
  includes `[:ascii:]`, `[:blank:]`, `[:cntrl:]`, `[:graph:]`,
  `[:lower:]`, `[:print:]`, `[:punct:]`, `[:word:]`, `[:xdigit:]`,
  case-insensitive class names, scalar-high `[:word:]`/`[:graph:]`/`[:print:]`,
  and negative forms such as `[:^alpha:]` and `[:^word:]`.
  Compile-time regex structure, reference, and extension validation share
  active extended-mode comment scanning, so fake group syntax inside `(?x)`
  line comments is ignored without accepting the same syntax after `(?-x)`.
  Runtime regex VM group and branch scans also honor active extended-mode
  comments, so `)` and `|` bytes inside `(?x)` comments do not terminate the
  enclosing group or branch, while scoped `(?-x:...)` groups keep `#` literal.
  Pattern-wide VM scans for capture slots, named backreferences, subexp calls,
  and conditionals ignore captures and conditional syntax inside active
  extended-mode comments.
  Regex-condition parsing also carries active extended-mode flags into the
  condition expression, so `#...` comments inside `(?(regex)yes|no)` do not
  terminate the condition early.
- `zig build check-visual -Doptimize=ReleaseFast` runs
  `npm --prefix benchmark run visual` with the built `zhlc` artifact. It
  compares zhl, Shiki, and syntect output for the native `.zhl` visual route
  set, including first-pass P0 routes, and fails if that visual route list
  changes unexpectedly. JSX and TSX visual probes include expression-body
  numeric tokens inside tag bodies; HTML style/script bodies and Markdown fence
  routing remain open.
- `zig build test` pins compact golden token-output hashes for the 26 bundled
  native grammar fixtures, so P0 token dumps cannot drift silently.
- `zig build check-diff-native -Doptimize=ReleaseFast` runs
  `npm --prefix benchmark run diff:native` with the built `zhlc` artifact. It
  checks native `.zhl` spans against Shiki-colored spans.
- `benchmark/run_compare.sh` covers native zhl, WASM zhl, Shiki,
  `vscode-textmate` plus Oniguruma, syntect onig, and syntect fancy-regex
  release runs over Zig 0.16, TypeScript, Rust, Python, adversarial Zig, real
  zhl Zig source files, minified JSON, minified JavaScript, TextMate JSON, and
  tracked real repo files for Bash, C, JavaScript, JSON, Markdown, Python,
  Rust, TOML, TypeScript, YAML, and Zig corpora. Reference comparison rows use bounded
  per-corpus byte targets so slow external engines do not dominate CI runtime.
  Some first-pass P0 native benchmark rows still use committed language fixtures
  rather than licensed external or repo-owned corpus snippets.
  `zig build check-bench-cases` checks that native zhl, Shiki,
  direct `vscode-textmate`, syntect onig, and syntect fancy-regex benchmark
  harnesses use the same case labels and that each runner keeps the required
  setup, hot, and total allocation or host-memory metric fields. The same gate
  also fails if `benchmark/run_compare.sh` stops running native zhl, WASM zhl,
  Shiki, direct `vscode-textmate`, syntect onig, or syntect fancy-regex, and
  pins the 12 WASM benchmark rows over Zig 0.16 plus the first-pass P0 native
  fixture corpus, with Markdown using repo README content instead of a fixture.
  Shiki, direct `vscode-textmate`, syntect onig, and syntect fancy-regex
  comparison runners fail if their expected row counts change.
  Native zhl throughput and zero-allocation gates run for every native zhl
  corpus row. Native zhl reports setup, hot, and total allocations/bytes;
  syntect reports setup, hot, and total allocator counts/bytes through a
  counting global allocator; Shiki and direct `vscode-textmate` report setup,
  hot, and total heap/RSS/external/buffer deltas because Node does not expose
  exact allocation counts without profiler instrumentation. WASM zhl is
  benchmarked over Zig 0.16 plus the first-pass P0 native fixture corpus, with
  Markdown using repo README content instead of a fixture, and reports setup,
  hot, and total allocation counts as zero plus host heap/RSS deltas.
- `zig build check-bench-native -Doptimize=ReleaseFast` runs the native zhl
  throughput and allocation gate against the built `zhl-bench` artifact. CI
  runs that artifact-backed gate once, and the gate fails if the expected
  native benchmark row count changes. `benchmark/gate.sh` applies per-route
  throughput bands plus setup, hot, and total allocation gates for every native
  zhl row.
- `zig build check-wasm-bench -Doptimize=ReleaseFast` runs the WASM zhl rows
  against the built `zhl_wasm.wasm` artifact. CI runs those artifact-backed rows
  once, then runs `benchmark/run_compare.sh` with the duplicate native and WASM
  rows skipped so Shiki, direct `vscode-textmate`, syntect onig, and syntect
  fancy-regex comparison rows still run.
- `zig build check-shiki-ecosystem -Doptimize=ReleaseFast` runs
  `npm --prefix benchmark run check:shiki-ecosystem` with the built `zhlc`
  artifact. It checks all 253 Shiki language routes against a reconstructed
  301-scope TextMate corpus, including scope aliases derived from Shiki
  language metadata, with `missing=0` and `external_missing=0`, then converts
  every route offline to native `.zhl` with `skipped=0`, runs
  `check-native`, emits generated native Zig, and compiles that generated Zig
  module. The check pins
  the 253 route, 301 scope, 111 dependency-root, 138 dependency-target-scope,
  and 723 direct cross-scope include-pair counts so coverage cannot silently
  shrink.
- `LineCache.rehighlight` supports incremental line rehighlighting and stops
  when state converges. Unit tests cover convergence, and golden tests compare
  cached rehighlight output and end states against a full rehighlight after an
  edit.
- Tree-sitter support ships as a dependency-free overlay/adapter API. Tests
  cover ordered capture overlays, captures clipped across native token
  boundaries, plain gaps, malformed native/capture ranges, common highlight
  capture-name style mapping, and a mock parser adapter feeding captures into
  `applyAdapterLine`. Parser libraries and query runtimes are caller-owned by
  design so the optional Tree-sitter path does not add C interop or parser
  dependencies to the core runtime. `zig build tree-sitter-example` runs a
  parser-adapter overlay example and is included in `zig build test`.
  `zig build check-tree-sitter` runs a benchmark/dev JavaScript route backed by
  the Node `tree-sitter` and `tree-sitter-javascript` packages, maps real query
  captures into overlay tokens, writes a native-vs-overlay visual page, and
  reports setup, parse, and overlay timings.
- `.github/workflows/ci.yml` runs license checks, Zig tests, integrations, WASM
  build, and the aggregate `zig build check-v1 -Doptimize=ReleaseFast` gate.
- `docs/public_api.md` documents the v1 `@import("zhl")` export surface,
  sink and renderer helpers, `EngineOptions` fields, `HighlightError` members,
  generated grammar ABI, and `.zhlb v4` binary ABI.
  `zig build check-public-api-docs` fails if a `src/root.zig` export is not
  documented, if the public API export sections mention a removed root export,
  if documented sink/renderer/document/Tree-sitter helpers are missing, if an
  `EngineOptions` field or `HighlightError` member is missing or stale in docs,
  if a checked grammar module lacks `pub const name` or `pub const grammar`, or
  if the documented `.zhlb` version drifts from `src/runtime/binary.zig`.
- `docs/migration.md` documents migration from TextMate JSON/plist, Sublime
  Syntax, Shiki/`vscode-textmate`, syntect, native `.zhl`, and runtime
  integration. `zig build check-release-docs` fails if required release docs or
  migration sections disappear, if the saved split spec parts are missing from
  `docs/spec`, or if `.gitignore` stops excluding `zig-pkg/`.
- `tools/check_file_lines.sh` enforces the 750-line non-test file cap, and
  `tools/check_file_lines.sh --report` prints the largest tracked non-test
  files so splits can be planned without deleting tests or grammar coverage.
- `tools/check_runtime_boundary.sh` recursively rejects `regex_special_*.zig`
  runtime files and scans dynamic-end runtime code plus all `src/regex/*.zig`
  and `src/textmate_dynamic*.zig` runtime helpers for language-specific scope
  strings, in addition to blocking runtime imports of offline TextMate/Sublime
  converter modules.
- `tools/check_corpus_counts.sh` enforces the documented checked-in corpus
  counts for native, TextMate, Sublime, and external TextMate/Sublime fixture
  routes, and fails if `src/grammars/root.zig` stops exporting any checked-in
  native `grammars/*.zhl` route. It also pins the external TextMate dependency
  edges used as evidence: Git Commit to Diff, Git Rebase to Shell, ShaderLab to HLSL, XML to Java, and HTML to CSS,
  JavaScript, and base HTML, plus the external plist Git commit to Diff edge.
  The Shiki ecosystem gate separately pins the broader reconstructed
  TextMate dependency graph. Packaged Sublime `extends` and syntax-include
  edge counts are pinned too, along with external Sublime `extends` edges for
  Diff, HTML, and TypeScript.
- `tools/check_licenses.sh` enforces license files for committed TextMate
  grammars, packaged and external TextMate/Sublime corpus chunks, generated
  grammar packs, and third-party benchmark corpora.

## Acceptance Checklist Audit

This maps the spec acceptance checklist to current evidence. It is intentionally
stricter than the green build: items stay bounded or open when evidence does
not prove the full requested scope.

| item | status | evidence |
|---|---|---|
| Zig 0.16 native highlighting | proven | `grammars/zig_0_16.zhl`, `src/grammars/zig_0_16.zig`, golden tests, visual gate |
| Native `.zhl` compiler | proven | `zhlc check-native`, `compile-native`, generated module checks in `check-integrations` |
| Native DSL docs | proven | `docs/native_dsl.md` |
| Zero heap allocations in `highlightLine` | proven for native gates | `zig build check-bench-native` requires zero setup, hot, and total native allocations |
| TextMate JSON compile/convert | bounded | 271 checked-in JSON grammars pass report, conversion, pack, and generated-Zig checks |
| TextMate plist compile/convert | bounded | plist fixtures plus eight independent external plist grammars pass report, conversion, and generated-Zig checks |
| TextMate match/begin/end/while/captures/includes/repositories/injections/embedded grammars | bounded | fixture coverage plus checked-in TextMate corpus; broader ecosystem still open |
| Oniguruma-compatible regex VM | bounded | focused compatibility tests pass, table rows are checked against Shiki's Oniguruma engine, and checked-in grammar patterns pass; full behavior matrix still open |
| Compatibility regex uses precompiled programs and caller scratch | proven for current VM/native paths | `regex_vm`, `regex_scratch`, and allocation gates |
| Lowerable regexes become native matchers | proven for current corpus | converter reports zero executable skips for checked-in TextMate corpus |
| Sublime import | bounded | local fixtures plus 113 packaged upstream source syntaxes and 19 external Sublime fixture syntaxes |
| Theme compilation | proven | JSON and plist theme compile checks in `check-integrations` |
| ANSI and HTML renderers | proven | renderer unit tests and integration output checks |
| Incremental rehighlight | proven for current cache model | `LineCache.rehighlight` tests and golden edit comparison |
| WASM build example | proven | `zig build wasm` and `zig build check-wasm-bench` WASM rows |
| Optional Tree-sitter overlay | proven with adapter API and JavaScript parser route | unit tests, `zig build tree-sitter-example`, and `zig build check-tree-sitter` |
| Differential TextMate harness | bounded | `npm --prefix benchmark run diff:native` checks native routes against Shiki spans; full TextMate semantic differential coverage remains open |
| Fuzz tests | proven for current fuzz corpus | `tests/fuzz.zig` in `zig build test` |
| Benchmark suite | proven | `zig build check-bench-native`, `zig build check-wasm-bench`, `zig build check-tree-sitter`, and `benchmark/run_compare.sh` cover zhl, WASM, Tree-sitter overlay, Shiki, direct `vscode-textmate` plus Oniguruma, syntect onig, and syntect fancy-regex |
| Precompiled grammar pack | proven | native, TextMate, and Sublime `.zhlb` pack checks |
| Editor integration example | proven | `examples/editor_tokens.zig` and `zig build editor-example` map `TokenBuffer` output to editor rows with registry `language_id` |
| Stable public API | proven | `docs/public_api.md` plus `zig build check-public-api-docs` gate root exports, sink/renderer helpers, `EngineOptions`, `HighlightError`, checked grammar module ABI, and `.zhlb v4` docs |
| Migration guides | proven | `docs/migration.md` plus `zig build check-release-docs` gate required migration routes |

## Supported Corpus Boundary

Current compatibility evidence is corpus-bounded, not ecosystem-complete:

- Native hand-written `.zhl`: Bash, C, C++, C#, CSS, Go, HTML, Java,
  JavaScript, JSX, JSON, Kotlin, Log, Markdown, PHP, Python, Ruby, Rust, SQL, Swift,
  TOML, TSX, TypeScript, XML, YAML, Zig 0.16.
- TextMate JSON: 271 checked-in grammars under `grammars/textmate`, all with
  tracked generated packs under `grammars/textmate-packs`, plus independent
  external ASP VB.NET, Batch, BibTeX, Clojure, CSS, Dart, Diff, Docker, Dotenv, Git Commit, Git Rebase, Go, HLSL, HTML, INI, Ignore, Java, JavaScript, JavaScriptReact, JSON, JSONC, JSONL, MagicRegExp, Makefile, Objective-C, PowerShell, Python, R, Rust, SassDoc, SCSS, ShaderLab, Shell, SQL, Swift, TeX, TypeScript, TypeScriptReact, XML, and XSL
  TextMate grammar fixtures.
- TextMate plist: local feature fixtures for plist import, external include,
  and conversion, plus independent Ada, ANTLR, Apache, DOT, INI,
  JavaScriptNext, Git commit, and Diff external plist grammars.
- Sublime: local fixtures plus 113 packaged upstream source syntaxes in 212
  locked cache chunks, 113 tracked generated packs under
  `grammars/sublime-packs`, and the matching external fixture subset without
  the packaged-only languages.
- Visual and differential checks: Zig, JSON, Rust, TOML, YAML, C, C++, C#,
  HTML, Java, Kotlin, Markdown, PHP, Ruby, Swift, JSX, TSX, Bash, JavaScript,
  TypeScript, Python, CSS, Go, SQL, and XML native `.zhl` routes.

## Not Proven Yet

- Full TextMate ecosystem conversion compatibility beyond the checked-in grammar
  set, Shiki's packaged language routes, and the independent external
  ASP VB.NET, Batch, BibTeX, Clojure, CSS, Dart, Diff, Docker, Dotenv, Git Commit, Git Rebase, Go, HLSL, HTML, INI, Ignore, Java, JavaScript, JavaScriptReact, JSON, JSONC, JSONL, MagicRegExp, Makefile, Objective-C, PowerShell, Python, R, Rust, SassDoc, SCSS, ShaderLab, Shell, SQL, Swift, TeX, TypeScript, TypeScriptReact, XML, and XSL grammars is not proven. Runtime
  TextMate interpretation is
  intentionally absent; TextMate support is offline import/report/convert to
  native `.zhl`, and `zig build check-runtime-boundary` gates runtime modules
  against offline TextMate/Sublime parser and converter imports. Shiki's
  packaged 253 language routes now report `missing=0` and
  `external_missing=0`, convert offline to native `.zhl` with `skipped=0`,
  pass `check-native`, and emit generated native Zig.
- Full Oniguruma compatibility is not proven. The native regex VM supports the
  currently checked-in grammar patterns, but the full Oniguruma behavior matrix
  needs more targeted conformance cases.
- Sublime support is broader but still not full ecosystem-wide. Current gates
  cover local fixtures and a large upstream package corpus subset, not every
  public Sublime syntax.
- P0 benchmark corpus is not fully real-world yet; several first-pass native
  P0 rows still use committed language fixtures instead of licensed external
  or repo-owned corpus snippets.
## Next Slices

- Expand TextMate/Sublime corpus checks beyond the checked-in grammar set.
- Expand independent TextMate dependency-graph evidence beyond the current
  VS Code fixture set and Shiki reconstructed corpus.
- Add focused Oniguruma compatibility tests for regex behavior beyond current
  checked-in grammar coverage.
- Keep all new grammar behavior data-driven; do not add language-specific
  engine branches.
