const ploof = @import("ploof");

const State = struct { readiness: ploof.Lifecycle.Readiness = .{} };
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Uploads = ploof.Multipart.FileSink(.{
    .root = "/srv/uploads",
    .durability = .buffered,
});
const UploadBody = ploof.Multipart.decode(.{
    .upload = ploof.Multipart.file(Uploads, ploof.Multipart.required),
}, .{});
const UploadEndpoint = ploof.Endpoint(.{ .body = UploadBody });
const UploadSpec = @TypeOf(UploadBody);
const PublicStaticDir = ploof.StaticDir.init("/public", "./public", .{});
const PublicStaticFile = ploof.StaticFile.init("/robots.txt", ".", "robots.txt", .{});
const CssAssetRef = ploof.AssetRef(.css);

comptime {
    ploof.Multipart.validateSink(Uploads);
}

fn ping(context: *Context) ploof.ResponseBodyError!Context.ResponseType {
    const values: ploof.RequestTrailers.Values = context.request.trailers.all("x-check");
    _ = values.count();
    _ = values.first();
    const one: ploof.RequestTrailers.OneError![]const u8 = values.one();
    _ = one catch "";
    var iterator: ploof.RequestTrailers.ValueIterator = values.iterator();
    _ = iterator.next();
    const raw: ploof.RequestTrailers.Raw = context.request.trailers.raw();
    _ = raw.count();
    var raw_iterator: ploof.RequestTrailers.RawIterator = raw.iterator();
    const field: ?ploof.RequestTrailers.RawField = raw_iterator.next();
    _ = field;
    var dynamic = [_]u8{ 'p', 'o', 'n', 'g' };
    const result = try context.text(.ok, &dynamic);
    @memset(&dynamic, 'x');
    return result;
}

const ReadyAccess = struct {
    fn binding(state: *State) *const ploof.Lifecycle.Readiness {
        return &state.readiness;
    }
};
const Ready = ploof.Health.Readiness(Context, ReadyAccess.binding);
const Live = ploof.Health.Liveness(Context);

const UploadConsumer = struct {
    pub const State = void;

    pub fn fileStart(
        _: UploadConsumer,
        _: *Context,
        _: *UploadConsumer.State,
        event: UploadSpec.FileStart,
    ) UploadSpec.FileAdmission(Context.ResponseType) {
        _ = switch (event) {
            .upload => |metadata| metadata,
        };
        return .{ .accept = .{
            .upload = Uploads.Key.init("incoming/upload.bin") catch unreachable,
        } };
    }

    pub fn complete(
        _: UploadConsumer,
        context: *Context,
        _: *UploadConsumer.State,
        _: UploadEndpoint.InputType,
        _: UploadSpec.Summaries,
    ) ploof.Multipart.Decision(Context.ResponseType) {
        return ploof.Multipart.commit(context.textStatic(.created, "stored"));
    }
};

const App = ploof.Application(.{
    .State = State,
    .Error = ploof.ResponseBodyError,
    .response_body_bytes_max = 4,
    .routes = .{
        ploof.get("/ping", ping),
        ploof.get("/live", Live.handle),
        ploof.get("/ready", Ready.handle),
        ploof.openMetrics("/metrics"),
        ploof.post("/upload", UploadEndpoint.handle(UploadConsumer{})),
    },
});
const RuntimeServer = ploof.Server(App, .{ .limits = .{
    .connection_slots = 1,
    .request_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 1024,
    .pipeline_bytes_per_connection = 1024,
    .response_bytes_per_request = 4096,
    .response_chunk_count = 2,
    .submission_entries = 32,
    .completion_entries = 64,
} });
const SignalRunner = ploof.ServerRunner(App, RuntimeServer.compiled_options);
var signal_runner: SignalRunner align(@alignOf(SignalRunner)) = SignalRunner.init();

pub fn main() void {
    _ = PublicStaticDir;
    _ = PublicStaticFile;
    _ = CssAssetRef;
    _ = ploof.Asset.mediaType(.css);
    var state = State{};
    const start_config = ploof.ServerStartConfig{
        .listener = .{ .address = .{ .ipv4 = .{
            .bytes = .{ 127, 0, 0, 1 },
            .port = 8080,
        } } },
        .worker_count = 1,
        .readiness = &state.readiness,
    };
    _ = start_config;
    _ = &signal_runner;
    _ = @sizeOf(RuntimeServer);
    _ = @sizeOf(SignalRunner);
    if (!@hasDecl(SignalRunner, "runOrExit")) @compileError("missing public runner exit API");
    _ = ploof.ServerExit.shutdown_incomplete;
    const RunResult: type = ploof.ServerRunResult;
    const RunError: type = ploof.ServerRunError;
    const SignalShutdownError: type = ploof.ServerSignalShutdownError;
    _ = RunResult;
    _ = RunError;
    _ = SignalShutdownError;
    var workspace = App.Workspace{};
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var output: [512]u8 = undefined;
    const result = App.serve(&state, &workspace, &route_workspace, ploof.Input{
        .method = "GET",
        .path = "/ping",
        .raw_target = "/ping",
        .raw_path = "/ping",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
    }, &output) catch @panic("public package API failed");
    if (result.status != .ok) @panic("unexpected status");
}
