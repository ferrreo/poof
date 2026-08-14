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
    start: u32 = 1,
};

const refs_max = 32;

const LinkRef = struct {
    id: []const u8,
    url: []const u8,
};

const LinkRefs = struct {
    items: [refs_max]LinkRef = undefined,
    len: usize = 0,

    fn get(self: *const LinkRefs, label: []const u8) ?[]const u8 {
        for (self.items[0..self.len]) |item| {
            if (eqlRefId(item.id, label)) return item.url;
        }
        return null;
    }

    fn put(self: *LinkRefs, id: []const u8, url: []const u8) void {
        if (self.len == self.items.len or self.get(id) != null) return;
        self.items[self.len] = .{ .id = id, .url = url };
        self.len += 1;
    }
};

pub fn render(writer: *std.Io.Writer, source: []const u8) Error!void {
    if (source.len > source_bytes_max) return error.SourceTooLarge;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
    var refs = LinkRefs{};
    collectRefs(source, &refs);
    try renderBlocks(writer, source, 0, &refs);
}

fn renderBlocks(writer: *std.Io.Writer, source: []const u8, depth: u8, refs: *const LinkRefs) Error!void {
    if (depth >= nesting_max) return highlight.escapeHtml(writer, source);

    var cursor: usize = 0;
    var lists: [nesting_max]ListFrame = undefined;
    var list_depth: usize = 0;
    while (cursor < source.len) {
        const current = lineAt(source, cursor);
        const line = std.mem.trimEnd(u8, current.bytes, "\r");
        const prefix = linePrefix(line);
        if (prefix.content.len == 0) {
            cursor = current.next;
            continue;
        }

        if (prefix.indent < 4) {
            if (parseLinkDef(prefix.content) != null) {
                try closeLists(writer, lists[0..], &list_depth, 0);
                cursor = current.next;
                continue;
            }
            if (fenceOpener(prefix.content)) |fence| {
                try closeLists(writer, lists[0..], &list_depth, 0);
                cursor = try renderFence(writer, source, current.next, fence);
                continue;
            }
            if (heading(prefix.content)) |value| {
                try closeLists(writer, lists[0..], &list_depth, 0);
                try writer.print("<h{d}>", .{value.level});
                try renderInline(writer, value.text, 0, refs);
                try writer.print("</h{d}>", .{value.level});
                cursor = current.next;
                continue;
            }
            if (setextHeading(source, cursor)) |value| {
                try closeLists(writer, lists[0..], &list_depth, 0);
                try writer.print("<h{d}>", .{value.level});
                try renderInline(writer, value.text, 0, refs);
                try writer.print("</h{d}>", .{value.level});
                cursor = value.next;
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
                cursor = try renderQuote(writer, source, cursor, depth, refs);
                continue;
            }
            if (tableHeader(source, cursor)) |header_end| {
                try closeLists(writer, lists[0..], &list_depth, 0);
                cursor = try renderTable(writer, source, cursor, header_end, refs);
                continue;
            }
        }

        if (list_depth == 0 and prefix.indent >= 4) {
            cursor = try renderIndentedCode(writer, source, cursor);
            continue;
        }

        if (listItem(line)) |item| {
            try syncLists(writer, lists[0..], &list_depth, item);
            try openItem(writer, &lists[list_depth - 1], item.task);
            try renderInline(writer, item.text, 0, refs);
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
                try renderInline(writer, item.text, 0, refs);
                cursor = current.next;
                continue;
            }
        }

        if (list_depth != 0) {
            const current_indent = lists[list_depth - 1].indent;
            if (prefix.indent > current_indent) {
                try writer.writeByte(' ');
                try renderInline(writer, prefix.content, 0, refs);
                cursor = current.next;
                continue;
            }
        }

        try closeLists(writer, lists[0..], &list_depth, 0);
        cursor = try renderParagraph(writer, source, cursor, refs);
    }
    try closeLists(writer, lists[0..], &list_depth, 0);
}

const Fence = struct {
    mark: u8,
    count: usize,
    info: []const u8,
};

fn fenceOpener(content: []const u8) ?Fence {
    if (content.len < 3) return null;
    const mark = content[0];
    if (mark != '`' and mark != '~') return null;
    var count: usize = 0;
    while (count < content.len and content[count] == mark) count += 1;
    if (count < 3) return null;
    const info = std.mem.trim(u8, content[count..], " \t");
    if (mark == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    return .{ .mark = mark, .count = count, .info = info };
}

fn fenceCloser(content: []const u8, opener: Fence) bool {
    const trimmed = std.mem.trim(u8, content, " \t");
    if (trimmed.len < opener.count) return false;
    var count: usize = 0;
    while (count < trimmed.len and trimmed[count] == opener.mark) count += 1;
    return count >= opener.count and count == trimmed.len;
}

fn fenceLanguage(info: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, info, " \t");
    if (std.mem.indexOfAny(u8, trimmed, " \t")) |end| return trimmed[0..end];
    return trimmed;
}

fn renderFence(
    writer: *std.Io.Writer,
    source: []const u8,
    start: usize,
    opener: Fence,
) Error!usize {
    const code_start = start;
    var scan = start;
    var code_end: ?usize = null;
    var next_cursor = start;
    while (scan < source.len) {
        const candidate = lineAt(source, scan);
        const candidate_line = std.mem.trimEnd(u8, candidate.bytes, "\r");
        if (fenceCloser(linePrefix(candidate_line).content, opener)) {
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
    try highlight.renderFence(writer, source[code_start..end], fenceLanguage(opener.info));
    return next_cursor;
}

fn renderIndentedCode(writer: *std.Io.Writer, source: []const u8, start: usize) Error!usize {
    try writer.writeAll("<pre class=\"code-block\"><code>");
    var cursor = start;
    var first = true;
    while (cursor < source.len) {
        const current = lineAt(source, cursor);
        const line = std.mem.trimEnd(u8, current.bytes, "\r");
        const prefix = linePrefix(line);
        if (prefix.content.len == 0) {
            var peek = current.next;
            var keep = false;
            while (peek < source.len) {
                const ahead = lineAt(source, peek);
                const ahead_line = std.mem.trimEnd(u8, ahead.bytes, "\r");
                const ahead_prefix = linePrefix(ahead_line);
                if (ahead_prefix.content.len == 0) {
                    peek = ahead.next;
                    continue;
                }
                keep = ahead_prefix.indent >= 4;
                break;
            }
            if (!keep) break;
            if (!first) try writer.writeByte('\n');
            first = false;
            cursor = current.next;
            continue;
        }
        if (prefix.indent < 4) break;
        if (!first) try writer.writeByte('\n');
        first = false;
        try highlight.escapeHtml(writer, dropIndent(line, 4));
        cursor = current.next;
    }
    try writer.writeAll("</code></pre>");
    return cursor;
}

fn dropIndent(line: []const u8, spaces: usize) []const u8 {
    var remaining = spaces;
    var index: usize = 0;
    while (index < line.len and remaining != 0) : (index += 1) {
        switch (line[index]) {
            ' ' => remaining -= 1,
            '\t' => remaining -|= 4,
            else => break,
        }
    }
    return line[index..];
}

fn renderQuote(
    writer: *std.Io.Writer,
    source: []const u8,
    start: usize,
    depth: u8,
    refs: *const LinkRefs,
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
        try renderBlocks(writer, inner_buf[0..used], depth + 1, refs);
    } else {
        var scan = start;
        while (scan < cursor) {
            const current = lineAt(source, scan);
            const line = std.mem.trimEnd(u8, current.bytes, "\r");
            const quoted = quoteText(linePrefix(line).content) orelse break;
            if (quoted.len != 0) {
                try writer.writeAll("<p>");
                try renderInline(writer, quoted, 0, refs);
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
    refs: *const LinkRefs,
) Error!usize {
    const header_line = lineAt(source, header_start);
    const sep_line = lineAt(source, header_end);
    var aligns: [16]Align = .{.left} ** 16;
    const align_count = parseAligns(sep_line.bytes, &aligns);
    try writer.writeAll("<table><thead><tr>");
    try writeTableRow(writer, header_line.bytes, true, aligns[0..align_count], refs);
    try writer.writeAll("</tr></thead><tbody>");
    var cursor = sep_line.next;
    while (cursor < source.len) {
        const current = lineAt(source, cursor);
        const line = std.mem.trimEnd(u8, current.bytes, "\r");
        if (!isTableRow(line)) break;
        try writer.writeAll("<tr>");
        try writeTableRow(writer, line, false, aligns[0..align_count], refs);
        try writer.writeAll("</tr>");
        cursor = current.next;
    }
    try writer.writeAll("</tbody></table>");
    return cursor;
}

const Align = enum { left, center, right };

fn parseAligns(line: []const u8, aligns: []Align) usize {
    var inner = std.mem.trim(u8, std.mem.trimEnd(u8, line, "\r"), " \t");
    if (inner.len != 0 and inner[0] == '|') inner = inner[1..];
    if (inner.len != 0 and inner[inner.len - 1] == '|') inner = inner[0 .. inner.len - 1];
    var cells = std.mem.splitScalar(u8, inner, '|');
    var count: usize = 0;
    while (cells.next()) |raw| {
        if (count == aligns.len) break;
        aligns[count] = sepAlign(std.mem.trim(u8, raw, " \t"));
        count += 1;
    }
    return count;
}

fn sepAlign(cell: []const u8) Align {
    const left = cell.len != 0 and cell[0] == ':';
    const right = cell.len != 0 and cell[cell.len - 1] == ':';
    if (left and right) return .center;
    if (right) return .right;
    return .left;
}

fn alignClass(value: Align) []const u8 {
    return switch (value) {
        .left => "",
        .center => " class=\"align-center\"",
        .right => " class=\"align-right\"",
    };
}

fn writeTableRow(
    writer: *std.Io.Writer,
    line: []const u8,
    header: bool,
    aligns: []const Align,
    refs: *const LinkRefs,
) Error!void {
    const tag = if (header) "th" else "td";
    var inner = std.mem.trim(u8, std.mem.trimEnd(u8, line, "\r"), " \t");
    if (inner.len != 0 and inner[0] == '|') inner = inner[1..];
    if (inner.len != 0 and inner[inner.len - 1] == '|') inner = inner[0 .. inner.len - 1];
    var cells = std.mem.splitScalar(u8, inner, '|');
    var index: usize = 0;
    while (cells.next()) |raw| {
        const alignment = if (index < aligns.len) aligns[index] else Align.left;
        try writer.print("<{s}{s}>", .{ tag, alignClass(alignment) });
        try renderInline(writer, std.mem.trim(u8, raw, " \t"), 0, refs);
        try writer.print("</{s}>", .{tag});
        index += 1;
    }
}

fn renderParagraph(writer: *std.Io.Writer, source: []const u8, start: usize, refs: *const LinkRefs) Error!usize {
    const first_line = lineAt(source, start);
    var cursor = first_line.next;
    var previous = first_line.bytes;
    try writer.writeAll("<p>");
    try renderInline(writer, trimHardBreak(std.mem.trimEnd(u8, first_line.bytes, "\r")), 0, refs);
    while (cursor < source.len) {
        const current = lineAt(source, cursor);
        const line = std.mem.trimEnd(u8, current.bytes, "\r");
        if (linePrefix(line).content.len == 0 or isBlockStart(line)) break;
        if (hardBreak(previous) or endsWithEscapeBreak(previous)) {
            try writer.writeAll("<br>");
        } else {
            try writer.writeByte('\n');
        }
        try renderInline(writer, trimHardBreak(line), 0, refs);
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
    const value = std.mem.trimEnd(u8, line, "\r");
    if (hardBreak(value)) return value[0 .. value.len - 2];
    if (endsWithEscapeBreak(value)) return value[0 .. value.len - 1];
    return std.mem.trimEnd(u8, value, " \t");
}

fn endsWithEscapeBreak(line: []const u8) bool {
    const value = std.mem.trimEnd(u8, line, "\r");
    return value.len != 0 and value[value.len - 1] == '\\' and
        (value.len == 1 or value[value.len - 2] != '\\');
}

fn isBlockStart(line: []const u8) bool {
    const prefix = linePrefix(line);
    if (prefix.content.len == 0) return true;
    if (listItem(line) != null) return true;
    if (prefix.indent < 4 and parseTask(prefix.content).task != .none) return true;
    if (prefix.indent >= 4) return false;
    return fenceOpener(prefix.content) != null or
        heading(prefix.content) != null or
        isHr(prefix.content) or
        quoteText(prefix.content) != null or
        isTableRow(prefix.content) or
        parseLinkDef(prefix.content) != null;
}

fn renderInline(writer: *std.Io.Writer, source: []const u8, depth: u8, refs: *const LinkRefs) Error!void {
    if (depth >= nesting_max) return highlight.escapeHtml(writer, source);
    var cursor: usize = 0;
    while (cursor < source.len) {
        if (source[cursor] == '\\' and cursor + 1 < source.len and isAsciiPunct(source[cursor + 1])) {
            try highlight.escapeHtml(writer, source[cursor + 1 .. cursor + 2]);
            cursor += 2;
            continue;
        }
        if (source[cursor] == '&') {
            if (entityAt(source, cursor)) |entity| {
                try highlight.escapeHtml(writer, entity.bytes[0..entity.len]);
                cursor = entity.next;
                continue;
            }
        }
        if (source[cursor] == '`') {
            if (codeSpanAt(source, cursor)) |span| {
                try writer.writeAll("<code>");
                try highlight.escapeHtml(writer, span.text);
                try writer.writeAll("</code>");
                cursor = span.next;
                continue;
            }
        }
        if (std.mem.startsWith(u8, source[cursor..], "~~")) {
            if (std.mem.indexOfPos(u8, source, cursor + 2, "~~")) |end| {
                try writer.writeAll("<del>");
                try renderInline(writer, source[cursor + 2 .. end], depth + 1, refs);
                try writer.writeAll("</del>");
                cursor = end + 2;
                continue;
            }
        }
        if (std.mem.startsWith(u8, source[cursor..], "***") or
            std.mem.startsWith(u8, source[cursor..], "___"))
        {
            const marker = source[cursor .. cursor + 3];
            if (std.mem.indexOfPos(u8, source, cursor + 3, marker)) |end| {
                try writer.writeAll("<strong><em>");
                try renderInline(writer, source[cursor + 3 .. end], depth + 1, refs);
                try writer.writeAll("</em></strong>");
                cursor = end + 3;
                continue;
            }
        }
        if (std.mem.startsWith(u8, source[cursor..], "**") or
            std.mem.startsWith(u8, source[cursor..], "__"))
        {
            const marker = source[cursor .. cursor + 2];
            if (std.mem.indexOfPos(u8, source, cursor + 2, marker)) |end| {
                try writer.writeAll("<strong>");
                try renderInline(writer, source[cursor + 2 .. end], depth + 1, refs);
                try writer.writeAll("</strong>");
                cursor = end + 2;
                continue;
            }
        }
        if (source[cursor] == '*' or (source[cursor] == '_' and canOpenUnderscore(source, cursor))) {
            const marker = source[cursor];
            if (closingMarker(source, cursor, marker)) |end| {
                try writer.writeAll("<em>");
                try renderInline(writer, source[cursor + 1 .. end], depth + 1, refs);
                try writer.writeAll("</em>");
                cursor = end + 1;
                continue;
            }
        }
        if (std.mem.startsWith(u8, source[cursor..], "![")) {
            if (linkAt(source, cursor + 1, refs)) |image| {
                if (safeLink(image.url)) {
                    try writer.writeAll("<img class=\"markdown-image\" src=\"");
                    try escapeAttribute(writer, image.url);
                    try writer.writeAll("\" alt=\"");
                    try escapeAttribute(writer, image.label);
                    try writeTitle(writer, image.title);
                    try writer.writeAll("\" loading=\"lazy\">");
                    cursor = image.next;
                    continue;
                }
            }
        }
        if (source[cursor] == '[') {
            if (linkAt(source, cursor, refs)) |link| {
                if (safeLink(link.url)) {
                    try writer.writeAll("<a href=\"");
                    try escapeAttribute(writer, link.url);
                    try writeTitle(writer, link.title);
                    try writer.writeAll("\" rel=\"nofollow noopener\">");
                    try renderInline(writer, link.label, depth + 1, refs);
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
    var text = std.mem.trim(u8, line[count + 1 ..], " \t");
    var end = text.len;
    while (end != 0 and text[end - 1] == '#') end -= 1;
    if (end != text.len and (end == 0 or text[end - 1] == ' ')) {
        text = std.mem.trim(u8, text[0..end], " \t");
    }
    return .{ .level = @intCast(count), .text = text };
}

fn isHr(content: []const u8) bool {
    const trimmed = std.mem.trim(u8, content, " \t");
    if (trimmed.len < 3) return false;
    var mark: ?u8 = null;
    var count: usize = 0;
    for (trimmed) |byte| {
        if (byte == ' ' or byte == '\t') continue;
        if (byte != '-' and byte != '*' and byte != '_') return false;
        if (mark) |current| {
            if (byte != current) return false;
        } else {
            mark = byte;
        }
        count += 1;
    }
    return count >= 3;
}

fn setextHeading(source: []const u8, start: usize) ?struct { level: u3, text: []const u8, next: usize } {
    const current = lineAt(source, start);
    const line = std.mem.trimEnd(u8, current.bytes, "\r");
    const prefix = linePrefix(line);
    if (prefix.indent >= 4 or prefix.content.len == 0) return null;
    if (listItem(line) != null or heading(prefix.content) != null or
        fenceOpener(prefix.content) != null or quoteText(prefix.content) != null)
        return null;
    if (current.next >= source.len) return null;
    const underline = lineAt(source, current.next);
    const under_line = std.mem.trimEnd(u8, underline.bytes, "\r");
    const under = std.mem.trim(u8, linePrefix(under_line).content, " \t");
    if (under.len == 0) return null;
    const mark = under[0];
    if (mark != '=' and mark != '-') return null;
    for (under) |byte| {
        if (byte != mark) return null;
    }
    return .{
        .level = if (mark == '=') 1 else 2,
        .text = std.mem.trim(u8, prefix.content, " \t"),
        .next = underline.next,
    };
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
    if (orderedMarker(content)) |item| {
        const task = parseTask(item.rest);
        return .{
            .indent = prefix.indent,
            .kind = .ordered,
            .task = task.task,
            .text = task.text,
            .start = item.start,
        };
    }
    return null;
}

fn orderedMarker(line: []const u8) ?struct { rest: []const u8, start: u32 } {
    var cursor: usize = 0;
    while (cursor < line.len and cursor < 9 and std.ascii.isDigit(line[cursor])) {
        cursor += 1;
    }
    if (cursor == 0 or cursor + 1 >= line.len or
        (line[cursor] != '.' and line[cursor] != ')') or
        line[cursor + 1] != ' ')
    {
        return null;
    }
    const start = std.fmt.parseInt(u32, line[0..cursor], 10) catch return null;
    return .{ .rest = line[cursor + 2 ..], .start = start };
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
    if (item.kind == .ordered) {
        if (item.start == 1) {
            try writer.writeAll("<ol>");
        } else {
            try writer.print("<ol start=\"{d}\">", .{item.start});
        }
    } else {
        try writer.writeAll("<ul>");
    }
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
        .open => try writer.writeAll("<input type=\"checkbox\" class=\"task-checkbox\" disabled>"),
        .done => try writer.writeAll("<input type=\"checkbox\" class=\"task-checkbox\" disabled checked>"),
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
    title: []const u8 = "",
    next: usize,
};

fn linkAt(source: []const u8, start: usize, refs: *const LinkRefs) ?Link {
    if (start >= source.len or source[start] != '[') return null;
    const label_end = std.mem.indexOfScalarPos(u8, source, start + 1, ']') orelse return null;
    const label = source[start + 1 .. label_end];
    const next = label_end + 1;
    if (next < source.len and source[next] == '(') {
        return inlineLink(source, label, next);
    }
    if (next < source.len and source[next] == '[') {
        const id_end = std.mem.indexOfScalarPos(u8, source, next + 1, ']') orelse return null;
        const id = if (id_end == next + 1) label else source[next + 1 .. id_end];
        const url = refs.get(id) orelse return null;
        return .{ .label = label, .url = url, .title = "", .next = id_end + 1 };
    }
    if (refs.get(label)) |url| {
        return .{ .label = label, .url = url, .title = "", .next = next };
    }
    return null;
}

fn inlineLink(source: []const u8, label: []const u8, open_paren: usize) ?Link {
    var cursor = open_paren + 1;
    while (cursor < source.len and (source[cursor] == ' ' or source[cursor] == '\t')) cursor += 1;
    if (cursor >= source.len) return null;
    var url_start = cursor;
    var url_end = cursor;
    if (source[cursor] == '<') {
        url_start = cursor + 1;
        url_end = std.mem.indexOfScalarPos(u8, source, url_start, '>') orelse return null;
        cursor = url_end + 1;
    } else {
        while (url_end < source.len and source[url_end] != ' ' and source[url_end] != '\t' and
            source[url_end] != ')')
        {
            url_end += 1;
        }
        cursor = url_end;
    }
    while (cursor < source.len and (source[cursor] == ' ' or source[cursor] == '\t')) cursor += 1;
    var title: []const u8 = "";
    if (cursor < source.len and (source[cursor] == '"' or source[cursor] == '\'')) {
        const quote = source[cursor];
        const title_start = cursor + 1;
        cursor = std.mem.indexOfScalarPos(u8, source, title_start, quote) orelse return null;
        title = source[title_start..cursor];
        cursor += 1;
        while (cursor < source.len and (source[cursor] == ' ' or source[cursor] == '\t')) cursor += 1;
    }
    if (cursor >= source.len or source[cursor] != ')') return null;
    return .{
        .label = label,
        .url = source[url_start..url_end],
        .title = title,
        .next = cursor + 1,
    };
}

fn writeTitle(writer: *std.Io.Writer, title: []const u8) Error!void {
    if (title.len == 0) return;
    try writer.writeAll("\" title=\"");
    try escapeAttribute(writer, title);
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
            '`', '*', '[', '!', '~', '_', '<', '\\', '&' => return cursor,
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

fn collectRefs(source: []const u8, refs: *LinkRefs) void {
    var cursor: usize = 0;
    while (cursor < source.len) {
        const current = lineAt(source, cursor);
        const line = std.mem.trimEnd(u8, current.bytes, "\r");
        const prefix = linePrefix(line);
        if (prefix.indent < 4) {
            if (parseLinkDef(prefix.content)) |def| refs.put(def.id, def.url);
        }
        cursor = current.next;
    }
}

fn parseLinkDef(content: []const u8) ?LinkRef {
    if (content.len < 4 or content[0] != '[') return null;
    const label_end = std.mem.indexOfScalarPos(u8, content, 1, ']') orelse return null;
    if (label_end + 1 >= content.len or content[label_end + 1] != ':') return null;
    const id = content[1..label_end];
    if (id.len == 0) return null;
    var cursor = label_end + 2;
    while (cursor < content.len and (content[cursor] == ' ' or content[cursor] == '\t')) cursor += 1;
    if (cursor >= content.len) return null;
    var url_start = cursor;
    var url_end = cursor;
    if (content[cursor] == '<') {
        url_start = cursor + 1;
        url_end = std.mem.indexOfScalarPos(u8, content, url_start, '>') orelse return null;
        cursor = url_end + 1;
    } else {
        while (url_end < content.len and content[url_end] != ' ' and content[url_end] != '\t') {
            url_end += 1;
        }
        cursor = url_end;
    }
    const url = content[url_start..url_end];
    if (url.len == 0) return null;
    return .{ .id = id, .url = url };
}

fn eqlRefId(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and (a[i] == ' ' or a[i] == '\t')) i += 1;
        while (j < b.len and (b[j] == ' ' or b[j] == '\t')) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
}

fn codeSpanAt(source: []const u8, start: usize) ?struct { text: []const u8, next: usize } {
    var open: usize = 0;
    while (start + open < source.len and source[start + open] == '`') open += 1;
    if (open == 0) return null;
    var index = start + open;
    while (index < source.len) {
        if (source[index] != '`') {
            index += 1;
            continue;
        }
        var close: usize = 0;
        while (index + close < source.len and source[index + close] == '`') close += 1;
        if (close == open) {
            var text = source[start + open .. index];
            if (text.len >= 2 and text[0] == ' ' and text[text.len - 1] == ' ') {
                text = text[1 .. text.len - 1];
            }
            return .{ .text = text, .next = index + close };
        }
        index += close;
    }
    return null;
}

fn entityAt(source: []const u8, start: usize) ?struct { bytes: [4]u8, len: u3, next: usize } {
    if (start + 3 >= source.len or source[start] != '&') return null;
    const end = std.mem.indexOfScalarPos(u8, source, start + 1, ';') orelse return null;
    if (end - start > 32) return null;
    const body = source[start + 1 .. end];
    var out: [4]u8 = undefined;
    if (namedEntity(body)) |ch| {
        out[0] = ch;
        return .{ .bytes = out, .len = 1, .next = end + 1 };
    }
    if (body.len >= 2 and body[0] == '#') {
        const value: u21 = if (body[1] == 'x' or body[1] == 'X')
            std.fmt.parseInt(u21, body[2..], 16) catch return null
        else
            std.fmt.parseInt(u21, body[1..], 10) catch return null;
        const len = std.unicode.utf8Encode(value, &out) catch return null;
        return .{ .bytes = out, .len = @intCast(len), .next = end + 1 };
    }
    return null;
}

fn namedEntity(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "amp")) return '&';
    if (std.mem.eql(u8, name, "lt")) return '<';
    if (std.mem.eql(u8, name, "gt")) return '>';
    if (std.mem.eql(u8, name, "quot")) return '"';
    if (std.mem.eql(u8, name, "apos")) return '\'';
    return null;
}

fn canOpenUnderscore(source: []const u8, cursor: usize) bool {
    const prev: u8 = if (cursor == 0) ' ' else source[cursor - 1];
    const next: u8 = if (cursor + 1 >= source.len) ' ' else source[cursor + 1];
    if (next == ' ' or next == '\t') return false;
    return !(std.ascii.isAlphanumeric(prev) and std.ascii.isAlphanumeric(next));
}

fn closingMarker(source: []const u8, start: usize, marker: u8) ?usize {
    var index = start + 1;
    while (index < source.len) : (index += 1) {
        if (source[index] != marker) continue;
        if (marker == '_' and index + 1 < source.len and
            std.ascii.isAlphanumeric(source[index - 1]) and
            std.ascii.isAlphanumeric(source[index + 1]))
            continue;
        return index;
    }
    return null;
}

fn isAsciiPunct(byte: u8) bool {
    return switch (byte) {
        '!',
        '"',
        '#',
        '$',
        '%',
        '&',
        '\'',
        '(',
        ')',
        '*',
        '+',
        ',',
        '-',
        '.',
        '/',
        ':',
        ';',
        '<',
        '=',
        '>',
        '?',
        '@',
        '[',
        '\\',
        ']',
        '^',
        '_',
        '`',
        '{',
        '|',
        '}',
        '~',
        => true,
        else => false,
    };
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
    try std.testing.expect(std.mem.indexOf(u8, output, "<li class=\"task-list-item\"><input type=\"checkbox\" class=\"task-checkbox\" disabled>checkbutton</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<input type=\"checkbox\" class=\"task-checkbox\" disabled checked>done") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<input type=\"checkbox\" class=\"task-checkbox\" disabled checked>also") != null);

    var bare: [512]u8 = undefined;
    const bare_out = try rendered("[ ] checkbutton\n[x] shipped", &bare);
    try std.testing.expect(std.mem.indexOf(u8, bare_out, "<li class=\"task-list-item\"><input type=\"checkbox\" class=\"task-checkbox\" disabled>checkbutton</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare_out, "<input type=\"checkbox\" class=\"task-checkbox\" disabled checked>shipped") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<li>parent<ul><li>child</li></ul></li>") != null);
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

test "Markdown covers setext fences refs entities and escapes" {
    var storage: [4096]u8 = undefined;
    const output = try rendered(
        \\Title
        \\=====
        \\
        \\Subtitle
        \\--------
        \\
        \\## Closed ##
        \\
        \\- - -
        \\
        \\    indented();
        \\
        \\~~~zig
        \\const x = 1;
        \\~~~
        \\
        \\See [docs][ref] and [ref].
        \\
        \\[ref]: https://example.com/ref
        \\
        \\\*star\* and &amp; &#42;
        \\
        \\`` code ` tick ``
        \\
        \\***both***
        \\
        \\3. later
        \\
        \\foo_bar_baz
        \\
        \\| left | right |
        \\| :--- | ---: |
        \\| a | b |
        \\
        \\> quoted
        \\>
        \\> still
        \\
        \\hard  
        \\break
        \\
        \\[named](https://example.com/t "Title")
        \\
        \\1) paren
        \\
        \\- keep
        \\
        \\- together
    ,
        &storage,
    );
    try std.testing.expect(std.mem.indexOf(u8, output, "<h1>Title</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<h2>Subtitle</h2>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<h2>Closed</h2>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<hr>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<pre class=\"code-block\"><code>indented();</code></pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "data-language=\"zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "href=\"https://example.com/ref\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "*star* and &amp; *") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<code>code ` tick</code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<strong><em>both</em></strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<ol start=\"3\"><li>later</li></ol>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "foo_bar_baz") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<em>foo_bar_baz</em>") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "class=\"align-right\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<blockquote>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "quoted") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "still") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hard<br>break") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "title=\"Title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<ol><li>paren</li></ol>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<ul><li>keep</li><li>together</li></ul>") != null);
}
