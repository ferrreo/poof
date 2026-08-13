const std = @import("std");
const dsl = @import("../native/dsl.zig");
const regex = @import("../regex/parser.zig");
const regex_class_parse = @import("../regex/class_parse.zig");
const regex_scan = @import("../regex/scan.zig");
const regex_vm = @import("../regex/vm.zig");
const textmate_line_end = @import("line_end.zig");

const max_native_string = dsl.max_string_bytes;

pub fn canCompileNativeRegex(pattern: []const u8) bool {
    _ = regex.Program(64).compile(pattern) catch return false;
    return true;
}

pub fn canCompileRegexVm(pattern: []const u8) bool {
    if (pattern.len <= 512) {
        _ = regex_vm.Program(512).compile(pattern) catch return false;
    } else {
        _ = regex_vm.Program(max_native_string).compile(pattern) catch return false;
    }
    return true;
}

pub fn regexLiteral(pattern: []const u8, buf: []u8) ?[]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        var byte = pattern[i];
        if (byte == '\\') {
            i += 1;
            if (i >= pattern.len or std.ascii.isAlphanumeric(pattern[i])) return null;
            byte = pattern[i];
        } else if (std.mem.indexOfScalar(u8, ".^$*+?[]()|{}", byte) != null) return null;
        if (out == buf.len) return null;
        buf[out] = byte;
        out += 1;
    }
    return buf[0..out];
}

pub fn literalPrefix(pattern: []const u8, buf: []u8) ?[]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        var byte = pattern[i];
        if (byte == '\\') {
            i += 1;
            if (i >= pattern.len) return null;
            byte = pattern[i];
        } else if (std.mem.indexOfScalar(u8, ".^$*+?[]()|{}", byte) != null) break;
        if (out == buf.len) return null;
        buf[out] = byte;
        out += 1;
    }
    return buf[0..out];
}

pub fn literalMarkerPrefix(pattern: []const u8, buf: []u8) ?[]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        var byte = pattern[i];
        if (byte == '\\') {
            if (i + 1 >= pattern.len) return null;
            const escaped = pattern[i + 1];
            if (std.ascii.isAlphabetic(escaped)) break;
            byte = escaped;
            i += 1;
        } else if (std.mem.indexOfScalar(u8, ".^$*+?[]()|{}", byte) != null) break;
        if (out == buf.len) return null;
        buf[out] = byte;
        out += 1;
    }
    if (out == 0) return null;
    const rest = pattern[i..];
    if (std.mem.startsWith(u8, rest, "\\s") or
        std.mem.startsWith(u8, rest, "[[:space:]]") or
        std.mem.startsWith(u8, rest, "[ \\t]"))
    {
        return buf[0..out];
    }
    return null;
}

pub fn anchoredLiteral(pattern: []const u8, buf: []u8) ?[]const u8 {
    if (std.mem.startsWith(u8, pattern, "^")) return regexLiteral(pattern[1..], buf);
    if (std.mem.startsWith(u8, pattern, "\\A")) return regexLiteral(pattern[2..], buf);
    if (std.mem.startsWith(u8, pattern, "\\G")) return regexLiteral(pattern[2..], buf);
    return null;
}

pub fn anchoredLinePattern(literal: []const u8, buf: []u8) ?[]const u8 {
    var out: usize = 0;
    appendRegexByte(buf, &out, '^') orelse return null;
    for (literal) |byte| {
        if (std.mem.indexOfScalar(u8, "\\.^$*+?[]()|{}", byte) != null) appendRegexByte(buf, &out, '\\') orelse return null;
        appendRegexByte(buf, &out, byte) orelse return null;
    }
    for (".*$") |byte| appendRegexByte(buf, &out, byte) orelse return null;
    return buf[0..out];
}

pub fn literalRegex(literal: []const u8, buf: []u8) ?[]const u8 {
    var out: usize = 0;
    for (literal) |byte| {
        if (std.mem.indexOfScalar(u8, "\\.^$*+?[]()|{}", byte) != null) appendRegexByte(buf, &out, '\\') orelse return null;
        appendRegexByte(buf, &out, byte) orelse return null;
    }
    return buf[0..out];
}

pub fn captureLiteral(pattern: []const u8, slot: u16, buf: []u8) ?[]const u8 {
    if (slot == 0) return anchoredStrictRegexLiteral(pattern, buf);
    return capturedGroupLiteral(pattern, slot, buf);
}

pub fn capturePattern(pattern: []const u8, slot: u16) ?[]const u8 {
    if (slot == 0) return pattern;
    return capturedGroupPattern(pattern, slot);
}

pub fn captureIsWholeMatchWithLookahead(pattern: []const u8, slot: u16) bool {
    if (slot != 1 or pattern.len == 0 or pattern[0] != '(' or !isCapturingGroup(pattern, 0)) return false;
    const end = groupEnd(pattern, 0) orelse return false;
    const suffix = pattern[end + 1 ..];
    return suffix.len > 0 and isSingleLookaround(suffix);
}

pub fn optionalCaptureBeforeLookahead(pattern: []const u8, slot: u16, buf: []u8) ?[]const u8 {
    if (slot != 1 or pattern.len == 0 or pattern[0] != '(' or !isCapturingGroup(pattern, 0)) return null;
    const end = groupEnd(pattern, 0) orelse return null;
    const suffix = pattern[end + 1 ..];
    if (!std.mem.startsWith(u8, suffix, "?\\s*")) return null;
    const lookahead = suffix[4..];
    if (!std.mem.startsWith(u8, lookahead, "(?=") or !isSingleLookaround(lookahead)) return null;
    var out: usize = 0;
    appendSlice(buf, &out, "(?:") orelse return null;
    appendSlice(buf, &out, pattern[1..end]) orelse return null;
    appendSlice(buf, &out, ")(?=\\s*") orelse return null;
    appendSlice(buf, &out, lookahead[3 .. lookahead.len - 1]) orelse return null;
    appendRegexByte(buf, &out, ')') orelse return null;
    return buf[0..out];
}

pub fn repeatedLiteral(pattern: []const u8, buf: []u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, pattern, '{') orelse return null;
    if (pattern.len < open + 5 or pattern[pattern.len - 1] != '}') return null;
    const comma = std.mem.indexOfScalarPos(u8, pattern, open + 1, ',') orelse return null;
    var base_buf: [max_native_string]u8 = undefined;
    const base = strictRegexLiteral(pattern[0..open], &base_buf) orelse return null;
    if (base.len == 0) return null;
    const min = std.fmt.parseInt(usize, pattern[open + 1 .. comma], 10) catch return null;
    const max = std.fmt.parseInt(usize, pattern[comma + 1 .. pattern.len - 1], 10) catch return null;
    if (min == 0 or min > max or min * base.len > buf.len) return null;
    var out: usize = 0;
    for (0..min) |_| {
        @memcpy(buf[out..][0..base.len], base);
        out += base.len;
    }
    return buf[0..out];
}

pub fn lazySpanPattern(begin: []const u8, end: []const u8, buf: []u8) ?[]const u8 {
    var out: usize = 0;
    appendSlice(buf, &out, "(?:") orelse return null;
    appendSlice(buf, &out, begin) orelse return null;
    appendSlice(buf, &out, ").*?") orelse return null;
    appendSlice(buf, &out, end) orelse return null;
    return buf[0..out];
}

pub fn zeroWidthBoundarySpan(begin: []const u8, end: []const u8) ?[]const u8 {
    const span = singleLookaroundBody(begin, "(?=") orelse return null;
    const boundary = singleLookaroundBody(end, "(?!") orelse return null;
    if (span.len == 0 or boundary.len == 0) return null;
    if (std.mem.endsWith(u8, span, "*") or std.mem.endsWith(u8, span, "+")) {
        if (std.mem.endsWith(u8, span[0 .. span.len - 1], boundary)) return span;
    }
    return null;
}

pub fn consumingPositiveLookahead(pattern: []const u8) ?[]const u8 {
    const body = singleLookaroundBody(pattern, "(?=") orelse return null;
    return singleAtomicBody(body) orelse body;
}

pub fn consumingPositiveLookaheadPattern(pattern: []const u8, buf: []u8) ?[]const u8 {
    if (consumingPositiveLookahead(pattern)) |body| return body;
    const prefixes = [_][]const u8{ "\\A", "^", "\\G" };
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, pattern, prefix)) continue;
        const body = singleLookaroundBody(pattern[prefix.len..], "(?=") orelse return null;
        const open = singleAtomicBody(body) orelse body;
        if (prefix.len + open.len > buf.len) return null;
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..][0..open.len], open);
        return buf[0 .. prefix.len + open.len];
    }
    return null;
}

pub fn backrefLineEndSlot(pattern: []const u8) ?u8 {
    if (pattern.len < 6 or pattern[0] != '(' or pattern[1] != '\\' or pattern[3] != ')' or pattern[4] != '|') return null;
    if (pattern[2] < '1' or pattern[2] > '9') return null;
    return if (textmate_line_end.classify(pattern[5..]) != .none) pattern[2] - '0' else null;
}

pub fn capturedByteClass(pattern: []const u8, slot: u8, buf: []u8) ?[]const u8 {
    if (slot != 1 or pattern.len < 4 or !std.mem.startsWith(u8, pattern, "([") or !std.mem.endsWith(u8, pattern, "])")) return null;
    var out: usize = 0;
    var i: usize = 2;
    while (i + 2 < pattern.len) : (i += 1) {
        var byte = pattern[i];
        if (byte == '\\') {
            i += 1;
            if (i + 2 >= pattern.len) return null;
            byte = pattern[i];
        } else if (std.mem.indexOfScalar(u8, "[]^-", byte) != null) return null;
        if (out == buf.len) return null;
        buf[out] = byte;
        out += 1;
    }
    return if (out == 0) null else buf[0..out];
}

pub fn isLineEndPattern(pattern: []const u8) bool {
    return std.mem.eql(u8, pattern, "$") or
        std.mem.eql(u8, pattern, "$()") or
        textmate_line_end.classify(pattern) != .none;
}

pub fn isNextLineStartEnd(pattern: []const u8) bool {
    return std.mem.eql(u8, pattern, "^(?<!\\G)");
}

pub fn literalOrLineEnd(pattern: []const u8, buf: []u8) ?[]const u8 {
    const bar = topLevelAlternation(pattern) orelse return null;
    if (literalLineEndAlt(pattern[0..bar], pattern[bar + 1 ..], buf)) |literal| return literal;
    return literalLineEndAlt(pattern[bar + 1 ..], pattern[0..bar], buf);
}

pub const SplitAlternation = struct {
    prefix: []const u8,
    open: []const u8,
    body: []const u8,
    suffix: []const u8,
    extended: bool = false,
};

pub fn splitTopLevelNonCapturingAlternation(pattern: []const u8) ?SplitAlternation {
    const split = splitTopLevelAlternationGroup(pattern) orelse return null;
    if (!std.mem.eql(u8, split.open, "(?:")) return null;
    return split;
}

pub fn splitTopLevelAlternationGroup(pattern: []const u8) ?SplitAlternation {
    return largestNestedAlternationGroup(pattern);
}

fn largestNestedAlternationGroup(pattern: []const u8) ?SplitAlternation {
    return largestNestedAlternationGroupWithFlags(pattern, false);
}

fn largestNestedAlternationGroupWithFlags(pattern: []const u8, initial_extended: bool) ?SplitAlternation {
    var best: ?SplitAlternation = null;
    var extended = initial_extended;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (regex_scan.ignoredEnd(pattern, i, pattern.len, extended)) |next| {
            i = next - 1;
            continue;
        }
        if (regex_scan.isolatedFlagEnd(pattern, i, pattern.len)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
            continue;
        }
        switch (pattern[i]) {
            '\\' => i += 1,
            '[' => i = regex_class_parse.findEnd(pattern, i) orelse return null,
            '(' => {
                const open_len: usize = if (std.mem.startsWith(u8, pattern[i..], "(?:") or std.mem.startsWith(u8, pattern[i..], "(?=")) 3 else if (i + 1 >= pattern.len or pattern[i + 1] != '?') 1 else continue;
                const end = regex_scan.findGroupEnd(pattern, i, extended) orelse return null;
                const body = pattern[i + open_len .. end];
                if (topLevelPipeFromWithExtended(body, 0, extended) != null) {
                    best = largerAlternation(best, .{ .prefix = pattern[0..i], .open = pattern[i .. i + open_len], .body = body, .suffix = pattern[end + 1 ..], .extended = extended });
                }
                if (largestNestedAlternationGroupWithFlags(body, extended)) |nested| {
                    const nested_start = nested.prefix.len;
                    const nested_end = nested_start + nested.open.len + nested.body.len;
                    best = largerAlternation(best, .{
                        .prefix = pattern[0 .. i + open_len + nested.prefix.len],
                        .open = nested.open,
                        .body = nested.body,
                        .suffix = pattern[i + open_len + nested_end + 1 ..],
                        .extended = nested.extended,
                    });
                }
                i = end;
            },
            else => {},
        }
    }
    return best;
}

fn largerAlternation(best: ?SplitAlternation, candidate: SplitAlternation) SplitAlternation {
    return if (best) |current| if (current.body.len >= candidate.body.len) current else candidate else candidate;
}

pub fn topLevelPipeFrom(pattern: []const u8, start: usize) ?usize {
    return topLevelPipeFromWithExtended(pattern, start, false);
}

pub fn topLevelPipeFromWithExtended(pattern: []const u8, start: usize, initial_extended: bool) ?usize {
    var depth: usize = 0;
    var extended = initial_extended;
    var i = start;
    while (i < pattern.len) : (i += 1) {
        if (regex_scan.ignoredEnd(pattern, i, pattern.len, extended)) |next| {
            i = next - 1;
            continue;
        }
        if (regex_scan.isolatedFlagEnd(pattern, i, pattern.len)) |next| {
            extended = regex_scan.applyExtendedFlag(pattern[i + 2 .. next - 1], extended);
            i = next - 1;
            continue;
        }
        switch (pattern[i]) {
            '\\' => i += 1,
            '[' => i = regex_class_parse.findEnd(pattern, i) orelse return null,
            '(' => if (depth == 0) {
                i = regex_scan.findGroupEnd(pattern, i, extended) orelse return null;
            } else {
                depth += 1;
            },
            ')' => if (depth == 0) return null else {
                depth -= 1;
            },
            '|' => if (depth == 0) return i,
            else => {},
        }
    }
    return null;
}

fn literalLineEndAlt(literal_part: []const u8, line_part: []const u8, buf: []u8) ?[]const u8 {
    if (!isLineEndPattern(line_part)) return null;
    const literal = regexLiteral(literal_part, buf) orelse return null;
    return if (literal.len == 0) null else literal;
}

fn topLevelAlternation(pattern: []const u8) ?usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => i += 1,
            '[' => i = regex_class_parse.findEnd(pattern, i) orelse return null,
            '(' => depth += 1,
            ')' => if (depth == 0) return null else {
                depth -= 1;
            },
            '|' => if (depth == 0) return i,
            else => {},
        }
    }
    return null;
}

fn capturedGroupLiteral(pattern: []const u8, slot: u16, buf: []u8) ?[]const u8 {
    const inner = capturedGroupPattern(pattern, slot) orelse return null;
    return anchoredStrictRegexLiteral(inner, buf);
}

fn capturedGroupPattern(pattern: []const u8, slot: u16) ?[]const u8 {
    var capture_slot: u16 = 0;
    var i: usize = 0;
    while (i < pattern.len) {
        switch (pattern[i]) {
            '\\' => i += 2,
            '[' => i = (regex_class_parse.findEnd(pattern, i) orelse return null) + 1,
            '(' => {
                if (isCapturingGroup(pattern, i)) {
                    capture_slot += 1;
                    if (capture_slot == slot) {
                        const end = groupEnd(pattern, i) orelse return null;
                        return pattern[i + 1 .. end];
                    }
                }
                i += 1;
            },
            else => i += 1,
        }
    }
    return null;
}

fn isCapturingGroup(pattern: []const u8, start: usize) bool {
    if (start >= 2 and pattern[start - 2] == '(' and pattern[start - 1] == '?') return false;
    if (start + 1 >= pattern.len or pattern[start + 1] != '?') return true;
    if (start + 2 >= pattern.len) return false;
    if (pattern[start + 2] == '\'') return true;
    if (pattern[start + 2] != '<') return false;
    return start + 3 >= pattern.len or (pattern[start + 3] != '=' and pattern[start + 3] != '!');
}

fn isSingleLookaround(pattern: []const u8) bool {
    if (!std.mem.startsWith(u8, pattern, "(?=") and !std.mem.startsWith(u8, pattern, "(?!")) return false;
    const end = groupEnd(pattern, 0) orelse return false;
    return end + 1 == pattern.len;
}

fn singleLookaroundBody(pattern: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    const end = groupEnd(pattern, 0) orelse return null;
    if (end + 1 != pattern.len) return null;
    return pattern[prefix.len..end];
}

fn singleAtomicBody(pattern: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, pattern, "(?>")) return null;
    const end = groupEnd(pattern, 0) orelse return null;
    if (end + 1 != pattern.len) return null;
    return pattern[3..end];
}

fn groupEnd(pattern: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => i += 1,
            '[' => i = regex_class_parse.findEnd(pattern, i) orelse return null,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn strictRegexLiteral(pattern: []const u8, buf: []u8) ?[]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        var byte = pattern[i];
        if (byte == '\\') {
            i += 1;
            if (i >= pattern.len or std.ascii.isAlphanumeric(pattern[i])) return null;
            byte = pattern[i];
        } else if (std.mem.indexOfScalar(u8, ".^$*+?[()|{", byte) != null) return null;
        if (out == buf.len) return null;
        buf[out] = byte;
        out += 1;
    }
    return buf[0..out];
}

fn anchoredStrictRegexLiteral(pattern: []const u8, buf: []u8) ?[]const u8 {
    if (std.mem.startsWith(u8, pattern, "^")) return strictRegexLiteral(pattern[1..], buf);
    if (std.mem.startsWith(u8, pattern, "\\A")) return strictRegexLiteral(pattern[2..], buf);
    if (std.mem.startsWith(u8, pattern, "\\G")) return strictRegexLiteral(pattern[2..], buf);
    return strictRegexLiteral(pattern, buf);
}

fn appendRegexByte(buf: []u8, out: *usize, byte: u8) ?void {
    if (out.* == buf.len) return null;
    buf[out.*] = byte;
    out.* += 1;
}

fn appendSlice(buf: []u8, out: *usize, value: []const u8) ?void {
    if (out.* + value.len > buf.len) return null;
    @memcpy(buf[out.*..][0..value.len], value);
    out.* += value.len;
}

test "TextMate pattern extracts literal delimiter before line end" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("\"", literalOrLineEnd("\\\"|(?<!\\\\)(?=\\s*\\n)", &buf).?);
    try std.testing.expectEqualStrings("'", literalOrLineEnd("(?<!\\\\)(?=\\s*\\n)|'", &buf).?);
    try std.testing.expect(literalOrLineEnd("(\\\")|(\\n)", &buf) == null);
}

test "TextMate pattern handles anchored and repeated literals" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\"\"\"", anchoredLiteral("\\G\"\"\"", &buf).?);
    try std.testing.expect(regexLiteral("\\G\"\"\"", &buf) == null);
    try std.testing.expectEqualStrings("]", captureLiteral("]", 0, &buf).?);
    try std.testing.expectEqualStrings("\"\"\"", repeatedLiteral("\"{3,5}", &buf).?);
    try std.testing.expectEqualStrings("if|while", capturePattern("\\b(if|while)\\b", 1).?);
}

test "TextMate pattern detects captured whole-match lookahead" {
    try std.testing.expect(captureIsWholeMatchWithLookahead("([A-Za-z_][A-Za-z0-9_]*)(?=\\s*=>)", 1));
    try std.testing.expect(!captureIsWholeMatchWithLookahead("([A-Za-z_][A-Za-z0-9_]*)", 1));
    try std.testing.expect(!captureIsWholeMatchWithLookahead("([A-Za-z_][A-Za-z0-9_]*)\\s*(?==)", 1));
}

test "TextMate pattern rewrites optional capture before lookahead" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "(?:[A-Za-z_][A-Za-z0-9_]*)(?=\\s*`)",
        optionalCaptureBeforeLookahead("([A-Za-z_][A-Za-z0-9_]*)?\\s*(?=`)", 1, &buf).?,
    );
    try std.testing.expect(optionalCaptureBeforeLookahead("([A-Za-z_][A-Za-z0-9_]*)?\\s*(?!`)", 1, &buf) == null);
}

test "TextMate pattern builds lazy span regex" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("(?:a|b).*?(?=$)", lazySpanPattern("a|b", "(?=$)", &buf).?);
}

test "TextMate pattern extracts zero-width boundary span" {
    try std.testing.expectEqualStrings(
        "[A-Z_a-z][0-9A-Z_a-z]*",
        zeroWidthBoundarySpan("(?=[A-Z_a-z][0-9A-Z_a-z]*)", "(?![0-9A-Z_a-z])").?,
    );
    try std.testing.expect(zeroWidthBoundarySpan("(?=foo)", "(?!bar)") == null);
}

test "TextMate pattern unwraps consuming positive lookahead" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("^\\[(comment)]$", consumingPositiveLookahead("(?=(?>^\\[(comment)]$))").?);
    try std.testing.expectEqualStrings("^abc$", consumingPositiveLookahead("(?=^abc$)").?);
    try std.testing.expectEqualStrings("\\A(-{3,})", consumingPositiveLookaheadPattern("\\A(?=(-{3,}))", &buf).?);
    try std.testing.expectEqualStrings("^---", consumingPositiveLookaheadPattern("^(?=(?>---))", &buf).?);
    try std.testing.expect(consumingPositiveLookahead("(?!abc)") == null);
}

test "TextMate pattern splits positive lookahead alternation with extended comments" {
    const split = splitTopLevelAlternationGroup("(?x)foo(?=a # ignored |\n|b|c)").?;
    try std.testing.expectEqualStrings("(?x)foo", split.prefix);
    try std.testing.expectEqualStrings("(?=", split.open);
    try std.testing.expect(split.extended);
    try std.testing.expectEqual(@as(?usize, 14), topLevelPipeFromWithExtended(split.body, 0, split.extended));
}
