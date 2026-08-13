const std = @import("std");

pub const marker = "poof_";
pub const lookup_random_bytes = 9;
pub const secret_random_bytes = 32;
pub const lookup_encoded_bytes = 12;
pub const secret_encoded_bytes = 43;
pub const lookup_bytes = marker.len + lookup_encoded_bytes;
pub const token_bytes = lookup_bytes + 1 + secret_encoded_bytes;

pub const Generated = struct {
    plaintext: [token_bytes]u8,
    lookup: [lookup_bytes]u8,
    digest: [32]u8,

    pub fn generate(io: std.Io, pepper: [32]u8) Generated {
        var lookup_raw: [lookup_random_bytes]u8 = undefined;
        var secret_raw: [secret_random_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &lookup_raw);
        defer std.crypto.secureZero(u8, &secret_raw);
        std.Io.random(io, &lookup_raw);
        std.Io.random(io, &secret_raw);
        return fromRaw(lookup_raw, secret_raw, pepper);
    }

    pub fn fromRaw(
        lookup_raw: [lookup_random_bytes]u8,
        secret_raw: [secret_random_bytes]u8,
        pepper: [32]u8,
    ) Generated {
        var result: Generated = undefined;
        @memcpy(result.plaintext[0..marker.len], marker);
        _ = std.base64.url_safe_no_pad.Encoder.encode(
            result.plaintext[marker.len..lookup_bytes],
            &lookup_raw,
        );
        result.plaintext[lookup_bytes] = '_';
        _ = std.base64.url_safe_no_pad.Encoder.encode(
            result.plaintext[lookup_bytes + 1 ..],
            &secret_raw,
        );
        result.lookup = result.plaintext[0..lookup_bytes].*;
        result.digest = digest(&result.plaintext, pepper);
        return result;
    }

    pub fn slice(self: *const Generated) []const u8 {
        return &self.plaintext;
    }

    pub fn clear(self: *Generated) void {
        std.crypto.secureZero(u8, &self.plaintext);
        std.crypto.secureZero(u8, &self.digest);
    }
};

pub const Parsed = struct {
    lookup: [lookup_bytes]u8,
    digest: [32]u8,
};

pub fn parse(value: []const u8, pepper: [32]u8) error{InvalidToken}!Parsed {
    if (value.len != token_bytes or !std.mem.startsWith(u8, value, marker) or
        value[lookup_bytes] != '_')
    {
        return error.InvalidToken;
    }
    if (!validEncoded(value[marker.len..lookup_bytes]) or
        !validEncoded(value[lookup_bytes + 1 ..]))
    {
        return error.InvalidToken;
    }
    var lookup_raw: [lookup_random_bytes]u8 = undefined;
    var secret_raw: [secret_random_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &lookup_raw);
    defer std.crypto.secureZero(u8, &secret_raw);
    std.base64.url_safe_no_pad.Decoder.decode(
        &lookup_raw,
        value[marker.len..lookup_bytes],
    ) catch return error.InvalidToken;
    std.base64.url_safe_no_pad.Decoder.decode(
        &secret_raw,
        value[lookup_bytes + 1 ..],
    ) catch return error.InvalidToken;

    const canonical = Generated.fromRaw(lookup_raw, secret_raw, pepper);
    if (!std.crypto.timing_safe.eql(
        [token_bytes]u8,
        canonical.plaintext,
        value[0..token_bytes].*,
    )) return error.InvalidToken;
    return .{
        .lookup = canonical.lookup,
        .digest = canonical.digest,
    };
}

pub fn verify(stored_digest: [32]u8, parsed: Parsed) bool {
    return std.crypto.timing_safe.eql([32]u8, stored_digest, parsed.digest);
}

fn digest(value: []const u8, pepper: [32]u8) [32]u8 {
    var output: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&output, value, &pepper);
    return output;
}

fn validEncoded(value: []const u8) bool {
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    }
    return true;
}

test "API tokens expose a lookup prefix and keyed digest" {
    const pepper = [_]u8{0xa5} ** 32;
    var generated = Generated.fromRaw(
        [_]u8{0x10} ** lookup_random_bytes,
        [_]u8{0x20} ** secret_random_bytes,
        pepper,
    );
    defer generated.clear();
    try std.testing.expectEqual(@as(usize, token_bytes), generated.slice().len);
    try std.testing.expect(std.mem.startsWith(u8, generated.slice(), marker));
    const parsed = try parse(generated.slice(), pepper);
    try std.testing.expectEqual(generated.lookup, parsed.lookup);
    try std.testing.expect(verify(generated.digest, parsed));

    const wrong = [_]u8{0x5a} ** 32;
    const wrong_parsed = try parse(generated.slice(), wrong);
    try std.testing.expect(!verify(generated.digest, wrong_parsed));
}

test "API tokens reject malformed and truncated values" {
    const pepper = [_]u8{0x33} ** 32;
    var generated = Generated.fromRaw(
        [_]u8{0x44} ** lookup_random_bytes,
        [_]u8{0x55} ** secret_random_bytes,
        pepper,
    );
    defer generated.clear();
    var malformed = generated.plaintext;
    malformed[10] = '?';
    try std.testing.expectError(error.InvalidToken, parse(&malformed, pepper));
    try std.testing.expectError(error.InvalidToken, parse("poof_short", pepper));
}
