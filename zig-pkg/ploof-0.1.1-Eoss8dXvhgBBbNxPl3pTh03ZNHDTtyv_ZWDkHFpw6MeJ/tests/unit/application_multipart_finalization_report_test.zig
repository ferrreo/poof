const std = @import("std");
const application = @import("../../src/application.zig");
const endpoint = @import("../../src/endpoint.zig");
const multipart = @import("../../src/multipart.zig");
const upload = @import("../../src/multipart/upload.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");

const SinkSupport = struct {
    pub const State = struct { ordinal: u16 = 0 };
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const Runtime = struct {
        begins: u16 = 0,
        commit_attempts: u16 = 0,
        commit_completions: u16 = 0,
        abort_attempts: u16 = 0,
        abort_completions: u16 = 0,
    };
    pub const StartupState = void;
    pub const Error = error{ Rejected, UnexpectedCompletion };

    pub fn runtimeStart(
        _: *StartupState,
        event: upload.PollEvent(upload.RuntimeStartInput),
    ) Error!upload.Poll(Runtime) {
        return switch (event) {
            .start => .{ .done = .{} },
            .completion => error.UnexpectedCompletion,
        };
    }

    pub fn runtimeStop(_: *Runtime, event: upload.PollEvent(void)) Error!upload.Poll(void) {
        return synchronous(event);
    }

    pub fn begin(
        runtime: *Runtime,
        state: *State,
        event: upload.PollEvent(BeginInput),
    ) Error!upload.Poll(void) {
        return switch (event) {
            .start => done: {
                runtime.begins += 1;
                state.ordinal = runtime.begins;
                break :done .{ .done = {} };
            },
            .completion => error.UnexpectedCompletion,
        };
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
        runtime: *Runtime,
        event: upload.PollEvent(void),
        reject: bool,
    ) Error!upload.Poll(void) {
        return switch (event) {
            .start => done: {
                runtime.commit_attempts += 1;
                if (reject) return error.Rejected;
                runtime.commit_completions += 1;
                break :done .{ .done = {} };
            },
            .completion => error.UnexpectedCompletion,
        };
    }

    pub fn abort(
        runtime: *Runtime,
        state: *State,
        event: upload.PollEvent(void),
        reject_second: bool,
    ) Error!upload.Poll(void) {
        return switch (event) {
            .start => done: {
                runtime.abort_attempts += 1;
                if (reject_second and state.ordinal == 2) return error.Rejected;
                runtime.abort_completions += 1;
                break :done .{ .done = {} };
            },
            .completion => error.UnexpectedCompletion,
        };
    }

    fn synchronous(event: anytype) Error!upload.Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.UnexpectedCompletion,
        };
    }
};

fn Sink(comptime reject_commit: bool, comptime reject_second_abort: bool) type {
    return struct {
        pub const ploof_multipart_sink = true;
        pub const State = SinkSupport.State;
        pub const WriteState = SinkSupport.WriteState;
        pub const Summary = SinkSupport.Summary;
        pub const BeginInput = SinkSupport.BeginInput;
        pub const Runtime = SinkSupport.Runtime;
        pub const StartupState = SinkSupport.StartupState;
        pub const Error = SinkSupport.Error;
        pub const io_requirements = upload.IoRequirements.none;
        pub const request_handles_max: u8 = 0;
        pub const runtime_handles_max: u8 = 0;
        pub const initial_state: State = .{};
        pub const initial_write_state: WriteState = {};
        pub const initial_startup_state: StartupState = {};
        pub const runtimeStart = SinkSupport.runtimeStart;
        pub const runtimeStop = SinkSupport.runtimeStop;
        pub const begin = SinkSupport.begin;
        pub const write = SinkSupport.write;
        pub const finish = SinkSupport.finish;

        pub fn commit(
            runtime: *Runtime,
            _: *State,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            return SinkSupport.commit(runtime, event, reject_commit);
        }

        pub fn abort(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            return SinkSupport.abort(runtime, state, event, reject_second_abort);
        }
    };
}

const Alpha = Sink(false, true);
const Beta = Sink(true, false);
const limits = multipart.Limits{
    .encoded_wire_bytes_max = 1_024,
    .total_body_bytes_max = 1_024,
    .file_bytes_max = 256,
    .field_bytes_max = 64,
    .parts_max = 3,
    .files_max = 3,
    .part_headers_max = 2,
    .part_header_bytes_max = 256,
    .disposition_parameters_max = 4,
    .delimiter_transport_padding_bytes_max = 8,
    .name_bytes_max = 16,
    .filename_bytes_max = 16,
    .boundary_bytes_max = 8,
};
const Body = @TypeOf(multipart.decode(.{
    .alpha = multipart.file(Alpha, multipart.oneTo(2)),
    .beta = multipart.file(Beta, multipart.required),
}, .{ .limits = limits }));
const PrimerBody = @TypeOf(multipart.decode(.{
    .beta = multipart.file(Beta, multipart.required),
}, .{ .limits = limits }));
const LegacyBody = @TypeOf(multipart.decode(.{
    .token = multipart.field([]const u8, multipart.required),
}, .{ .limits = limits }));
const Spec = Body;
const Definition = endpoint.Endpoint(.{ .body = Body{} });
const PrimerSpec = PrimerBody;
const PrimerDefinition = endpoint.Endpoint(.{ .body = PrimerBody{} });
const LegacySpec = LegacyBody;
const LegacyDefinition = endpoint.Endpoint(.{ .body = LegacyBody{} });
const Context = application.Context(void, response.standard_head_limits);

const Consumer = struct {
    pub const State = void;

    pub fn init(_: Consumer, _: *Context) State {}

    pub fn fileStart(
        _: Consumer,
        _: *Context,
        _: *State,
        event: Spec.FileStart,
    ) Spec.FileAdmission(Context.ResponseType) {
        return switch (event) {
            .alpha => .{ .accept = .{ .alpha = {} } },
            .beta => .{ .accept = .{ .beta = {} } },
        };
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

const PrimerConsumer = struct {
    pub const State = void;

    pub fn init(_: PrimerConsumer, _: *Context) State {}

    pub fn fileStart(
        _: PrimerConsumer,
        _: *Context,
        _: *State,
        _: PrimerSpec.FileStart,
    ) PrimerSpec.FileAdmission(Context.ResponseType) {
        return .{ .accept = .{ .beta = {} } };
    }

    pub fn complete(
        _: PrimerConsumer,
        context: *Context,
        _: *State,
        _: PrimerDefinition.InputType,
        _: PrimerSpec.Summaries,
    ) multipart.Decision(Context.ResponseType) {
        return multipart.commit(context.empty(.no_content));
    }
};

const LegacyConsumer = struct {
    pub const State = void;

    pub fn init(_: LegacyConsumer, _: *Context) State {}

    pub fn field(_: LegacyConsumer, _: *State, _: LegacySpec.Field) void {}

    pub fn complete(
        _: LegacyConsumer,
        context: *Context,
        _: *State,
        _: LegacyDefinition.InputType,
        _: LegacySpec.Summaries,
    ) multipart.Decision(Context.ResponseType) {
        return multipart.commit(context.empty(.no_content));
    }
};

const App = application.Application(.{
    .State = void,
    .routes = .{
        route.post("/primer", PrimerDefinition.handle(PrimerConsumer{})),
        route.post("/legacy", LegacyDefinition.handle(LegacyConsumer{})),
        route.post("/upload", Definition.handle(Consumer{})),
    },
});

const request_workspace_bytes: usize = @intCast(App.body_workspace_bytes_max);
const wire = "--B\r\n" ++
    "Content-Disposition: form-data; name=alpha; filename=a1\r\n\r\n" ++
    "a\r\n--B\r\n" ++
    "Content-Disposition: form-data; name=beta; filename=b1\r\n\r\n" ++
    "b\r\n--B\r\n" ++
    "Content-Disposition: form-data; name=alpha; filename=a2\r\n\r\n" ++
    "c\r\n--B--";
const legacy_wire = "--B\r\n" ++
    "Content-Disposition: form-data; name=token\r\n\r\n" ++
    "csrf\r\n--B--";

test "Application normalizes interleaved multipart finalization reports" {
    var state: void = {};
    var workspace = App.Workspace{};
    var registry = App.UploadRegistry{};
    var request_workspace: [request_workspace_bytes]u8 align(App.body_workspace_alignment) =
        undefined;
    var output: [512]u8 = undefined;
    var gzip = App.ResponseGzipWorkspace{};
    try startSinks(&registry);
    defer stopSinks(&registry);
    try expectFilelessReport(&state, &registry);

    try prepareUpload(
        &state,
        &workspace,
        &registry,
        &request_workspace,
        &output,
        &gzip,
    );
    try std.testing.expectEqual(@as(u16, 3), App.upload_finalization_instances_max);
    try std.testing.expectEqual(@as(u16, 0), App.UploadRegistry.indexOf(Beta));
    try std.testing.expectEqual(@as(u16, 1), App.UploadRegistry.indexOf(Alpha));
    try std.testing.expect((try App.__multipartFinalizationReport(
        &workspace,
        &request_workspace,
    )) == null);
    try std.testing.expectError(
        error.InvariantViolation,
        App.__multipartFinalizationCleanupFailure(&workspace, &request_workspace, 0),
    );
    try std.testing.expect((try App.__peekUploadSubmission(
        &workspace,
        &request_workspace,
    )) == null);
    try std.testing.expectEqual(
        .complete,
        try App.__startMultipartFinalization(&workspace, &request_workspace),
    );
    try expectReport(&workspace, &request_workspace);
    try expectCleanupFailures(&workspace, &request_workspace);
    try expectRuntimeCounts(&registry);
}

fn expectFilelessReport(state: *void, registry: *App.UploadRegistry) !void {
    var workspace = App.Workspace{};
    var request_workspace: [request_workspace_bytes]u8 align(App.body_workspace_alignment) =
        undefined;
    var output: [512]u8 = undefined;
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var plan = App.plan(legacyRequestInput(), &route_workspace);
    try App.__refinePlanBody(
        &plan,
        plan.body.selectMedia(0) orelse return error.TestUnexpectedResult,
    );
    const head = try App.prepareHeadPlannedIn(
        state,
        &workspace,
        &request_workspace,
        &output,
        &plan,
        .{},
    );
    if (head != .receive_body) return error.TestUnexpectedResult;
    try App.__beginMultipart(&workspace, &request_workspace, "B", registry);
    try App.__feedMultipart(&workspace, &request_workspace, legacy_wire);
    try App.__finishMultipart(&workspace, &request_workspace);
    try std.testing.expect((try App.__multipartFinalizationReport(
        &workspace,
        &request_workspace,
    )) == null);
    try std.testing.expectError(
        error.InvariantViolation,
        App.__multipartFinalizationCleanupFailure(&workspace, &request_workspace, 0),
    );
}

fn prepareUpload(
    state: *void,
    workspace: *App.Workspace,
    registry: *App.UploadRegistry,
    request_workspace: []u8,
    output: []u8,
    gzip: *App.ResponseGzipWorkspace,
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
    try App.__beginMultipart(workspace, request_workspace, "B", registry);
    try App.__feedMultipart(workspace, request_workspace, wire);
    try App.__finishMultipart(workspace, request_workspace);
    const prepared = try App.__prepareBodyWithResponseGzip(
        workspace,
        .none,
        .{},
        request_workspace,
        [_]u8{0} ** 16,
        output,
        gzip,
    );
    try std.testing.expectEqual(response.Status.ok, prepared.status);
}

fn expectReport(workspace: *App.Workspace, request_workspace: []u8) !void {
    const report = (try App.__multipartFinalizationReport(
        workspace,
        request_workspace,
    )).?;
    try std.testing.expectEqual(App.MultipartFinalization.Outcome.failed, report.outcome);
    try std.testing.expectEqual(
        App.MultipartFinalization.Outcome.failed,
        (try App.__multipartFinalizationOutcome(workspace, request_workspace)).?,
    );
    try std.testing.expect(!report.responseAllowed());
    try std.testing.expect(report.primary.?.class == .sink);
    try std.testing.expectEqual(App.MultipartFinalization.Identity{
        .registry_index = App.UploadRegistry.indexOf(Beta),
        .instance_index = 1,
    }, report.primary.?.identity.?);
    try std.testing.expectEqual(@as(u16, 3), report.instance_count);
    try std.testing.expectEqual(@as(u32, 2), report.commit_attempted_count);
    try std.testing.expectEqual(@as(u32, 1), report.commit_completed_count);
    try std.testing.expectEqual(@as(u32, 3), report.abort_attempted_count);
    try std.testing.expectEqual(@as(u32, 2), report.abort_completed_count);
    try std.testing.expectEqual(@as(u32, 1), report.cleanup_failure_count);
}

fn expectCleanupFailures(workspace: *App.Workspace, request_workspace: []u8) !void {
    try std.testing.expect((try App.__multipartFinalizationCleanupFailure(
        workspace,
        request_workspace,
        0,
    )) == null);
    try std.testing.expect((try App.__multipartFinalizationCleanupFailure(
        workspace,
        request_workspace,
        1,
    )) == null);
    const failure = (try App.__multipartFinalizationCleanupFailure(
        workspace,
        request_workspace,
        2,
    )).?;
    try std.testing.expectEqual(App.MultipartFinalization.CleanupFailureClass.sink, failure.class);
    try std.testing.expectEqual(App.MultipartFinalization.Identity{
        .registry_index = App.UploadRegistry.indexOf(Alpha),
        .instance_index = 2,
    }, failure.identity);
    try std.testing.expectError(
        error.InvariantViolation,
        App.__multipartFinalizationCleanupFailure(workspace, request_workspace, 3),
    );
}

fn expectRuntimeCounts(registry: *App.UploadRegistry) !void {
    const alpha = registry.get(Alpha).?;
    const beta = registry.get(Beta).?;
    try std.testing.expectEqual(@as(u16, 2), alpha.begins);
    try std.testing.expectEqual(@as(u16, 1), alpha.commit_attempts);
    try std.testing.expectEqual(@as(u16, 1), alpha.commit_completions);
    try std.testing.expectEqual(@as(u16, 2), alpha.abort_attempts);
    try std.testing.expectEqual(@as(u16, 1), alpha.abort_completions);
    try std.testing.expectEqual(@as(u16, 1), beta.begins);
    try std.testing.expectEqual(@as(u16, 1), beta.commit_attempts);
    try std.testing.expectEqual(@as(u16, 0), beta.commit_completions);
    try std.testing.expectEqual(@as(u16, 1), beta.abort_attempts);
    try std.testing.expectEqual(@as(u16, 1), beta.abort_completions);
}

fn startSinks(registry: *App.UploadRegistry) !void {
    const input = upload.RuntimeStartInput{
        .worker_index = 0,
        .entropy = &([_]u8{0xa5} ** 32),
    };
    if (try registry.driver(Alpha).startRuntime(input) != .done) {
        return error.TestUnexpectedResult;
    }
    if (try registry.driver(Beta).startRuntime(input) != .done) {
        return error.TestUnexpectedResult;
    }
}

fn stopSinks(registry: *App.UploadRegistry) void {
    const beta = registry.driver(Beta).startStop() catch unreachable;
    std.debug.assert(beta == .done);
    const alpha = registry.driver(Alpha).startStop() catch unreachable;
    std.debug.assert(alpha == .done);
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

fn legacyRequestInput() application.Input {
    return .{
        .method = "POST",
        .path = "/legacy",
        .raw_target = "/legacy",
        .raw_path = "/legacy",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
    };
}
