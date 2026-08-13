const std = @import("std");
const application = @import("../../src/application.zig");
const body = @import("../../src/body.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const limits = @import("../../src/internal/http1/limits.zig");
const request_head = @import("../../src/internal/http1/request_head.zig");
const request_trailers = @import("../../src/internal/http1/request_trailers.zig");
const config = @import("../../src/internal/runtime/config.zig");
const connection_body = @import("../../src/internal/runtime/connection/body.zig");
const body_runtime = @import("../../src/internal/runtime/connection/body_runtime.zig");
const chunked_body = @import("../../src/internal/runtime/connection/chunked_body.zig");
const gzip_encoder = @import("../../src/internal/runtime/gzip/encoder.zig");
const worker_storage = @import("../../src/internal/runtime/worker/storage.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const trailer_head =
    "POST /bytes HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Trailer: X-Check\r\n\r\n";
const chunked_bytes = "2\r\nab\r\n2\r\ncd\r\n0\r\nX-Check: yes\r\n\r\n";

const TestState = struct {
    body: [4]u8 = undefined,
    body_len: u8 = 0,
    bytes_calls: u8 = 0,
    text_calls: u8 = 0,
    saw_trailer: bool = false,
    fixed_trailers_empty: bool = false,
};

const TestContext = application.Context(TestState, response.standard_head_limits);
const TestResponse = TestContext.ResponseType;

fn bytesHandler(context: *TestContext, value: body.Bytes) TestResponse {
    context.state.bytes_calls += 1;
    const bytes = value.single() orelse return context.empty(.internal_server_error);
    context.state.body_len = @intCast(bytes.len);
    @memcpy(context.state.body[0..bytes.len], bytes);
    if (std.mem.eql(u8, context.request.path, "/fixed")) {
        context.state.fixed_trailers_empty = context.request.trailers.raw().count() == 0;
    } else {
        const value_view = context.request.trailers.all("x-check");
        context.state.saw_trailer = value_view.count() == 1 and
            std.mem.eql(u8, value_view.first().?, "yes");
    }
    return context.textStatic(.ok, "ok");
}

fn textHandler(context: *TestContext, value: body.Text) TestResponse {
    context.state.text_calls += 1;
    const bytes = value.single() orelse return context.empty(.internal_server_error);
    context.state.body_len = @intCast(bytes.len);
    @memcpy(context.state.body[0..bytes.len], bytes);
    return context.textStatic(.ok, "ok");
}

const TestApp = application.Application(.{
    .State = TestState,
    .response_gzip = application.ResponseGzip{ .minimum_bytes = 0, .level = .fastest },
    .routes = .{
        route.post("/bytes", body.bytes(.{
            .encoded_wire_bytes_max = 128,
            .decoded_bytes_max = 4,
        }, bytesHandler)),
        route.post("/fixed", body.bytes(.{
            .encoded_wire_bytes_max = 4,
            .decoded_bytes_max = 4,
        }, bytesHandler)),
        route.post("/text", body.text(.{
            .encoded_wire_bytes_max = 128,
            .decoded_bytes_max = 4,
        }, textHandler)),
    },
});

const response_staging_bytes: u32 = response.standard_head_limits.head_bytes_max +
    @as(u32, @intCast(gzip_encoder.bound(2) catch unreachable));
const test_limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .body_workspace_slots = 1,
    .chunked_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 128,
    .pipeline_bytes_per_connection = 128,
    .response_bytes_per_request = response_staging_bytes,
    .submission_entries = 8,
    .completion_entries = 16,
});
const TestStorage = worker_storage.Storage(TestApp, test_limits);

const Harness = struct {
    slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined,
    storage: TestStorage = undefined,
    state: TestState = .{},
    connection: ?u16 = null,

    fn init(self: *Harness) !void {
        try self.storage.init(&self.slab);
    }

    fn begin(self: *Harness, path: []const u8, chunked: bool) !u16 {
        const connection = self.connection orelse connection: {
            const acquired = self.storage.acquireConnection(.{ .value = 10 }) orelse {
                return error.TestUnexpectedResult;
            };
            self.connection = acquired;
            break :connection acquired;
        };
        const result = self.storage.acquireRequestClassified(connection, 1, chunked);
        const request = switch (result) {
            .acquired => |index| index,
            else => return error.TestUnexpectedResult,
        };
        const prepared = try TestApp.prepareHead(
            &self.state,
            &self.storage.requests[request].workspace,
            &self.storage.route_search_workspace,
            input(path),
            self.storage.responseWritable(request),
        );
        switch (prepared) {
            .receive_body => {},
            .prepared => return error.TestUnexpectedResult,
        }
        return request;
    }
};

fn input(path: []const u8) application.Input {
    return .{
        .method = "POST",
        .path = path,
        .raw_target = path,
        .raw_path = path,
        .date = fixed_date,
        .accept_encoding = .{ .gzip = 1000, .identity = 1000 },
    };
}

fn declarations() !request_trailers.StandardDeclarations {
    const HeadDecoder = request_head.Decoder(limits.standard_request_head_limits);
    var decoder = HeadDecoder.init();
    switch (decoder.feed(trailer_head).state) {
        .ready => {},
        else => return error.TestUnexpectedResult,
    }
    return request_trailers.StandardDeclarations.parse(
        decoder.fields(),
        trailer_head,
    );
}

fn feedChunked(
    harness: *Harness,
    request: u16,
    wire: []const u8,
) !chunked_body.ReadyTrailers {
    const state = try harness.storage.chunkedState(request);
    var offset: usize = 0;
    while (offset < wire.len) {
        const result = state.feed(wire[offset .. offset + 1]);
        if (result.consumed > 1) return error.TestUnexpectedResult;
        offset += result.consumed;
        switch (result.event) {
            .need_more => if (result.consumed == 0) return error.TestUnexpectedResult,
            .data => |data| try body_runtime.appendChunk(&harness.storage, request, data),
            .ready => return state.trailers() orelse error.TestUnexpectedResult,
            .rejected => return error.TestUnexpectedResult,
        }
    }
    return error.TestUnexpectedResult;
}

test "chunked sink appends fragments through exact limit and rejects overflow" {
    var harness = Harness{};
    try harness.init();
    const request = try harness.begin("/bytes", true);
    try body_runtime.startChunked(&harness.storage, request, .bytes);

    try body_runtime.appendChunk(&harness.storage, request, "ab");
    try body_runtime.appendChunk(&harness.storage, request, "cd");
    try std.testing.expectEqual(@as(u32, 4), harness.storage.requests[request].body.used);
    try std.testing.expectError(
        error.StateInvariant,
        body_runtime.appendChunk(&harness.storage, request, "e"),
    );
    try std.testing.expectEqual(@as(u32, 4), harness.storage.requests[request].body.used);
    const body_bytes = (try harness.storage.finishBody(request, .bytes)).bytes;
    try std.testing.expect(body_bytes.eql("abcd"));
}

test "chunked bytes reach handler with final trailers" {
    var harness = Harness{};
    try harness.init();
    const request = try harness.begin("/bytes", true);
    const state = try harness.storage.chunkedState(request);
    state.* = chunked_body.State.init(128, 4, try declarations(), trailer_head);
    try body_runtime.startChunked(&harness.storage, request, .bytes);

    const ready = try feedChunked(&harness, request, chunked_bytes);
    var forged_bytes: [64]u8 = @splat(0);
    try std.testing.expectError(
        error.StateInvariant,
        body_runtime.finishChunked(
            TestApp,
            &harness.storage,
            request,
            .{ .bytes = forged_bytes[0..ready.bytes.len], .fields = ready.fields },
        ),
    );
    const finished = try body_runtime.finishChunked(
        TestApp,
        &harness.storage,
        request,
        ready,
    );
    try std.testing.expectEqual(body_runtime.Event.prepared, finished.event);
    try std.testing.expectEqual(@as(u8, 1), harness.state.bytes_calls);
    try std.testing.expectEqual(@as(u8, 4), harness.state.body_len);
    try std.testing.expectEqualSlices(u8, "abcd", &harness.state.body);
    try std.testing.expect(harness.state.saw_trailer);
}

test "chunked text validates UTF-8 before application dispatch" {
    var valid = Harness{};
    try valid.init();
    const valid_request = try valid.begin("/text", true);
    const valid_state = try valid.storage.chunkedState(valid_request);
    valid_state.* = chunked_body.State.init(128, 4, .{}, "");
    try body_runtime.startChunked(&valid.storage, valid_request, .text);
    const valid_ready = try feedChunked(&valid, valid_request, "3\r\nh\xc3\xa9\r\n0\r\n\r\n");
    const valid_result = try body_runtime.finishChunked(
        TestApp,
        &valid.storage,
        valid_request,
        valid_ready,
    );
    try std.testing.expectEqual(body_runtime.Event.prepared, valid_result.event);
    try std.testing.expectEqual(@as(u8, 1), valid.state.text_calls);
    try std.testing.expectEqualSlices(u8, "h\xc3\xa9", valid.state.body[0..3]);

    var invalid = Harness{};
    try invalid.init();
    const invalid_request = try invalid.begin("/text", true);
    const invalid_state = try invalid.storage.chunkedState(invalid_request);
    invalid_state.* = chunked_body.State.init(128, 4, .{}, "");
    try body_runtime.startChunked(&invalid.storage, invalid_request, .text);
    const invalid_ready = try feedChunked(&invalid, invalid_request, "1\r\n\xff\r\n0\r\n\r\n");
    const invalid_result = try body_runtime.finishChunked(
        TestApp,
        &invalid.storage,
        invalid_request,
        invalid_ready,
    );
    try std.testing.expectEqual(body_runtime.Event.invalid_utf8, invalid_result.event);
    try std.testing.expectEqual(@as(u8, 0), invalid.state.text_calls);
}

test "fixed body dispatch receives empty trailers" {
    var harness = Harness{};
    try harness.init();
    const request = try harness.begin("/fixed", false);
    const receiver = switch (connection_body.FixedIdentity.init(2, 4, 4)) {
        .accepted => |value| value,
        .over_limit => return error.TestUnexpectedResult,
    };
    try body_runtime.startFixed(&harness.storage, request, receiver, .bytes);
    const finished = try body_runtime.feedFixed(
        TestApp,
        &harness.storage,
        request,
        "ok",
    );
    try std.testing.expectEqual(body_runtime.Event.prepared, finished.event);
    try std.testing.expect(harness.state.fixed_trailers_empty);
}

test "fixed and chunked completion gzip responses reuse worker workspace" {
    var harness = Harness{};
    try harness.init();

    const fixed_request = try harness.begin("/fixed", false);
    const receiver = switch (connection_body.FixedIdentity.init(2, 4, 4)) {
        .accepted => |value| value,
        .over_limit => return error.TestUnexpectedResult,
    };
    try body_runtime.startFixed(&harness.storage, fixed_request, receiver, .bytes);
    const fixed = try body_runtime.feedFixed(
        TestApp,
        &harness.storage,
        fixed_request,
        "ok",
    );
    try std.testing.expectEqual(body_runtime.Event.prepared, fixed.event);
    try expectGzipResponse(&harness.storage, fixed_request);
    try expectResponseGzipWorkspaceZero(&harness.storage);

    _ = try TestApp.complete(&harness.storage.requests[fixed_request].workspace);
    harness.storage.releaseRequest(harness.connection.?, fixed_request);
    const chunked_request = try harness.begin("/bytes", true);
    const state = try harness.storage.chunkedState(chunked_request);
    state.* = chunked_body.State.init(128, 4, try declarations(), trailer_head);
    try body_runtime.startChunked(&harness.storage, chunked_request, .bytes);
    const ready = try feedChunked(&harness, chunked_request, chunked_bytes);
    const chunked = try body_runtime.finishChunked(
        TestApp,
        &harness.storage,
        chunked_request,
        ready,
    );
    try std.testing.expectEqual(body_runtime.Event.prepared, chunked.event);
    try expectGzipResponse(&harness.storage, chunked_request);
    try expectResponseGzipWorkspaceZero(&harness.storage);
}

fn expectGzipResponse(storage: *const TestStorage, request: u16) !void {
    const used: usize = storage.requests[request].response_used;
    const wire = storage.responseReadable(request)[0..used];
    const marker = std.mem.indexOf(u8, wire, "\r\n\r\n") orelse {
        return error.TestUnexpectedResult;
    };
    const head = wire[0 .. marker + 4];
    const encoded = wire[marker + 4 ..];
    try std.testing.expect(std.mem.indexOf(
        u8,
        head,
        "content-encoding: gzip\r\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        head,
        "vary: Accept-Encoding\r\n",
    ) != null);

    var input_reader = std.Io.Reader.fixed(encoded);
    var decoder = std.compress.flate.Decompress.init(&input_reader, .gzip, &.{});
    var decoded: [2]u8 = undefined;
    var writer = std.Io.Writer.fixed(&decoded);
    const written = try decoder.reader.streamRemaining(&writer);
    try std.testing.expectEqual(@as(usize, 2), written);
    try std.testing.expectEqualStrings("ok", decoded[0..written]);
}

fn expectResponseGzipWorkspaceZero(storage: *const TestStorage) !void {
    for (std.mem.asBytes(&storage.response_gzip_workspace)) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}
