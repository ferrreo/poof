const std = @import("std");
const render = @import("../../src/html/render.zig");
const inline_text = @import("../../src/inline_text.zig");

const BufferWriter = struct {
    storage: []u8,
    length: usize = 0,

    const WriteError = error{NoSpaceLeft};

    fn init(storage: []u8) BufferWriter {
        return .{ .storage = storage };
    }

    pub fn write(writer: *BufferWriter, input: []const u8) WriteError!void {
        if (input.len > writer.storage.len - writer.length) return error.NoSpaceLeft;
        @memcpy(writer.storage[writer.length..][0..input.len], input);
        writer.length += input.len;
    }

    fn bytes(writer: *const BufferWriter) []const u8 {
        return writer.storage[0..writer.length];
    }

    fn reset(writer: *BufferWriter) void {
        writer.length = 0;
    }
};

test "text and quoted attributes use exact context escapes" {
    var storage: [256]u8 = undefined;
    var writer = BufferWriter.init(&storage);

    try render.writeText(&writer, "Grüße & <x> \"q\" 's'");
    try std.testing.expectEqualStrings(
        "Grüße &amp; &lt;x&gt; \"q\" 's'",
        writer.bytes(),
    );

    writer.reset();
    try render.writeAttribute(&writer, .double, "&<>\"'");
    try std.testing.expectEqualStrings("&amp;&lt;&gt;&quot;'", writer.bytes());

    writer.reset();
    try render.writeAttribute(&writer, .single, "&<>\"'");
    try std.testing.expectEqualStrings("&amp;&lt;&gt;\"&#39;", writer.bytes());
}

test "SIMD scan finds escapes at and across every lane boundary" {
    const prefix = "a" ** 31;
    const input = prefix ++ "<&" ++ prefix ++ ">";
    const expected = prefix ++ "&lt;&amp;" ++ prefix ++ "&gt;";
    var storage: [expected.len]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try render.writeRcData(&writer, input);
    try std.testing.expectEqualStrings(expected, writer.bytes());
}

test "invalid UTF-8 fails before writer mutation in every text context" {
    const invalid = [_]u8{ 0xc0, 0x80, '<' };
    var storage: [64]u8 = undefined;
    var writer = BufferWriter.init(&storage);

    try std.testing.expectError(error.InvalidUtf8, render.writeText(&writer, &invalid));
    try std.testing.expectEqual(@as(usize, 0), writer.length);
    try std.testing.expectError(
        error.InvalidUtf8,
        render.writeAttribute(&writer, .double, &invalid),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.length);
}

test "writer errors propagate without hidden allocation or retry" {
    var storage: [3]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try std.testing.expectError(error.NoSpaceLeft, render.writeText(&writer, "a<b"));
    try std.testing.expectEqualStrings("a", writer.bytes());
}

test "typed values render booleans integers byte text and enum tags" {
    const Kind = enum { ready, @"<&" };
    var storage: [512]u8 = undefined;
    var writer = BufferWriter.init(&storage);

    try render.writeValue(&writer, .html_data, true);
    try writer.write("|");
    try render.writeValue(&writer, .html_data, @as(i128, std.math.minInt(i128)));
    try writer.write("|");
    try render.writeValue(&writer, .html_data, @as(u128, std.math.maxInt(u128)));
    try writer.write("|");
    try render.writeValue(&writer, .html_data, Kind.@"<&");
    try writer.write("|");
    const array = [_]u8{ 'x', '<', 'y' };
    try render.writeValue(&writer, .attribute_double_quoted, array);
    try writer.write("|");
    const slice: []const u8 = "a\"b";
    try render.writeValue(&writer, .attribute_double_quoted, slice);

    try std.testing.expectEqualStrings(
        "true|-170141183460469231731687303715884105728|" ++
            "340282366920938463463374607431768211455|&lt;&amp;|x&lt;y|a&quot;b",
        writer.bytes(),
    );
}

test "wide integers remain exact and allocation-free" {
    const Wide = i257;
    const value: Wide = std.math.minInt(Wide);
    var storage: [128]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try render.writeValue(&writer, .html_data, value);
    try std.testing.expectEqualStrings(
        "-115792089237316195423570985008687907853269984665640564039457584007913129639936",
        writer.bytes(),
    );
}

test "non-exhaustive enum unknown tag fails before output" {
    const Status = enum(u8) { ready = 1, _ };
    const unknown: Status = @enumFromInt(2);
    var storage: [32]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try std.testing.expectError(
        error.UnknownEnumTag,
        render.writeValue(&writer, .html_data, unknown),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.length);
}

test "InlineText and closed formatText hooks remain escaped" {
    const Text = inline_text.InlineText(32);
    const Badge = struct {
        count: u8,

        pub fn formatText(self: @This()) inline_text.Error!Text {
            return Text.print("<{d}>", .{self.count});
        }
    };
    const Label = struct {
        pub fn formatText(_: @This()) Text {
            return Text.init("plain<&") catch unreachable;
        }
    };
    var storage: [64]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try render.writeValue(&writer, .html_data, try Text.init("<&"));
    try writer.write("|");
    try render.writeValue(&writer, .html_data, Badge{ .count = 7 });
    try writer.write("|");
    try render.writeValue(&writer, .html_data, Label{});
    try std.testing.expectEqualStrings(
        "&lt;&amp;|&lt;7&gt;|plain&lt;&amp;",
        writer.bytes(),
    );
}

test "formatText hook errors propagate before output" {
    const Text = inline_text.InlineText(8);
    const Badge = struct {
        pub fn formatText(_: @This()) error{Rejected}!Text {
            return error.Rejected;
        }
    };
    var storage: [32]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try std.testing.expectError(
        error.Rejected,
        render.writeValue(&writer, .html_data, Badge{}),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.length);
}

test "forged InlineText invalid UTF-8 fails closed in ReleaseFast" {
    const Text = inline_text.InlineText(8);
    var forged = Text{
        .storage = [_]u8{0} ** 8,
        .length = 2,
    };
    forged.storage[0] = 0xc0;
    forged.storage[1] = 0x80;
    var storage: [32]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try std.testing.expectError(
        error.InvalidUtf8,
        render.writeValue(&writer, .html_data, forged),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.length);
}

test "TrustedHtml literal and explicit unsafe borrow emit only in raw primitive" {
    const Html = render.TrustedHtml(64);
    const literal = Html.literal("<strong>safe</strong>");
    var mutable = [_]u8{ '<', 'b', '>', 'x', '<', '/', 'b', '>' };
    const borrowed = try Html.unsafeAssumeSanitized(&mutable);
    mutable[3] = 'y';

    var storage: [64]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try render.writeTrustedHtml(&writer, literal);
    try writer.write("|");
    try render.writeTrustedHtml(&writer, borrowed);
    try std.testing.expectEqualStrings(
        "<strong>safe</strong>|<b>y</b>",
        writer.bytes(),
    );
}

test "TrustedHtml enforces bound and UTF-8 before output in ReleaseFast" {
    const Html = render.TrustedHtml(4);
    try std.testing.expectError(error.BoundExceeded, Html.unsafeAssumeSanitized("12345"));
    const invalid = [_]u8{ 0xc0, 0x80 };
    const trusted = try Html.unsafeAssumeSanitized(&invalid);
    const forged = Html{ ._borrowed = "12345" };
    var storage: [32]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try std.testing.expectError(error.InvalidUtf8, render.writeTrustedHtml(&writer, trusted));
    try std.testing.expectEqual(@as(usize, 0), writer.length);
    try std.testing.expectError(error.BoundExceeded, render.writeTrustedHtml(&writer, forged));
    try std.testing.expectEqual(@as(usize, 0), writer.length);
}

test "browser JSON is typed bounded and safe for script data" {
    const value = .{ .text = "</script>&'\u{2028}\u{2029}" };
    var scratch: [256]u8 = undefined;
    var storage: [512]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try render.writeBrowserJson(
        .{ .encoded_bytes_max = 256 },
        &writer,
        "page-state",
        value,
        &scratch,
    );
    try std.testing.expectEqualStrings(
        "<script type=\"application/json\" id=\"page-state\">" ++
            "{\"text\":\"\\u003c/script\\u003e\\u0026\\u0027\\u2028\\u2029\"}" ++
            "</script>",
        writer.bytes(),
    );
}

test "browser JSON encoding failure leaves writer untouched" {
    const value = .{ .message = "too large" };
    var scratch: [4]u8 = undefined;
    var storage: [64]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try std.testing.expectError(
        error.ResponseBodyTooLarge,
        render.writeBrowserJson(.{ .encoded_bytes_max = 4 }, &writer, "state", value, &scratch),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.length);
}

test "static SVG is comptime-validated and emitted exactly" {
    const svg = "<svg viewBox=\"0 0 10 10\"><title>Ok</title><path d=\"M0 0\"/></svg>";
    var storage: [svg.len]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try render.writeStaticSvg(&writer, svg);
    try std.testing.expectEqualStrings(svg, writer.bytes());
}

test "empty valid text performs no writer call" {
    var storage: [0]u8 = .{};
    var writer = BufferWriter.init(&storage);
    try render.writeText(&writer, "");
    try std.testing.expectEqual(@as(usize, 0), writer.length);
}
