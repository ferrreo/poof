const std = @import("std");

const address = @import("../../src/address.zig");
const application = @import("../../src/application.zig");
const csrf = @import("../../src/csrf.zig");
const endpoint = @import("../../src/endpoint.zig");
const multipart = @import("../../src/multipart.zig");
const upload = @import("../../src/multipart/upload.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");

const AuditSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const Runtime = struct {
        commits: u8 = 0,
        aborts: u8 = 0,
    };
    pub const StartupState = void;
    pub const Error = error{UnexpectedCompletion};
    pub const io_requirements = upload.IoRequirements{};
    pub const request_handles_max: u8 = 1;
    pub const runtime_handles_max: u8 = 0;
    pub const initial_state: AuditSink.State = {};
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

    pub fn runtimeStop(_: *Runtime, event: upload.PollEvent(void)) Error!upload.Poll(void) {
        return synchronous(event);
    }

    pub fn begin(
        _: *Runtime,
        _: *AuditSink.State,
        event: upload.PollEvent(BeginInput),
    ) Error!upload.Poll(void) {
        return synchronous(event);
    }

    pub fn write(
        _: *Runtime,
        _: *AuditSink.State,
        _: *WriteState,
        event: upload.PollEvent(upload.WriteInput),
    ) Error!upload.Poll(void) {
        return synchronous(event);
    }

    pub fn finish(
        _: *Runtime,
        _: *AuditSink.State,
        event: upload.PollEvent(upload.FinishInput),
    ) Error!upload.Poll(Summary) {
        return synchronous(event);
    }

    pub fn commit(
        runtime: *Runtime,
        _: *AuditSink.State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return switch (event) {
            .start => {
                runtime.commits += 1;
                return .{ .done = {} };
            },
            .completion => error.UnexpectedCompletion,
        };
    }

    pub fn abort(
        runtime: *Runtime,
        _: *AuditSink.State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return switch (event) {
            .start => {
                runtime.aborts += 1;
                return .{ .done = {} };
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

const Body = multipart.decode(.{
    ._csrf = csrf.multipartField(),
    .upload = multipart.file(AuditSink, multipart.required),
}, .{ .limits = .{
    .encoded_wire_bytes_max = 1024,
    .total_body_bytes_max = 1024,
    .file_bytes_max = 32,
    .field_bytes_max = 128,
    .parts_max = 2,
    .files_max = 1,
    .part_headers_max = 2,
    .part_header_bytes_max = 128,
    .disposition_parameters_max = 3,
    .delimiter_transport_padding_bytes_max = 4,
    .name_bytes_max = 16,
    .filename_bytes_max = 16,
    .boundary_bytes_max = 8,
} });
const Spec = @TypeOf(Body);
const Definition = endpoint.Endpoint(.{ .body = Body });
const Origins = csrf.OriginSet(1, 64);

const State = struct {
    origins: Origins = .{},
    session: ?csrf.SessionToken = null,
};
const Context = application.Context(State, response.standard_head_limits);

fn origins(state: *const State) *const Origins {
    return &state.origins;
}

fn load(context: *Context) ?csrf.SessionToken {
    return context.state.session;
}

fn store(context: *Context, token: csrf.SessionToken) void {
    context.state.session = token;
}

fn clear(context: *Context) void {
    context.state.session = null;
}

const policy = csrf.synchronizer(Context, .{
    .origins = origins,
    .load = load,
    .store = store,
    .clear = clear,
});

const Consumer = struct {
    pub const State = void;

    pub fn init(_: Consumer, _: *Context) Consumer.State {}

    pub fn fileStart(
        _: Consumer,
        _: *Context,
        _: *Consumer.State,
        _: Spec.FileStart,
    ) Spec.FileAdmission(Context.ResponseType) {
        return .{ .accept = .{ .upload = {} } };
    }

    pub fn complete(
        _: Consumer,
        context: *Context,
        _: *Consumer.State,
        _: Definition.InputType,
        _: Spec.Summaries,
    ) multipart.Decision(Context.ResponseType) {
        var token = policy.token(context) catch {
            return multipart.abort(context.empty(.internal_server_error));
        };
        defer token.clear();
        var value = context.htmlStatic(.ok, "protected");
        while (true) value.appendHeaderStatic("X-Fill", "x") catch break;
        return multipart.commit(value);
    }
};

const App = application.Application(.{
    .State = State,
    .middleware = .{policy},
    .routes = .{route.post("/upload", Definition.handle(Consumer{}))},
});

const request_workspace_bytes: usize = @intCast(App.body_workspace_bytes_max);
const token_raw = [_]u8{0x5a} ** csrf.synchronizer_bytes;
const encoded_token = @import("../../src/internal/csrf/request.zig").encodeSynchronizer(&token_raw);
const wire = std.fmt.comptimePrint(
    "--B\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n{s}\r\n" ++
        "--B\r\nContent-Disposition: form-data; name=\"upload\"; " ++
        "filename=\"x\"\r\n\r\ndata\r\n--B--\r\n",
    .{encoded_token},
);

test "CSRF response saturation aborts multipart transaction before commit" {
    var state = State{
        .origins = try Origins.init(&.{"http://ploof.test"}),
        .session = try csrf.SessionToken.fromRandomBytes(token_raw),
    };
    var workspace = App.Workspace{};
    var registry = App.UploadRegistry{};
    var request_workspace: [request_workspace_bytes]u8 align(App.body_workspace_alignment) =
        undefined;
    var output: [2048]u8 = undefined;
    var gzip = App.ResponseGzipWorkspace{};
    const driver = registry.driver(AuditSink);
    try std.testing.expectEqual(.done, try driver.startRuntime(.{
        .worker_index = 0,
        .entropy = &([_]u8{0xa5} ** 32),
    }));
    defer std.debug.assert((driver.startStop() catch unreachable) == .done);

    var route_workspace: App.RouteSearchWorkspace = undefined;
    var plan = App.plan(requestInput(), &route_workspace);
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
    if (head != .receive_body) return error.TestUnexpectedResult;
    try App.__beginMultipart(&workspace, &request_workspace, "B", &registry);
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

    try std.testing.expectEqual(response.Status.internal_server_error, prepared.status);
    try std.testing.expect(
        std.mem.indexOf(u8, prepared.bytes, "\r\ncache-control: no-store\r\n") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, prepared.bytes, "x-fill") == null);
    try std.testing.expectEqual(
        .complete,
        try App.__startMultipartFinalization(&workspace, &request_workspace),
    );
    try std.testing.expectEqual(
        .aborted,
        (try App.__multipartFinalizationOutcome(&workspace, &request_workspace)).?,
    );
    const runtime = registry.get(AuditSink).?;
    try std.testing.expectEqual(@as(u8, 0), runtime.commits);
    try std.testing.expectEqual(@as(u8, 1), runtime.aborts);
    const outcome = try App.complete(&workspace);
    try std.testing.expect(outcome.mapped_error);
}

fn requestInput() application.Input {
    const peer = address.Endpoint{
        .address = .{ .ipv4 = .{ 127, 0, 0, 1 } },
        .port = 1234,
    };
    return .{
        .method = "POST",
        .path = "/upload",
        .raw_target = "/upload",
        .raw_path = "/upload",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
        .forwarding = .{
            .transport_peer = peer,
            .connection_peer = peer,
            .client = peer,
            .authority = .{
                .host = .{ .reg_name = .{ .bytes = "ploof.test" } },
                .port = 80,
            },
            .scheme = .http,
            .connection_source = .transport,
            .client_provenance = .transport,
            .host_provenance = .host,
            .scheme_provenance = .connection,
            .forwarding_headers = .absent,
            .trusted_hops = 0,
        },
    };
}
