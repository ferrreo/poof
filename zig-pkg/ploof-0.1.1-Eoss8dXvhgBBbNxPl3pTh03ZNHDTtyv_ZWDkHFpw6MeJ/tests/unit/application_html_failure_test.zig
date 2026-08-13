const std = @import("std");
const application = @import("../../src/application.zig");
const application_chunk_output = @import("../../src/internal/application/chunk_output.zig");
const html_response = @import("../../src/html/response.zig");
const html_source = @import("../../src/html/source.zig");
const html_template = @import("../../src/html/template.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const worker_response_chunks = @import("../../src/internal/runtime/worker/response_chunks.zig");

const Pool = worker_response_chunks.Pool(16);
const FaultState = struct {
    message: []const u8,
    response_status: ?response.Status = null,
    response_rendered: bool = true,
};
const FaultContext = application.Context(FaultState, response.standard_head_limits);
const FaultResponse = FaultContext.ResponseType;
const FaultPage = html_template.Template(.{
    .View = struct { message: []const u8 },
    .encoded_bytes_max = 32,
    .source = html_source.SourceSpec{
        .kind = .fragment,
        .graph_name = "application-html-failure",
        .file_path = "views/failure.html",
        .bytes = "{{view.message}}",
    },
});

fn faultHandler(context: *FaultContext) html_response.TemplateResponse(FaultPage) {
    return context.html(.ok, FaultPage, .{ .message = context.state.message });
}

const ObserveFailure = struct {
    pub const State = void;

    pub fn response(
        _: ObserveFailure,
        context: *FaultContext,
        _: *State,
        value: *FaultResponse,
    ) void {
        context.state.response_status = value.status;
        context.state.response_rendered = value.body.isRendered();
    }
};

const FaultApp = application.Application(.{
    .State = FaultState,
    .middleware = .{ObserveFailure{}},
    .routes = .{route.get("/", faultHandler)},
});

const WorkError = error{RenderWorkExhausted};
const WorkState = struct { mapped: bool = false };
const WorkContext = application.Context(WorkState, response.standard_head_limits);
const WorkResponse = WorkContext.ResponseType;
const work_items = [_]u16{ 1, 2 };
const WorkPage = html_template.Template(.{
    .View = struct { items: []const u16 },
    .render_operations_max = 2,
    .source = html_source.SourceSpec{
        .kind = .fragment,
        .graph_name = "application-render-work",
        .file_path = "views/render-work.html",
        .bytes = "prefix{{#each view.items as item}}x{{/each}}suffix",
    },
});

fn workHandler(context: *WorkContext) html_response.TemplateResponse(WorkPage) {
    return context.html(.ok, WorkPage, .{ .items = &work_items });
}

fn mapWorkError(context: *WorkContext, _: WorkError) WorkResponse {
    context.state.mapped = true;
    return context.textStatic(.forbidden, "mapped");
}

const WorkApp = application.Application(.{
    .State = WorkState,
    .Error = WorkError,
    .routes = .{route.get("/", workHandler)},
    .map_error = mapWorkError,
});

const LayoutState = struct {};
const LayoutContext = application.Context(LayoutState, response.standard_head_limits);
const Layout = html_template.Template(.{
    .View = struct { title: []const u8 },
    .encoded_bytes_max = 128,
    .source = html_source.SourceSpec{
        .kind = .layout,
        .graph_name = "application-layout",
        .file_path = "views/layout.html",
        .bytes = "<!doctype html><html><head><title>{{view.title}}</title></head>" ++
            "<body>{{@body}}</body></html>",
    },
});
const LayoutBody = html_template.Template(.{
    .View = struct { message: []const u8 },
    .encoded_bytes_max = 64,
    .source = html_source.SourceSpec{
        .kind = .fragment,
        .graph_name = "application-layout-body",
        .file_path = "views/layout-body.html",
        .bytes = "<main>{{view.message}}</main>",
    },
});

fn layoutHandler(
    context: *LayoutContext,
) html_response.LayoutResponse(Layout, LayoutBody) {
    return context.htmlLayout(
        .ok,
        Layout,
        LayoutBody,
        .{ .title = "Ploof" },
        .{ .message = "safe <body>" },
    );
}

const LayoutApp = application.Application(.{
    .State = LayoutState,
    .routes = .{route.get("/", layoutHandler)},
});

test "invalid UTF-8 and encoded limit failures close with clean reusable 500 state" {
    inline for (.{ "\xff", "x" ** 33 }) |invalid| {
        var state = FaultState{ .message = invalid };
        var workspace = FaultApp.Workspace{};
        var indices: [8]u16 = undefined;
        var nodes: [8]worker_response_chunks.Node = undefined;
        var storage: [8 * 16]u8 = undefined;
        var pool = try Pool.init(&indices, &nodes, &storage);

        const failed = try prepare(FaultApp, &state, &workspace, &pool);
        try std.testing.expectEqual(response.Status.internal_server_error, failed.status);
        try std.testing.expect(failed.close_connection);
        try std.testing.expect(failed.source.finite_chain.body.isEmpty());
        try std.testing.expectEqual(response.Status.internal_server_error, state.response_status.?);
        try std.testing.expect(!state.response_rendered);
        try std.testing.expectEqual(@as(u16, 8), pool.available());
        _ = try FaultApp.complete(&workspace);

        state.message = "reused";
        state.response_status = null;
        const reused = try prepare(FaultApp, &state, &workspace, &pool);
        const finite = reused.source.finite_chain;
        try std.testing.expectEqual(response.Status.ok, reused.status);
        try expectBody(&pool, finite.body, "reused");
        pool.release(finite.body);
        _ = try FaultApp.complete(&workspace);
        try std.testing.expectEqual(@as(u16, 8), pool.available());
    }
}

test "render work exhaustion discards staged chunks without invoking application mapper" {
    var state = WorkState{};
    var workspace = WorkApp.Workspace{};
    var indices: [8]u16 = undefined;
    var nodes: [8]worker_response_chunks.Node = undefined;
    var storage: [8 * 16]u8 = undefined;
    @memset(&storage, 0xa5);
    var pool = try Pool.init(&indices, &nodes, &storage);

    const failed = try prepare(WorkApp, &state, &workspace, &pool);
    try std.testing.expectEqual(response.Status.internal_server_error, failed.status);
    try std.testing.expect(failed.close_connection);
    try std.testing.expect(failed.source.finite_chain.body.isEmpty());
    try std.testing.expect(!state.mapped);
    try std.testing.expectEqual(@as(u16, 8), pool.available());
    try std.testing.expectEqual(@as(usize, 7), std.mem.count(u8, &storage, "\x00"));
    _ = try WorkApp.complete(&workspace);
}

test "layout and body render as one finite chain" {
    var state = LayoutState{};
    var workspace = LayoutApp.Workspace{};
    var indices: [16]u16 = undefined;
    var nodes: [16]worker_response_chunks.Node = undefined;
    var storage: [16 * 16]u8 = undefined;
    var pool = try Pool.init(&indices, &nodes, &storage);
    const prepared = try prepare(LayoutApp, &state, &workspace, &pool);
    const finite = prepared.source.finite_chain;
    try expectBody(
        &pool,
        finite.body,
        "<!doctype html><html><head><title>Ploof</title></head><body>" ++
            "<main>safe &lt;body&gt;</main></body></html>",
    );
    pool.release(finite.body);
    _ = try LayoutApp.complete(&workspace);
}

fn prepare(
    comptime App: type,
    state: anytype,
    workspace: anytype,
    pool: *Pool,
) !application.Prepared {
    const request = input();
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var plan = App.plan(request, &route_workspace);
    var concrete = pool.writer(plan.finite_output.chunks.encoded_bytes_max);
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
    return result.prepared;
}

fn input() application.Input {
    return .{
        .method = "GET",
        .path = "/",
        .raw_target = "/",
        .raw_path = "/",
        .date = "Thu, 16 Jul 2026 12:00:00 GMT",
    };
}

fn expectBody(pool: *Pool, chain: worker_response_chunks.Chain, expected: []const u8) !void {
    var actual: [256]u8 = undefined;
    var used: usize = 0;
    var iterator = pool.iterator(chain);
    while (iterator.next()) |bytes| {
        @memcpy(actual[used..][0..bytes.len], bytes);
        used += bytes.len;
    }
    try std.testing.expectEqualStrings(expected, actual[0..used]);
}
