const std = @import("std");
const regex_escape = @import("escape.zig");
const regex_types = @import("types.zig");

const Atom = regex_types.Atom;
const CompileError = error{ DanglingEscape, UnsupportedRegex };
const max_alt_count = regex_types.max_alt_count;
const max_alt_bytes = regex_types.max_alt_bytes;
const max_captures = regex_types.max_captures;

pub fn parseLiteral(pattern: []const u8, index: *usize, capture_count: *u8) CompileError!Atom {
    index.* += 1;
    return parseBody(pattern, index, try nextCaptureAtom(capture_count));
}

pub fn parseNamedLiteral(pattern: []const u8, index: *usize, capture_count: *u8) CompileError!Atom {
    index.* += 3;
    while (index.* < pattern.len and pattern[index.*] != '>') : (index.* += 1) {}
    if (index.* >= pattern.len or pattern[index.*] != '>') return error.UnsupportedRegex;
    index.* += 1;
    return parseBody(pattern, index, try nextCaptureAtom(capture_count));
}

pub fn parseNonCapturing(pattern: []const u8, index: *usize) CompileError!Atom {
    if (pattern[index.* + 2] == '>') {
        const i = index.* + 3;
        if (i + 3 < pattern.len and pattern[i] == '\\' and pattern[i + 1] == 's' and (pattern[i + 2] == '*' or pattern[i + 2] == '+') and pattern[i + 3] == ')') {
            index.* = i + 4;
            return .{ .kind = .space, .quantifier = if (pattern[i + 2] == '*') .zero_or_more else .one_or_more };
        }
    }
    index.* += 3;
    return parseBody(pattern, index, .{ .kind = .literal_alt, .alt_count = 1 });
}

pub fn parseInlineFlag(pattern: []const u8, index: *usize) CompileError!Atom {
    index.* += 2;
    var ignore_case = false;
    var extended = false;
    var negated = false;
    while (index.* < pattern.len and pattern[index.*] != ':') {
        const flag = pattern[index.*];
        const next = regex_escape.flagTokenEnd(pattern, index.*, pattern.len) orelse return error.UnsupportedRegex;
        if (flag == '-') {
            negated = true;
        } else if (flag == 'i') {
            ignore_case = !negated;
        } else if (flag == 'x') {
            extended = !negated;
        }
        index.* = next;
    }
    if (index.* >= pattern.len or pattern[index.*] != ':') return error.UnsupportedRegex;
    index.* += 1;
    return parseBody(pattern, index, .{ .kind = .literal_alt, .alt_count = 1, .ignore_case = ignore_case, .extended = extended });
}

pub fn isNamedCaptureStart(pattern: []const u8, index: usize) bool {
    return index + 3 < pattern.len and pattern[index + 2] == '<' and
        pattern[index + 3] != '=' and pattern[index + 3] != '!';
}

pub fn isNonCapturingStart(pattern: []const u8, index: usize) bool {
    return index + 2 < pattern.len and (pattern[index + 2] == ':' or pattern[index + 2] == '>');
}

pub fn isInlineFlagStart(pattern: []const u8, index: usize) bool {
    return regex_escape.flagRunEnd(pattern, index + 2, pattern.len, ':') != null;
}

pub fn match(atom: Atom, text: []const u8, pos: usize) ?usize {
    var alt_i: usize = 0;
    while (alt_i < atom.alt_count) : (alt_i += 1) {
        const alt = atom.alt_bytes[alt_i][0..atom.alt_lens[alt_i]];
        if (startsWith(text[pos..], alt, atom.ignore_case)) return pos + alt.len;
    }
    return null;
}

fn nextCaptureAtom(capture_count: *u8) CompileError!Atom {
    if (capture_count.* + 1 == max_captures) return error.UnsupportedRegex;
    capture_count.* += 1;
    return .{ .kind = .capture_alt, .alt_count = 1, .capture_slot = capture_count.* };
}

fn parseBody(pattern: []const u8, index: *usize, initial: Atom) CompileError!Atom {
    var atom = initial;
    var alt_i: usize = 0;
    var len: u8 = 0;
    while (index.* < pattern.len) {
        if (atom.extended and std.ascii.isWhitespace(pattern[index.*])) {
            index.* += 1;
            continue;
        }
        if (pattern[index.*] == ')') {
            if (len == 0) return error.UnsupportedRegex;
            atom.alt_lens[alt_i] = len;
            index.* += 1;
            return atom;
        }
        if (pattern[index.*] == '|') {
            if (len == 0 or atom.alt_count == max_alt_count) return error.UnsupportedRegex;
            atom.alt_lens[alt_i] = len;
            atom.alt_count += 1;
            alt_i += 1;
            len = 0;
            index.* += 1;
            continue;
        }
        const byte = try readByte(pattern, index);
        if (len == max_alt_bytes) return error.UnsupportedRegex;
        atom.alt_bytes[alt_i][len] = byte;
        len += 1;
    }
    return error.UnsupportedRegex;
}

fn readByte(pattern: []const u8, index: *usize) CompileError!u8 {
    const escaped = pattern[index.*] == '\\';
    if (escaped) {
        index.* += 1;
        if (index.* >= pattern.len) return error.DanglingEscape;
        if (regex_escape.parseEscapedByte(pattern, index.*, pattern.len)) |parsed| {
            index.* = parsed.end;
            return parsed.byte;
        }
        if (regex_escape.isClass(pattern[index.*]) or regex_escape.isNonLiteral(pattern[index.*]) or
            pattern[index.*] == 'b' or pattern[index.*] == 'B' or pattern[index.*] == 'p' or pattern[index.*] == 'P')
            return error.UnsupportedRegex;
        if (pattern[index.*] == '0') return error.UnsupportedRegex;
    } else if (regex_escape.isMeta(pattern[index.*]) and pattern[index.*] != ')') {
        return error.UnsupportedRegex;
    }
    const byte = if (escaped) regex_escape.byte(pattern[index.*]) else pattern[index.*];
    index.* += 1;
    return byte;
}

fn startsWith(text: []const u8, alt: []const u8, ignore_case: bool) bool {
    if (text.len < alt.len) return false;
    if (!ignore_case) return std.mem.startsWith(u8, text, alt);
    for (alt, 0..) |byte, i| if (regex_escape.asciiLower(text[i]) != regex_escape.asciiLower(byte)) return false;
    return true;
}
