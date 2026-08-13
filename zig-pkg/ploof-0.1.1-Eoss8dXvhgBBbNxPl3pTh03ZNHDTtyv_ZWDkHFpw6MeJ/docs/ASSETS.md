# Embedded asset compiler

`ploof-assets` is a host build artifact. It reads only explicitly enumerated files and emits one
generated Zig module. It does not scan directories, access the network, invoke another compressor,
or modify application source.

## Build wiring

Use one `Run` step and pass its output directly to `root_source_file`:

```zig
const ploof = b.dependency("ploof", .{});
const compile_assets = b.addRunArtifact(ploof.artifact("ploof-assets"));
compile_assets.addArg("--output");
const generated = compile_assets.addOutputFileArg("ploof_assets.zig");

compile_assets.addArgs(&.{ "--asset", "app.css", "css" });
compile_assets.addFileArg(b.path("web/app.css"));
compile_assets.addArgs(&.{ "--asset", "app.js", "javascript" });
compile_assets.addFileArg(b.path("web/app.js"));

const assets = b.createModule(.{ .root_source_file = generated });
application.root_module.addImport("assets", assets);
```

`addFileArg` makes each source an explicit build dependency. `addOutputFileArg` supplies a cached
output path; the tool never chooses or writes a source-tree path itself.

## Command line

```text
ploof-assets --output <generated.zig>
  [--prefix /assets/]
  [--assets-max N]
  [--input-bytes-max N]
  [--generated-bytes-max N]
  --asset <logical-name> <media-kind> <path>...
```

Options appear at most once. At least one `--asset` is required. Logical names are 1–128 bytes from
`[a-z0-9._-]`; `.` and `..` are rejected because browsers repair those path segments. Prefixes begin
and end with `/`, contain nonempty lowercase `[a-z0-9_-]+` segments, and are at most 128 bytes.

Defaults are 256 assets, 64 MiB total input, 512 MiB generated source, and `/assets/`. Corresponding
hard maxima are 4096 assets, 1 GiB input, and 4 GiB generated source. Every limit is replaceable on
the command line up to its hard maximum. Generation first counts exact output bytes, so an output
limit failure occurs before the requested file is opened.

Media kinds are declarations, not extension or content sniffing:

| Kind | Content-Type | Build-time gzip |
| --- | --- | --- |
| `css` | `text/css; charset=utf-8` | 1 KiB–4 MiB |
| `javascript` | `text/javascript; charset=utf-8` | 1 KiB–4 MiB |
| `json` | `application/json; charset=utf-8` | 1 KiB–4 MiB |
| `svg` | `image/svg+xml` | 1 KiB–4 MiB |
| `text` | `text/plain; charset=utf-8` | 1 KiB–4 MiB |
| `html` | `text/html; charset=utf-8` | 1 KiB–4 MiB |
| `xml` | `application/xml` | 1 KiB–4 MiB |
| `png`, `jpeg`, `gif`, `webp`, `avif`, `ico` | matching image type | no |
| `woff`, `woff2`, `ttf`, `otf` | matching font type | no |
| `wasm` | `application/wasm` | no |
| `binary` | `application/octet-stream` | no |

Gzip uses Zig 0.16's standard-library best level. The compiler fixes gzip modification time to zero
and OS to 255. Identical inputs, declarations, prefix, and compiler version therefore emit identical
source and wire bytes.

## Generated module

The module exposes `format_version`, `route_prefix`, `MediaKind`, `Representation`, `Asset`, and one
immutable `assets` array sorted by logical name. Each asset carries its complete public path,
declared media type, identity bytes, full SHA-256 identity digest, and quoted strong ETag. Eligible
assets also carry gzip bytes, their full wire SHA-256 digest, and their own quoted strong ETag.
`Asset.Bundle` recomputes both wire digests at comptime before trusting paths or ETags.

Paths have one exact form:

```text
<prefix><first-128-identity-digest-bits-lowercase-hex>/<logical-name>
```

For example, the default prefix yields `/assets/0123456789abcdef0123456789abcdef/app.css`.

## Runtime bundle and routes

Wrap the generated module once, then include that bundle in the application configuration:

```zig
const ploof = @import("ploof");
const GeneratedAssets = @import("assets");

const Assets = ploof.Asset.Bundle(GeneratedAssets);
const App = ploof.Application(.{
    .State = State,
    .routes = .{
        ploof.route.get("/", index),
    },
    .assets = Assets,
});
```

`App` adds one public GET route per generated asset; HEAD is selected through normal GET/HEAD
routing. These content-addressed routes deliberately bypass application and route middleware.
OPTIONS, redirects, and method rejection still come from the same route graph and expose the
combined `Allow` value.

Delivery allocates nothing and performs no request-time compression. It selects immutable identity
or prebuilt gzip bytes from `Accept-Encoding`, sends the selected representation's strong ETag,
handles `If-None-Match` on GET and HEAD, and emits:

```text
Cache-Control: public, max-age=31536000, immutable
X-Content-Type-Options: nosniff
Vary: Accept-Encoding
```

Range fields are ignored for embedded assets. Use a live static-file route, object storage, or an
edge for large seekable media.

## Typed references and trusted origins

Local references are compile-time typed by media kind:

```zig
const css = Assets.local("app.css");
const javascript = Assets.local("app.js");
```

By default they render the local content-addressed path. A fixed reference table may select one
startup-validated HTTPS origin and path prefix without allocation:

```zig
const References = Assets.References(
    &.{ "https://cdn.example", "https://static.example:8443" },
    .{ .origin_bytes_max = 512, .prefix_bytes_max = 128 },
);

var references: References = undefined;
if (references.init(.{
    .origin = "https://cdn.example",
    .prefix = "/release_7",
})) |failure| {
    return reportAssetOriginFailure(failure);
}
const css = try references.get("app.css");
```

The allowlist and capacities are comptime configuration. The chosen origin is application startup
state; request headers, Host, forwarded metadata, and template view text cannot change it. Local
routes remain available as the canonical fallback.

## HTML templates

An `AssetRef` can be view data in a compatible resource position. Media mismatches fail at
comptime: JavaScript is accepted by `script src`, CSS by stylesheet links, image kinds by image
positions, font kinds by font preloads, and HTML by frame positions. Active positions also accept an
explicit `TrustedResourceUrl`; plain strings and ordinary `Url` values cannot become active
resources.

```zig
const Page = ploof.HtmlTemplate.Template(.{
    .View = struct {
        css: @TypeOf(Assets.local("app.css")),
        javascript: @TypeOf(Assets.local("app.js")),
    },
    .source = .{
        .kind = .fragment,
        .graph_name = "page",
        .file_path = "views/page.html",
        .bytes =
            "<link rel=\"stylesheet\" href=\"{{view.css}}\">" ++
            "<script src=\"{{view.javascript}}\"></script>",
    },
});
```

External references write origin and path as separate escaped chunks; no concatenation buffer is
needed. For deliberately repeated critical content, templates also support compile-time-only inline
assets:

```zig
const InlinePage = ploof.HtmlTemplate.Template(.{
    .View = struct {},
    .source = .{
        .kind = .fragment,
        .graph_name = "inline-page",
        .file_path = "views/inline-page.html",
        .bytes =
            "<style>{{@inlineCss critical}}</style>" ++
            "<script>{{@inlineJavaScript bootstrap}}</script>",
    },
    .assets = .{
        .critical = Assets.local("app.css"),
        .bootstrap = Assets.local("app.js"),
    },
});
```

Inline directives accept only the matching compile-time asset kind. Inline bytes must be NUL-free
UTF-8 and cannot contain an ASCII-case-insensitive `</style` or `</script` sequence. External assets
remain the default because they cache independently and work with stricter Content Security Policy.

## Exit status

- `0`: generated module written.
- `2`: invocation, declaration, prefix, name, media kind, or configured-count error
  (`E5001`–`E5011`).
- `3`: input read, input-byte limit, or digest-collision error (`E5012`–`E5014`).
- `4`: generated-byte limit, output write, compression, or host-memory error (`E5015`–`E5018`).

Diagnostics are one stable `PLOOF-E50xx` line on stderr. Successful generation writes nothing to
stdout or stderr.
