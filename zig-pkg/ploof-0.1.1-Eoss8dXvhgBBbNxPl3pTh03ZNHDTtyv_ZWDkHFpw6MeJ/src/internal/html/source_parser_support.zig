const types = @import("source_types.zig");

pub fn startsWith(bytes: []const u8, prefix: []const u8) bool {
    return startsWithAt(bytes, 0, prefix);
}

pub fn startsWithAt(bytes: []const u8, index: usize, prefix: []const u8) bool {
    if (index > bytes.len or prefix.len > bytes.len - index) return false;
    return equal(bytes[index .. index + prefix.len], prefix);
}

pub fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

pub fn isAsciiLetter(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
}

pub fn makeRange(start: usize, end: usize) types.SourceRange {
    return .{ .start = @intCast(start), .end = @intCast(end) };
}
