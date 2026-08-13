const std = @import("std");
const regex_escape = @import("escape.zig");

pub const Kind = enum {
    dotted_identifier_lookahead,
    bounded_literal,
    bounded_alt,
    literal_or_lookahead,
    literal_space_or_lookahead,
    boundary_class_lookahead,
    line_end_lookahead,
    unescaped_line_end,
    anchored_http_run_pipe,
    anchored_text_run_pipe,
};

pub const Classification = struct {
    kind: Kind,
    alt_bytes: [8][16]u8 = [_][16]u8{[_]u8{0} ** 16} ** 8,
    alt_lens: [8]u8 = [_]u8{0} ** 8,
    alt_count: u8 = 0,
    lookahead_buf: [16]u8 = [_]u8{0} ** 16,
    lookahead_len: u8 = 0,

    pub fn literal(self: *const @This()) []const u8 {
        return self.alt_bytes[0][0..self.alt_lens[0]];
    }

    pub fn lookahead(self: *const @This()) []const u8 {
        return self.lookahead_buf[0..self.lookahead_len];
    }
};

pub fn classify(pattern: []const u8) ?Classification {
    if (std.mem.eql(u8, pattern, "(?=(([$_[:alpha:]][$_[:alnum:]]*\\s*\\??\\.\\s*)*|(\\??\\.\\s*)?)([$_[:alpha:]][$_[:alnum:]]*))"))
        return .{ .kind = .dotted_identifier_lookahead };
    if (boundedLiteral(pattern)) |literal| return init(.bounded_literal, &.{literal}, "");
    if (boundedAlt(pattern)) |item| return item;
    if (literalOrLookahead(pattern)) |item| return item;
    if (std.mem.eql(u8, pattern, "(?=\\s|\\*/|[^]$A-\\[_a-{}])")) return .{ .kind = .boundary_class_lookahead };
    if (std.mem.eql(u8, pattern, "(?=\\n)")) return .{ .kind = .line_end_lookahead };
    if (std.mem.eql(u8, pattern, "(?<=\\n)(?<!\\\\\\n)")) return .{ .kind = .unescaped_line_end };
    if (std.mem.eql(u8, pattern, "\\G((?=https?://)(?:[^*|}\\s]|\\*/)+)(\\|)?")) return .{ .kind = .anchored_http_run_pipe };
    if (std.mem.eql(u8, pattern, "\\G((?:[^*@{|}\\s]|\\*[^/])+)(\\|)?")) return .{ .kind = .anchored_text_run_pipe };
    return null;
}

pub fn consumes(kind: Kind) bool {
    return kind == .bounded_literal or kind == .bounded_alt or kind == .literal_or_lookahead or kind == .literal_space_or_lookahead;
}

pub fn match(kind: Kind, alt_bytes: anytype, alt_lens: anytype, alt_count: usize, lookahead: []const u8, text: []const u8, index: usize, captures: anytype) ?usize {
    return switch (kind) {
        .dotted_identifier_lookahead => if (matchDottedIdentifier(text, index)) index else null,
        .bounded_literal => matchBoundedLiteral(alt_bytes[0][0..alt_lens[0]], text, index, captures),
        .bounded_alt => matchBoundedAlt(alt_bytes, alt_lens, alt_count, text, index, captures),
        .literal_or_lookahead => matchLiteralOrLookahead(alt_bytes[0][0..alt_lens[0]], lookahead, text, index, captures, false),
        .literal_space_or_lookahead => matchLiteralOrLookahead(alt_bytes[0][0..alt_lens[0]], lookahead, text, index, captures, true),
        .boundary_class_lookahead => if (matchBoundaryClassLookahead(text, index)) index else null,
        .line_end_lookahead => if (matchLineEnd(text, index)) index else null,
        .unescaped_line_end => if (matchUnescapedLineEnd(text, index)) index else null,
        .anchored_http_run_pipe => matchAnchoredRun(text, index, .http),
        .anchored_text_run_pipe => matchAnchoredRun(text, index, .text),
    };
}

fn boundedLiteral(pattern: []const u8) ?[]const u8 {
    var literal = boundedMiddle(pattern) orelse return null;
    if (literal.len >= 2 and literal[0] == '(' and literal[literal.len - 1] == ')') literal = literal[1 .. literal.len - 1];
    for (literal) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$')) return null;
    return literal;
}

fn boundedMiddle(pattern: []const u8) ?[]const u8 {
    const prefix = "(?<![$_[:alnum:]])(?:(?<=\\.\\.\\.)|(?<!\\.))";
    const suffix = "(?![$_[:alnum:]])(?:(?=\\.\\.\\.)|(?!\\.))";
    if (!std.mem.startsWith(u8, pattern, prefix) or !std.mem.endsWith(u8, pattern, suffix)) return null;
    return pattern[prefix.len .. pattern.len - suffix.len];
}

fn boundedAlt(pattern: []const u8) ?Classification {
    const literal = boundedMiddle(pattern) orelse return null;
    if (literal.len < 3 or literal[0] != '(' or literal[literal.len - 1] != ')' or std.mem.indexOfScalar(u8, literal, '|') == null) return null;
    var alts: [8][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, literal[1 .. literal.len - 1], '|');
    while (it.next()) |alt| {
        if (count == alts.len or alt.len == 0) return null;
        for (alt) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$')) return null;
        alts[count] = alt;
        count += 1;
    }
    return init(.bounded_alt, alts[0..count], "");
}

fn literalOrLookahead(pattern: []const u8) ?Classification {
    const marker = "|(?=";
    const split = std.mem.indexOf(u8, pattern, marker) orelse return null;
    if (pattern[pattern.len - 1] != ')') return null;
    const lookahead = pattern[split + marker.len .. pattern.len - 1];
    // Explicit slice type: at comptime the initializer is a pointer-to-array
    // whose length would otherwise be frozen into the inferred type.
    var left: []const u8 = pattern[0..split];
    var space = false;
    if (std.mem.endsWith(u8, left, "\\s*")) {
        left = left[0 .. left.len - 3];
        space = true;
    }
    var literal_buf: [16]u8 = undefined;
    var lookahead_buf: [16]u8 = undefined;
    const literal = flattenLiteralGroups(left, &literal_buf) orelse return null;
    const lookahead_literal = flattenLiteralGroups(lookahead, &lookahead_buf) orelse return null;
    return init(if (space) .literal_space_or_lookahead else .literal_or_lookahead, &.{literal}, lookahead_literal);
}

fn init(kind: Kind, alts: []const []const u8, lookahead: []const u8) ?Classification {
    if (alts.len == 0 or alts.len > 7 or lookahead.len > 16) return null;
    var out = Classification{ .kind = kind, .alt_count = @intCast(alts.len), .lookahead_len = @intCast(lookahead.len) };
    for (alts, 0..) |alt, i| {
        if (alt.len > 16) return null;
        out.alt_lens[i] = @intCast(alt.len);
        @memcpy(out.alt_bytes[i][0..alt.len], alt);
    }
    @memcpy(out.lookahead_buf[0..lookahead.len], lookahead);
    return out;
}

fn flattenLiteralGroups(pattern: []const u8, buf: *[16]u8) ?[]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '(' or c == ')') continue;
        if (std.mem.indexOfScalar(u8, ".^$*+?[]|", c) != null) return null;
        if (out == buf.len) return null;
        buf[out] = if (c == '\\') blk: {
            i += 1;
            if (i >= pattern.len) return null;
            if (regex_escape.isNonLiteral(pattern[i]) or pattern[i] == 'b' or pattern[i] == 'B') return null;
            break :blk pattern[i];
        } else c;
        out += 1;
    }
    return if (out == 0) null else buf[0..out];
}

fn matchBoundedLiteral(literal: []const u8, text: []const u8, index: usize, captures: anytype) ?usize {
    if (literal.len == 0 or !std.mem.startsWith(u8, text[index..], literal)) return null;
    if (index > 0 and isIdent(text[index - 1])) return null;
    if (index > 0 and text[index - 1] == '.' and !endsWithDots(text[0..index])) return null;
    const end = index + literal.len;
    if (end < text.len and isIdent(text[end])) return null;
    if (end < text.len and text[end] == '.' and !std.mem.startsWith(u8, text[end..], "...")) return null;
    if (captures.len > 1) captures[1] = .{ .start = @intCast(index), .end = @intCast(end), .set = true };
    return end;
}

fn matchBoundedAlt(alt_bytes: anytype, alt_lens: anytype, alt_count: usize, text: []const u8, index: usize, captures: anytype) ?usize {
    var i: usize = 0;
    while (i < alt_count) : (i += 1) {
        if (matchBoundedLiteral(alt_bytes[i][0..alt_lens[i]], text, index, captures)) |end| return end;
    }
    return null;
}

fn matchLiteralOrLookahead(literal: []const u8, lookahead: []const u8, text: []const u8, index: usize, captures: anytype, comptime space: bool) ?usize {
    if (std.mem.startsWith(u8, text[index..], lookahead)) return index;
    if (!std.mem.startsWith(u8, text[index..], literal)) return null;
    var end = index + literal.len;
    if (space) {
        while (end < text.len and (text[end] == ' ' or text[end] == '\t')) : (end += 1) {}
    }
    if (captures.len > 1) captures[1] = .{ .start = @intCast(index), .end = @intCast(index + literal.len), .set = true };
    return end;
}

fn matchBoundaryClassLookahead(text: []const u8, index: usize) bool {
    if (index >= text.len or std.ascii.isWhitespace(text[index])) return true;
    if (std.mem.startsWith(u8, text[index..], "*/")) return true;
    const c = text[index];
    return !(c == ']' or c == '$' or (c >= 'A' and c <= '[') or c == '_' or (c >= 'a' and c <= '{') or c == '}');
}

fn matchLineEnd(text: []const u8, index: usize) bool {
    return index == text.len or (index < text.len and text[index] == '\n');
}

fn matchUnescapedLineEnd(text: []const u8, index: usize) bool {
    return matchLineEnd(text, index) and (index == 0 or text[index - 1] != '\\');
}

const RunKind = enum { http, text };

fn matchAnchoredRun(text: []const u8, index: usize, comptime kind: RunKind) ?usize {
    if (kind == .http and !(std.mem.startsWith(u8, text[index..], "http://") or std.mem.startsWith(u8, text[index..], "https://"))) return null;
    var end = index;
    while (end < text.len) {
        if (kind == .http and std.mem.startsWith(u8, text[end..], "*/")) {
            end += 2;
        } else if (kind == .http and (text[end] == '*' or text[end] == '|' or text[end] == '}' or std.ascii.isWhitespace(text[end]))) {
            break;
        } else if (kind == .text and (text[end] == '@' or text[end] == '{' or text[end] == '|' or text[end] == '}' or std.ascii.isWhitespace(text[end]))) {
            break;
        } else if (kind == .text and text[end] == '*' and end + 1 < text.len and text[end + 1] == '/') {
            break;
        } else end += 1;
    }
    if (end == index) return null;
    if (end < text.len and text[end] == '|') end += 1;
    return end;
}

fn matchDottedIdentifier(text: []const u8, index: usize) bool {
    var pos = index;
    if (std.mem.startsWith(u8, text[pos..], "?.")) pos += 2 else if (pos < text.len and text[pos] == '.') pos += 1;
    while (pos < text.len and (text[pos] == ' ' or text[pos] == '\t')) : (pos += 1) {}
    while (true) {
        if (pos >= text.len or !isIdentStart(text[pos])) return false;
        pos += 1;
        while (pos < text.len and isIdent(text[pos])) : (pos += 1) {}
        var dot = pos;
        while (dot < text.len and (text[dot] == ' ' or text[dot] == '\t')) : (dot += 1) {}
        if (std.mem.startsWith(u8, text[dot..], "?.")) {
            pos = dot + 2;
        } else if (dot < text.len and text[dot] == '.') {
            pos = dot + 1;
        } else return true;
        while (pos < text.len and (text[pos] == ' ' or text[pos] == '\t')) : (pos += 1) {}
    }
}

fn endsWithDots(text: []const u8) bool {
    return text.len >= 3 and std.mem.eql(u8, text[text.len - 3 ..], "...");
}

fn isIdentStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$';
}

fn isIdent(byte: u8) bool {
    return isIdentStart(byte) or std.ascii.isDigit(byte);
}

test "generic lowered regex shapes match bounded literal and dotted identifier lookahead" {
    const Capture = struct { start: usize = 0, end: usize = 0, set: bool = false };
    const bounded = classify("(?<![$_[:alnum:]])(?:(?<=\\.\\.\\.)|(?<!\\.))true(?![$_[:alnum:]])(?:(?=\\.\\.\\.)|(?!\\.))").?;
    var captures = [_]Capture{.{}} ** 4;
    try std.testing.expectEqual(@as(usize, 4), match(bounded.kind, bounded.alt_bytes, bounded.alt_lens, bounded.alt_count, bounded.lookahead(), "true", 0, &captures).?);
    try std.testing.expectEqual(null, match(bounded.kind, bounded.alt_bytes, bounded.alt_lens, bounded.alt_count, bounded.lookahead(), "obj.true", 4, &captures));
    const bounded_alt = classify("(?<![$_[:alnum:]])(?:(?<=\\.\\.\\.)|(?<!\\.))(this|true|false)(?![$_[:alnum:]])(?:(?=\\.\\.\\.)|(?!\\.))").?;
    try std.testing.expectEqual(@as(usize, 4), match(bounded_alt.kind, bounded_alt.alt_bytes, bounded_alt.alt_lens, bounded_alt.alt_count, bounded_alt.lookahead(), "this", 0, &captures).?);
    const dotted = classify("(?=(([$_[:alpha:]][$_[:alnum:]]*\\s*\\??\\.\\s*)*|(\\??\\.\\s*)?)([$_[:alpha:]][$_[:alnum:]]*))").?;
    try std.testing.expectEqual(@as(usize, 0), match(dotted.kind, dotted.alt_bytes, dotted.alt_lens, dotted.alt_count, dotted.lookahead(), "foo?.bar`x`", 0, &captures).?);
    const end = classify("(</)caption(>)|(?=\\*/)").?;
    try std.testing.expectEqual(@as(usize, 10), match(end.kind, end.alt_bytes, end.alt_lens, end.alt_count, end.lookahead(), "</caption>", 0, &captures).?);
    try std.testing.expectEqual(@as(usize, 0), match(end.kind, end.alt_bytes, end.alt_lens, end.alt_count, end.lookahead(), "*/", 0, &captures).?);
    const comma = classify("(,)|(?=})").?;
    try std.testing.expectEqual(@as(usize, 1), match(comma.kind, comma.alt_bytes, comma.alt_lens, comma.alt_count, comma.lookahead(), ",", 0, &captures).?);
    try std.testing.expect(captures[1].set);
    try std.testing.expectEqual(@as(?Classification, null), classify("(a\\A)|(?=b)"));
    try std.testing.expectEqual(@as(?Classification, null), classify("(?=[\\t \\&;|]|$|[\\n)`])|(?=<)"));
    const url = classify("\\G((?=https?://)(?:[^*|}\\s]|\\*/)+)(\\|)?").?;
    try std.testing.expectEqual(@as(usize, 15), match(url.kind, url.alt_bytes, url.alt_lens, url.alt_count, url.lookahead(), "https://a.test|x", 0, &captures).?);
    const line_end = classify("(?=\\n)").?;
    try std.testing.expectEqual(@as(usize, 3), match(line_end.kind, line_end.alt_bytes, line_end.alt_lens, line_end.alt_count, line_end.lookahead(), "abc", 3, &captures).?);
    const guarded = classify("(?<=\\n)(?<!\\\\\\n)").?;
    try std.testing.expectEqual(null, match(guarded.kind, guarded.alt_bytes, guarded.alt_lens, guarded.alt_count, guarded.lookahead(), "abc\\", 4, &captures));
}
