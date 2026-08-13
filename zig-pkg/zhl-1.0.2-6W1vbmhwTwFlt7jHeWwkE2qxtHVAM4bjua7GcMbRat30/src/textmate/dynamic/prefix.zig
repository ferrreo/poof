const std = @import("std");

const max_bytes = 32;

pub const LookbehindAlt = struct {
    slot: u8,
    prefix_len: u8,
    prefix: [max_bytes]u8 = [_]u8{0} ** max_bytes,
    suffix_len: u8,
    suffix: [max_bytes]u8 = [_]u8{0} ** max_bytes,
    literal_alt_len: u8,
    literal_alt: [max_bytes]u8 = [_]u8{0} ** max_bytes,
};

pub fn parseLookbehindAlt(pattern: []const u8) ?LookbehindAlt {
    const source = "/>|(?<=</>)|(?<=</\\";
    if (!std.mem.startsWith(u8, pattern, source) or pattern.len != source.len + 3) return null;
    const slot = pattern[source.len];
    if (slot < '1' or slot > '9' or !std.mem.eql(u8, pattern[source.len + 1 ..], ">)")) return null;
    var out = LookbehindAlt{ .slot = slot - '0', .prefix_len = 2, .suffix_len = 1, .literal_alt_len = 2 };
    out.literal_alt[0] = '/';
    out.literal_alt[1] = '>';
    out.prefix[0] = '<';
    out.prefix[1] = '/';
    out.suffix[0] = '>';
    return out;
}

pub fn matchLookbehindAlt(prefix: []const u8, suffix: []const u8, marker: []const u8, line: []const u8, index: usize) bool {
    return endsWithParts(line[0..index], prefix, "", suffix) or endsWithParts(line[0..index], prefix, marker, suffix);
}

pub fn matchTagOnLine(marker: []const u8, line: []const u8, index: usize) ?usize {
    if (std.mem.startsWith(u8, line[index..], "</")) {
        const start = index + 2;
        const end = start + marker.len;
        if (end < line.len and std.ascii.eqlIgnoreCase(line[start..end], marker) and line[end] == '>') return null;
    }
    if (std.mem.startsWith(u8, line[index..], "<")) {
        const start = index + 1;
        const end = start + marker.len;
        if (end < line.len and std.ascii.eqlIgnoreCase(line[start..end], marker) and line[end] == '>') return null;
    }
    return index;
}

fn endsWithParts(line: []const u8, prefix: []const u8, marker: []const u8, suffix: []const u8) bool {
    const len = prefix.len + marker.len + suffix.len;
    if (line.len < len) return false;
    const tail = line[line.len - len ..];
    return std.mem.startsWith(u8, tail, prefix) and std.mem.startsWith(u8, tail[prefix.len..], marker) and std.mem.endsWith(u8, tail, suffix);
}
