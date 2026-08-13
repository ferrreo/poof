const std = @import("std");
const limits = @import("limits.zig");
const query = @import("query.zig");
const rejection_response = @import("rejection_response.zig");
const request_analysis = @import("request_analysis.zig");
const request_framing = @import("request_framing.zig");
const request_head = @import("request_head.zig");
const request_trailers = @import("request_trailers.zig");
const response_transfer = @import("response_transfer.zig");
const status_module = @import("status.zig");

const Status = status_module.Status;

const Canary = struct {
    wire: []const u8,
    status: Status,
};

const prefix = "POST / HTTP/1.1\r\nHost: example.test\r\n";

const canaries = [_]Canary{
    .{
        .wire = prefix ++ "Content-Length: 5\r\nContent-Length: 5\r\n\r\nhello",
        .status = .bad_request,
    },
    .{
        .wire = prefix ++ "Content-Length: 5\r\nContent-Length: 6\r\n\r\nhello!",
        .status = .bad_request,
    },
    .{ .wire = prefix ++ "Content-Length: 5, 5\r\n\r\nhello", .status = .bad_request },
    .{
        .wire = prefix ++ "Content-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n",
        .status = .bad_request,
    },
    .{
        .wire = prefix ++ "Transfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n",
        .status = .bad_request,
    },
    .{
        .wire = prefix ++ "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n",
        .status = .bad_request,
    },
    .{
        .wire = prefix ++ "Transfer-Encoding : chunked\r\n\r\n",
        .status = .bad_request,
    },
    .{
        .wire = prefix ++ "Transfer-Encoding:\x0bchunked\r\n\r\n",
        .status = .bad_request,
    },
    .{
        .wire = prefix ++ "Transfer-Encoding: chunked\r\n chunk-extension: x\r\n\r\n",
        .status = .bad_request,
    },
    .{
        .wire = prefix ++ "Transfer-Encoding: gzip, chunked\r\n\r\n",
        .status = .not_implemented,
    },
    .{
        .wire = prefix ++ "Transfer-Encoding: chunked, gzip\r\n\r\n",
        .status = .bad_request,
    },
    .{
        .wire = prefix ++ "Transfer-Encoding: chunked, chunked\r\n\r\n",
        .status = .bad_request,
    },
    .{
        .wire = prefix ++ "Transfer-Encoding: chunked; p=x\r\n\r\n",
        .status = .bad_request,
    },
    .{
        .wire = "POST / HTTP/1.1\r\nHost: one\r\nHost: two\r\n\r\n",
        .status = .bad_request,
    },
    .{
        .wire = "POST / HTTP/1.1\nHost: example.test\nContent-Length: 0\n\n",
        .status = .bad_request,
    },
    .{
        .wire = prefix ++ "X-Test: safe\rInjected: yes\r\n\r\n",
        .status = .bad_request,
    },
    .{
        .wire = prefix ++ "X-Test: safe\x00hidden\r\n\r\n",
        .status = .bad_request,
    },
};

test "request-smuggling canaries reject and close at the first semantic boundary" {
    for (canaries) |canary| {
        const rejection = try rejectRequest(canary.wire);
        try std.testing.expectEqual(canary.status, rejection.status);
        try std.testing.expect(rejection.close);
        try expectExactClosingResponse(rejection);
    }
}

const pipeline_canary = "GET /canary HTTP/1.1\r\nHost: example.test\r\n\r\n";

test "semantic rejection closes before a pipelined canary can dispatch" {
    const first_requests = [_][]const u8{
        "GET /?x=a;b HTTP/1.1\r\nHost: example.test\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: example.test\r\nTE: trailers;q=1\r\n\r\n",
        prefix ++ "Transfer-Encoding: chunked\r\nTrailer: Host\r\n\r\n",
    };
    for (first_requests) |first| {
        var wire: [256]u8 = undefined;
        @memcpy(wire[0..first.len], first);
        @memcpy(wire[first.len..][0..pipeline_canary.len], pipeline_canary);
        const complete = wire[0 .. first.len + pipeline_canary.len];
        const rejection = try rejectSemanticRequest(complete, first.len);
        try std.testing.expectEqual(Status.bad_request, rejection.status);
        try std.testing.expect(rejection.close);
        try expectExactClosingResponse(rejection);
    }
}

fn rejectRequest(wire: []const u8) !request_head.Rejection {
    const Decoder = request_head.Decoder(limits.standard_request_head_limits);
    var decoder = Decoder.init();
    const decoded = decoder.feed(wire);
    switch (decoded.state) {
        .need_more => return error.TestUnexpectedResult,
        .rejected => |rejection| return rejection,
        .ready => {},
    }

    return switch (request_framing.analyze(decoder.fields(), decoder.bytes())) {
        .accepted => error.TestUnexpectedResult,
        .rejected => |rejection| .{
            .status = rejection.status,
            .close = rejection.close,
        },
    };
}

fn rejectSemanticRequest(wire: []const u8, first_length: usize) !request_head.Rejection {
    const Decoder = request_head.Decoder(limits.standard_request_head_limits);
    var decoder = Decoder.init();
    const decoded = decoder.feed(wire);
    try std.testing.expectEqual(first_length, decoded.consumed);
    const head = switch (decoded.state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(pipeline_canary, wire[decoded.consumed..]);
    var decoded_path: [256]u8 = undefined;
    return switch (request_analysis.analyze(
        query.segments_standard_max,
        request_trailers.standard_names_max,
        head,
        decoder.fields(),
        decoder.bytes(),
        &decoded_path,
    )) {
        .rejected => |rejection| rejection,
        .accepted => error.TestUnexpectedResult,
    };
}

fn expectExactClosingResponse(rejection: request_head.Rejection) !void {
    var output: [256]u8 = undefined;
    const written = try rejection_response.write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        &output,
        rejection,
        .{ .date = "Tue, 14 Jul 2026 12:00:00 GMT" },
    );
    const suffix =
        "content-length: 0\r\n" ++
        "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
        "connection: close\r\n" ++
        "\r\n";
    const expected = switch (rejection.status) {
        .bad_request => "HTTP/1.1 400 Bad Request\r\n" ++ suffix,
        .not_implemented => "HTTP/1.1 501 Not Implemented\r\n" ++ suffix,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(expected, written.bytes);
}
