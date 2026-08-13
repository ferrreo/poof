const std = @import("std");
const address = @import("../src/address.zig");
const forwarding = @import("../src/forwarding.zig");
const authority = @import("../src/internal/http1/authority.zig");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const limits = @import("../src/internal/http1/limits.zig");
const request_forwarded = @import("../src/internal/http1/request_forwarded.zig");
const request_head = @import("../src/internal/http1/request_head.zig");
const request_proxy_identity = @import("../src/internal/http1/request_proxy_identity.zig");
const request_x_forwarded = @import("../src/internal/http1/request_x_forwarded.zig");

const fuzz_limits = forwarding.Limits{
    .trusted_matchers_max = 2,
    .hops_max = 4,
    .parameters_per_element_max = 4,
};
const authority_bytes_max: usize = 256;
const authority_format_bytes_max: usize = authority_bytes_max + 8;
const FuzzProfile = forwarding.Profile(fuzz_limits);
const Decoder = request_head.Decoder(limits.standard_request_head_limits);

const Family = enum(u1) { forwarded, x_forwarded };
const Peer = enum(u2) { trusted_direct, untrusted_direct, proxy_public };
const Prefix = enum(u2) { absent, valid, malformed };

const ScenarioSeed = packed struct(u16) {
    family_x: bool = false,
    peer: u2 = 0,
    prefix: u2 = 0,
    nearest_trusted: bool = false,
    multiple_fields: bool = false,
    nearest_host: bool = false,
    nearest_proto: bool = false,
    _padding: u7 = 0,
};

const Scenario = struct {
    family: Family,
    peer: Peer,
    prefix: Prefix,
    nearest_trusted: bool,
    multiple_fields: bool,
    nearest_host: bool,
    nearest_proto: bool,
};

const Identity = struct {
    transport: address.Endpoint,
    connection: address.Endpoint,
    source: forwarding.ConnectionSource,
};

const ExpectedMetadata = struct {
    identity: Identity,
    client: address.Endpoint,
    host: []const u8,
    scheme: forwarding.Scheme,
    client_provenance: forwarding.ClientProvenance,
    host_provenance: forwarding.HostProvenance,
    scheme_provenance: forwarding.SchemeProvenance,
    headers: forwarding.HeaderDisposition,
    trusted_hops: u16,
};

const Expected = union(enum) {
    rejected: forwarding.BadRequestReason,
    accepted: ExpectedMetadata,
};

const FuzzField = struct { name: []const u8, value: []const u8 };

const FuzzFields = struct {
    values: []const FuzzField,
    index: usize = 0,

    pub fn next(fields: *FuzzFields) ?FuzzField {
        if (fields.index == fields.values.len) return null;
        defer fields.index += 1;
        return fields.values[fields.index];
    }
};

pub fn fuzzAuthority(_: void, smith: *std.testing.Smith) !void {
    var storage: [authority_bytes_max]u8 = undefined;
    const raw = storage[0..smith.slice(&storage)];
    const control = smith.valueRangeAtMost(u8, 0, 3);
    const scheme: authority.Scheme = if (control & 1 == 0) .http else .https;
    const text = if (control & 2 == 0)
        authority.Text.raw(raw)
    else
        authority.Text.quotedValue(raw);
    const first = authority.parseText(text, scheme) catch |problem| {
        try std.testing.expectError(problem, authority.parseText(text, scheme));
        return;
    };
    const second = try authority.parseText(text, scheme);
    try std.testing.expect(first.eql(second));
    try std.testing.expectEqual(first.port, second.port);

    var formatted: [authority_format_bytes_max]u8 = undefined;
    const encoded = try first.formatInto(&formatted);
    const reparsed = try authority.parse(encoded, scheme);
    try std.testing.expect(first.eql(reparsed));
}

pub fn fuzzForwardedParser(_: void, smith: *std.testing.Smith) !void {
    var storage: [256]u8 = undefined;
    const raw = storage[0..smith.slice(&storage)];
    var field_storage: [2]FuzzField = undefined;
    const fields = forwardedFuzzFields(raw, smith.value(u64), &field_storage);
    var first_fields = FuzzFields{ .values = fields };
    const first = request_forwarded.parse(fuzz_limits, &first_fields) catch |problem| {
        var second_fields = FuzzFields{ .values = fields };
        try std.testing.expectError(
            problem,
            request_forwarded.parse(fuzz_limits, &second_fields),
        );
        return;
    };
    var second_fields = FuzzFields{ .values = fields };
    const second = try request_forwarded.parse(fuzz_limits, &second_fields);
    try expectForwardedParsed(first, second);
}

fn forwardedFuzzFields(raw: []const u8, control: u64, output: *[2]FuzzField) []FuzzField {
    output[0] = .{ .name = "Forwarded", .value = raw };
    if (control & 1 == 0) return output[0..1];
    const split = @as(usize, @truncate(control >> 1)) % (raw.len + 1);
    output[0].value = raw[0..split];
    output[1] = .{ .name = "Forwarded", .value = raw[split..] };
    return output;
}

fn expectForwardedParsed(
    first: request_forwarded.Parsed(fuzz_limits),
    second: request_forwarded.Parsed(fuzz_limits),
) !void {
    try std.testing.expect(first.present);
    try std.testing.expect(first.element_count > 0);
    try std.testing.expect(first.element_count <= fuzz_limits.hops_max);
    try std.testing.expectEqual(first.present, second.present);
    try std.testing.expectEqual(first.element_count, second.element_count);
    for (first.elements[0..first.element_count], second.elements[0..second.element_count]) |a, b| {
        try std.testing.expectEqualDeep(a, b);
        if (a.host) |host| try std.testing.expect(host.valid());
    }
}

pub fn fuzzXForwardedParser(_: void, smith: *std.testing.Smith) !void {
    var storage: [256]u8 = undefined;
    const raw = storage[0..smith.slice(&storage)];
    var field_storage: [6]FuzzField = undefined;
    const fields = xFuzzFields(raw, smith.value(u64), &field_storage);
    var first_fields = FuzzFields{ .values = fields };
    const first = request_x_forwarded.parse(fuzz_limits, &first_fields, .http) catch |problem| {
        var second_fields = FuzzFields{ .values = fields };
        try std.testing.expectError(
            problem,
            request_x_forwarded.parse(fuzz_limits, &second_fields, .http),
        );
        return;
    };
    var second_fields = FuzzFields{ .values = fields };
    const second = try request_x_forwarded.parse(fuzz_limits, &second_fields, .http);
    try expectXForwardedParsed(first, second);
}

fn xFuzzFields(raw: []const u8, control: u64, output: *[6]FuzzField) []FuzzField {
    const a = @as(usize, @truncate(control)) % (raw.len + 1);
    const b = @as(usize, @truncate(control >> 16)) % (raw.len + 1);
    const first = @min(a, b);
    const second = @max(a, b);
    var count: usize = 0;
    appendFuzzField(output, &count, "X-Forwarded-For", raw[0..first]);
    if (control & (@as(u64, 1) << 32) != 0) {
        appendFuzzField(output, &count, "X-Forwarded-For", raw[first..second]);
    }
    if (control & (@as(u64, 1) << 33) != 0) {
        appendFuzzField(output, &count, "X-Forwarded-Host", raw[first..second]);
        if (control & (@as(u64, 1) << 34) != 0) {
            appendFuzzField(output, &count, "X-Forwarded-Host", raw[first..second]);
        }
    }
    if (control & (@as(u64, 1) << 35) != 0) {
        appendFuzzField(output, &count, "X-Forwarded-Proto", raw[second..]);
        if (control & (@as(u64, 1) << 36) != 0) {
            appendFuzzField(output, &count, "X-Forwarded-Proto", raw[second..]);
        }
    }
    return output[0..count];
}

fn appendFuzzField(output: *[6]FuzzField, count: *usize, name: []const u8, value: []const u8) void {
    output[count.*] = .{ .name = name, .value = value };
    count.* += 1;
}

fn expectXForwardedParsed(
    first: request_x_forwarded.Parsed(fuzz_limits),
    second: request_x_forwarded.Parsed(fuzz_limits),
) !void {
    try std.testing.expect(first.present);
    try std.testing.expect(first.node_count > 0);
    try std.testing.expect(first.node_count <= fuzz_limits.hops_max);
    try std.testing.expectEqual(first.present, second.present);
    try std.testing.expectEqual(first.node_count, second.node_count);
    try std.testing.expectEqual(first.scheme, second.scheme);
    try std.testing.expectEqualDeep(
        first.nodes[0..first.node_count],
        second.nodes[0..second.node_count],
    );
    if (first.host) |host| {
        try std.testing.expect(second.host != null);
        try std.testing.expect(host.eql(second.host.?));
    } else try std.testing.expect(second.host == null);
}

pub fn fuzzResolver(_: void, smith: *std.testing.Smith) !void {
    const scenario = scenarioFromSeed(smith.value(ScenarioSeed));
    var wire_storage: [512]u8 = undefined;
    const wire = try buildRequest(scenario, &wire_storage);
    var decoder = Decoder.init();
    if (decoder.feed(wire).state != .ready) return error.TestUnexpectedResult;
    const identity = identityFor(scenario.peer);
    const profile = try profileFor(scenario);
    const actual = request_proxy_identity.resolve(
        fuzz_limits,
        &profile,
        resolverInput(&decoder, identity),
    );
    try expectResult(scenario, actual, expectedFor(scenario, identity));
}

fn scenarioFromSeed(seed: ScenarioSeed) Scenario {
    return .{
        .family = if (seed.family_x) .x_forwarded else .forwarded,
        .peer = switch (seed.peer) {
            0 => .trusted_direct,
            1 => .untrusted_direct,
            else => .proxy_public,
        },
        .prefix = switch (seed.prefix) {
            0 => .absent,
            1 => .valid,
            else => .malformed,
        },
        .nearest_trusted = seed.nearest_trusted,
        .multiple_fields = seed.multiple_fields,
        .nearest_host = seed.nearest_host,
        .nearest_proto = seed.nearest_proto,
    };
}

fn buildRequest(scenario: Scenario, output: []u8) std.Io.Writer.Error![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("GET / HTTP/1.1\r\nHost: direct.test\r\n");
    switch (scenario.family) {
        .forwarded => try writeForwarded(&writer, scenario),
        .x_forwarded => try writeXForwarded(&writer, scenario),
    }
    try writer.writeAll("\r\n");
    return writer.buffered();
}

fn writeForwarded(writer: *std.Io.Writer, scenario: Scenario) std.Io.Writer.Error!void {
    try writer.writeAll("X-Forwarded-For: invalid\r\n");
    const prefix: ?[]const u8 = switch (scenario.prefix) {
        .absent => null,
        .valid => "for=192.0.2.9;host=outer.test;proto=http",
        .malformed => "broken ]]]",
    };
    try writer.writeAll("Forwarded: ");
    if (prefix) |value| {
        try writer.writeAll(value);
        if (scenario.multiple_fields) {
            try writer.writeAll("\r\nForwarded: ");
        } else {
            try writer.writeAll(", ");
        }
    }
    try writer.writeAll("for=");
    try writer.writeAll(if (scenario.nearest_trusted) "10.0.0.2" else "198.51.100.8");
    if (scenario.nearest_host) try writer.writeAll(";host=public.test");
    if (scenario.nearest_proto) try writer.writeAll(";proto=https");
    try writer.writeAll("\r\n");
}

fn writeXForwarded(writer: *std.Io.Writer, scenario: Scenario) std.Io.Writer.Error!void {
    try writer.writeAll("Forwarded: invalid ]]]\r\nX-Forwarded-For: ");
    const prefix: ?[]const u8 = switch (scenario.prefix) {
        .absent => null,
        .valid => "192.0.2.9",
        .malformed => "not-an-address",
    };
    if (prefix) |value| {
        try writer.writeAll(value);
        if (scenario.multiple_fields) {
            try writer.writeAll("\r\nX-Forwarded-For: ");
        } else {
            try writer.writeAll(", ");
        }
    }
    try writer.writeAll(if (scenario.nearest_trusted) "10.0.0.2" else "198.51.100.8");
    try writer.writeAll("\r\n");
    if (scenario.nearest_host) try writer.writeAll("X-Forwarded-Host: public.test\r\n");
    if (scenario.nearest_proto) try writer.writeAll("X-Forwarded-Proto: https\r\n");
}

fn profileFor(scenario: Scenario) forwarding.ProfileError!FuzzProfile {
    var config = forwarding.Config{
        .family = switch (scenario.family) {
            .forwarded => .forwarded,
            .x_forwarded => .x_forwarded,
        },
        .trusted = &.{"10.0.0.0/8"},
    };
    if (scenario.peer == .proxy_public) {
        config.proxy_protocol = .v2_required;
        config.untrusted_peer = .reject;
    }
    return FuzzProfile.init(config);
}

fn identityFor(peer: Peer) Identity {
    return switch (peer) {
        .trusted_direct => .{
            .transport = endpoint("10.0.0.1", 8080),
            .connection = endpoint("10.0.0.1", 8080),
            .source = .transport,
        },
        .untrusted_direct => .{
            .transport = endpoint("192.0.2.200", 8080),
            .connection = endpoint("192.0.2.200", 8080),
            .source = .transport,
        },
        .proxy_public => .{
            .transport = endpoint("10.0.0.1", 8080),
            .connection = endpoint("203.0.113.200", 9000),
            .source = .proxy_protocol_v2,
        },
    };
}

fn resolverInput(decoder: *const Decoder, identity: Identity) request_proxy_identity.Input {
    return .{
        .bytes = decoder.bytes(),
        .fields = decoder.fields(),
        .transport_peer = identity.transport,
        .connection_peer = identity.connection,
        .connection_source = identity.source,
    };
}

fn expectedFor(scenario: Scenario, identity: Identity) Expected {
    if (scenario.peer == .untrusted_direct) return .{ .accepted = .{
        .identity = identity,
        .client = identity.connection,
        .host = "direct.test",
        .scheme = .http,
        .client_provenance = .transport,
        .host_provenance = .host,
        .scheme_provenance = .connection,
        .headers = .ignored_untrusted,
        .trusted_hops = 0,
    } };
    if (scenario.prefix == .malformed) return .{ .rejected = .malformed };
    var expected = baseExpected(identity);
    applyExpectedOrigin(scenario, &expected);
    applyExpectedClient(scenario, &expected);
    return .{ .accepted = expected };
}

fn baseExpected(identity: Identity) ExpectedMetadata {
    return .{
        .identity = identity,
        .client = identity.connection,
        .host = "direct.test",
        .scheme = .http,
        .client_provenance = switch (identity.source) {
            .transport => .transport,
            .proxy_protocol_v2 => .proxy_protocol_v2,
            .proxy_protocol_v2_local => .proxy_protocol_v2_local,
        },
        .host_provenance = .host,
        .scheme_provenance = .connection,
        .headers = .applied,
        .trusted_hops = 0,
    };
}

fn applyExpectedOrigin(scenario: Scenario, expected: *ExpectedMetadata) void {
    const trusted_prefix = scenario.prefix == .valid and scenario.nearest_trusted;
    if (scenario.nearest_host) {
        expected.host = "public.test";
        expected.host_provenance = switch (scenario.family) {
            .forwarded => .forwarded,
            .x_forwarded => .x_forwarded_host,
        };
    } else if (scenario.family == .forwarded and trusted_prefix) {
        expected.host = "outer.test";
        expected.host_provenance = .forwarded;
    }
    if (scenario.nearest_proto) {
        expected.scheme = .https;
        expected.scheme_provenance = switch (scenario.family) {
            .forwarded => .forwarded,
            .x_forwarded => .x_forwarded_proto,
        };
    } else if (scenario.family == .forwarded and trusted_prefix) {
        expected.scheme_provenance = .forwarded;
    }
}

fn applyExpectedClient(scenario: Scenario, expected: *ExpectedMetadata) void {
    if (scenario.peer == .proxy_public) return;
    expected.client = endpoint(
        if (scenario.nearest_trusted) "10.0.0.2" else "198.51.100.8",
        0,
    );
    expected.client_provenance = switch (scenario.family) {
        .forwarded => .forwarded,
        .x_forwarded => .x_forwarded,
    };
    expected.trusted_hops = 1;
    if (scenario.nearest_trusted and scenario.prefix == .valid) {
        expected.client = endpoint("192.0.2.9", 0);
        expected.trusted_hops = 2;
    }
}

fn expectResult(
    scenario: Scenario,
    actual: request_proxy_identity.Result,
    expected: Expected,
) !void {
    switch (expected) {
        .rejected => |reason| switch (actual) {
            .accepted => return error.TestUnexpectedResult,
            .rejected => |rejection| {
                if (rejection != .bad_request) return error.TestUnexpectedResult;
                try std.testing.expectEqual(reason, rejection.bad_request.reason);
                try std.testing.expectEqual(
                    switch (scenario.family) {
                        .forwarded => forwarding.HeaderFamily.forwarded,
                        .x_forwarded => forwarding.HeaderFamily.x_forwarded,
                    },
                    rejection.bad_request.family,
                );
            },
        },
        .accepted => |metadata| switch (actual) {
            .rejected => return error.TestUnexpectedResult,
            .accepted => |value| try expectMetadata(value, metadata),
        },
    }
}

fn expectMetadata(actual: forwarding.Metadata, expected: ExpectedMetadata) !void {
    try std.testing.expect(actual.transport_peer.eql(expected.identity.transport));
    try std.testing.expect(actual.connection_peer.eql(expected.identity.connection));
    try std.testing.expect(actual.client.eql(expected.client));
    try std.testing.expectEqual(expected.identity.source, actual.connection_source);
    try std.testing.expectEqual(expected.scheme, actual.scheme);
    try std.testing.expect(actual.authority.eql(
        try authority.parse(expected.host, expected.scheme),
    ));
    try std.testing.expectEqual(expected.client_provenance, actual.client_provenance);
    try std.testing.expectEqual(expected.host_provenance, actual.host_provenance);
    try std.testing.expectEqual(expected.scheme_provenance, actual.scheme_provenance);
    try std.testing.expectEqual(expected.headers, actual.forwarding_headers);
    try std.testing.expectEqual(expected.trusted_hops, actual.trusted_hops);
}

fn endpoint(raw: []const u8, port: u16) address.Endpoint {
    return .{ .address = address.Address.parse(raw) catch unreachable, .port = port };
}

fn fuzzSeed(comptime seed: ScenarioSeed) [8]u8 {
    var input = [_]u8{0} ** 8;
    std.mem.writeInt(u64, &input, @as(u16, @bitCast(seed)), .little);
    return input;
}

pub const authority_corpus = struct {
    const empty = fuzz_support.smithInputThenU64("", 0);
    const reg_name = fuzz_support.smithInputThenU64("example.test:8443", 1);
    const ipv6 = fuzz_support.smithInputThenU64("[2001:db8::1]", 0);
    const quoted = fuzz_support.smithInputThenU64("example.test\\:443", 3);
    const malformed = fuzz_support.smithInputThenU64("[unterminated", 0);
    const values = [_][]const u8{ &empty, &reg_name, &ipv6, &quoted, &malformed };
}.values;

pub const forwarded_parser_corpus = struct {
    const one = fuzz_support.smithInputThenU64("for=192.0.2.1", 0);
    const first = "for=192.0.2.1";
    const fields = fuzz_support.smithInputThenU64(
        first ++ "for=10.0.0.2;host=public.test;proto=https",
        1 | (@as(u64, first.len) << 1),
    );
    const malformed = fuzz_support.smithInputThenU64("for=\"unterminated", 0);
    const values = [_][]const u8{ &one, &fields, &malformed };
}.values;

pub const x_parser_corpus = struct {
    const one_value = "192.0.2.1";
    const one_cut = @as(u64, one_value.len);
    const one = fuzz_support.smithInputThenU64(one_value, one_cut | (one_cut << 16));
    const first = "192.0.2.1";
    const second = "10.0.0.2";
    const many = fuzz_support.smithInputThenU64(
        first ++ second,
        @as(u64, first.len) | (@as(u64, first.len + second.len) << 16) |
            (@as(u64, 1) << 32),
    );
    const host = "public.test";
    const origin = fuzz_support.smithInputThenU64(
        first ++ host ++ "https",
        @as(u64, first.len) | (@as(u64, first.len + host.len) << 16) |
            (@as(u64, 1) << 33) | (@as(u64, 1) << 35),
    );
    const malformed_value = "not-an-address";
    const malformed_cut = @as(u64, malformed_value.len);
    const malformed = fuzz_support.smithInputThenU64(
        malformed_value,
        malformed_cut | (malformed_cut << 16),
    );
    const values = [_][]const u8{ &one, &many, &origin, &malformed };
}.values;

pub const fuzz_corpus = struct {
    const forwarded_untrusted_suffix = fuzzSeed(.{
        .prefix = 1,
        .multiple_fields = true,
        .nearest_host = true,
        .nearest_proto = true,
    });
    const forwarded_trusted_suffix = fuzzSeed(.{
        .prefix = 1,
        .nearest_trusted = true,
        .multiple_fields = true,
    });
    const forwarded_proxy_public = fuzzSeed(.{
        .peer = 2,
        .prefix = 1,
        .nearest_trusted = true,
        .nearest_host = true,
        .nearest_proto = true,
    });
    const forwarded_malformed = fuzzSeed(.{ .peer = 2, .prefix = 2 });
    const x_trusted_suffix = fuzzSeed(.{
        .family_x = true,
        .prefix = 1,
        .nearest_trusted = true,
        .multiple_fields = true,
        .nearest_host = true,
        .nearest_proto = true,
    });
    const x_untrusted_malformed = fuzzSeed(.{
        .family_x = true,
        .peer = 1,
        .prefix = 2,
        .multiple_fields = true,
    });
    const x_proxy_public = fuzzSeed(.{
        .family_x = true,
        .peer = 2,
        .prefix = 1,
        .nearest_trusted = true,
        .multiple_fields = true,
        .nearest_host = true,
        .nearest_proto = true,
    });
    const x_malformed = fuzzSeed(.{ .family_x = true, .prefix = 2 });
    const values = [_][]const u8{
        &forwarded_untrusted_suffix,
        &forwarded_trusted_suffix,
        &forwarded_proxy_public,
        &forwarded_malformed,
        &x_trusted_suffix,
        &x_untrusted_malformed,
        &x_proxy_public,
        &x_malformed,
    };
}.values;
