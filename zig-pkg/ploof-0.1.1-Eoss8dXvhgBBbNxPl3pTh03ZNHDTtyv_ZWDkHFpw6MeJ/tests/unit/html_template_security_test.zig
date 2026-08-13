const std = @import("std");
const html_render = @import("../../src/html/render.zig");
const html_source = @import("../../src/html/source.zig");
const html_template = @import("../../src/html/template.zig");
const url = @import("../../src/url.zig");

const Writer = struct {
    storage: []u8,
    length: usize = 0,

    pub fn write(writer: *Writer, chunk: []const u8) error{NoSpaceLeft}!void {
        if (chunk.len > writer.storage.len - writer.length) return error.NoSpaceLeft;
        @memcpy(writer.storage[writer.length..][0..chunk.len], chunk);
        writer.length += chunk.len;
    }

    fn bytes(writer: *const Writer) []const u8 {
        return writer.storage[0..writer.length];
    }
};

test "untrusted values are escaped for HTML RCDATA and both attribute quotes" {
    const View = struct { value: []const u8 };
    const Page = html_template.Template(.{
        .View = View,
        .source = fragment(
            "xss-contexts",
            "<p>{{view.value}}</p><textarea>{{view.value}}</textarea>" ++
                "<div title=\"{{view.value}}\" data-label='{{view.value}}'></div>",
        ),
    });
    var output: [512]u8 = undefined;
    var writer = Writer{ .storage = &output };
    try Page.render(&writer, .{ .value = "<&>\"'" }, &.{});
    try std.testing.expectEqualStrings(
        "<p>&lt;&amp;&gt;\"'</p><textarea>&lt;&amp;&gt;\"'</textarea>" ++
            "<div title=\"&lt;&amp;&gt;&quot;'\" " ++
            "data-label='&lt;&amp;&gt;\"&#39;'></div>",
        writer.bytes(),
    );
}

test "attribute quote state ignores opposite-quote assignments and raw text" {
    const View = struct { value: []const u8 };
    const Page = html_template.Template(.{
        .View = View,
        .source = fragment(
            "exact-attribute-quotes",
            "<script>const fake = \"<div title='noise'>\";</script>" ++
                "<textarea><div title='noise'></textarea>" ++
                "<div title=\"x='{{view.value}}'\" " ++
                "data-label='y=\"{{view.value}}\"'></div>",
        ),
    });
    var output: [512]u8 = undefined;
    var writer = Writer{ .storage = &output };
    try Page.render(&writer, .{ .value = "<&>\"'" }, &.{});
    try std.testing.expectEqualStrings(
        "<script>const fake = \"<div title='noise'>\";</script>" ++
            "<textarea><div title='noise'></textarea>" ++
            "<div title=\"x='&lt;&amp;&gt;&quot;''\" " ++
            "data-label='y=\"&lt;&amp;&gt;\"&#39;\"'></div>",
        writer.bytes(),
    );
}

test "TrustedHtml is raw only in HTML data and validates forged bytes" {
    const Trusted = html_render.TrustedHtml(32);
    const View = struct { markup: Trusted };
    const Page = html_template.Template(.{
        .View = View,
        .source = fragment("trusted-html", "<section>{{view.markup}}</section>"),
    });
    var output: [128]u8 = undefined;
    var writer = Writer{ .storage = &output };
    const markup = try Trusted.unsafeAssumeSanitized("<b>safe</b>");
    try Page.render(&writer, .{ .markup = markup }, &.{});
    try std.testing.expectEqualStrings("<section><b>safe</b></section>", writer.bytes());

    const invalid_bytes = [_]u8{ 0xc0, 0x80 };
    const forged = try Trusted.unsafeAssumeSanitized(&invalid_bytes);
    writer.length = 0;
    try std.testing.expectError(
        error.InvalidUtf8,
        Page.render(&writer, .{ .markup = forged }, &.{}),
    );
    try std.testing.expectEqualStrings("<section>", writer.bytes());
}

test "forged Url is revalidated before dynamic bytes reach output" {
    const View = struct { destination: url.Url };
    const Page = html_template.Template(.{
        .View = View,
        .source = fragment("forged-url", "<a href=\"{{view.destination}}\">x</a>"),
    });
    const forged = url.Url{
        .bytes_value = "javascript:alert(1)",
        .kind_value = .local,
    };
    var output: [128]u8 = undefined;
    var writer = Writer{ .storage = &output };
    try std.testing.expectError(
        error.InvalidLocalReference,
        Page.render(&writer, .{ .destination = forged }, &.{}),
    );
    try std.testing.expectEqualStrings("<a href=\"", writer.bytes());
}

test "writer exhaustion propagates without template commit or retry" {
    const View = struct { value: []const u8 };
    const Page = html_template.Template(.{
        .View = View,
        .source = fragment("writer-exhaustion", "prefix/{{view.value}}/suffix"),
    });
    var output: [8]u8 = undefined;
    var writer = Writer{ .storage = &output };
    try std.testing.expectError(
        error.NoSpaceLeft,
        Page.render(&writer, .{ .value = "long value" }, &.{}),
    );
    try std.testing.expectEqualStrings("prefix/", writer.bytes());
}

fn fragment(comptime name: []const u8, comptime bytes: []const u8) html_source.SourceSpec {
    return .{
        .kind = .fragment,
        .graph_name = name,
        .file_path = "security/" ++ name ++ ".html",
        .bytes = bytes,
    };
}
