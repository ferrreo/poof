const std = @import("std");
const domain = @import("../domain.zig");
const highlight = @import("highlight.zig");

pub const source_bytes_max = 64 * 1024;
pub const nesting_max = 8;

pub const Error = std.Io.Writer.Error || error{
    InvalidUtf8,
    SourceTooLarge,
    UnterminatedFence,
};

const ListKind = enum {
    unordered,
    ordered,
};

const TaskState = enum {
    none,
    open,
    done,
};

const ListFrame = struct {
    kind: ListKind,
    indent: usize,
    item_open: bool,
};

const ListItem = struct {
    indent: usize,
    kind: ListKind,
    task: TaskState,
    text: []const u8,
};

pub fn render(writer: *std.Io.Writer, source: []const u8) Error!void {
    if (source.len > source_bytes_max) return error.SourceTooLarge;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
    try renderBlocks(writer, source, 0);
}

fn renderBlocks(writer: *std.Io.Writer, source: []const u8, depth: u8) Error!void {
    if (depth >= nesting_max) return highlight.escapeHtml(writer, source);

    var cursor: usize = 0;
    var lists: [nesting_max]ListFrame = undefined;
    var list_depth: usize = 0;
    while (cursor < source.len) {
        const current = lineAt(source, cursor);
        const line = std.mem.trimEnd(u8, current.bytes, "\r");
        const prefix = linePrefix(line);
        if (prefix.content.len == 0) {
            try closeLists(writer, lists[0..], &list_depth, 0);
            cursor = current.next;
            continue;
        }

        if (prefix.indent < 4 and std.mem.startsWith(u8, prefix.content, "```")) {
            try closeLists(writer, lists[0..], &list_depth, 0);
            cursor = try renderFence(writer, source, current.next, prefix.content[3..]);
            continue;
        }

        if (prefix.indent < 4) {
            if (heading(prefix.content)) |value| {
                try closeLists(writer, lists[0..], &list_depth, 0);
                try writer.print("<h{d}>", .{value.level});
                try renderInline(writer, value.text, 0);
                try writer.print("</h{d}>", .{value.level});
                cursor = current.next;
                continue;
            }
            if (isHr(prefix.content)) {
                try closeLists(writer, lists[0..], &list_depth, 0);
                try writer.writeAll("<hr>");
                cursor = current.next;
                continue;
            }
            if (quoteText(prefix.content) != null) {
                try closeLists(writer, lists[0..], &list_depth, 0);
                cursor = try renderQuote(writer, source, cursor, depth);
                continue;
            }
            if (tableHeader(source, cursor)) |header_end| {
                try closeLists(writer, lists[0..], &list_depth, 0);
                cursor = try renderTable(writer, source, cursor, header_end);
                continue;
            }
        }

        if (listItem(line)) |item| {
            try syncLists(writer, lists[0..], &list_depth, item);
            try openItem(writer, &lists[list_depth - 1], item.task);
            try renderInline(writer, item.text, 0);
            cursor = current.next;
            continue;
        }
        if (prefix.indent < 4) {
            const task = parseTask(prefix.content);
            if (task.task != .none) {
                const item = ListItem{
                    .indent = prefix.indent,
                    .kind = .unordered,
                    .task = task.task,
                    .text = task.text,
                };
                try syncLists(writer, lists[0..], &list_depth, item);
                try openItem(writer, &lists[list_depth - 1], item.task);
                try renderInline(writer, item.text, 0);
                cursor = current.next;
                continue;
            }
        }

        if (list_depth != 0) {
            const current_indent = lists[list_depth - 1].indent;
            if (prefix.indent > current_indent) {
                try writer.writeByte(' ');
                try renderInline(writer, prefix.content, 0);
                cursor = current.next;
                continue;
            }
        }

        try closeLists(writer, lists[0..], &list_depth, 0);
        cursor = try renderParagraph(writer, source, cursor);
    }
    try closeLists(writer, lists[0..], &list_depth, 0);
}

fn renderFence(
    writer: *std.Io.Writer,
    source: []const u8,
    start: usize,
    language_line: []const u8,
) Error!usize {
    const language = std.mem.trim(u8, language_line, " \t");
    const code_start = start;
    var scan = start;
    var code_end: ?usize = null;
    var next_cursor = start;
    while (scan < source.len) {
        const candidate = lineAt(source, scan);
        const candidate_line = std.mem.trimEnd(u8, candidate.bytes, "\r");
        if (std.mem.eql(u8, std.mem.trim(u8, candidate_line, " \t"), "```")) {
            code_end = if (scan > code_start and source[scan - 1] == '\n')
                scan - 1
            else
                scan;
            next_cursor = candidate.next;
            break;
        }
        scan = candidate.next;
    }
    const end = code_end orelse return error.UnterminatedFence;
    try highlight.renderFence(writer, source[code_start..end], language);
    return next_cursor;
}

fn renderQuote(
    writer: *std.Io.Writer,
    source: []const u8,
    start: usize,
    depth: u8,
) Error!usize {
    var inner_buf: [2048]u8 = undefined;
    var used: usize = 0;
    var cursor = start;
    var fits = true;
    while (cursor < source.len) {
        const current = lineAt(source, cursor);
        const line = std.mem.trimEnd(u8, current.bytes, "\r");
        const prefix = linePrefix(line);
        const quoted = quoteText(prefix.content) orelse break;
        if (used != 0) {
            if (used >= inner_buf.len) {
                fits = false;
                break;
            }
            inner_buf[used] = '\n';
            used += 1;
        }
        if (used + quoted.len > inner_buf.len) {
            fits = false;
            break;
        }
        @memcpy(inner_buf[used..][0..quoted.len], quoted);
        used += quoted.len;
        cursor = current.next;
    }
    try writer.writeAll("<blockquote>");
    if (fits and used != 0) {
        try renderBlocks(writer, inner_buf[0..used], depth + 1);
    } else {
        var scan = start;
        while (scan < cursor) {
            const current = lineAt(source, scan);
            const line = std.mem.trimEnd(u8, current.bytes, "\r");
            const quoted = quoteText(linePrefix(line).content) orelse break;
            if (quoted.len != 0) {
                try writer.writeAll("<p>");
                try renderInline(writer, quoted, 0);
                try writer.writeAll("</p>");
            }
            scan = current.next;
        }
    }
    try writer.writeAll("</blockquote>");
    return cursor;
}

fn renderTable(
    writer: *std.Io.Writer,
    source: []const u8,
    header_start: usize,
    header_end: usize,
) Error!usize {
    const header_line = lineAt(source, header_start);
    const sep_line = lineAt(source, header_end);
    try writer.writeAll("<table><thead><tr>");
    try writeTableRow(writer, header_line.bytes, true);
    try writer.writeAll("</tr></thead><tbody>");
    var cursor = sep_line.next;
    while (cursor < source.len) {
        const current = lineAt(source, cursor);
        const line = std.mem.trimEnd(u8, current.bytes, "\r");
        if (!isTableRow(line)) break;
        try writer.writeAll("<tr>");
        try writeTableRow(writer, line, false);
        try writer.writeAll("</tr>");
        cursor = current.next;
    }
    try writer.writeAll("</tbody></table>");
    return cursor;
}

fn writeTableRow(writer: *std.Io.Writer, line: []const u8, header: bool) Error!void {
    const tag = if (header) "th" else "td";
    var inner = std.mem.trim(u8, std.mem.trimEnd(u8, line, "\r"), " \t");
    if (inner.len != 0 and inner[0] == '|') inner = inner[1..];
    if (inner.len != 0 and inner[inner.len - 1] == '|') inner = inner[0 .. inner.len - 1];
    var cells = std.mem.splitScalar(u8, inner, '|');
    while (cells.next()) |raw| {
        try writer.print("<{s}>", .{tag});
        try renderInline(writer, std.mem.trim(u8, raw, " \t"), 0);
        try writer.print("</{s}>", .{tag});
    }
}

fn renderParagraph(writer: *std.Io.Writer, source: []const u8, start: usize) Error!usize {
    const first_line = lineAt(source, start);
    var cursor = first_line.next;
    var previous = first_line.bytes;
    try writer.writeAll("<p>");
    try renderInline(writer, trimHardBreak(std.mem.trimEnd(u8, first_line.bytes, "\r")), 0);
    while (cursor < source.len) {
        const current = lineAt(source, cursor);
        const line = std.mem.trimEnd(u8, current.bytes, "\r");
        if (linePrefix(line).content.len == 0 or isBlockStart(line)) break;
        if (hardBreak(previous)) {
            try writer.writeAll("<br>");
        } else {
            try writer.writeByte('\n');
        }
        try renderInline(writer, trimHardBreak(line), 0);
        previous = current.bytes;
        cursor = current.next;
    }
    try writer.writeAll("</p>");
    return cursor;
}

fn hardBreak(line: []const u8) bool {
    const value = std.mem.trimEnd(u8, line, "\r");
    return value.len >= 2 and value[value.len - 1] == ' ' and value[value.len - 2] == ' ';
}

fn trimHardBreak(line: []const u8) []const u8 {
    return if (hardBreak(line)) line[0 .. line.len - 2] else std.mem.trimEnd(u8, line, " \t");
}

fn isBlockStart(line: []const u8) bool {
    const prefix = linePrefix(line);
    if (prefix.content.len == 0) return true;
    if (listItem(line) != null) return true;
    if (prefix.indent < 4 and parseTask(prefix.content).task != .none) return true;
    if (prefix.indent >= 4) return false;
    return std.mem.startsWith(u8, prefix.content, "```") or
        heading(prefix.content) != null or
        isHr(prefix.content) or
        quoteText(prefix.content) != null or
        isTableRow(prefix.content);
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
        if (std.mem.startsWith(u8, source[cursor..], "~~")) {
            if (std.mem.indexOfPos(u8, source, cursor + 2, "~~")) |end| {
                try writer.writeAll("<del>");
                try renderInline(writer, source[cursor + 2 .. end], depth + 1);
                try writer.writeAll("</del>");
                cursor = end + 2;
                continue;
            }
        }
        if (std.mem.startsWith(u8, source[cursor..], "**") or
            std.mem.startsWith(u8, source[cursor..], "__"))
        {
            const marker = source[cursor .. cursor + 2];
            if (std.mem.indexOfPos(u8, source, cursor + 2, marker)) |end| {
                try writer.writeAll("<strong>");
                try renderInline(writer, source[cursor + 2 .. end], depth + 1);
                try writer.writeAll("</strong>");
                cursor = end + 2;
                continue;
            }
        }
        if (source[cursor] == '*' or source[cursor] == '_') {
            const marker = source[cursor];
            if (std.mem.indexOfScalarPos(u8, source, cursor + 1, marker)) |end| {
                try writer.writeAll("<em>");
                try renderInline(writer, source[cursor + 1 .. end], depth + 1);
                try writer.writeAll("</em>");
                cursor = end + 1;
                continue;
            }
        }
        if (std.mem.startsWith(u8, source[cursor..], "![")) {
            if (linkAt(source, cursor + 1)) |image| {
                if (safeLink(image.url)) {
                    try writer.writeAll("<img class=\"markdown-image\" src=\"");
                    try escapeAttribute(writer, image.url);
                    try writer.writeAll("\" alt=\"");
                    try escapeAttribute(writer, image.label);
                    try writer.writeAll("\" loading=\"lazy\">");
                    cursor = image.next;
                    continue;
                }
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
        if (source[cursor] == '<') {
            if (angleLinkAt(source, cursor)) |link| {
                if (safeLink(link.url)) {
                    try writer.writeAll("<a href=\"");
                    try escapeAttribute(writer, link.url);
                    try writer.writeAll("\" rel=\"nofollow noopener\">");
                    try highlight.escapeHtml(writer, link.url);
                    try writer.writeAll("</a>");
                    cursor = link.next;
                    continue;
                }
            }
        }
        if (bareUrlAt(source, cursor)) |link| {
            if (safeLink(link.url)) {
                try writer.writeAll("<a href=\"");
                try escapeAttribute(writer, link.url);
                try writer.writeAll("\" rel=\"nofollow noopener\">");
                try highlight.escapeHtml(writer, link.url);
                try writer.writeAll("</a>");
                cursor = link.next;
                continue;
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

const Prefix = struct {
    indent: usize,
    content: []const u8,
};

fn linePrefix(line: []const u8) Prefix {
    var indent: usize = 0;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        switch (line[index]) {
            ' ' => indent += 1,
            '\t' => indent += 4,
            else => break,
        }
    }
    return .{ .indent = indent, .content = line[index..] };
}

fn heading(line: []const u8) ?struct { level: u3, text: []const u8 } {
    var count: usize = 0;
    while (count < line.len and count < 6 and line[count] == '#') count += 1;
    if (count == 0 or count == line.len or line[count] != ' ') return null;
    return .{ .level = @intCast(count), .text = std.mem.trim(u8, line[count + 1 ..], " \t") };
}

fn isHr(content: []const u8) bool {
    const trimmed = std.mem.trim(u8, content, " \t");
    if (trimmed.len < 3) return false;
    const mark = trimmed[0];
    if (mark != '-' and mark != '*' and mark != '_') return false;
    for (trimmed) |byte| {
        if (byte != mark) return false;
    }
    return true;
}

fn quoteText(content: []const u8) ?[]const u8 {
    if (content.len == 0 or content[0] != '>') return null;
    if (content.len == 1) return "";
    if (content[1] == ' ') return content[2..];
    return content[1..];
}

fn listItem(line: []const u8) ?ListItem {
    const prefix = linePrefix(line);
    const content = prefix.content;
    if (content.len >= 2 and (content[0] == '-' or content[0] == '*' or content[0] == '+') and
        content[1] == ' ')
    {
        const rest = parseTask(content[2..]);
        return .{
            .indent = prefix.indent,
            .kind = .unordered,
            .task = rest.task,
            .text = rest.text,
        };
    }
    if (orderedMarker(content)) |rest| {
        const task = parseTask(rest);
        return .{
            .indent = prefix.indent,
            .kind = .ordered,
            .task = task.task,
            .text = task.text,
        };
    }
    return null;
}

fn orderedMarker(line: []const u8) ?[]const u8 {
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

fn parseTask(text: []const u8) struct { task: TaskState, text: []const u8 } {
    if (text.len < 3 or text[0] != '[' or text[2] != ']') {
        return .{ .task = .none, .text = text };
    }
    const mark = text[1];
    if (mark != ' ' and mark != 'x' and mark != 'X') {
        return .{ .task = .none, .text = text };
    }
    if (text.len > 3 and text[3] != ' ') {
        return .{ .task = .none, .text = text };
    }
    const rest = if (text.len > 3) text[4..] else text[3..];
    return .{
        .task = if (mark == ' ') .open else .done,
        .text = rest,
    };
}

fn syncLists(
    writer: *std.Io.Writer,
    lists: []ListFrame,
    depth: *usize,
    item: ListItem,
) Error!void {
    try closeLists(writer, lists, depth, item.indent + 1);
    if (depth.* != 0 and lists[depth.* - 1].indent == item.indent) {
        if (lists[depth.* - 1].kind != item.kind) {
            try closeLists(writer, lists, depth, item.indent);
        } else {
            return;
        }
    }
    if (depth.* >= lists.len) return;
    try writer.writeAll(if (item.kind == .ordered) "<ol>" else "<ul>");
    lists[depth.*] = .{
        .kind = item.kind,
        .indent = item.indent,
        .item_open = false,
    };
    depth.* += 1;
}

fn openItem(writer: *std.Io.Writer, frame: *ListFrame, task: TaskState) Error!void {
    if (frame.item_open) try writer.writeAll("</li>");
    try writer.writeAll(if (task == .none) "<li>" else "<li class=\"task-list-item\">");
    switch (task) {
        .none => {},
        .open => try writer.writeAll("<input type=\"checkbox\" disabled> "),
        .done => try writer.writeAll("<input type=\"checkbox\" disabled checked> "),
    }
    frame.item_open = true;
}

fn closeLists(
    writer: *std.Io.Writer,
    lists: []ListFrame,
    depth: *usize,
    min_indent: usize,
) Error!void {
    while (depth.* != 0 and lists[depth.* - 1].indent >= min_indent) {
        depth.* -= 1;
        if (lists[depth.*].item_open) try writer.writeAll("</li>");
        try writer.writeAll(if (lists[depth.*].kind == .ordered) "</ol>" else "</ul>");
    }
}

fn tableHeader(source: []const u8, start: usize) ?usize {
    const header = lineAt(source, start);
    const header_line = std.mem.trimEnd(u8, header.bytes, "\r");
    if (!isTableRow(header_line) or header.next >= source.len) return null;
    const sep = lineAt(source, header.next);
    return if (isTableSep(std.mem.trimEnd(u8, sep.bytes, "\r"))) header.next else null;
}

fn isTableRow(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return trimmed.len >= 3 and trimmed[0] == '|' and
        std.mem.indexOfScalar(u8, trimmed[1..], '|') != null;
}

fn isTableSep(line: []const u8) bool {
    if (!isTableRow(line)) return false;
    var inner = std.mem.trim(u8, line, " \t");
    if (inner[0] == '|') inner = inner[1..];
    if (inner.len != 0 and inner[inner.len - 1] == '|') inner = inner[0 .. inner.len - 1];
    var cells = std.mem.splitScalar(u8, inner, '|');
    var count: usize = 0;
    while (cells.next()) |raw| {
        const cell = std.mem.trim(u8, raw, " \t");
        if (!isSepCell(cell)) return false;
        count += 1;
    }
    return count != 0;
}

fn isSepCell(cell: []const u8) bool {
    if (cell.len < 3) return false;
    var start: usize = 0;
    var end = cell.len;
    if (cell[0] == ':') start = 1;
    if (cell[end - 1] == ':') end -= 1;
    if (end - start < 3) return false;
    for (cell[start..end]) |byte| {
        if (byte != '-') return false;
    }
    return true;
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

fn angleLinkAt(source: []const u8, start: usize) ?struct { url: []const u8, next: usize } {
    if (start + 1 >= source.len or source[start] != '<') return null;
    const end = std.mem.indexOfScalarPos(u8, source, start + 1, '>') orelse return null;
    const url = source[start + 1 .. end];
    if (!(std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://"))) {
        return null;
    }
    return .{ .url = url, .next = end + 1 };
}

fn bareUrlAt(source: []const u8, start: usize) ?struct { url: []const u8, next: usize } {
    const rest = source[start..];
    const scheme_len: usize = if (std.mem.startsWith(u8, rest, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, rest, "http://"))
        "http://".len
    else
        return null;
    var end = scheme_len;
    while (start + end < source.len) {
        switch (source[start + end]) {
            ' ', '\t', '<', '>', '"', '\'', ')', ']' => break,
            else => end += 1,
        }
    }
    if (end == scheme_len) return null;
    var url = source[start .. start + end];
    while (url.len > scheme_len) {
        switch (url[url.len - 1]) {
            '.', ',', ':', ';', '!' => url = url[0 .. url.len - 1],
            else => break,
        }
    }
    return .{ .url = url, .next = start + url.len };
}

fn safeLink(value: []const u8) bool {
    domain.validateEvidenceUrl(value) catch return false;
    return true;
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
            '`', '*', '[', '!', '~', '_', '<' => return cursor,
            'h' => {
                const rest = source[cursor..];
                if (std.mem.startsWith(u8, rest, "https://") or
                    std.mem.startsWith(u8, rest, "http://"))
                    return cursor;
            },
            else => {},
        }
    }
    return source.len;
}

fn rendered(source: []const u8, storage: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(storage);
    try render(&writer, source);
    return storage[0..writer.end];
}

test "Markdown escapes HTML and dangerous links" {
    var storage: [4096]u8 = undefined;
    const output = try rendered(
        "# Hello\n<script>alert(1)</script>\n[bad](javascript:alert(1))\n[good](https://example.com/a?b=1&c=2)",
        &storage,
    );
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
    const output = try rendered(
        "- **Fast**\n- `safe`\n\n```javascript\nconst value = \"<&\";\n```",
        &storage,
    );
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

test "Markdown renders safe images and rejects javascript sources" {
    var storage: [4096]u8 = undefined;
    const output = try rendered(
        "See ![diagram](https://cdn.example.com/a.png?x=1&y=2) and ![bad](javascript:alert(1))",
        &storage,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "src=\"https://cdn.example.com/a.png?x=1&amp;y=2\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "alt=\"diagram\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "src=\"javascript:") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "javascript:alert(1)") != null);
}

test "Markdown renders task lists nested lists tables and strike" {
    var storage: [4096]u8 = undefined;
    const output = try rendered(
        \\- [ ] checkbutton
        \\- [x] done
        \\- [X] also
        \\
        \\- parent
        \\  - child
        \\
        \\~~old~~ __bold__ _em_
        \\
        \\| a | b |
        \\| --- | --- |
        \\| 1 | 2 |
        \\
        \\#### Deep
        \\
        \\---
        \\
        \\<https://example.com>
        \\
        \\https://example.com/path
        \\
        \\![shot](/media/abc.png)
    ,
        &storage,
    );
    try std.testing.expect(std.mem.indexOf(u8, output, "<li class=\"task-list-item\"><input type=\"checkbox\" disabled> checkbutton</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<input type=\"checkbox\" disabled checked> done") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<input type=\"checkbox\" disabled checked> also") != null);

    var bare: [512]u8 = undefined;
    const bare_out = try rendered("[ ] checkbutton\n[x] shipped", &bare);
    try std.testing.expect(std.mem.indexOf(u8, bare_out, "<li class=\"task-list-item\"><input type=\"checkbox\" disabled> checkbutton</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare_out, "<input type=\"checkbox\" disabled checked> shipped") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<ul><li>parent<ul><li>child</li></ul></li></ul>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<del>old</del>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<strong>bold</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<em>em</em>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<table><thead><tr><th>a</th><th>b</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<h4>Deep</h4>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<hr>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "href=\"https://example.com\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "href=\"https://example.com/path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "src=\"/media/abc.png\"") != null);
}

test "Markdown joins paragraph lines and keeps plus lists" {
    var storage: [1024]u8 = undefined;
    const output = try rendered("hello\nworld\n\n+ item", &storage);
    try std.testing.expect(std.mem.indexOf(u8, output, "<p>hello\nworld</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<ul><li>item</li></ul>") != null);
}
