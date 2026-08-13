const std = @import("std");
const address = @import("address.zig");
const authority = @import("internal/http1/authority.zig");

pub const Authority = authority.Authority;
pub const Host = authority.Host;
pub const Scheme = authority.Scheme;

pub const Limits = struct {
    trusted_matchers_max: u16 = 64,
    hops_max: u16 = 8,
    parameters_per_element_max: u8 = 16,
};

pub const standard_limits = Limits{};

pub const HeaderFamily = enum(u2) {
    none,
    forwarded,
    x_forwarded,
};

pub const ProxyProtocol = enum(u1) {
    disabled,
    v2_required,
};

pub const UntrustedPeerPolicy = enum(u1) {
    allow_direct,
    reject,
};

pub const Config = struct {
    proxy_protocol: ProxyProtocol = .disabled,
    family: HeaderFamily = .none,
    untrusted_peer: UntrustedPeerPolicy = .allow_direct,
    /// IPv6 link-local peers are never trusted because their interface scope is unavailable.
    trusted: []const []const u8 = &.{},
};

pub const ProfileError = error{
    TooManyTrustedMatchers,
    InvalidTrustedMatcher,
    ContradictoryPolicy,
    RequiredProxyHasNoTrustedPeers,
};

pub const ProfileFailure = struct {
    reason: ProfileError,
    trusted_matcher_index: ?usize = null,
};

fn profileFailure(reason: ProfileError, index: ?usize) ProfileFailure {
    return .{ .reason = reason, .trusted_matcher_index = index };
}

pub fn Profile(comptime limits: Limits) type {
    validateLimits(limits);
    return struct {
        const Self = @This();
        family: HeaderFamily,
        proxy_protocol: ProxyProtocol,
        untrusted_peer: UntrustedPeerPolicy,
        trusted: [limits.trusted_matchers_max]address.Matcher,
        trusted_count: u16,
        pub fn init(config: Config) ProfileError!Self {
            return switch (initDetailed(config)) {
                .profile => |profile| profile,
                .failure => |failure| failure.reason,
            };
        }
        pub const InitResult = union(enum) { profile: Self, failure: ProfileFailure };
        /// Returns startup validation detail without formatting or allocation.
        pub fn initDetailed(config: Config) InitResult {
            if (config.proxy_protocol == .v2_required and config.untrusted_peer == .allow_direct) {
                return .{ .failure = profileFailure(error.ContradictoryPolicy, null) };
            }
            if (config.trusted.len > limits.trusted_matchers_max) {
                return .{ .failure = profileFailure(
                    error.TooManyTrustedMatchers,
                    limits.trusted_matchers_max,
                ) };
            }
            var profile: Self = .{
                .family = config.family,
                .proxy_protocol = config.proxy_protocol,
                .untrusted_peer = config.untrusted_peer,
                .trusted = undefined,
                .trusted_count = @intCast(config.trusted.len),
            };
            var first_inert: ?usize = null;
            var has_usable_matcher = false;
            for (config.trusted, 0..) |raw, index| {
                const matcher = address.Matcher.parse(raw) catch {
                    return .{ .failure = profileFailure(error.InvalidTrustedMatcher, index) };
                };
                profile.trusted[index] = matcher;
                if (matcherCanTrustPeer(matcher)) {
                    has_usable_matcher = true;
                } else if (first_inert == null) {
                    first_inert = index;
                }
            }
            if (config.proxy_protocol == .v2_required and !has_usable_matcher) {
                return .{ .failure = profileFailure(
                    error.RequiredProxyHasNoTrustedPeers,
                    first_inert,
                ) };
            }
            return .{ .profile = profile };
        }

        pub fn trusts(profile: *const Self, candidate: address.Address) bool {
            if (candidate.isIpv6LinkLocal()) return false;
            for (profile.trusted[0..profile.trusted_count]) |matcher| {
                if (matcher.matches(candidate)) return true;
            }
            return false;
        }

        pub fn trustsEndpoint(profile: *const Self, candidate: address.Endpoint) bool {
            return profile.trusts(candidate.address);
        }
    };
}

fn matcherCanTrustPeer(matcher: address.Matcher) bool {
    return switch (matcher) {
        .exact => |exact| !exact.isIpv6LinkLocal(),
        .cidr => |cidr| switch (cidr) {
            .ipv4 => true,
            .ipv6 => |network| network.prefix < 10 or
                !(address.Address{ .ipv6 = network.network }).isIpv6LinkLocal(),
        },
    };
}

pub const ConnectionSource = enum(u2) {
    transport,
    proxy_protocol_v2,
    proxy_protocol_v2_local,
};

pub const ClientProvenance = enum(u3) {
    transport,
    proxy_protocol_v2,
    proxy_protocol_v2_local,
    forwarded,
    x_forwarded,
};

pub const HostProvenance = enum(u2) {
    host,
    forwarded,
    x_forwarded_host,
};

pub const SchemeProvenance = enum(u2) {
    connection,
    forwarded,
    x_forwarded_proto,
};

pub const HeaderDisposition = enum(u2) {
    absent,
    applied,
    ignored_untrusted,
};

pub const Metadata = struct {
    transport_peer: address.Endpoint,
    connection_peer: address.Endpoint,
    client: address.Endpoint,
    /// Host text borrows the request head and expires with the request.
    authority: Authority,
    scheme: Scheme,
    connection_source: ConnectionSource,
    client_provenance: ClientProvenance,
    host_provenance: HostProvenance,
    scheme_provenance: SchemeProvenance,
    forwarding_headers: HeaderDisposition,
    trusted_hops: u16,

    pub fn provenance(metadata: Metadata) Provenance {
        return .{
            .connection_source = metadata.connection_source,
            .client = metadata.client_provenance,
            .host = metadata.host_provenance,
            .scheme = metadata.scheme_provenance,
            .headers = metadata.forwarding_headers,
            .trusted_hops = metadata.trusted_hops,
        };
    }
};

pub const Provenance = struct {
    connection_source: ConnectionSource,
    client: ClientProvenance,
    host: HostProvenance,
    scheme: SchemeProvenance,
    headers: HeaderDisposition,
    trusted_hops: u16,
};

pub const Rejection = union(enum) {
    bad_request: BadRequest,
    untrusted_peer: UntrustedPeer,

    pub const BadRequest = struct {
        family: HeaderFamily,
        reason: BadRequestReason,
    };

    pub const UntrustedPeer = struct {
        peer: address.Endpoint,
    };
};

pub const BadRequestReason = enum(u4) {
    invalid_host,
    malformed,
    duplicate,
    contradictory,
    too_many_hops,
    too_many_parameters,
};

fn validateLimits(comptime limits: Limits) void {
    if (limits.trusted_matchers_max == 0 or limits.trusted_matchers_max > 1024) {
        @compileError("forwarding trusted_matchers_max must be in 1...1024");
    }
    if (limits.hops_max == 0 or limits.hops_max > 64) {
        @compileError("forwarding hops_max must be in 1...64");
    }
    if (limits.parameters_per_element_max == 0 or
        limits.parameters_per_element_max > 64)
    {
        @compileError("forwarding parameters_per_element_max must be in 1...64");
    }
}

test "trust profile parses exact and CIDR matchers once" {
    const TestProfile = Profile(.{
        .trusted_matchers_max = 3,
        .hops_max = 4,
        .parameters_per_element_max = 4,
    });
    const profile = try TestProfile.init(.{
        .family = .forwarded,
        .trusted = &.{ "127.0.0.1", "10.0.0.0/8", "2001:db8::/32" },
    });
    try std.testing.expect(profile.trusts(try address.Address.parse("127.0.0.1")));
    try std.testing.expect(profile.trusts(try address.Address.parse("10.9.8.7")));
    try std.testing.expect(profile.trusts(try address.Address.parse("2001:db8::1")));
    try std.testing.expect(!profile.trusts(try address.Address.parse("192.0.2.1")));
}

test "forwarding trust always excludes unscoped IPv6 link-local peers" {
    const TestProfile = Profile(.{
        .trusted_matchers_max = 2,
        .hops_max = 1,
        .parameters_per_element_max = 1,
    });
    const profile = try TestProfile.init(.{ .trusted = &.{ "::/0", "fe80::1" } });
    try std.testing.expect(profile.trusts(try address.Address.parse("2001:db8::1")));
    try std.testing.expect(!profile.trusts(try address.Address.parse("fe80::1")));
    try std.testing.expect(!profile.trusts(try address.Address.parse("febf::ffff")));
    try std.testing.expect(profile.trusts(try address.Address.parse("fec0::1")));
}

test "detailed profile validation reports the failing matcher index" {
    const TestProfile = Profile(.{
        .trusted_matchers_max = 3,
        .hops_max = 1,
        .parameters_per_element_max = 1,
    });
    const result = TestProfile.initDetailed(.{
        .trusted = &.{ "127.0.0.1", "localhost", "::1" },
    });
    const failure = switch (result) {
        .profile => return error.TestUnexpectedResult,
        .failure => |value| value,
    };
    try std.testing.expectEqual(error.InvalidTrustedMatcher, failure.reason);
    try std.testing.expectEqual(@as(?usize, 1), failure.trusted_matcher_index);
}

test "trust profile reports bounded startup configuration errors" {
    const TestProfile = Profile(.{
        .trusted_matchers_max = 1,
        .hops_max = 1,
        .parameters_per_element_max = 1,
    });
    try std.testing.expectError(
        error.TooManyTrustedMatchers,
        TestProfile.init(.{ .trusted = &.{ "127.0.0.1", "::1" } }),
    );
    try std.testing.expectError(
        error.InvalidTrustedMatcher,
        TestProfile.init(.{ .trusted = &.{"localhost"} }),
    );
    try std.testing.expectError(
        error.ContradictoryPolicy,
        TestProfile.init(.{
            .proxy_protocol = .v2_required,
            .trusted = &.{"127.0.0.1"},
        }),
    );
    try std.testing.expectError(
        error.RequiredProxyHasNoTrustedPeers,
        TestProfile.init(.{
            .proxy_protocol = .v2_required,
            .untrusted_peer = .reject,
        }),
    );
}

test "required proxy rejects only entirely inert link-local trust sets" {
    const TestProfile = Profile(.{
        .trusted_matchers_max = 2,
        .hops_max = 1,
        .parameters_per_element_max = 1,
    });
    const required = Config{
        .proxy_protocol = .v2_required,
        .untrusted_peer = .reject,
    };
    for ([_][]const u8{ "fe80::1", "fe90::/16" }) |raw| {
        var config = required;
        config.trusted = &.{raw};
        const failure = switch (TestProfile.initDetailed(config)) {
            .profile => return error.TestUnexpectedResult,
            .failure => |value| value,
        };
        try std.testing.expectEqual(error.RequiredProxyHasNoTrustedPeers, failure.reason);
        try std.testing.expectEqual(@as(?usize, 0), failure.trusted_matcher_index);
        try std.testing.expectError(
            error.RequiredProxyHasNoTrustedPeers,
            TestProfile.init(config),
        );
    }

    var broad = required;
    broad.trusted = &.{"fe80::/9"};
    const profile = try TestProfile.init(broad);
    try std.testing.expect(!profile.trusts(try address.Address.parse("fe80::1")));
    try std.testing.expect(profile.trusts(try address.Address.parse("fec0::1")));

    var mixed = required;
    mixed.trusted = &.{ "fe80::/10", "2001:db8::/32" };
    _ = try TestProfile.init(mixed);
}

test {
    _ = @import("internal/http1/authority.zig");
    _ = @import("internal/http1/request_forwarded.zig");
    _ = @import("internal/http1/request_x_forwarded.zig");
    _ = @import("internal/http1/request_proxy_identity.zig");
}
