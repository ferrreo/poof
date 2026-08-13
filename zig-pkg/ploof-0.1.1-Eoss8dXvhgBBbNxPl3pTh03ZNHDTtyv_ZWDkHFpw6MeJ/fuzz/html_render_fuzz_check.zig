const std = @import("std");
const render = @import("../src/html/render.zig");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");

test "HTML rendering differential and browser-boundary fuzz" {
    try std.testing.fuzz({}, fuzzRender, .{ .corpus = &fuzz_corpus });
}

const fuzz_corpus = struct {
    const empty = fuzz_support.smithInput("");
    const escapes = fuzz_support.smithInput("<&>\"'</script>");
    const lanes = fuzz_support.smithInput(("a" ** 31) ++ "<&" ++ ("b" ** 32) ++ ">");
    const unicode = fuzz_support.smithInput("Grüße € 𝄞 \u{2028}\u{2029}");
    const invalid = fuzz_support.smithInput("\xff\xc0\x80");
    const values = [_][]const u8{ &empty, &escapes, &lanes, &unicode, &invalid };
}.values;

const BufferWriter = struct {
    storage: []u8,
    length: usize = 0,

    pub fn write(writer: *BufferWriter, input: []const u8) error{NoSpaceLeft}!void {
        if (input.len > writer.storage.len - writer.length) return error.NoSpaceLeft;
        @memcpy(writer.storage[writer.length..][0..input.len], input);
        writer.length += input.len;
    }

    fn bytes(writer: *const BufferWriter) []const u8 {
        return writer.storage[0..writer.length];
    }
};

fn fuzzRender(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [1024]u8 = undefined;
    const input = input_storage[0..smith.slice(&input_storage)];
    inline for (.{
        render.EscapeContext.html_data,
        render.EscapeContext.rcdata,
        render.EscapeContext.attribute_double_quoted,
        render.EscapeContext.attribute_single_quoted,
    }) |context| {
        try checkEscaping(context, input);
    }
    try checkTrustedHtml(input);
    try checkBrowserJson(input);
}

fn checkEscaping(comptime context: render.EscapeContext, input: []const u8) !void {
    var actual_storage: [6 * 1024]u8 = undefined;
    var expected_storage: [6 * 1024]u8 = undefined;
    var actual = BufferWriter{ .storage = &actual_storage };
    var expected = BufferWriter{ .storage = &expected_storage };

    const valid = std.unicode.utf8ValidateSlice(input);
    if (!valid) {
        try std.testing.expectError(
            error.InvalidUtf8,
            render.writeValue(&actual, context, input),
        );
        try std.testing.expectEqual(@as(usize, 0), actual.length);
        return;
    }
    try render.writeValue(&actual, context, input);
    try oracleEscape(&expected, context, input);
    try std.testing.expectEqualStrings(expected.bytes(), actual.bytes());
}

fn oracleEscape(
    writer: *BufferWriter,
    comptime context: render.EscapeContext,
    input: []const u8,
) !void {
    for (input) |byte| {
        switch (byte) {
            '&' => try writer.write("&amp;"),
            '<' => try writer.write("&lt;"),
            '>' => try writer.write("&gt;"),
            '"' => if (context == .attribute_double_quoted)
                try writer.write("&quot;")
            else
                try writer.write("\""),
            '\'' => if (context == .attribute_single_quoted)
                try writer.write("&#39;")
            else
                try writer.write("'"),
            else => try writer.write(&.{byte}),
        }
    }
}

fn checkTrustedHtml(input: []const u8) !void {
    const Html = render.TrustedHtml(1024);
    const trusted = try Html.unsafeAssumeSanitized(input);
    var storage: [1024]u8 = undefined;
    var writer = BufferWriter{ .storage = &storage };
    if (!std.unicode.utf8ValidateSlice(input)) {
        try std.testing.expectError(error.InvalidUtf8, render.writeTrustedHtml(&writer, trusted));
        try std.testing.expectEqual(@as(usize, 0), writer.length);
        return;
    }
    try render.writeTrustedHtml(&writer, trusted);
    try std.testing.expectEqualStrings(input, writer.bytes());
}

fn checkBrowserJson(input: []const u8) !void {
    var scratch: [8 * 1024]u8 = undefined;
    var output: [9 * 1024]u8 = undefined;
    var writer = BufferWriter{ .storage = &output };
    const result = render.writeBrowserJson(
        .{ .encoded_bytes_max = scratch.len },
        &writer,
        "fuzz-state",
        .{ .value = input },
        &scratch,
    );
    if (!std.unicode.utf8ValidateSlice(input)) {
        try std.testing.expectError(error.InvalidUtf8, result);
        try std.testing.expectEqual(@as(usize, 0), writer.length);
        return;
    }
    try result;
    const opening = "<script type=\"application/json\" id=\"fuzz-state\">";
    const suffix = "</script>";
    try std.testing.expect(std.mem.startsWith(u8, writer.bytes(), opening));
    try std.testing.expect(std.mem.endsWith(u8, writer.bytes(), suffix));
    const encoded = writer.bytes()[opening.len .. writer.length - suffix.len];
    for ([_][]const u8{ "<", ">", "&", "'", "\xe2\x80\xa8", "\xe2\x80\xa9" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, encoded, needle) == null);
    }
}
