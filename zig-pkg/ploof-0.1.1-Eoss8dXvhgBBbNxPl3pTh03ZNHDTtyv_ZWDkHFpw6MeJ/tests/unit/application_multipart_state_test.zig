const std = @import("std");
const application = @import("../../src/application.zig");
const endpoint = @import("../../src/endpoint.zig");
const multipart = @import("../../src/multipart.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const upload_finalizer = @import("../../src/internal/upload/finalizer.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const Upload = @TypeOf(multipart.decode(.{
    .age = multipart.field(u16, multipart.required),
    .token = multipart.bytesField(multipart.required),
    .upload = multipart.file(multipart.DiscardSink, multipart.required),
}, .{ .limits = .{
    .encoded_wire_bytes_max = 2_048,
    .total_body_bytes_max = 2_048,
    .file_bytes_max = 1_024,
    .field_bytes_max = 128,
    .parts_max = 3,
    .files_max = 1,
    .part_headers_max = 2,
    .part_header_bytes_max = 256,
    .disposition_parameters_max = 4,
    .delimiter_transport_padding_bytes_max = 8,
    .name_bytes_max = 16,
    .filename_bytes_max = 32,
    .boundary_bytes_max = 8,
} }));
const Definition = endpoint.Endpoint(.{
    .body = Upload{},
    .response_json_bytes_max = 32,
});
const AppError = error{ Denied, UploadFailure };

const AppState = struct {
    events: [16]u8 = undefined,
    events_len: usize = 0,
    state_valid: bool = false,
    decision_commit: bool = true,
    response_failure: bool = false,
    reject_file: bool = false,
    fail_file_start: bool = false,
    collide_file_start: bool = false,

    fn mark(self: *AppState, event: u8) void {
        self.events[self.events_len] = event;
        self.events_len += 1;
    }
};

const Context = application.Context(AppState, response.standard_head_limits);
const Response = Context.ResponseType;

const Consumer = struct {
    pub const State = struct {
        age: u16 = 0,
        token_valid: bool = false,
        alignment_canary: u8 align(64) = 0,
        app: *AppState,
    };

    pub fn init(_: Consumer, context: *Context) State {
        context.state.mark('I');
        return .{ .alignment_canary = 0xa5, .app = context.state };
    }

    pub fn field(_: Consumer, state: *State, value: Upload.Field) void {
        switch (value) {
            .age => |age| {
                state.age = age;
                state.app.mark('A');
            },
            .token => |token| {
                state.token_valid = std.mem.eql(u8, token, "csrf");
                state.app.mark('T');
            },
        }
    }

    pub fn fileStart(
        _: Consumer,
        context: *Context,
        _: *State,
        _: Upload.FileStart,
    ) AppError!Upload.FileAdmission(Response) {
        if (context.state.fail_file_start) return error.Denied;
        if (context.state.collide_file_start) return error.UploadFailure;
        if (context.state.reject_file) {
            return .{ .reject = context.textStatic(.unsupported_media_type, "rejected") };
        }
        return .{ .accept = .{ .upload = {} } };
    }

    pub fn complete(
        _: Consumer,
        context: *Context,
        state: *State,
        input: Definition.InputType,
        _: Upload.Summaries,
    ) multipart.Decision(Response) {
        context.state.mark('C');
        context.state.state_valid = state.age == 42 and
            state.token_valid and
            state.alignment_canary == 0xa5 and
            @sizeOf(@TypeOf(input.body)) == 0;
        const result = context.textStatic(.ok, "accepted");
        return if (state.app.decision_commit)
            multipart.commit(result)
        else
            multipart.abort(result);
    }
};

const Observe = struct {
    pub const State = void;

    pub fn head(_: Observe, context: *Context, _: *State) ?Response {
        context.state.mark('H');
        return null;
    }

    pub fn body(
        _: Observe,
        context: *Context,
        _: *State,
        _: Definition.InputType,
    ) ?Response {
        context.state.mark('B');
        return null;
    }

    pub fn response(
        _: Observe,
        context: *Context,
        _: *State,
        _: *Response,
    ) error{Denied}!void {
        context.state.mark('R');
        if (context.state.response_failure) return error.Denied;
    }

    pub fn after(
        _: Observe,
        context: *const Context,
        _: *State,
        _: application.Outcome,
    ) void {
        context.state.mark('Z');
    }
};

const handler = Definition.handle(Consumer{});

fn mapError(context: *Context, _: AppError) Response {
    return context.textStatic(.forbidden, "denied");
}

const App = application.Application(.{
    .State = AppState,
    .Error = AppError,
    .map_error = mapError,
    .routes = .{route.configured(
        .post,
        "/upload",
        handler,
        .{Observe{}},
        null,
    )},
});

const wire = "--B\r\n" ++
    "Content-Disposition: form-data; name=age\r\n\r\n" ++
    "42\r\n--B\r\n" ++
    "Content-Disposition: form-data; name=token\r\n\r\n" ++
    "csrf\r\n--B\r\n" ++
    "Content-Disposition: form-data; name=upload; filename=x\r\n" ++
    "Content-Type: application/octet-stream\r\n\r\n" ++
    "file-data\r\n--B--";

test "multipart state remains workspace-owned through the body pipeline" {
    const Begin = fn (
        *App.Workspace,
        []u8,
        []const u8,
        *App.UploadRegistry,
    ) (application.MultipartError || App.Error)!void;
    const Feed = fn (
        *App.Workspace,
        []u8,
        []const u8,
    ) (application.MultipartError || App.Error)!void;
    const Finish = fn (
        *App.Workspace,
        []u8,
    ) (application.MultipartError || App.Error)!void;
    try std.testing.expect(App.Context == Context);
    try std.testing.expect(!@hasField(Context, "__multipart_consumer"));
    // Context retains request-local CSRF state and fixed response-body storage bindings.
    try std.testing.expectEqual(@as(usize, 336), @sizeOf(Context));
    try std.testing.expect(@TypeOf(App.__beginMultipart) == Begin);
    try std.testing.expect(@TypeOf(App.__feedMultipart) == Feed);
    try std.testing.expect(@TypeOf(App.__finishMultipart) == Finish);

    const workspace_bytes: usize = @intCast(App.body_workspace_bytes_max);
    var state = AppState{};
    var workspace = App.Workspace{};
    var upload_registry = App.UploadRegistry{};
    var request_workspace: [workspace_bytes]u8 align(App.body_workspace_alignment) = undefined;
    var output: [512]u8 = undefined;
    var gzip = App.ResponseGzipWorkspace{};
    const input = requestInput();
    var plan = planInput(input);
    try App.__refinePlanBody(
        &plan,
        plan.body.selectMedia(0) orelse return error.TestUnexpectedResult,
    );

    const head = try App.prepareHeadPlannedIn(
        &state,
        &workspace,
        &request_workspace,
        &output,
        &plan,
        .{},
    );
    switch (head) {
        .receive_body => {},
        .prepared => return error.TestUnexpectedResult,
    }
    try App.__beginMultipart(&workspace, &request_workspace, "B", &upload_registry);
    for (wire) |byte| try App.__feedMultipart(
        &workspace,
        &request_workspace,
        (&byte)[0..1],
    );
    try App.__finishMultipart(&workspace, &request_workspace);
    try std.testing.expectEqual(
        App.MultipartTerminalSource.none,
        try App.__multipartTerminalSource(&workspace, &request_workspace),
    );
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
    try std.testing.expect(std.mem.endsWith(u8, prepared.bytes, "\r\n\r\naccepted"));
    try std.testing.expectError(
        error.UploadFinalizationPending,
        App.complete(&workspace),
    );
    try std.testing.expectError(
        error.UploadFinalizationPending,
        App.abort(&workspace),
    );
    try std.testing.expectEqualStrings("HIATBCR", state.events[0..state.events_len]);
    try std.testing.expectEqual(
        .complete,
        try App.__startMultipartFinalization(&workspace, &request_workspace),
    );
    try std.testing.expectEqual(
        .committed,
        (try App.__multipartFinalizationOutcome(&workspace, &request_workspace)).?,
    );
    try std.testing.expect(state.state_valid);
    try std.testing.expectEqualStrings("HIATBCR", state.events[0..state.events_len]);
    _ = try App.complete(&workspace);
    try std.testing.expectEqualStrings("HIATBCRZ", state.events[0..state.events_len]);
}

test "multipart decision and response failure select commit or abort" {
    try std.testing.expectEqual(.aborted, try finalizationCase(false, false));
    try std.testing.expectEqual(.aborted, try finalizationCase(true, true));
}

test "file admission rejection skips completion and aborts before response" {
    const workspace_bytes: usize = @intCast(App.body_workspace_bytes_max);
    var state = AppState{ .reject_file = true };
    var workspace = App.Workspace{};
    var upload_registry = App.UploadRegistry{};
    var request_workspace: [workspace_bytes]u8 align(App.body_workspace_alignment) = undefined;
    var output: [512]u8 = undefined;
    var gzip = App.ResponseGzipWorkspace{};
    const input = requestInput();
    var plan = planInput(input);
    try App.__refinePlanBody(
        &plan,
        plan.body.selectMedia(0) orelse return error.TestUnexpectedResult,
    );
    const head = try App.prepareHeadPlannedIn(
        &state,
        &workspace,
        &request_workspace,
        &output,
        &plan,
        .{},
    );
    switch (head) {
        .receive_body => {},
        .prepared => return error.TestUnexpectedResult,
    }
    try App.__beginMultipart(&workspace, &request_workspace, "B", &upload_registry);
    try std.testing.expectError(
        error.FileRejected,
        App.__feedMultipart(&workspace, &request_workspace, wire),
    );
    try std.testing.expectEqual(
        App.MultipartTerminalSource.rejection,
        try App.__multipartTerminalSource(&workspace, &request_workspace),
    );
    const rejection = (try App.__multipartRejection(
        &workspace,
        &request_workspace,
    )).?;
    try std.testing.expectEqual(response.Status.unsupported_media_type, rejection.status);
    const prepared = try App.__prepareBodyWithResponseGzip(
        &workspace,
        .none,
        .{},
        &request_workspace,
        [_]u8{0} ** 16,
        &output,
        &gzip,
    );
    try std.testing.expectEqual(response.Status.unsupported_media_type, prepared.status);
    try std.testing.expect(std.mem.endsWith(u8, prepared.bytes, "\r\n\r\nrejected"));
    try std.testing.expectEqual(
        .complete,
        try App.__startMultipartFinalization(&workspace, &request_workspace),
    );
    try std.testing.expectEqual(
        .aborted,
        (try App.__multipartFinalizationOutcome(&workspace, &request_workspace)).?,
    );
    try std.testing.expectEqualStrings("HIATR", state.events[0..state.events_len]);
}

test "file admission application error maps response then aborts" {
    const workspace_bytes: usize = @intCast(App.body_workspace_bytes_max);
    var state = AppState{ .fail_file_start = true };
    var workspace = App.Workspace{};
    var upload_registry = App.UploadRegistry{};
    var request_workspace: [workspace_bytes]u8 align(App.body_workspace_alignment) = undefined;
    var output: [512]u8 = undefined;
    var gzip = App.ResponseGzipWorkspace{};
    const input = requestInput();
    var plan = planInput(input);
    try App.__refinePlanBody(
        &plan,
        plan.body.selectMedia(0) orelse return error.TestUnexpectedResult,
    );
    const head = try App.prepareHeadPlannedIn(
        &state,
        &workspace,
        &request_workspace,
        &output,
        &plan,
        .{},
    );
    switch (head) {
        .receive_body => {},
        .prepared => return error.TestUnexpectedResult,
    }
    try App.__beginMultipart(&workspace, &request_workspace, "B", &upload_registry);
    try std.testing.expectError(
        error.Denied,
        App.__feedMultipart(&workspace, &request_workspace, wire),
    );
    try std.testing.expectEqual(
        App.MultipartTerminalSource.application,
        try App.__multipartTerminalSource(&workspace, &request_workspace),
    );
    try std.testing.expectEqual(
        error.Denied,
        (try App.__multipartApplicationFailure(&workspace, &request_workspace)).?,
    );
    const prepared = try App.__prepareBodyWithResponseGzip(
        &workspace,
        .none,
        .{},
        &request_workspace,
        [_]u8{0} ** 16,
        &output,
        &gzip,
    );
    try std.testing.expectEqual(response.Status.forbidden, prepared.status);
    try std.testing.expect(std.mem.endsWith(u8, prepared.bytes, "\r\n\r\ndenied"));
    try std.testing.expectEqual(
        .complete,
        try App.__startMultipartFinalization(&workspace, &request_workspace),
    );
    try std.testing.expectEqual(
        .aborted,
        (try App.__multipartFinalizationOutcome(&workspace, &request_workspace)).?,
    );
    try std.testing.expectEqualStrings("HIATR", state.events[0..state.events_len]);
}

test "file admission application error keeps provenance across a framework name collision" {
    const workspace_bytes: usize = @intCast(App.body_workspace_bytes_max);
    var state = AppState{ .collide_file_start = true };
    var workspace = App.Workspace{};
    var upload_registry = App.UploadRegistry{};
    var request_workspace: [workspace_bytes]u8 align(App.body_workspace_alignment) = undefined;
    var output: [512]u8 = undefined;
    var gzip = App.ResponseGzipWorkspace{};
    const input = requestInput();
    var plan = planInput(input);
    try App.__refinePlanBody(
        &plan,
        plan.body.selectMedia(0) orelse return error.TestUnexpectedResult,
    );
    const head = try App.prepareHeadPlannedIn(
        &state,
        &workspace,
        &request_workspace,
        &output,
        &plan,
        .{},
    );
    switch (head) {
        .receive_body => {},
        .prepared => return error.TestUnexpectedResult,
    }
    try App.__beginMultipart(&workspace, &request_workspace, "B", &upload_registry);
    try std.testing.expectError(
        error.UploadFailure,
        App.__feedMultipart(&workspace, &request_workspace, wire),
    );
    try std.testing.expectEqual(
        App.MultipartTerminalSource.application,
        try App.__multipartTerminalSource(&workspace, &request_workspace),
    );
    try std.testing.expectEqual(
        error.UploadFailure,
        (try App.__multipartApplicationFailure(&workspace, &request_workspace)).?,
    );
    const prepared = try App.__prepareBodyWithResponseGzip(
        &workspace,
        .none,
        .{},
        &request_workspace,
        [_]u8{0} ** 16,
        &output,
        &gzip,
    );
    try std.testing.expectEqual(response.Status.forbidden, prepared.status);
    try std.testing.expectEqual(
        .complete,
        try App.__startMultipartFinalization(&workspace, &request_workspace),
    );
    try std.testing.expectEqual(
        .aborted,
        (try App.__multipartFinalizationOutcome(&workspace, &request_workspace)).?,
    );
}

fn finalizationCase(commit: bool, response_failure: bool) !upload_finalizer.Outcome {
    const workspace_bytes: usize = @intCast(App.body_workspace_bytes_max);
    var state = AppState{
        .decision_commit = commit,
        .response_failure = response_failure,
    };
    var workspace = App.Workspace{};
    var upload_registry = App.UploadRegistry{};
    var request_workspace: [workspace_bytes]u8 align(App.body_workspace_alignment) = undefined;
    var output: [512]u8 = undefined;
    var gzip = App.ResponseGzipWorkspace{};
    const input = requestInput();
    var plan = planInput(input);
    try App.__refinePlanBody(
        &plan,
        plan.body.selectMedia(0) orelse return error.TestUnexpectedResult,
    );
    const head = try App.prepareHeadPlannedIn(
        &state,
        &workspace,
        &request_workspace,
        &output,
        &plan,
        .{},
    );
    switch (head) {
        .receive_body => {},
        .prepared => return error.TestUnexpectedResult,
    }
    try App.__beginMultipart(&workspace, &request_workspace, "B", &upload_registry);
    try App.__feedMultipart(&workspace, &request_workspace, wire);
    try App.__finishMultipart(&workspace, &request_workspace);
    const prepared = try App.__prepareBodyWithResponseGzip(
        &workspace,
        .none,
        .{},
        &request_workspace,
        [_]u8{0} ** 16,
        &output,
        &gzip,
    );
    const expected_status: response.Status = if (response_failure) .forbidden else .ok;
    const expected_suffix = if (response_failure) "\r\n\r\ndenied" else "\r\n\r\naccepted";
    try std.testing.expectEqual(expected_status, prepared.status);
    try std.testing.expect(std.mem.endsWith(u8, prepared.bytes, expected_suffix));
    try std.testing.expectEqual(
        .complete,
        try App.__startMultipartFinalization(&workspace, &request_workspace),
    );
    const report = (try App.__multipartFinalizationReport(
        &workspace,
        &request_workspace,
    )).?;
    try std.testing.expectEqual(@as(u16, 0), report.instance_count);
    try std.testing.expectEqual(@as(u32, 0), report.cleanup_failure_count);
    try std.testing.expectError(
        error.InvariantViolation,
        App.__multipartFinalizationCleanupFailure(&workspace, &request_workspace, 0),
    );
    return report.outcome;
}

test "multipart completion rejects an uninitialized runtime state" {
    const workspace_bytes: usize = @intCast(App.body_workspace_bytes_max);
    var state = AppState{};
    var workspace = App.Workspace{};
    var request_workspace: [workspace_bytes]u8 align(App.body_workspace_alignment) = undefined;
    var output: [512]u8 = undefined;
    var gzip = App.ResponseGzipWorkspace{};
    const input = requestInput();
    var plan = planInput(input);
    try App.__refinePlanBody(
        &plan,
        plan.body.selectMedia(0) orelse return error.TestUnexpectedResult,
    );

    const head = try App.prepareHeadPlannedIn(
        &state,
        &workspace,
        &request_workspace,
        &output,
        &plan,
        .{},
    );
    switch (head) {
        .receive_body => {},
        .prepared => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(error.InvalidBodyInput, App.__prepareBodyWithResponseGzip(
        &workspace,
        .none,
        .{},
        &request_workspace,
        [_]u8{0} ** 16,
        &output,
        &gzip,
    ));
    _ = try App.abort(&workspace);
    try std.testing.expectEqualStrings("HZ", state.events[0..state.events_len]);
}

fn requestInput() application.Input {
    return .{
        .method = "POST",
        .path = "/upload",
        .raw_target = "/upload",
        .raw_path = "/upload",
        .date = fixed_date,
    };
}

fn planInput(input: application.Input) App.Plan {
    var route_workspace: App.RouteSearchWorkspace = undefined;
    return App.plan(input, &route_workspace);
}
