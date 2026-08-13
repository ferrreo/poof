const std = @import("std");

const net = std.Io.net;

pub const ParseError = error{InvalidAddress};

pub const Address = union(enum) {
    pub const formatted_bytes_max: usize = 45;

    ipv4: [4]u8,
    ipv6: [16]u8,

    pub fn initIpv4(bytes: [4]u8) Address {
        return .{ .ipv4 = bytes };
    }

    pub fn initIpv6(bytes: [16]u8) Address {
        if (mappedIpv4(bytes)) |ipv4| return .{ .ipv4 = ipv4 };
        return .{ .ipv6 = bytes };
    }

    pub fn parse(text: []const u8) ParseError!Address {
        const parsed = net.IpAddress.parse(text, 0) catch return error.InvalidAddress;
        return switch (parsed) {
            .ip4 => |value| Address.initIpv4(value.bytes),
            .ip6 => |value| Address.initIpv6(value.bytes),
        };
    }

    pub fn normalized(address: Address) Address {
        return switch (address) {
            .ipv4 => address,
            .ipv6 => |bytes| initIpv6(bytes),
        };
    }

    pub fn eql(left: Address, right: Address) bool {
        const a = left.normalized();
        const b = right.normalized();
        return switch (a) {
            .ipv4 => |bytes| switch (b) {
                .ipv4 => |other| std.mem.eql(u8, &bytes, &other),
                .ipv6 => false,
            },
            .ipv6 => |bytes| switch (b) {
                .ipv4 => false,
                .ipv6 => |other| std.mem.eql(u8, &bytes, &other),
            },
        };
    }

    pub fn isIpv6LinkLocal(address: Address) bool {
        return switch (address.normalized()) {
            .ipv4 => false,
            .ipv6 => |bytes| bytes[0] == 0xfe and bytes[1] & 0xc0 == 0x80,
        };
    }

    pub fn format(value: Address, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (value.normalized()) {
            .ipv4 => |bytes| try writer.print(
                "{d}.{d}.{d}.{d}",
                .{ bytes[0], bytes[1], bytes[2], bytes[3] },
            ),
            .ipv6 => |bytes| {
                const unresolved = net.Ip6Address.Unresolved{
                    .bytes = bytes,
                    .interface_name = null,
                };
                try unresolved.format(writer);
            },
        }
    }

    pub fn formatInto(value: Address, output: []u8) std.Io.Writer.Error![]const u8 {
        var writer = std.Io.Writer.fixed(output);
        try value.format(&writer);
        return writer.buffered();
    }
};

pub const Endpoint = struct {
    pub const formatted_bytes_max: usize = Address.formatted_bytes_max + 8;

    address: Address,
    port: u16,

    pub fn initIpv4(bytes: [4]u8, port: u16) Endpoint {
        return .{ .address = Address.initIpv4(bytes), .port = port };
    }

    pub fn initIpv6(bytes: [16]u8, port: u16) Endpoint {
        return .{ .address = Address.initIpv6(bytes), .port = port };
    }

    pub fn normalized(endpoint: Endpoint) Endpoint {
        return .{ .address = endpoint.address.normalized(), .port = endpoint.port };
    }

    pub fn eql(left: Endpoint, right: Endpoint) bool {
        return left.port == right.port and left.address.eql(right.address);
    }

    pub fn sameAddress(left: Endpoint, right: Endpoint) bool {
        return left.address.eql(right.address);
    }

    pub fn format(value: Endpoint, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (value.address.normalized()) {
            .ipv4 => |bytes| try writer.print(
                "{d}.{d}.{d}.{d}:{d}",
                .{ bytes[0], bytes[1], bytes[2], bytes[3], value.port },
            ),
            .ipv6 => |bytes| {
                try writer.writeAll("[");
                try (Address{ .ipv6 = bytes }).format(writer);
                try writer.print("]:{d}", .{value.port});
            },
        }
    }

    pub fn formatInto(value: Endpoint, output: []u8) std.Io.Writer.Error![]const u8 {
        var writer = std.Io.Writer.fixed(output);
        try value.format(&writer);
        return writer.buffered();
    }
};

pub const Cidr = union(enum) {
    pub const Ipv4 = struct { network: [4]u8, prefix: u8 };
    pub const Ipv6 = struct { network: [16]u8, prefix: u8 };

    ipv4: Ipv4,
    ipv6: Ipv6,

    pub fn parse(text: []const u8) ParseError!Cidr {
        const slash = std.mem.indexOfScalar(u8, text, '/') orelse {
            return error.InvalidAddress;
        };
        if (slash == 0 or slash + 1 == text.len or
            std.mem.indexOfScalarPos(u8, text, slash + 1, '/') != null)
        {
            return error.InvalidAddress;
        }
        const parsed = net.IpAddress.parse(text[0..slash], 0) catch {
            return error.InvalidAddress;
        };
        const prefix = parsePrefix(text[slash + 1 ..]) catch return error.InvalidAddress;
        return switch (parsed) {
            .ip4 => |value| initCidrIpv4(value.bytes, prefix),
            .ip6 => |value| initParsedIpv6(value.bytes, prefix),
        };
    }

    pub fn contains(cidr: Cidr, address: Address) bool {
        const candidate = address.normalized();
        return switch (cidr) {
            .ipv4 => |network| switch (candidate) {
                .ipv4 => |bytes| prefixMatches(&network.network, &bytes, network.prefix),
                .ipv6 => false,
            },
            .ipv6 => |network| switch (candidate) {
                .ipv4 => false,
                .ipv6 => |bytes| prefixMatches(&network.network, &bytes, network.prefix),
            },
        };
    }

    pub fn containsEndpoint(cidr: Cidr, endpoint: Endpoint) bool {
        return cidr.contains(endpoint.address);
    }
};

pub const Matcher = union(enum) {
    exact: Address,
    cidr: Cidr,

    pub fn parse(text: []const u8) ParseError!Matcher {
        if (std.mem.indexOfScalar(u8, text, '/') != null) {
            return .{ .cidr = try Cidr.parse(text) };
        }
        return .{ .exact = try Address.parse(text) };
    }

    pub fn matches(matcher: Matcher, address: Address) bool {
        return switch (matcher) {
            .exact => |exact| exact.eql(address),
            .cidr => |cidr| cidr.contains(address),
        };
    }

    pub fn matchesEndpoint(matcher: Matcher, endpoint: Endpoint) bool {
        return matcher.matches(endpoint.address);
    }
};

fn initCidrIpv4(bytes: [4]u8, prefix: u8) ParseError!Cidr {
    if (prefix > 32) return error.InvalidAddress;
    var network = bytes;
    maskHostBits(&network, prefix);
    return .{ .ipv4 = .{ .network = network, .prefix = prefix } };
}

fn initParsedIpv6(bytes: [16]u8, prefix: u8) ParseError!Cidr {
    if (prefix > 128) return error.InvalidAddress;
    if (mappedIpv4(bytes)) |ipv4| {
        if (prefix < 96) return error.InvalidAddress;
        return initCidrIpv4(ipv4, prefix - 96);
    }
    var network = bytes;
    maskHostBits(&network, prefix);
    return .{ .ipv6 = .{ .network = network, .prefix = prefix } };
}

fn parsePrefix(text: []const u8) error{InvalidPrefix}!u8 {
    if (text.len == 0) return error.InvalidPrefix;
    if (text.len > 1 and text[0] == '0') return error.InvalidPrefix;
    var value: u8 = 0;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidPrefix;
        value = std.math.mul(u8, value, 10) catch return error.InvalidPrefix;
        value = std.math.add(u8, value, byte - '0') catch return error.InvalidPrefix;
    }
    return value;
}

fn mappedIpv4(bytes: [16]u8) ?[4]u8 {
    const prefix = [12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
    if (!std.mem.eql(u8, bytes[0..12], &prefix)) return null;
    return bytes[12..16].*;
}

fn maskHostBits(bytes: []u8, prefix: u8) void {
    const whole: usize = prefix / 8;
    const partial: u8 = prefix % 8;
    if (partial != 0) {
        const shift: u3 = @intCast(8 - partial);
        bytes[whole] &= @as(u8, 0xff) << shift;
    }
    const clear_from = whole + @intFromBool(partial != 0);
    @memset(bytes[clear_from..], 0);
}

fn prefixMatches(network: []const u8, address: []const u8, prefix: u8) bool {
    const whole: usize = prefix / 8;
    const partial: u8 = prefix % 8;
    if (!std.mem.eql(u8, network[0..whole], address[0..whole])) return false;
    if (partial == 0) return true;
    const shift: u3 = @intCast(8 - partial);
    const mask = @as(u8, 0xff) << shift;
    return network[whole] & mask == address[whole] & mask;
}

test "numeric addresses parse strictly and normalize mapped IPv6" {
    try std.testing.expectEqualDeep(
        Address{ .ipv4 = .{ 192, 0, 2, 9 } },
        try Address.parse("192.0.2.9"),
    );
    const ipv6 = try Address.parse("2001:db8::9");
    try std.testing.expect(ipv6 == .ipv6);
    try std.testing.expectEqualDeep(
        Address{ .ipv4 = .{ 192, 0, 2, 9 } },
        try Address.parse("::ffff:192.0.2.9"),
    );
    for ([_][]const u8{ "", "192.0.2", "192.00.2.9", "256.0.0.1", "fe80::1%3" }) |bad| {
        try std.testing.expectError(error.InvalidAddress, Address.parse(bad));
    }
}

test "endpoint equality is canonical and port-aware" {
    const ipv4 = Endpoint.initIpv4(.{ 203, 0, 113, 4 }, 443);
    const mapped = Endpoint.initIpv6(
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 203, 0, 113, 4 },
        443,
    );
    try std.testing.expect(ipv4.eql(mapped));
    try std.testing.expect(ipv4.sameAddress(.{ .address = mapped.address, .port = 80 }));
    try std.testing.expect(!ipv4.eql(.{ .address = mapped.address, .port = 80 }));
}

test "addresses and endpoints format into caller storage" {
    const cases = [_]struct {
        raw: []const u8,
        port: u16,
        expected_address: []const u8,
        expected_endpoint: []const u8,
    }{
        .{
            .raw = "192.0.2.7",
            .port = 8080,
            .expected_address = "192.0.2.7",
            .expected_endpoint = "192.0.2.7:8080",
        },
        .{
            .raw = "2001:db8::7",
            .port = 443,
            .expected_address = "2001:db8::7",
            .expected_endpoint = "[2001:db8::7]:443",
        },
    };
    for (cases) |case| {
        const ip = try Address.parse(case.raw);
        var address_buffer: [Address.formatted_bytes_max]u8 = undefined;
        try std.testing.expectEqualStrings(
            case.expected_address,
            try ip.formatInto(&address_buffer),
        );
        const endpoint = Endpoint{ .address = ip, .port = case.port };
        var endpoint_buffer: [Endpoint.formatted_bytes_max]u8 = undefined;
        try std.testing.expectEqualStrings(
            case.expected_endpoint,
            try endpoint.formatInto(&endpoint_buffer),
        );
    }

    var short: [2]u8 = undefined;
    try std.testing.expectError(
        error.WriteFailed,
        (try Address.parse("192.0.2.7")).formatInto(&short),
    );
}

test "CIDR parsing masks host bits and matches inclusive boundaries" {
    const ipv4 = try Cidr.parse("192.0.2.129/24");
    try std.testing.expectEqualDeep(
        Cidr{ .ipv4 = .{ .network = .{ 192, 0, 2, 0 }, .prefix = 24 } },
        ipv4,
    );
    try std.testing.expect(ipv4.contains(try Address.parse("192.0.2.0")));
    try std.testing.expect(ipv4.contains(try Address.parse("192.0.2.255")));
    try std.testing.expect(!ipv4.contains(try Address.parse("192.0.3.0")));

    const ipv6 = try Cidr.parse("2001:db8:1:2::abcd/63");
    try std.testing.expect(ipv6.contains(try Address.parse("2001:db8:1:3::ffff")));
    try std.testing.expect(!ipv6.contains(try Address.parse("2001:db8:1:4::")));
    try std.testing.expect((try Cidr.parse("0.0.0.0/0")).contains(
        try Address.parse("255.255.255.255"),
    ));
    try std.testing.expect((try Cidr.parse("::/0")).contains(
        try Address.parse("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"),
    ));
}

test "mapped IPv6 CIDRs become their exact IPv4 networks" {
    const mapped = try Cidr.parse("::ffff:192.0.2.129/120");
    try std.testing.expectEqualDeep(
        Cidr{ .ipv4 = .{ .network = .{ 192, 0, 2, 0 }, .prefix = 24 } },
        mapped,
    );
    try std.testing.expect(mapped.contains(try Address.parse("192.0.2.200")));
    try std.testing.expectError(
        error.InvalidAddress,
        Cidr.parse("::ffff:192.0.2.1/95"),
    );
}

test "CIDR and matcher parsing reject ambiguous forms" {
    for ([_][]const u8{
        "192.0.2.1",
        "/24",
        "192.0.2.1/",
        "192.0.2.1/024",
        "192.0.2.1/33",
        "2001:db8::1/129",
        "192.0.2.1/24/1",
    }) |bad| try std.testing.expectError(error.InvalidAddress, Cidr.parse(bad));

    const exact = try Matcher.parse("203.0.113.9");
    try std.testing.expect(exact.matches(try Address.parse("203.0.113.9")));
    try std.testing.expect(!exact.matches(try Address.parse("203.0.113.10")));
    const network = try Matcher.parse("203.0.113.0/25");
    try std.testing.expect(network.matchesEndpoint(
        Endpoint.initIpv4(.{ 203, 0, 113, 127 }, 65535),
    ));
    try std.testing.expect(!network.matches(try Address.parse("203.0.113.128")));
}

test "IPv6 link-local classification covers exactly fe80::/10" {
    try std.testing.expect((try Address.parse("fe80::1")).isIpv6LinkLocal());
    try std.testing.expect((try Address.parse("febf::ffff")).isIpv6LinkLocal());
    try std.testing.expect(!(try Address.parse("fec0::1")).isIpv6LinkLocal());
    try std.testing.expect(!(try Address.parse("192.0.2.1")).isIpv6LinkLocal());
}
