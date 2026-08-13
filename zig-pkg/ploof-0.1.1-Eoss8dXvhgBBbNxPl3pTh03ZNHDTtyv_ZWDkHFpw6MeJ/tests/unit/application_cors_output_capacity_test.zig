const std = @import("std");
const cors = @import("../../src/cors.zig");
const response = @import("../../src/response.zig");
const response_stream = @import("../../src/response/stream.zig");
const stream_response = @import("../../src/response/streaming.zig");
const gzip_serializer = @import("../../src/internal/application/response_gzip.zig");
const stream_serializer = @import("../../src/internal/application/stream_output.zig");
const gzip_encoder = @import("../../src/internal/runtime/gzip/encoder.zig");
const request_accept_encoding = @import("../../src/internal/http1/request_accept_encoding.zig");
const response_cors_fields = @import("../../src/internal/http1/response_cors_fields.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const maximum = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 16,
});
const identity_capacity = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 5,
});
const gzip_capacity = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 6,
});
const framework_capacity = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 5,
});
const Workspace = response.Workspace(maximum);
const Response = response.Response(maximum);
const gzip_options = gzip_serializer.Options{ .minimum_bytes = 0, .level = .fastest };

fn fullCors() response_cors_fields.Fields {
    return response_cors_fields.actual(
        cors.allow_any_credentialed,
        .{ .value = "https://app.example" },
    );
}

fn gzipRequest(
    preferences: request_accept_encoding.Preferences,
    cors_fields: response_cors_fields.Fields,
) gzip_serializer.RequestFields {
    return .{
        .method = "GET",
        .accept_encoding = preferences,
        .accepts_response_trailers = false,
        .date = fixed_date,
        .connection_close = false,
        .cors_fields = cors_fields,
    };
}

test "gzip identity retries aggregate and output CORS capacity only" {
    var workspace = Workspace{};
    const value = Response.textStatic(&workspace, .ok, "data");
    var output: [4096]u8 = undefined;
    const full = fullCors();
    const preferences = request_accept_encoding.Preferences{ .gzip = 0, .identity = 1000 };
    const aggregate = try gzip_serializer.serialize(
        identity_capacity,
        maximum,
        &value,
        gzipRequest(preferences, full),
        &output,
        null,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(.identity_negotiated, aggregate.coding_outcome);
    try std.testing.expectEqual(response.Status.ok, aggregate.status);
    try expectFallbackHead(aggregate.bytes);
    try std.testing.expect(std.mem.endsWith(u8, aggregate.bytes, "\r\n\r\ndata"));

    const vary_only = try gzip_serializer.serialize(
        maximum,
        maximum,
        &value,
        gzipRequest(preferences, full.capacityFallback().?),
        &output,
        null,
        gzip_options,
        null,
    );
    const output_retry = try gzip_serializer.serialize(
        maximum,
        maximum,
        &value,
        gzipRequest(preferences, full),
        output[0..vary_only.bytes.len],
        null,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(vary_only.bytes.len, output_retry.bytes.len);
    try expectFallbackHead(output_retry.bytes);

    const empty = full.capacityFallback().?.capacityFallback().?;
    const baseline = try gzip_serializer.serialize(
        maximum,
        maximum,
        &value,
        gzipRequest(preferences, empty),
        &output,
        null,
        gzip_options,
        null,
    );
    try std.testing.expectError(error.OutputTooSmall, gzip_serializer.serialize(
        maximum,
        maximum,
        &value,
        gzipRequest(preferences, full),
        output[0 .. baseline.bytes.len - 1],
        null,
        gzip_options,
        null,
    ));
}

test "gzip and framework responses fail closed on aggregate CORS capacity" {
    const body = "compressible CORS capacity payload " ** 12;
    var workspace = Workspace{};
    const value = Response.textStatic(&workspace, .ok, body);
    var encoder: gzip_encoder.Workspace = undefined;
    var output: [4096]u8 = undefined;
    const full = fullCors();

    const compressed = try gzip_serializer.serialize(
        gzip_capacity,
        maximum,
        &value,
        gzipRequest(.{ .gzip = 1000, .identity = 1000 }, full),
        &output,
        &encoder,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(.gzip, compressed.coding_outcome);
    try std.testing.expectEqual(response.Status.ok, compressed.status);
    try expectFallbackHead(compressed.bytes);
    try expectGzipRoundTrip(compressed.bytes, body);

    const rejected = try gzip_serializer.serialize(
        maximum,
        framework_capacity,
        &value,
        gzipRequest(.{ .gzip = 0, .identity = 0 }, full),
        &output,
        null,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(.not_acceptable, rejected.coding_outcome);
    try std.testing.expectEqual(response.Status.not_acceptable, rejected.status);
    try expectFallbackHead(rejected.bytes);

    const unavailable = try gzip_serializer.serialize(
        maximum,
        framework_capacity,
        &value,
        gzipRequest(.{ .gzip = 1000, .identity = 0 }, full),
        &output,
        null,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(.capacity_unavailable, unavailable.coding_outcome);
    try std.testing.expectEqual(response.Status.service_unavailable, unavailable.status);
    try expectFallbackHead(unavailable.bytes);
}

const Producer = struct { marker: u32 };
const StreamResponse = stream_response.Response(maximum, Producer);

fn streamRequest(
    identity: u16,
    cors_fields: response_cors_fields.Fields,
) stream_serializer.RequestFields {
    return .{
        .method = "GET",
        .accept_encoding = .{ .identity = identity },
        .accepts_response_trailers = false,
        .date = fixed_date,
        .connection_close = false,
        .cors_fields = cors_fields,
    };
}

fn exactStream(workspace: *Workspace) !StreamResponse {
    return StreamResponse.init(
        workspace,
        .ok,
        response.media.text,
        response_stream.exact(5, Producer{ .marker = 17 }),
    );
}

test "stream identity and framework 406 retry aggregate CORS capacity" {
    var workspace = Workspace{};
    workspace.reset(identity_capacity);
    const value = try exactStream(&workspace);
    const before = workspace;
    var output: [512]u8 = undefined;
    const full = fullCors();
    const identity = try stream_serializer.serialize(
        identity_capacity,
        maximum,
        value,
        &workspace,
        streamRequest(1000, full),
        &output,
        null,
    );
    try std.testing.expectEqual(response.Status.ok, identity.status);
    try std.testing.expect(identity.framing.invoke_stream);
    try std.testing.expectEqual(@as(u64, 5), identity.framing.framing.fixed);
    try expectFallbackHead(identity.bytes);
    try std.testing.expectEqualDeep(before, workspace);

    const rejected = try stream_serializer.serialize(
        identity_capacity,
        framework_capacity,
        value,
        &workspace,
        streamRequest(0, full),
        &output,
        null,
    );
    try std.testing.expectEqual(response.Status.not_acceptable, rejected.status);
    try std.testing.expect(!rejected.framing.invoke_stream);
    try expectFallbackHead(rejected.bytes);
}

test "stream output retries CORS and preserves genuine OutputTooSmall" {
    var workspace = Workspace{};
    const value = try exactStream(&workspace);
    var output: [512]u8 = undefined;
    const full = fullCors();
    const vary_only = try stream_serializer.serialize(
        maximum,
        maximum,
        value,
        &workspace,
        streamRequest(1000, full.capacityFallback().?),
        &output,
        null,
    );
    const retried = try stream_serializer.serialize(
        maximum,
        maximum,
        value,
        &workspace,
        streamRequest(1000, full),
        output[0..vary_only.bytes.len],
        null,
    );
    try std.testing.expectEqual(vary_only.bytes.len, retried.bytes.len);
    try expectFallbackHead(retried.bytes);

    const empty = full.capacityFallback().?.capacityFallback().?;
    const baseline = try stream_serializer.serialize(
        maximum,
        maximum,
        value,
        &workspace,
        streamRequest(1000, empty),
        &output,
        null,
    );
    try std.testing.expectError(error.OutputTooSmall, stream_serializer.serialize(
        maximum,
        maximum,
        value,
        &workspace,
        streamRequest(1000, full),
        output[0 .. baseline.bytes.len - 1],
        null,
    ));
}

fn expectFallbackHead(wire: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, wire, "access-control-allow-") == null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "vary: Origin\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "vary: Accept-Encoding\r\n") != null);
}

fn expectGzipRoundTrip(wire: []const u8, expected: []const u8) !void {
    const marker = std.mem.indexOf(u8, wire, "\r\n\r\n") orelse
        return error.TestUnexpectedResult;
    const body = wire[marker + 4 ..];
    var input_reader = std.Io.Reader.fixed(body);
    var decoder = std.compress.flate.Decompress.init(&input_reader, .gzip, &.{});
    var decoded: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(decoded[0..expected.len]);
    const written = try decoder.reader.streamRemaining(&writer);
    try std.testing.expectEqualStrings(expected, decoded[0..written]);
}
