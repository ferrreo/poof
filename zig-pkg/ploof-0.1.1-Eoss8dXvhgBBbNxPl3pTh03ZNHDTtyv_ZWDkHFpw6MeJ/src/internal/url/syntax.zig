const std = @import("std");

pub const url_bytes_hard_max: u32 = 64 * 1024;
pub const url_bytes_standard_max: u32 = 8 * 1024;

pub const ValidationError = error{
    Empty,
    TooLong,
    NonAscii,
    ForbiddenByte,
    MalformedPercentEscape,
    EncodedBackslash,
    InvalidLocalReference,
    UnsupportedScheme,
    InvalidAuthority,
    InvalidHost,
    InvalidPort,
};

pub const BuildError = error{
    EmptyComponent,
    InvalidComponent,
    InvalidOrder,
    InvalidUtf8,
    NoSpace,
    TooLong,
};

pub const Scheme = enum(u1) {
    http,
    https,

    pub fn wire(scheme: Scheme) []const u8 {
        return switch (scheme) {
            .http => "http",
            .https => "https",
        };
    }

    pub fn defaultPort(scheme: Scheme) u16 {
        return switch (scheme) {
            .http => 80,
            .https => 443,
        };
    }
};

pub const Host = union(enum) {
    dns: []const u8,
    ipv4: [4]u8,
    ipv6: [16]u8,

    pub fn eql(left: Host, right: Host) bool {
        return switch (left) {
            .dns => |left_dns| switch (right) {
                .dns => |right_dns| std.ascii.eqlIgnoreCase(left_dns, right_dns),
                else => false,
            },
            .ipv4 => |left_ipv4| switch (right) {
                .ipv4 => |right_ipv4| std.mem.eql(u8, &left_ipv4, &right_ipv4),
                else => false,
            },
            .ipv6 => |left_ipv6| switch (right) {
                .ipv6 => |right_ipv6| std.mem.eql(u8, &left_ipv6, &right_ipv6),
                else => false,
            },
        };
    }
};

pub const ParsedWeb = struct {
    scheme: Scheme,
    host: Host,
    port: u16,
    authority_end: u32,

    pub fn sameOrigin(left: ParsedWeb, right: ParsedWeb) bool {
        if (left.scheme != right.scheme) return false;
        if (left.port != right.port) return false;
        return left.host.eql(right.host);
    }
};

const Component = enum(u2) {
    path,
    query,
    fragment,
};

const CharClass = packed struct(u8) {
    pchar: bool = false,
    slash: bool = false,
    question: bool = false,
    percent: bool = false,
    reserved: u4 = 0,
};

const character_classes = buildCharacterClasses();

pub fn validateLocal(input: []const u8, bytes_max: u32) ValidationError!void {
    try validateLength(input, bytes_max);
    switch (input[0]) {
        '/' => {
            if (input.len > 1 and input[1] == '/') return error.InvalidLocalReference;
            try validateTail(input, 0, .path);
        },
        '?' => try validateTail(input, 1, .query),
        '#' => try validateTail(input, 1, .fragment),
        else => return error.InvalidLocalReference,
    }
}

pub fn parseWeb(input: []const u8, bytes_max: u32) ValidationError!ParsedWeb {
    try validateLength(input, bytes_max);
    const scheme: Scheme, const authority_start: usize = if (std.mem.startsWith(
        u8,
        input,
        "https://",
    )) .{ .https, "https://".len } else if (std.mem.startsWith(
        u8,
        input,
        "http://",
    )) .{ .http, "http://".len } else return error.UnsupportedScheme;

    const authority_end = findAuthorityEnd(input, authority_start);
    if (authority_end == authority_start) return error.InvalidAuthority;
    const authority = try parseAuthority(input[authority_start..authority_end], scheme);
    try validateWebTail(input, authority_end);
    return .{
        .scheme = scheme,
        .host = authority.host,
        .port = authority.port,
        .authority_end = @intCast(authority_end),
    };
}

pub fn parseHost(input: []const u8) ValidationError!Host {
    if (input.len == 0) return error.InvalidHost;
    if (input[0] == '[') return parseBracketedHost(input);
    if (std.mem.indexOfScalar(u8, input, ':') != null) return error.InvalidHost;
    return parseUnbracketedHost(input);
}

pub fn validateOrigin(input: []const u8) ValidationError!ParsedWeb {
    const parsed = try parseWeb(input, url_bytes_standard_max);
    if (parsed.scheme != .https) return error.UnsupportedScheme;
    if (parsed.authority_end != input.len) return error.InvalidAuthority;
    return parsed;
}

pub fn encodedLength(input: []const u8) BuildError!u32 {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    if (input.len > url_bytes_hard_max) return error.TooLong;
    var length: u32 = 0;
    for (input) |byte| {
        const addition: u32 = if (isUnreserved(byte)) 1 else 3;
        length = std.math.add(u32, length, addition) catch return error.TooLong;
        if (length > url_bytes_hard_max) return error.TooLong;
    }
    return length;
}

pub fn writeEncoded(input: []const u8, output: []u8) BuildError!u32 {
    const length = try encodedLength(input);
    if (output.len < length) return error.NoSpace;
    var written: u32 = 0;
    for (input) |byte| {
        if (isUnreserved(byte)) {
            output[written] = byte;
            written += 1;
        } else {
            output[written] = '%';
            output[written + 1] = upper_hex[byte >> 4];
            output[written + 2] = upper_hex[byte & 0x0f];
            written += 3;
        }
    }
    std.debug.assert(written == length);
    return written;
}

pub fn validateOpaqueComponent(input: []const u8) ValidationError!void {
    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (byte >= 0x80) return error.NonAscii;
        if (isUnreserved(byte)) continue;
        if (byte != '%') return error.ForbiddenByte;
        index = try validateOpaqueEscape(input, index);
    }
}

fn validateLength(input: []const u8, bytes_max: u32) ValidationError!void {
    std.debug.assert(bytes_max > 0);
    std.debug.assert(bytes_max <= url_bytes_hard_max);
    if (input.len == 0) return error.Empty;
    if (input.len > bytes_max) return error.TooLong;
}

fn validateWebTail(input: []const u8, start: usize) ValidationError!void {
    if (start == input.len) return;
    switch (input[start]) {
        '/' => try validateTail(input, start, .path),
        '?' => try validateTail(input, start + 1, .query),
        '#' => try validateTail(input, start + 1, .fragment),
        else => return error.ForbiddenByte,
    }
}

fn validateTail(input: []const u8, start: usize, initial: Component) ValidationError!void {
    std.debug.assert(start <= input.len);
    var component = initial;
    var index = start;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (byte >= 0x80) return error.NonAscii;
        const class = character_classes[byte];
        if (class.percent) {
            index = try validateEscape(input, index);
            continue;
        }
        if (component == .path and class.question) {
            component = .query;
            continue;
        }
        if (component != .fragment and byte == '#') {
            component = .fragment;
            continue;
        }
        if (!componentAllows(component, class)) return error.ForbiddenByte;
    }
}

fn componentAllows(component: Component, class: CharClass) bool {
    return switch (component) {
        .path => class.pchar or class.slash,
        .query, .fragment => class.pchar or class.slash or class.question,
    };
}

fn validateEscape(input: []const u8, index: usize) ValidationError!usize {
    if (index + 2 >= input.len) return error.MalformedPercentEscape;
    const high = hexValue(input[index + 1]) orelse return error.MalformedPercentEscape;
    const low = hexValue(input[index + 2]) orelse return error.MalformedPercentEscape;
    if ((high << 4) | low == '\\') return error.EncodedBackslash;
    return index + 2;
}

fn validateOpaqueEscape(input: []const u8, index: usize) ValidationError!usize {
    if (index + 2 >= input.len) return error.MalformedPercentEscape;
    _ = hexValue(input[index + 1]) orelse return error.MalformedPercentEscape;
    _ = hexValue(input[index + 2]) orelse return error.MalformedPercentEscape;
    return index + 2;
}

fn findAuthorityEnd(input: []const u8, start: usize) usize {
    var index = start;
    while (index < input.len) : (index += 1) {
        switch (input[index]) {
            '/', '?', '#' => return index,
            else => {},
        }
    }
    return input.len;
}

const ParsedAuthority = struct {
    host: Host,
    port: u16,
};

fn parseAuthority(input: []const u8, scheme: Scheme) ValidationError!ParsedAuthority {
    if (std.mem.indexOfScalar(u8, input, '@') != null) return error.InvalidAuthority;
    if (input[0] == '[') return parseBracketedAuthority(input, scheme);
    const colon = std.mem.indexOfScalar(u8, input, ':');
    if (colon) |index| {
        if (std.mem.indexOfScalarPos(u8, input, index + 1, ':') != null) {
            return error.InvalidAuthority;
        }
    }
    const host_end = colon orelse input.len;
    const host = try parseUnbracketedHost(input[0..host_end]);
    const port = if (colon) |index|
        try parsePort(input[index + 1 ..])
    else
        scheme.defaultPort();
    return .{ .host = host, .port = port };
}

fn parseBracketedAuthority(input: []const u8, scheme: Scheme) ValidationError!ParsedAuthority {
    const close = std.mem.indexOfScalar(u8, input, ']') orelse return error.InvalidHost;
    const host = try parseBracketedHost(input[0 .. close + 1]);
    if (close + 1 == input.len) return .{ .host = host, .port = scheme.defaultPort() };
    if (input[close + 1] != ':') return error.InvalidAuthority;
    const port = try parsePort(input[close + 2 ..]);
    return .{ .host = host, .port = port };
}

fn parseBracketedHost(input: []const u8) ValidationError!Host {
    if (input.len < 4) return error.InvalidHost;
    if (input[0] != '[' or input[input.len - 1] != ']') return error.InvalidHost;
    const literal = input[1 .. input.len - 1];
    for (literal) |byte| {
        if (!(std.ascii.isHex(byte) or byte == ':' or byte == '.')) return error.InvalidHost;
    }
    const parsed = std.Io.net.IpAddress.parse(literal, 0) catch return error.InvalidHost;
    return switch (parsed) {
        .ip4 => error.InvalidHost,
        .ip6 => |ipv6| .{ .ipv6 = ipv6.bytes },
    };
}

fn parseUnbracketedHost(input: []const u8) ValidationError!Host {
    if (input.len == 0 or input.len > 253) return error.InvalidHost;
    if (parseIpv4(input)) |ipv4| return .{ .ipv4 = ipv4 };
    if (endsInNumber(input)) return error.InvalidHost;
    try validateDnsName(input);
    return .{ .dns = input };
}

fn validateDnsName(input: []const u8) ValidationError!void {
    var labels = std.mem.splitScalar(u8, input, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return error.InvalidHost;
        if (!std.ascii.isAlphanumeric(label[0])) return error.InvalidHost;
        if (!std.ascii.isAlphanumeric(label[label.len - 1])) return error.InvalidHost;
        for (label, 0..) |byte, index| {
            if (index == 0 or index + 1 == label.len) continue;
            if (!(std.ascii.isAlphanumeric(byte) or byte == '-')) return error.InvalidHost;
        }
        if (startsWithPunycodePrefix(label) and !validPunycodeLabel(label[4..])) {
            return error.InvalidHost;
        }
    }
}

fn startsWithPunycodePrefix(label: []const u8) bool {
    return label.len >= 4 and std.ascii.eqlIgnoreCase(label[0..4], "xn--");
}

fn validPunycodeLabel(payload: []const u8) bool {
    if (payload.len == 0) return false;
    const delimiter = std.mem.lastIndexOfScalar(u8, payload, '-');
    var output_count: u64 = 0;
    var cursor: usize = 0;
    if (delimiter) |index| {
        if (index == 0 or index + 1 == payload.len) return false;
        output_count = index;
        cursor = index + 1;
    }

    var codepoint: u64 = 128;
    var insertion: u64 = 0;
    var bias: u64 = 72;
    while (cursor < payload.len) {
        const previous = insertion;
        var weight: u64 = 1;
        var k: u64 = 36;
        while (true) : (k += 36) {
            if (cursor == payload.len) return false;
            const digit = punycodeDigit(payload[cursor]) orelse return false;
            cursor += 1;
            const scaled = std.math.mul(u64, digit, weight) catch return false;
            insertion = std.math.add(u64, insertion, scaled) catch return false;
            const threshold = punycodeThreshold(k, bias);
            if (digit < threshold) break;
            weight = std.math.mul(u64, weight, 36 - threshold) catch return false;
            if (k > std.math.maxInt(u64) - 36) return false;
        }
        const next_count = output_count + 1;
        bias = punycodeAdapt(insertion - previous, next_count, previous == 0) orelse {
            return false;
        };
        codepoint = std.math.add(u64, codepoint, insertion / next_count) catch return false;
        if (!validPunycodeScalar(codepoint)) return false;
        insertion %= next_count;
        output_count = next_count;
        insertion += 1;
    }
    return output_count > 0;
}

fn punycodeThreshold(k: u64, bias: u64) u64 {
    if (k <= bias) return 1;
    const distance = k - bias;
    if (distance <= 1) return 1;
    if (distance >= 26) return 26;
    return distance;
}

fn punycodeAdapt(delta_input: u64, points: u64, first: bool) ?u64 {
    var delta = delta_input / (if (first) @as(u64, 700) else 2);
    delta = std.math.add(u64, delta, delta / points) catch return null;
    var k: u64 = 0;
    while (delta > 455) {
        delta /= 35;
        k = std.math.add(u64, k, 36) catch return null;
    }
    const scaled = std.math.mul(u64, 36, delta) catch return null;
    const tail = scaled / (delta + 38);
    return std.math.add(u64, k, tail) catch null;
}

fn punycodeDigit(byte: u8) ?u64 {
    return switch (byte) {
        'a'...'z' => byte - 'a',
        'A'...'Z' => byte - 'A',
        '0'...'9' => byte - '0' + 26,
        else => null,
    };
}

fn validPunycodeScalar(value: u64) bool {
    if (value < 0xa0 or value > 0x10ffff) return false;
    if (value >= 0xd800 and value <= 0xdfff) return false;
    if (value >= 0xfdd0 and value <= 0xfdef) return false;
    return value & 0xffff != 0xfffe and value & 0xffff != 0xffff;
}

fn parseIpv4(input: []const u8) ?[4]u8 {
    var output: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, input, '.');
    var count: u8 = 0;
    while (parts.next()) |part| {
        if (count == output.len) return null;
        if (part.len == 0 or (part.len > 1 and part[0] == '0')) return null;
        var value: u16 = 0;
        for (part) |byte| {
            if (!std.ascii.isDigit(byte)) return null;
            value = value * 10 + byte - '0';
            if (value > 255) return null;
        }
        output[count] = @intCast(value);
        count += 1;
    }
    if (count != output.len) return null;
    return output;
}

fn endsInNumber(input: []const u8) bool {
    const start = if (std.mem.lastIndexOfScalar(u8, input, '.')) |dot| dot + 1 else 0;
    const label = input[start..];
    if (label.len == 0) return false;
    if (label.len > 2 and label[0] == '0' and (label[1] == 'x' or label[1] == 'X')) {
        for (label[2..]) |byte| if (!std.ascii.isHex(byte)) return false;
        return true;
    }
    for (label) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn parsePort(input: []const u8) ValidationError!u16 {
    if (input.len == 0) return error.InvalidPort;
    if (input.len > 1 and input[0] == '0') return error.InvalidPort;
    var value: u32 = 0;
    for (input) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidPort;
        value = value * 10 + byte - '0';
        if (value > std.math.maxInt(u16)) return error.InvalidPort;
    }
    return @intCast(value);
}

fn buildCharacterClasses() [256]CharClass {
    var table = [_]CharClass{.{}} ** 256;
    for (0..256) |index| {
        const byte: u8 = @intCast(index);
        table[index].pchar = isUnreserved(byte) or isSubDelimiter(byte) or
            byte == ':' or byte == '@';
        table[index].slash = byte == '/';
        table[index].question = byte == '?';
        table[index].percent = byte == '%';
    }
    return table;
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-', '.', '_', '~' => true,
        else => false,
    };
}

fn isSubDelimiter(byte: u8) bool {
    return switch (byte) {
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        else => false,
    };
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

const upper_hex = "0123456789ABCDEF";

comptime {
    std.debug.assert(@sizeOf(CharClass) == 1);
    std.debug.assert(url_bytes_standard_max <= url_bytes_hard_max);
}
