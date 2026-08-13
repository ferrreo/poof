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

pub fn formatId(value: [16]u8) [36]u8 {
    var output: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var source: usize = 0;
    var target: usize = 0;
    while (source < value.len) : (source += 1) {
        if (target == 8 or target == 13 or target == 18 or target == 23) {
            output[target] = '-';
            target += 1;
        }
        output[target] = hex[value[source] >> 4];
        output[target + 1] = hex[value[source] & 0x0f];
        target += 2;
    }
    return output;
}

pub fn parseId(value: []const u8) error{InvalidTokenId}![16]u8 {
    if (value.len != 36 or value[8] != '-' or value[13] != '-' or
        value[18] != '-' or value[23] != '-')
    {
        return error.InvalidTokenId;
    }
    var output: [16]u8 = undefined;
    var source: usize = 0;
    var target: usize = 0;
    while (target < output.len) : (target += 1) {
        if (source == 8 or source == 13 or source == 18 or source == 23) source += 1;
        const high = idNibble(value[source]) orelse return error.InvalidTokenId;
        const low = idNibble(value[source + 1]) orelse return error.InvalidTokenId;
        output[target] = high << 4 | low;
        source += 2;
    }
    return output;
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

fn idNibble(value: u8) ?u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => null,
    };
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

test "token UUIDs round trip for revocation forms" {
    const value = [_]u8{
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
    };
    const formatted = formatId(value);
    try std.testing.expectEqualStrings(
        "12345678-9abc-def0-1122-334455667788",
        &formatted,
    );
    try std.testing.expectEqual(value, try parseId(&formatted));
}
