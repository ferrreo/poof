const std = @import("std");
const address = @import("../../address.zig");
const syntax = @import("syntax.zig");

pub const ParseError = error{InvalidAuthority};

pub const Scheme = enum(u1) {
    http,
    https,
};

pub const Text = struct {
    bytes: []const u8,
    quoted: bool = false,

    pub fn raw(bytes: []const u8) Text {
        return .{ .bytes = bytes };
    }

    pub fn quotedValue(bytes: []const u8) Text {
        return .{ .bytes = bytes, .quoted = true };
    }

    pub fn valid(text: Text) bool {
        if (!text.quoted) return true;
        var cursor = text.iterator();
        while (cursor.next()) |_| {}
        return cursor.valid;
    }

    pub fn iterator(text: Text) TextIterator {
        return .{ .text = text };
    }

    fn write(text: Text, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var bytes = text.iterator();
        while (bytes.next()) |byte| try writer.writeByte(byte);
        std.debug.assert(bytes.valid);
    }

    fn sub(text: Text, start: usize, end: usize) Text {
        std.debug.assert(start <= end);
        std.debug.assert(end <= text.bytes.len);
        return .{ .bytes = text.bytes[start..end], .quoted = text.quoted };
    }
};

pub const TextIterator = struct {
    text: Text,
    index: usize = 0,
    valid: bool = true,

    pub fn next(iterator: *TextIterator) ?u8 {
        if (!iterator.valid or iterator.index == iterator.text.bytes.len) return null;
        const byte = iterator.text.bytes[iterator.index];
        iterator.index += 1;
        if (!iterator.text.quoted) return byte;
        if (byte != '\\') {
            if (!isQuotedText(byte)) iterator.valid = false;
            return if (iterator.valid) byte else null;
        }
        if (iterator.index == iterator.text.bytes.len) {
            iterator.valid = false;
            return null;
        }
        const escaped = iterator.text.bytes[iterator.index];
        iterator.index += 1;
        if (!isQuotedPairByte(escaped)) iterator.valid = false;
        return if (iterator.valid) escaped else null;
    }
};

pub const Host = union(enum) {
    reg_name: Text,
    ip: address.Address,
    ipv_future: Text,

    pub fn eql(left: Host, right: Host) bool {
        return switch (left) {
            .reg_name => |a| switch (right) {
                .reg_name => |b| canonicalRegNameEql(a, b),
                else => false,
            },
            .ip => |a| switch (right) {
                .ip => |b| a.eql(b),
                else => false,
            },
            .ipv_future => |a| switch (right) {
                .ipv_future => |b| decodedEqlIgnoreCase(a, b),
                else => false,
            },
        };
    }

    pub fn valid(host: Host) bool {
        return switch (host) {
            .reg_name => |text| validRegName(text),
            .ip => true,
            .ipv_future => |text| validIpvFuture(text),
        };
    }

    pub fn format(host: Host, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (host) {
            .reg_name => |text| try text.write(writer),
            .ip => |ip| try ip.format(writer),
            .ipv_future => |text| try text.write(writer),
        }
    }

    pub fn formatInto(host: Host, output: []u8) std.Io.Writer.Error![]const u8 {
        var writer = std.Io.Writer.fixed(output);
        try host.format(&writer);
        return writer.buffered();
    }
};

pub const Authority = struct {
    host: Host,
    port: u16,

    pub fn eql(left: Authority, right: Authority) bool {
        return left.port == right.port and left.host.eql(right.host);
    }

    pub fn format(value: Authority, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const bracketed = switch (value.host) {
            .ip => |ip| ip == .ipv6,
            .ipv_future => true,
            .reg_name => false,
        };
        if (bracketed) try writer.writeAll("[");
        try value.host.format(writer);
        if (bracketed) try writer.writeAll("]");
        try writer.print(":{d}", .{value.port});
    }

    pub fn formatInto(value: Authority, output: []u8) std.Io.Writer.Error![]const u8 {
        var writer = std.Io.Writer.fixed(output);
        try value.format(&writer);
        return writer.buffered();
    }

    pub fn formatCanonical(
        value: Authority,
        writer: *std.Io.Writer,
    ) (ParseError || std.Io.Writer.Error)!void {
        const bracketed = switch (value.host) {
            .ip => |ip| ip == .ipv6,
            .ipv_future => true,
            .reg_name => false,
        };
        if (bracketed) try writer.writeAll("[");
        try formatCanonicalHost(value.host, writer);
        if (bracketed) try writer.writeAll("]");
        try writer.print(":{d}", .{value.port});
    }

    pub fn formatCanonicalInto(
        value: Authority,
        output: []u8,
    ) (ParseError || std.Io.Writer.Error)![]const u8 {
        var writer = std.Io.Writer.fixed(output);
        try value.formatCanonical(&writer);
        return writer.buffered();
    }
};

fn formatCanonicalHost(
    host: Host,
    writer: *std.Io.Writer,
) (ParseError || std.Io.Writer.Error)!void {
    if (!host.valid()) return error.InvalidAuthority;
    switch (host) {
        .reg_name => |text| {
            var iterator = CanonicalIterator.init(text);
            while (iterator.next()) |byte| try writer.writeByte(byte);
        },
        .ip => |ip| try ip.format(writer),
        .ipv_future => |text| {
            var iterator = text.iterator();
            while (iterator.next()) |byte| try writer.writeByte(syntax.asciiLower(byte));
            std.debug.assert(iterator.valid);
        },
    }
}

pub fn parse(raw: []const u8, scheme: Scheme) ParseError!Authority {
    return parseText(Text.raw(raw), scheme);
}

pub fn parseText(text: Text, scheme: Scheme) ParseError!Authority {
    if (!text.valid() or text.bytes.len == 0) return error.InvalidAuthority;
    var iterator = text.iterator();
    const first = iterator.next() orelse return error.InvalidAuthority;
    if (first == '[') return parseBracketed(text, scheme);
    return parseRegName(text, scheme);
}

pub fn parseScheme(raw: []const u8) ?Scheme {
    if (syntax.eqlIgnoreCase(raw, "http")) return .http;
    if (syntax.eqlIgnoreCase(raw, "https")) return .https;
    return null;
}

pub fn defaultPort(scheme: Scheme) u16 {
    return switch (scheme) {
        .http => 80,
        .https => 443,
    };
}

fn parseBracketed(text: Text, scheme: Scheme) ParseError!Authority {
    var iterator = text.iterator();
    _ = iterator.next().?;
    const literal_start = iterator.index;
    var literal_end: ?usize = null;
    while (iterator.next()) |byte| {
        if (byte == ']') {
            literal_end = rawByteStart(text, iterator.index);
            break;
        }
    }
    const end = literal_end orelse return error.InvalidAuthority;
    if (end == literal_start) return error.InvalidAuthority;
    const literal = text.sub(literal_start, end);
    const host = try parseLiteral(literal);
    const port = try parseSuffixPort(text, iterator.index, scheme);
    return .{ .host = host, .port = port };
}

fn parseRegName(text: Text, scheme: Scheme) ParseError!Authority {
    var iterator = text.iterator();
    var colon_raw: ?usize = null;
    while (iterator.next()) |byte| {
        const start = rawByteStart(text, iterator.index);
        if (byte == ':') {
            if (colon_raw != null) return error.InvalidAuthority;
            colon_raw = start;
            continue;
        }
        if (isForbiddenAuthorityByte(byte)) return error.InvalidAuthority;
    }
    if (!iterator.valid) return error.InvalidAuthority;
    const host_end = colon_raw orelse text.bytes.len;
    const host_text = text.sub(0, host_end);
    if (!validRegName(host_text)) return error.InvalidAuthority;
    const host = parseIpv4(host_text) orelse Host{ .reg_name = host_text };
    const port_start = if (colon_raw) |colon| encodedByteEnd(text, colon) else null;
    const port = if (port_start) |start|
        try parsePort(text.sub(start, text.bytes.len), scheme)
    else
        defaultPort(scheme);
    return .{ .host = host, .port = port };
}

fn parseLiteral(literal: Text) ParseError!Host {
    var iterator = literal.iterator();
    const first = iterator.next() orelse return error.InvalidAuthority;
    if (first == 'v' or first == 'V') {
        if (!validIpvFuture(literal)) return error.InvalidAuthority;
        return .{ .ipv_future = literal };
    }
    var buffer: [45]u8 = undefined;
    const decoded = decodeInto(literal, &buffer) orelse return error.InvalidAuthority;
    const ip = address.Address.parse(decoded) catch return error.InvalidAuthority;
    if (ip == .ipv4 and std.mem.indexOfScalar(u8, decoded, ':') == null) {
        return error.InvalidAuthority;
    }
    return switch (ip) {
        .ipv4 => .{ .ip = ip },
        .ipv6 => .{ .ip = ip },
    };
}

fn parseSuffixPort(text: Text, start: usize, scheme: Scheme) ParseError!u16 {
    if (start == text.bytes.len) return defaultPort(scheme);
    const suffix = text.sub(start, text.bytes.len);
    var iterator = suffix.iterator();
    if (iterator.next() != ':') return error.InvalidAuthority;
    const port_start = iterator.index;
    return parsePort(suffix.sub(port_start, suffix.bytes.len), scheme);
}

fn parsePort(text: Text, scheme: Scheme) ParseError!u16 {
    var iterator = text.iterator();
    var value: u32 = 0;
    var digits: u8 = 0;
    while (iterator.next()) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidAuthority;
        value = value * 10 + byte - '0';
        if (value > std.math.maxInt(u16)) return error.InvalidAuthority;
        digits +|= 1;
    }
    if (!iterator.valid) return error.InvalidAuthority;
    return if (digits == 0) defaultPort(scheme) else @intCast(value);
}

fn parseIpv4(text: Text) ?Host {
    var buffer: [15]u8 = undefined;
    const decoded = decodeRegNameInto(text, &buffer) orelse return null;
    const ip = address.Address.parse(decoded) catch return null;
    return switch (ip) {
        .ipv4 => .{ .ip = ip },
        .ipv6 => null,
    };
}

fn decodeRegNameInto(text: Text, output: []u8) ?[]const u8 {
    var iterator = text.iterator();
    var written: usize = 0;
    while (iterator.next()) |raw| {
        var byte = raw;
        if (raw == '%') {
            const high = iterator.next() orelse return null;
            const low = iterator.next() orelse return null;
            const high_value = hexValue(high);
            const low_value = hexValue(low);
            if (high_value >= 16 or low_value >= 16) return null;
            byte = (high_value << 4) | low_value;
        }
        if (written == output.len) return null;
        output[written] = byte;
        written += 1;
    }
    if (!iterator.valid) return null;
    return output[0..written];
}

fn validRegName(text: Text) bool {
    var iterator = text.iterator();
    var count: usize = 0;
    while (iterator.next()) |byte| {
        count += 1;
        if (byte == '%') {
            const high = iterator.next() orelse return false;
            const low = iterator.next() orelse return false;
            if (hexValue(high) >= 16 or hexValue(low) >= 16) return false;
        } else if (!isRegNameByte(byte)) return false;
    }
    return iterator.valid and count != 0;
}

fn validIpvFuture(text: Text) bool {
    var iterator = text.iterator();
    const marker = iterator.next() orelse return false;
    if (marker != 'v' and marker != 'V') return false;
    var version_digits: usize = 0;
    while (iterator.next()) |byte| {
        if (byte == '.') break;
        if (hexValue(byte) >= 16) return false;
        version_digits += 1;
    }
    if (version_digits == 0) return false;
    var address_bytes: usize = 0;
    while (iterator.next()) |byte| {
        if (!isIpvFutureByte(byte)) return false;
        address_bytes += 1;
    }
    return iterator.valid and address_bytes != 0;
}

fn decodeInto(text: Text, output: []u8) ?[]const u8 {
    var iterator = text.iterator();
    var written: usize = 0;
    while (iterator.next()) |byte| {
        if (written == output.len) return null;
        output[written] = byte;
        written += 1;
    }
    if (!iterator.valid) return null;
    return output[0..written];
}

const CanonicalIterator = struct {
    decoded: TextIterator,
    queued: [2]u8 = undefined,
    queued_index: u2 = 0,
    queued_len: u2 = 0,
    valid: bool = true,

    fn init(text: Text) CanonicalIterator {
        return .{ .decoded = text.iterator() };
    }

    fn next(iterator: *CanonicalIterator) ?u8 {
        if (iterator.queued_index < iterator.queued_len) {
            const byte = iterator.queued[iterator.queued_index];
            iterator.queued_index += 1;
            return byte;
        }
        const byte = iterator.decoded.next() orelse {
            iterator.valid = iterator.decoded.valid and iterator.decoded.index != 0;
            return null;
        };
        if (byte != '%') {
            if (!isRegNameByte(byte)) iterator.valid = false;
            return if (iterator.valid) syntax.asciiLower(byte) else null;
        }
        const high = iterator.decoded.next() orelse {
            iterator.valid = false;
            return null;
        };
        const low = iterator.decoded.next() orelse {
            iterator.valid = false;
            return null;
        };
        const high_value = hexValue(high);
        const low_value = hexValue(low);
        if (high_value >= 16 or low_value >= 16) {
            iterator.valid = false;
            return null;
        }
        const value = (high_value << 4) | low_value;
        if (isUnreserved(value)) return syntax.asciiLower(value);
        iterator.queued = .{ upperHex(high), upperHex(low) };
        iterator.queued_index = 0;
        iterator.queued_len = 2;
        return '%';
    }
};

fn canonicalRegNameEql(left: Text, right: Text) bool {
    var a = CanonicalIterator.init(left);
    var b = CanonicalIterator.init(right);
    while (true) {
        const a_byte = a.next();
        const b_byte = b.next();
        if (a_byte != b_byte) return false;
        if (a_byte == null) return a.valid and b.valid;
    }
}

fn decodedEqlIgnoreCase(left: Text, right: Text) bool {
    var a = IpvFutureIterator.init(left);
    var b = IpvFutureIterator.init(right);
    while (true) {
        const a_byte = a.next();
        const b_byte = b.next();
        if (a_byte != b_byte) return false;
        if (a_byte == null) return a.valid and b.valid;
    }
}

const IpvFutureIterator = struct {
    const State = enum(u2) { marker, version, address, done };

    decoded: TextIterator,
    state: State = .marker,
    version_digits: u16 = 0,
    address_bytes: u16 = 0,
    valid: bool = true,

    fn init(text: Text) IpvFutureIterator {
        return .{ .decoded = text.iterator() };
    }

    fn next(iterator: *IpvFutureIterator) ?u8 {
        if (!iterator.valid or iterator.state == .done) return null;
        const byte = iterator.decoded.next() orelse {
            iterator.valid = iterator.decoded.valid and
                iterator.state == .address and iterator.address_bytes != 0;
            iterator.state = .done;
            return null;
        };
        switch (iterator.state) {
            .marker => {
                if (byte != 'v' and byte != 'V') return iterator.fail();
                iterator.state = .version;
            },
            .version => {
                if (byte == '.') {
                    if (iterator.version_digits == 0) return iterator.fail();
                    iterator.state = .address;
                } else {
                    if (hexValue(byte) >= 16) return iterator.fail();
                    iterator.version_digits +|= 1;
                }
            },
            .address => {
                if (!isIpvFutureByte(byte)) return iterator.fail();
                iterator.address_bytes +|= 1;
            },
            .done => unreachable,
        }
        return syntax.asciiLower(byte);
    }

    fn fail(iterator: *IpvFutureIterator) ?u8 {
        iterator.valid = false;
        iterator.state = .done;
        return null;
    }
};

fn rawByteStart(text: Text, end: usize) usize {
    std.debug.assert(end > 0);
    if (text.quoted and end >= 2 and text.bytes[end - 2] == '\\') return end - 2;
    return end - 1;
}

fn encodedByteEnd(text: Text, start: usize) usize {
    if (text.quoted and text.bytes[start] == '\\') return start + 2;
    return start + 1;
}

fn isForbiddenAuthorityByte(byte: u8) bool {
    return byte == '[' or byte == ']' or byte == '@' or byte == '/' or
        byte == '?' or byte == '#' or byte == '\\';
}

fn isRegNameByte(byte: u8) bool {
    return isUnreserved(byte) or isSubDelimiter(byte);
}

fn isIpvFutureByte(byte: u8) bool {
    return isUnreserved(byte) or isSubDelimiter(byte) or byte == ':';
}

fn isUnreserved(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        std.mem.indexOfScalar(u8, "-._~", byte) != null;
}

fn isSubDelimiter(byte: u8) bool {
    return std.mem.indexOfScalar(u8, "!$&'()*+,;=", byte) != null;
}

fn isQuotedText(byte: u8) bool {
    return byte == '\t' or byte == ' ' or byte == '!' or
        (byte >= '#' and byte <= '[') or (byte >= ']' and byte <= '~') or byte >= 0x80;
}

fn isQuotedPairByte(byte: u8) bool {
    return byte == '\t' or byte == ' ' or (byte >= 0x21 and byte <= 0x7e) or byte >= 0x80;
}

fn upperHex(byte: u8) u8 {
    return if (byte >= 'a' and byte <= 'f') byte - 32 else byte;
}

fn hexValue(byte: u8) u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => std.math.maxInt(u8),
    };
}

test "authority normalizes scheme defaults ports and reg-name identity" {
    const bare = try parse("EXAMPLE.com", .http);
    const empty_port = try parse("example.com:", .http);
    const explicit = try parse("example.com:080", .https);
    try std.testing.expect(bare.eql(empty_port));
    try std.testing.expect(bare.eql(explicit));
    try std.testing.expectEqual(@as(u16, 80), bare.port);
    try std.testing.expectEqual(@as(u16, 443), (try parse("example.com", .https)).port);

    const escaped = try parse("%65xample.com", .http);
    try std.testing.expect(bare.eql(escaped));
    try std.testing.expect((try parse("a%2cb", .http)).eql(try parse("a%2Cb", .http)));
    try std.testing.expect(!(try parse("a%2cb", .http)).eql(try parse("a,b", .http)));

    const encoded_ipv4 = try parse("%31%39%32%2e0%2e2%2e1", .http);
    const plain_ipv4 = try parse("192.0.2.1", .http);
    try std.testing.expect(encoded_ipv4.host == .ip);
    try std.testing.expect(encoded_ipv4.eql(plain_ipv4));
}

test "authority canonicalizes numeric hosts and IPvFuture" {
    const ipv4 = try parse("192.0.2.8:81", .http);
    try std.testing.expect(ipv4.host == .ip);
    try std.testing.expectEqual(@as(u16, 81), ipv4.port);
    const compressed = try parse("[2001:db8::1]", .http);
    const expanded = try parse("[2001:0db8:0:0:0:0:0:1]:80", .https);
    try std.testing.expect(compressed.eql(expanded));
    try std.testing.expect((try parse("[vF.a:b]", .http)).eql(
        try parse("[Vf.A:B]:80", .https),
    ));
}

test "authority accepts quoted escaped views without allocation" {
    const quoted = Text.quotedValue("example.com\\:443");
    const parsed = try parseText(quoted, .https);
    try std.testing.expect(parsed.eql(try parse("EXAMPLE.com", .https)));
    try std.testing.expectError(
        error.InvalidAuthority,
        parseText(Text.quotedValue("example.com\\"), .http),
    );
}

test "authority host and endpoint formatting use caller storage" {
    const cases = [_]struct {
        raw: []const u8,
        scheme: Scheme,
        expected_host: []const u8,
        expected_authority: []const u8,
    }{
        .{
            .raw = "Example.test",
            .scheme = .https,
            .expected_host = "Example.test",
            .expected_authority = "Example.test:443",
        },
        .{
            .raw = "[2001:db8::7]:8443",
            .scheme = .http,
            .expected_host = "2001:db8::7",
            .expected_authority = "[2001:db8::7]:8443",
        },
        .{
            .raw = "[v1.edge]:80",
            .scheme = .http,
            .expected_host = "v1.edge",
            .expected_authority = "[v1.edge]:80",
        },
    };
    for (cases) |case| {
        const value = try parse(case.raw, case.scheme);
        var host_buffer: [64]u8 = undefined;
        try std.testing.expectEqualStrings(
            case.expected_host,
            try value.host.formatInto(&host_buffer),
        );
        var authority_buffer: [80]u8 = undefined;
        try std.testing.expectEqualStrings(
            case.expected_authority,
            try value.formatInto(&authority_buffer),
        );
    }
}

test "authority canonical formatting owns one equivalence spelling" {
    const cases = [_]struct {
        raw: []const u8,
        scheme: Scheme,
        expected: []const u8,
    }{
        .{ .raw = "%65XAMPLE.com", .scheme = .https, .expected = "example.com:443" },
        .{ .raw = "a%2cb:80", .scheme = .http, .expected = "a%2Cb:80" },
        .{ .raw = "[2001:0db8::1]", .scheme = .http, .expected = "[2001:db8::1]:80" },
        .{ .raw = "[vF.A:B]", .scheme = .https, .expected = "[vf.a:b]:443" },
    };
    for (cases) |case| {
        var output: [80]u8 = undefined;
        const actual = try (try parse(case.raw, case.scheme)).formatCanonicalInto(&output);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "authority equality and canonical formatting obey the same law" {
    const cases = [_]struct {
        left: []const u8,
        right: []const u8,
        scheme: Scheme,
    }{
        .{ .left = "example%2ecom", .right = "EXAMPLE.com", .scheme = .https },
        .{ .left = "%31%39%32%2e0%2e2%2e1", .right = "192.0.2.1", .scheme = .http },
        .{ .left = "[2001:0db8::1]", .right = "[2001:db8::1]", .scheme = .https },
        .{ .left = "[vF.A:B]", .right = "[Vf.a:b]", .scheme = .http },
        .{ .left = "a%2cb", .right = "a,b", .scheme = .http },
    };
    for (cases) |case| {
        const left = try parse(case.left, case.scheme);
        const right = try parse(case.right, case.scheme);
        var left_storage: [80]u8 = undefined;
        var right_storage: [80]u8 = undefined;
        const left_canonical = try left.formatCanonicalInto(&left_storage);
        const right_canonical = try right.formatCanonicalInto(&right_storage);
        try std.testing.expectEqual(
            left.eql(right),
            std.mem.eql(u8, left_canonical, right_canonical),
        );
    }
}

test "authority canonical formatting rejects forged host text" {
    const invalid = [_]Text{
        Text.raw(""),
        Text.raw("app.example%"),
        Text.raw("app.example%2"),
        Text.raw("app.example%zz"),
    };
    const valid = try parse("app.example", .https);
    for (invalid) |text| {
        const forged = Authority{ .host = .{ .reg_name = text }, .port = 443 };
        var output: [80]u8 = undefined;
        try std.testing.expectError(
            error.InvalidAuthority,
            forged.formatCanonicalInto(&output),
        );
        try std.testing.expect(!forged.eql(valid));
        if (text.bytes.len == 0) try std.testing.expect(!forged.eql(forged));
    }
    const future = Authority{
        .host = .{ .ipv_future = Text.raw("v1.bad%") },
        .port = 443,
    };
    const valid_future = try parse("[v1.good]", .https);
    const truncated_future = Authority{
        .host = .{ .ipv_future = Text.quotedValue("v1.good\\") },
        .port = 443,
    };
    const empty_future = Authority{
        .host = .{ .ipv_future = Text.raw("v1.") },
        .port = 443,
    };
    var output: [80]u8 = undefined;
    try std.testing.expectError(error.InvalidAuthority, future.formatCanonicalInto(&output));
    try std.testing.expect(!truncated_future.eql(valid_future));
    try std.testing.expect(!empty_future.eql(empty_future));
}

test "authority rejects invalid syntax and overflowing ports" {
    const invalid = [_][]const u8{
        "",
        ":80",
        "user@example.com",
        "example.com:65536",
        "example.com:-1",
        "example.com:1:2",
        "[2001:db8::1",
        "[2001:db8::1]x",
        "[192.0.2.1]",
        "[fe80::1%25eth0]",
        "[v.abc]",
        "[v1.]",
        "[v1.a%20b]",
        "example.com/path",
        "example.com\\path",
    };
    for (invalid) |raw| {
        try std.testing.expectError(error.InvalidAuthority, parse(raw, .http));
    }
}

test "authority parser has deterministic byte-domain outcomes" {
    var one = [_]u8{0};
    for (0..256) |value| {
        one[0] = @intCast(value);
        _ = parse(&one, .http) catch |err| switch (err) {
            error.InvalidAuthority => continue,
        };
    }
}
