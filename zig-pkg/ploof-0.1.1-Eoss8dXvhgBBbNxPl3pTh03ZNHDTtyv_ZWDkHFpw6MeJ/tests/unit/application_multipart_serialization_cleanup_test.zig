const std = @import("std");
const application = @import("../../src/application.zig");
const endpoint = @import("../../src/endpoint.zig");
const multipart = @import("../../src/multipart.zig");
const upload = @import("../../src/multipart/upload.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");

const AsyncAbortSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const Runtime = struct {
        abort_starts: u8 = 0,
        abort_completions: u8 = 0,
    };
    pub const StartupState = void;
    pub const Error = error{UnexpectedCompletion};
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
        return switch (event) {
            .start => .{ .done = .{} },
            .completion => error.UnexpectedCompletion,
        };
    }

    pub fn runtimeStop(
        _: *Runtime,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return synchronous(event);
    }

    pub fn begin(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(BeginInput),
    ) Error!upload.Poll(void) {
        return synchronous(event);
    }

    pub fn write(
        _: *Runtime,
        _: *State,
        _: *WriteState,
        event: upload.PollEvent(upload.WriteInput),
    ) Error!upload.Poll(void) {
        return synchronous(event);
    }

    pub fn finish(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(upload.FinishInput),
    ) Error!upload.Poll(Summary) {
        return synchronous(event);
    }

    pub fn commit(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return synchronous(event);
    }

    pub fn abort(
        runtime: *Runtime,
        _: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return switch (event) {
            .start => {
                runtime.abort_starts += 1;
                return .{ .request = .{ .sync = .{
                    .file = upload.FileHandle.init(1),
                } } };
            },
            .completion => |completion| {
                if (completion != .success or completion.success != .sync) {
                    return error.UnexpectedCompletion;
                }
                runtime.abort_completions += 1;
                return .{ .done = {} };
            },
        };
    }

    fn synchronous(event: anytype) Error!upload.Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.UnexpectedCompletion,
        };
    }
};

const Body = @TypeOf(multipart.decode(.{
    .upload = multipart.file(AsyncAbortSink, multipart.required),
}, .{ .limits = .{
    .encoded_wire_bytes_max = 1_024,
    .total_body_bytes_max = 1_024,
    .file_bytes_max = 256,
    .field_bytes_max = 64,
    .parts_max = 1,
    .files_max = 1,
    .part_headers_max = 2,
    .part_header_bytes_max = 256,
    .disposition_parameters_max = 4,
    .delimiter_transport_padding_bytes_max = 8,
    .name_bytes_max = 16,
    .filename_bytes_max = 16,
    .boundary_bytes_max = 8,
} }));
const Spec = Body;
const Definition = endpoint.Endpoint(.{ .body = Body{} });

const AppState = struct {
    after_calls: u8 = 0,
    last_outcome: ?application.Outcome = null,
};
const Context = application.Context(AppState, response.standard_head_limits);

const Consumer = struct {
    pub const State = void;

    pub fn init(_: Consumer, _: *Context) State {}

    pub fn fileStart(
        _: Consumer,
        _: *Context,
        _: *State,
        _: Spec.FileStart,
    ) Spec.FileAdmission(Context.ResponseType) {
        return .{ .accept = .{ .upload = {} } };
    }

    pub fn complete(
        _: Consumer,
        context: *Context,
        _: *State,
        _: Definition.InputType,
        _: Spec.Summaries,
    ) multipart.Decision(Context.ResponseType) {
        return multipart.commit(context.textStatic(.ok, "response-body"));
    }
};

const Observe = struct {
    pub const State = void;

    pub fn after(
        _: Observe,
        context: *const Context,
        _: *State,
        outcome: application.Outcome,
    ) void {
        context.state.after_calls += 1;
        context.state.last_outcome = outcome;
    }
};

const App = application.Application(.{
    .State = AppState,
    .routes = .{route.configured(
        .post,
        "/upload",
        Definition.handle(Consumer{}),
        .{Observe{}},
        null,
    )},
});

const request_workspace_bytes: usize = @intCast(App.body_workspace_bytes_max);
const wire = "--B\r\n" ++
    "Content-Disposition: form-data; name=upload; filename=x\r\n" ++
    "Content-Type: application/octet-stream\r\n\r\n" ++
    "data\r\n--B--";

test "serialization failure retains async multipart abort until its CQE" {
    var state = AppState{};
    var workspace = App.Workspace{};
    var registry = App.UploadRegistry{};
    var request_workspace: [request_workspace_bytes]u8 align(App.body_workspace_alignment) =
        undefined;
    var output: [1]u8 = undefined;
    var gzip = App.ResponseGzipWorkspace{};
    const driver = registry.driver(AsyncAbortSink);
    const started = try driver.startRuntime(.{
        .worker_index = 0,
        .entropy = &([_]u8{0xa5} ** 32),
    });
    if (started != .done) return error.TestUnexpectedResult;
    defer {
        const stopped = driver.startStop() catch unreachable;
        std.debug.assert(stopped == .done);
    }

    try beginRequest(&state, &workspace, &request_workspace, &output);
    try App.__beginMultipart(&workspace, &request_workspace, "B", &registry);
    try App.__feedMultipart(&workspace, &request_workspace, wire);
    try App.__finishMultipart(&workspace, &request_workspace);
    try std.testing.expectError(error.OutputTooSmall, App.__prepareBodyWithResponseGzip(
        &workspace,
        .none,
        .{},
        &request_workspace,
        [_]u8{0} ** 16,
        &output,
        &gzip,
    ));

    const runtime = registry.get(AsyncAbortSink).?;
    try std.testing.expectEqual(@as(u8, 0), state.after_calls);
    try std.testing.expectEqual(@as(u8, 0), runtime.abort_starts);
    try std.testing.expectError(error.NoPendingRequest, App.complete(&workspace));
    try std.testing.expectError(error.NoPendingRequest, App.abort(&workspace));
    try std.testing.expectError(
        error.RequestAlreadyPending,
        beginRequest(&state, &workspace, &request_workspace, &output),
    );

    try std.testing.expectEqual(
        .paused,
        try App.__startMultipartFinalization(&workspace, &request_workspace),
    );
    try std.testing.expectEqual(@as(u8, 1), runtime.abort_starts);
    try std.testing.expectEqual(@as(u8, 0), state.after_calls);
    const submission = (try App.__peekUploadSubmission(
        &workspace,
        &request_workspace,
    )).?;
    try std.testing.expectEqual(.lifecycle, submission.lane);
    try std.testing.expect(submission.request == .sync);
    try App.__markUploadSubmitted(&workspace, &request_workspace, submission.lane);
    try App.__completeUploadSubmission(
        &workspace,
        &request_workspace,
        submission.lane,
        .{ .success = .{ .sync = {} } },
    );
    try std.testing.expectEqual(
        .complete,
        try App.__multipartFinalizationFlow(&workspace, &request_workspace),
    );
    try std.testing.expectEqual(@as(u8, 1), runtime.abort_completions);
    try std.testing.expectEqual(
        .failed,
        (try App.__multipartFinalizationOutcome(&workspace, &request_workspace)).?,
    );
    try std.testing.expectEqual(@as(u8, 0), state.after_calls);

    const outcome = try App.abort(&workspace);
    try std.testing.expectEqual(application.TransportOutcome.aborted, outcome.transport);
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);
    try std.testing.expectEqual(outcome, state.last_outcome.?);

    try beginRequest(&state, &workspace, &request_workspace, &output);
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);
    _ = try App.abort(&workspace);
    try std.testing.expectEqual(@as(u8, 2), state.after_calls);
}

fn beginRequest(
    state: *AppState,
    workspace: *App.Workspace,
    request_workspace: []u8,
    output: []u8,
) !void {
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var plan = App.plan(requestInput(), &route_workspace);
    try App.__refinePlanBody(
        &plan,
        plan.body.selectMedia(0) orelse return error.TestUnexpectedResult,
    );
    const head = try App.prepareHeadPlannedIn(
        state,
        workspace,
        request_workspace,
        output,
        &plan,
        .{},
    );
    if (head != .receive_body) return error.TestUnexpectedResult;
}

fn requestInput() application.Input {
    return .{
        .method = "POST",
        .path = "/upload",
        .raw_target = "/upload",
        .raw_path = "/upload",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
    };
}
