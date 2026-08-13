const std = @import("std");
const application = @import("../../src/application.zig");
const body_runtime = @import("../../src/internal/runtime/connection/body_runtime.zig");
const chunked_body = @import("../../src/internal/runtime/connection/chunked_body.zig");
const config = @import("../../src/internal/runtime/config.zig");
const connection_body = @import("../../src/internal/runtime/connection/body.zig");
const endpoint = @import("../../src/endpoint.zig");
const gzip_encoder = @import("../../src/internal/runtime/gzip/encoder.zig");
const multipart = @import("../../src/multipart.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const worker_storage = @import("../../src/internal/runtime/worker/storage.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const boundary = "runtime-boundary";
const gzip_wire = "gzip-wire";
const body =
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"count\"\r\n\r\n" ++
    "17\r\n" ++
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"upload\"; filename=\"a.bin\"\r\n" ++
    "Content-Type: application/octet-stream\r\n\r\n" ++
    "abcdef\r\n" ++
    "--" ++ boundary ++ "--\r\n";

const MultipartBody = multipart.decode(.{
    .count = multipart.field(u16, multipart.required),
    .upload = multipart.file(multipart.DiscardSink, multipart.required),
}, .{ .limits = multipart.Limits.validate(.{
    .encoded_wire_bytes_max = 1024,
    .total_body_bytes_max = 512,
    .file_bytes_max = 64,
    .field_bytes_max = 16,
    .parts_max = 2,
    .files_max = 1,
    .part_headers_max = 2,
    .part_header_bytes_max = 192,
    .disposition_parameters_max = 3,
    .delimiter_transport_padding_bytes_max = 8,
    .name_bytes_max = 16,
    .filename_bytes_max = 32,
    .boundary_bytes_max = 32,
}) });
const Definition = endpoint.Endpoint(.{ .body = MultipartBody });
const MultipartSpec = @TypeOf(MultipartBody);

const AppState = struct {
    count: u16 = 0,
    fields: u8 = 0,
    completions: u8 = 0,
    trailers_empty: bool = false,
};
const Context = application.Context(AppState, response.standard_head_limits);

const Consumer = struct {
    pub const State = struct { count: u16 = 0 };

    pub fn init(_: Consumer, _: *Context) State {
        return .{};
    }

    pub fn field(_: Consumer, state: *State, value: @TypeOf(MultipartBody).Field) void {
        state.count = value.count;
    }

    pub fn fileStart(
        _: Consumer,
        _: *Context,
        _: *State,
        _: MultipartSpec.FileStart,
    ) MultipartSpec.FileAdmission(Context.ResponseType) {
        return .{ .accept = .{ .upload = {} } };
    }

    pub fn complete(
        _: Consumer,
        context: *Context,
        state: *State,
        _: Definition.InputType,
        _: MultipartSpec.Summaries,
    ) multipart.Decision(Context.ResponseType) {
        context.state.count = state.count;
        context.state.fields += 1;
        context.state.completions += 1;
        context.state.trailers_empty = context.request.trailers.raw().count() == 0;
        return multipart.commit(context.textStatic(.ok, "ok"));
    }
};

const App = application.Application(.{
    .State = AppState,
    .routes = .{route.post("/upload", Definition.handle(Consumer{}))},
});

const response_staging_bytes: u32 = response.standard_head_limits.head_bytes_max +
    @as(u32, @intCast(gzip_encoder.bound(2) catch unreachable));
const runtime_limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .body_workspace_slots = 1,
    .chunked_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 256,
    .pipeline_bytes_per_connection = 256,
    .response_bytes_per_request = response_staging_bytes,
    .submission_entries = 8,
    .completion_entries = 16,
});
const Storage = worker_storage.Storage(App, runtime_limits);

const Harness = struct {
    slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined,
    storage: Storage = undefined,
    state: AppState = .{},
    connection: ?u16 = null,

    fn init(self: *Harness) !void {
        try self.storage.init(&self.slab);
        self.connection = self.storage.acquireConnection(.{ .value = 10 });
        if (self.connection == null) return error.TestUnexpectedResult;
    }

    fn begin(self: *Harness, chunked: bool) !u16 {
        const request_input = input();
        var planned = App.plan(request_input, &self.storage.route_search_workspace);
        try App.__refinePlanBody(
            &planned,
            planned.body.selectMedia(0) orelse return error.TestUnexpectedResult,
        );
        const connection = self.connection orelse return error.TestUnexpectedResult;
        const acquired = self.storage.acquireRequestClassified(
            connection,
            planned.body.headWorkspaceClass(),
            chunked,
        );
        const request = switch (acquired) {
            .acquired => |index| index,
            else => return error.TestUnexpectedResult,
        };
        const request_workspace = try self.storage.bodyWorkspace(request);
        const prepared = try App.prepareHeadPlannedIn(
            &self.state,
            &self.storage.requests[request].workspace,
            request_workspace,
            self.storage.responseWritable(request),
            &planned,
            .{},
        );
        switch (prepared) {
            .receive_body => |plan| {
                try std.testing.expectEqual(.multipart, plan.decoderKind().?);
            },
            .prepared => return error.TestUnexpectedResult,
        }
        return request;
    }
};

test "fixed identity multipart streams without retaining body bytes" {
    var harness = Harness{};
    try harness.init();
    const request = try harness.begin(false);
    const receiver = switch (connection_body.FixedIdentity.init(
        body.len,
        1024,
        512,
    )) {
        .accepted => |value| value,
        .over_limit => return error.TestUnexpectedResult,
    };
    try body_runtime.startMultipartFixed(
        App,
        &harness.storage,
        request,
        receiver,
        boundary,
    );

    var final: ?body_runtime.FeedResult = null;
    for (body) |byte| {
        const result = try body_runtime.feedMultipartFixed(
            App,
            &harness.storage,
            request,
            @as(*const [1]u8, &byte),
        );
        try std.testing.expectEqual(@as(u32, 0), harness.storage.requests[request].body.used);
        if (result.event != .need_more) final = result;
    }
    try expectPrepared(&harness, request, final orelse return error.TestUnexpectedResult);
}

test "chunked identity multipart streams framing fragments and finishes once" {
    var harness = Harness{};
    try harness.init();
    const request = try harness.begin(true);
    const receiver = try harness.storage.chunkedState(request);
    receiver.* = chunked_body.State.init(1024, 512, .{}, "");
    try body_runtime.startMultipartChunked(
        App,
        &harness.storage,
        request,
        boundary,
    );

    var wire_storage: [body.len + 32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&wire_storage);
    try writer.print("{x}\r\n{s}\r\n0\r\n\r\n", .{ body.len, body });
    const wire = writer.buffered();
    var ready: ?chunked_body.ReadyTrailers = null;
    for (wire) |byte| {
        const result = receiver.feed(@as(*const [1]u8, &byte));
        try std.testing.expect(result.consumed <= 1);
        switch (result.event) {
            .data => |data| {
                try std.testing.expectEqual(
                    body_runtime.Event.need_more,
                    (try body_runtime.appendMultipartChunk(
                        App,
                        &harness.storage,
                        request,
                        data,
                    )).event,
                );
            },
            .ready => ready = receiver.trailers(),
            .need_more => {},
            .rejected => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(@as(u32, 0), harness.storage.requests[request].body.used);
    }
    const result = try body_runtime.finishMultipartChunked(
        App,
        &harness.storage,
        request,
        ready orelse return error.TestUnexpectedResult,
    );
    try expectPrepared(&harness, request, result);
}

test "gzip fixed multipart streams decoded bytes and finishes after encoded input" {
    var harness = Harness{};
    try harness.init();
    const request = try harness.begin(false);
    setGzipLease(&harness, request);
    try body_runtime.startMultipartGzipFixed(
        App,
        &harness.storage,
        request,
        try fixedReceiver(gzip_wire.len),
        boundary,
    );

    for (body) |byte| {
        try std.testing.expectEqual(
            body_runtime.Event.need_more,
            (try body_runtime.appendMultipartChunk(
                App,
                &harness.storage,
                request,
                @as(*const [1]u8, &byte),
            )).event,
        );
        try std.testing.expectEqual(
            @as(u32, 0),
            harness.storage.requests[request].body.used,
        );
    }
    try completeEncoded(&harness, request);
    harness.storage.requests[request].gzip_lease = null;
    const result = try body_runtime.finishMultipartGzipFixed(
        App,
        &harness.storage,
        request,
    );
    try expectPrepared(&harness, request, result);
}

test "gzip fixed multipart start rejects invalid state" {
    const Case = enum { missing_lease, used, progressed, multipart };
    for (std.enums.values(Case)) |case| {
        var harness = Harness{};
        try harness.init();
        const request = try harness.begin(false);
        var receiver = try fixedReceiver(gzip_wire.len);
        if (case != .missing_lease) setGzipLease(&harness, request);
        switch (case) {
            .missing_lease => {},
            .used => harness.storage.requests[request].body.used = 1,
            .progressed => _ = try receiver.feed(gzip_wire[0..1]),
            .multipart => harness.storage.requests[request].body.multipart = true,
        }
        try std.testing.expectError(
            error.StateInvariant,
            body_runtime.startMultipartGzipFixed(
                App,
                &harness.storage,
                request,
                receiver,
                boundary,
            ),
        );
    }
}

test "gzip fixed multipart finish rejects invalid state" {
    const Case = enum { active_lease, incomplete, not_multipart };
    for (std.enums.values(Case)) |case| {
        var harness = Harness{};
        try harness.init();
        const request = try harness.begin(false);
        setGzipLease(&harness, request);
        try body_runtime.startMultipartGzipFixed(
            App,
            &harness.storage,
            request,
            try fixedReceiver(gzip_wire.len),
            boundary,
        );
        switch (case) {
            .active_lease => try completeEncoded(&harness, request),
            .incomplete => harness.storage.requests[request].gzip_lease = null,
            .not_multipart => {
                try completeEncoded(&harness, request);
                harness.storage.requests[request].gzip_lease = null;
                harness.storage.requests[request].body.multipart = false;
            },
        }
        try std.testing.expectError(
            error.StateInvariant,
            body_runtime.finishMultipartGzipFixed(
                App,
                &harness.storage,
                request,
            ),
        );
    }
}

fn fixedReceiver(expected: usize) !connection_body.FixedIdentity {
    return switch (connection_body.FixedIdentity.init(expected, 1024, 512)) {
        .accepted => |receiver| receiver,
        .over_limit => error.TestUnexpectedResult,
    };
}

fn setGzipLease(harness: *Harness, request: u16) void {
    harness.storage.requests[request].gzip_lease = .{
        .index = 0,
        .generation = 1,
    };
}

fn completeEncoded(harness: *Harness, request: u16) !void {
    const result = try harness.storage.requests[request].body.receiver.feed(gzip_wire);
    try std.testing.expect(result.complete);
    try std.testing.expectEqual(@as(usize, 0), result.tail.len);
}

fn expectPrepared(harness: *Harness, request: u16, result: body_runtime.FeedResult) !void {
    try std.testing.expectEqual(body_runtime.Event.prepared, result.event);
    try std.testing.expectEqual(@as(u16, 17), harness.state.count);
    try std.testing.expectEqual(@as(u8, 1), harness.state.fields);
    try std.testing.expectEqual(@as(u8, 1), harness.state.completions);
    try std.testing.expect(harness.state.trailers_empty);
    const used: usize = harness.storage.requests[request].response_used;
    const bytes = harness.storage.responseReadable(request)[0..used];
    try std.testing.expect(std.mem.endsWith(u8, bytes, "\r\n\r\nok"));
    _ = try App.complete(&harness.storage.requests[request].workspace);
}

fn input() application.Input {
    return .{
        .method = "POST",
        .path = "/upload",
        .raw_target = "/upload",
        .raw_path = "/upload",
        .date = fixed_date,
    };
}
