const engine = @import("engine.zig");

pub fn storeLiteral(state: anytype, bytes: []const u8) engine.HighlightError!@TypeOf(state) {
    var out = state;
    if (bytes.len > out.dynamic_captures.len) return error.DynamicCaptureOverflow;
    @memcpy(out.dynamic_captures[0..bytes.len], bytes);
    out.dynamic_capture_len = @intCast(bytes.len);
    out.fingerprint = fingerprint(bytes);
    return out;
}

pub fn matchLiteral(state: anytype, line: []const u8, index: usize) ?usize {
    const len: usize = state.dynamic_capture_len;
    if (len == 0 or index + len > line.len) return null;
    if (!equal(state.dynamic_captures[0..len], line[index .. index + len])) return null;
    return index + len;
}

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn fingerprint(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

test "dynamic literal end uses state storage" {
    const std = @import("std");
    const S = engine.State(2, 16);
    const state = try storeLiteral(S.initial(), "EOF");

    try std.testing.expectEqual(@as(?usize, 5), matchLiteral(state, "<<EOF", 2));
    try std.testing.expect(matchLiteral(state, "<<END", 2) == null);
}

test "dynamic literal end reports overflow" {
    const std = @import("std");
    const S = engine.State(2, 2);
    try std.testing.expectError(error.DynamicCaptureOverflow, storeLiteral(S.initial(), "EOF"));
}
