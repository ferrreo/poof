const std = @import("std");

pub const chunked = @import("http1/chunked.zig");
pub const authority = @import("http1/authority.zig");
pub const limits = @import("http1/limits.zig");
pub const media_type = @import("http1/media_type.zig");
pub const query = @import("http1/query.zig");
pub const rejection_response = @import("http1/rejection_response.zig");
pub const request_accept_encoding = @import("http1/request_accept_encoding.zig");
pub const request_analysis = @import("http1/request_analysis.zig");
pub const request_connection = @import("http1/request_connection.zig");
pub const request_cors = @import("http1/request_cors.zig");
pub const request_content = @import("http1/request_content.zig");
pub const request_expect = @import("http1/request_expect.zig");
pub const request_fields = @import("http1/request_fields.zig");
pub const request_framing = @import("http1/request_framing.zig");
pub const request_forwarded = @import("http1/request_forwarded.zig");
pub const request_head = @import("http1/request_head.zig");
pub const request_proxy_identity = @import("http1/request_proxy_identity.zig");
pub const request_te = @import("http1/request_te.zig");
pub const request_target = @import("http1/request_target.zig");
pub const request_trailers = @import("http1/request_trailers.zig");
pub const request_x_forwarded = @import("http1/request_x_forwarded.zig");
pub const response_coding_fields = @import("http1/response_coding_fields.zig");
pub const response_content_coding = @import("http1/response_content_coding.zig");
pub const response_cors_fields = @import("http1/response_cors_fields.zig");
pub const response_field_rules = @import("http1/response_field_rules.zig");
pub const response_framing = @import("http1/response_framing.zig");
pub const response_head = @import("http1/response_head.zig");
pub const response_headers = @import("http1/response_headers.zig");
pub const response_transfer = @import("http1/response_transfer.zig");
pub const security_canaries = @import("http1/security_canaries.zig");
pub const status = @import("http1/status.zig");
pub const syntax = @import("http1/syntax.zig");

const ping_request = "GET /ping HTTP/1.1\r\nHost: example.test\r\n\r\n";
const ping_response =
    "HTTP/1.1 200 OK\r\n" ++
    "content-type: text/plain; charset=utf-8\r\n" ++
    "content-length: 4\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "\r\n" ++
    "pong";

const trailer_request_head =
    "POST /upload HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "TE: trailers\r\n" ++
    "Trailer: Content-Digest\r\n" ++
    "\r\n";
const trailer_request_body =
    "4\r\ndata\r\n" ++
    "0\r\n" ++
    "Content-Digest: sha-256=:test:\r\n" ++
    "\r\n";

const trailer_response =
    "HTTP/1.1 200 OK\r\n" ++
    "content-type: text/plain; charset=utf-8\r\n" ++
    "transfer-encoding: chunked\r\n" ++
    "trailer: x-checksum\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "\r\n" ++
    "4\r\ndata\r\n" ++
    "0\r\n" ++
    "x-checksum: valid\r\n" ++
    "\r\n";

test "fragmented ping request produces exact fixed response" {
    const Decoder = request_head.Decoder(limits.standard_request_head_limits);
    const PingHeaders = response_headers.Headers(limits.standard_response_head_limits);
    var headers = PingHeaders{};
    var split: usize = 0;
    while (split <= ping_request.len) : (split += 1) {
        var decoder = Decoder.init();
        _ = decoder.feed(ping_request[0..split]);
        const parsed = decoder.feed(ping_request[split..]);
        const head = switch (parsed.state) {
            .ready => |head| head,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqualStrings("GET", head.method.slice(decoder.bytes()));
        try std.testing.expectEqualStrings("/ping", head.target.slice(decoder.bytes()));
        var decoded_path: [ping_request.len]u8 = undefined;
        const analysis = switch (request_analysis.analyze(
            query.segments_standard_max,
            request_trailers.standard_names_max,
            head,
            decoder.fields(),
            decoder.bytes(),
            &decoded_path,
        )) {
            .accepted => |accepted| accepted,
            .rejected => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqualStrings("/ping", analysis.target.origin.decoded_path);
        try std.testing.expect(analysis.framing.body == .none);

        var output: [ping_response.len]u8 = undefined;
        const written = try response_head.write(
            limits.standard_response_head_limits,
            response_transfer.standard_trailer_limits,
            &output,
            .{
                .framing = .{
                    .status = .ok,
                    .request_is_head = false,
                    .request_accepts_trailers = false,
                    .body = .{ .fixed = 4 },
                    .trailers_declared = false,
                },
                .default_content_type = media_type.text,
                .date = "Tue, 14 Jul 2026 12:00:00 GMT",
            },
            &headers,
        );
        @memcpy(output[written.bytes.len..], "pong");
        try std.testing.expectEqualStrings(ping_response, &output);
    }
}

test "chunked request composes declared trailers and preserves pipeline" {
    const HeadDecoder = request_head.Decoder(limits.standard_request_head_limits);
    var head_decoder = HeadDecoder.init();
    const head_result = head_decoder.feed(trailer_request_head ++ trailer_request_body ++ "NEXT");
    try std.testing.expectEqual(trailer_request_head.len, head_result.consumed);
    const head = switch (head_result.state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    var decoded_path: [trailer_request_head.len]u8 = undefined;
    const analysis = switch (request_analysis.analyze(
        query.segments_standard_max,
        request_trailers.standard_names_max,
        head,
        head_decoder.fields(),
        head_decoder.bytes(),
        &decoded_path,
    )) {
        .accepted => |accepted| accepted,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expect(analysis.framing.body == .chunked);
    try std.testing.expect(analysis.framing.trailer_declared);

    var chunk_decoder = chunked.StandardDecoder.init(trailer_request_body.len);
    var body: [4]u8 = undefined;
    var body_length: usize = 0;
    var body_offset: usize = 0;
    while (body_offset < trailer_request_body.len) {
        const result = chunk_decoder.feed(trailer_request_body[body_offset..]);
        body_offset += result.consumed;
        switch (result.event) {
            .data => |data| {
                @memcpy(body[body_length..][0..data.len], data);
                body_length += data.len;
            },
            .trailers_begin => break,
            .need_more => return error.TestUnexpectedResult,
            .rejected => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqualStrings("data", body[0..body_length]);

    const trailer_budget = trailer_request_body.len - chunk_decoder.wireBytesConsumed();
    var trailer_decoder = request_trailers.StandardDecoder.init(
        analysis.trailer_declarations,
        head_decoder.bytes(),
        trailer_budget,
    );
    const wire_with_pipeline = trailer_request_body ++ "NEXT";
    const trailer_result = trailer_decoder.feed(wire_with_pipeline[body_offset..]);
    try std.testing.expect(trailer_result.event == .ready);
    try std.testing.expectEqual(trailer_request_body.len, body_offset + trailer_result.consumed);
    try std.testing.expectEqualStrings(
        "Content-Digest",
        trailer_decoder.fields()[0].name.slice(trailer_decoder.bytes()),
    );
    try std.testing.expectEqualStrings("NEXT", wire_with_pipeline[trailer_request_body.len..]);
}

test "chunked response composes negotiated declared trailers" {
    const HeadDecoder = request_head.Decoder(limits.standard_request_head_limits);
    const Headers = response_headers.Headers(limits.standard_response_head_limits);
    var request_decoder = HeadDecoder.init();
    const request = request_decoder.feed(trailer_request_head);
    const request_head_value = switch (request.state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    var decoded_path: [trailer_request_head.len]u8 = undefined;
    const request_analysis_value = switch (request_analysis.analyze(
        query.segments_standard_max,
        request_trailers.standard_names_max,
        request_head_value,
        request_decoder.fields(),
        request_decoder.bytes(),
        &decoded_path,
    )) {
        .accepted => |accepted| accepted,
        .rejected => return error.TestUnexpectedResult,
    };
    var headers = Headers{};
    var output: [trailer_response.len]u8 = undefined;
    var cursor: usize = 0;
    const trailer_names = [_][]const u8{"X-Checksum"};

    const head = try response_head.write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        output[cursor..],
        .{
            .framing = .{
                .status = .ok,
                .request_is_head = false,
                .request_accepts_trailers = request_analysis_value.accepts_response_trailers,
                .body = .stream_unknown,
                .trailers_declared = true,
            },
            .default_content_type = media_type.text,
            .trailer_names = &trailer_names,
            .date = "Tue, 14 Jul 2026 12:00:00 GMT",
        },
        &headers,
    );
    cursor += head.bytes.len;
    const chunk = try response_transfer.writeChunk(output[cursor..], "data");
    cursor += chunk.len;
    const trailer_fields = [_]response_transfer.TrailerField{
        .{ .name = "X-Checksum", .value = "valid" },
    };
    const undeclared_fields = [_]response_transfer.TrailerField{
        .{ .name = "X-Other", .value = "invalid" },
    };
    var rejected_terminal = [_]u8{0xa5} ** 64;
    const rejected_before = rejected_terminal;
    try std.testing.expectError(error.UndeclaredField, response_transfer.writeTerminal(
        response_transfer.standard_trailer_limits,
        &rejected_terminal,
        head.trailer_plan,
        &undeclared_fields,
    ));
    try std.testing.expectEqualSlices(u8, &rejected_before, &rejected_terminal);
    const terminal = try response_transfer.writeTerminal(
        response_transfer.standard_trailer_limits,
        output[cursor..],
        head.trailer_plan,
        &trailer_fields,
    );
    cursor += terminal.len;

    try std.testing.expect(head.plan.emit_trailers);
    try std.testing.expect(head.trailer_plan.emitted);
    try std.testing.expectEqual(trailer_response.len, cursor);
    try std.testing.expectEqualStrings(trailer_response, &output);
}

test {
    _ = chunked;
    _ = authority;
    _ = limits;
    _ = query;
    _ = rejection_response;
    _ = request_analysis;
    _ = request_connection;
    _ = request_cors;
    _ = request_fields;
    _ = request_framing;
    _ = request_forwarded;
    _ = request_head;
    _ = request_proxy_identity;
    _ = request_te;
    _ = request_target;
    _ = request_trailers;
    _ = request_x_forwarded;
    _ = response_cors_fields;
    _ = response_framing;
    _ = response_field_rules;
    _ = response_head;
    _ = response_headers;
    _ = response_transfer;
    _ = security_canaries;
    _ = status;
    _ = syntax;
}
