const std = @import("std");
const limits = @import("../../../../src/internal/http1/limits.zig");
const media_type = @import("../../../../src/internal/http1/media_type.zig");
const response_framing = @import("../../../../src/internal/http1/response_framing.zig");
const response_head = @import("../../../../src/internal/http1/response_head.zig");
const response_headers = @import("../../../../src/internal/http1/response_headers.zig");
const response_transfer = @import("../../../../src/internal/http1/response_transfer.zig");
const status = @import("../../../../src/internal/http1/status.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const Headers = response_headers.Headers(limits.standard_response_head_limits);

test "bodyless status response heads have exact wire bytes" {
    const cases = [_]struct {
        response_status: status.Status,
        expected: []const u8,
    }{
        .{
            .response_status = .no_content,
            .expected = "HTTP/1.1 204 No Content\r\n" ++
                "date: " ++ fixed_date ++ "\r\n\r\n",
        },
        .{
            .response_status = .reset_content,
            .expected = "HTTP/1.1 205 Reset Content\r\n" ++
                "content-length: 0\r\n" ++
                "date: " ++ fixed_date ++ "\r\n\r\n",
        },
        .{
            .response_status = .not_modified,
            .expected = "HTTP/1.1 304 Not Modified\r\n" ++
                "date: " ++ fixed_date ++ "\r\n\r\n",
        },
    };

    for (cases) |case| {
        try expectExact(case.response_status, false, .none, case.expected);
    }
}

test "HEAD response heads have exact hypothetical representation framing" {
    const common_prefix =
        "HTTP/1.1 200 OK\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n";
    const suffix = "date: " ++ fixed_date ++ "\r\n\r\n";
    const cases = [_]struct {
        body: response_framing.Body,
        expected: []const u8,
    }{
        .{
            .body = .{ .fixed = 17 },
            .expected = common_prefix ++ "content-length: 17\r\n" ++ suffix,
        },
        .{
            .body = .{ .stream_exact = 23 },
            .expected = common_prefix ++ "content-length: 23\r\n" ++ suffix,
        },
        .{
            .body = .stream_unknown,
            .expected = common_prefix ++ suffix,
        },
    };

    for (cases) |case| try expectExact(.ok, true, case.body, case.expected);
}

fn expectExact(
    response_status: status.Status,
    request_is_head: bool,
    body: response_framing.Body,
    expected: []const u8,
) !void {
    var headers = Headers{};
    var output: [256]u8 = undefined;
    const result = try response_head.write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        &output,
        .{
            .framing = .{
                .status = response_status,
                .request_is_head = request_is_head,
                .request_accepts_trailers = false,
                .body = body,
                .trailers_declared = false,
            },
            .default_content_type = media_type.text,
            .date = fixed_date,
        },
        &headers,
    );
    try std.testing.expectEqualStrings(expected, result.bytes);
    try std.testing.expect(!result.plan.send_body);
    try std.testing.expect(!result.plan.invoke_stream);
}
