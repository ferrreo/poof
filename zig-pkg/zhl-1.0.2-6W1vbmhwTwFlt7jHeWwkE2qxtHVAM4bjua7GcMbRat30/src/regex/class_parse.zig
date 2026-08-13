const std = @import("std");
const regex_classes = @import("classes.zig");
const regex_escape = @import("escape.zig");
const regex_unicode = @import("unicode.zig");

pub const Error = error{ UnclosedClass, DanglingEscape, InvalidRange, UnsupportedRegex };
pub const max_codepoints = 64;
pub const max_ranges = 320;

const ScalarRange = regex_unicode.ScalarRange;

pub const Result = struct {
    mask: [4]u64 = [_]u64{0} ** 4,
    codepoints: [max_codepoints]regex_escape.CodepointEscape = [_]regex_escape.CodepointEscape{.{}} ** max_codepoints,
    codepoint_count: u8 = 0,
    ranges: [max_ranges]ScalarRange = [_]ScalarRange{.{ .lo = 0, .hi = 0 }} ** max_ranges,
    range_count: u16 = 0,
    negated: bool = false,
    scalar_high: bool = false,
    exclude_codepoints: bool = false,
    end: usize = 0,
};

pub const Options = struct {
    ascii_digit: bool = false,
    ascii_word: bool = false,
    ascii_space: bool = false,
    ascii_posix: bool = false,
    byte_posix: bool = false,
    ascii_unicode_properties: bool = false,
};

pub fn parse(pattern: []const u8, start: usize) Error!Result {
    return parseWithOptions(pattern, start, .{});
}

pub fn parseWithOptions(pattern: []const u8, start: usize, options: Options) Error!Result {
    if (start >= pattern.len or pattern[start] != '[') return error.UnsupportedRegex;
    var i = start + 1;
    var negated = false;
    if (i < pattern.len and pattern[i] == '^') {
        negated = true;
        i += 1;
    }
    var result = try parseExpr(pattern, &i, options);
    if (i >= pattern.len or pattern[i] != ']') return error.UnclosedClass;
    if (negated) {
        const included_scalar_high = result.scalar_high;
        result.negated = true;
        result.scalar_high = !included_scalar_high;
        result.exclude_codepoints = result.codepoint_count != 0 or result.range_count != 0;
        invert(&result.mask);
        if (included_scalar_high) regex_classes.clearHighBytes(&result.mask);
    }
    result.end = i;
    return result;
}

pub fn findEnd(pattern: []const u8, start: usize) ?usize {
    return (parse(pattern, start) catch return null).end;
}

pub fn matchAt(result: Result, text: []const u8, pos: usize, ignore_case: bool) ?usize {
    if (result.exclude_codepoints) {
        if (classCodepointEnd(result, text, pos, ignore_case) != null) return null;
        if (foldedScalarByteMatch(result, text, pos, ignore_case)) |ok| return if (ok) scalarEnd(text, pos) else null;
        if (result.scalar_high and pos < text.len and text[pos] >= 0x80 and scalarAt(text, pos) != null) return scalarEnd(text, pos);
        if (!classContainsByte(result, text, pos, ignore_case)) return null;
        return scalarEnd(text, pos);
    }
    if (classCodepointEnd(result, text, pos, ignore_case)) |next| return next;
    if (foldedScalarByteMatch(result, text, pos, ignore_case)) |ok| {
        if (ok) return scalarEnd(text, pos);
        if (result.negated) return null;
    }
    if (result.scalar_high and pos < text.len and text[pos] >= 0x80 and scalarAt(text, pos) != null) return scalarEnd(text, pos);
    if (!classContainsByte(result, text, pos, ignore_case)) return null;
    return pos + 1;
}

fn classCodepointEnd(result: Result, text: []const u8, pos: usize, ignore_case: bool) ?usize {
    for (result.codepoints[0..result.codepoint_count]) |codepoint| {
        if (regex_escape.matchCodepoint(codepoint, text, pos, ignore_case)) |next| return next;
    }
    const scalar = scalarAt(text, pos) orelse return null;
    for (result.ranges[0..result.range_count]) |range| {
        if (scalar >= range.lo and scalar <= range.hi) return scalarEnd(text, pos);
        if (ignore_case) {
            const folded = regex_escape.scalarFold(scalar);
            if (folded >= regex_escape.scalarFold(range.lo) and folded <= regex_escape.scalarFold(range.hi)) return scalarEnd(text, pos);
        }
    }
    return null;
}

fn classContainsByte(result: Result, text: []const u8, pos: usize, ignore_case: bool) bool {
    if (pos >= text.len) return false;
    if (regex_classes.contains(result.mask, text[pos])) return true;
    if (!ignore_case) return false;
    const byte = text[pos];
    if (byte >= 'a' and byte <= 'z' and regex_classes.contains(result.mask, byte - 32)) return true;
    if (byte >= 'A' and byte <= 'Z' and regex_classes.contains(result.mask, byte + 32)) return true;
    return false;
}

fn foldedScalarByteMatch(result: Result, text: []const u8, pos: usize, ignore_case: bool) ?bool {
    if (!ignore_case or pos >= text.len or text[pos] < 0x80) return null;
    const scalar = scalarAt(text, pos) orelse return null;
    const folded = regex_escape.scalarFold(scalar);
    if (folded > 0x7f) return null;
    return regex_classes.contains(result.mask, @intCast(folded));
}

fn scalarEnd(text: []const u8, pos: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch return pos + 1;
    return if (pos + len <= text.len) pos + len else pos + 1;
}

fn scalarAt(text: []const u8, pos: usize) ?u21 {
    if (pos >= text.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch return null;
    if (pos + len > text.len) return null;
    return std.unicode.utf8Decode(text[pos..][0..len]) catch null;
}

fn parseExpr(pattern: []const u8, index: *usize, options: Options) Error!Result {
    var result = try parseUnion(pattern, index, options);
    while (startsIntersection(pattern, index.*)) {
        index.* += 2;
        const rhs = try parseUnion(pattern, index, options);
        try intersect(&result, rhs);
    }
    return result;
}

fn parseUnion(pattern: []const u8, index: *usize, options: Options) Error!Result {
    var result = Result{};
    var first = true;
    while (index.* < pattern.len and !classEnds(pattern[index.*], first) and !startsIntersection(pattern, index.*)) {
        if (try parsePosix(pattern, index, &result, options)) {
            first = false;
            continue;
        }
        if (pattern[index.*] == '[' and !classEnds(pattern[index.*], first)) {
            // Explicit optional type: a bare `catch null` collapses to the bare
            // payload type when the operand is comptime-known non-error.
            const parsed: ?Result = parseWithOptions(pattern, index.*, options) catch null;
            if (parsed) |nested| {
                try merge(&result, nested);
                index.* = nested.end + 1;
                first = false;
                continue;
            }
        }
        if (try parseEscapeSet(pattern, index, &result, options)) {
            first = false;
            continue;
        }
        const lo = try readClassAtom(pattern, index);
        if (index.* + 1 < pattern.len and pattern[index.*] == '-' and pattern[index.* + 1] != ']') {
            index.* += 1;
            const hi = try readClassAtom(pattern, index);
            try addRange(&result, lo, hi);
        } else {
            try addAtom(&result, lo);
        }
        first = false;
    }
    return result;
}

fn parsePosix(pattern: []const u8, index: *usize, result: *Result, options: Options) Error!bool {
    if (!std.mem.startsWith(u8, pattern[index.*..], "[:")) return false;
    const start = index.* + 2;
    const close = std.mem.indexOf(u8, pattern[start..], ":]") orelse return false;
    const name = pattern[start .. start + close];
    const inverse = name.len > 0 and name[0] == '^';
    const body = if (inverse) name[1..] else name;
    const ascii_posix = options.ascii_posix or
        (options.ascii_digit and std.ascii.eqlIgnoreCase(body, "digit")) or
        (options.ascii_word and std.ascii.eqlIgnoreCase(body, "word"));
    if (!ascii_posix and !options.byte_posix and try addUnicodePosix(result, body, inverse)) {
        index.* = start + close + 2;
        return true;
    }
    const includes_scalar_high = !ascii_posix and posixIncludesScalarHigh(body);
    if ((options.ascii_space or ascii_posix) and std.ascii.eqlIgnoreCase(body, "space")) {
        if (inverse) regex_classes.addInverseAsciiSpace(&result.mask) else regex_classes.addAsciiSpace(&result.mask);
    } else if (!regex_classes.addPosixClass(&result.mask, name)) return error.UnsupportedRegex;
    if (inverse) {
        result.scalar_high = result.scalar_high or !includes_scalar_high;
        if (includes_scalar_high) regex_classes.clearHighBytes(&result.mask);
    } else result.scalar_high = result.scalar_high or includes_scalar_high;
    index.* = start + close + 2;
    return true;
}

fn parseEscapeSet(pattern: []const u8, index: *usize, result: *Result, options: Options) Error!bool {
    if (index.* + 1 >= pattern.len or pattern[index.*] != '\\') return false;
    const escape = pattern[index.* + 1];
    if (regex_escape.isClass(escape)) {
        if (!options.byte_posix and try addUnicodeEscapeClass(result, escape, options)) {
            index.* += 2;
            return true;
        }
        if (escape >= 'A' and escape <= 'Z' and (escape != 'W' or options.ascii_word or options.ascii_posix)) result.scalar_high = true;
        if ((options.ascii_space or options.ascii_posix) and (escape == 's' or escape == 'S')) {
            if (escape == 'S') regex_classes.addInverseAsciiSpace(&result.mask) else regex_classes.addAsciiSpace(&result.mask);
        } else if (escape >= 'A' and escape <= 'Z')
            regex_classes.addInverseEscape(&result.mask, escape)
        else
            regex_classes.addEscape(&result.mask, escape);
        if (escape == 'W' and !options.ascii_word and !options.ascii_posix) regex_classes.clearHighBytes(&result.mask);
        index.* += 2;
        return true;
    }
    if (escape == 'p' or escape == 'P') {
        if (regex_unicode.propertyName(pattern[index.* + 2 ..])) |property| {
            if (try addAsciiProperty(result, property.name, escape == 'P', options)) {
                index.* += property.consumed + 2;
                return true;
            }
            if (!options.byte_posix and std.ascii.eqlIgnoreCase(property.name, "Alnum")) {
                _ = try addUnicodePosix(result, "alnum", escape == 'P');
                index.* += property.consumed + 2;
                return true;
            }
            if (regex_unicode.isWordProperty(property.name)) {
                if (escape == 'P') {
                    regex_classes.addInverseEscape(&result.mask, 'W');
                    regex_classes.clearHighBytes(&result.mask);
                } else {
                    regex_classes.addEscape(&result.mask, 'w');
                    result.scalar_high = true;
                }
                index.* += property.consumed + 2;
                return true;
            }
        }
        if (options.ascii_unicode_properties) {
            const consumed = (if (options.ascii_space or options.ascii_posix)
                regex_classes.addUnicodePropertyTokenAsciiSpace(&result.mask, pattern[index.* + 2 ..], escape == 'P')
            else
                regex_classes.addUnicodePropertyToken(&result.mask, pattern[index.* + 2 ..], escape == 'P')) orelse return error.UnsupportedRegex;
            index.* += consumed + 2;
            return true;
        }
        if (regex_unicode.propertyName(pattern[index.* + 2 ..])) |property| {
            if (regex_unicode.scalarRangesForProperty(property.name)) |ranges| {
                if (escape == 'p') {
                    for (ranges) |range| try addScalarRange(result, range.lo, range.hi);
                } else {
                    var inverse = Result{};
                    for (ranges) |range| try addScalarRange(&inverse, range.lo, range.hi);
                    invert(&inverse.mask);
                    inverse.scalar_high = true;
                    inverse.exclude_codepoints = true;
                    try merge(result, inverse);
                }
                index.* += property.consumed + 2;
                return true;
            }
        }
        if (escape == 'P') result.scalar_high = true;
        const consumed = (if (options.ascii_space or options.ascii_posix)
            regex_classes.addUnicodePropertyTokenAsciiSpace(&result.mask, pattern[index.* + 2 ..], escape == 'P')
        else
            regex_classes.addUnicodePropertyToken(&result.mask, pattern[index.* + 2 ..], escape == 'P')) orelse return error.UnsupportedRegex;
        index.* += consumed + 2;
        return true;
    }
    return false;
}

fn addUnicodePosix(result: *Result, body: []const u8, inverse: bool) Error!bool {
    var included = Result{};
    if (std.ascii.eqlIgnoreCase(body, "alpha")) {
        try addRanges(&included, regex_unicode.scalarRangesForProperty("L").?);
    } else if (std.ascii.eqlIgnoreCase(body, "digit")) {
        try addRanges(&included, regex_unicode.scalarRangesForProperty("Nd").?);
    } else if (std.ascii.eqlIgnoreCase(body, "alnum")) {
        try addRanges(&included, regex_unicode.scalarRangesForProperty("L").?);
        try addRanges(&included, regex_unicode.scalarRangesForProperty("N").?);
    } else if (std.ascii.eqlIgnoreCase(body, "word")) {
        try addRanges(&included, regex_unicode.scalarRangesForProperty("L").?);
        try addRanges(&included, regex_unicode.scalarRangesForProperty("N").?);
        try addRanges(&included, regex_unicode.scalarRangesForProperty("M").?);
        try addRanges(&included, regex_unicode.scalarRangesForProperty("Pc").?);
    } else return false;
    if (!inverse) {
        try merge(result, included);
        return true;
    }
    invert(&included.mask);
    included.scalar_high = true;
    included.exclude_codepoints = true;
    try merge(result, included);
    return true;
}

fn addUnicodeEscapeClass(result: *Result, escape: u8, options: Options) Error!bool {
    switch (escape) {
        'd', 'D' => {
            if (options.ascii_digit or options.ascii_posix) return false;
            return try addUnicodePosix(result, "digit", escape == 'D');
        },
        'w', 'W' => {
            if (options.ascii_word or options.ascii_posix) return false;
            return try addUnicodePosix(result, "word", escape == 'W');
        },
        else => return false,
    }
}

fn addAsciiProperty(result: *Result, name_raw: []const u8, negated_raw: bool, options: Options) Error!bool {
    var name = name_raw;
    var negated = negated_raw;
    if (name.len != 0 and name[0] == '^') {
        name = name[1..];
        negated = !negated;
    }
    var mask = [_]u64{0} ** 4;
    const ascii = if (options.ascii_posix and regex_classes.addPosix(&mask, name))
        true
    else if (options.ascii_digit and (std.ascii.eqlIgnoreCase(name, "Digit") or std.ascii.eqlIgnoreCase(name, "Nd") or std.ascii.eqlIgnoreCase(name, "Decimal_Number"))) blk: {
        _ = regex_classes.addPosix(&mask, "digit");
        break :blk true;
    } else if (options.ascii_word and regex_unicode.isWordProperty(name)) blk: {
        _ = regex_classes.addPosix(&mask, "word");
        break :blk true;
    } else if (options.ascii_space and std.ascii.eqlIgnoreCase(name, "Space")) blk: {
        regex_classes.addAsciiSpace(&mask);
        break :blk true;
    } else false;
    if (!ascii) return false;
    if (negated) invert(&mask);
    for (&result.mask, mask) |*word, rhs| word.* |= rhs;
    return true;
}

fn addRanges(result: *Result, ranges: []const ScalarRange) Error!void {
    for (ranges) |range| try addScalarRange(result, range.lo, range.hi);
}

const ClassAtom = union(enum) {
    byte: u8,
    codepoint: regex_escape.CodepointEscape,
};

fn readClassAtom(pattern: []const u8, index: *usize) Error!ClassAtom {
    if (index.* >= pattern.len) return error.UnclosedClass;
    const escaped = pattern[index.*] == '\\';
    if (escaped) {
        index.* += 1;
        if (index.* >= pattern.len) return error.DanglingEscape;
        if (regex_escape.parseEscapedByte(pattern, index.*, pattern.len)) |parsed| {
            index.* = parsed.end;
            return .{ .byte = parsed.byte };
        }
        if (regex_escape.parseCodepoint(pattern, index.*, pattern.len)) |parsed| {
            index.* = parsed.end;
            return if (parsed.len == 1) .{ .byte = parsed.bytes[0] } else .{ .codepoint = parsed };
        }
        if (pattern[index.*] == '0') {
            const parsed = regex_escape.parseOctal(pattern, index.*, pattern.len) orelse return error.UnsupportedRegex;
            index.* = parsed.end;
            return .{ .byte = parsed.byte };
        }
        if (regex_escape.isNonLiteral(pattern[index.*])) return error.UnsupportedRegex;
    }
    if (!escaped and pattern[index.*] >= 0x80) {
        const len = std.unicode.utf8ByteSequenceLength(pattern[index.*]) catch return error.UnsupportedRegex;
        if (index.* + len > pattern.len) return error.UnsupportedRegex;
        var codepoint = regex_escape.CodepointEscape{ .len = @intCast(len), .end = index.* + len };
        @memcpy(codepoint.bytes[0..len], pattern[index.*..][0..len]);
        index.* += len;
        return .{ .codepoint = codepoint };
    }
    const byte = if (escaped) regex_escape.byte(pattern[index.*]) else pattern[index.*];
    index.* += 1;
    return .{ .byte = byte };
}

fn addRange(result: *Result, lo_atom: ClassAtom, hi_atom: ClassAtom) Error!void {
    const lo = scalarFromAtom(lo_atom) orelse return error.UnsupportedRegex;
    const hi = scalarFromAtom(hi_atom) orelse return error.UnsupportedRegex;
    if (hi < lo) return error.InvalidRange;
    if (lo <= 0x7f) {
        regex_classes.addRange(&result.mask, @intCast(lo), @intCast(@min(hi, 0x7f)));
    }
    if (hi > 0x7f) {
        if (result.range_count == max_ranges) return error.UnsupportedRegex;
        const index: usize = result.range_count;
        result.ranges[index] = .{ .lo = @intCast(@max(lo, 0x80)), .hi = @intCast(hi) };
        result.range_count += 1;
    }
}

fn scalarFromAtom(atom: ClassAtom) ?u21 {
    return switch (atom) {
        .byte => |value| value,
        .codepoint => |value| scalarFromCodepoint(value),
    };
}

fn scalarFromCodepoint(value: regex_escape.CodepointEscape) ?u21 {
    const len: usize = value.len;
    if (len == 0 or len > 4) return null;
    const scalar_len = std.unicode.utf8ByteSequenceLength(value.bytes[0]) catch return null;
    if (scalar_len != len) return null;
    return std.unicode.utf8Decode(value.bytes[0..len]) catch null;
}

fn singleScalarFromCodepoint(value: regex_escape.CodepointEscape) ?u21 {
    return scalarFromCodepoint(value);
}

fn addAtom(result: *Result, atom: ClassAtom) Error!void {
    switch (atom) {
        .byte => |value| regex_classes.addByte(&result.mask, value),
        .codepoint => |value| {
            if (singleScalarFromCodepoint(value)) |scalar| return addScalarRange(result, scalar, scalar);
            if (result.codepoint_count == max_codepoints) return error.UnsupportedRegex;
            const index: usize = result.codepoint_count;
            result.codepoints[index] = value;
            result.codepoint_count += 1;
        },
    }
}

fn classEnds(byte: u8, first: bool) bool {
    return byte == ']' and !first;
}

fn startsIntersection(pattern: []const u8, index: usize) bool {
    return index + 1 < pattern.len and pattern[index] == '&' and pattern[index + 1] == '&';
}

fn merge(result: *Result, other: Result) Error!void {
    if (result.exclude_codepoints or other.exclude_codepoints) return mergeWithExcluded(result, other);
    result.scalar_high = result.scalar_high or other.scalar_high;
    for (&result.mask, other.mask) |*word, rhs| word.* |= rhs;
    for (other.codepoints[0..other.codepoint_count]) |codepoint| try addAtom(result, .{ .codepoint = codepoint });
    for (other.ranges[0..other.range_count]) |range| {
        if (result.range_count == max_ranges) return error.UnsupportedRegex;
        const index: usize = result.range_count;
        result.ranges[index] = range;
        result.range_count += 1;
    }
}

fn mergeWithExcluded(result: *Result, other: Result) Error!void {
    if (result.exclude_codepoints and other.exclude_codepoints) {
        for (&result.mask, other.mask) |*word, rhs| word.* |= rhs;
        try intersectExcludedRanges(result, other);
        result.scalar_high = result.scalar_high or other.scalar_high;
        return;
    }
    if (other.exclude_codepoints) {
        const positive = result.*;
        const mask = positive.mask;
        result.* = other;
        for (&result.mask, mask) |*word, rhs| word.* |= rhs;
        try subtractIncludedScalars(result, positive);
        return;
    }
    for (&result.mask, other.mask) |*word, rhs| word.* |= rhs;
    result.scalar_high = result.scalar_high or other.scalar_high;
    try subtractIncludedScalars(result, other);
}

fn intersect(result: *Result, other: Result) Error!void {
    if (result.exclude_codepoints or other.exclude_codepoints) return error.UnsupportedRegex;
    const lhs = result.*;
    result.* = .{};
    for (&result.mask, lhs.mask, other.mask) |*word, left, right| word.* = left & right;
    result.scalar_high = lhs.scalar_high and other.scalar_high;

    for (lhs.codepoints[0..lhs.codepoint_count]) |codepoint| {
        const scalar = scalarFromCodepoint(codepoint) orelse return error.UnsupportedRegex;
        if (containsScalar(other, scalar)) try addAtom(result, .{ .codepoint = codepoint });
    }
    for (other.codepoints[0..other.codepoint_count]) |codepoint| {
        const scalar = scalarFromCodepoint(codepoint) orelse return error.UnsupportedRegex;
        if (containsScalar(lhs, scalar)) try addAtom(result, .{ .codepoint = codepoint });
    }
    for (lhs.ranges[0..lhs.range_count]) |left| {
        for (other.ranges[0..other.range_count]) |right| {
            try addScalarRange(result, @max(left.lo, right.lo), @min(left.hi, right.hi));
        }
        if (other.scalar_high) try addScalarRange(result, left.lo, left.hi);
    }
    for (other.ranges[0..other.range_count]) |range| {
        if (lhs.scalar_high) try addScalarRange(result, range.lo, range.hi);
    }
}

fn invert(mask: *[4]u64) void {
    for (mask) |*word| word.* = ~word.*;
}

fn posixIncludesScalarHigh(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "word") or
        std.ascii.eqlIgnoreCase(name, "graph") or
        std.ascii.eqlIgnoreCase(name, "print");
}

fn addScalarRange(result: *Result, lo: u21, hi: u21) Error!void {
    if (hi < lo) return;
    if (lo <= 0x7f) {
        regex_classes.addRange(&result.mask, @intCast(lo), @intCast(@min(hi, 0x7f)));
    }
    if (hi <= 0x7f) return;
    const merged = ScalarRange{ .lo = @intCast(@max(lo, 0x80)), .hi = @intCast(hi) };
    var i: usize = 0;
    while (i < result.range_count) : (i += 1) {
        if (!rangesTouch(result.ranges[i], merged)) continue;
        result.ranges[i] = .{ .lo = @min(result.ranges[i].lo, merged.lo), .hi = @max(result.ranges[i].hi, merged.hi) };
        var j: usize = 0;
        while (j < result.range_count) {
            if (j == i or !rangesTouch(result.ranges[i], result.ranges[j])) {
                j += 1;
                continue;
            }
            result.ranges[i] = .{ .lo = @min(result.ranges[i].lo, result.ranges[j].lo), .hi = @max(result.ranges[i].hi, result.ranges[j].hi) };
            result.range_count -= 1;
            result.ranges[j] = result.ranges[result.range_count];
            if (j < i) i -= 1;
        }
        return;
    }
    if (result.range_count == max_ranges) return error.UnsupportedRegex;
    const index: usize = result.range_count;
    result.ranges[index] = merged;
    result.range_count += 1;
}

fn rangesTouch(a: ScalarRange, b: ScalarRange) bool {
    return a.lo <= b.hi + 1 and b.lo <= a.hi + 1;
}

fn subtractIncludedScalars(result: *Result, included: Result) Error!void {
    for (included.ranges[0..included.range_count]) |range| try subtractRange(result, range.lo, range.hi);
    for (included.codepoints[0..included.codepoint_count]) |codepoint| {
        if (scalarFromCodepoint(codepoint)) |scalar| try subtractRange(result, scalar, scalar);
    }
}

fn subtractRange(result: *Result, lo: u21, hi: u21) Error!void {
    var i: usize = 0;
    while (i < result.range_count) {
        const range = result.ranges[i];
        if (hi < range.lo or lo > range.hi) {
            i += 1;
            continue;
        }
        if (lo <= range.lo and hi >= range.hi) {
            result.range_count -= 1;
            result.ranges[i] = result.ranges[result.range_count];
            continue;
        }
        if (lo <= range.lo) {
            result.ranges[i].lo = hi + 1;
            i += 1;
            continue;
        }
        if (hi >= range.hi) {
            result.ranges[i].hi = lo - 1;
            i += 1;
            continue;
        }
        if (result.range_count == max_ranges) return error.UnsupportedRegex;
        result.ranges[i].hi = lo - 1;
        result.ranges[result.range_count] = .{ .lo = hi + 1, .hi = range.hi };
        result.range_count += 1;
        i += 1;
    }
}

fn intersectExcludedRanges(result: *Result, other: Result) Error!void {
    var out = Result{};
    out.mask = result.mask;
    out.scalar_high = result.scalar_high or other.scalar_high;
    out.negated = result.negated;
    out.exclude_codepoints = true;
    for (result.ranges[0..result.range_count]) |left| {
        for (other.ranges[0..other.range_count]) |right| {
            try addScalarRange(&out, @max(left.lo, right.lo), @min(left.hi, right.hi));
        }
    }
    result.* = out;
}

fn containsScalar(result: Result, scalar: u21) bool {
    if (scalar <= 0x7f) return regex_classes.contains(result.mask, @intCast(scalar));
    for (result.ranges[0..result.range_count]) |range| {
        if (scalar >= range.lo and scalar <= range.hi) return true;
    }
    for (result.codepoints[0..result.codepoint_count]) |codepoint| {
        if (scalarFromCodepoint(codepoint) == scalar) return true;
    }
    return result.scalar_high;
}

test "regex class parser handles Oniguruma intersections" {
    const parsed = try parse("[a-w&&[^c-g]z]", 0);
    const nested = try parse("[[a-c][x-z]]", 0);
    const literal_open = try parse("[[]", 0);
    const scalar = try parse("[\\x{200C}_]", 0);
    const negated_scalar = try parse("[^\\x{200C}a]", 0);
    const inverse_escape = try parse("[\\D]", 0);
    const word = try parse("[[:word:]]", 0);
    const inverse_word = try parse("[[:^word:]]", 0);
    const outer_not_word = try parse("[^[:word:]]", 0);
    const word_property = try parse("[\\p{Word}]", 0);
    const inverse_word_property = try parse("[\\P{Word}]", 0);
    const ascii_inverse_word_escape = try parseWithOptions("[\\W]", 0, .{ .ascii_word = true });
    const ascii_word_escape = try parseWithOptions("[\\w]", 0, .{ .ascii_word = true });
    const folded_ascii = try parse("[k]", 0);
    const inverse_folded_ascii = try parse("[^k]", 0);

    try std.testing.expect(regex_classes.contains(parsed.mask, 'a'));
    try std.testing.expect(regex_classes.contains(parsed.mask, 'b'));
    try std.testing.expect(!regex_classes.contains(parsed.mask, 'c'));
    try std.testing.expect(!regex_classes.contains(parsed.mask, 'g'));
    try std.testing.expect(regex_classes.contains(parsed.mask, 'h'));
    try std.testing.expect(regex_classes.contains(parsed.mask, 'w'));
    try std.testing.expect(!regex_classes.contains(parsed.mask, 'z'));
    try std.testing.expect(regex_classes.contains(nested.mask, 'a'));
    try std.testing.expect(regex_classes.contains(nested.mask, 'c'));
    try std.testing.expect(!regex_classes.contains(nested.mask, 'm'));
    try std.testing.expect(regex_classes.contains(nested.mask, 'x'));
    try std.testing.expect(regex_classes.contains(nested.mask, 'z'));
    try std.testing.expect(regex_classes.contains(literal_open.mask, '['));
    try std.testing.expect(regex_classes.contains(scalar.mask, '_'));
    try std.testing.expectEqual(@as(u16, 1), scalar.range_count);
    try std.testing.expectEqual(@as(?usize, 3), matchAt(scalar, "\xe2\x80\x8c", 0, false));
    try std.testing.expect(negated_scalar.exclude_codepoints);
    try std.testing.expectEqual(@as(?usize, null), matchAt(negated_scalar, "\xe2\x80\x8c", 0, false));
    try std.testing.expectEqual(@as(?usize, null), matchAt(negated_scalar, "a", 0, false));
    try std.testing.expectEqual(@as(?usize, 3), matchAt(negated_scalar, "\xe2\x80\x8d", 0, false));
    try std.testing.expectEqual(@as(?usize, 2), matchAt(inverse_escape, "é", 0, false));
    try std.testing.expectEqual(@as(?usize, 2), matchAt(word, "é", 0, false));
    try std.testing.expectEqual(@as(?usize, null), matchAt(inverse_word, "é", 0, false));
    try std.testing.expectEqual(@as(?usize, null), matchAt(outer_not_word, "é", 0, false));
    try std.testing.expectEqual(@as(?usize, 1), matchAt(inverse_word, "!", 0, false));
    try std.testing.expectEqual(@as(?usize, 1), matchAt(outer_not_word, "!", 0, false));
    try std.testing.expectEqual(@as(?usize, 2), matchAt(word_property, "é", 0, false));
    try std.testing.expectEqual(@as(?usize, null), matchAt(inverse_word_property, "é", 0, false));
    try std.testing.expectEqual(@as(?usize, 1), matchAt(inverse_word_property, "!", 0, false));
    try std.testing.expectEqual(@as(?usize, 2), matchAt(ascii_inverse_word_escape, "é", 0, false));
    try std.testing.expectEqual(@as(?usize, null), matchAt(ascii_word_escape, "é", 0, false));
    try std.testing.expectEqual(@as(?usize, 3), matchAt(folded_ascii, "K", 0, true));
    try std.testing.expectEqual(@as(?usize, null), matchAt(inverse_folded_ascii, "K", 0, true));
    const scalar_intersection = try parse("[[^a]&&[\\x{80}-\\x{82}]]", 0);
    try std.testing.expectEqual(@as(?usize, 2), matchAt(scalar_intersection, "\xc2\x81", 0, false));
    try std.testing.expectEqual(@as(?usize, null), matchAt(scalar_intersection, "a", 0, false));
    try std.testing.expectEqual(@as(?usize, null), matchAt(scalar_intersection, "\xc2\x83", 0, false));
    const ascii_or_not_scalar = try parse("[A-Z[^\\x{0}-\\x{127}]]", 0);
    try std.testing.expectEqual(@as(?usize, 1), matchAt(ascii_or_not_scalar, "A", 0, false));
    try std.testing.expectEqual(@as(?usize, null), matchAt(ascii_or_not_scalar, "a", 0, false));
    try std.testing.expectEqual(@as(?usize, 2), matchAt(ascii_or_not_scalar, "ƀ", 0, false));
}

test "regex class parser handles Unicode scalar ranges" {
    const raw_range = try parse("[À-Ö_]", 0);
    const escaped_range = try parse("[\\x{80}-\\x{9F}]", 0);
    const negated_many = try parse("[^\\x7F-\\x{9F}﷐-﷯\\x{4FFFE}\\x{10FFFF}]", 0);
    const sequence = try parse("[\\x{41 42}]", 0);
    const greek = try parse("[#$%>❯➜\\p{Greek}]", 0);
    const format = try parse("[\\p{Cf}]", 0);

    try std.testing.expectEqual(@as(u8, 1), raw_range.range_count);
    try std.testing.expectEqual(@as(?usize, 2), matchAt(raw_range, "À", 0, false));
    try std.testing.expectEqual(@as(?usize, 2), matchAt(raw_range, "Ö", 0, false));
    try std.testing.expectEqual(@as(?usize, 1), matchAt(raw_range, "_", 0, false));
    try std.testing.expectEqual(@as(?usize, null), matchAt(raw_range, "×", 0, false));

    try std.testing.expectEqual(@as(?usize, 2), matchAt(escaped_range, "\xc2\x85", 0, false));
    try std.testing.expectEqual(@as(?usize, null), matchAt(negated_many, "\xc2\x85", 0, false));
    try std.testing.expectEqual(@as(?usize, null), matchAt(negated_many, "﷐", 0, false));
    try std.testing.expectEqual(@as(?usize, 1), matchAt(negated_many, "a", 0, false));
    try std.testing.expectEqual(@as(?usize, 2), matchAt(sequence, "AB", 0, false));
    try std.testing.expectEqual(@as(?usize, 2), matchAt(greek, "α", 0, false));
    try std.testing.expectEqual(@as(?usize, 3), matchAt(greek, "❯", 0, false));
    try std.testing.expectEqual(@as(?usize, null), matchAt(greek, "a", 0, false));
    try std.testing.expectEqual(@as(?usize, 3), matchAt(format, "\xe2\x80\x8c", 0, false));
    try std.testing.expectEqual(@as(?usize, null), matchAt(format, "a", 0, false));
}

test "regex class parser handles large Unicode literal classes" {
    var pattern: [1 + 70 * 2 + 1]u8 = undefined;
    pattern[0] = '[';
    var index: usize = 1;
    var n: usize = 0;
    while (n < 70) : (n += 1) {
        pattern[index] = 0xc3;
        pattern[index + 1] = 0xa9;
        index += 2;
    }
    pattern[index] = ']';

    const parsed = try parse(pattern[0 .. index + 1], 0);
    try std.testing.expectEqual(@as(u16, 1), parsed.range_count);
    try std.testing.expectEqual(@as(?usize, 2), matchAt(parsed, "é", 0, false));
}

test "regex class parser unions scalar exclusions" {
    const explicit = try parse("[é[^é]]", 0);
    const two_exclusions = try parse("[[^é][^ê]]", 0);

    try std.testing.expectEqual(@as(?usize, 2), matchAt(explicit, "é", 0, false));
    try std.testing.expectEqual(@as(?usize, 2), matchAt(explicit, "ê", 0, false));
    try std.testing.expectEqual(@as(?usize, 2), matchAt(two_exclusions, "é", 0, false));
    try std.testing.expectEqual(@as(?usize, 2), matchAt(two_exclusions, "ê", 0, false));
}
