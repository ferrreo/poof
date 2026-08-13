const std = @import("std");
const regex_escape = @import("../../regex/escape.zig");

const max_bytes = 32;

pub const Lookahead = struct {
    slot: u8,
    required: u8,
    len: u8 = 0,
    bytes: [max_bytes]u8 = [_]u8{0} ** max_bytes,
};

pub fn parseStar(pattern: []const u8, out: anytype) ?usize {
    if (pattern.len < 3 or pattern[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, pattern, ']') orelse return null;
    if (close + 1 >= pattern.len or pattern[close + 1] != '*') return null;
    var index: usize = 1;
    while (index < close) {
        var byte = pattern[index];
        if (byte == '\\') {
            index += 1;
            if (index >= close) return null;
            byte = regex_escape.byte(pattern[index]);
        }
        append(&out.class_tail, &out.class_tail_len, byte) orelse return null;
        index += 1;
    }
    return close + 2;
}

pub fn parseLookahead(pattern: []const u8) ?Lookahead {
    if (pattern.len < 12 or pattern[0] != '\\' or pattern[1] < '1' or pattern[1] > '9') return null;
    const prefix = "(?=[";
    if (!std.mem.startsWith(u8, pattern[2..], prefix)) return null;
    const class_start = 2 + prefix.len;
    const close = std.mem.indexOfScalarPos(u8, pattern, class_start, ']') orelse return null;
    if (close == class_start or close + 3 >= pattern.len or pattern[close + 1] != '*') return null;
    const required = pattern[close + 2];
    if (regex_escape.isMeta(required) or pattern[close + 3] != '[') return null;
    const class = pattern[class_start..close];
    const second_start = close + 4;
    if (second_start + class.len > pattern.len or !std.mem.eql(u8, pattern[second_start..][0..class.len], class)) return null;
    if (!std.mem.eql(u8, pattern[second_start + class.len ..], "]*)\\b")) return null;
    var out = Lookahead{ .slot = pattern[1] - '0', .required = required };
    for (class) |byte| {
        if (regex_escape.isMeta(byte)) return null;
        append(&out.bytes, &out.len, byte) orelse return null;
    }
    return out;
}

pub fn contains(bytes: []const u8, byte: u8) bool {
    for (bytes) |item| if (item == byte) return true;
    return false;
}

pub fn lookaheadContains(bytes: []const u8, required: u8, line: []const u8) bool {
    var index: usize = 0;
    while (index < line.len and contains(bytes, line[index])) : (index += 1) {}
    if (index >= line.len or line[index] != required) return false;
    index += 1;
    while (index < line.len and contains(bytes, line[index])) : (index += 1) {}
    return true;
}

fn append(buf: *[max_bytes]u8, len: *u8, byte: u8) ?void {
    if (len.* == buf.len) return null;
    buf[len.*] = byte;
    len.* += 1;
}
