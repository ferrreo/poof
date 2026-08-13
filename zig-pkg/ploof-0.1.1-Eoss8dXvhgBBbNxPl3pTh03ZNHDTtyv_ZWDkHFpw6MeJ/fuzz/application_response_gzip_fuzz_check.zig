const std = @import("std");
const response = @import("../src/response.zig");
const serializer = @import("../src/internal/application/response_gzip.zig");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const request_accept_encoding = @import("../src/internal/http1/request_accept_encoding.zig");
const syntax = @import("../src/internal/http1/syntax.zig");
const gzip_encoder = @import("../src/internal/runtime/gzip/encoder.zig");

const body_bytes_max: usize = 1024;
const policy_seed_max: usize = 32;
const sentinel: u8 = 0xa5;
const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const fuzz_limits = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 16,
});
const gzip_bytes_max = gzip_encoder.bound(body_bytes_max) catch unreachable;
const output_bytes_max: usize = fuzz_limits.head_bytes_max +
    @max(body_bytes_max, gzip_bytes_max);
const ResponseWorkspace = response.Workspace(fuzz_limits);
const Response = response.Response(fuzz_limits);

const Flags = packed struct(u8) {
    head: bool,
    workspace: bool,
    binary: bool,
    application_encoding: bool,
    application_vary: bool,
    connection_close: bool,
    _padding: u2 = 0,
};

const Policy = packed struct(u16) {
    cache_control: u3,
    etag: u2,
    digest: u3,
    content_type: u3,
    _padding: u5 = 0,
};

const PolicyOracle = struct {
    skips_automatic: bool,
};

const PolicyStorage = struct {
    token: [policy_seed_max]u8,
    cache_control: [96]u8,
    etag: [48]u8,
    digest: [48]u8,
    content_type: [80]u8,
};

const SourceSnapshot = struct {
    body: [body_bytes_max]u8,
    headers: ResponseWorkspace.HeaderStorage,
    value: Response,
};

test "finite response gzip serializer bounded composition fuzz" {
    try std.testing.fuzz({}, fuzzSerializer, .{ .corpus = &fuzz_corpus });
}

fn fuzzSerializer(_: void, smith: *std.testing.Smith) !void {
    var body_storage = [_]u8{0} ** body_bytes_max;
    const body = body_storage[0..smith.slice(&body_storage)];
    var policy_seed_storage = [_]u8{0} ** policy_seed_max;
    const policy_seed = policy_seed_storage[0..smith.slice(&policy_seed_storage)];
    const flags: Flags = @bitCast(smith.value(u8));
    const preferences = request_accept_encoding.Preferences{
        .gzip = smith.valueRangeAtMost(u16, 0, request_accept_encoding.weight_max),
        .identity = smith.valueRangeAtMost(u16, 0, request_accept_encoding.weight_max),
    };
    const capacity = smith.valueRangeAtMost(u16, 0, @intCast(output_bytes_max));
    const policy: Policy = @bitCast(smith.value(u16));

    var response_workspace = ResponseWorkspace{};
    var value = if (flags.binary)
        Response.bytesBorrowed(&response_workspace, .ok, body)
    else
        Response.textBorrowed(&response_workspace, .ok, body);
    if (flags.application_encoding) try value.setHeader("Content-Encoding", "br");
    if (flags.application_vary) try value.setHeader("Vary", "Accept-Encoding");
    var policy_storage: PolicyStorage = undefined;
    const policy_oracle = try applyPolicy(
        &value,
        &policy_storage,
        policy_seed,
        policy,
        flags.binary,
    );
    const source_before = SourceSnapshot{
        .body = body_storage,
        .headers = response_workspace.headers,
        .value = value,
    };

    var encoder: gzip_encoder.Workspace = undefined;
    @memset(std.mem.asBytes(&encoder), sentinel);
    var guarded = [_]u8{sentinel} ** (output_bytes_max + 2);
    const output = guarded[1 .. 1 + capacity];
    const prepared = serializer.serialize(
        fuzz_limits,
        fuzz_limits,
        &value,
        request(flags, preferences),
        output,
        if (flags.workspace) &encoder else null,
        .{ .minimum_bytes = 0, .level = .fastest },
        null,
    ) catch |problem| return expectFailure(
        problem,
        source_before,
        body_storage,
        response_workspace.headers,
        value,
        &guarded,
        capacity,
        &encoder,
        flags,
    );

    try expectSourceUnchanged(
        source_before,
        body_storage,
        response_workspace.headers,
        value,
    );
    try expectOutputGuards(&guarded, capacity);
    try expectPrepared(prepared, output, body, flags, preferences, policy_oracle);
    try expectWorkspaceCleanup(&encoder, flags, prepared.coding_outcome, body.len, capacity);
}

fn expectFailure(
    problem: serializer.Error,
    source_before: SourceSnapshot,
    body_after: [body_bytes_max]u8,
    headers_after: ResponseWorkspace.HeaderStorage,
    value_after: Response,
    guarded: []const u8,
    capacity: usize,
    encoder: *const gzip_encoder.Workspace,
    flags: Flags,
) !void {
    try expectSourceUnchanged(source_before, body_after, headers_after, value_after);
    try expectOutputGuards(guarded, capacity);
    try expectWorkspaceErrorCleanup(encoder, flags);
    return switch (problem) {
        error.OutputTooSmall, error.ResponseHeadTooLarge => {},
        else => problem,
    };
}

fn applyPolicy(
    value: *Response,
    storage: *PolicyStorage,
    seed: []const u8,
    policy: Policy,
    binary: bool,
) !PolicyOracle {
    const token = tokenFromSeed(&storage.token, seed);
    const cache_skips = try applyCacheControl(
        value,
        &storage.cache_control,
        token,
        policy.cache_control,
    );
    const etag_skips = try applyEtag(value, &storage.etag, token, policy.etag);
    const digest_skips = try applyDigest(value, &storage.digest, token, policy.digest);
    const content_compressible = try applyContentType(
        value,
        &storage.content_type,
        token,
        policy.content_type,
        binary,
    );
    return .{
        .skips_automatic = cache_skips or etag_skips or digest_skips or
            !content_compressible,
    };
}

fn applyCacheControl(
    value: *Response,
    storage: []u8,
    token: []const u8,
    shape: u3,
) !bool {
    const bytes = switch (shape) {
        0 => return false,
        1 => join(storage, &.{ "public, x-", token }),
        2 => join(storage, &.{ "foo=\"no-transform,", token, "\"" }),
        3 => join(storage, &.{ "public, no-transform, x-", token }),
        4 => "NO-TRANSFORM",
        5 => join(storage, &.{ "foo=\"", token }),
        6 => {
            try value.appendHeader(
                "Cache-Control",
                join(storage, &.{ "public, x-", token }),
            );
            try value.appendHeader("Cache-Control", "no-transform");
            return true;
        },
        7 => join(storage, &.{ "no-transform=", token }),
    };
    try value.appendHeader("Cache-Control", bytes);
    return shape == 3 or shape == 4 or shape == 5;
}

fn applyEtag(
    value: *Response,
    storage: []u8,
    token: []const u8,
    shape: u2,
) !bool {
    const bytes = switch (shape) {
        0 => return false,
        1 => join(storage, &.{ "W/\"", token, "\"" }),
        2 => join(storage, &.{ "\"", token, "\"" }),
        3 => join(storage, &.{ "w/\"", token, "\"" }),
    };
    try value.setHeader("ETag", bytes);
    return shape != 1;
}

fn applyDigest(
    value: *Response,
    storage: []u8,
    token: []const u8,
    shape: u3,
) !bool {
    if (shape == 0) return false;
    const bytes = join(storage, &.{ "x-", token });
    if (shape == 6) {
        try value.appendHeader("Content-Digest", bytes);
        try value.appendHeader("Digest", bytes);
        return true;
    }
    const name: []const u8 = switch (shape) {
        1 => "Content-Digest",
        2 => "Repr-Digest",
        3 => "Digest",
        4 => "Content-MD5",
        5, 7 => "Content-Range",
        0, 6 => unreachable,
    };
    try value.appendHeader(name, bytes);
    return true;
}

fn applyContentType(
    value: *Response,
    storage: []u8,
    token: []const u8,
    shape: u3,
    binary: bool,
) !bool {
    switch (shape) {
        0 => return !binary,
        1 => try value.setHeader("Content-Type", join(storage, &.{ "text/", token })),
        2 => try value.setHeader(
            "Content-Type",
            join(storage, &.{ "application/", token, "+json" }),
        ),
        3 => {
            try value.setHeader("Content-Type", "application/octet-stream");
            return false;
        },
        4 => {
            try value.setHeader("Content-Type", "image/png");
            return false;
        },
        5 => {
            try value.setHeader(
                "Content-Type",
                join(storage, &.{ "application/", token, "+xml" }),
            );
            return true;
        },
        6 => {
            try value.setHeader("Content-Type", join(storage, &.{ "application/", token }));
            return false;
        },
        7 => try value.setHeader(
            "Content-Type",
            join(storage, &.{ "image/svg+xml; x=", token }),
        ),
    }
    return true;
}

fn tokenFromSeed(output: *[policy_seed_max]u8, seed: []const u8) []const u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyz012345";
    if (seed.len == 0) {
        output[0] = 'a';
        return output[0..1];
    }
    const length = @min(seed.len, output.len);
    for (seed[0..length], 0..) |byte, index| {
        output[index] = alphabet[@as(usize, byte) % alphabet.len];
    }
    return output[0..length];
}

fn join(output: []u8, parts: []const []const u8) []const u8 {
    var used: usize = 0;
    for (parts) |part| {
        std.debug.assert(part.len <= output.len - used);
        @memcpy(output[used..][0..part.len], part);
        used += part.len;
    }
    return output[0..used];
}

fn request(
    flags: Flags,
    preferences: request_accept_encoding.Preferences,
) serializer.RequestFields {
    return .{
        .method = if (flags.head) "HEAD" else "GET",
        .accept_encoding = preferences,
        .accepts_response_trailers = false,
        .date = fixed_date,
        .connection_close = flags.connection_close,
    };
}

fn expectPrepared(
    prepared: serializer.Prepared,
    output: []const u8,
    source: []const u8,
    flags: Flags,
    preferences: request_accept_encoding.Preferences,
    policy: PolicyOracle,
) !void {
    try expectPolicyOutcome(prepared.coding_outcome, flags, preferences, policy);
    try std.testing.expect(prepared.bytes.ptr == output.ptr);
    try std.testing.expect(prepared.bytes.len <= output.len);
    const wire = try splitWire(prepared.bytes);
    try std.testing.expectEqual(@intFromEnum(prepared.status), try wireStatus(wire.head));
    const connection = headerValue(wire.head, "connection");
    try std.testing.expectEqual(prepared.close_connection, connection != null);
    if (connection) |value| try std.testing.expectEqualStrings("close", value);

    switch (prepared.coding_outcome) {
        .gzip => try expectGzip(wire, source, flags),
        .application_content_encoding => try expectIdentity(
            wire,
            source,
            flags,
            "br",
            flags.application_vary,
        ),
        .skipped_ineligible => try expectIdentity(
            wire,
            source,
            flags,
            null,
            true,
        ),
        .identity_negotiated, .identity_capacity_fallback => try expectIdentity(
            wire,
            source,
            flags,
            null,
            true,
        ),
        .not_acceptable => try expectFramework(wire, prepared, 406),
        .capacity_unavailable => try expectFramework(wire, prepared, 503),
        .identity_below_threshold,
        .skipped_bodyless_status,
        .skipped_bodyless,
        .compression_failed,
        => return error.TestUnexpectedResult,
    }
}

fn expectPolicyOutcome(
    outcome: serializer.CodingOutcome,
    flags: Flags,
    preferences: request_accept_encoding.Preferences,
    policy: PolicyOracle,
) !void {
    const expected: ?serializer.CodingOutcome = if (flags.application_encoding)
        .application_content_encoding
    else if (policy.skips_automatic)
        if (preferences.identity != 0) .skipped_ineligible else .not_acceptable
    else
        null;
    if (expected) |value| try std.testing.expectEqual(value, outcome);
}

const Wire = struct {
    head: []const u8,
    body: []const u8,
};

fn splitWire(bytes: []const u8) !Wire {
    const marker = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse {
        return error.TestUnexpectedResult;
    };
    const body_start = marker + 4;
    return .{ .head = bytes[0..body_start], .body = bytes[body_start..] };
}

fn expectGzip(wire: Wire, source: []const u8, flags: Flags) !void {
    try std.testing.expectEqualStrings("gzip", headerValue(wire.head, "content-encoding").?);
    try std.testing.expectEqual(@as(usize, 1), headerCount(wire.head, "vary"));
    try std.testing.expectEqualStrings(
        "Accept-Encoding",
        headerValue(wire.head, "vary").?,
    );
    const length = try contentLength(wire.head);
    if (flags.head) {
        try std.testing.expectEqual(@as(usize, 0), wire.body.len);
        try std.testing.expect(length >= 18);
        return;
    }
    try std.testing.expectEqual(length, wire.body.len);
    var input = std.Io.Reader.fixed(wire.body);
    var decoder = std.compress.flate.Decompress.init(&input, .gzip, &.{});
    var decoded: [body_bytes_max]u8 = undefined;
    var writer = std.Io.Writer.fixed(decoded[0..source.len]);
    const written = try decoder.reader.streamRemaining(&writer);
    try std.testing.expectEqual(source.len, written);
    try std.testing.expectEqualSlices(u8, source, decoded[0..written]);
}

fn expectIdentity(
    wire: Wire,
    source: []const u8,
    flags: Flags,
    encoding: ?[]const u8,
    varies: bool,
) !void {
    try std.testing.expectEqual(@as(u16, 200), try wireStatus(wire.head));
    try std.testing.expectEqual(source.len, try contentLength(wire.head));
    const actual_encoding = headerValue(wire.head, "content-encoding");
    try std.testing.expectEqual(encoding != null, actual_encoding != null);
    if (encoding) |expected| try std.testing.expectEqualStrings(expected, actual_encoding.?);
    try std.testing.expectEqual(@intFromBool(varies), headerCount(wire.head, "vary"));
    if (flags.head) {
        try std.testing.expectEqual(@as(usize, 0), wire.body.len);
    } else {
        try std.testing.expectEqualSlices(u8, source, wire.body);
    }
}

fn expectFramework(wire: Wire, prepared: serializer.Prepared, expected_status: u16) !void {
    try std.testing.expectEqual(expected_status, try wireStatus(wire.head));
    try std.testing.expect(prepared.close_connection);
    try std.testing.expectEqual(@as(usize, 0), try contentLength(wire.head));
    try std.testing.expectEqual(@as(usize, 0), wire.body.len);
    try std.testing.expect(headerValue(wire.head, "content-encoding") == null);
    try std.testing.expectEqual(@as(usize, 1), headerCount(wire.head, "vary"));
    try std.testing.expectEqualStrings(
        "Accept-Encoding",
        headerValue(wire.head, "vary").?,
    );
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    const status_end = std.mem.indexOf(u8, head, "\r\n") orelse return null;
    var remaining = head[status_end + 2 ..];
    while (remaining.len != 0) {
        const line_end = std.mem.indexOf(u8, remaining, "\r\n") orelse return null;
        const line = remaining[0..line_end];
        if (line.len == 0) return null;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        if (syntax.eqlIgnoreCase(line[0..colon], name)) {
            return syntax.trimOws(line[colon + 1 ..]);
        }
        remaining = remaining[line_end + 2 ..];
    }
    return null;
}

fn headerCount(head: []const u8, name: []const u8) usize {
    const status_end = std.mem.indexOf(u8, head, "\r\n") orelse return 0;
    var remaining = head[status_end + 2 ..];
    var count: usize = 0;
    while (remaining.len != 0) {
        const line_end = std.mem.indexOf(u8, remaining, "\r\n") orelse return count;
        const line = remaining[0..line_end];
        if (line.len == 0) return count;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return count;
        count += @intFromBool(syntax.eqlIgnoreCase(line[0..colon], name));
        remaining = remaining[line_end + 2 ..];
    }
    return count;
}

fn contentLength(head: []const u8) !usize {
    const value = headerValue(head, "content-length") orelse {
        return error.TestUnexpectedResult;
    };
    return std.fmt.parseInt(usize, value, 10);
}

fn wireStatus(head: []const u8) !u16 {
    if (head.len < 12 or !std.mem.startsWith(u8, head, "HTTP/1.1 ")) {
        return error.TestUnexpectedResult;
    }
    return std.fmt.parseInt(u16, head[9..12], 10);
}

fn expectSourceUnchanged(
    before: SourceSnapshot,
    body_after: [body_bytes_max]u8,
    headers_after: ResponseWorkspace.HeaderStorage,
    value_after: Response,
) !void {
    try std.testing.expectEqualSlices(u8, &before.body, &body_after);
    try std.testing.expectEqualDeep(before.headers, headers_after);
    try std.testing.expectEqualDeep(before.value, value_after);
}

fn expectOutputGuards(output: []const u8, capacity: usize) !void {
    try std.testing.expectEqual(sentinel, output[0]);
    for (output[capacity + 1 ..]) |byte| try std.testing.expectEqual(sentinel, byte);
}

fn expectWorkspaceCleanup(
    workspace: *const gzip_encoder.Workspace,
    flags: Flags,
    outcome: serializer.CodingOutcome,
    body_length: usize,
    output_capacity: usize,
) !void {
    if (!flags.workspace) return;
    const selected_gzip = switch (outcome) {
        .gzip, .identity_capacity_fallback, .capacity_unavailable, .compression_failed => true,
        else => false,
    };
    const stage_end = fuzz_limits.head_bytes_max +
        (gzip_encoder.bound(body_length) catch unreachable);
    const attempted = selected_gzip and stage_end <= output_capacity;
    const expected: u8 = if (attempted) 0 else sentinel;
    for (std.mem.asBytes(workspace)) |byte| try std.testing.expectEqual(expected, byte);
}

fn expectWorkspaceErrorCleanup(
    workspace: *const gzip_encoder.Workspace,
    flags: Flags,
) !void {
    if (!flags.workspace) return;
    const bytes = std.mem.asBytes(workspace);
    const expected = bytes[0];
    try std.testing.expect(expected == 0 or expected == sentinel);
    for (bytes[1..]) |byte| try std.testing.expectEqual(expected, byte);
}

fn fuzzCase(
    comptime body: []const u8,
    comptime policy_seed: []const u8,
    comptime flags: u8,
    comptime gzip: u64,
    comptime identity: u64,
    comptime capacity: u64,
    comptime policy: u64,
) [body.len + policy_seed.len + 48]u8 {
    const encoded_body = fuzz_support.smithInput(body);
    const encoded_policy = fuzz_support.smithInput(policy_seed);
    var input: [body.len + policy_seed.len + 48]u8 = undefined;
    @memcpy(input[0..encoded_body.len], &encoded_body);
    @memcpy(input[encoded_body.len..][0..encoded_policy.len], &encoded_policy);
    const values = [_]u64{ flags, gzip, identity, capacity, policy };
    const values_start = encoded_body.len + encoded_policy.len;
    inline for (values, 0..) |value, index| {
        const start = values_start + index * 8;
        std.mem.writeInt(u64, input[start..][0..8], value, .little);
    }
    return input;
}

fn policyBits(
    comptime cache_control: u3,
    comptime etag: u2,
    comptime digest: u3,
    comptime content_type: u3,
) u16 {
    return @as(u16, cache_control) |
        (@as(u16, etag) << 3) |
        (@as(u16, digest) << 5) |
        (@as(u16, content_type) << 8);
}

const fuzz_corpus = struct {
    const payload = "compressible response payload " ** 8;
    const none = policyBits(0, 0, 0, 0);
    const gzip_get = fuzzCase(payload, "plain", 0x02, 1000, 1000, output_bytes_max, none);
    const gzip_head = fuzzCase(payload, "head", 0x03, 1000, 1000, output_bytes_max, none);
    const fallback = fuzzCase(payload, "fallback", 0x00, 1000, 1000, output_bytes_max, none);
    const unavailable = fuzzCase(payload, "none", 0x00, 1000, 0, output_bytes_max, none);
    const identity = fuzzCase("identity", "identity", 0x00, 0, 1000, output_bytes_max, none);
    const encoded = fuzzCase("encoded", "encoded", 0x08, 0, 0, output_bytes_max, none);
    const binary = fuzzCase("binary", "binary", 0x04, 1000, 0, output_bytes_max, none);
    const constrained = fuzzCase(payload, "small", 0x02, 1000, 0, 16, none);
    const safe_policy = fuzzCase(
        payload,
        "arbitrary-policy-seed",
        0x02,
        1000,
        0,
        output_bytes_max,
        policyBits(1, 1, 0, 2),
    );
    const quoted_cache = fuzzCase(
        payload,
        "no-transform",
        0x02,
        1000,
        0,
        output_bytes_max,
        policyBits(2, 0, 0, 1),
    );
    const cache_skip = fuzzCase(
        payload,
        "cache",
        0x02,
        1000,
        0,
        output_bytes_max,
        policyBits(3, 0, 0, 1),
    );
    const etag_skip = fuzzCase(
        payload,
        "etag",
        0x02,
        1000,
        0,
        output_bytes_max,
        policyBits(0, 2, 0, 1),
    );
    const digest_skip = fuzzCase(
        payload,
        "digest",
        0x02,
        1000,
        0,
        output_bytes_max,
        policyBits(0, 0, 1, 1),
    );
    const binary_type = fuzzCase(
        payload,
        "media",
        0x02,
        1000,
        0,
        output_bytes_max,
        policyBits(0, 0, 0, 3),
    );
    const xml_type = fuzzCase(
        payload,
        "xml",
        0x02,
        1000,
        0,
        output_bytes_max,
        policyBits(0, 0, 0, 5),
    );
    const generic_type = fuzzCase(
        payload,
        "generic",
        0x02,
        1000,
        0,
        output_bytes_max,
        policyBits(0, 0, 0, 6),
    );

    const values = [_][]const u8{
        &gzip_get,
        &gzip_head,
        &fallback,
        &unavailable,
        &identity,
        &encoded,
        &binary,
        &constrained,
        &safe_policy,
        &quoted_cache,
        &cache_skip,
        &etag_skip,
        &digest_skip,
        &binary_type,
        &xml_type,
        &generic_type,
    };
}.values;
