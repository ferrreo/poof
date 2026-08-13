const std = @import("std");
const chunked = @import("../../../../src/internal/http1/chunked.zig");
const limits = @import("../../../../src/internal/http1/limits.zig");
const query = @import("../../../../src/internal/http1/query.zig");
const request_analysis = @import("../../../../src/internal/http1/request_analysis.zig");
const request_head = @import("../../../../src/internal/http1/request_head.zig");
const request_trailers = @import("../../../../src/internal/http1/request_trailers.zig");

const request_head_wire =
    "POST /upload?part=two HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "TE: trailers\r\n" ++
    "Trailer: Content-Digest\r\n" ++
    "\r\n";
const request_body_wire =
    "2; x=y\r\nda\r\n" ++
    "2\r\nta\r\n" ++
    "0\r\n" ++
    "Content-Digest: sha-256=:test:\r\n" ++
    "\r\n";
const pipeline_wire = "GET /canary HTTP/1.1\r\nHost: example.test\r\n\r\n";
const complete_wire = request_head_wire ++ request_body_wire ++ pipeline_wire;

const Fragmentation = union(enum) {
    contiguous,
    split: usize,
    one_byte,
};

const Snapshot = struct {
    consumed: usize,
    body: [4]u8,
    trailer_name: ["Content-Digest".len]u8,
    trailer_value: ["sha-256=:test:".len]u8,
};

const Cursor = struct {
    offset: usize = 0,
    mode: Fragmentation,

    fn end(self: Cursor) usize {
        return switch (self.mode) {
            .contiguous => complete_wire.len,
            .split => |split| if (self.offset < split) split else complete_wire.len,
            .one_byte => @min(self.offset + 1, complete_wire.len),
        };
    }
};

test "integrated chunked request is invariant across every fragmentation" {
    const expected = try drive(.contiguous);
    try std.testing.expectEqual(request_head_wire.len + request_body_wire.len, expected.consumed);
    try std.testing.expectEqualStrings("data", &expected.body);
    try std.testing.expectEqualStrings("Content-Digest", &expected.trailer_name);
    try std.testing.expectEqualStrings("sha-256=:test:", &expected.trailer_value);

    var split: usize = 0;
    while (split <= complete_wire.len) : (split += 1) {
        try std.testing.expectEqualDeep(expected, try drive(.{ .split = split }));
    }
    try std.testing.expectEqualDeep(expected, try drive(.one_byte));
}

fn drive(mode: Fragmentation) !Snapshot {
    const HeadDecoder = request_head.Decoder(limits.standard_request_head_limits);
    var head_decoder = HeadDecoder.init();
    var cursor = Cursor{ .mode = mode };
    const head = try driveHead(&head_decoder, &cursor);

    var decoded_path: [request_head_wire.len]u8 = undefined;
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
    try std.testing.expect(analysis.accepts_response_trailers);

    var body: [4]u8 = undefined;
    var body_length: usize = 0;
    var chunk_decoder = chunked.StandardDecoder.init(request_body_wire.len);
    try driveChunks(&chunk_decoder, &cursor, &body, &body_length);
    try std.testing.expectEqual(body.len, body_length);

    const trailer_budget = request_body_wire.len - chunk_decoder.wireBytesConsumed();
    var trailer_decoder = request_trailers.StandardDecoder.init(
        analysis.trailer_declarations,
        head_decoder.bytes(),
        trailer_budget,
    );
    try driveTrailers(&trailer_decoder, &cursor);
    try std.testing.expectEqualStrings(pipeline_wire, complete_wire[cursor.offset..]);
    const field = trailer_decoder.fields()[0];
    const trailer_bytes = trailer_decoder.bytes();
    var snapshot = Snapshot{
        .consumed = cursor.offset,
        .body = body,
        .trailer_name = undefined,
        .trailer_value = undefined,
    };
    @memcpy(&snapshot.trailer_name, field.name.slice(trailer_bytes));
    @memcpy(&snapshot.trailer_value, field.value.slice(trailer_bytes));
    return snapshot;
}

fn driveHead(decoder: anytype, cursor: *Cursor) !request_head.Head {
    while (cursor.offset < complete_wire.len) {
        const fragment_end = cursor.end();
        const result = decoder.feed(complete_wire[cursor.offset..fragment_end]);
        cursor.offset += result.consumed;
        switch (result.state) {
            .need_more => try expectFragmentConsumed(cursor, fragment_end),
            .ready => |head| return head,
            .rejected => return error.TestUnexpectedResult,
        }
    }
    return error.TestUnexpectedResult;
}

fn driveChunks(
    decoder: anytype,
    cursor: *Cursor,
    body: []u8,
    body_length: *usize,
) !void {
    while (cursor.offset < complete_wire.len) {
        const fragment_end = cursor.end();
        const result = decoder.feed(complete_wire[cursor.offset..fragment_end]);
        cursor.offset += result.consumed;
        switch (result.event) {
            .need_more => try expectFragmentConsumed(cursor, fragment_end),
            .data => |data| {
                if (data.len > body.len - body_length.*) return error.TestUnexpectedResult;
                @memcpy(body[body_length.*..][0..data.len], data);
                body_length.* += data.len;
            },
            .trailers_begin => return,
            .rejected => return error.TestUnexpectedResult,
        }
    }
    return error.TestUnexpectedResult;
}

fn driveTrailers(decoder: anytype, cursor: *Cursor) !void {
    while (cursor.offset < complete_wire.len) {
        const fragment_end = cursor.end();
        const result = decoder.feed(complete_wire[cursor.offset..fragment_end]);
        cursor.offset += result.consumed;
        switch (result.event) {
            .need_more => try expectFragmentConsumed(cursor, fragment_end),
            .ready => return,
            .rejected => return error.TestUnexpectedResult,
        }
    }
    return error.TestUnexpectedResult;
}

fn expectFragmentConsumed(cursor: *const Cursor, fragment_end: usize) !void {
    if (cursor.offset != fragment_end) return error.TestUnexpectedResult;
}
