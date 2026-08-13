const std = @import("std");
const asset = @import("../../src/asset.zig");
const asset_fixture = @import("asset_test.zig");
const html_source = @import("../../src/html/source.zig");
const html_template = @import("../../src/html/template.zig");

const CssGenerated = SingleAsset(.css, "theme.css", "body{color:#123}");
const ScriptGenerated = SingleAsset(.javascript, "app.js", "start()");
const ImageGenerated = SingleAsset(.svg, "logo.svg", "<svg></svg>");
const FontGenerated = SingleAsset(.woff2, "font.woff2", "woff2");
const DocumentGenerated = SingleAsset(.html, "frame.html", "<!doctype html>");

const CssAssets = asset.Bundle(CssGenerated);
const ScriptAssets = asset.Bundle(ScriptGenerated);
const ImageAssets = asset.Bundle(ImageGenerated);
const FontAssets = asset.Bundle(FontGenerated);
const DocumentAssets = asset.Bundle(DocumentGenerated);

const BufferWriter = struct {
    storage: []u8,
    length: usize = 0,

    pub fn write(writer: *BufferWriter, bytes: []const u8) error{NoSpaceLeft}!void {
        if (bytes.len > writer.storage.len - writer.length) return error.NoSpaceLeft;
        @memcpy(writer.storage[writer.length..][0..bytes.len], bytes);
        writer.length += bytes.len;
    }

    fn written(writer: *const BufferWriter) []const u8 {
        return writer.storage[0..writer.length];
    }
};

test "typed assets render only through media-compatible HTML resource contexts" {
    const Page = html_template.Template(.{
        .View = struct {
            css: @TypeOf(CssAssets.local("theme.css")),
            script: @TypeOf(ScriptAssets.local("app.js")),
            image: @TypeOf(ImageAssets.local("logo.svg")),
            font: @TypeOf(FontAssets.local("font.woff2")),
            document: @TypeOf(DocumentAssets.local("frame.html")),
        },
        .source = fragment(
            "typed-assets",
            "<link rel=\"stylesheet\" href=\"{{view.css}}\">" ++
                "<script src=\"{{view.script}}\"></script>" ++
                "<img src='{{view.image}}'>" ++
                "<link rel=\"preload\" as=\"font\" href=\"{{view.font}}\">" ++
                "<iframe src=\"{{view.document}}\"></iframe>",
        ),
    });
    var output: [1024]u8 = undefined;
    var writer = BufferWriter{ .storage = &output };
    try Page.render(&writer, .{
        .css = CssAssets.local("theme.css"),
        .script = ScriptAssets.local("app.js"),
        .image = ImageAssets.local("logo.svg"),
        .font = FontAssets.local("font.woff2"),
        .document = DocumentAssets.local("frame.html"),
    }, &.{});
    try std.testing.expectEqualStrings(
        "<link rel=\"stylesheet\" href=\"" ++ CssGenerated.assets[0].path ++ "\">" ++
            "<script src=\"" ++ ScriptGenerated.assets[0].path ++ "\"></script>" ++
            "<img src='" ++ ImageGenerated.assets[0].path ++ "'>" ++
            "<link rel=\"preload\" as=\"font\" href=\"" ++
            FontGenerated.assets[0].path ++ "\">" ++
            "<iframe src=\"" ++ DocumentGenerated.assets[0].path ++ "\"></iframe>",
        writer.written(),
    );
}

test "asset origin and path render as two allocation-free escaped writes" {
    const References = CssAssets.References(&.{"https://cdn.example"}, .{});
    const Page = html_template.Template(.{
        .View = struct { css: @TypeOf(CssAssets.local("theme.css")) },
        .source = fragment(
            "asset-origin",
            "<link rel=\"stylesheet\" href=\"{{view.css}}\">",
        ),
    });
    var references: References = undefined;
    try std.testing.expect(references.init(.{
        .origin = "https://cdn.example",
        .prefix = "/v1",
    }) == null);
    var output: [256]u8 = undefined;
    var writer = BufferWriter{ .storage = &output };
    try Page.render(&writer, .{ .css = try references.get("theme.css") }, &.{});
    try std.testing.expectEqualStrings(
        "<link rel=\"stylesheet\" href=\"https://cdn.example/v1" ++
            CssGenerated.assets[0].path ++ "\">",
        writer.written(),
    );
}

test "explicit inline directives emit only comptime-known CSS and JavaScript bytes" {
    const Page = html_template.Template(.{
        .View = struct {},
        .source = fragment(
            "inline-assets",
            "<style>{{@inlineCss critical}}</style>" ++
                "<script>{{@inlineJavaScript bootstrap}}</script>",
        ),
        .assets = .{
            .critical = CssAssets.local("theme.css"),
            .bootstrap = ScriptAssets.local("app.js"),
        },
    });
    var output: [128]u8 = undefined;
    var writer = BufferWriter{ .storage = &output };
    try Page.render(&writer, .{}, &.{});
    try std.testing.expectEqualStrings(
        "<style>" ++ CssGenerated.assets[0].identity.bytes ++ "</style>" ++
            "<script>" ++ ScriptGenerated.assets[0].identity.bytes ++ "</script>",
        writer.written(),
    );
}

fn SingleAsset(
    comptime kind: asset.MediaKind,
    comptime logical_name: []const u8,
    comptime bytes: []const u8,
) type {
    const digest_value = sha256(bytes);
    const path_value = assetPath(logical_name, digest_value);
    const etag_value = assetEtag(digest_value);
    return struct {
        pub const format_version: u16 = asset.format_version;
        pub const route_prefix = "/assets/";
        pub const MediaKind = asset_fixture.Generated.MediaKind;
        pub const Representation = asset_fixture.Generated.Representation;
        pub const Asset = asset_fixture.Generated.Asset;
        pub const path = path_value;
        pub const etag = etag_value;
        pub const assets = [_]Asset{.{
            .logical_name = logical_name,
            .path = &path,
            .media_kind = @enumFromInt(@intFromEnum(kind)),
            .media_type = asset.mediaType(kind),
            .identity = .{
                .bytes = bytes,
                .digest = digest_value,
                .etag = &etag,
            },
            .gzip = null,
        }};
    };
}

fn assetPath(comptime logical_name: []const u8, comptime digest: [32]u8) [
    "/assets/".len + 32 + 1 + logical_name.len
]u8 {
    var result: ["/assets/".len + 32 + 1 + logical_name.len]u8 = undefined;
    @memcpy(result[0.."/assets/".len], "/assets/");
    for (digest[0..16], 0..) |byte, index| {
        result["/assets/".len + index * 2] = lower_hex[byte >> 4];
        result["/assets/".len + index * 2 + 1] = lower_hex[byte & 0x0f];
    }
    const slash = "/assets/".len + 32;
    result[slash] = '/';
    @memcpy(result[slash + 1 ..], logical_name);
    return result;
}

fn assetEtag(comptime digest: [32]u8) [66]u8 {
    var result: [66]u8 = undefined;
    result[0] = '"';
    for (digest, 0..) |byte, index| {
        result[1 + index * 2] = lower_hex[byte >> 4];
        result[2 + index * 2] = lower_hex[byte & 0x0f];
    }
    result[65] = '"';
    return result;
}

fn sha256(comptime bytes: []const u8) [32]u8 {
    @setEvalBranchQuota(100_000);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn fragment(comptime graph_name: []const u8, comptime bytes: []const u8) html_source.SourceSpec {
    return .{
        .kind = .fragment,
        .graph_name = graph_name,
        .file_path = "views/" ++ graph_name ++ ".html",
        .bytes = bytes,
    };
}

const lower_hex = "0123456789abcdef";
