const std = @import("std");
const address = @import("../../address.zig");
const authority = @import("authority.zig");
const forwarding = @import("../../forwarding.zig");
const request_fields = @import("request_fields.zig");
const request_forwarded = @import("request_forwarded.zig");
const request_head = @import("request_head.zig");
const request_x_forwarded = @import("request_x_forwarded.zig");
const syntax = @import("syntax.zig");

pub const Input = struct {
    bytes: []const u8,
    fields: []const request_head.Field,
    transport_peer: address.Endpoint,
    connection_peer: address.Endpoint,
    connection_source: forwarding.ConnectionSource = .transport,
    direct_scheme: authority.Scheme = .http,
};

pub const Result = union(enum) {
    accepted: forwarding.Metadata,
    rejected: forwarding.Rejection,
};

pub fn resolve(
    comptime limits: forwarding.Limits,
    profile: *const forwarding.Profile(limits),
    input: Input,
) Result {
    if (!profile.trustsEndpoint(input.transport_peer)) {
        if (profile.untrusted_peer == .reject) {
            return .{ .rejected = .{
                .untrusted_peer = .{ .peer = input.transport_peer },
            } };
        }
        return directMetadata(input, selectedHeadersPresent(profile.family, input)) catch {
            return reject(profile.family, .invalid_host);
        };
    }
    return switch (profile.family) {
        .none => directMetadata(input, false) catch reject(.none, .invalid_host),
        .forwarded => resolveForwarded(limits, profile, input),
        .x_forwarded => resolveXForwarded(limits, profile, input),
    };
}

fn resolveForwarded(
    comptime limits: forwarding.Limits,
    profile: *const forwarding.Profile(limits),
    input: Input,
) Result {
    var fields = request_fields.raw(input.bytes, input.fields).iterator();
    const parsed = request_forwarded.parse(limits, &fields) catch |err| {
        return reject(.forwarded, mapForwardedError(err));
    };
    const walked = walkForwarded(
        limits,
        profile,
        input.connection_peer,
        parsed.elements[0..parsed.element_count],
    );
    const scheme = walked.scheme orelse input.direct_scheme;
    const effective_authority = if (walked.host) |host|
        authority.parseText(host, scheme) catch return reject(.forwarded, .malformed)
    else
        directAuthority(input, scheme) catch return reject(.forwarded, .invalid_host);
    var metadata = metadataBase(input, effective_authority, scheme);
    metadata.forwarding_headers = if (parsed.present) .applied else .absent;
    if (walked.host != null) metadata.host_provenance = .forwarded;
    if (walked.scheme != null) metadata.scheme_provenance = .forwarded;
    metadata.client = walked.client;
    metadata.trusted_hops = walked.trusted_hops;
    if (walked.trusted_hops != 0) metadata.client_provenance = .forwarded;
    return .{ .accepted = metadata };
}

fn resolveXForwarded(
    comptime limits: forwarding.Limits,
    profile: *const forwarding.Profile(limits),
    input: Input,
) Result {
    var fields = request_fields.raw(input.bytes, input.fields).iterator();
    const parsed = request_x_forwarded.parse(limits, &fields, input.direct_scheme) catch |err| {
        return reject(.x_forwarded, mapXForwardedError(err));
    };
    const scheme = parsed.scheme orelse input.direct_scheme;
    const effective_authority = parsed.host orelse directAuthority(input, scheme) catch {
        return reject(.x_forwarded, .invalid_host);
    };
    var metadata = metadataBase(input, effective_authority, scheme);
    metadata.forwarding_headers = if (parsed.present) .applied else .absent;
    if (parsed.host != null) metadata.host_provenance = .x_forwarded_host;
    if (parsed.scheme != null) metadata.scheme_provenance = .x_forwarded_proto;
    walkXForwarded(limits, profile, &metadata, parsed.nodes[0..parsed.node_count]);
    return .{ .accepted = metadata };
}

fn directMetadata(input: Input, ignored: bool) error{InvalidHost}!Result {
    const effective_authority = directAuthority(input, input.direct_scheme) catch {
        return error.InvalidHost;
    };
    var metadata = metadataBase(input, effective_authority, input.direct_scheme);
    metadata.forwarding_headers = if (ignored) .ignored_untrusted else .absent;
    return .{ .accepted = metadata };
}

fn directAuthority(input: Input, scheme: authority.Scheme) !authority.Authority {
    const host = try request_fields.one(input.bytes, input.fields, "host");
    return authority.parse(host, scheme);
}

fn metadataBase(
    input: Input,
    effective_authority: authority.Authority,
    scheme: authority.Scheme,
) forwarding.Metadata {
    return .{
        .transport_peer = input.transport_peer,
        .connection_peer = input.connection_peer,
        .client = input.connection_peer,
        .authority = effective_authority,
        .scheme = scheme,
        .connection_source = input.connection_source,
        .client_provenance = baseClientProvenance(input.connection_source),
        .host_provenance = .host,
        .scheme_provenance = .connection,
        .forwarding_headers = .absent,
        .trusted_hops = 0,
    };
}

const ForwardedWalk = struct {
    client: address.Endpoint,
    host: ?authority.Text = null,
    scheme: ?authority.Scheme = null,
    trusted_hops: u16 = 0,
};

fn walkForwarded(
    comptime limits: forwarding.Limits,
    profile: *const forwarding.Profile(limits),
    connection_peer: address.Endpoint,
    elements: []const request_forwarded.Element,
) ForwardedWalk {
    var result = ForwardedWalk{ .client = connection_peer };

    var index = elements.len;
    while (index > 0) {
        index -= 1;
        const element = elements[index];
        if (result.host == null) result.host = element.host;
        if (result.scheme == null) result.scheme = element.scheme;
        if (index == 0) break;
        const writer = switch (element.node) {
            .endpoint => |value| value,
            .missing, .unknown, .obfuscated => break,
        };
        if (!profile.trustsEndpoint(writer)) break;
    }

    index = elements.len;
    while (index > 0) {
        if (!profile.trustsEndpoint(result.client)) break;
        index -= 1;
        result.client = switch (elements[index].node) {
            .endpoint => |value| value,
            .missing, .unknown, .obfuscated => break,
        };
        result.trusted_hops += 1;
    }
    return result;
}

fn walkXForwarded(
    comptime limits: forwarding.Limits,
    profile: *const forwarding.Profile(limits),
    metadata: *forwarding.Metadata,
    nodes: []const address.Endpoint,
) void {
    var index = nodes.len;
    while (index > 0) {
        if (!profile.trustsEndpoint(metadata.client)) break;
        index -= 1;
        metadata.client = nodes[index];
        metadata.client_provenance = .x_forwarded;
        metadata.trusted_hops += 1;
    }
}

fn selectedHeadersPresent(family: forwarding.HeaderFamily, input: Input) bool {
    if (family == .none) return false;
    var fields = request_fields.raw(input.bytes, input.fields).iterator();
    while (fields.next()) |field| switch (family) {
        .none => unreachable,
        .forwarded => if (syntax.eqlIgnoreCase(field.name, "forwarded")) return true,
        .x_forwarded => if (syntax.eqlIgnoreCase(field.name, "x-forwarded-for") or
            syntax.eqlIgnoreCase(field.name, "x-forwarded-host") or
            syntax.eqlIgnoreCase(field.name, "x-forwarded-proto")) return true,
    };
    return false;
}

fn baseClientProvenance(source: forwarding.ConnectionSource) forwarding.ClientProvenance {
    return switch (source) {
        .transport => .transport,
        .proxy_protocol_v2 => .proxy_protocol_v2,
        .proxy_protocol_v2_local => .proxy_protocol_v2_local,
    };
}

fn mapForwardedError(err: request_forwarded.ParseError) forwarding.BadRequestReason {
    return switch (err) {
        error.Malformed => .malformed,
        error.Duplicate => .duplicate,
        error.TooManyHops => .too_many_hops,
        error.TooManyParameters => .too_many_parameters,
    };
}

fn mapXForwardedError(err: request_x_forwarded.ParseError) forwarding.BadRequestReason {
    return switch (err) {
        error.Malformed => .malformed,
        error.Duplicate => .duplicate,
        error.TooManyHops => .too_many_hops,
    };
}

fn reject(family: forwarding.HeaderFamily, reason: forwarding.BadRequestReason) Result {
    return .{ .rejected = .{ .bad_request = .{ .family = family, .reason = reason } } };
}

const http_limits = @import("limits.zig");

const test_forwarding_limits = forwarding.Limits{
    .trusted_matchers_max = 4,
    .hops_max = 4,
    .parameters_per_element_max = 4,
};
const TestProfile = forwarding.Profile(test_forwarding_limits);
const Head = request_head.Decoder(http_limits.standard_request_head_limits);

test "untrusted direct forwarding bytes are ignored without parsing" {
    const profile = try TestProfile.init(.{
        .family = .forwarded,
        .trusted = &.{"10.0.0.0/8"},
    });
    var head = try parseHead(
        "GET / HTTP/1.1\r\nHost: direct.test\r\n" ++
            "Forwarded: not even remotely valid ]]]\r\n\r\n",
    );
    const result = resolve(test_forwarding_limits, &profile, inputFor(&head, "192.0.2.1"));
    const metadata = try expectAccepted(result);
    try std.testing.expectEqual(
        forwarding.HeaderDisposition.ignored_untrusted,
        metadata.forwarding_headers,
    );
    try std.testing.expectEqual(
        forwarding.ClientProvenance.transport,
        metadata.client_provenance,
    );
}

test "proxy-only profile rejects an untrusted peer with typed outcome" {
    const profile = try TestProfile.init(.{
        .family = .x_forwarded,
        .untrusted_peer = .reject,
        .trusted = &.{"10.0.0.0/8"},
    });
    var head = try parseHead("GET / HTTP/1.1\r\nHost: direct.test\r\n\r\n");
    const result = resolve(test_forwarding_limits, &profile, inputFor(&head, "192.0.2.1"));
    try std.testing.expect(result == .rejected);
    try std.testing.expect(result.rejected == .untrusted_peer);
}

test "only selected trusted family is parsed and applied" {
    const profile = try TestProfile.init(.{
        .family = .x_forwarded,
        .trusted = &.{"10.0.0.0/8"},
    });
    var head = try parseHead(
        "GET / HTTP/1.1\r\nHost: direct.test\r\n" ++
            "Forwarded: malformed ]]]\r\n" ++
            "X-Forwarded-For: 192.0.2.1, 10.1.1.2\r\n" ++
            "X-Forwarded-Host: public.test\r\n" ++
            "X-Forwarded-Proto: https\r\n\r\n",
    );
    const result = resolve(test_forwarding_limits, &profile, inputFor(&head, "10.9.9.9"));
    const metadata = try expectAccepted(result);
    try std.testing.expect(metadata.client.address.eql(try address.Address.parse("192.0.2.1")));
    try std.testing.expectEqual(authority.Scheme.https, metadata.scheme);
    try std.testing.expectEqual(
        forwarding.HostProvenance.x_forwarded_host,
        metadata.host_provenance,
    );
}

test "trusted malformed selected metadata becomes bad request" {
    const profile = try TestProfile.init(.{
        .family = .forwarded,
        .trusted = &.{"10.0.0.0/8"},
    });
    var head = try parseHead(
        "GET / HTTP/1.1\r\nHost: direct.test\r\nForwarded: for=unknown;for=_x\r\n\r\n",
    );
    const result = resolve(test_forwarding_limits, &profile, inputFor(&head, "10.0.0.1"));
    try std.testing.expect(result == .rejected);
    try std.testing.expectEqual(
        forwarding.BadRequestReason.duplicate,
        result.rejected.bad_request.reason,
    );
}

test "nearest-to-farthest walk stops beyond first untrusted claim" {
    const profile = try TestProfile.init(.{
        .family = .x_forwarded,
        .trusted = &.{"10.0.0.0/8"},
    });
    var head = try parseHead(
        "GET / HTTP/1.1\r\nHost: direct.test\r\n" ++
            "X-Forwarded-For: 192.0.2.9, 198.51.100.8\r\n\r\n",
    );
    const result = resolve(test_forwarding_limits, &profile, inputFor(&head, "10.0.0.1"));
    const metadata = try expectAccepted(result);
    try std.testing.expect(metadata.client.address.eql(
        try address.Address.parse("198.51.100.8"),
    ));
    try std.testing.expectEqual(@as(u16, 1), metadata.trusted_hops);
}

test "opaque nearest Forwarded node prevents older address consumption" {
    const profile = try TestProfile.init(.{
        .family = .forwarded,
        .trusted = &.{"10.0.0.0/8"},
    });
    var head = try parseHead(
        "GET / HTTP/1.1\r\nHost: direct.test\r\n" ++
            "Forwarded: for=192.0.2.9, for=unknown\r\n\r\n",
    );
    const metadata = try expectAccepted(resolve(
        test_forwarding_limits,
        &profile,
        inputFor(&head, "10.0.0.1"),
    ));
    try std.testing.expect(metadata.client.address.eql(try address.Address.parse("10.0.0.1")));
    try std.testing.expectEqual(@as(u16, 0), metadata.trusted_hops);
}

test "untrusted Forwarded prefix cannot replace trusted rightmost origin" {
    const profile = try TestProfile.init(.{
        .family = .forwarded,
        .trusted = &.{"10.0.0.0/8"},
    });
    var head = try parseHead(
        "GET / HTTP/1.1\r\nHost: direct.test\r\n" ++
            "Forwarded: for=192.0.2.9;host=evil.test;proto=http," ++
            " for=198.51.100.8;host=public.test;proto=https\r\n\r\n",
    );
    const metadata = try expectAccepted(resolve(
        test_forwarding_limits,
        &profile,
        inputFor(&head, "10.0.0.1"),
    ));
    try std.testing.expect(metadata.authority.eql(try authority.parse("public.test", .https)));
    try std.testing.expectEqual(authority.Scheme.https, metadata.scheme);
    try std.testing.expect(metadata.client.address.eql(
        try address.Address.parse("198.51.100.8"),
    ));
    try std.testing.expectEqual(@as(u16, 1), metadata.trusted_hops);
}

test "nearest trusted Forwarded hop owns differing host and proto" {
    const profile = try TestProfile.init(.{
        .family = .forwarded,
        .trusted = &.{"10.0.0.0/8"},
    });
    var head = try parseHead(
        "GET / HTTP/1.1\r\nHost: direct.test\r\n" ++
            "Forwarded: for=192.0.2.9;host=public.test;proto=https," ++
            " for=10.0.0.2;host=internal.test;proto=http\r\n\r\n",
    );
    const metadata = try expectAccepted(resolve(
        test_forwarding_limits,
        &profile,
        inputFor(&head, "10.0.0.1"),
    ));
    try std.testing.expect(metadata.authority.eql(try authority.parse("internal.test", .http)));
    try std.testing.expectEqual(authority.Scheme.http, metadata.scheme);
    try std.testing.expect(metadata.client.address.eql(try address.Address.parse("192.0.2.9")));
    try std.testing.expectEqual(@as(u16, 2), metadata.trusted_hops);
}

test "PROXY LOCAL keeps transport client provenance until HTTP overrides it" {
    const profile = try TestProfile.init(.{ .family = .none, .trusted = &.{"127.0.0.1"} });
    var head = try parseHead("GET / HTTP/1.1\r\nHost: local.test\r\n\r\n");
    var input = inputFor(&head, "127.0.0.1");
    input.connection_source = .proxy_protocol_v2_local;
    const metadata = try expectAccepted(resolve(test_forwarding_limits, &profile, input));
    try std.testing.expectEqual(
        forwarding.ClientProvenance.proxy_protocol_v2_local,
        metadata.client_provenance,
    );
}

test "trusted PROXY transport applies origin metadata without walking an untrusted client" {
    const profile = try TestProfile.init(.{
        .proxy_protocol = .v2_required,
        .family = .forwarded,
        .untrusted_peer = .reject,
        .trusted = &.{"10.0.0.0/8"},
    });
    var head = try parseHead(
        "GET / HTTP/1.1\r\nHost: direct.test\r\n" ++
            "Forwarded: for=198.51.100.7;proto=https;host=public.test\r\n\r\n",
    );
    var input = inputFor(&head, "10.0.0.1");
    input.connection_peer = .{
        .address = try address.Address.parse("192.0.2.5"),
        .port = 9000,
    };
    input.connection_source = .proxy_protocol_v2;
    const metadata = try expectAccepted(resolve(test_forwarding_limits, &profile, input));
    try std.testing.expectEqual(
        forwarding.HeaderDisposition.applied,
        metadata.forwarding_headers,
    );
    try std.testing.expectEqual(
        forwarding.ClientProvenance.proxy_protocol_v2,
        metadata.client_provenance,
    );
    try std.testing.expectEqual(authority.Scheme.https, metadata.scheme);
    try std.testing.expectEqual(@as(u16, 0), metadata.trusted_hops);
    try std.testing.expect(metadata.client.eql(input.connection_peer));
}

test "trusted PROXY transport rejects malformed metadata from an untrusted client hop" {
    const profile = try TestProfile.init(.{
        .proxy_protocol = .v2_required,
        .family = .forwarded,
        .untrusted_peer = .reject,
        .trusted = &.{"10.0.0.0/8"},
    });
    var head = try parseHead(
        "GET / HTTP/1.1\r\nHost: direct.test\r\nForwarded: invalid ]]]\r\n\r\n",
    );
    var input = inputFor(&head, "10.0.0.1");
    input.connection_peer = .{
        .address = try address.Address.parse("192.0.2.5"),
        .port = 9000,
    };
    input.connection_source = .proxy_protocol_v2;
    const result = resolve(test_forwarding_limits, &profile, input);
    try std.testing.expect(result == .rejected);
    try std.testing.expectEqual(
        forwarding.BadRequestReason.malformed,
        result.rejected.bad_request.reason,
    );
}

fn parseHead(raw: []const u8) !Head {
    var head = Head.init();
    const result = head.feed(raw);
    if (result.state != .ready) return error.TestUnexpectedResult;
    return head;
}

fn inputFor(head: *const Head, peer: []const u8) Input {
    const endpoint = address.Endpoint{
        .address = address.Address.parse(peer) catch unreachable,
        .port = 8080,
    };
    return .{
        .bytes = head.bytes(),
        .fields = head.fields(),
        .transport_peer = endpoint,
        .connection_peer = endpoint,
    };
}

fn expectAccepted(result: Result) !forwarding.Metadata {
    return switch (result) {
        .accepted => |metadata| metadata,
        .rejected => error.TestUnexpectedResult,
    };
}
