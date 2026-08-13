const std = @import("std");
const request_cors = @import("internal/http1/request_cors.zig");

pub const exact_origins_hard_max: u8 = 64;
pub const exact_request_headers_hard_max: u8 = request_cors.request_header_names_max;
pub const default_max_age_seconds: u32 = 600;
// Hard-max duplicate validation is bounded but exceeds Zig's default comptime quota.
const validation_eval_branch_quota = 1_000_000;

pub const RequestHeaders = union(enum) {
    reflect,
    /// Every requested name must occur in this case-insensitive set.
    exact: []const []const u8,
};

pub const Options = struct {
    allow_null: bool = false,
    request_headers: RequestHeaders = .reflect,
    max_age_seconds: u32 = default_max_age_seconds,
};

pub const Exact = struct {
    origins: []const []const u8,
    parsed_origins: []const request_cors.Origin = &.{},
    credentials: bool = false,
    allow_null: bool = false,
    request_headers: RequestHeaders = .reflect,
    max_age_seconds: u32 = default_max_age_seconds,
};

pub const ExactOptions = struct {
    credentials: bool = false,
    allow_null: bool = false,
    request_headers: RequestHeaders = .reflect,
    max_age_seconds: u32 = default_max_age_seconds,
};

pub const Policy = union(enum) {
    disabled,
    allow_any: Options,
    allow_exact: Exact,
    allow_any_credentialed: Options,

    pub fn enabled(self: Policy) bool {
        return self != .disabled;
    }

    pub fn allowsNull(self: Policy) bool {
        return switch (self) {
            .disabled => false,
            .allow_any, .allow_any_credentialed => |options| options.allow_null,
            .allow_exact => |options| options.allow_null,
        };
    }

    pub fn sendsCredentials(self: Policy) bool {
        return switch (self) {
            .allow_any_credentialed => true,
            .allow_exact => |options| options.credentials,
            .disabled, .allow_any => false,
        };
    }

    pub fn requestHeaderPolicy(self: Policy) RequestHeaders {
        return switch (self) {
            .disabled => .reflect,
            .allow_any, .allow_any_credentialed => |options| options.request_headers,
            .allow_exact => |options| options.request_headers,
        };
    }

    pub fn maxAgeSeconds(self: Policy) u32 {
        return switch (self) {
            .disabled => default_max_age_seconds,
            .allow_any, .allow_any_credentialed => |options| options.max_age_seconds,
            .allow_exact => |options| options.max_age_seconds,
        };
    }
};

pub const disabled: Policy = .disabled;
pub const allow_any: Policy = .{ .allow_any = .{} };
pub const allow_any_credentialed: Policy = .{ .allow_any_credentialed = .{} };

pub fn any(comptime options: Options) Policy {
    return validate(.{ .allow_any = options });
}

pub fn exact(
    comptime origins: []const []const u8,
    comptime options: ExactOptions,
) Policy {
    return validate(.{ .allow_exact = .{
        .origins = origins,
        .credentials = options.credentials,
        .allow_null = options.allow_null,
        .request_headers = options.request_headers,
        .max_age_seconds = options.max_age_seconds,
    } });
}

pub fn anyCredentialed(comptime options: Options) Policy {
    return validate(.{ .allow_any_credentialed = options });
}

pub const PolicyIssue = enum(u8) {
    exact_origins_empty,
    exact_origins_above_hard_max,
    invalid_origin,
    null_origin_requires_option,
    duplicate_origin,
    request_headers_above_hard_max,
    invalid_request_header,
    duplicate_request_header,

    pub fn diagnostic(problem: PolicyIssue) []const u8 {
        return switch (problem) {
            .exact_origins_empty => "PLOOF-E3300 exact CORS origin set must not be empty",
            .exact_origins_above_hard_max => "PLOOF-E3301 exact CORS origin set exceeds 64 entries",
            .invalid_origin => "PLOOF-E3302 invalid exact CORS origin",
            .null_origin_requires_option => "PLOOF-E3303 CORS null origin requires allow_null",
            .duplicate_origin => "PLOOF-E3304 duplicate exact CORS origin",
            .request_headers_above_hard_max => "PLOOF-E3305 exact CORS headers exceed limit 64",
            .invalid_request_header => "PLOOF-E3306 invalid exact CORS request header",
            .duplicate_request_header => "PLOOF-E3307 duplicate exact CORS request header",
        };
    }
};

pub fn issue(policy: Policy) ?PolicyIssue {
    return switch (policy) {
        .disabled => null,
        .allow_any, .allow_any_credentialed => |options| headerIssue(
            options.request_headers,
        ),
        .allow_exact => |options| exactIssue(options),
    };
}

pub fn validate(comptime policy: Policy) Policy {
    @setEvalBranchQuota(validation_eval_branch_quota);
    const problem = comptime issue(policy);
    if (problem) |value| @compileError(value.diagnostic());
    return switch (policy) {
        .allow_exact => |options| .{ .allow_exact = .{
            .origins = options.origins,
            .parsed_origins = &ParsedOrigins(options.origins).values,
            .credentials = options.credentials,
            .allow_null = options.allow_null,
            .request_headers = options.request_headers,
            .max_age_seconds = options.max_age_seconds,
        } },
        else => policy,
    };
}

fn ParsedOrigins(comptime origins: []const []const u8) type {
    return struct {
        pub const values: [origins.len]request_cors.Origin = parsed: {
            @setEvalBranchQuota(validation_eval_branch_quota);
            var parsed: [origins.len]request_cors.Origin = undefined;
            for (origins, 0..) |origin, index| {
                parsed[index] = request_cors.parseOrigin(origin).?;
            }
            break :parsed parsed;
        };
    };
}

fn exactIssue(options: Exact) ?PolicyIssue {
    if (options.origins.len == 0) return .exact_origins_empty;
    if (options.origins.len > exact_origins_hard_max) {
        return .exact_origins_above_hard_max;
    }
    var parsed_origins: [exact_origins_hard_max]request_cors.Origin = undefined;
    for (options.origins, 0..) |origin, index| {
        const parsed = request_cors.parseOrigin(origin) orelse return .invalid_origin;
        if (parsed == .opaque_null) return .null_origin_requires_option;
        for (parsed_origins[0..index]) |prior| {
            if (request_cors.originEquivalentOrigins(parsed, prior)) return .duplicate_origin;
        }
        parsed_origins[index] = parsed;
    }
    return headerIssue(options.request_headers);
}

fn headerIssue(policy: RequestHeaders) ?PolicyIssue {
    const headers = switch (policy) {
        .reflect => return null,
        .exact => |names| names,
    };
    if (headers.len > exact_request_headers_hard_max) {
        return .request_headers_above_hard_max;
    }
    var hashes: [exact_request_headers_hard_max]u64 = undefined;
    for (headers, 0..) |name, index| {
        if (!request_cors.methodValid(name)) return .invalid_request_header;
        const hash = asciiFoldHash(name);
        for (hashes[0..index], headers[0..index]) |prior_hash, prior| {
            if (hash == prior_hash and asciiEqualIgnoreCase(name, prior)) {
                return .duplicate_request_header;
            }
        }
        hashes[index] = hash;
    }
    return null;
}

fn asciiFoldHash(value: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (value) |byte| {
        hash = (hash ^ asciiLower(byte)) *% 0x100000001b3;
    }
    return hash;
}

fn asciiEqualIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        if (asciiLower(left_byte) != asciiLower(right_byte)) return false;
    }
    return true;
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

test "CORS policy constructors keep unsafe any-credentialed mode explicit" {
    const wildcard = any(.{ .allow_null = true });
    const reflected = anyCredentialed(.{ .max_age_seconds = 42 });
    const selected = exact(&.{"https://app.example"}, .{ .credentials = true });
    try std.testing.expect(wildcard == .allow_any);
    try std.testing.expect(wildcard.allowsNull());
    try std.testing.expect(!wildcard.sendsCredentials());
    try std.testing.expect(reflected == .allow_any_credentialed);
    try std.testing.expect(reflected.sendsCredentials());
    try std.testing.expectEqual(@as(u32, 42), reflected.maxAgeSeconds());
    try std.testing.expect(selected.sendsCredentials());
    try std.testing.expectEqual(@as(usize, 1), selected.allow_exact.parsed_origins.len);
    try std.testing.expect(request_cors.originEquivalentOrigins(
        request_cors.parseOrigin("HTTPS://APP.EXAMPLE:443").?,
        selected.allow_exact.parsed_origins[0],
    ));

    const rebuilt = validate(.{ .allow_exact = .{
        .origins = &.{"https://app.example"},
        .parsed_origins = &.{.opaque_null},
    } });
    try std.testing.expect(rebuilt.allow_exact.parsed_origins[0] == .tuple);
}

test "CORS policy validation distinguishes every bounded issue" {
    const too_many_origins = [_][]const u8{"https://app.example"} **
        (exact_origins_hard_max + 1);
    const too_many_headers = [_][]const u8{"X-Trace"} **
        (exact_request_headers_hard_max + 1);
    try std.testing.expectEqual(
        PolicyIssue.exact_origins_empty,
        issue(.{ .allow_exact = .{ .origins = &.{} } }).?,
    );
    try std.testing.expectEqual(
        PolicyIssue.exact_origins_above_hard_max,
        issue(.{ .allow_exact = .{ .origins = &too_many_origins } }).?,
    );
    try std.testing.expectEqual(
        PolicyIssue.invalid_origin,
        issue(.{ .allow_exact = .{ .origins = &.{"https://bad.example/"} } }).?,
    );
    try std.testing.expectEqual(
        PolicyIssue.null_origin_requires_option,
        issue(.{ .allow_exact = .{ .origins = &.{"null"} } }).?,
    );
    try std.testing.expectEqual(
        PolicyIssue.duplicate_origin,
        issue(.{ .allow_exact = .{
            .origins = &.{ "HTTPS://APP.EXAMPLE:443", "https://app.example" },
        } }).?,
    );
    try std.testing.expectEqual(
        PolicyIssue.invalid_request_header,
        issue(.{ .allow_any = .{
            .request_headers = .{ .exact = &.{"bad name"} },
        } }).?,
    );
    try std.testing.expectEqual(
        PolicyIssue.request_headers_above_hard_max,
        issue(.{ .allow_any = .{
            .request_headers = .{ .exact = &too_many_headers },
        } }).?,
    );
    try std.testing.expectEqual(
        PolicyIssue.duplicate_request_header,
        issue(.{ .allow_any = .{
            .request_headers = .{ .exact = &.{ "X-Trace", "x-trace" } },
        } }).?,
    );
}

test "empty exact request-header set deliberately denies all requested headers" {
    const policy = exact(&.{"https://app.example"}, .{
        .request_headers = .{ .exact = &.{} },
    });
    try std.testing.expectEqual(@as(?PolicyIssue, null), issue(policy));
}
