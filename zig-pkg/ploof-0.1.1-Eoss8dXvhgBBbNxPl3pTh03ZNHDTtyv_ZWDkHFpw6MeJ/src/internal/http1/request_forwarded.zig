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
    TooManyParameters,
};

pub const Node = union(enum) {
    missing,
    unknown,
    obfuscated,
    endpoint: address.Endpoint,
};

pub const Element = struct {
    node: Node = .missing,
    host: ?authority.Text = null,
    scheme: ?authority.Scheme = null,
};

pub fn Parsed(comptime limits: forwarding.Limits) type {
    return struct {
        present: bool = false,
        elements: [limits.hops_max]Element = undefined,
        element_count: u16 = 0,
    };
}

pub fn parse(
    comptime limits: forwarding.Limits,
    fields: anytype,
) ParseError!Parsed(limits) {
    var builder = Builder(limits).init();
    while (fields.next()) |field| {
        if (!syntax.eqlIgnoreCase(field.name, "forwarded")) continue;
        builder.result.present = true;
        try parseField(limits, &builder, field.value);
    }
    return builder.result;
}

fn Builder(comptime limits: forwarding.Limits) type {
    return struct {
        const Self = @This();

        result: Parsed(limits),

        fn init() Self {
            return .{ .result = .{} };
        }

        fn addElement(builder: *Self, element: Element) ParseError!void {
            if (builder.result.element_count == limits.hops_max) {
                return error.TooManyHops;
            }
            builder.result.elements[builder.result.element_count] = element;
            builder.result.element_count += 1;
        }
    };
}

const Pair = struct {
    name: []const u8,
    value: authority.Text,
};

fn parseField(
    comptime limits: forwarding.Limits,
    builder: *Builder(limits),
    field: []const u8,
) ParseError!void {
    var index: usize = 0;
    while (true) {
        skipOws(field, &index);
        if (index == field.len) return error.Malformed;
        var element = Element{};
        var names: [limits.parameters_per_element_max][]const u8 = undefined;
        var name_count: u8 = 0;
        try parseElement(limits, field, &index, &element, &names, &name_count);
        try builder.addElement(element);
        if (index == field.len) return;
        std.debug.assert(field[index] == ',');
        index += 1;
    }
}

fn parseElement(
    comptime limits: forwarding.Limits,
    field: []const u8,
    index: *usize,
    element: *Element,
    names: *[limits.parameters_per_element_max][]const u8,
    name_count: *u8,
) ParseError!void {
    while (true) {
        skipOws(field, index);
        const pair = try parsePair(field, index);
        try rememberName(limits, names, name_count, pair.name);
        try applyPair(element, pair);
        skipOws(field, index);
        if (index.* == field.len or field[index.*] == ',') return;
        if (field[index.*] != ';') return error.Malformed;
        index.* += 1;
        skipOws(field, index);
        if (index.* == field.len or field[index.*] == ',' or field[index.*] == ';') {
            return error.Malformed;
        }
    }
}

fn parsePair(field: []const u8, index: *usize) ParseError!Pair {
    const name_start = index.*;
    while (index.* < field.len and syntax.isTokenByte(field[index.*])) index.* += 1;
    if (index.* == name_start) return error.Malformed;
    const name = field[name_start..index.*];
    skipOws(field, index);
    if (index.* == field.len or field[index.*] != '=') return error.Malformed;
    index.* += 1;
    skipOws(field, index);
    return .{ .name = name, .value = try parseValue(field, index) };
}

fn parseValue(field: []const u8, index: *usize) ParseError!authority.Text {
    if (index.* == field.len) return error.Malformed;
    if (field[index.*] != '"') {
        const start = index.*;
        while (index.* < field.len and syntax.isTokenByte(field[index.*])) index.* += 1;
        if (index.* == start) return error.Malformed;
        return authority.Text.raw(field[start..index.*]);
    }
    index.* += 1;
    const start = index.*;
    while (index.* < field.len) {
        if (field[index.*] == '"') {
            const text = authority.Text.quotedValue(field[start..index.*]);
            index.* += 1;
            if (!text.valid()) return error.Malformed;
            return text;
        }
        if (field[index.*] == '\\') {
            index.* += 1;
            if (index.* == field.len) return error.Malformed;
        }
        index.* += 1;
    }
    return error.Malformed;
}

fn rememberName(
    comptime limits: forwarding.Limits,
    names: *[limits.parameters_per_element_max][]const u8,
    count: *u8,
    name: []const u8,
) ParseError!void {
    for (names[0..count.*]) |seen| {
        if (syntax.eqlIgnoreCase(seen, name)) return error.Duplicate;
    }
    if (count.* == limits.parameters_per_element_max) return error.TooManyParameters;
    names[count.*] = name;
    count.* += 1;
}

fn applyPair(element: *Element, pair: Pair) ParseError!void {
    if (syntax.eqlIgnoreCase(pair.name, "for")) {
        element.node = try parseNode(pair.value);
    } else if (syntax.eqlIgnoreCase(pair.name, "by")) {
        _ = try parseNode(pair.value);
    } else if (syntax.eqlIgnoreCase(pair.name, "host")) {
        element.host = pair.value;
    } else if (syntax.eqlIgnoreCase(pair.name, "proto")) {
        element.scheme = try parseProto(pair.value);
    }
}

fn parseProto(text: authority.Text) ParseError!authority.Scheme {
    var buffer: [5]u8 = undefined;
    const decoded = decode(text, &buffer) orelse return error.Malformed;
    return authority.parseScheme(decoded) orelse error.Malformed;
}

fn parseNode(text: authority.Text) ParseError!Node {
    var buffer: [64]u8 = undefined;
    const decoded = decode(text, &buffer) orelse return error.Malformed;
    if (classifyOpaqueNode(decoded)) |node| return node;
    if (request_forwarding_endpoint.parse(decoded, .reject)) |endpoint| {
        return .{ .endpoint = endpoint };
    } else |_| {}
    const colon = std.mem.lastIndexOfScalar(u8, decoded, ':') orelse return error.Malformed;
    if (!validNodePort(decoded[colon + 1 ..])) return error.Malformed;
    return classifyOpaqueNode(decoded[0..colon]) orelse error.Malformed;
}

fn classifyOpaqueNode(raw: []const u8) ?Node {
    if (syntax.eqlIgnoreCase(raw, "unknown")) return .unknown;
    if (validObfuscated(raw)) return .obfuscated;
    return null;
}

fn validNodePort(raw: []const u8) bool {
    if (validObfuscated(raw)) return true;
    _ = request_forwarding_endpoint.parsePort(raw) catch return false;
    return true;
}

fn validObfuscated(raw: []const u8) bool {
    if (raw.len < 2 or raw[0] != '_') return false;
    for (raw[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return false;
        }
    }
    return true;
}

fn decode(text: authority.Text, output: []u8) ?[]const u8 {
    var iterator = text.iterator();
    var count: usize = 0;
    while (iterator.next()) |byte| {
        if (count == output.len) return null;
        output[count] = byte;
        count += 1;
    }
    if (!iterator.valid) return null;
    return output[0..count];
}

fn skipOws(field: []const u8, index: *usize) void {
    while (index.* < field.len and (field[index.*] == ' ' or field[index.*] == '\t')) {
        index.* += 1;
    }
}

const SliceIterator = struct {
    values: []const []const u8,
    index: usize = 0,

    const Field = struct { name: []const u8, value: []const u8 };

    fn next(iterator: *SliceIterator) ?Field {
        if (iterator.index == iterator.values.len) return null;
        defer iterator.index += 1;
        return .{ .name = "Forwarded", .value = iterator.values[iterator.index] };
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
            .{ .name = "Forwarded", .value = "for=192.0.2.1" }
        else
            .{ .name = "X-Noise", .value = "ignored" };
    }
};

test "Forwarded classifies one default and hard-max field sets in one pass" {
    for ([_]usize{
        1,
        http_limits.standard_request_head_limits.fields_max,
        http_limits.fields_hard_max,
    }) |count| {
        var fields = CountedIterator{ .count = count };
        const parsed = try parse(test_limits, &fields);
        try std.testing.expectEqual(count, fields.index);
        try std.testing.expectEqual(@as(u16, 1), parsed.element_count);
        try expectEndpoint(parsed.elements[0].node, "192.0.2.1", 0);
    }
}

test "Forwarded combines physical fields and preserves hop order" {
    var values = SliceIterator{ .values = &.{
        "for=192.0.2.1;proto=https;host=Example.test",
        "for=198.51.100.2, for=203.0.113.3",
    } };
    const parsed = try parse(test_limits, &values);
    try std.testing.expect(parsed.present);
    try std.testing.expectEqual(@as(u16, 3), parsed.element_count);
    try std.testing.expectEqual(authority.Scheme.https, parsed.elements[0].scheme.?);
    try expectHost(parsed.elements[0].host.?, "example.test", .https);
    try expectEndpoint(parsed.elements[0].node, "192.0.2.1", 0);
    try expectEndpoint(parsed.elements[2].node, "203.0.113.3", 0);
}

test "Forwarded parses quoted IPv6 ports escapes and opaque nodes" {
    var values = SliceIterator{ .values = &.{
        "for=\"unknown:_port\",for=_edge-1,for=\"[2001:db8::1]:8443\";" ++
            "host=\"example.test\\:443\";proto=https",
    } };
    const parsed = try parse(test_limits, &values);
    try std.testing.expect(parsed.elements[0].node == .unknown);
    try std.testing.expect(parsed.elements[1].node == .obfuscated);
    try expectEndpoint(parsed.elements[2].node, "2001:db8::1", 8443);
    try expectHost(parsed.elements[2].host.?, "example.test", .https);
}

test "Forwarded enforces unique parameters and bounds" {
    const cases = [_]struct { values: []const []const u8, expected: ParseError }{
        .{ .values = &.{"for=192.0.2.1;For=192.0.2.2"}, .expected = error.Duplicate },
        .{ .values = &.{"for=1.1.1.1,for=2.2.2.2,for=3.3.3.3,for=4.4.4.4," ++
            "for=5.5.5.5"}, .expected = error.TooManyHops },
        .{ .values = &.{"a=1;b=2;c=3;d=4;e=5"}, .expected = error.TooManyParameters },
    };
    for (cases) |case| {
        var values = SliceIterator{ .values = case.values };
        try std.testing.expectError(case.expected, parse(test_limits, &values));
    }
}

test "Forwarded retains differing origin attributes on their own hops" {
    var values = SliceIterator{ .values = &.{
        "for=192.0.2.1;host=public.test;proto=https," ++
            "for=10.0.0.2;host=internal.test;proto=http",
    } };
    const parsed = try parse(test_limits, &values);
    try std.testing.expectEqual(@as(u16, 2), parsed.element_count);
    try std.testing.expectEqual(authority.Scheme.https, parsed.elements[0].scheme.?);
    try std.testing.expectEqual(authority.Scheme.http, parsed.elements[1].scheme.?);
    try expectHost(parsed.elements[0].host.?, "public.test", .https);
    try expectHost(parsed.elements[1].host.?, "internal.test", .http);
}

test "Forwarded rejects malformed selected metadata" {
    const invalid = [_][]const u8{
        "",
        "for",
        "for=",
        "for=192.0.2.1;",
        "for=192.0.2.1,,for=192.0.2.2",
        "for=\"unterminated",
        "for=2001:db8::1",
        "for=999.0.0.1",
        "for=\"[2001:db8::1]:65536\"",
        "proto=ftp",
        "host=bad/path",
    };
    for (invalid) |raw| {
        var values = SliceIterator{ .values = &.{raw} };
        try std.testing.expectError(error.Malformed, parse(test_limits, &values));
    }
}

test "Forwarded byte fuzz has only typed bounded outcomes" {
    var bytes = [_]u8{ 0, 0 };
    for (0..256) |first| {
        bytes[0] = @intCast(first);
        for (0..256) |second| {
            bytes[1] = @intCast(second);
            var values = SliceIterator{ .values = &.{&bytes} };
            _ = parse(test_limits, &values) catch |err| switch (err) {
                error.Malformed,
                error.Duplicate,
                error.TooManyHops,
                error.TooManyParameters,
                => continue,
            };
        }
    }
}

fn expectHost(text: authority.Text, raw: []const u8, scheme: authority.Scheme) !void {
    try std.testing.expect((try authority.parseText(text, scheme)).eql(
        try authority.parse(raw, scheme),
    ));
}

fn expectEndpoint(node: Node, raw: []const u8, port: u16) !void {
    const endpoint = switch (node) {
        .endpoint => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(endpoint.address.eql(try address.Address.parse(raw)));
    try std.testing.expectEqual(port, endpoint.port);
}
