const std = @import("std");
const session = @import("session.zig");

pub const Pair = struct {
    state: session.Token,
    cookie: session.Token,

    pub fn generate(io: std.Io) Pair {
        return .{
            .state = session.Token.generate(io),
            .cookie = session.Token.generate(io),
        };
    }

    pub fn fromRaw(state_raw: [32]u8, cookie_raw: [32]u8) Pair {
        return .{
            .state = session.Token.fromRaw(state_raw),
            .cookie = session.Token.fromRaw(cookie_raw),
        };
    }

    pub fn clear(self: *Pair) void {
        self.state.clear();
        self.cookie.clear();
    }
};

pub fn validReturnTarget(value: []const u8) bool {
    if (value.len == 0 or value.len > 512 or value[0] != '/') return false;
    if (value.len > 1 and value[1] == '/') return false;
    if (std.mem.indexOfScalar(u8, value, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, value, '\r') != null or
        std.mem.indexOfScalar(u8, value, '\n') != null)
    {
        return false;
    }
    const path = if (std.mem.indexOfScalar(u8, value, '?')) |index|
        value[0..index]
    else
        value;
    for (path) |byte| {
        if (byte < 0x21 or byte > 0x7e or byte == '#') return false;
    }
    return true;
}

pub fn matches(
    expected_state_hash: [32]u8,
    expected_cookie_hash: [32]u8,
    state_value: []const u8,
    cookie_value: []const u8,
) bool {
    var state = session.Token.parse(state_value) catch return false;
    defer state.clear();
    var cookie = session.Token.parse(cookie_value) catch return false;
    defer cookie.clear();
    return std.crypto.timing_safe.eql([32]u8, expected_state_hash, state.hash()) and
        std.crypto.timing_safe.eql([32]u8, expected_cookie_hash, cookie.hash());
}

test "OAuth state binds the browser cookie and rejects open redirects" {
    var pair = Pair.fromRaw([_]u8{0x12} ** 32, [_]u8{0x34} ** 32);
    defer pair.clear();
    try std.testing.expect(matches(
        pair.state.hash(),
        pair.cookie.hash(),
        pair.state.slice(),
        pair.cookie.slice(),
    ));
    try std.testing.expect(!matches(
        pair.state.hash(),
        pair.cookie.hash(),
        pair.cookie.slice(),
        pair.state.slice(),
    ));
    try std.testing.expect(validReturnTarget("/issues/42?from=login"));
    try std.testing.expect(!validReturnTarget("//evil.example"));
    try std.testing.expect(!validReturnTarget("/\\evil.example"));
}
