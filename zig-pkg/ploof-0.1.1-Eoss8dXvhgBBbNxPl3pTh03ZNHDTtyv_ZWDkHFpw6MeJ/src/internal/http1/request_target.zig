const std = @import("std");
const fuzz_support = @import("testing/smith.zig");
const status_module = @import("status.zig");
const syntax = @import("syntax.zig");

pub const Status = status_module.Status;

pub const Rejection = struct {
    status: Status,
    close: bool = true,
};

pub const ParseResult = union(enum) {
    ready: Target,
    rejected: Rejection,
};

pub const Scheme = enum(u1) {
    http,
    https,
};

pub const PortRequirement = enum(u1) {
    optional,
    required,
};

pub const Origin = struct {
    raw_target: []const u8,
    raw_path: []const u8,
    raw_query: ?[]const u8,
    decoded_path: []const u8,
};

pub const Absolute = struct {
    raw_target: []const u8,
    scheme: Scheme,
    authority_unverified: []const u8,
    raw_path: []const u8,
    raw_query: ?[]const u8,
    decoded_path: []const u8,
};

pub const Target = union(enum) {
    origin: Origin,
    absolute: Absolute,
    asterisk: []const u8,
};

const SchemeMatch = struct {
    scheme: Scheme,
    authority_start: usize,
};

const PathQuery = struct {
    path: []const u8,
    query: ?[]const u8,
};

pub fn parse(method: []const u8, raw_target: []const u8, decoded_path_output: []u8) ParseResult {
    std.debug.assert(decoded_path_output.len >= raw_target.len);
    if (raw_target.len == 0) return reject(.bad_request);

    if (std.mem.eql(u8, raw_target, "*")) {
        if (!std.mem.eql(u8, method, "OPTIONS")) return reject(.bad_request);
        return .{ .ready = .{ .asterisk = raw_target } };
    }

    if (raw_target[0] == '/') {
        if (std.mem.eql(u8, method, "CONNECT")) return reject(.bad_request);
        return parseOrigin(raw_target, decoded_path_output);
    }

    if (absoluteScheme(raw_target)) |scheme| {
        if (std.mem.eql(u8, method, "CONNECT")) return reject(.bad_request);
        return parseAbsolute(raw_target, decoded_path_output, scheme);
    }

    if (std.mem.eql(u8, method, "CONNECT") and
        validAuthoritySyntax(raw_target, .required))
    {
        return reject(.not_implemented);
    }
    return reject(.bad_request);
}

fn parseOrigin(raw_target: []const u8, output: []u8) ParseResult {
    const split = splitPathQuery(raw_target);
    if (split.query) |query| if (!validQuery(query)) return reject(.bad_request);
    const decoded = decodePath(split.path, output) orelse return reject(.bad_request);
    return .{ .ready = .{ .origin = .{
        .raw_target = raw_target,
        .raw_path = split.path,
        .raw_query = split.query,
        .decoded_path = decoded,
    } } };
}

fn parseAbsolute(raw_target: []const u8, output: []u8, match: SchemeMatch) ParseResult {
    var authority_end = match.authority_start;
    while (authority_end < raw_target.len and
        raw_target[authority_end] != '/' and raw_target[authority_end] != '?')
    {
        authority_end += 1;
    }
    const authority = raw_target[match.authority_start..authority_end];
    if (!validAuthoritySyntax(authority, .optional)) return reject(.bad_request);

    const split = splitPathQuery(raw_target[authority_end..]);
    if (split.query) |query| if (!validQuery(query)) return reject(.bad_request);
    const decoded = if (split.path.len == 0)
        decodedRoot(output)
    else
        decodePath(split.path, output) orelse return reject(.bad_request);
    return .{ .ready = .{ .absolute = .{
        .raw_target = raw_target,
        .scheme = match.scheme,
        .authority_unverified = authority,
        .raw_path = split.path,
        .raw_query = split.query,
        .decoded_path = decoded,
    } } };
}

fn absoluteScheme(raw: []const u8) ?SchemeMatch {
    if (raw.len >= 7 and syntax.eqlIgnoreCase(raw[0..7], "http://")) {
        return .{ .scheme = .http, .authority_start = 7 };
    }
    if (raw.len >= 8 and syntax.eqlIgnoreCase(raw[0..8], "https://")) {
        return .{ .scheme = .https, .authority_start = 8 };
    }
    return null;
}

fn splitPathQuery(raw: []const u8) PathQuery {
    const question = std.mem.indexOfScalar(u8, raw, '?') orelse {
        return .{ .path = raw, .query = null };
    };
    return .{ .path = raw[0..question], .query = raw[question + 1 ..] };
}

fn decodePath(raw: []const u8, output: []u8) ?[]const u8 {
    var escaped = false;
    var index: usize = 0;
    while (index < raw.len) {
        const byte = raw[index];
        if (byte != '%') {
            if (byte != '/' and !syntax.isUriPchar(byte)) return null;
            index += 1;
            continue;
        }
        if (raw.len - index < 3) return null;
        if (hexValue(raw[index + 1]) >= 16 or hexValue(raw[index + 2]) >= 16) return null;
        escaped = true;
        index += 3;
    }
    if (!escaped) return raw;

    index = 0;
    var written: usize = 0;
    while (index < raw.len) {
        if (raw[index] == '%') {
            output[written] = (hexValue(raw[index + 1]) << 4) | hexValue(raw[index + 2]);
            index += 3;
        } else {
            output[written] = raw[index];
            index += 1;
        }
        written += 1;
    }
    return output[0..written];
}

fn validQuery(raw: []const u8) bool {
    var index: usize = 0;
    while (index < raw.len) {
        const byte = raw[index];
        if (byte != '%') {
            if (byte != '/' and byte != '?' and !syntax.isUriPchar(byte)) return false;
            index += 1;
            continue;
        }
        if (raw.len - index < 3) return false;
        if (hexValue(raw[index + 1]) >= 16 or hexValue(raw[index + 2]) >= 16) return false;
        index += 3;
    }
    return true;
}

fn decodedRoot(output: []u8) []const u8 {
    output[0] = '/';
    return output[0..1];
}

/// Validates raw authority; nonempty numeric ports must fit `u16`.
/// Does not normalize or establish authority identity.
pub fn validAuthoritySyntax(authority: []const u8, port: PortRequirement) bool {
    if (authority.len == 0) return false;
    if (authority[0] == '[') return validBracketAuthority(authority, port);

    var colon: ?usize = null;
    for (authority, 0..) |byte, index| {
        if (byte == '[' or byte == ']' or byte == '@' or byte == '/' or
            byte == '?' or byte == '#' or byte == '\\') return false;
        if (byte == ':') {
            if (colon != null) return false;
            colon = index;
        }
    }
    const host_end = colon orelse authority.len;
    if (!validRegName(authority[0..host_end])) return false;
    if (colon) |position| {
        const digits = authority[position + 1 ..];
        return digits.len == 0 and port == .optional or validPort(digits);
    }
    return port == .optional;
}

fn validBracketAuthority(authority: []const u8, port: PortRequirement) bool {
    const close = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
    if (close == 1 or !validIpLiteral(authority[1..close])) return false;
    const suffix = authority[close + 1 ..];
    if (suffix.len == 0) return port == .optional;
    if (suffix[0] != ':') return false;
    const digits = suffix[1..];
    return digits.len == 0 and port == .optional or validPort(digits);
}

fn validRegName(host: []const u8) bool {
    if (host.len == 0) return false;
    var index: usize = 0;
    while (index < host.len) {
        const byte = host[index];
        if (byte == '%') {
            if (host.len - index < 3) return false;
            if (hexValue(host[index + 1]) >= 16 or hexValue(host[index + 2]) >= 16) {
                return false;
            }
            index += 3;
            continue;
        }
        if (!hostByte(byte)) return false;
        index += 1;
    }
    return true;
}

fn validIpLiteral(literal: []const u8) bool {
    if (literal.len == 0) return false;
    if (literal[0] == 'v' or literal[0] == 'V') return validIpvFuture(literal);
    return validIpv6(literal);
}

fn validIpvFuture(literal: []const u8) bool {
    var index: usize = 1;
    while (index < literal.len and hexValue(literal[index]) < 16) index += 1;
    if (index == 1 or index == literal.len or literal[index] != '.') return false;
    index += 1;
    if (index == literal.len) return false;
    for (literal[index..]) |byte| {
        if (!hostByte(byte) and byte != ':') return false;
    }
    return true;
}

fn validIpv6(address: []const u8) bool {
    if (address.len < 2) return false;
    var index: usize = 0;
    var groups: u8 = 0;
    var compressed = false;
    if (std.mem.startsWith(u8, address, "::")) {
        compressed = true;
        index = 2;
        if (index == address.len) return true;
    }

    while (index < address.len) {
        const start = index;
        while (index < address.len and address[index] != ':') index += 1;
        const piece = address[start..index];
        if (piece.len == 0) return false;
        if (std.mem.indexOfScalar(u8, piece, '.') != null) {
            if (index != address.len or groups > 6 or !validIpv4(piece)) return false;
            groups += 2;
            break;
        }
        if (piece.len > 4) return false;
        for (piece) |byte| if (hexValue(byte) >= 16) return false;
        groups += 1;
        if (groups > 8) return false;
        if (index == address.len) break;

        if (index + 1 < address.len and address[index + 1] == ':') {
            if (compressed) return false;
            compressed = true;
            index += 2;
            if (index == address.len) break;
        } else {
            index += 1;
            if (index == address.len) return false;
        }
    }
    return if (compressed) groups < 8 else groups == 8;
}

fn validIpv4(address: []const u8) bool {
    var index: usize = 0;
    var octets: u8 = 0;
    while (index < address.len) {
        const start = index;
        var value: u16 = 0;
        while (index < address.len and address[index] >= '0' and address[index] <= '9') {
            value = value * 10 + address[index] - '0';
            if (value > 255) return false;
            index += 1;
        }
        if (index == start or index - start > 1 and address[start] == '0') return false;
        octets += 1;
        if (octets > 4) return false;
        if (index == address.len) break;
        if (address[index] != '.') return false;
        index += 1;
        if (index == address.len) return false;
    }
    return octets == 4;
}

fn hostByte(byte: u8) bool {
    return switch (byte) {
        '0'...'9',
        'A'...'Z',
        'a'...'z',
        '-',
        '.',
        '_',
        '~',
        '!',
        '$',
        '&',
        '\'',
        '(',
        ')',
        '*',
        '+',
        ',',
        ';',
        '=',
        => true,
        else => false,
    };
}

fn validPort(port: []const u8) bool {
    if (port.len == 0) return false;
    var value: u32 = 0;
    for (port) |byte| {
        if (byte < '0' or byte > '9') return false;
        const digit: u32 = byte - '0';
        if (value > (std.math.maxInt(u16) - digit) / 10) return false;
        value = value * 10 + digit;
    }
    return true;
}

fn hexValue(byte: u8) u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => std.math.maxInt(u8),
    };
}

fn reject(status: Status) ParseResult {
    return .{ .rejected = .{ .status = status } };
}

test "origin form preserves syntax while decoding its path" {
    const raw = "/A//b/./c/../D%2fe?x=%25&still=raw";
    var output = [_]u8{0xa5} ** raw.len;
    const target = try expectReady("GET", raw, &output);
    const origin = switch (target) {
        .origin => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(raw, origin.raw_target);
    try std.testing.expectEqualStrings("/A//b/./c/../D%2fe", origin.raw_path);
    try std.testing.expectEqualStrings("x=%25&still=raw", origin.raw_query.?);
    try std.testing.expectEqualStrings("/A//b/./c/../D/e", origin.decoded_path);
}

test "unchanged origin path remains borrowed" {
    const raw = "/Mixed//./../path";
    var output = [_]u8{0xa5} ** raw.len;
    const before = output;
    const target = try expectReady("GET", raw, &output);
    try std.testing.expectEqualStrings(raw, target.origin.decoded_path);
    try std.testing.expectEqualSlices(u8, &before, &output);
}

test "path percent decoding accepts every byte and hex case" {
    const digits = "0123456789ABCDEF";
    var raw: [1 + 256 * 3]u8 = undefined;
    var expected: [1 + 256]u8 = undefined;
    raw[0] = '/';
    expected[0] = '/';
    for (0..256) |index| {
        const byte: u8 = @intCast(index);
        const cursor = 1 + index * 3;
        raw[cursor] = '%';
        raw[cursor + 1] = digits[byte >> 4];
        raw[cursor + 2] = if (index % 2 == 0)
            digits[byte & 0x0f]
        else
            syntax.asciiLower(digits[byte & 0x0f]);
        expected[index + 1] = byte;
    }
    var output: [raw.len]u8 = undefined;
    const target = try expectReady("GET", &raw, &output);
    try std.testing.expectEqualSlices(u8, &expected, target.origin.decoded_path);
}

test "absolute form exposes only unverified raw authority" {
    const raw = "HtTpS://Example.COM:443/a%2Fb?q=one?two";
    var output: [raw.len]u8 = undefined;
    const target = try expectReady("GET", raw, &output);
    const absolute = switch (target) {
        .absolute => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(Scheme.https, absolute.scheme);
    try std.testing.expectEqualStrings("Example.COM:443", absolute.authority_unverified);
    try std.testing.expectEqualStrings("/a%2Fb", absolute.raw_path);
    try std.testing.expectEqualStrings("q=one?two", absolute.raw_query.?);
    try std.testing.expectEqualStrings("/a/b", absolute.decoded_path);
}

test "absolute empty paths decode to root and preserve query presence" {
    const cases = [_]struct { raw: []const u8, query: ?[]const u8 }{
        .{ .raw = "http://example.test", .query = null },
        .{ .raw = "http://example.test?x=1", .query = "x=1" },
        .{ .raw = "http://example.test?", .query = "" },
    };
    for (cases) |case| {
        var output: [64]u8 = undefined;
        const target = try expectReady("GET", case.raw, &output);
        try std.testing.expectEqualStrings("", target.absolute.raw_path);
        try expectOptionalString(case.query, target.absolute.raw_query);
        try std.testing.expectEqualStrings("/", target.absolute.decoded_path);
    }
}

test "asterisk and authority forms enforce exact method case" {
    var output: [32]u8 = undefined;
    const asterisk = try expectReady("OPTIONS", "*", &output);
    try std.testing.expectEqualStrings("*", asterisk.asterisk);

    try expectRejected("options", "*", .bad_request);
    try expectRejected("GET", "*", .bad_request);
    try expectRejected("CONNECT", "/", .bad_request);
    try expectRejected("CONNECT", "http://example.test/", .bad_request);
    try expectRejected("GET", "example.test:443", .bad_request);
    try expectRejected("connect", "example.test:443", .bad_request);
    try expectRejected("CONNECT", "example.test:443", .not_implemented);
    try expectRejected("CONNECT", "[::1]:65535", .not_implemented);
}

test "malformed paths fragments and raw bytes reject" {
    const malformed = [_][]const u8{
        "/%",
        "/%0",
        "/%GG",
        "/a%2x",
        "/raw#fragment",
        "/raw\\slash",
        "/space here",
        "/nul\x00",
        "/delete\x7f",
        "/obs\x80",
        "/raw[bracket",
        "/raw]bracket",
        "/raw\"quote",
        "/raw<angle",
        "/raw>angle",
        "/raw^caret",
        "/raw`tick",
        "/raw{brace",
        "/raw|pipe",
        "/raw}brace",
        "/ok?bad%",
        "/ok?bad%0",
        "/ok?bad%GG",
        "/ok?bad[query",
        "http://example.test/bad[path",
        "http://example.test/ok?bad|query",
    };
    for (malformed) |raw| try expectRejected("GET", raw, .bad_request);
}

test "path and query accept exact RFC3986 component punctuation" {
    const raw = "/AZaz09-._~!$&'()*+,;=:@/%00?q=/?:@!$&'()*+,;=%25";
    var output: [raw.len]u8 = undefined;
    const target = try expectReady("GET", raw, &output);
    try std.testing.expectEqualStrings("q=/?:@!$&'()*+,;=%25", target.origin.raw_query.?);
}

test "absolute authority and port syntax is strict" {
    const valid = [_][]const u8{
        "http://example.test/",
        "http://EXAMPLE.com:/",
        "http://example.test:0/",
        "http://example.test:65535/",
        "http://ho%73t/",
        "https://[::1]/",
        "https://[::1]:443/",
        "https://[::192.0.2.1]/",
        "https://[v1.a:b]:443/",
    };
    for (valid) |raw| {
        var output: [64]u8 = undefined;
        _ = try expectReady("GET", raw, &output);
    }

    const malformed = [_][]const u8{
        "ftp://example.test/",
        "http://",
        "http:///path",
        "http://:80/",
        "http://user@example.test/",
        "http://example.test:x/",
        "http://example.test:65536/",
        "http://example.test:999999999999999999999999999999999999/",
        "http://example.test:80:90/",
        "http://ho%2/",
        "http://ho%xx/",
        "http://[]/",
        "http://[::1/",
        "http://[::1]tail/",
        "http://example.test\\path",
        "http://example.test/#fragment",
    };
    for (malformed) |raw| try expectRejected("GET", raw, .bad_request);
}

test "authority syntax supports Host and CONNECT port rules" {
    const optional = [_][]const u8{
        "example.test",
        "example.test:",
        "example.test:0",
        "ho%73t:65535",
        "[::]",
        "[::1]:",
        "[2001:db8::2:1]",
        "[::192.0.2.1]",
        "[0:0:0:0:0:ffff:192.0.2.1]",
        "[v1.a]",
        "[vF.a:b]:443",
    };
    for (optional) |authority| {
        try std.testing.expect(validAuthoritySyntax(authority, .optional));
    }

    const required = [_][]const u8{ "example.test:443", "[::1]:443", "[v1.a]:1" };
    for (required) |authority| {
        try std.testing.expect(validAuthoritySyntax(authority, .required));
    }
    try std.testing.expect(!validAuthoritySyntax("example.test", .required));
    try std.testing.expect(!validAuthoritySyntax("example.test:", .required));
    try std.testing.expect(!validAuthoritySyntax("[::1]", .required));
    try std.testing.expect(!validAuthoritySyntax("[::1]:", .required));

    const malformed = [_][]const u8{
        "[garbage]",
        "[::::]",
        "[1:2:3:4:5:6:7]",
        "[1:2:3:4:5:6:7:8:9]",
        "[1::2::3]",
        "[fe80::1%25eth0]",
        "[::ffff:192.168.001.1]",
        "[::ffff:192.0.2.1.]",
        "[v.a]",
        "[v1.]",
        "[v1.a%20]",
        "[v1.a]tail",
    };
    for (malformed) |authority| {
        try std.testing.expect(!validAuthoritySyntax(authority, .optional));
        try std.testing.expect(!validAuthoritySyntax(authority, .required));
    }
}

test "CONNECT rejects malformed or missing authority ports" {
    const malformed = [_][]const u8{
        "example.test",
        ":443",
        "example.test:",
        "example.test:http",
        "example.test:65536",
        "example.test:999999999999999999999999999999999999",
        "example.test:443:1",
        "user@example.test:443",
        "[::1]",
        "[::1]:",
        "[::1]:x",
        "[::1",
        "[]:443",
    };
    for (malformed) |raw| try expectRejected("CONNECT", raw, .bad_request);
}

test "request target parser fuzz invariants" {
    try std.testing.fuzz({}, fuzzRequestTarget, .{ .corpus = &request_target_fuzz_corpus });
}

const request_target_fuzz_corpus = struct {
    const origin = fuzz_support.smithInput("GET\x00/");
    const encoded = fuzz_support.smithInput("GET\x00/a%2Fb?x=%");
    const absolute = fuzz_support.smithInput("GET\x00http://example.test/a");
    const asterisk = fuzz_support.smithInput("OPTIONS\x00*");
    const authority = fuzz_support.smithInput("CONNECT\x00example.test:443");
    const bad_escape = fuzz_support.smithInput("GET\x00/%");
    const bad_query_escape = fuzz_support.smithInput("GET\x00/ok?bad%GG");
    const bad_delimiter = fuzz_support.smithInput("GET\x00/bad[path");
    const bad_ipv6 = fuzz_support.smithInput("GET\x00http://[::::]/");

    const values = [_][]const u8{
        &origin,
        &encoded,
        &absolute,
        &asterisk,
        &authority,
        &bad_escape,
        &bad_query_escape,
        &bad_delimiter,
        &bad_ipv6,
    };
}.values;

fn fuzzRequestTarget(_: void, smith: *std.testing.Smith) !void {
    var storage: [512]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];
    const separator = std.mem.indexOfScalar(u8, input, 0);
    const method = if (separator) |index| input[0..index] else "GET";
    const raw = if (separator) |index| input[index + 1 ..] else input;
    var output_storage: [storage.len]u8 = undefined;
    const output = output_storage[0..raw.len];

    switch (parse(method, raw, output)) {
        .ready => |target| try checkReadyInvariants(method, target, raw, output),
        .rejected => |rejection| {
            try std.testing.expect(switch (rejection.status) {
                .bad_request, .not_implemented => true,
                else => false,
            });
            try std.testing.expect(rejection.close);
        },
    }
}

fn checkReadyInvariants(
    method: []const u8,
    target: Target,
    raw: []const u8,
    output: []const u8,
) !void {
    switch (target) {
        .asterisk => |value| {
            try std.testing.expectEqualStrings("OPTIONS", method);
            try std.testing.expectEqualStrings("*", value);
            try std.testing.expect(sliceWithin(raw, value));
        },
        .origin => |origin| {
            try std.testing.expect(raw.len > 0);
            try std.testing.expect(raw[0] == '/');
            try std.testing.expect(!std.mem.eql(u8, method, "CONNECT"));
            try std.testing.expectEqualStrings(raw, origin.raw_target);
            try std.testing.expect(sliceWithin(raw, origin.raw_target));
            try std.testing.expect(sliceWithin(raw, origin.raw_path));
            if (origin.raw_query) |query| {
                try std.testing.expect(sliceWithin(raw, query));
                try std.testing.expect(validQuery(query));
            }
            try std.testing.expect(origin.decoded_path.len <= origin.raw_path.len);
            try expectDecodedStorage(raw, output, origin.decoded_path);
        },
        .absolute => |absolute| {
            const match = absoluteScheme(raw) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(match.scheme, absolute.scheme);
            try std.testing.expect(!std.mem.eql(u8, method, "CONNECT"));
            try std.testing.expectEqualStrings(raw, absolute.raw_target);
            try std.testing.expect(sliceWithin(raw, absolute.raw_target));
            try std.testing.expect(sliceWithin(raw, absolute.authority_unverified));
            try std.testing.expect(sliceWithin(raw, absolute.raw_path));
            if (absolute.raw_query) |query| {
                try std.testing.expect(sliceWithin(raw, query));
                try std.testing.expect(validQuery(query));
            }
            if (absolute.raw_path.len == 0) {
                try std.testing.expectEqualStrings("/", absolute.decoded_path);
            } else {
                try std.testing.expect(absolute.decoded_path.len <= absolute.raw_path.len);
            }
            try expectDecodedStorage(raw, output, absolute.decoded_path);
        },
    }
}

fn expectDecodedStorage(raw: []const u8, output: []const u8, decoded: []const u8) !void {
    if (sliceWithin(raw, decoded)) return;
    try std.testing.expect(sliceWithin(output, decoded));
}

fn sliceWithin(storage: []const u8, slice: []const u8) bool {
    const storage_start = @intFromPtr(storage.ptr);
    const slice_start = @intFromPtr(slice.ptr);
    if (slice_start < storage_start) return false;
    const offset = slice_start - storage_start;
    return offset <= storage.len and slice.len <= storage.len - offset;
}

fn expectReady(method: []const u8, raw: []const u8, output: []u8) !Target {
    return switch (parse(method, raw, output)) {
        .ready => |target| target,
        .rejected => error.TestUnexpectedResult,
    };
}

fn expectRejected(method: []const u8, raw: []const u8, expected: Status) !void {
    var output: [1024]u8 = undefined;
    switch (parse(method, raw, &output)) {
        .ready => return error.TestUnexpectedResult,
        .rejected => |rejection| {
            try std.testing.expectEqual(expected, rejection.status);
            try std.testing.expect(rejection.close);
        },
    }
}

fn expectOptionalString(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |text| {
        try std.testing.expectEqualStrings(text, actual orelse return error.TestUnexpectedResult);
    } else {
        try std.testing.expectEqual(@as(?[]const u8, null), actual);
    }
}
