const std = @import("std");
const highlight = @import("highlight.zig");

pub const source_bytes_max = 64 * 1024;
pub const nesting_max = 8;

pub const Error = std.Io.Writer.Error || error{
    InvalidUtf8,
    SourceTooLarge,
    UnterminatedFence,
};

const ListKind = enum {
    none,
    unordered,
    ordered,
};

pub fn render(writer: *std.Io.Writer, source: []const u8) Error!void {
    if (source.len > source_bytes_max) return error.SourceTooLarge;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;

    var cursor: usize = 0;
    var list: ListKind = .none;
    while (cursor < source.len) {
        const current = lineAt(source, cursor);
        cursor = current.next;
        const line = std.mem.trimEnd(u8, current.bytes, "\r");
        if (line.len == 0) {
            try closeList(writer, &list);
            continue;
        }

        if (std.mem.startsWith(u8, line, "```")) {
            try closeList(writer, &list);
            const language = std.mem.trim(u8, line[3..], " \t");
            const code_start = cursor;
            var scan = cursor;
            var code_end: ?usize = null;
            while (scan < source.len) {
                const candidate = lineAt(source, scan);
                const candidate_line = std.mem.trimEnd(u8, candidate.bytes, "\r");
                if (std.mem.eql(u8, std.mem.trim(u8, candidate_line, " \t"), "```")) {
                    code_end = if (scan > code_start and source[scan - 1] == '\n')
                        scan - 1
                    else
                        scan;
                    cursor = candidate.next;
                    break;
                }
                scan = candidate.next;
            }
            const end = code_end orelse return error.UnterminatedFence;
            try highlight.renderFence(writer, source[code_start..end], language);
            continue;
        }

        if (heading(line)) |value| {
            try closeList(writer, &list);
            try writer.print("<h{d}>", .{value.level});
            try renderInline(writer, value.text, 0);
            try writer.print("</h{d}>", .{value.level});
            continue;
        }

        if (std.mem.startsWith(u8, line, "> ")) {
            try closeList(writer, &list);
            try writer.writeAll("<blockquote>");
            try renderInline(writer, line[2..], 0);
            try writer.writeAll("</blockquote>");
            continue;
        }

        if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ")) {
            try ensureList(writer, &list, .unordered);
            try writer.writeAll("<li>");
            try renderInline(writer, line[2..], 0);
            try writer.writeAll("</li>");
            continue;
        }
        if (orderedItem(line)) |item| {
            try ensureList(writer, &list, .ordered);
            try writer.writeAll("<li>");
            try renderInline(writer, item, 0);
            try writer.writeAll("</li>");
            continue;
        }

        try closeList(writer, &list);
        try writer.writeAll("<p>");
        try renderInline(writer, line, 0);
        try writer.writeAll("</p>");
    }
    try closeList(writer, &list);
}

fn renderInline(writer: *std.Io.Writer, source: []const u8, depth: u8) Error!void {
    if (depth >= nesting_max) return highlight.escapeHtml(writer, source);
    var cursor: usize = 0;
    while (cursor < source.len) {
        if (source[cursor] == '`') {
            if (std.mem.indexOfScalarPos(u8, source, cursor + 1, '`')) |end| {
                try writer.writeAll("<code>");
                try highlight.escapeHtml(writer, source[cursor + 1 .. end]);
                try writer.writeAll("</code>");
                cursor = end + 1;
                continue;
            }
        }
        if (std.mem.startsWith(u8, source[cursor..], "**")) {
            if (std.mem.indexOfPos(u8, source, cursor + 2, "**")) |end| {
                try writer.writeAll("<strong>");
                try renderInline(writer, source[cursor + 2 .. end], depth + 1);
                try writer.writeAll("</strong>");
                cursor = end + 2;
                continue;
            }
        }
        if (source[cursor] == '*') {
            if (std.mem.indexOfScalarPos(u8, source, cursor + 1, '*')) |end| {
                try writer.writeAll("<em>");
                try renderInline(writer, source[cursor + 1 .. end], depth + 1);
                try writer.writeAll("</em>");
                cursor = end + 1;
                continue;
            }
        }
        if (source[cursor] == '[') {
            if (linkAt(source, cursor)) |link| {
                if (safeLink(link.url)) {
                    try writer.writeAll("<a href=\"");
                    try escapeAttribute(writer, link.url);
                    try writer.writeAll("\" rel=\"nofollow noopener\">");
                    try renderInline(writer, link.label, depth + 1);
                    try writer.writeAll("</a>");
                    cursor = link.next;
                    continue;
                }
            }
        }

        const next = nextSpecial(source, cursor + 1);
        try highlight.escapeHtml(writer, source[cursor..next]);
        cursor = next;
    }
}

const Line = struct {
    bytes: []const u8,
    next: usize,
};

fn lineAt(source: []const u8, start: usize) Line {
    const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    return .{
        .bytes = source[start..end],
        .next = if (end < source.len) end + 1 else end,
    };
}

fn heading(line: []const u8) ?struct { level: u3, text: []const u8 } {
    var count: usize = 0;
    while (count < line.len and count < 3 and line[count] == '#') count += 1;
    if (count == 0 or count == line.len or line[count] != ' ') return null;
    return .{ .level = @intCast(count), .text = line[count + 1 ..] };
}

fn orderedItem(line: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < line.len and cursor < 9 and std.ascii.isDigit(line[cursor])) {
        cursor += 1;
    }
    if (cursor == 0 or cursor + 1 >= line.len or line[cursor] != '.' or
        line[cursor + 1] != ' ')
    {
        return null;
    }
    return line[cursor + 2 ..];
}

fn ensureList(writer: *std.Io.Writer, current: *ListKind, wanted: ListKind) Error!void {
    if (current.* == wanted) return;
    try closeList(writer, current);
    try writer.writeAll(if (wanted == .ordered) "<ol>" else "<ul>");
    current.* = wanted;
}

fn closeList(writer: *std.Io.Writer, current: *ListKind) Error!void {
    switch (current.*) {
        .none => {},
        .ordered => try writer.writeAll("</ol>"),
        .unordered => try writer.writeAll("</ul>"),
    }
    current.* = .none;
}

const Link = struct {
    label: []const u8,
    url: []const u8,
    next: usize,
};

fn linkAt(source: []const u8, start: usize) ?Link {
    const label_end = std.mem.indexOfScalarPos(u8, source, start + 1, ']') orelse return null;
    if (label_end + 1 >= source.len or source[label_end + 1] != '(') return null;
    const url_end = std.mem.indexOfScalarPos(u8, source, label_end + 2, ')') orelse return null;
    return .{
        .label = source[start + 1 .. label_end],
        .url = source[label_end + 2 .. url_end],
        .next = url_end + 1,
    };
}

fn safeLink(value: []const u8) bool {
    if (value.len == 0 or value.len > 512) return false;
    const uri = std.Uri.parse(value) catch return false;
    return (std.mem.eql(u8, uri.scheme, "https") or
        std.mem.eql(u8, uri.scheme, "http")) and
        uri.host != null and uri.user == null and uri.password == null;
}

fn escapeAttribute(writer: *std.Io.Writer, value: []const u8) Error!void {
    for (value) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(byte),
        }
    }
}

fn nextSpecial(source: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < source.len) : (cursor += 1) {
        switch (source[cursor]) {
            '`', '*', '[' => return cursor,
            else => {},
        }
    }
    return source.len;
}

test "Markdown escapes HTML and dangerous links" {
    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try render(
        &writer,
        "# Hello\n<script>alert(1)</script>\n[bad](javascript:alert(1))\n[good](https://example.com/a?b=1&c=2)",
    );
    const output = storage[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "<h1>Hello</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "javascript:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "href=\"javascript:") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "href=\"https://example.com/a?b=1&amp;c=2\"",
    ) != null);
}

test "Markdown renders lists emphasis and highlighted fences" {
    var storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try render(
        &writer,
        "- **Fast**\n- `safe`\n\n```javascript\nconst value = \"<&\";\n```",
    );
    const output = storage[0..writer.end];
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "<ul><li><strong>Fast</strong></li><li><code>safe</code></li></ul>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "data-language=\"javascript\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zhl-keyword") != null);
}

test "Markdown requires a closing code fence" {
    var storage: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.UnterminatedFence, render(&writer, "```zig\nconst x = 1;"));
}
