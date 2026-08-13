const std = @import("std");
const application = @import("../../src/application.zig");
const application_chunk_output = @import("../../src/internal/application/chunk_output.zig");
const html_response = @import("../../src/html/response.zig");
const html_render = @import("../../src/html/render.zig");
const html_source = @import("../../src/html/source.zig");
const html_template = @import("../../src/html/template.zig");
const json = @import("../../src/json.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const worker_response_chunks = @import("../../src/internal/runtime/worker/response_chunks.zig");
const inline_text = @import("../../src/inline_text.zig");

const limits = response.standard_head_limits;
const AppState = struct {
    saw_rendered: bool = false,
    replace: bool = false,
    mapped: bool = false,
    response_saw_mapped: bool = false,
    after_mapped_error: bool = false,
};
const Context = application.Context(AppState, limits);
const Response = Context.ResponseType;
const Page = html_template.Template(.{
    .View = struct { message: []const u8 },
    .encoded_bytes_max = 128,
    .source = html_source.SourceSpec{
        .kind = .fragment,
        .graph_name = "application-html",
        .file_path = "views/application.html",
        .bytes = "<main>{{view.message}}</main>",
    },
});

fn handler(context: *Context) html_response.TemplateResponse(Page) {
    return context.html(.ok, Page, .{ .message = "safe <body>" });
}

const Observe = struct {
    pub const State = void;

    pub fn response(_: Observe, context: *Context, _: *State, value: *Response) void {
        context.state.saw_rendered = value.body.isRendered();
        if (context.state.replace) {
            value.* = context.textStatic(.accepted, "replaced");
        }
    }
};

const App = application.Application(.{
    .State = AppState,
    .middleware = .{Observe{}},
    .routes = .{route.get("/", handler)},
});
const GzipApp = application.Application(.{
    .State = AppState,
    .middleware = .{Observe{}},
    .routes = .{route.get("/", handler)},
    .response_gzip = application.ResponseGzip{ .minimum_bytes = 0 },
});
const tight_gzip_limits = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 4,
});
const TightGzipApp = application.Application(.{
    .State = AppState,
    .routes = .{route.configured(.get, "/", handler, .{}, tight_gzip_limits)},
    .response_gzip = application.ResponseGzip{ .minimum_bytes = 0 },
});

const RenderError = error{Denied};
const ErrorPage = html_template.Template(.{
    .View = struct { denied: bool },
    .encoded_bytes_max = 64,
    .source = html_source.SourceSpec{
        .kind = .fragment,
        .graph_name = "application-html-error",
        .file_path = "views/error.html",
        .bytes = "before/{{checked view.denied}}/after",
    },
    .helpers = .{ .checked = struct {
        fn call(denied: bool) RenderError![]const u8 {
            if (denied) return error.Denied;
            return "allowed";
        }
    }.call },
});
const Formatted = struct {
    pub fn formatText(_: Formatted) RenderError!inline_text.InlineText(8) {
        return error.Denied;
    }
};
const FormatErrorPage = html_template.Template(.{
    .View = struct { value: Formatted },
    .encoded_bytes_max = 64,
    .source = html_source.SourceSpec{
        .kind = .fragment,
        .graph_name = "application-format-error",
        .file_path = "views/format-error.html",
        .bytes = "before/{{view.value}}/after",
    },
});
const BrowserJsonValue = struct {
    denied: bool,
    pub const JsonApplicationError = RenderError;

    pub fn jsonStringify(
        value: BrowserJsonValue,
        writer: anytype,
    ) (json.Error || JsonApplicationError)!void {
        if (value.denied) return error.Denied;
        return writer.write("allowed");
    }
};
const BrowserJsonErrorPage = html_template.Template(.{
    .View = struct { value: BrowserJsonValue },
    .encoded_bytes_max = 128,
    .source = html_source.SourceSpec{
        .kind = .fragment,
        .graph_name = "application-browser-json-error",
        .file_path = "views/browser-json-error.html",
        .bytes = "before/{{@jsonData state view.value}}/after",
    },
    .browser_json = html_render.BrowserJsonOptions{ .encoded_bytes_max = 32 },
});

fn errorHandler(context: *Context) html_response.TemplateResponse(ErrorPage) {
    return context.html(.ok, ErrorPage, .{ .denied = true });
}

fn formatErrorHandler(context: *Context) html_response.TemplateResponse(FormatErrorPage) {
    return context.html(.ok, FormatErrorPage, .{ .value = .{} });
}

fn browserJsonErrorHandler(context: *Context) html_response.TemplateResponse(BrowserJsonErrorPage) {
    return context.html(.ok, BrowserJsonErrorPage, .{ .value = .{ .denied = true } });
}

fn mapRenderError(context: *Context, _: RenderError) Response {
    context.state.mapped = true;
    return context.textStatic(.forbidden, "mapped");
}

const ErrorObserve = struct {
    pub const State = void;

    pub fn response(_: ErrorObserve, context: *Context, _: *State, value: *Response) void {
        context.state.response_saw_mapped = value.status == .forbidden and
            !value.body.isRendered();
    }

    pub fn after(
        _: ErrorObserve,
        context: *const Context,
        _: *State,
        outcome: application.Outcome,
    ) void {
        context.state.after_mapped_error = outcome.mapped_error;
    }
};

const ErrorApp = application.Application(.{
    .State = AppState,
    .Error = RenderError,
    .middleware = .{ErrorObserve{}},
    .routes = .{
        route.get("/helper", errorHandler),
        route.get("/format", formatErrorHandler),
        route.get("/json", browserJsonErrorHandler),
    },
    .map_error = mapRenderError,
});

const CollisionError = error{ResponseChunksExhausted};
const CollisionPage = html_template.Template(.{
    .View = struct { value: []const u8 },
    .encoded_bytes_max = 64,
    .source = html_source.SourceSpec{
        .kind = .fragment,
        .graph_name = "application-error-collision",
        .file_path = "views/error-collision.html",
        .bytes = "{{view.value}}",
    },
});

fn collisionHandler(context: *Context) html_response.TemplateResponse(CollisionPage) {
    return context.html(.ok, CollisionPage, .{ .value = "body-needs-two-chunks" });
}

fn mapCollision(context: *Context, _: CollisionError) Response {
    context.state.mapped = true;
    return context.textStatic(.forbidden, "must-not-map");
}

const CollisionApp = application.Application(.{
    .State = AppState,
    .Error = CollisionError,
    .routes = .{route.get("/", collisionHandler)},
    .map_error = mapCollision,
});

const Pool = worker_response_chunks.Pool(16);

fn input(method: []const u8) application.Input {
    return .{
        .method = method,
        .path = "/",
        .raw_target = "/",
        .raw_path = "/",
        .date = "Thu, 16 Jul 2026 12:00:00 GMT",
    };
}

test "typed HTML renders to a finite chain before ordinary response middleware" {
    var state = AppState{};
    var workspace = App.Workspace{};
    var indices: [16]u16 = undefined;
    var nodes: [16]worker_response_chunks.Node = undefined;
    var storage: [16 * 16]u8 = undefined;
    var pool = try Pool.init(&indices, &nodes, &storage);

    const prepared = try prepare(&state, &workspace, &pool, "GET");
    const finite = switch (prepared.source) {
        .finite_chain => |value| value,
        .contiguous_wire,
        .borrowed_static,
        .live_static,
        .live_static_file,
        => return error.TestUnexpectedResult,
    };
    defer pool.release(finite.body);
    try std.testing.expect(state.saw_rendered);
    try std.testing.expect(std.mem.indexOf(
        u8,
        finite.head,
        "content-type: text/html; charset=utf-8\r\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, finite.head, "content-length: 30\r\n") != null);
    try expectBody(&pool, finite.body, "<main>safe &lt;body&gt;</main>");
    _ = try App.complete(&workspace);
}

test "ordinary prepare rejects HTML without silently producing a framework response" {
    var state = AppState{};
    var workspace = App.Workspace{};
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var output: [512]u8 = undefined;
    try std.testing.expectError(
        error.HtmlRequiresTransport,
        App.prepare(&state, &workspace, &route_workspace, input("GET"), &output),
    );
}

test "response middleware can replace rendered HTML without leaking its chunks" {
    var state = AppState{ .replace = true };
    var workspace = App.Workspace{};
    var indices: [16]u16 = undefined;
    var nodes: [16]worker_response_chunks.Node = undefined;
    var storage: [16 * 16]u8 = undefined;
    var pool = try Pool.init(&indices, &nodes, &storage);

    const prepared = try prepare(&state, &workspace, &pool, "GET");
    const finite = prepared.source.finite_chain;
    defer pool.release(finite.body);
    try std.testing.expectEqual(response.Status.accepted, prepared.status);
    try expectBody(&pool, finite.body, "replaced");
    try std.testing.expect(std.mem.indexOf(u8, finite.head, "content-length: 8\r\n") != null);
    _ = try App.complete(&workspace);
}

test "HEAD retains hypothetical HTML length and releases body chunks before commit" {
    var state = AppState{};
    var workspace = App.Workspace{};
    var indices: [16]u16 = undefined;
    var nodes: [16]worker_response_chunks.Node = undefined;
    var storage: [16 * 16]u8 = undefined;
    var pool = try Pool.init(&indices, &nodes, &storage);

    const prepared = try prepare(&state, &workspace, &pool, "HEAD");
    const finite = prepared.source.finite_chain;
    try std.testing.expect(finite.body.isEmpty());
    try std.testing.expect(std.mem.indexOf(u8, finite.head, "content-length: 30\r\n") != null);
    try std.testing.expectEqual(@as(u16, 16), pool.available());
    const outcome = try App.complete(&workspace);
    try std.testing.expectEqual(application.TransportOutcome.head_suppressed, outcome.transport);
}

test "HTML gzip chains round trip and release preserved identity source at finish" {
    var state = AppState{};
    var workspace = GzipApp.Workspace{};
    var indices: [16]u16 = undefined;
    var nodes: [16]worker_response_chunks.Node = undefined;
    var storage: [16 * 16]u8 = undefined;
    var pool = try Pool.init(&indices, &nodes, &storage);
    const prepared = try prepareGzip(&state, &workspace, &pool, .{
        .gzip = 1000,
        .identity = 1000,
    });
    const finite = prepared.source.finite_chain;
    defer pool.release(finite.body);
    try std.testing.expectEqual(application.CodingOutcome.gzip, prepared.coding_outcome);
    try std.testing.expect(std.mem.indexOf(
        u8,
        finite.head,
        "content-encoding: gzip\r\n",
    ) != null);
    var encoded: [128]u8 = undefined;
    const compressed = gather(&pool, finite.body, &encoded);
    var source = std.Io.Reader.fixed(compressed);
    var decoder = std.compress.flate.Decompress.init(&source, .gzip, &.{});
    var decoded: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&decoded);
    const written = try decoder.reader.streamRemaining(&output);
    try std.testing.expectEqualStrings(
        "<main>safe &lt;body&gt;</main>",
        decoded[0..written],
    );
    _ = try GzipApp.complete(&workspace);
}

test "gzip capacity falls back to preserved identity or closed 503" {
    var state = AppState{};
    var workspace = GzipApp.Workspace{};
    const SmallPool = worker_response_chunks.Pool(16);
    var indices: [2]u16 = undefined;
    var nodes: [2]worker_response_chunks.Node = undefined;
    var storage: [2 * 16]u8 = undefined;
    var pool = try SmallPool.init(&indices, &nodes, &storage);
    var gzip: GzipApp.ResponseGzipWorkspace = undefined;

    @memset(std.mem.asBytes(&gzip), 0xa5);
    const fallback = try prepareGzipWithWorkspace(&state, &workspace, &pool, .{
        .gzip = 1000,
        .identity = 1000,
    }, &gzip);
    const identity = fallback.source.finite_chain;
    try std.testing.expectEqual(
        application.CodingOutcome.identity_capacity_fallback,
        fallback.coding_outcome,
    );
    try expectBody(&pool, identity.body, "<main>safe &lt;body&gt;</main>");
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&gzip), 0xa5));
    pool.release(identity.body);
    _ = try GzipApp.complete(&workspace);

    @memset(std.mem.asBytes(&gzip), 0x5a);
    const unavailable = try prepareGzipWithWorkspace(&state, &workspace, &pool, .{
        .gzip = 1000,
        .identity = 0,
    }, &gzip);
    const service_unavailable = unavailable.source.finite_chain;
    try std.testing.expectEqual(response.Status.service_unavailable, unavailable.status);
    try std.testing.expect(unavailable.close_connection);
    try std.testing.expect(service_unavailable.body.isEmpty());
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&gzip), 0x5a));
    try std.testing.expectEqual(@as(u16, 2), pool.available());
    _ = try GzipApp.complete(&workspace);
}

test "gzip head overflow restores identity bytes or closes with empty 503" {
    var state = AppState{};
    var workspace = TightGzipApp.Workspace{};
    @memset(&workspace.response_head_bytes, 0xa5);
    var indices: [16]u16 = undefined;
    var nodes: [16]worker_response_chunks.Node = undefined;
    var storage: [16 * 16]u8 = undefined;
    var pool = try Pool.init(&indices, &nodes, &storage);

    const fallback = try prepareTightGzip(&state, &workspace, &pool, 1000);
    const identity = fallback.source.finite_chain;
    try std.testing.expectEqual(
        application.CodingOutcome.identity_capacity_fallback,
        fallback.coding_outcome,
    );
    try std.testing.expect(std.mem.indexOf(u8, identity.head, "content-encoding") == null);
    try std.testing.expect(std.mem.indexOf(u8, identity.head, "content-length: 30\r\n") != null);
    try expectBody(&pool, identity.body, "<main>safe &lt;body&gt;</main>");
    try std.testing.expect(pool.high_water > identity.body.chunks);
    var committed_head: [512]u8 = undefined;
    @memcpy(committed_head[0..identity.head.len], identity.head);
    TightGzipApp.__scrubPreparedHead(&workspace, identity.head);
    try std.testing.expect(std.mem.allEqual(u8, &workspace.response_head_bytes, 0));
    try std.testing.expect(std.mem.indexOf(
        u8,
        committed_head[0..identity.head.len],
        "content-length: 30\r\n",
    ) != null);
    pool.release(identity.body);
    try std.testing.expectEqual(@as(u16, 16), pool.available());
    _ = try TightGzipApp.complete(&workspace);

    const unavailable = try prepareTightGzip(&state, &workspace, &pool, 0);
    const closed = unavailable.source.finite_chain;
    try std.testing.expectEqual(response.Status.service_unavailable, unavailable.status);
    try std.testing.expectEqual(
        application.CodingOutcome.capacity_unavailable,
        unavailable.coding_outcome,
    );
    try std.testing.expect(unavailable.close_connection);
    try std.testing.expect(closed.body.isEmpty());
    try std.testing.expect(std.mem.indexOf(u8, closed.head, "content-length: 0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, closed.head, "connection: close\r\n") != null);
    try std.testing.expectEqual(@as(u16, 16), pool.available());
    _ = try TightGzipApp.complete(&workspace);
}

test "template application errors map before response middleware and commit" {
    inline for (.{ "/helper", "/format", "/json" }) |path| {
        var state = AppState{};
        var workspace = ErrorApp.Workspace{};
        var indices: [8]u16 = undefined;
        var nodes: [8]worker_response_chunks.Node = undefined;
        var storage: [8 * 16]u8 = undefined;
        var pool = try Pool.init(indices[0..], nodes[0..], storage[0..]);
        const prepared = try prepareError(&state, &workspace, &pool, path);
        const finite = prepared.source.finite_chain;
        defer pool.release(finite.body);
        try std.testing.expectEqual(response.Status.forbidden, prepared.status);
        try expectBody(&pool, finite.body, "mapped");
        try std.testing.expect(state.mapped);
        try std.testing.expect(state.response_saw_mapped);
        _ = try ErrorApp.complete(&workspace);
        try std.testing.expect(state.after_mapped_error);
    }
}

test "writer exhaustion wins over a colliding Application error name" {
    var state = AppState{};
    var workspace = CollisionApp.Workspace{};
    var indices: [1]u16 = undefined;
    var nodes: [1]worker_response_chunks.Node = undefined;
    var storage: [16]u8 = undefined;
    var pool = try Pool.init(&indices, &nodes, &storage);
    const request = input("GET");
    var route_workspace: CollisionApp.RouteSearchWorkspace = undefined;
    var plan = CollisionApp.plan(request, &route_workspace);
    var concrete = pool.writer(plan.finite_output.chunks.encoded_bytes_max);
    defer concrete.abort();
    var writer = application_chunk_output.bind(&concrete);
    var scratch: [CollisionApp.html_json_scratch_bytes_max]u8 = undefined;
    var gzip: CollisionApp.ResponseGzipWorkspace = undefined;
    const result = try CollisionApp.__prepareHeadPlannedWithChunks(
        &state,
        &workspace,
        &.{},
        &workspace.response_head_bytes,
        &plan,
        .{},
        &writer,
        &scratch,
        &gzip,
    );
    const prepared = result.prepared;
    try std.testing.expectEqual(response.Status.service_unavailable, prepared.status);
    try std.testing.expectEqual(
        application.CodingOutcome.capacity_unavailable,
        prepared.coding_outcome,
    );
    try std.testing.expect(prepared.source.finite_chain.body.isEmpty());
    try std.testing.expect(!state.mapped);
    try std.testing.expectEqual(@as(u16, 1), pool.available());
    _ = try CollisionApp.complete(&workspace);
}

fn prepare(
    state: *AppState,
    workspace: *App.Workspace,
    pool: *Pool,
    method: []const u8,
) !application.Prepared {
    const request = input(method);
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var plan = App.plan(request, &route_workspace);
    const chunk_plan = plan.finite_output.chunks;
    var concrete = pool.writer(chunk_plan.encoded_bytes_max);
    defer concrete.abort();
    var writer = application_chunk_output.bind(&concrete);
    var scratch: [App.html_json_scratch_bytes_max]u8 = undefined;
    var gzip: App.ResponseGzipWorkspace = undefined;
    const result = try App.__prepareHeadPlannedWithChunks(
        state,
        workspace,
        &.{},
        &workspace.response_head_bytes,
        &plan,
        .{},
        &writer,
        &scratch,
        &gzip,
    );
    return switch (result) {
        .prepared => |value| value,
        .receive_body => error.TestUnexpectedResult,
    };
}

fn prepareGzip(
    state: *AppState,
    workspace: *GzipApp.Workspace,
    pool: anytype,
    preferences: @import("../../src/internal/http1/request_accept_encoding.zig").Preferences,
) !application.Prepared {
    var gzip: GzipApp.ResponseGzipWorkspace = undefined;
    return prepareGzipWithWorkspace(state, workspace, pool, preferences, &gzip);
}

fn prepareGzipWithWorkspace(
    state: *AppState,
    workspace: *GzipApp.Workspace,
    pool: anytype,
    preferences: @import("../../src/internal/http1/request_accept_encoding.zig").Preferences,
    gzip: *GzipApp.ResponseGzipWorkspace,
) !application.Prepared {
    var request = input("GET");
    request.accept_encoding = preferences;
    var route_workspace: GzipApp.RouteSearchWorkspace = undefined;
    var plan = GzipApp.plan(request, &route_workspace);
    const chunk_plan = plan.finite_output.chunks;
    var concrete = pool.writer(chunk_plan.encoded_bytes_max);
    defer concrete.abort();
    var writer = application_chunk_output.bind(&concrete);
    var scratch: [GzipApp.html_json_scratch_bytes_max]u8 = undefined;
    const result = try GzipApp.__prepareHeadPlannedWithChunks(
        state,
        workspace,
        &.{},
        &workspace.response_head_bytes,
        &plan,
        .{},
        &writer,
        &scratch,
        gzip,
    );
    return result.prepared;
}

fn prepareTightGzip(
    state: *AppState,
    workspace: *TightGzipApp.Workspace,
    pool: anytype,
    identity_weight: u16,
) !application.Prepared {
    var request = input("GET");
    request.accept_encoding = .{ .gzip = 1000, .identity = identity_weight };
    var route_workspace: TightGzipApp.RouteSearchWorkspace = undefined;
    var plan = TightGzipApp.plan(request, &route_workspace);
    const chunk_plan = plan.finite_output.chunks;
    var concrete = pool.writer(chunk_plan.encoded_bytes_max);
    defer concrete.abort();
    var writer = application_chunk_output.bind(&concrete);
    var scratch: [TightGzipApp.html_json_scratch_bytes_max]u8 = undefined;
    var gzip: TightGzipApp.ResponseGzipWorkspace = undefined;
    const result = try TightGzipApp.__prepareHeadPlannedWithChunks(
        state,
        workspace,
        &.{},
        &workspace.response_head_bytes,
        &plan,
        .{},
        &writer,
        &scratch,
        &gzip,
    );
    return result.prepared;
}

fn prepareError(
    state: *AppState,
    workspace: *ErrorApp.Workspace,
    pool: anytype,
    path: []const u8,
) !application.Prepared {
    var request = input("GET");
    request.path = path;
    request.raw_path = path;
    request.raw_target = path;
    var route_workspace: ErrorApp.RouteSearchWorkspace = undefined;
    var plan = ErrorApp.plan(request, &route_workspace);
    const chunk_plan = plan.finite_output.chunks;
    var concrete = pool.writer(chunk_plan.encoded_bytes_max);
    defer concrete.abort();
    var writer = application_chunk_output.bind(&concrete);
    var scratch: [ErrorApp.html_json_scratch_bytes_max]u8 = undefined;
    var gzip: ErrorApp.ResponseGzipWorkspace = undefined;
    const result = try ErrorApp.__prepareHeadPlannedWithChunks(
        state,
        workspace,
        &.{},
        &workspace.response_head_bytes,
        &plan,
        .{},
        &writer,
        &scratch,
        &gzip,
    );
    return result.prepared;
}

fn expectBody(pool: anytype, chain: worker_response_chunks.Chain, expected: []const u8) !void {
    var actual: [128]u8 = undefined;
    var used: usize = 0;
    var iterator = pool.iterator(chain);
    while (iterator.next()) |bytes| {
        @memcpy(actual[used..][0..bytes.len], bytes);
        used += bytes.len;
    }
    try std.testing.expectEqualStrings(expected, actual[0..used]);
}

fn gather(pool: anytype, chain: worker_response_chunks.Chain, output: []u8) []const u8 {
    var used: usize = 0;
    var iterator = pool.iterator(chain);
    while (iterator.next()) |bytes| {
        @memcpy(output[used..][0..bytes.len], bytes);
        used += bytes.len;
    }
    return output[0..used];
}
