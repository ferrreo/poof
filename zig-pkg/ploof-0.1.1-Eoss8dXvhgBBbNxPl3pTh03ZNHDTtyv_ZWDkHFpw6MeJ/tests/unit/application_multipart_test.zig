const std = @import("std");
const application = @import("../../src/application.zig");
const endpoint = @import("../../src/endpoint.zig");
const multipart = @import("../../src/multipart.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const boundary = "unit-boundary";

const Mode = enum {
    safe,
    fast,
};

const limits = multipart.Limits.validate(.{
    .encoded_wire_bytes_max = 4096,
    .total_body_bytes_max = 2048,
    .file_bytes_max = 128,
    .field_bytes_max = 64,
    .parts_max = 8,
    .files_max = 1,
    .part_headers_max = 3,
    .part_header_bytes_max = 256,
    .disposition_parameters_max = 4,
    .delimiter_transport_padding_bytes_max = 16,
    .name_bytes_max = 32,
    .filename_bytes_max = 64,
    .boundary_bytes_max = 16,
});

const MultipartBody = multipart.decode(.{
    .age = multipart.field(u16, multipart.required),
    .enabled = multipart.field(bool, multipart.optional),
    .mode = multipart.field(Mode, multipart.required),
    .raw = multipart.bytesField(multipart.required),
    .upload = multipart.fileWithPolicy(
        multipart.DiscardSink,
        multipart.required,
        multipart.claimedMediaTypes(&.{"application/octet-stream"}, .reject),
    ),
}, .{ .limits = limits });

const Definition = endpoint.Endpoint(.{ .body = MultipartBody });
const MultipartSpec = @TypeOf(MultipartBody);
const Field = @TypeOf(MultipartBody).Field;

const AppState = struct {
    order: [16]u8 = undefined,
    order_used: u8 = 0,
    init_calls: u8 = 0,
    field_calls: u8 = 0,
    complete_calls: u8 = 0,
    age: u16 = 0,
    enabled: bool = false,
    mode: Mode = .safe,
    raw: [3]u8 = undefined,
    raw_len: u8 = 0,
    logical_body_zero: bool = false,
    middleware_state_preserved: bool = false,
    response_saw_complete: bool = false,
    after_status: ?response.Status = null,

    fn record(self: *AppState, event: u8) void {
        std.debug.assert(self.order_used < self.order.len);
        self.order[self.order_used] = event;
        self.order_used += 1;
    }
};

const Context = application.Context(AppState, response.standard_head_limits);
const Response = Context.ResponseType;

const Consumer = struct {
    pub const State = struct {
        app: *AppState,
        age: u16 = 0,
        enabled: bool = false,
        mode: Mode = .safe,
        raw: [3]u8 = undefined,
        raw_len: u8 = 0,
    };

    pub fn init(_: Consumer, context: *Context) State {
        context.state.init_calls += 1;
        context.state.record('I');
        return .{ .app = context.state };
    }

    pub fn field(_: Consumer, state: *State, value: Field) void {
        state.app.field_calls += 1;
        state.app.record('F');
        switch (value) {
            .age => |age| state.age = age,
            .enabled => |enabled| state.enabled = enabled,
            .mode => |mode| state.mode = mode,
            .raw => |raw| {
                std.debug.assert(raw.len <= state.raw.len);
                @memcpy(state.raw[0..raw.len], raw);
                state.raw_len = @intCast(raw.len);
            },
        }
    }

    pub fn fileStart(
        _: Consumer,
        _: *Context,
        _: *State,
        _: MultipartSpec.FileStart,
    ) MultipartSpec.FileAdmission(Response) {
        return .{ .accept = .{ .upload = {} } };
    }

    pub fn complete(
        _: Consumer,
        context: *Context,
        state: *State,
        logical_input: Definition.InputType,
        _: MultipartSpec.Summaries,
    ) multipart.Decision(Response) {
        context.state.record('C');
        context.state.complete_calls += 1;
        context.state.age = state.age;
        context.state.enabled = state.enabled;
        context.state.mode = state.mode;
        context.state.raw_len = state.raw_len;
        @memcpy(context.state.raw[0..state.raw_len], state.raw[0..state.raw_len]);
        context.state.logical_body_zero = @sizeOf(@TypeOf(logical_input.body)) == 0;
        return multipart.commit(context.textStatic(.ok, "multipart-ok"));
    }
};

const Lifecycle = struct {
    pub const State = u8;

    pub fn init(_: Lifecycle) State {
        return 0xa5;
    }

    pub fn head(_: Lifecycle, context: *Context, state: *State) ?Response {
        context.state.record('H');
        context.state.middleware_state_preserved = state.* == 0xa5;
        return null;
    }

    pub fn body(
        _: Lifecycle,
        context: *Context,
        state: *State,
        _: Definition.InputType,
    ) ?Response {
        context.state.record('B');
        context.state.middleware_state_preserved =
            context.state.middleware_state_preserved and state.* == 0xa5;
        return null;
    }

    pub fn response(
        _: Lifecycle,
        context: *Context,
        _: *State,
        _: *Response,
    ) void {
        context.state.record('R');
        context.state.response_saw_complete = context.state.complete_calls == 1;
    }

    pub fn after(
        _: Lifecycle,
        context: *const Context,
        _: *State,
        outcome: application.Outcome,
    ) void {
        context.state.record('A');
        context.state.after_status = outcome.status;
    }
};

const handler = Definition.handle(Consumer{});
const App = application.Application(.{
    .State = AppState,
    .routes = .{route.configured(
        .post,
        "/upload",
        handler,
        .{Lifecycle{}},
        null,
    )},
});

const request_workspace_bytes: usize = @intCast(App.body_workspace_bytes_max);

const Harness = struct {
    state: AppState = .{},
    workspace: App.Workspace = .{},
    request_workspace: [request_workspace_bytes]u8 align(App.body_workspace_alignment) = undefined,
    output: [1024]u8 = undefined,
    gzip: App.ResponseGzipWorkspace = .{},
    upload_registry: App.UploadRegistry = .{},
    route_workspace: App.RouteSearchWorkspace = undefined,

    fn begin(self: *Harness) !void {
        const request_input = input();
        var plan = App.plan(request_input, &self.route_workspace);
        try App.__refinePlanBody(
            &plan,
            plan.body.selectMedia(0) orelse return error.TestUnexpectedResult,
        );
        const result = try App.prepareHeadPlannedIn(
            &self.state,
            &self.workspace,
            &self.request_workspace,
            &self.output,
            &plan,
            .{},
        );
        const body_plan = switch (result) {
            .receive_body => |value| value,
            .prepared => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(?u8, 0), body_plan.selected_decoder);
        try std.testing.expectEqual(.multipart, body_plan.decoderKind().?);
        try App.__beginMultipart(
            &self.workspace,
            &self.request_workspace,
            boundary,
            &self.upload_registry,
        );
    }

    fn finish(self: *Harness) !application.Prepared {
        try App.__finishMultipart(&self.workspace, &self.request_workspace);
        const prepared = try App.__prepareBodyWithResponseGzip(
            &self.workspace,
            .none,
            .{},
            &self.request_workspace,
            [_]u8{0} ** 16,
            &self.output,
            &self.gzip,
        );
        try std.testing.expectEqual(
            .complete,
            try App.__startMultipartFinalization(
                &self.workspace,
                &self.request_workspace,
            ),
        );
        return prepared;
    }
};

const valid_body =
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"age\"\r\n" ++
    "Content-Type: text/plain; charset=utf-8\r\n\r\n" ++
    "42\r\n" ++
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"enabled\"\r\n\r\n" ++
    "true\r\n" ++
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"mode\"\r\n\r\n" ++
    "fast\r\n" ++
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"raw\"\r\n\r\n" ++
    "\xff\x00Z\r\n" ++
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"upload\"; filename=\"data.bin\"\r\n" ++
    "Content-Type: application/octet-stream\r\n\r\n" ++
    "file-data\r\n" ++
    "--" ++ boundary ++ "--\r\n";

test "multipart consumer receives typed fields across every two-way split" {
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Definition.InputType));
    try std.testing.expect(@TypeOf(MultipartBody).ploof_multipart_push_decoder);
    try std.testing.expect(multipart.DiscardSink.ploof_multipart_discard_sink);

    for (0..valid_body.len + 1) |split| {
        var harness = Harness{};
        try harness.begin();
        try App.__feedMultipart(
            &harness.workspace,
            &harness.request_workspace,
            valid_body[0..split],
        );
        try App.__feedMultipart(
            &harness.workspace,
            &harness.request_workspace,
            valid_body[split..],
        );
        const prepared = try harness.finish();
        try expectSuccess(&harness, prepared);
    }
}

fn expectSuccess(harness: *Harness, prepared: application.Prepared) !void {
    try std.testing.expectEqual(response.Status.ok, prepared.status);
    try std.testing.expect(std.mem.endsWith(
        u8,
        prepared.bytes,
        "\r\n\r\nmultipart-ok",
    ));
    _ = try App.complete(&harness.workspace);
    try std.testing.expectEqual(@as(u8, 1), harness.state.init_calls);
    try std.testing.expectEqual(@as(u8, 4), harness.state.field_calls);
    try std.testing.expectEqual(@as(u8, 1), harness.state.complete_calls);
    try std.testing.expectEqual(@as(u16, 42), harness.state.age);
    try std.testing.expect(harness.state.enabled);
    try std.testing.expectEqual(Mode.fast, harness.state.mode);
    try std.testing.expectEqualStrings("\xff\x00Z", harness.state.raw[0..harness.state.raw_len]);
    try std.testing.expect(harness.state.logical_body_zero);
    try std.testing.expect(harness.state.middleware_state_preserved);
    try std.testing.expect(harness.state.response_saw_complete);
    try std.testing.expectEqualStrings(
        "HIFFFFBCRA",
        harness.state.order[0..harness.state.order_used],
    );
    try std.testing.expectEqual(
        @as(?response.Status, response.Status.ok),
        harness.state.after_status,
    );
}

test "multipart application maps required unknown scalar media and size failures" {
    const cases = [_]struct {
        body: []const u8,
        expected: application.MultipartError,
    }{
        .{ .body = missing_required_body, .expected = error.InvalidMultipart },
        .{ .body = unknown_body, .expected = error.InvalidMultipart },
        .{ .body = invalid_scalar_body, .expected = error.InvalidField },
        .{ .body = unsupported_media_body, .expected = error.UnsupportedMedia },
        .{ .body = oversized_field_body, .expected = error.LimitExceeded },
    };
    for (cases) |case| try expectMultipartError(case.body, case.expected);
}

fn expectMultipartError(body: []const u8, expected: application.MultipartError) !void {
    var harness = Harness{};
    try harness.begin();
    var actual: ?application.MultipartError = null;
    App.__feedMultipart(&harness.workspace, &harness.request_workspace, body) catch |problem| {
        actual = problem;
    };
    if (actual == null) {
        App.__finishMultipart(&harness.workspace, &harness.request_workspace) catch |problem| {
            actual = problem;
        };
    }
    try std.testing.expectEqual(expected, actual orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(
        .complete,
        try App.__startMultipartFinalization(
            &harness.workspace,
            &harness.request_workspace,
        ),
    );
    _ = try App.abort(&harness.workspace);
}

const missing_required_body =
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"age\"\r\n\r\n" ++
    "42\r\n" ++
    "--" ++ boundary ++ "--\r\n";

const unknown_body =
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"unknown\"\r\n\r\n" ++
    "value\r\n" ++
    "--" ++ boundary ++ "--\r\n";

const invalid_scalar_body =
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"age\"\r\n\r\n" ++
    "not-a-number\r\n" ++
    "--" ++ boundary ++ "--\r\n";

const unsupported_media_body =
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"upload\"; filename=\"data.bin\"\r\n" ++
    "Content-Type: text/plain\r\n\r\n" ++
    "file-data\r\n" ++
    "--" ++ boundary ++ "--\r\n";

const oversized_field_body =
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"raw\"\r\n\r\n" ++
    ("x" ** 65) ++ "\r\n" ++
    "--" ++ boundary ++ "--\r\n";

fn input() application.Input {
    return .{
        .method = "POST",
        .path = "/upload",
        .raw_target = "/upload",
        .raw_path = "/upload",
        .date = fixed_date,
    };
}
