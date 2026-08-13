const std = @import("std");
const chunked = @import("chunked.zig");
const limits = @import("limits.zig");
const media_type = @import("media_type.zig");
const request_analysis = @import("request_analysis.zig");
const request_head = @import("request_head.zig");
const response_head = @import("response_head.zig");
const response_headers = @import("response_headers.zig");
const response_transfer = @import("response_transfer.zig");

pub const RuntimeFields = struct {
    date: []const u8,
    server_identity: ?response_head.ServerIdentity = null,
};

const longest_error_status = longestErrorStatus();

pub fn write(
    comptime requested: limits.ResponseHeadLimits,
    comptime requested_trailers: response_transfer.TrailerLimits,
    output: []u8,
    rejection: request_head.Rejection,
    runtime_fields: RuntimeFields,
) response_head.WriteError!response_head.WriteResult {
    const code = @intFromEnum(rejection.status);
    if (!rejection.close or code < 400 or code > 599) return error.InvalidResponse;

    const Headers = response_headers.Headers(requested);
    var headers = Headers{};
    return response_head.write(
        requested,
        requested_trailers,
        output,
        .{
            .framing = .{
                .status = rejection.status,
                .request_is_head = false,
                .request_accepts_trailers = false,
                .body = .none,
                .trailers_declared = false,
            },
            .default_content_type = media_type.octet_stream,
            .date = runtime_fields.date,
            .server_identity = runtime_fields.server_identity,
            .connection_close = true,
        },
        &headers,
    );
}

/// Writes the largest standard error head for startup capacity validation.
pub fn writeCapacityProbe(
    output: []u8,
    runtime_fields: RuntimeFields,
) response_head.WriteError![]u8 {
    const result = try write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        output,
        .{ .status = longest_error_status },
        runtime_fields,
    );
    return result.bytes;
}

fn longestErrorStatus() request_head.Status {
    var longest: request_head.Status = .bad_request;
    for (400..600) |code| {
        const candidate: request_head.Status = @enumFromInt(code);
        if (candidate.reasonPhrase().len > longest.reasonPhrase().len) {
            longest = candidate;
        }
    }
    return longest;
}

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";

test "request rejection statuses produce exact empty close responses" {
    const Case = struct {
        status: request_head.Status,
        expected: []const u8,
    };
    const suffix =
        "content-length: 0\r\n" ++
        "date: " ++ fixed_date ++ "\r\n" ++
        "connection: close\r\n" ++
        "\r\n";
    const bad_request = "HTTP/1.1 400 Bad Request\r\n" ++ suffix;
    const payload_too_large = "HTTP/1.1 413 Payload Too Large\r\n" ++ suffix;
    const uri_too_long = "HTTP/1.1 414 URI Too Long\r\n" ++ suffix;
    const fields_too_large =
        "HTTP/1.1 431 Request Header Fields Too Large\r\n" ++ suffix;
    const not_implemented = "HTTP/1.1 501 Not Implemented\r\n" ++ suffix;
    const version_unsupported =
        "HTTP/1.1 505 HTTP Version Not Supported\r\n" ++ suffix;
    const cases = [_]Case{
        .{ .status = .bad_request, .expected = bad_request },
        .{ .status = .payload_too_large, .expected = payload_too_large },
        .{ .status = .uri_too_long, .expected = uri_too_long },
        .{ .status = .request_header_fields_too_large, .expected = fields_too_large },
        .{ .status = .not_implemented, .expected = not_implemented },
        .{ .status = .http_version_not_supported, .expected = version_unsupported },
    };

    for (cases) |case| {
        try expectExact(.{ .status = case.status }, .{ .date = fixed_date }, case.expected);
    }
}

test "request rejection response forwards static Server identity in runtime order" {
    const expected =
        "HTTP/1.1 400 Bad Request\r\n" ++
        "content-length: 0\r\n" ++
        "date: " ++ fixed_date ++ "\r\n" ++
        "server: edge-app\r\n" ++
        "connection: close\r\n" ++
        "\r\n";
    try expectExact(
        .{ .status = .bad_request },
        .{
            .date = fixed_date,
            .server_identity = response_head.ServerIdentity.init("edge-app"),
        },
        expected,
    );
}

test "capacity probe is the exact upper bound for every error status" {
    var output: [512]u8 = undefined;
    const runtime_fields = RuntimeFields{ .date = fixed_date };
    const probe = try writeCapacityProbe(&output, runtime_fields);
    const required = probe.len;
    for (400..600) |code| {
        const result = try write(
            limits.standard_response_head_limits,
            response_transfer.standard_trailer_limits,
            &output,
            .{ .status = @enumFromInt(code) },
            runtime_fields,
        );
        try std.testing.expect(result.bytes.len <= required);
    }
    _ = try writeCapacityProbe(output[0..required], runtime_fields);
    try std.testing.expectError(
        error.OutputTooSmall,
        writeCapacityProbe(output[0 .. required - 1], runtime_fields),
    );
}

test "request rejection adapter requires error and close semantics before mutation" {
    var output = [_]u8{0xa5} ** 256;
    const before = output;
    try std.testing.expectError(error.InvalidResponse, write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        &output,
        .{ .status = .bad_request, .close = false },
        .{ .date = fixed_date },
    ));
    try std.testing.expectEqualSlices(u8, &before, &output);

    try std.testing.expectError(error.InvalidResponse, write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        &output,
        .{ .status = .ok },
        .{ .date = fixed_date },
    ));
    try std.testing.expectEqualSlices(u8, &before, &output);
}

test "request-head parser rejections serialize through the close adapter" {
    const unsupported_version = "GET / HTTP/1.0\r\nHost: example.test\r\n\r\n";
    const cases = [_]struct {
        wire: []const u8,
        status: request_head.Status,
    }{
        .{ .wire = "GET / HTTP/1.1\nHost: example.test\n\n", .status = .bad_request },
        .{ .wire = unsupported_version, .status = .http_version_not_supported },
    };
    for (cases) |case| {
        const rejection = try parseHeadRejection(
            limits.standard_request_head_limits,
            case.wire,
        );
        try std.testing.expectEqual(case.status, rejection.status);
        try expectSerializedClose(rejection);
    }

    const request_line_limits = limits.RequestHeadLimits{
        .head_bytes_max = 64,
        .request_line_bytes_max = 15,
        .field_line_bytes_max = 32,
        .fields_max = 4,
    };
    const line_rejection = try parseHeadRejection(request_line_limits, "GET / HTTP/1.1\r");
    try std.testing.expectEqual(request_head.Status.uri_too_long, line_rejection.status);
    try expectSerializedClose(line_rejection);

    const field_limits = limits.RequestHeadLimits{
        .head_bytes_max = 64,
        .request_line_bytes_max = 32,
        .field_line_bytes_max = 8,
        .fields_max = 4,
    };
    const field_rejection = try parseHeadRejection(
        field_limits,
        "GET / HTTP/1.1\r\nHost: x\r",
    );
    try std.testing.expectEqual(
        request_head.Status.request_header_fields_too_large,
        field_rejection.status,
    );
    try expectSerializedClose(field_rejection);
}

test "request semantic and body-limit rejections serialize through the close adapter" {
    const semantic_cases = [_]struct {
        wire: []const u8,
        status: request_head.Status,
    }{
        .{
            .wire = "GET / HTTP/1.1\r\nHost: example.test\r\n" ++
                "Content-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
            .status = .bad_request,
        },
        .{
            .wire = "CONNECT example.test:443 HTTP/1.1\r\nHost: example.test\r\n\r\n",
            .status = .not_implemented,
        },
    };
    for (semantic_cases) |case| {
        const rejection = try analyzeRejection(case.wire);
        try std.testing.expectEqual(case.status, rejection.status);
        try expectSerializedClose(rejection);
    }

    var decoder = chunked.StandardDecoder.init(2);
    const result = decoder.feed("1\r\n");
    const body_rejection = switch (result.event) {
        .rejected => |rejection| request_head.Rejection{
            .status = rejection.status,
            .close = rejection.close,
        },
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(request_head.Status.payload_too_large, body_rejection.status);
    try expectSerializedClose(body_rejection);
}

fn expectExact(
    rejection: request_head.Rejection,
    runtime_fields: RuntimeFields,
    expected: []const u8,
) !void {
    var output: [256]u8 = undefined;
    const result = try write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        &output,
        rejection,
        runtime_fields,
    );
    try std.testing.expectEqualStrings(expected, result.bytes);
    try std.testing.expect(result.plan.framing == .fixed);
    try std.testing.expectEqual(@as(u64, 0), result.plan.framing.fixed);
    try std.testing.expect(!result.plan.send_body);
}

fn expectSerializedClose(rejection: request_head.Rejection) !void {
    var output: [256]u8 = undefined;
    const result = try write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        &output,
        rejection,
        .{ .date = fixed_date },
    );
    try std.testing.expect(std.mem.endsWith(
        u8,
        result.bytes,
        "date: " ++ fixed_date ++ "\r\nconnection: close\r\n\r\n",
    ));
}

fn parseHeadRejection(
    comptime request_limits: limits.RequestHeadLimits,
    wire: []const u8,
) !request_head.Rejection {
    const Decoder = request_head.Decoder(request_limits);
    var decoder = Decoder.init();
    return switch (decoder.feed(wire).state) {
        .rejected => |rejection| rejection,
        else => error.TestUnexpectedResult,
    };
}

fn analyzeRejection(wire: []const u8) !request_head.Rejection {
    const Decoder = request_head.Decoder(limits.standard_request_head_limits);
    var decoder = Decoder.init();
    const parsed = decoder.feed(wire);
    const head = switch (parsed.state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    var decoded_path: [512]u8 = undefined;
    return switch (request_analysis.analyze(
        16,
        4,
        head,
        decoder.fields(),
        decoder.bytes(),
        &decoded_path,
    )) {
        .rejected => |rejection| rejection,
        .accepted => error.TestUnexpectedResult,
    };
}
