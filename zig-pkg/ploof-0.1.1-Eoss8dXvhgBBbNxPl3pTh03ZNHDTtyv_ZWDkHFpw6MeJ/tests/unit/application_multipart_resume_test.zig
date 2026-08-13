const std = @import("std");
const application = @import("../../src/application.zig");
const endpoint = @import("../../src/endpoint.zig");
const multipart = @import("../../src/multipart.zig");
const upload = @import("../../src/multipart/upload.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");

const AsyncFinishSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const Runtime = void;
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
            .start => .{ .done = {} },
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
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.UnexpectedCompletion,
        };
    }

    pub fn finish(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(upload.FinishInput),
    ) Error!upload.Poll(Summary) {
        return switch (event) {
            .start => .{ .request = .{ .sync = .{
                .file = upload.FileHandle.init(1),
            } } },
            .completion => |completion| switch (completion) {
                .success => |success| switch (success) {
                    .sync => .{ .done = {} },
                    else => error.UnexpectedCompletion,
                },
                .failure => error.UnexpectedCompletion,
            },
        };
    }

    pub fn commit(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return synchronous(event);
    }

    pub fn abort(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return synchronous(event);
    }

    fn synchronous(event: anytype) Error!upload.Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.UnexpectedCompletion,
        };
    }
};

const Body = @TypeOf(multipart.decode(.{
    .upload = multipart.file(AsyncFinishSink, multipart.required),
}, .{ .limits = .{
    .encoded_wire_bytes_max = 1_024,
    .total_body_bytes_max = 1_024,
    .file_bytes_max = 256,
    .field_bytes_max = 128,
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
const Context = application.Context(void, response.standard_head_limits);

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
        return multipart.commit(context.textStatic(.ok, "done"));
    }
};

const App = application.Application(.{
    .State = void,
    .routes = .{route.post("/async-upload", Definition.handle(Consumer{}))},
});

const wire = "--B\r\n" ++
    "Content-Disposition: form-data; name=upload; filename=x\r\n" ++
    "Content-Type: application/octet-stream\r\n\r\n" ++
    "data\r\n--B--";

test "async file-end resume marks multipart complete before body preparation" {
    const workspace_bytes: usize = @intCast(App.body_workspace_bytes_max);
    var state: void = {};
    var workspace = App.Workspace{};
    var registry = App.UploadRegistry{};
    var request_workspace: [workspace_bytes]u8 align(App.body_workspace_alignment) = undefined;
    var output: [512]u8 = undefined;
    var gzip = App.ResponseGzipWorkspace{};
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var plan = App.plan(requestInput(), &route_workspace);
    try App.__refinePlanBody(
        &plan,
        plan.body.selectMedia(0) orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqual(@as(usize, 1), App.upload_route_profiles.len);
    try std.testing.expectEqual(@as(u16, 0), App.upload_route_profiles[0].route_id);
    try std.testing.expectEqual(
        @as(u8, @intCast(App.upload_window_max)),
        App.upload_route_profiles[0].window,
    );
    try std.testing.expectError(
        error.InvariantViolation,
        App.__multipartUploadRouteId(&workspace),
    );
    const started = try registry.driver(AsyncFinishSink).startRuntime(.{
        .worker_index = 0,
        .entropy = &([_]u8{0xa5} ** 32),
    });
    if (started != .done) return error.TestUnexpectedResult;
    const head = try App.prepareHeadPlannedIn(
        &state,
        &workspace,
        &request_workspace,
        &output,
        &plan,
        .{},
    );
    if (head != .receive_body) return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(u16, 0),
        try App.__multipartUploadRouteId(&workspace),
    );
    try App.__beginMultipart(&workspace, &request_workspace, "B", &registry);
    try std.testing.expect(!App.__multipartParserFinished(&workspace));
    try std.testing.expectEqual(
        @as(u16, 0),
        try App.__multipartUploadRouteId(&workspace),
    );
    const fed = try App.__feedMultipartProgress(&workspace, &request_workspace, wire);
    try std.testing.expectEqual(wire.len, fed.consumed);
    try std.testing.expectEqual(.ready, fed.flow);
    try std.testing.expectEqual(
        .paused,
        (try App.__finishMultipartProgress(&workspace, &request_workspace)).flow,
    );
    const submission = (try App.__peekUploadSubmission(
        &workspace,
        &request_workspace,
    )).?;
    try std.testing.expect(submission.lane == .lifecycle);
    try App.__markUploadSubmitted(&workspace, &request_workspace, submission.lane);
    try App.__completeUploadSubmission(
        &workspace,
        &request_workspace,
        submission.lane,
        .{ .success = .{ .sync = {} } },
    );
    try std.testing.expect(!App.__multipartParserFinished(&workspace));
    const resumed = try App.__resumeMultipart(&workspace, &request_workspace);
    try std.testing.expectEqual(.complete, resumed.flow);
    try std.testing.expect(App.__multipartParserFinished(&workspace));
    const prepared = try App.__prepareBodyWithResponseGzip(
        &workspace,
        .none,
        .{},
        &request_workspace,
        [_]u8{0} ** 16,
        &output,
        &gzip,
    );
    try std.testing.expectEqual(response.Status.ok, prepared.status);
    try std.testing.expect(std.mem.endsWith(u8, prepared.bytes, "\r\n\r\ndone"));
    try std.testing.expectEqual(
        .complete,
        try App.__startMultipartFinalization(&workspace, &request_workspace),
    );
    try std.testing.expectEqual(
        .committed,
        (try App.__multipartFinalizationOutcome(&workspace, &request_workspace)).?,
    );
    const stopped = try registry.driver(AsyncFinishSink).startStop();
    if (stopped != .done) return error.TestUnexpectedResult;
}

fn requestInput() application.Input {
    return .{
        .method = "POST",
        .path = "/async-upload",
        .raw_target = "/async-upload",
        .raw_path = "/async-upload",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
    };
}
