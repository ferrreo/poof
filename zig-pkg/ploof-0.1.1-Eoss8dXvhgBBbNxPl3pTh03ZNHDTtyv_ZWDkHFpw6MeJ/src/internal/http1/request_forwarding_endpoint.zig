const std = @import("std");
const address = @import("../../address.zig");

pub const Error = error{InvalidEndpoint};

pub const UnbracketedIpv6 = enum(u1) {
    reject,
    accept,
};

pub fn parse(raw: []const u8, ipv6: UnbracketedIpv6) Error!address.Endpoint {
    if (raw.len == 0) return error.InvalidEndpoint;
    if (raw[0] == '[') return parseBracketed(raw);
    if (ipv6 == .reject) {
        const first = std.mem.indexOfScalar(u8, raw, ':');
        if (first) |colon| {
            if (std.mem.indexOfScalarPos(u8, raw, colon + 1, ':') != null) {
                return error.InvalidEndpoint;
            }
        }
    }
    if (address.Address.parse(raw)) |ip| {
        if (ip == .ipv6 and ipv6 == .reject) return error.InvalidEndpoint;
        return .{ .address = ip, .port = 0 };
    } else |_| {}
    const colon = std.mem.lastIndexOfScalar(u8, raw, ':') orelse
        return error.InvalidEndpoint;
    if (std.mem.indexOfScalar(u8, raw[0..colon], ':') != null) {
        return error.InvalidEndpoint;
    }
    const ip = address.Address.parse(raw[0..colon]) catch return error.InvalidEndpoint;
    if (ip != .ipv4) return error.InvalidEndpoint;
    return .{ .address = ip, .port = try parsePort(raw[colon + 1 ..]) };
}

fn parseBracketed(raw: []const u8) Error!address.Endpoint {
    const close = std.mem.indexOfScalar(u8, raw, ']') orelse return error.InvalidEndpoint;
    if (close == 1) return error.InvalidEndpoint;
    const ip = address.Address.parse(raw[1..close]) catch return error.InvalidEndpoint;
    if (ip == .ipv4 and std.mem.indexOfScalar(u8, raw[1..close], ':') == null) {
        return error.InvalidEndpoint;
    }
    const suffix = raw[close + 1 ..];
    if (suffix.len == 0) return .{ .address = ip, .port = 0 };
    if (suffix[0] != ':') return error.InvalidEndpoint;
    return .{ .address = ip, .port = try parsePort(suffix[1..]) };
}

pub fn parsePort(raw: []const u8) Error!u16 {
    if (raw.len == 0) return error.InvalidEndpoint;
    var value: u32 = 0;
    for (raw) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidEndpoint;
        value = value * 10 + byte - '0';
        if (value > std.math.maxInt(u16)) return error.InvalidEndpoint;
    }
    return @intCast(value);
}

test "forwarding endpoint owns bracket and unbracketed IPv6 policy" {
    const ipv4 = try parse("192.0.2.1:8080", .reject);
    try std.testing.expect(ipv4.address == .ipv4);
    try std.testing.expectEqual(@as(u16, 8080), ipv4.port);
    const ipv6 = try parse("2001:db8::1", .accept);
    try std.testing.expect(ipv6.address == .ipv6);
    try std.testing.expectEqual(@as(u16, 0), ipv6.port);
    try std.testing.expectError(error.InvalidEndpoint, parse("2001:db8::1", .reject));
    try std.testing.expectError(
        error.InvalidEndpoint,
        parse("::ffff:192.0.2.1", .reject),
    );
    const bracketed = try parse("[2001:db8::1]:443", .reject);
    try std.testing.expect(bracketed.address == .ipv6);
    try std.testing.expectEqual(@as(u16, 443), bracketed.port);
}
