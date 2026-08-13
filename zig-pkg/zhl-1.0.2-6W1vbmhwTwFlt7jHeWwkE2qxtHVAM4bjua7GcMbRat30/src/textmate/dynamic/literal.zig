const std = @import("std");
const regex_escape = @import("../../regex/escape.zig");

pub fn dynamicSuffixByte(pattern: []const u8, index: *usize) ?u8 {
    if (literalByte(pattern, index)) |byte| return byte;
    if (index.* >= pattern.len) return null;
    const byte = pattern[index.*];
    if (byte != '}' and byte != ']') return null;
    index.* += 1;
    return byte;
}

pub fn literalByte(pattern: []const u8, index: *usize) ?u8 {
    if (index.* >= pattern.len) return null;
    var byte = pattern[index.*];
    if (byte == '\\') {
        index.* += 1;
        if (index.* >= pattern.len or std.ascii.isAlphanumeric(pattern[index.*])) return null;
        byte = regex_escape.byte(pattern[index.*]);
    } else if (std.mem.indexOfScalar(u8, ".^$*+?[]()|{}", byte) != null) return null;
    index.* += 1;
    return byte;
}

pub fn appendFixed(comptime len_type: type, buf: []u8, len: *len_type, byte: u8) ?void {
    if (len.* == buf.len) return null;
    buf[len.*] = byte;
    len.* += 1;
}
