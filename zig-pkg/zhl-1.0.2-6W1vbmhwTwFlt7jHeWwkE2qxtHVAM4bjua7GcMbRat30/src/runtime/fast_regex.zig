const std = @import("std");
const scan = @import("scan.zig");

pub fn match(comptime pattern: []const u8, line: []const u8, start: usize) ?usize {
    if (std.mem.eql(u8, pattern, "^#{1,6}\\s+.*$")) return markdownHeading(line, start);
    if (std.mem.eql(u8, pattern, "^>.*$")) return if (start == 0 and line.len > 0 and line[0] == '>') line.len else null;
    if (std.mem.eql(u8, pattern, "^\\s*[-+*]\\s+")) return markdownBullet(line, start);
    if (std.mem.eql(u8, pattern, "^\\s*[0-9]+\\.\\s+")) return markdownOrdered(line, start);
    if (std.mem.eql(u8, pattern, "`[^`]+`")) return delimitedRun(line, start, '`', '`', false);
    if (std.mem.eql(u8, pattern, "^```.*$")) return if (start == 0 and std.mem.startsWith(u8, line, "```")) line.len else null;
    if (std.mem.eql(u8, pattern, "^~~~.*$")) return if (start == 0 and std.mem.startsWith(u8, line, "~~~")) line.len else null;
    if (std.mem.eql(u8, pattern, "\\*\\*[^*]+\\*\\*")) return markdownDelimited(line, start, "**");
    if (std.mem.eql(u8, pattern, "\\*[^*]+\\*")) return markdownDelimited(line, start, "*");
    if (std.mem.eql(u8, pattern, "\\[[^\\]]+\\]\\([^\\)]+\\)")) return markdownLink(line, start);
    if (std.mem.eql(u8, pattern, "<![A-Z]+[^>]*>")) return htmlBang(line, start);
    if (std.mem.eql(u8, pattern, "</?[A-Za-z][A-Za-z0-9:-]*")) return htmlTag(line, start);
    if (std.mem.eql(u8, pattern, "[A-Za-z_:][A-Za-z0-9_:.:-]*")) return htmlName(line, start);
    if (std.mem.eql(u8, pattern, "&[A-Za-z0-9#]+;")) return htmlEntity(line, start);
    if (std.mem.eql(u8, pattern, "#\\s*[A-Za-z_][A-Za-z0-9_]*")) return directiveName(line, start);
    if (std.mem.eql(u8, pattern, "\\$[A-Za-z_][A-Za-z0-9_]*")) return prefixedIdent(line, start, '$');
    return null;
}

fn markdownHeading(line: []const u8, start: usize) ?usize {
    if (start != 0) return null;
    var i: usize = 0;
    while (i < line.len and i < 6 and line[i] == '#') : (i += 1) {}
    if (i == 0 or i >= line.len or (line[i] != ' ' and line[i] != '\t')) return null;
    return line.len;
}

fn markdownBullet(line: []const u8, start: usize) ?usize {
    if (start != 0) return null;
    var i = skipInlineWhitespace(line, 0);
    if (i >= line.len or !scan.isAnyOf(line[i], "-+*")) return null;
    i += 1;
    const space_start = i;
    i = skipInlineWhitespace(line, i);
    return if (i > space_start) i else null;
}

fn markdownOrdered(line: []const u8, start: usize) ?usize {
    if (start != 0) return null;
    var i = skipInlineWhitespace(line, 0);
    const digit_start = i;
    while (i < line.len and scan.isDigit(line[i])) : (i += 1) {}
    if (i == digit_start or i + 1 >= line.len or line[i] != '.') return null;
    i += 1;
    const space_start = i;
    i = skipInlineWhitespace(line, i);
    return if (i > space_start) i else null;
}

fn markdownDelimited(line: []const u8, start: usize, comptime marker: []const u8) ?usize {
    if (!std.mem.startsWith(u8, line[start..], marker)) return null;
    var i = start + marker.len;
    if (i >= line.len or line[i] == marker[0]) return null;
    while (i < line.len) : (i += 1) {
        if (std.mem.startsWith(u8, line[i..], marker)) return i + marker.len;
        if (line[i] == marker[0]) return null;
    }
    return null;
}

fn markdownLink(line: []const u8, start: usize) ?usize {
    if (start >= line.len or line[start] != '[') return null;
    const close = std.mem.indexOfScalarPos(u8, line, start + 1, ']') orelse return null;
    if (close == start + 1 or close + 2 >= line.len or line[close + 1] != '(') return null;
    const end = std.mem.indexOfScalarPos(u8, line, close + 2, ')') orelse return null;
    return if (end == close + 2) null else end + 1;
}

fn delimitedRun(line: []const u8, start: usize, open: u8, close: u8, comptime allow_empty: bool) ?usize {
    if (start >= line.len or line[start] != open) return null;
    const end = std.mem.indexOfScalarPos(u8, line, start + 1, close) orelse return null;
    return if (!allow_empty and end == start + 1) null else end + 1;
}

fn htmlBang(line: []const u8, start: usize) ?usize {
    if (!std.mem.startsWith(u8, line[start..], "<!") or start + 2 >= line.len or !isUpper(line[start + 2])) return null;
    var i = start + 3;
    while (i < line.len and isUpper(line[i])) : (i += 1) {}
    return if (std.mem.indexOfScalarPos(u8, line, i, '>')) |end| end + 1 else null;
}

fn htmlTag(line: []const u8, start: usize) ?usize {
    if (start >= line.len or line[start] != '<') return null;
    var i = start + 1;
    if (i < line.len and line[i] == '/') i += 1;
    if (i >= line.len or !isAsciiAlpha(line[i])) return null;
    i += 1;
    while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == ':' or line[i] == '-')) : (i += 1) {}
    return i;
}

fn htmlName(line: []const u8, start: usize) ?usize {
    if (start >= line.len or !(isAsciiAlpha(line[start]) or line[start] == '_' or line[start] == ':')) return null;
    var i = start + 1;
    while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_' or line[i] == ':' or line[i] == '.' or line[i] == '-')) : (i += 1) {}
    return i;
}

fn htmlEntity(line: []const u8, start: usize) ?usize {
    if (start >= line.len or line[start] != '&') return null;
    var i = start + 1;
    while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '#')) : (i += 1) {}
    return if (i > start + 1 and i < line.len and line[i] == ';') i + 1 else null;
}

fn directiveName(line: []const u8, start: usize) ?usize {
    if (start >= line.len or line[start] != '#') return null;
    const i = skipInlineWhitespace(line, start + 1);
    if (i >= line.len or !scan.isIdentStart(line[i])) return null;
    return scan.scanAsciiIdentifier(line, i);
}

fn prefixedIdent(line: []const u8, start: usize, prefix: u8) ?usize {
    if (start + 1 >= line.len or line[start] != prefix or !scan.isIdentStart(line[start + 1])) return null;
    return scan.scanAsciiIdentifier(line, start + 1);
}

fn skipInlineWhitespace(line: []const u8, start: usize) usize {
    var i = start;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i;
}

fn isUpper(byte: u8) bool {
    return byte >= 'A' and byte <= 'Z';
}

fn isAsciiAlpha(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z');
}
