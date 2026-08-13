const std = @import("std");
const address = @import("../../address.zig");
const authority = @import("authority.zig");
const forwarding = @import("../../forwarding.zig");
const http_limits = @import("limits.zig");
const request_forwarding_endpoint = @import("request_forwarding_endpoint.zig");
const syntax = @import("syntax.zig");

pub const ParseError = error{
    Malformed,
    Duplicate,
    TooManyHops,
};

pub fn Parsed(comptime limits: forwarding.Limits) type {
    return struct {
        present: bool = false,
        nodes: [limits.hops_max]address.Endpoint = undefined,
        node_count: u16 = 0,
        host: ?authority.Authority = null,
        scheme: ?authority.Scheme = null,
    };
}

pub fn parse(
    comptime limits: forwarding.Limits,
    fields: anytype,
    direct_scheme: authority.Scheme,
) ParseError!Parsed(limits) {
    var result: Parsed(limits) = .{};
    var for_error: ?ParseError = null;
    var host: ?[]const u8 = null;
    var proto: ?[]const u8 = null;
    var host_duplicate = false;
    var proto_duplicate = false;
    while (fields.next()) |field| {
        if (syntax.eqlIgnoreCase(field.name, "x-forwarded-for")) {
            result.present = true;
            if (for_error == null) {
                parseForField(limits, &result, field.value) catch |problem| {
                    for_error = problem;
                };
            }
        } else if (syntax.eqlIgnoreCase(field.name, "x-forwarded-host")) {
            result.present = true;
            if (host != null) host_duplicate = true else host = field.value;
        } else if (syntax.eqlIgnoreCase(field.name, "x-forwarded-proto")) {
            result.present = true;
            if (proto != null) proto_duplicate = true else proto = field.value;
        }
    }
    if (for_error) |problem| return problem;
    if (proto_duplicate) return error.Duplicate;
    result.scheme = try parseProto(proto);
    const effective_scheme = result.scheme orelse direct_scheme;
    if (host_duplicate) return error.Duplicate;
    result.host = try parseHost(host, effective_scheme);
    return result;
}

fn parseForField(
    comptime limits: forwarding.Limits,
    result: *Parsed(limits),
    field: []const u8,
) ParseError!void {
    var start: usize = 0;
    while (true) {
        const comma = std.mem.indexOfScalarPos(u8, field, start, ',') orelse field.len;
        const raw = syntax.trimOws(field[start..comma]);
        if (raw.len == 0) return error.Malformed;
        if (result.node_count == limits.hops_max) return error.TooManyHops;
        result.nodes[result.node_count] = request_forwarding_endpoint.parse(
            raw,
            .accept,
        ) catch return error.Malformed;
        result.node_count += 1;
        if (comma == field.len) break;
        start = comma + 1;
    }
}

fn parseProto(value: ?[]const u8) ParseError!?authority.Scheme {
    const raw = syntax.trimOws(value orelse return null);
    if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, ',') != null) {
        return error.Malformed;
    }
    return authority.parseScheme(raw) orelse error.Malformed;
}

fn parseHost(value: ?[]const u8, scheme: authority.Scheme) ParseError!?authority.Authority {
    const raw = syntax.trimOws(value orelse return null);
    if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, ',') != null) {
        return error.Malformed;
    }
    return authority.parse(raw, scheme) catch error.Malformed;
}

const SliceIterator = struct {
    xff_values: []const []const u8 = &.{},
    xfh_values: []const []const u8 = &.{},
    xfp_values: []const []const u8 = &.{},
    phase: u2 = 0,
    index: usize = 0,

    const Field = struct { name: []const u8, value: []const u8 };

    fn next(iterator: *SliceIterator) ?Field {
        while (iterator.phase < 3) {
            const values, const name = switch (iterator.phase) {
                0 => .{ iterator.xff_values, "X-Forwarded-For" },
                1 => .{ iterator.xfh_values, "X-Forwarded-Host" },
                2 => .{ iterator.xfp_values, "X-Forwarded-Proto" },
                else => unreachable,
            };
            if (iterator.index < values.len) {
                defer iterator.index += 1;
                return .{ .name = name, .value = values[iterator.index] };
            }
            iterator.phase += 1;
            iterator.index = 0;
        }
        return null;
    }
};

const test_limits = forwarding.Limits{
    .trusted_matchers_max = 2,
    .hops_max = 4,
    .parameters_per_element_max = 4,
};

const CountedIterator = struct {
    count: usize,
    index: usize = 0,

    fn next(iterator: *CountedIterator) ?SliceIterator.Field {
        if (iterator.index == iterator.count) return null;
        defer iterator.index += 1;
        return if (iterator.index + 1 == iterator.count)
            .{ .name = "X-Forwarded-For", .value = "192.0.2.1" }
        else
            .{ .name = "X-Noise", .value = "ignored" };
    }
};

test "X-Forwarded classifies one default and hard-max field sets in one pass" {
    for ([_]usize{
        1,
        http_limits.standard_request_head_limits.fields_max,
        http_limits.fields_hard_max,
    }) |count| {
        var fields = CountedIterator{ .count = count };
        const parsed = try parse(test_limits, &fields, .http);
        try std.testing.expectEqual(count, fields.index);
        try std.testing.expectEqual(@as(u16, 1), parsed.node_count);
        try expectEndpoint(parsed.nodes[0], "192.0.2.1", 0);
    }
}

test "X-Forwarded parses numeric chain singleton host and proto" {
    var fields = SliceIterator{
        .xff_values = &.{ "192.0.2.1, 2001:db8::1", "[2001:db8::2]:8443" },
        .xfh_values = &.{"Example.test:443"},
        .xfp_values = &.{"https"},
    };
    const parsed = try parse(test_limits, &fields, .http);
    try std.testing.expect(parsed.present);
    try std.testing.expectEqual(@as(u16, 3), parsed.node_count);
    try expectEndpoint(parsed.nodes[0], "192.0.2.1", 0);
    try expectEndpoint(parsed.nodes[1], "2001:db8::1", 0);
    try expectEndpoint(parsed.nodes[2], "2001:db8::2", 8443);
    try std.testing.expectEqual(authority.Scheme.https, parsed.scheme.?);
    try std.testing.expect(parsed.host.?.eql(try authority.parse("example.test", .https)));
}

test "X-Forwarded host and proto are physical and logical singletons" {
    const cases = [_]struct {
        hosts: []const []const u8,
        protos: []const []const u8,
        expected: ParseError,
    }{
        .{ .hosts = &.{ "a.test", "b.test" }, .protos = &.{}, .expected = error.Duplicate },
        .{ .hosts = &.{"a.test,b.test"}, .protos = &.{}, .expected = error.Malformed },
        .{ .hosts = &.{}, .protos = &.{ "http", "https" }, .expected = error.Duplicate },
        .{ .hosts = &.{}, .protos = &.{"http,https"}, .expected = error.Malformed },
    };
    for (cases) |case| {
        var fields = SliceIterator{ .xfh_values = case.hosts, .xfp_values = case.protos };
        try std.testing.expectError(
            case.expected,
            parse(test_limits, &fields, .http),
        );
    }
}

test "X-Forwarded rejects nonnumeric empty and over-limit chains" {
    const invalid = [_][]const u8{
        "unknown",
        "_hidden",
        "192.0.2.1,",
        ",192.0.2.1",
        "999.0.0.1",
        "[2001:db8::1]:65536",
    };
    for (invalid) |raw| {
        var fields = SliceIterator{ .xff_values = &.{raw} };
        try std.testing.expectError(
            error.Malformed,
            parse(test_limits, &fields, .http),
        );
    }

    var fields = SliceIterator{
        .xff_values = &.{"1.1.1.1,2.2.2.2,3.3.3.3,4.4.4.4,5.5.5.5"},
    };
    try std.testing.expectError(
        error.TooManyHops,
        parse(test_limits, &fields, .http),
    );
}

test "X-Forwarded byte fuzz has deterministic typed outcomes" {
    var bytes = [_]u8{ 0, 0 };
    for (0..256) |first| {
        bytes[0] = @intCast(first);
        for (0..256) |second| {
            bytes[1] = @intCast(second);
            var fields = SliceIterator{ .xff_values = &.{&bytes} };
            _ = parse(test_limits, &fields, .http) catch |err| switch (err) {
                error.Malformed, error.Duplicate, error.TooManyHops => continue,
            };
        }
    }
}

fn expectEndpoint(endpoint: address.Endpoint, raw: []const u8, port: u16) !void {
    try std.testing.expect(endpoint.address.eql(try address.Address.parse(raw)));
    try std.testing.expectEqual(port, endpoint.port);
}
