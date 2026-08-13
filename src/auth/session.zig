const std = @import("std");
const cookie = @import("cookie.zig");

pub const raw_bytes = 32;
pub const encoded_bytes = 43;
pub const production_cookie_name = "__Host-poof-session";
pub const development_cookie_name = "poof_session";

pub const Token = struct {
    encoded: [encoded_bytes]u8,

    pub fn generate(io: std.Io) Token {
        var raw: [raw_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &raw);
        std.Io.random(io, &raw);
        return fromRaw(raw);
    }

    pub fn fromRaw(raw: [raw_bytes]u8) Token {
        var encoded: [encoded_bytes]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &raw);
        return .{ .encoded = encoded };
    }

    pub fn parse(value: []const u8) error{InvalidToken}!Token {
        if (value.len != encoded_bytes) return error.InvalidToken;
        var raw: [raw_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &raw);
        std.base64.url_safe_no_pad.Decoder.decode(&raw, value) catch
            return error.InvalidToken;
        const canonical = fromRaw(raw);
        if (!std.crypto.timing_safe.eql([encoded_bytes]u8, canonical.encoded, value[0..encoded_bytes].*)) {
            return error.InvalidToken;
        }
        return canonical;
    }

    pub fn slice(self: *const Token) []const u8 {
        return &self.encoded;
    }

    pub fn hash(self: *const Token) [32]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.slice(), &digest, .{});
        return digest;
    }

    pub fn clear(self: *Token) void {
        std.crypto.secureZero(u8, &self.encoded);
    }
};

pub fn cookieName(production: bool) []const u8 {
    return if (production) production_cookie_name else development_cookie_name;
}

pub fn writeCookie(
    output: []u8,
    token: *const Token,
    production: bool,
    ttl_days: u16,
) cookie.Error![]const u8 {
    const seconds = @as(u32, ttl_days) * 24 * 60 * 60;
    return cookie.write(output, cookieName(production), token.slice(), .{
        .secure = production,
        .max_age_seconds = seconds,
    });
}

pub fn clearCookie(output: []u8, production: bool) cookie.Error![]const u8 {
    return cookie.write(output, cookieName(production), "", .{
        .secure = production,
        .max_age_seconds = 0,
    });
}

test "session tokens round trip canonically and hash deterministically" {
    const raw = [_]u8{0x42} ** raw_bytes;
    var token = Token.fromRaw(raw);
    defer token.clear();
    const parsed = try Token.parse(token.slice());
    try std.testing.expectEqualSlices(u8, token.slice(), parsed.slice());
    try std.testing.expectEqual(token.hash(), parsed.hash());
    try std.testing.expectError(error.InvalidToken, Token.parse("short"));
}

test "development cookies are deliberately not Host-prefixed" {
    var token = Token.fromRaw([_]u8{0x11} ** raw_bytes);
    defer token.clear();
    var storage: [256]u8 = undefined;
    const header = try writeCookie(&storage, &token, false, 30);
    try std.testing.expect(std.mem.startsWith(u8, header, "poof_session="));
    try std.testing.expect(std.mem.indexOf(u8, header, "; Secure") == null);
}
