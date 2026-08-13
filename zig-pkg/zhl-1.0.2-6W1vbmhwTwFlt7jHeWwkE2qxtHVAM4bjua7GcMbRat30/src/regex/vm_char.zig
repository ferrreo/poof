const std = @import("std");
const regex_class_parse = @import("class_parse.zig");
const regex_escape = @import("escape.zig");
const regex_match = @import("match.zig");
const regex_unicode = @import("unicode.zig");
const vm = @import("vm_types.zig");

pub fn matchUnicodeClass(pattern: []const u8, index: usize, end: usize, text: []const u8, pos: usize, negated: bool, flags: vm.Flags) ?usize {
    return regex_unicode.matchPropertyEscape(pattern[index + 1 .. end], text, pos, negated, .{
        .ascii_digit = flags.ascii_digit,
        .ascii_word = flags.ascii_word,
        .ascii_space = flags.ascii_space,
        .ascii_posix = flags.ascii_posix,
    });
}

pub fn matchClass(class: []const u8, text: []const u8, pos: usize, flags: vm.Flags) ?usize {
    if (pos >= text.len or class.len < 2) return null;
    const parsed = regex_class_parse.parseWithOptions(class, 0, .{
        .ascii_digit = flags.ascii_digit,
        .ascii_word = flags.ascii_word,
        .ascii_space = flags.ascii_space,
        .ascii_posix = flags.ascii_posix,
    }) catch return null;
    return regex_class_parse.matchAt(parsed, text, pos, flags.ignore_case);
}

pub fn digitAt(text: []const u8, pos: usize, flags: vm.Flags) ?usize {
    if (pos >= text.len) return null;
    if (std.ascii.isDigit(text[pos])) return pos + 1;
    if (flags.ascii_digit or flags.ascii_posix) return null;
    const ranges = regex_unicode.scalarRangesForProperty("Nd") orelse return null;
    return if (regex_unicode.matchScalarRanges(text, pos, ranges) orelse false) regex_unicode.scalarEnd(text, pos) else null;
}

pub fn wordAt(text: []const u8, pos: usize, flags: vm.Flags) ?usize {
    if (pos >= text.len) return null;
    if (regex_match.wordByte(text[pos])) return pos + 1;
    if (flags.ascii_word or flags.ascii_posix) return null;
    return regex_match.wordAt(text, pos);
}

pub fn wordBoundary(text: []const u8, pos: usize, flags: vm.Flags) bool {
    const prev_word = wordBefore(text, pos, flags);
    const next_word = wordAt(text, pos, flags) != null;
    return prev_word != next_word;
}

pub fn wordStart(text: []const u8, pos: usize, flags: vm.Flags) bool {
    return wordAt(text, pos, flags) != null and !wordBefore(text, pos, flags);
}

pub fn wordEnd(text: []const u8, pos: usize, flags: vm.Flags) bool {
    return wordBefore(text, pos, flags) and wordAt(text, pos, flags) == null;
}

fn wordBefore(text: []const u8, pos: usize, flags: vm.Flags) bool {
    if (pos == 0 or pos > text.len) return false;
    if (text[pos - 1] < 0x80) return regex_match.wordByte(text[pos - 1]);
    if (flags.ascii_word or flags.ascii_posix) return false;
    var start = pos - 1;
    while (start > 0 and (text[start] & 0xc0) == 0x80) : (start -= 1) {}
    return wordAt(text, start, flags) == pos;
}

pub fn spaceAt(text: []const u8, pos: usize, flags: vm.Flags) ?usize {
    return if (flags.ascii_space or flags.ascii_posix) regex_match.asciiSpaceAt(text, pos) else regex_match.spaceAt(text, pos);
}

pub fn matchEscapedByte(parsed: ?regex_escape.HexEscape, text: []const u8, pos: usize, flags: vm.Flags) ?usize {
    const byte = (parsed orelse return null).byte;
    return if (pos < text.len and bytesEqual(text[pos], byte, flags.ignore_case)) pos + 1 else null;
}

pub fn bytesEqual(a: u8, b: u8, ignore_case: bool) bool {
    return a == b or (ignore_case and regex_escape.asciiLower(a) == regex_escape.asciiLower(b));
}
