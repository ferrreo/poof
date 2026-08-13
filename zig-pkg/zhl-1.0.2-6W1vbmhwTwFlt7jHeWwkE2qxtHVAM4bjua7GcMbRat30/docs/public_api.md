# zhl Public API

This is the v1 public surface exported by `@import("zhl")`. Changing an
exported name, `EngineOptions` field, `HighlightError` member, generated
grammar shape, or `.zhlb` version is a compatibility change and must update
this document and the matching tests.

## Runtime API

- `Engine`
- `EngineOptions`
- `HighlightError`
- `LineResult`
- `Token`
- `PackedToken`
- `StyleId`
- `ScopeStackId`
- `sinks`
- `renderers`
- `document`
- `tree_sitter`
- `wasm`

`Engine(grammar, options)` is the stable runtime entry point. The returned type
exposes `State`, `Scratch`, `LineResult`, `grammar_name`, `init`, and
`highlightLine`. Callers own `State`, `Scratch`, and sinks; `highlightLine`
does not allocate for native generated grammars.

`sinks` exports stable sink helpers:

- `NullSink`
- `DebugSink`
- `TokenBuffer`

`renderers` exports stable line renderers:

- `renderAnsiLine`
- `renderHtmlLine`
- `renderDebugLine`

`document` exports stable incremental highlighting helpers:

- `DirtyRange`
- `LineCache`

`tree_sitter` exports stable overlay helpers:

- `LanguageId`
- `no_language`
- `Capture`
- `styleFromCaptureName`
- `applyOverlay`
- `applyAdapterLine`
- `applyOverlayLine`

`EngineOptions` fields are stable v1 configuration:

- `max_stack_depth`
- `max_dynamic_capture_bytes`
- `max_regex_vm_stack`
- `max_capture_slots`
- `max_line_bytes`
- `max_tokens_per_line`
- `offset_type`
- `emit_scopes`
- `emit_style_ids`

`HighlightError` members are stable v1 failures:

- `StackOverflow`
- `DynamicCaptureOverflow`
- `RegexVmStackOverflow`
- `RegexCaptureOverflow`
- `RegexStepLimitExceeded`
- `TokenOverflow`
- `LineTooLong`
- `MalformedGrammar`

## Grammar And Compiler API

- `dsl`
- `native_runtime`
- `binary`
- `theme`
- `textmate`
- `textmate_captures`
- `textmate_dynamic`
- `textmate_include`
- `textmate_import`
- `textmate_injection`
- `textmate_keyword`
- `textmate_convert`
- `textmate_convert_regex`
- `textmate_plist`
- `textmate_reachability`
- `textmate_types`
- `sublime`
- `sublime_convert`
- `dynamic_end`

These modules are public for offline compiler/tooling use. Runtime code should
use generated native grammars, not parse TextMate, plist, Sublime, or theme
source at highlight time.

## Regex API

- `regex`
- `regex_absent`
- `regex_vm`
- `regex_classes`
- `regex_validate`
- `regex_scratch`
- `regex_unicode`
- `ByteMask256`
- `scan`
- `style`
- `token`

Regex programs are compiled ahead of use and matched with caller-owned scratch.
They are public because generated grammars and compatibility tests rely on the
same matcher contracts.

## Generated Grammar ABI

Generated grammar modules export:

- `pub const grammar`
- `pub const name`

The grammar value must provide:

- `highlightLine(options, line, state, scratch, sink)`

`src/runtime/native_runtime.zig` owns the native grammar table shape. `zhlc
compile-native` emits modules in that shape and `check-integrations` compiles
generated modules from native, TextMate, plist, and Sublime sources.

The bundled native grammar module `zhl_grammars` also exports a stable language
metadata registry:

- `pub const LanguageId`
- `pub const LanguageMetadata`
- `pub const languages`
- `pub fn findByName(name: []const u8) ?*const LanguageMetadata`
- `pub fn findByExtension(ext: []const u8) ?*const LanguageMetadata`
- `pub fn findByMime(mime: []const u8) ?*const LanguageMetadata`

`zhlc --grammar` resolves canonical names and aliases through this registry.
Extensions may be passed with or without a leading dot.

## Editor Integration Example

`zig build editor-example` runs `examples/editor_tokens.zig`, which resolves a
language by extension, highlights a line into `TokenBuffer`, and maps tokens to
editor rows carrying `start`, `end`, `style_id`, and registry `language_id`.

## Binary Grammar ABI

`.zhlb` is stable at `zhlb v4`. `src/runtime/binary.zig` owns the version constant and
`docs/zhlb.md` owns the byte layout. Version changes require a docs update and
new validation coverage.
