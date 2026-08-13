const std = @import("std");
const token = @import("../runtime/token.zig");

pub fn renderAnsiLine(writer: anytype, line: []const u8, tokens: []const token.Token) !void {
    var cursor: usize = 0;
    for (tokens) |tok| {
        const start: usize = tok.start;
        const end: usize = tok.end;
        if (start > cursor) {
            try writer.writeAll("\x1b[0m");
            try writer.writeAll(line[cursor..start]);
        }
        try writer.writeAll(tok.style_id.ansi());
        try writer.writeAll(line[start..end]);
        cursor = end;
    }
    if (cursor < line.len) {
        try writer.writeAll("\x1b[0m");
        try writer.writeAll(line[cursor..]);
    } else {
        try writer.writeAll("\x1b[0m");
    }
}

pub fn renderHtmlLine(writer: anytype, line: []const u8, tokens: []const token.Token) !void {
    var cursor: usize = 0;
    for (tokens) |tok| {
        const start: usize = tok.start;
        const end: usize = tok.end;
        if (start > cursor) try writeEscapedHtml(writer, line[cursor..start]);
        try writer.print("<span class=\"{s}\">", .{tok.style_id.cssClass()});
        try writeEscapedHtml(writer, line[start..end]);
        try writer.writeAll("</span>");
        cursor = end;
    }
    if (cursor < line.len) try writeEscapedHtml(writer, line[cursor..]);
}

pub fn renderDebugLine(writer: anytype, line_no: usize, tokens: []const token.Token) !void {
    for (tokens) |tok| {
        try writer.print("{d}:{d}:{d}:{s}:{s}:{d}\n", .{
            line_no,
            tok.start,
            tok.end,
            @tagName(tok.style_id),
            @tagName(tok.scope_stack_id),
            tok.language_id,
        });
    }
}

fn writeEscapedHtml(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(byte),
        }
    }
}

test "renderHtmlLine escapes source bytes" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const toks = [_]token.Token{.{ .start = 0, .end = 3, .style_id = .string }};
    try renderHtmlLine(&writer, "\"<&", &toks);
    try std.testing.expectEqualStrings("<span class=\"zhl-string\">&quot;&lt;&amp;</span>", buf[0..writer.end]);
}

test "renderHtmlLine preserves plain gaps" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const toks = [_]token.Token{.{ .start = 2, .end = 3, .style_id = .string }};
    try renderHtmlLine(&writer, "ab<cd", &toks);
    try std.testing.expectEqualStrings("ab<span class=\"zhl-string\">&lt;</span>cd", buf[0..writer.end]);
}

test "renderAnsiLine preserves plain gaps" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const toks = [_]token.Token{.{ .start = 1, .end = 2, .style_id = .keyword }};
    try renderAnsiLine(&writer, "abc", &toks);
    try std.testing.expectEqualStrings("\x1b[0ma\x1b[35mb\x1b[0mc", buf[0..writer.end]);
}

test "renderDebugLine emits style and scope rows" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const toks = [_]token.Token{.{ .start = 1, .end = 3, .style_id = .keyword, .scope_stack_id = .source_zig, .language_id = 7 }};
    try renderDebugLine(&writer, 7, &toks);
    try std.testing.expectEqualStrings("7:1:3:keyword:source_zig:7\n", buf[0..writer.end]);
}
