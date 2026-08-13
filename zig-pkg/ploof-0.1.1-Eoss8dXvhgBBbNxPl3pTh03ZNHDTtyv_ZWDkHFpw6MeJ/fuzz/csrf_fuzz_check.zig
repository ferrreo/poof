const std = @import("std");
const csrf = @import("../src/csrf.zig");
const csrf_origin = @import("../src/internal/csrf/origin.zig");
const csrf_request = @import("../src/internal/csrf/request.zig");
const authority = @import("../src/internal/http1/authority.zig");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const request_cors = @import("../src/internal/http1/request_cors.zig");

test "CSRF token cookie and origin parsers are deterministic and canonical" {
    try std.testing.fuzz({}, fuzzCore, .{ .corpus = &corpus });
}

const corpus = struct {
    const origin = fuzz_support.smithInput("https://App.Example:443");
    const encoded_ip = fuzz_support.smithInput("http://%31%39%32%2e0%2e2%2e1");
    const cookie = fuzz_support.smithInput("__Host-ploof-csrf=abc-123_; theme=dark");
    const token = fuzz_support.smithInput(
        "AQczMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM8HJABqmBpO0-p6yrtkC00iECHKW8UHyFBTrN9SucJLv",
    );
    const mixed = fuzz_support.smithInput("null; cross-site; X-CSRF-Token");
    const values = [_][]const u8{ &origin, &encoded_ip, &cookie, &token, &mixed };
}.values;

fn fuzzCore(_: void, smith: *std.testing.Smith) !void {
    var storage: [512]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];
    try checkSynchronizer(input);
    try checkSigned(input);
    try checkCookie(input);
    try checkOrigin(input);
    try checkSigning(input);
}

fn checkSynchronizer(input: []const u8) !void {
    var first: [csrf_request.synchronizer_bytes]u8 = undefined;
    var second: [csrf_request.synchronizer_bytes]u8 = undefined;
    const valid_first = csrf_request.decodeSynchronizer(input, &first);
    const valid_second = csrf_request.decodeSynchronizer(input, &second);
    try std.testing.expectEqual(valid_first, valid_second);
    if (!valid_first) return;
    try std.testing.expectEqualSlices(u8, &first, &second);
    const encoded = csrf_request.encodeSynchronizer(&first);
    try std.testing.expectEqualSlices(u8, input, &encoded);
}

fn checkSigned(input: []const u8) !void {
    var first: [csrf_request.signed_bytes]u8 = undefined;
    var second: [csrf_request.signed_bytes]u8 = undefined;
    const valid_first = csrf_request.decodeSigned(input, &first);
    const valid_second = csrf_request.decodeSigned(input, &second);
    try std.testing.expectEqual(valid_first, valid_second);
    if (!valid_first) return;
    try std.testing.expectEqualSlices(u8, &first, &second);
    const encoded = csrf_request.encodeSigned(&first);
    try std.testing.expectEqualSlices(u8, input, &encoded);
}

fn checkCookie(input: []const u8) !void {
    var first = csrf_request.CookieScanner.init("__Host-ploof-csrf");
    var second = csrf_request.CookieScanner.init("__Host-ploof-csrf");
    first.feed(input);
    second.feed(input);
    const first_result = first.finish();
    const second_result = second.finish();
    try std.testing.expectEqual(
        std.meta.activeTag(first_result),
        std.meta.activeTag(second_result),
    );
    if (first_result == .value) {
        try std.testing.expectEqualSlices(u8, first_result.value, second_result.value);
    }
}

fn checkOrigin(input: []const u8) !void {
    const first = csrf_origin.parseRefererOrigin(input);
    const second = csrf_origin.parseRefererOrigin(input);
    try std.testing.expectEqual(first == null, second == null);
    if (first) |parsed| {
        try std.testing.expect(oracleOriginEqual(parsed, second.?));
        if (parsed == .tuple) {
            const reparsed = request_cors.parseOrigin(parsed.tuple.raw) orelse {
                return error.TestUnexpectedResult;
            };
            try std.testing.expect(oracleOriginEqual(parsed, reparsed));
        }
    }
    try std.testing.expectEqual(
        oracleFetchSite(input),
        csrf_origin.parseFetchSite(input),
    );
    try checkOriginSet(input);
}

const origin_values = [_][]const u8{
    "HTTPS://App.Example:443",
    "http://a%2Cb:80",
    "https://[2001:db8::1]:8443",
    "http://[vF.A:B]",
    "http://%31%39%32%2e0%2e2%2e1",
};

fn checkOriginSet(input: []const u8) !void {
    const Origins = csrf.OriginSet(origin_values.len, 64);
    const set = try Origins.init(&origin_values);
    const candidate = request_cors.parseOrigin(input);
    var expected_matches: u16 = 0;
    if (candidate) |parsed| {
        for (origin_values) |value| {
            const configured = request_cors.parseOrigin(value) orelse unreachable;
            if (oracleOriginEqual(parsed, configured)) expected_matches += 1;
        }
    }
    try std.testing.expectEqual(expected_matches == 1, set.containsRaw(input));
    try checkCorruptedSet(set, input);
}

fn checkCorruptedSet(original: anytype, input: []const u8) !void {
    var set = original;
    const selected: usize = if (input.len == 0) 0 else input[0] % origin_values.len;
    const mutation = if (input.len < 2) 0 else input[1] % 4;
    switch (mutation) {
        0 => set.entries[selected].seal ^= 1,
        1 => set.entries[selected].bytes[0] ^= 1,
        2 => set.entries[selected].length = 0,
        3 => set.entries[origin_values.len - 1] = set.entries[origin_values.len - 2],
        else => unreachable,
    }
    try std.testing.expect(set.issue() != null);
    try std.testing.expect(!set.containsRaw("https://app.example"));
    const app = request_cors.parseOrigin("https://app.example").?.tuple;
    try std.testing.expect(!set.containsEffective(.https, app.canonical_authority.?));
    try std.testing.expectEqual(csrf_origin.GateDecision.misdirected, csrf_origin.gate(
        &set,
        &set,
        .https,
        app.canonical_authority.?,
        false,
        .{},
    ));
}

fn oracleOriginEqual(left: request_cors.Origin, right: request_cors.Origin) bool {
    return switch (left) {
        .opaque_null => right == .opaque_null,
        .tuple => |left_tuple| switch (right) {
            .opaque_null => false,
            .tuple => |right_tuple| blk: {
                const left_authority = left_tuple.canonical_authority orelse break :blk false;
                const right_authority = right_tuple.canonical_authority orelse break :blk false;
                if (!asciiEqualFold(left_tuple.scheme, right_tuple.scheme)) break :blk false;
                if (left_authority.port != right_authority.port) break :blk false;
                break :blk oracleHostEqual(left_authority.host, right_authority.host);
            },
        },
    };
}

fn oracleHostEqual(left: authority.Host, right: authority.Host) bool {
    return switch (left) {
        .reg_name => |left_text| switch (right) {
            .reg_name => |right_text| oracleTextEqual(left_text, right_text, true),
            else => false,
        },
        .ip => |left_ip| switch (right) {
            .ip => |right_ip| left_ip.eql(right_ip),
            else => false,
        },
        .ipv_future => |left_text| switch (right) {
            .ipv_future => |right_text| oracleTextEqual(left_text, right_text, false),
            else => false,
        },
    };
}

fn oracleTextEqual(left: authority.Text, right: authority.Text, decode: bool) bool {
    if (left.quoted or right.quoted) return false;
    var left_storage: [512]u8 = undefined;
    var right_storage: [512]u8 = undefined;
    const left_bytes = oracleText(left.bytes, decode, &left_storage) orelse return false;
    const right_bytes = oracleText(right.bytes, decode, &right_storage) orelse return false;
    return std.mem.eql(u8, left_bytes, right_bytes);
}

fn oracleText(input: []const u8, decode: bool, output: []u8) ?[]const u8 {
    var read: usize = 0;
    var written: usize = 0;
    while (read < input.len) {
        var byte = input[read];
        read += 1;
        if (decode and byte == '%') {
            if (read + 1 >= input.len) return null;
            const high = oracleHex(input[read]) orelse return null;
            const low = oracleHex(input[read + 1]) orelse return null;
            read += 2;
            const decoded = (high << 4) | low;
            if (oracleUnreserved(decoded)) {
                byte = asciiLower(decoded);
            } else {
                if (written + 3 > output.len) return null;
                output[written] = '%';
                output[written + 1] = upperHex(input[read - 2]);
                output[written + 2] = upperHex(input[read - 1]);
                written += 3;
                continue;
            }
        } else {
            byte = asciiLower(byte);
        }
        if (written == output.len) return null;
        output[written] = byte;
        written += 1;
    }
    return output[0..written];
}

fn oracleFetchSite(input: []const u8) csrf_origin.FetchSite {
    if (std.mem.eql(u8, input, "same-origin")) return .same_origin;
    if (std.mem.eql(u8, input, "same-site")) return .same_site;
    if (std.mem.eql(u8, input, "cross-site")) return .cross_site;
    if (std.mem.eql(u8, input, "none")) return .none;
    return .unknown;
}

fn asciiEqualFold(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (asciiLower(a) != asciiLower(b)) return false;
    return true;
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn oracleHex(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
}

fn upperHex(byte: u8) u8 {
    return if (byte >= 'a' and byte <= 'f') byte - 32 else byte;
}

fn oracleUnreserved(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        std.mem.indexOfScalar(u8, "-._~", byte) != null;
}

fn checkSigning(input: []const u8) !void {
    if (input.len < 96) return;
    const key = csrf.Key.init(17, input[0..32].*) catch return;
    const binding = csrf.LoginBinding.fromRandomLoginValue(input[32..64].*) catch return;
    const nonce = input[64..96].*;
    const keys = try csrf.Keyring.init(key, null);
    var encoded = keys.sign(binding, nonce) catch return;
    defer encoded.clear();
    try std.testing.expect(keys.verify(binding, encoded.slice()));
}
