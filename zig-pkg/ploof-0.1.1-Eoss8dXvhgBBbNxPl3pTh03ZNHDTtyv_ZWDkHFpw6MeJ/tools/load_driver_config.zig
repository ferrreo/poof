const std = @import("std");

pub const concurrency_max: u16 = 256;
pub const requests_max: u64 = 1_000_000_000;
pub const request_bytes_max: usize = 16 * 1024;
pub const request_file_bytes_max: usize = 1024 * 1024;
pub const request_generated_bytes_max: u64 = 16 * 1024 * 1024;
pub const expected_body_bytes_max: usize = 128 * 1024;
pub const expected_hashed_body_bytes_max: u64 = 1024 * 1024 * 1024;
pub const host_bytes_max: usize = 255;
pub const path_bytes_max: usize = 1024;
pub const timeout_ms_max: u32 = 3_600_000;
pub const rate_max: u64 = 100_000_000;
pub const headers_max: u8 = 8;
pub const header_name_bytes_max: usize = 64;
pub const header_value_bytes_max: usize = 512;

pub const Scheduling = enum {
    closed_loop,
    constant_rate,
};

pub const Connections = enum {
    keepalive,
    churn,
};

pub const ExpectedBody = union(enum) {
    bytes: []const u8,
    sha256: struct {
        bytes: u64,
        digest: [32]u8,
    },
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Config = struct {
    address: [4]u8 = .{ 127, 0, 0, 1 },
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    path: []const u8 = "/",
    method: []const u8 = "GET",
    request_body: []const u8 = "",
    request_body_explicit: bool = false,
    request_body_file: ?[]const u8 = null,
    request_body_bytes: ?u64 = null,
    request_body_byte: u8 = 'a',
    request_body_byte_explicit: bool = false,
    content_type: []const u8 = "application/octet-stream",
    expected_status: u16 = 200,
    expected_body: []const u8 = "",
    expected_body_explicit: bool = false,
    expected_body_bytes: ?u64 = null,
    expected_sha256: ?[32]u8 = null,
    requests: u64 = 1,
    concurrency: u16 = 1,
    rate: u64 = 0,
    timeout_ms: u32 = 10_000,
    scheduling: Scheduling = .closed_loop,
    connections: Connections = .keepalive,
    calibration: bool = false,
    headers: [headers_max]Header = undefined,
    header_count: u8 = 0,

    pub fn expectedBody(self: Config) ExpectedBody {
        if (self.expected_body_bytes) |bytes| return .{ .sha256 = .{
            .bytes = bytes,
            .digest = self.expected_sha256.?,
        } };
        return .{ .bytes = self.expected_body };
    }

    pub fn headerSlice(self: *const Config) []const Header {
        return self.headers[0..self.header_count];
    }
};

const Seen = struct {
    address: bool = false,
    host: bool = false,
    port: bool = false,
    path: bool = false,
    method: bool = false,
    request_body: bool = false,
    request_body_file: bool = false,
    request_body_bytes: bool = false,
    request_body_byte: bool = false,
    content_type: bool = false,
    expected_status: bool = false,
    expected_body: bool = false,
    expected_body_bytes: bool = false,
    expected_sha256: bool = false,
    requests: bool = false,
    concurrency: bool = false,
    rate: bool = false,
    timeout_ms: bool = false,
    scheduling: bool = false,
    connections: bool = false,
    calibration: bool = false,
};

pub fn parse(process_args: std.process.Args) !Config {
    var args = process_args.iterate();
    defer args.deinit();
    _ = args.next() orelse return error.MissingProgramName;
    var config = Config{};
    var seen = Seen{};
    while (args.next()) |name| {
        if (std.mem.eql(u8, name, "--help")) return error.HelpRequested;
        if (std.mem.eql(u8, name, "--calibrate")) {
            try claim(&seen.calibration);
            config.calibration = true;
            continue;
        }
        const value = args.next() orelse return error.MissingOptionValue;
        try parseOption(&config, &seen, name, value);
    }
    try validate(config);
    return config;
}

fn parseOption(config: *Config, seen: *Seen, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--header")) {
        try addHeader(config, value);
    } else if (std.mem.eql(u8, name, "--address")) {
        try claim(&seen.address);
        config.address = try parseIpv4(value);
    } else if (std.mem.eql(u8, name, "--host")) {
        try claim(&seen.host);
        config.host = value;
    } else if (std.mem.eql(u8, name, "--port")) {
        try claim(&seen.port);
        config.port = try parseUnsigned(u16, value, 1, std.math.maxInt(u16));
    } else if (std.mem.eql(u8, name, "--path")) {
        try claim(&seen.path);
        config.path = value;
    } else if (std.mem.eql(u8, name, "--method")) {
        try claim(&seen.method);
        config.method = value;
    } else if (std.mem.eql(u8, name, "--request-body")) {
        try claim(&seen.request_body);
        config.request_body = value;
        config.request_body_explicit = true;
    } else if (std.mem.eql(u8, name, "--request-body-file")) {
        try claim(&seen.request_body_file);
        config.request_body_file = value;
    } else if (std.mem.eql(u8, name, "--request-body-bytes")) {
        try claim(&seen.request_body_bytes);
        config.request_body_bytes = try parseUnsigned(
            u64,
            value,
            0,
            request_generated_bytes_max,
        );
    } else if (std.mem.eql(u8, name, "--request-body-byte")) {
        try claim(&seen.request_body_byte);
        config.request_body_byte = try parseByte(value);
        config.request_body_byte_explicit = true;
    } else if (std.mem.eql(u8, name, "--content-type")) {
        try claim(&seen.content_type);
        config.content_type = value;
    } else if (std.mem.eql(u8, name, "--expect-status")) {
        try claim(&seen.expected_status);
        config.expected_status = try parseUnsigned(u16, value, 200, 599);
    } else if (std.mem.eql(u8, name, "--expect-body")) {
        try claim(&seen.expected_body);
        config.expected_body = value;
        config.expected_body_explicit = true;
    } else if (std.mem.eql(u8, name, "--expect-body-bytes")) {
        try claim(&seen.expected_body_bytes);
        config.expected_body_bytes = try parseUnsigned(
            u64,
            value,
            0,
            expected_hashed_body_bytes_max,
        );
    } else if (std.mem.eql(u8, name, "--expect-sha256")) {
        try claim(&seen.expected_sha256);
        config.expected_sha256 = try parseSha256(value);
    } else {
        try parseExecutionOption(config, seen, name, value);
    }
}

fn parseExecutionOption(
    config: *Config,
    seen: *Seen,
    name: []const u8,
    value: []const u8,
) !void {
    if (std.mem.eql(u8, name, "--requests")) {
        try claim(&seen.requests);
        config.requests = try parseUnsigned(u64, value, 1, requests_max);
    } else if (std.mem.eql(u8, name, "--concurrency")) {
        try claim(&seen.concurrency);
        config.concurrency = try parseUnsigned(u16, value, 1, concurrency_max);
    } else if (std.mem.eql(u8, name, "--rate")) {
        try claim(&seen.rate);
        config.rate = try parseUnsigned(u64, value, 1, rate_max);
    } else if (std.mem.eql(u8, name, "--timeout-ms")) {
        try claim(&seen.timeout_ms);
        config.timeout_ms = try parseUnsigned(u32, value, 1, timeout_ms_max);
    } else if (std.mem.eql(u8, name, "--scheduling")) {
        try claim(&seen.scheduling);
        config.scheduling = try parseScheduling(value);
    } else if (std.mem.eql(u8, name, "--connections")) {
        try claim(&seen.connections);
        config.connections = try parseConnections(value);
    } else {
        return error.UnknownOption;
    }
}

fn validate(config: Config) !void {
    if (config.host.len == 0 or config.host.len > host_bytes_max) return error.InvalidHost;
    if (config.path.len == 0 or config.path.len > path_bytes_max or config.path[0] != '/') {
        return error.InvalidPath;
    }
    if (config.method.len == 0 or config.method.len > 16) return error.InvalidMethod;
    if (config.request_body.len > request_bytes_max / 2) return error.RequestBodyTooLarge;
    if (config.expected_body.len > expected_body_bytes_max) return error.ExpectedBodyTooLarge;
    if (config.content_type.len == 0 or config.content_type.len > 255) {
        return error.InvalidContentType;
    }
    if (!headerValueValid(config.host) or !headerValueValid(config.content_type)) {
        return error.InvalidHeaderValue;
    }
    if (!tokenValid(config.method)) return error.InvalidMethod;
    if (!originTargetValid(config.path)) return error.InvalidPath;
    if (std.mem.eql(u8, config.method, "HEAD") or
        std.mem.eql(u8, config.method, "CONNECT")) return error.UnsupportedMethod;
    if (config.concurrency > config.requests) return error.ConcurrencyExceedsRequests;
    if (config.scheduling == .constant_rate and config.rate == 0) return error.RateRequired;
    if (config.scheduling == .closed_loop and config.rate != 0) return error.RateNotAllowed;
    if (config.expected_status == 304) return error.UnsupportedStatus;
    if (config.calibration and config.scheduling != .constant_rate) {
        return error.CalibrationRequiresConstantRate;
    }
    if (config.calibration and config.requests < 1_000) return error.CalibrationTooShort;
    const request_modes = @as(u8, @intFromBool(config.request_body_explicit)) +
        @as(u8, @intFromBool(config.request_body_file != null)) +
        @as(u8, @intFromBool(config.request_body_bytes != null));
    if (request_modes > 1) return error.ConflictingRequestBodies;
    if (config.request_body_file) |path| {
        if (path.len == 0 or path.len > std.fs.max_path_bytes) return error.InvalidBodyFile;
    }
    if (config.request_body_bytes == null and config.request_body_byte_explicit) {
        return error.RequestBodyByteWithoutLength;
    }
    const hash_length = config.expected_body_bytes != null;
    const hash_digest = config.expected_sha256 != null;
    if (hash_length != hash_digest) return error.IncompleteExpectedHash;
    if (hash_length and config.expected_body_explicit) return error.ConflictingExpectedBodies;
    const expected_length = config.expected_body_bytes orelse config.expected_body.len;
    if ((config.expected_status == 204 or config.expected_status == 205) and
        expected_length != 0) return error.ExpectedBodyForbidden;
}

fn parseIpv4(value: []const u8) ![4]u8 {
    var result: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, value, '.');
    for (&result) |*part| {
        const raw = parts.next() orelse return error.InvalidAddress;
        part.* = parseUnsigned(u8, raw, 0, 255) catch return error.InvalidAddress;
    }
    if (parts.next() != null) return error.InvalidAddress;
    return result;
}

fn parseUnsigned(comptime T: type, value: []const u8, minimum: T, maximum: T) !T {
    if (value.len == 0) return error.InvalidNumber;
    const parsed = std.fmt.parseUnsigned(T, value, 10) catch return error.InvalidNumber;
    if (parsed < minimum or parsed > maximum) return error.NumberOutOfRange;
    return parsed;
}

fn parseScheduling(value: []const u8) !Scheduling {
    if (std.mem.eql(u8, value, "closed-loop")) return .closed_loop;
    if (std.mem.eql(u8, value, "constant-rate")) return .constant_rate;
    return error.InvalidScheduling;
}

fn parseConnections(value: []const u8) !Connections {
    if (std.mem.eql(u8, value, "keepalive")) return .keepalive;
    if (std.mem.eql(u8, value, "churn")) return .churn;
    return error.InvalidConnections;
}

fn parseByte(value: []const u8) !u8 {
    if (value.len != 2) return error.InvalidByte;
    return std.fmt.parseUnsigned(u8, value, 16) catch error.InvalidByte;
}

fn parseSha256(value: []const u8) ![32]u8 {
    if (value.len != 64) return error.InvalidSha256;
    var digest: [32]u8 = undefined;
    for (&digest, 0..) |*byte, index| {
        byte.* = std.fmt.parseUnsigned(u8, value[index * 2 .. index * 2 + 2], 16) catch {
            return error.InvalidSha256;
        };
    }
    return digest;
}

fn addHeader(config: *Config, raw: []const u8) !void {
    if (config.header_count == headers_max) return error.TooManyHeaders;
    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return error.InvalidHeader;
    const name = raw[0..colon];
    const value = std.mem.trim(u8, raw[colon + 1 ..], " \t");
    if (name.len == 0 or name.len > header_name_bytes_max or
        value.len > header_value_bytes_max or !headerNameValid(name) or
        !customHeaderValueValid(value)) return error.InvalidHeader;
    inline for (.{
        "host", "content-length", "transfer-encoding", "connection", "content-type",
    }) |forbidden| {
        if (std.ascii.eqlIgnoreCase(name, forbidden)) return error.ForbiddenHeader;
    }
    config.headers[config.header_count] = .{ .name = name, .value = value };
    config.header_count += 1;
}

fn headerNameValid(value: []const u8) bool {
    for (value) |byte| switch (byte) {
        'a'...'z',
        'A'...'Z',
        '0'...'9',
        '!',
        '#',
        '$',
        '%',
        '&',
        '\'',
        '*',
        '+',
        '-',
        '.',
        '^',
        '_',
        '`',
        '|',
        '~',
        => {},
        else => return false,
    };
    return value.len != 0;
}

fn customHeaderValueValid(value: []const u8) bool {
    for (value) |byte| if ((byte < 0x20 and byte != '\t') or byte > 0x7e) return false;
    return true;
}

fn originTargetValid(value: []const u8) bool {
    if (value.len == 0 or value[0] != '/') return false;
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        if (byte == '%') {
            if (index + 2 >= value.len or !std.ascii.isHex(value[index + 1]) or
                !std.ascii.isHex(value[index + 2])) return false;
            index += 2;
            continue;
        }
        switch (byte) {
            'a'...'z',
            'A'...'Z',
            '0'...'9',
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
            ':',
            '@',
            '/',
            '?',
            => {},
            else => return false,
        }
    }
    return true;
}

fn claim(seen: *bool) !void {
    if (seen.*) return error.DuplicateOption;
    seen.* = true;
}

fn headerValueValid(value: []const u8) bool {
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

fn tokenValid(value: []const u8) bool {
    for (value) |byte| switch (byte) {
        'A'...'Z' => {},
        else => return false,
    };
    return true;
}

test "configuration validates bounds and scheduling contract" {
    var config = Config{};
    try validate(config);
    config.scheduling = .constant_rate;
    try std.testing.expectError(error.RateRequired, validate(config));
    config.rate = 1;
    try validate(config);
    config.scheduling = .closed_loop;
    try std.testing.expectError(error.RateNotAllowed, validate(config));
}

test "configuration rejects ambiguous bodies and unsupported methods" {
    var config = Config{
        .request_body = "inline",
        .request_body_explicit = true,
        .request_body_bytes = 64 * 1024,
    };
    try std.testing.expectError(error.ConflictingRequestBodies, validate(config));
    config = .{ .expected_body_bytes = 1 };
    try std.testing.expectError(error.IncompleteExpectedHash, validate(config));
    config = .{ .method = "HEAD" };
    try std.testing.expectError(error.UnsupportedMethod, validate(config));
    config = .{ .path = "/fragment#forbidden" };
    try std.testing.expectError(error.InvalidPath, validate(config));
    config = .{ .path = "/bad%2" };
    try std.testing.expectError(error.InvalidPath, validate(config));
    config = .{ .path = "/bad\\target" };
    try std.testing.expectError(error.InvalidPath, validate(config));
    config = .{ .path = "/ok/a%2Fz?x=1&y=two" };
    try validate(config);
    config = .{ .expected_status = 304 };
    try std.testing.expectError(error.UnsupportedStatus, validate(config));
    config = .{ .expected_status = 205, .expected_body = "bad" };
    try std.testing.expectError(error.ExpectedBodyForbidden, validate(config));
}

test "SHA-256 and generated byte parsers are exact" {
    const digest = try parseSha256("00" ** 31 ++ "ff");
    try std.testing.expectEqual(@as(u8, 0xff), digest[31]);
    try std.testing.expectEqual(@as(u8, 0xa5), try parseByte("a5"));
    try std.testing.expectError(error.InvalidSha256, parseSha256("00"));
    try std.testing.expectError(error.InvalidByte, parseByte("xyz"));
}

test "custom headers are repeated bounded and cannot override framing" {
    var config = Config{};
    try addHeader(&config, "Accept-Encoding: gzip");
    try addHeader(&config, "Origin: https://app.example");
    try std.testing.expectEqual(@as(usize, 2), config.headerSlice().len);
    try std.testing.expectError(error.ForbiddenHeader, addHeader(&config, "Host: attacker"));
    try std.testing.expectError(
        error.ForbiddenHeader,
        addHeader(&config, "Content-Length: 0"),
    );
    try std.testing.expectError(error.InvalidHeader, addHeader(&config, "X-Test: bad\r\nnext"));
}

test "IPv4 parser is exact" {
    try std.testing.expectEqual([4]u8{ 192, 0, 2, 9 }, try parseIpv4("192.0.2.9"));
    try std.testing.expectError(error.InvalidAddress, parseIpv4("192.0.2"));
    try std.testing.expectError(error.InvalidAddress, parseIpv4("192.0.2.256"));
    try std.testing.expectError(error.InvalidAddress, parseIpv4("192.0.2.9.1"));
}
