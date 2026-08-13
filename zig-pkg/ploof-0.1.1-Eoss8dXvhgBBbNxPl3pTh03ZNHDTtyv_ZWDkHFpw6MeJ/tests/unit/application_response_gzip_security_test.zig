const std = @import("std");
const response = @import("../../src/response.zig");
const serializer = @import("../../src/internal/application/response_gzip.zig");
const runtime_config = @import("../../src/internal/runtime/config.zig");
const gzip_encoder = @import("../../src/internal/runtime/gzip/encoder.zig");
const response_head = @import("../../src/internal/http1/response_head.zig");

const test_limits = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 16,
});

const tight_field_limits = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 4,
});

const selected_too_small = response.HeadLimits.validate(.{
    .head_bytes_max = 128,
    .field_line_bytes_max = 64,
    .fields_max = 1,
});

const ResponseWorkspace = response.Workspace(test_limits);
const Response = response.Response(test_limits);
const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const gzip_options = serializer.Options{ .minimum_bytes = 0, .level = .fastest };
const sentinel: u8 = 0xa5;

test "standard staging covers checked 48 KiB gzip reservation" {
    const required = response.standard_head_limits.head_bytes_max +
        try gzip_encoder.bound(48 * 1024);
    try std.testing.expect(required <= runtime_config.standard_limits.response_bytes_per_request);
}

fn BrokenEncoder(comptime invalid_result: bool) type {
    return struct {
        pub const Workspace = struct { secret: [64]u8 = @splat(sentinel) };

        pub fn bound(_: usize) error{}!usize {
            return 32;
        }

        pub fn compress(
            workspace: *Workspace,
            _: []const u8,
            output: []u8,
            comptime _: gzip_encoder.Level,
        ) error{Failed}![]u8 {
            @memset(std.mem.asBytes(workspace), 0x6b);
            @memset(output, 0x6b);
            if (invalid_result) return output[1..19];
            return error.Failed;
        }
    };
}

test "framework probes exact head and runtime output capacities" {
    const identity = comptime response_head.ServerIdentity.init("ploof-test");
    const plain = serializer.frameworkBytesRequired(test_limits, null).?;
    const identified = serializer.frameworkBytesRequired(test_limits, identity).?;
    try std.testing.expect(identified > plain);
    try std.testing.expect(serializer.frameworkCapacityFits(test_limits, identity));
    try std.testing.expect(serializer.frameworkOutputCapacityFits(
        test_limits,
        identified,
        identity,
    ));
    try std.testing.expect(!serializer.frameworkOutputCapacityFits(
        test_limits,
        identified - 1,
        identity,
    ));
    try std.testing.expect(!serializer.frameworkCapacityFits(selected_too_small, null));
}

test "Cache-Control no-transform negotiates identity" {
    try expectCacheControl(&.{"public,   No-Transform   "}, .skipped_ineligible);
    try expectCacheControl(&.{ "public", "max-age=1, NO-TRANSFORM" }, .skipped_ineligible);
    try expectCacheControl(&.{"foo=\"a,no-transform\""}, .gzip);
    try expectCacheControl(&.{"no-transform=x"}, .gzip);
    try expectCacheControl(&.{"," ** 64}, .skipped_ineligible);
}

test "partial and representation-bound metadata skip automatic gzip" {
    try expectPolicy(.partial_content, null, "", .skipped_ineligible);
    try expectPolicy(.ok, "Content-Range", "bytes 0-3/10", .skipped_ineligible);
    try expectPolicy(.ok, "ETag", "W/\"weak\"", .gzip);
    try expectPolicy(.ok, "ETag", " W/\"\" ", .gzip);
    try expectPolicy(.ok, "ETag", "\"strong\"", .skipped_ineligible);
    try expectPolicy(.ok, "ETag", "w/\"not-weak\"", .skipped_ineligible);
    try expectPolicy(.ok, "ETag", "W/not-quoted", .skipped_ineligible);
    inline for (.{ "Content-Digest", "Repr-Digest", "Digest", "Content-MD5" }) |name| {
        try expectPolicy(.ok, name, "sha-256=:YWJjZA==:", .skipped_ineligible);
    }
}

test "application Content-Encoding bypasses automatic representation exclusions" {
    var workspace = ResponseWorkspace{};
    var value = Response.textStatic(&workspace, .ok, "precompressed");
    try value.setHeader("Content-Encoding", "br");
    try value.setHeader("ETag", "\"strong-for-br\"");
    try value.setHeader("Content-Digest", "sha-256=:YWJjZA==:");
    var output: [1024]u8 = undefined;
    const prepared = try serializer.serialize(
        test_limits,
        test_limits,
        &value,
        request("GET", .{ .gzip = 0, .identity = 0 }),
        &output,
        null,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(.application_content_encoding, prepared.coding_outcome);
}

test "gzip and HEAD preserve committed overlap and scrub workspace and stage tail" {
    var body: [800]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @truncate(index *% 131 +% index / 7);
    inline for (.{ "GET", "HEAD" }) |method| {
        var workspace = ResponseWorkspace{};
        const value = Response.textBorrowed(&workspace, .ok, &body);
        var encoder: gzip_encoder.Workspace = undefined;
        @memset(std.mem.asBytes(&encoder), sentinel);
        var output = [_]u8{sentinel} ** 2048;
        const prepared = try serializer.serialize(
            test_limits,
            test_limits,
            &value,
            request(method, .{ .gzip = 1000, .identity = 0 }),
            &output,
            &encoder,
            gzip_options,
            null,
        );
        try std.testing.expectEqual(.gzip, prepared.coding_outcome);
        try expectCleanup(
            &output,
            prepared.bytes.len,
            test_limits.head_bytes_max,
            try gzip_encoder.bound(body.len),
        );
        try expectZero(std.mem.asBytes(&encoder));
        if (std.mem.eql(u8, method, "GET")) {
            try expectGzipRoundTrip(prepared.bytes, &body);
            try std.testing.expect(prepared.bytes.len > test_limits.head_bytes_max);
        } else {
            try std.testing.expectEqual(
                @as(usize, 0),
                (try wireParts(prepared.bytes)).body.len,
            );
            try std.testing.expect(
                std.mem.indexOf(u8, prepared.bytes, "content-encoding: gzip") != null,
            );
        }
    }
}

test "post-compress head fallback scrubs before writing identity" {
    var body: [800]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @truncate(index *% 131 +% index / 7);
    var workspace = ResponseWorkspace{};
    const value = Response.textBorrowed(&workspace, .ok, &body);
    var encoder: gzip_encoder.Workspace = undefined;
    @memset(std.mem.asBytes(&encoder), sentinel);
    var output = [_]u8{sentinel} ** 2048;
    const prepared = try serializer.serialize(
        tight_field_limits,
        test_limits,
        &value,
        request("GET", .{ .gzip = 1000, .identity = 1000 }),
        &output,
        &encoder,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(.identity_capacity_fallback, prepared.coding_outcome);
    try std.testing.expect(std.mem.endsWith(u8, prepared.bytes, &body));
    try expectCleanup(
        &output,
        prepared.bytes.len,
        tight_field_limits.head_bytes_max,
        try gzip_encoder.bound(body.len),
    );
    try expectZero(std.mem.asBytes(&encoder));
}

test "known staging miss leaves unacquired workspace untouched" {
    var workspace = ResponseWorkspace{};
    const value = Response.textStatic(&workspace, .ok, "capacity");
    var encoder: gzip_encoder.Workspace = undefined;
    @memset(std.mem.asBytes(&encoder), sentinel);
    var output = [_]u8{sentinel} ** 256;
    const prepared = try serializer.serialize(
        test_limits,
        test_limits,
        &value,
        request("GET", .{ .gzip = 1000, .identity = 1000 }),
        &output,
        &encoder,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(.identity_capacity_fallback, prepared.coding_outcome);
    for (std.mem.asBytes(&encoder)) |byte| {
        try std.testing.expectEqual(sentinel, byte);
    }
}

test "compressor error and invariant failure scrub before exact 500" {
    const expected =
        "HTTP/1.1 500 Internal Server Error\r\n" ++
        "content-length: 0\r\n" ++
        "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
        "connection: close\r\n" ++
        "\r\n";
    inline for (.{ BrokenEncoder(false), BrokenEncoder(true) }) |Encoder| {
        var workspace = ResponseWorkspace{};
        const value = Response.textStatic(&workspace, .ok, "compress me");
        var encoder = Encoder.Workspace{};
        var output = [_]u8{sentinel} ** 1024;
        const prepared = try serializer.serializeWithEncoder(
            Encoder,
            selected_too_small,
            test_limits,
            &value,
            request("GET", .{ .gzip = 1000, .identity = 0 }),
            &output,
            &encoder,
            gzip_options,
            null,
        );
        try std.testing.expectEqualStrings(expected, prepared.bytes);
        try std.testing.expectEqual(.compression_failed, prepared.coding_outcome);
        try expectCleanup(&output, prepared.bytes.len, selected_too_small.head_bytes_max, 32);
        try expectZero(std.mem.asBytes(&encoder));
    }
}

fn request(
    method: []const u8,
    preferences: @import("../../src/internal/http1/request_accept_encoding.zig").Preferences,
) serializer.RequestFields {
    return .{
        .method = method,
        .accept_encoding = preferences,
        .accepts_response_trailers = false,
        .date = fixed_date,
        .connection_close = false,
    };
}

fn expectCacheControl(values: []const []const u8, expected: serializer.CodingOutcome) !void {
    var workspace = ResponseWorkspace{};
    var value = Response.textStatic(&workspace, .ok, "cache control body");
    for (values) |header| try value.appendHeader("Cache-Control", header);
    try expectSerializedPolicy(&value, expected);
}

fn expectPolicy(
    comptime status: response.Status,
    name: ?[]const u8,
    value_bytes: []const u8,
    expected: serializer.CodingOutcome,
) !void {
    var workspace = ResponseWorkspace{};
    var value = Response.textStatic(&workspace, status, "policy body");
    if (name) |field_name| try value.setHeader(field_name, value_bytes);
    try expectSerializedPolicy(&value, expected);
}

fn expectSerializedPolicy(value: anytype, expected: serializer.CodingOutcome) !void {
    try expectPolicySelection(value, .{ .gzip = 1000, .identity = 1000 }, expected);
    try expectPolicySelection(
        value,
        .{ .gzip = 1000, .identity = 0 },
        if (expected == .skipped_ineligible) .not_acceptable else expected,
    );
}

fn expectPolicySelection(
    value: anytype,
    preferences: @import("../../src/internal/http1/request_accept_encoding.zig").Preferences,
    expected: serializer.CodingOutcome,
) !void {
    var encoder: gzip_encoder.Workspace = undefined;
    var output: [4096]u8 = undefined;
    const prepared = try serializer.serialize(
        test_limits,
        test_limits,
        value,
        request("GET", preferences),
        &output,
        &encoder,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(expected, prepared.coding_outcome);
    const varies = std.mem.indexOf(u8, prepared.bytes, "vary: Accept-Encoding") != null;
    const encoded = std.mem.indexOf(u8, prepared.bytes, "content-encoding: gzip") != null;
    try std.testing.expect(varies);
    try std.testing.expectEqual(expected == .gzip, encoded);
    if (expected == .not_acceptable) {
        try std.testing.expectEqual(response.Status.not_acceptable, prepared.status);
        try std.testing.expect(prepared.close_connection);
    }
}

fn expectCleanup(output: []const u8, committed: usize, stage_start: usize, stage_len: usize) !void {
    const stage_end = stage_start + stage_len;
    for (output[committed..], committed..) |byte, index| {
        const expected: u8 = if (index >= stage_start and index < stage_end) 0 else sentinel;
        try std.testing.expectEqual(expected, byte);
    }
}

fn expectZero(bytes: []const u8) !void {
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

const WireParts = struct { head: []const u8, body: []const u8 };

fn wireParts(bytes: []const u8) !WireParts {
    const marker = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.TestUnexpectedResult;
    const body_start = marker + "\r\n\r\n".len;
    return .{ .head = bytes[0..body_start], .body = bytes[body_start..] };
}

fn expectGzipRoundTrip(wire: []const u8, expected: []const u8) !void {
    const parts = try wireParts(wire);
    var input_reader = std.Io.Reader.fixed(parts.body);
    var decoder = std.compress.flate.Decompress.init(&input_reader, .gzip, &.{});
    var decoded: [800]u8 = undefined;
    var writer = std.Io.Writer.fixed(decoded[0..expected.len]);
    const written = try decoder.reader.streamRemaining(&writer);
    try std.testing.expectEqual(expected.len, written);
    try std.testing.expectEqualStrings(expected, decoded[0..written]);
}
