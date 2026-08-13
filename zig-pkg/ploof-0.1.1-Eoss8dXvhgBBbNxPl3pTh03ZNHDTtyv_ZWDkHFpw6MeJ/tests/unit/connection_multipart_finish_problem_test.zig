const std = @import("std");

const application = @import("../../src/application.zig");
const application_types = @import("../../src/internal/application/types.zig");
const body_runtime = @import("../../src/internal/runtime/connection/body_runtime.zig");
const chunked_body = @import("../../src/internal/runtime/connection/chunked_body.zig");
const connection_body = @import("../../src/internal/runtime/connection/body.zig");
const config = @import("../../src/internal/runtime/config.zig");
const endpoint = @import("../../src/endpoint.zig");
const gzip_encoder = @import("../../src/internal/runtime/gzip/encoder.zig");
const multipart = @import("../../src/multipart.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const upload_finalizer = @import("../../src/internal/upload/finalizer.zig");
const upload = @import("../../src/multipart/upload.zig");
const worker_storage = @import("../../src/internal/runtime/worker/storage.zig");

const Source = enum(u8) {
    none,
    parser,
    application,
    rejection,
    sink,
    fatal,
};

const Flow = enum(u8) {
    progress,
    paused,
    complete,
};

const Progress = struct {
    consumed: usize,
    flow: enum(u8) { ready, paused, complete },
};

const Report = struct {
    const Primary = struct {
        class: union(enum) {
            upstream: upload_finalizer.UpstreamFailure,
            sink: void,
        },
    };

    cleanup_failure_count: u16 = 0,
    outcome: enum(u8) { failed } = .failed,
    primary: ?Primary = null,

    pub fn responseAllowed(_: Report) bool {
        return true;
    }
};

const TestApp = struct {
    pub const upload_async_sink_present = true;
    pub const upload_request_handles_max: u32 = 1;
    pub const upload_window_max: u32 = 1;

    pub const Workspace = struct {
        source: Source = .none,
        multipart_finalization: application_types.MultipartFinalization = .required,
        parser_finished: bool = false,
        prepared: u8 = 0,
        finalized: u8 = 0,
    };

    pub fn __multipartParserFinished(workspace: *const Workspace) bool {
        return workspace.parser_finished;
    }

    pub fn __finishMultipartProgress(
        workspace: *Workspace,
        _: []u8,
    ) error{ Denied, FileRejected, UploadFailure, InvariantViolation }!Progress {
        return switch (workspace.source) {
            .application => error.Denied,
            .rejection => error.FileRejected,
            .sink => error.UploadFailure,
            .fatal => error.InvariantViolation,
            .none, .parser => error.InvariantViolation,
        };
    }

    pub fn __multipartTerminalSource(
        workspace: *Workspace,
        _: []u8,
    ) error{}!Source {
        return workspace.source;
    }

    pub fn __prepareBodyWithResponseGzip(
        workspace: *Workspace,
        _: anytype,
        _: anytype,
        _: []u8,
        _: [16]u8,
        output: []u8,
        _: anytype,
    ) error{}!Prepared {
        const bytes = "selected";
        @memcpy(output[0..bytes.len], bytes);
        workspace.prepared += 1;
        return .{ .bytes = output[0..bytes.len], .close_connection = false };
    }

    pub fn __startMultipartFinalization(
        workspace: *Workspace,
        _: []u8,
    ) error{}!Flow {
        workspace.finalized += 1;
        workspace.multipart_finalization = if (workspace.source == .sink)
            .failed
        else
            .aborted;
        return .complete;
    }

    pub fn __multipartFinalizationFlow(_: *Workspace, _: []u8) error{}!Flow {
        return .complete;
    }

    pub fn __multipartFinalizationReport(_: *Workspace, _: []u8) error{}!?Report {
        return Report{};
    }

    const Prepared = struct {
        bytes: []const u8,
        close_connection: bool,
    };
};

const SyncTestApp = struct {
    pub const upload_request_handles_max: u32 = 1;
    pub const upload_window_max: u32 = 1;
    pub const Workspace = TestApp.Workspace;

    pub fn __feedMultipart(
        _: *Workspace,
        _: []u8,
        _: []const u8,
    ) error{FileRejected}!void {
        return error.FileRejected;
    }

    pub fn __finishMultipart(_: *Workspace, _: []u8) error{FileRejected}!void {
        return error.FileRejected;
    }

    pub fn __multipartTerminalSource(
        workspace: *Workspace,
        request_workspace: []u8,
    ) error{}!Source {
        return TestApp.__multipartTerminalSource(workspace, request_workspace);
    }

    pub fn __prepareBodyWithResponseGzip(
        workspace: *Workspace,
        decoded: anytype,
        trailers: anytype,
        request_workspace: []u8,
        hash_key: [16]u8,
        output: []u8,
        gzip: anytype,
    ) error{}!TestApp.Prepared {
        return TestApp.__prepareBodyWithResponseGzip(
            workspace,
            decoded,
            trailers,
            request_workspace,
            hash_key,
            output,
            gzip,
        );
    }

    pub fn __startMultipartFinalization(
        workspace: *Workspace,
        request_workspace: []u8,
    ) error{}!Flow {
        return TestApp.__startMultipartFinalization(workspace, request_workspace);
    }

    pub fn __multipartFinalizationFlow(
        workspace: *Workspace,
        request_workspace: []u8,
    ) error{}!Flow {
        return TestApp.__multipartFinalizationFlow(workspace, request_workspace);
    }

    pub fn __multipartFinalizationReport(
        workspace: *Workspace,
        request_workspace: []u8,
    ) error{}!?Report {
        return TestApp.__multipartFinalizationReport(workspace, request_workspace);
    }
};

const Request = struct {
    body: struct {
        receiver: connection_body.FixedIdentity,
        multipart: bool = true,
    },
    workspace: TestApp.Workspace,
    flags: struct {
        upload_finalizing: bool = false,
        upload_response_failed: bool = false,
    } = .{},
};

const EmptyChunked = struct {
    const bytes: []const u8 = "";
    const fields: []const @import("../../src/internal/http1/request_head.zig").Field = &.{};

    pub fn trailers(_: *const EmptyChunked) ?chunked_body.ReadyTrailers {
        return .{ .bytes = bytes, .fields = fields };
    }
};

const TestStorage = struct {
    pub const body_workspace_bytes_per_slot: u32 = 1;

    requests: [1]Request,
    body_workspace: [1]u8 = .{0},
    response: [32]u8 = @splat(0),
    response_used: usize = 0,
    chunked: EmptyChunked = .{},
    response_gzip_workspace: u8 = 0,
    json_hash_key: [16]u8 = @splat(0),

    fn init(source: Source) TestStorage {
        return .{ .requests = .{.{
            .body = .{ .receiver = fixedComplete() },
            .workspace = .{ .source = source },
        }} };
    }

    pub fn bodyWorkspace(self: *TestStorage, _: u16) error{}![]u8 {
        return &self.body_workspace;
    }

    pub fn responseWritable(self: *TestStorage, _: u16) []u8 {
        return &self.response;
    }

    pub fn commitResponse(self: *TestStorage, _: u16, bytes: []const u8) bool {
        if (bytes.len > self.response.len) return false;
        self.response_used = bytes.len;
        return true;
    }

    pub fn commitExternalResponse(_: *TestStorage, _: u16, _: []const u8) bool {
        return false;
    }

    pub fn clearResponse(self: *TestStorage, _: u16) void {
        self.response_used = 0;
    }

    pub fn chunkedState(self: *TestStorage, _: u16) error{}!*EmptyChunked {
        return &self.chunked;
    }
};

const Transport = enum(u8) { fixed, chunked };

test "synchronous multipart FileRejected selects terminal response while feeding" {
    var storage = TestStorage.init(.rejection);
    storage.requests[0].body.receiver = fixedReceiver(1);
    const fixed = try body_runtime.feedMultipartFixed(SyncTestApp, &storage, 0, "x");
    try expectSelected(&storage, fixed);

    storage = TestStorage.init(.rejection);
    const chunked = try body_runtime.appendMultipartChunk(SyncTestApp, &storage, 0, "x");
    try expectSelected(&storage, chunked);
}

test "synchronous multipart FileRejected selects terminal response at EOF" {
    var storage = TestStorage.init(.rejection);
    const result = try body_runtime.finishMultipartFixed(SyncTestApp, &storage, 0);
    try expectSelected(&storage, result);
}

test "fixed multipart EOF classifies every terminal source" {
    try runCases(.fixed);
}

test "chunked multipart EOF classifies every terminal source" {
    try runCases(.chunked);
}

test "completed async parser prepares without a second finish" {
    var storage = TestStorage.init(.fatal);
    storage.requests[0].workspace.parser_finished = true;
    const result = try body_runtime.finishMultipartFixed(TestApp, &storage, 0);
    try std.testing.expectEqual(body_runtime.Event.prepared, result.event);
    try std.testing.expectEqual(@as(u8, 1), storage.requests[0].workspace.prepared);
}

fn runCases(comptime transport: Transport) !void {
    const cases = [_]Source{ .application, .rejection, .sink, .fatal };
    for (cases) |source| {
        var storage = TestStorage.init(source);
        const result = if (transport == .fixed)
            body_runtime.finishMultipartFixed(TestApp, &storage, 0)
        else
            body_runtime.finishMultipartChunked(
                TestApp,
                &storage,
                0,
                storage.chunked.trailers().?,
            );
        try expectCase(source, &storage, result);
    }
}

fn expectCase(
    source: Source,
    storage: *TestStorage,
    result: body_runtime.Error!body_runtime.FeedResult,
) !void {
    switch (source) {
        .application, .rejection => {
            const prepared = try result;
            try std.testing.expectEqual(body_runtime.Event.prepared, prepared.event);
            try std.testing.expect(prepared.close_connection);
            try std.testing.expectEqual(@as(u8, 1), storage.requests[0].workspace.prepared);
            try std.testing.expectEqual(@as(usize, "selected".len), storage.response_used);
        },
        .sink => try std.testing.expectError(error.ApplicationFailure, result),
        .fatal => try std.testing.expectError(error.StateInvariant, result),
        .none, .parser => return error.TestUnexpectedResult,
    }
    const finalized: u8 = if (source == .fatal) 0 else 1;
    try std.testing.expectEqual(finalized, storage.requests[0].workspace.finalized);
}

fn expectSelected(storage: *TestStorage, result: body_runtime.FeedResult) !void {
    try std.testing.expectEqual(body_runtime.Event.prepared, result.event);
    try std.testing.expect(result.close_connection);
    try std.testing.expectEqual(@as(u8, 1), storage.requests[0].workspace.prepared);
    try std.testing.expectEqual(@as(usize, "selected".len), storage.response_used);
}

fn fixedComplete() connection_body.FixedIdentity {
    return switch (connection_body.FixedIdentity.init(0, 0, 0)) {
        .accepted => |receiver| receiver,
        .over_limit => unreachable,
    };
}

const SyncFinishSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const Runtime = void;
    pub const StartupState = void;
    pub const Error = error{ FinishFailed, UnexpectedCompletion };
    pub const io_requirements = upload.IoRequirements{ .sync = true };
    pub const request_handles_max: u8 = 1;
    pub const runtime_handles_max: u8 = 0;
    pub const initial_state: State = {};
    pub const initial_write_state: WriteState = {};
    pub const initial_startup_state: StartupState = {};

    pub fn runtimeStart(
        _: *StartupState,
        event: upload.PollEvent(upload.RuntimeStartInput),
    ) Error!upload.Poll(Runtime) {
        return complete(Runtime, event);
    }

    pub fn runtimeStop(_: *Runtime, event: upload.PollEvent(void)) Error!upload.Poll(void) {
        return complete(void, event);
    }

    pub fn begin(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(BeginInput),
    ) Error!upload.Poll(void) {
        return complete(void, event);
    }

    pub fn write(
        _: *Runtime,
        _: *State,
        _: *WriteState,
        event: upload.PollEvent(upload.WriteInput),
    ) Error!upload.Poll(void) {
        return complete(void, event);
    }

    pub fn finish(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(upload.FinishInput),
    ) Error!upload.Poll(Summary) {
        return switch (event) {
            .start => error.FinishFailed,
            .completion => error.UnexpectedCompletion,
        };
    }

    pub fn commit(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return complete(void, event);
    }

    pub fn abort(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return complete(void, event);
    }

    fn complete(comptime Value: type, event: anytype) Error!upload.Poll(Value) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.UnexpectedCompletion,
        };
    }
};

const sink_boundary = "E";
const sink_wire = "--E\r\n" ++
    "Content-Disposition: form-data; name=upload; filename=x\r\n" ++
    "Content-Type: application/octet-stream\r\n\r\n" ++
    "data\r\n--E--";
const SinkBody = multipart.decode(.{
    .upload = multipart.file(SyncFinishSink, multipart.required),
}, .{ .limits = multipart.Limits.validate(.{
    .encoded_wire_bytes_max = 1024,
    .total_body_bytes_max = 512,
    .file_bytes_max = 64,
    .field_bytes_max = 16,
    .parts_max = 1,
    .files_max = 1,
    .part_headers_max = 2,
    .part_header_bytes_max = 192,
    .disposition_parameters_max = 3,
    .delimiter_transport_padding_bytes_max = 8,
    .name_bytes_max = 16,
    .filename_bytes_max = 16,
    .boundary_bytes_max = 8,
}) });
const SinkSpec = @TypeOf(SinkBody);
const SinkDefinition = endpoint.Endpoint(.{ .body = SinkBody });
const SinkContext = application.Context(void, response.standard_head_limits);

const SinkConsumer = struct {
    pub const State = void;

    pub fn init(_: SinkConsumer, _: *SinkContext) State {}

    pub fn fileStart(
        _: SinkConsumer,
        _: *SinkContext,
        _: *State,
        _: SinkSpec.FileStart,
    ) SinkSpec.FileAdmission(SinkContext.ResponseType) {
        return .{ .accept = .{ .upload = {} } };
    }

    pub fn complete(
        _: SinkConsumer,
        context: *SinkContext,
        _: *State,
        _: SinkDefinition.InputType,
        _: SinkSpec.Summaries,
    ) multipart.Decision(SinkContext.ResponseType) {
        return multipart.commit(context.textStatic(.ok, "unreachable"));
    }
};

const SinkApp = application.Application(.{
    .State = void,
    .routes = .{route.post("/sink", SinkDefinition.handle(SinkConsumer{}))},
});
const sink_response_bytes: u32 = response.standard_head_limits.head_bytes_max +
    @as(u32, @intCast(gzip_encoder.bound("unreachable".len) catch unreachable));
const sink_limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .body_workspace_slots = 1,
    .chunked_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 256,
    .pipeline_bytes_per_connection = 256,
    .response_bytes_per_request = sink_response_bytes,
    .submission_entries = 8,
    .completion_entries = 16,
});
const SinkStorage = worker_storage.Storage(SinkApp, sink_limits);

const SinkHarness = struct {
    slab: [SinkStorage.required_bytes]u8 align(SinkStorage.slab_alignment) = undefined,
    storage: SinkStorage = undefined,
    state: void = {},
    request: u16 = 0,

    fn init(self: *SinkHarness, chunked: bool) !void {
        try self.storage.init(&self.slab);
        const started = try self.storage.upload_registry.driver(SyncFinishSink).startRuntime(.{
            .worker_index = 0,
            .entropy = &([_]u8{0xa5} ** 32),
        });
        if (started != .done) return error.TestUnexpectedResult;
        const connection = self.storage.acquireConnection(.{ .value = 1 }) orelse
            return error.TestUnexpectedResult;
        self.request = try self.beginRequest(connection, chunked);
    }

    fn beginRequest(self: *SinkHarness, connection: u16, chunked: bool) !u16 {
        var planned = SinkApp.plan(sinkInput(), &self.storage.route_search_workspace);
        try SinkApp.__refinePlanBody(
            &planned,
            planned.body.selectMedia(0) orelse return error.TestUnexpectedResult,
        );
        const acquired = self.storage.acquireRequestClassified(
            connection,
            planned.body.headWorkspaceClass(),
            chunked,
        );
        const request = switch (acquired) {
            .acquired => |index| index,
            else => return error.TestUnexpectedResult,
        };
        const prepared = try SinkApp.prepareHeadPlannedIn(
            &self.state,
            &self.storage.requests[request].workspace,
            try self.storage.bodyWorkspace(request),
            self.storage.responseWritable(request),
            &planned,
            .{},
        );
        if (prepared != .receive_body) return error.TestUnexpectedResult;
        return request;
    }

    fn stop(self: *SinkHarness) !void {
        const stopped = try self.storage.upload_registry.driver(SyncFinishSink).startStop();
        if (stopped != .done) return error.TestUnexpectedResult;
    }
};

test "fixed EOF synchronous sink failure completes abort cleanup" {
    var harness = SinkHarness{};
    try harness.init(false);
    try body_runtime.startMultipartFixed(
        SinkApp,
        &harness.storage,
        harness.request,
        fixedReceiver(sink_wire.len),
        sink_boundary,
    );
    try std.testing.expectError(
        error.ApplicationFailure,
        body_runtime.feedMultipartFixed(
            SinkApp,
            &harness.storage,
            harness.request,
            sink_wire,
        ),
    );
    try expectSinkCleanup(&harness);
    try harness.stop();
}

test "chunked EOF synchronous sink failure completes abort cleanup" {
    var harness = SinkHarness{};
    try harness.init(true);
    const receiver = try harness.storage.chunkedState(harness.request);
    receiver.* = chunked_body.State.init(1024, 512, .{}, "");
    try body_runtime.startMultipartChunked(
        SinkApp,
        &harness.storage,
        harness.request,
        sink_boundary,
    );
    const ready = try feedChunked(&harness, receiver);
    try std.testing.expectError(
        error.ApplicationFailure,
        body_runtime.finishMultipartChunked(
            SinkApp,
            &harness.storage,
            harness.request,
            ready,
        ),
    );
    try expectSinkCleanup(&harness);
    try harness.stop();
}

fn feedChunked(
    harness: *SinkHarness,
    receiver: *chunked_body.State,
) !chunked_body.ReadyTrailers {
    var wire_storage: [sink_wire.len + 32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&wire_storage);
    try writer.print("{x}\r\n{s}\r\n0\r\n\r\n", .{ sink_wire.len, sink_wire });
    const wire = writer.buffered();
    var offset: usize = 0;
    while (offset < wire.len) {
        const result = receiver.feed(wire[offset..]);
        if (result.consumed == 0) return error.TestUnexpectedResult;
        offset += result.consumed;
        switch (result.event) {
            .data => |data| {
                const progress = try body_runtime.appendMultipartProgress(
                    SinkApp,
                    &harness.storage,
                    harness.request,
                    data,
                );
                if (progress.event != .need_more) return error.TestUnexpectedResult;
            },
            .ready => return receiver.trailers() orelse error.TestUnexpectedResult,
            .need_more => {},
            .rejected => return error.TestUnexpectedResult,
        }
    }
    return error.TestUnexpectedResult;
}

fn expectSinkCleanup(harness: *SinkHarness) !void {
    const workspace = &harness.storage.requests[harness.request].workspace;
    try std.testing.expectEqual(
        application_types.MultipartFinalization.failed,
        workspace.multipart_finalization,
    );
    try std.testing.expect(!harness.storage.requests[harness.request].flags.upload_finalizing);
}

fn fixedReceiver(expected: usize) connection_body.FixedIdentity {
    return switch (connection_body.FixedIdentity.init(expected, 1024, 512)) {
        .accepted => |receiver| receiver,
        .over_limit => unreachable,
    };
}

fn sinkInput() application.Input {
    return .{
        .method = "POST",
        .path = "/sink",
        .raw_target = "/sink",
        .raw_path = "/sink",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
    };
}
