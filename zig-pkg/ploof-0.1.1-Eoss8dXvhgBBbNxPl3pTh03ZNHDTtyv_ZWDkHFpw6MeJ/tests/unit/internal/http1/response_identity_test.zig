const std = @import("std");
const limits = @import("../../../../src/internal/http1/limits.zig");
const media_type = @import("../../../../src/internal/http1/media_type.zig");
const response_head = @import("../../../../src/internal/http1/response_head.zig");
const response_headers = @import("../../../../src/internal/http1/response_headers.zig");
const response_transfer = @import("../../../../src/internal/http1/response_transfer.zig");

const Headers = response_headers.Headers(limits.standard_response_head_limits);

test "static Server identity follows Date and precedes Connection" {
    var headers = Headers{};
    try headers.set("X-App", "test");
    var output: [512]u8 = undefined;
    const result = try response_head.write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        &output,
        .{
            .framing = .{
                .status = .ok,
                .request_is_head = false,
                .request_accepts_trailers = false,
                .body = .{ .fixed = 1 },
                .trailers_declared = false,
            },
            .default_content_type = media_type.text,
            .date = "Tue, 14 Jul 2026 12:00:00 GMT",
            .server_identity = response_head.ServerIdentity.init("ploof/0.1.0"),
            .connection_close = true,
        },
        &headers,
    );
    const expected =
        "HTTP/1.1 200 OK\r\n" ++
        "x-app: test\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 1\r\n" ++
        "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
        "server: ploof/0.1.0\r\n" ++
        "connection: close\r\n" ++
        "\r\n";
    try std.testing.expectEqualStrings(expected, result.bytes);
}

test "static Server identity consumes response head limits before mutation" {
    const constrained = limits.ResponseHeadLimits{
        .head_bytes_max = 256,
        .field_line_bytes_max = 40,
        .fields_max = 8,
    };
    const ConstrainedHeaders = response_headers.Headers(constrained);
    var headers = ConstrainedHeaders{};
    var output = [_]u8{0xa5} ** 256;
    const before = output;
    try std.testing.expectError(
        error.ResponseHeadTooLarge,
        response_head.write(
            constrained,
            response_transfer.standard_trailer_limits,
            &output,
            .{
                .framing = .{
                    .status = .no_content,
                    .request_is_head = false,
                    .request_accepts_trailers = false,
                    .body = .none,
                    .trailers_declared = false,
                },
                .default_content_type = media_type.octet_stream,
                .date = "Tue, 14 Jul 2026 12:00:00 GMT",
                .server_identity = response_head.ServerIdentity.init(
                    "identity-too-long-for-this-field-profile",
                ),
            },
            &headers,
        ),
    );
    try std.testing.expectEqualSlices(u8, &before, &output);
}
