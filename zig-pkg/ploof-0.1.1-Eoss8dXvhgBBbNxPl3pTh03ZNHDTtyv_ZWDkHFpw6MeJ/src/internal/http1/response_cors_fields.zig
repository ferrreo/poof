const std = @import("std");
const cors = @import("../../cors.zig");
const fuzz_support = @import("testing/smith.zig");
const request_cors = @import("request_cors.zig");
const response_headers = @import("response_headers.zig");
const syntax = @import("syntax.zig");

pub const fields_max: u8 = 6;
pub const fields_bytes_max: usize = 64;
pub const capacity_attempts_max: usize = 3;
pub const vary_origin = "Origin";
pub const vary_preflight =
    "Origin, Access-Control-Request-Method, Access-Control-Request-Headers";
pub const field_line_bytes_min = "vary: ".len + vary_preflight.len + "\r\n".len;

pub const Value = union(enum) {
    bytes: []const u8,
    max_age_seconds: u32,
};

pub const Field = struct {
    name: []const u8,
    value: Value,
};

pub const Fields = struct {
    allow_origin: ?[]const u8 = null,
    allow_method: ?[]const u8 = null,
    allow_headers: ?[]const u8 = null,
    max_age_seconds: ?u32 = null,
    count: u8 = 0,
    managed: bool = false,
    credentials: bool = false,
    vary: Vary = .none,

    pub fn at(self: *const Fields, index: usize) Field {
        std.debug.assert(index < self.count);
        var cursor: u8 = 0;
        if (self.allow_origin) |value| {
            if (index == cursor) return .{
                .name = "access-control-allow-origin",
                .value = .{ .bytes = value },
            };
            cursor += 1;
        }
        if (self.credentials) {
            if (index == cursor) return .{
                .name = "access-control-allow-credentials",
                .value = .{ .bytes = "true" },
            };
            cursor += 1;
        }
        if (self.allow_method) |value| {
            if (index == cursor) return .{
                .name = "access-control-allow-methods",
                .value = .{ .bytes = value },
            };
            cursor += 1;
        }
        if (self.allow_headers) |value| {
            if (index == cursor) return .{
                .name = "access-control-allow-headers",
                .value = .{ .bytes = value },
            };
            cursor += 1;
        }
        if (self.max_age_seconds) |value| {
            if (index == cursor) return .{
                .name = "access-control-max-age",
                .value = .{ .max_age_seconds = value },
            };
            cursor += 1;
        }
        std.debug.assert(self.vary != .none);
        std.debug.assert(index == cursor);
        return .{
            .name = "vary",
            .value = .{ .bytes = switch (self.vary) {
                .origin => vary_origin,
                .preflight => vary_preflight,
                .none => unreachable,
            } },
        };
    }

    pub fn isPreflight(self: Fields) bool {
        return self.vary == .preflight;
    }

    pub fn capacityFallback(self: Fields) ?Fields {
        if (!self.managed or self.count == 0) return null;
        if (self.vary != .none and self.count > 1) return .{
            .count = 1,
            .managed = true,
            .vary = self.vary,
        };
        return .{ .managed = true, .vary = self.vary };
    }

    fn added(self: *Fields) void {
        std.debug.assert(self.count < fields_max);
        self.count += 1;
    }
};

const Vary = enum(u2) { none, origin, preflight };

comptime {
    if (@sizeOf(Fields) > fields_bytes_max) @compileError("CORS fields storage exceeds 64 bytes");
}

pub const PreflightStatus = enum(u16) {
    no_content = 204,
    forbidden = 403,
};

pub const PreflightInput = struct {
    origin: request_cors.Value,
    requested_method: request_cors.Value,
    requested_headers: request_cors.Value = .absent,
    route_selected: bool,
};

pub const PreflightDecision = struct {
    status: PreflightStatus,
    fields: Fields,
};

pub fn actual(policy: cors.Policy, origin: request_cors.Value) Fields {
    return actualRequestOrigin(policy, origin, null);
}

pub fn actualRequest(policy: cors.Policy, request: request_cors.Request) Fields {
    return actualRequestOrigin(policy, request.origin, request.parsed_origin);
}

pub fn actualRequestBounded(
    policy: cors.Policy,
    request: request_cors.Request,
    field_line_bytes_max: u32,
) Fields {
    const fields = actualRequest(policy, request);
    if (fieldsFit(fields, field_line_bytes_max)) return fields;
    return varyOnly(.origin, field_line_bytes_max);
}

fn actualRequestOrigin(
    policy: cors.Policy,
    origin: request_cors.Value,
    parsed_origin: ?request_cors.Origin,
) Fields {
    if (!policy.enabled()) return .{};
    var fields = Fields{ .managed = true };
    const allowed = allowedOrigin(policy, origin, parsed_origin) orelse {
        fields.vary = .origin;
        fields.added();
        return fields;
    };
    fields.allow_origin = allowed;
    fields.added();
    if (policy.sendsCredentials()) {
        fields.credentials = true;
        fields.added();
    }
    fields.vary = .origin;
    fields.added();
    return fields;
}

pub fn preflight(policy: cors.Policy, input: PreflightInput) PreflightDecision {
    return preflightParsed(policy, input, null, null);
}

pub fn preflightRequest(
    policy: cors.Policy,
    request: request_cors.Request,
    route_selected: bool,
) PreflightDecision {
    return preflightParsed(policy, .{
        .origin = request.origin,
        .requested_method = request.requested_method,
        .requested_headers = request.requested_headers,
        .route_selected = route_selected,
    }, request.parsed_origin, request.parsed_requested_headers);
}

pub fn preflightRequestBounded(
    policy: cors.Policy,
    request: request_cors.Request,
    route_selected: bool,
    field_line_bytes_max: u32,
) PreflightDecision {
    const decision = preflightParsed(policy, .{
        .origin = request.origin,
        .requested_method = request.requested_method,
        .requested_headers = request.requested_headers,
        .route_selected = route_selected,
    }, request.parsed_origin, request.parsed_requested_headers);
    if (fieldsFit(decision.fields, field_line_bytes_max)) return decision;
    return .{
        .status = .forbidden,
        .fields = varyOnly(.preflight, field_line_bytes_max),
    };
}

fn preflightParsed(
    policy: cors.Policy,
    input: PreflightInput,
    parsed_origin: ?request_cors.Origin,
    parsed_headers: ?request_cors.HeaderList,
) PreflightDecision {
    if (!policy.enabled()) return .{ .status = .forbidden, .fields = .{} };
    var fields = Fields{ .managed = true };
    const origin = allowedOrigin(policy, input.origin, parsed_origin) orelse {
        return deniedPreflight(fields);
    };
    const method = input.requested_method.get() orelse return deniedPreflight(fields);
    if (!input.route_selected or !request_cors.methodValid(method)) {
        return deniedPreflight(fields);
    }
    const requested_headers = allowedHeaders(
        policy,
        input.requested_headers,
        parsed_headers,
    ) orelse {
        return deniedPreflight(fields);
    };
    fields.allow_origin = origin;
    fields.added();
    if (policy.sendsCredentials()) {
        fields.credentials = true;
        fields.added();
    }
    fields.allow_method = method;
    fields.added();
    switch (requested_headers) {
        .none => {},
        .value => |headers| {
            fields.allow_headers = headers;
            fields.added();
        },
    }
    fields.max_age_seconds = policy.maxAgeSeconds();
    fields.added();
    fields.vary = .preflight;
    fields.added();
    return .{ .status = .no_content, .fields = fields };
}

fn deniedPreflight(mut_fields: Fields) PreflightDecision {
    var fields = mut_fields;
    fields.vary = .preflight;
    fields.added();
    return .{ .status = .forbidden, .fields = fields };
}

const AllowedHeaders = union(enum) {
    none,
    value: []const u8,
};

fn allowedHeaders(
    policy: cors.Policy,
    value: request_cors.Value,
    parsed: ?request_cors.HeaderList,
) ?AllowedHeaders {
    return switch (value) {
        .absent => .none,
        .invalid => null,
        .value => |headers| allowed: {
            const list = parsed orelse request_cors.parseHeaderList(headers) orelse return null;
            switch (policy.requestHeaderPolicy()) {
                .reflect => {},
                .exact => |names| if (!request_cors.headersAllowedParsed(list, names)) {
                    return null;
                },
            }
            break :allowed .{ .value = headers };
        },
    };
}

fn allowedOrigin(
    policy: cors.Policy,
    value: request_cors.Value,
    parsed_origin: ?request_cors.Origin,
) ?[]const u8 {
    if (!policy.enabled()) return null;
    const raw = value.get() orelse return null;
    const parsed = parsed_origin orelse request_cors.parseOrigin(raw) orelse return null;
    if (parsed == .opaque_null and !policy.allowsNull()) return null;
    return switch (policy) {
        .disabled => null,
        .allow_any => "*",
        .allow_any_credentialed => raw,
        .allow_exact => |options| if (parsed == .opaque_null or
            originInSet(parsed, options.parsed_origins))
            raw
        else
            null,
    };
}

fn fieldsFit(fields: Fields, field_line_bytes_max: u32) bool {
    for (0..fields.count) |index| {
        if (fieldLineBytes(fields.at(index)) > field_line_bytes_max) return false;
    }
    return true;
}

fn fieldLineBytes(field: Field) usize {
    const value_bytes = switch (field.value) {
        .bytes => |value| value.len,
        .max_age_seconds => |value| decimalDigits(value),
    };
    return field.name.len + ": \r\n".len + value_bytes;
}

fn decimalDigits(value: u32) usize {
    if (value < 10) return 1;
    if (value < 100) return 2;
    if (value < 1_000) return 3;
    if (value < 10_000) return 4;
    if (value < 100_000) return 5;
    if (value < 1_000_000) return 6;
    if (value < 10_000_000) return 7;
    if (value < 100_000_000) return 8;
    if (value < 1_000_000_000) return 9;
    return 10;
}

fn varyOnly(vary: Vary, field_line_bytes_max: u32) Fields {
    const value = switch (vary) {
        .origin => vary_origin,
        .preflight => vary_preflight,
        .none => unreachable,
    };
    var fields = Fields{ .managed = true, .vary = vary };
    if (fieldLineBytes(.{
        .name = "vary",
        .value = .{ .bytes = value },
    }) <= field_line_bytes_max) fields.added();
    return fields;
}

fn originInSet(
    origin: request_cors.Origin,
    allowed: []const request_cors.Origin,
) bool {
    for (allowed) |candidate| {
        if (request_cors.originEquivalentOrigins(origin, candidate)) return true;
    }
    return false;
}

pub const OverlayError = error{ConflictingCorsHeader};

pub fn Overlay(comptime Source: type) type {
    return struct {
        const Self = @This();

        source: *const Source,
        synthetic: Fields,
        max_age_wire: [10]u8 = undefined,
        max_age_length: u8 = 0,

        pub fn init(source: *const Source, synthetic: Fields) OverlayError!Self {
            if (synthetic.managed) try rejectConflicts(source);
            var result = Self{ .source = source, .synthetic = synthetic };
            for (0..synthetic.count) |index| switch (synthetic.at(index).value) {
                .bytes => {},
                .max_age_seconds => |seconds| {
                    const wire = std.fmt.bufPrint(&result.max_age_wire, "{d}", .{seconds}) catch {
                        unreachable;
                    };
                    result.max_age_length = @intCast(wire.len);
                },
            };
            return result;
        }

        pub fn len(self: *const Self) usize {
            return self.source.len() + self.synthetic.count;
        }

        pub fn at(self: *const Self, index: usize) response_headers.Field {
            const source_count = self.source.len();
            if (index < source_count) return self.source.at(index);
            const field = self.synthetic.at(index - source_count);
            return .{
                .name = field.name,
                .value = switch (field.value) {
                    .bytes => |bytes| bytes,
                    .max_age_seconds => self.max_age_wire[0..self.max_age_length],
                },
            };
        }
    };
}

fn rejectConflicts(source: anytype) OverlayError!void {
    var index: usize = 0;
    while (index < source.len()) : (index += 1) {
        if (managedName(source.at(index).name)) return error.ConflictingCorsHeader;
    }
}

fn managedName(name: []const u8) bool {
    const managed = [_][]const u8{
        "access-control-allow-origin",
        "access-control-allow-credentials",
        "access-control-allow-methods",
        "access-control-allow-headers",
        "access-control-max-age",
    };
    for (managed) |candidate| {
        if (syntax.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

const FakeHeaders = struct {
    fields: []const response_headers.Field,

    pub fn len(self: *const FakeHeaders) usize {
        return self.fields.len;
    }

    pub fn at(self: *const FakeHeaders, index: usize) response_headers.Field {
        return self.fields[index];
    }
};

test "actual CORS decisions cover every explicit mode and denied origin" {
    const origin = request_cors.Value{ .value = "https://app.example" };
    const wildcard = actual(cors.allow_any, origin);
    try expectBytes(wildcard.at(0), "access-control-allow-origin", "*");
    try expectBytes(wildcard.at(1), "vary", vary_origin);

    const exact_policy = cors.exact(&.{"https://app.example"}, .{
        .credentials = true,
    });
    const exact = actual(exact_policy, origin);
    try expectBytes(exact.at(0), "access-control-allow-origin", origin.value);
    try expectBytes(exact.at(1), "access-control-allow-credentials", "true");
    try expectBytes(exact.at(2), "vary", vary_origin);

    const denied = actual(exact_policy, .{ .value = "https://other.example" });
    try std.testing.expectEqual(@as(u8, 1), denied.count);
    try expectBytes(denied.at(0), "vary", vary_origin);

    const reflected = actual(cors.allow_any_credentialed, origin);
    try expectBytes(reflected.at(0), "access-control-allow-origin", origin.value);
    try expectBytes(reflected.at(1), "access-control-allow-credentials", "true");
    try std.testing.expectEqual(@as(u8, 0), actual(cors.disabled, origin).count);
}

test "null origin requires the separate option in every enabled mode" {
    const denied = actual(cors.allow_any, .{ .value = "null" });
    try std.testing.expectEqual(@as(u8, 1), denied.count);
    const allowed = actual(cors.any(.{ .allow_null = true }), .{ .value = "null" });
    try expectBytes(allowed.at(0), "access-control-allow-origin", "*");
    const credentialed = actual(
        cors.anyCredentialed(.{ .allow_null = true }),
        .{ .value = "null" },
    );
    try expectBytes(credentialed.at(0), "access-control-allow-origin", "null");
}

test "preflight emits only selected method requested headers and required vary" {
    const policy = cors.exact(&.{"https://app.example"}, .{
        .credentials = true,
        .request_headers = .{ .exact = &.{ "Content-Type", "X-Trace" } },
        .max_age_seconds = 42,
    });
    const result = preflight(policy, .{
        .origin = .{ .value = "https://app.example" },
        .requested_method = .{ .value = "POST" },
        .requested_headers = .{ .value = "x-trace, content-type" },
        .route_selected = true,
    });
    try std.testing.expectEqual(PreflightStatus.no_content, result.status);
    try expectBytes(result.fields.at(0), "access-control-allow-origin", "https://app.example");
    try expectBytes(result.fields.at(1), "access-control-allow-credentials", "true");
    try expectBytes(result.fields.at(2), "access-control-allow-methods", "POST");
    try expectBytes(result.fields.at(3), "access-control-allow-headers", "x-trace, content-type");
    try std.testing.expect(result.fields.at(4).value == .max_age_seconds);
    try std.testing.expectEqual(@as(u32, 42), result.fields.at(4).value.max_age_seconds);
    try expectBytes(result.fields.at(5), "vary", vary_preflight);
}

test "preflight permits an absent requested-header list and omits allow-headers" {
    const result = preflight(cors.allow_any, .{
        .origin = .{ .value = "https://app.example" },
        .requested_method = .{ .value = "GET" },
        .route_selected = true,
    });
    try std.testing.expectEqual(PreflightStatus.no_content, result.status);
    try std.testing.expectEqual(@as(u8, 4), result.fields.count);
    try expectBytes(result.fields.at(0), "access-control-allow-origin", "*");
    try expectBytes(result.fields.at(1), "access-control-allow-methods", "GET");
    try std.testing.expect(result.fields.at(2).value == .max_age_seconds);
    try expectBytes(result.fields.at(3), "vary", vary_preflight);
}

test "preflight denies missing routes invalid fields and header-set misses" {
    const policy = cors.exact(&.{"https://app.example"}, .{
        .request_headers = .{ .exact = &.{"X-Allowed"} },
    });
    const cases = [_]PreflightInput{
        .{
            .origin = .{ .value = "https://app.example" },
            .requested_method = .{ .value = "POST" },
            .route_selected = false,
        },
        .{
            .origin = .invalid,
            .requested_method = .{ .value = "POST" },
            .route_selected = true,
        },
        .{
            .origin = .{ .value = "https://app.example" },
            .requested_method = .{ .value = "POST" },
            .requested_headers = .{ .value = "X-Denied" },
            .route_selected = true,
        },
    };
    for (cases) |input| {
        const result = preflight(policy, input);
        try std.testing.expectEqual(PreflightStatus.forbidden, result.status);
        try std.testing.expectEqual(@as(u8, 1), result.fields.count);
        try expectBytes(result.fields.at(0), "vary", vary_preflight);
    }
}

test "bounded decisions downgrade every oversized synthetic field" {
    const origin = "null";
    const parsed_origin = request_cors.parseOrigin(origin).?;
    const request = request_cors.Request{
        .origin = .{ .value = origin },
        .parsed_origin = parsed_origin,
    };
    const wildcard = actualRequestBounded(
        cors.any(.{ .allow_null = true }),
        request,
        31,
    );
    try std.testing.expect(wildcard.managed);
    try std.testing.expectEqual(@as(u8, 1), wildcard.count);
    try expectBytes(wildcard.at(0), "vary", vary_origin);

    const credentialed = actualRequestBounded(
        cors.anyCredentialed(.{ .allow_null = true }),
        request,
        39,
    );
    try std.testing.expectEqual(@as(u8, 1), credentialed.count);
    try expectBytes(credentialed.at(0), "vary", vary_origin);

    const no_room = actualRequestBounded(cors.allow_any, request, 13);
    try std.testing.expect(no_room.managed);
    try std.testing.expectEqual(@as(u8, 0), no_room.count);
}

test "bounded preflight denies reflected headers above the exact line limit" {
    const origin = "https://app.example";
    const requested_headers = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const request = request_cors.Request{
        .origin = .{ .value = origin },
        .requested_method = .{ .value = "POST" },
        .requested_headers = .{ .value = requested_headers },
        .parsed_origin = request_cors.parseOrigin(origin).?,
        .parsed_requested_headers = request_cors.parseHeaderList(requested_headers).?,
    };
    const denied = preflightRequestBounded(cors.allow_any, request, true, 77);
    try std.testing.expectEqual(PreflightStatus.forbidden, denied.status);
    try std.testing.expectEqual(@as(u8, 1), denied.fields.count);
    try expectBytes(denied.fields.at(0), "vary", vary_preflight);

    const allowed = preflightRequestBounded(cors.allow_any, request, true, 78);
    try std.testing.expectEqual(PreflightStatus.no_content, allowed.status);
    try expectBytes(
        allowed.fields.at(2),
        "access-control-allow-headers",
        requested_headers,
    );

    const no_vary_room = preflightRequestBounded(cors.allow_any, request, true, 76);
    try std.testing.expectEqual(PreflightStatus.forbidden, no_vary_room.status);
    try std.testing.expectEqual(@as(u8, 0), no_vary_room.fields.count);
}

test "CORS overlay preserves source order materializes age and rejects conflicts" {
    const source_fields = [_]response_headers.Field{
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "vary", .value = "Accept-Encoding" },
    };
    const source = FakeHeaders{ .fields = &source_fields };
    const decision = preflight(cors.allow_any, .{
        .origin = .{ .value = "https://app.example" },
        .requested_method = .{ .value = "PATCH" },
        .route_selected = true,
    });
    const composed = try Overlay(FakeHeaders).init(&source, decision.fields);
    try std.testing.expectEqual(source_fields.len + decision.fields.count, composed.len());
    try std.testing.expectEqualStrings("cache-control", composed.at(0).name);
    try std.testing.expectEqualStrings("600", composed.at(composed.len() - 2).value);
    try std.testing.expectEqualStrings(vary_preflight, composed.at(composed.len() - 1).value);

    const conflicting_fields = [_]response_headers.Field{.{
        .name = "Access-Control-Allow-Origin",
        .value = "https://wrong.example",
    }};
    const conflicting = FakeHeaders{ .fields = &conflicting_fields };
    try std.testing.expectError(
        error.ConflictingCorsHeader,
        Overlay(FakeHeaders).init(&conflicting, decision.fields),
    );
}

test "application-owned exposed-header policy composes with CORS permission fields" {
    const source_fields = [_]response_headers.Field{.{
        .name = "access-control-expose-headers",
        .value = "X-Trace",
    }};
    const source = FakeHeaders{ .fields = &source_fields };
    const fields = actual(cors.allow_any, .{ .value = "https://app.example" });
    const composed = try Overlay(FakeHeaders).init(&source, fields);
    try std.testing.expectEqualStrings(
        "access-control-expose-headers",
        composed.at(0).name,
    );
    try std.testing.expectEqualStrings("X-Trace", composed.at(0).value);
    try std.testing.expectEqualStrings("access-control-allow-origin", composed.at(1).name);
}

fn expectBytes(field: Field, name: []const u8, value: []const u8) !void {
    try std.testing.expectEqualStrings(name, field.name);
    try std.testing.expect(field.value == .bytes);
    try std.testing.expectEqualStrings(value, field.value.bytes);
}

test "CORS decisions fuzz never reflect invalid origin or header bytes" {
    try std.testing.fuzz({}, fuzzDecisions, .{ .corpus = &decision_fuzz_corpus });
}

const decision_fuzz_corpus = struct {
    const valid = fuzzPair("https://app.example", "X-Trace");
    const null_origin = fuzzPair("null", "Content-Type, Authorization");
    const injected = fuzzPair("https://a.example\r\nx:y", "x,,y");
    const long = fuzzPair("https://" ++ "a" ** 128, "X-Trace");
    const values = [_][]const u8{ &valid, &null_origin, &injected, &long };
}.values;

fn fuzzPair(
    comptime origin: []const u8,
    comptime headers: []const u8,
) [origin.len + headers.len + 8]u8 {
    const first = fuzz_support.smithInput(origin);
    const second = fuzz_support.smithInput(headers);
    var result: [first.len + second.len]u8 = undefined;
    @memcpy(result[0..first.len], &first);
    @memcpy(result[first.len..], &second);
    return result;
}

fn fuzzDecisions(_: void, smith: *std.testing.Smith) !void {
    var origin_storage: [512]u8 = undefined;
    var header_storage: [512]u8 = undefined;
    const origin = origin_storage[0..smith.slice(&origin_storage)];
    const headers = header_storage[0..smith.slice(&header_storage)];
    const parsed_origin = request_cors.parseOrigin(origin);
    const parsed_headers = request_cors.parseHeaderList(headers);
    const origin_value: request_cors.Value = if (parsed_origin != null)
        .{ .value = origin }
    else
        .invalid;
    const header_value: request_cors.Value = if (parsed_headers != null)
        .{ .value = headers }
    else
        .invalid;
    const request = request_cors.Request{
        .origin = origin_value,
        .requested_method = .{ .value = "POST" },
        .requested_headers = header_value,
        .parsed_origin = parsed_origin,
        .parsed_requested_headers = parsed_headers,
    };
    const field_line_bytes_max = smith.valueRangeAtMost(
        u16,
        @intCast(field_line_bytes_min),
        512,
    );
    const first = preflightRequestBounded(
        cors.allow_any_credentialed,
        request,
        true,
        field_line_bytes_max,
    );
    const second = preflightRequestBounded(
        cors.allow_any_credentialed,
        request,
        true,
        field_line_bytes_max,
    );
    try std.testing.expectEqualDeep(first, second);
    try expectFuzzFields(first.fields, field_line_bytes_max);
    try expectFuzzFields(
        actualRequestBounded(cors.allow_any_credentialed, request, field_line_bytes_max),
        field_line_bytes_max,
    );
}

fn expectFuzzFields(fields: Fields, field_line_bytes_max: u32) !void {
    for (0..fields.count) |index| {
        const field = fields.at(index);
        var max_age_wire: [10]u8 = undefined;
        const value_bytes = switch (field.value) {
            .bytes => |bytes| bytes.len,
            .max_age_seconds => |seconds| (try std.fmt.bufPrint(
                &max_age_wire,
                "{d}",
                .{seconds},
            )).len,
        };
        try std.testing.expect(
            field.name.len + ": \r\n".len + value_bytes <=
                @as(usize, field_line_bytes_max),
        );
        switch (field.value) {
            .bytes => |bytes| {
                try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '\r') == null);
                try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '\n') == null);
            },
            .max_age_seconds => {},
        }
    }
}
