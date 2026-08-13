const std = @import("std");
const application = @import("../../src/application.zig");
const application_chunk_output = @import("../../src/internal/application/chunk_output.zig");
const html_response = @import("../../src/html/response.zig");
const html_render = @import("../../src/html/render.zig");
const html_source = @import("../../src/html/source.zig");
const html_template = @import("../../src/html/template.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const config = @import("../../src/internal/runtime/config.zig");
const worker_storage = @import("../../src/internal/runtime/worker/storage.zig");

const State = struct {};
const Context = application.Context(State, response.standard_head_limits);
const Page = html_template.Template(.{
    .View = struct { state: struct { value: []const u8 } },
    .encoded_bytes_max = 256,
    .source = html_source.SourceSpec{
        .kind = .fragment,
        .graph_name = "worker-browser-json",
        .file_path = "views/worker-browser-json.html",
        .bytes = "{{@jsonData page-state view.state}}",
    },
    .browser_json = html_render.BrowserJsonOptions{ .encoded_bytes_max = 128 },
});

fn handler(context: *Context) html_response.TemplateResponse(Page) {
    return context.html(.ok, Page, .{ .state = .{ .value = "</script><secret>" } });
}

const App = application.Application(.{
    .State = State,
    .routes = .{route.get("/", handler)},
});
const worker_limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 8,
    .pipeline_bytes_per_connection = 8,
    .response_bytes_per_request = 512,
    .response_chunk_count = 2,
    .submission_entries = 8,
    .completion_entries = 16,
});
const Storage = worker_storage.Storage(App, worker_limits);

test "worker browser JSON scratch is shared bounded and scrubbed after every render" {
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var storage: Storage = undefined;
    try storage.init(&slab);
    var state = State{};
    var workspace = App.Workspace{};
    var gzip: App.ResponseGzipWorkspace = undefined;

    for ([_]u8{ 0xa5, 0x5a }) |canary| {
        const scratch = storage.htmlJsonScratch(App.html_json_scratch_bytes_max);
        @memset(scratch, canary);
        const request = input();
        var plan = App.plan(request, &storage.route_search_workspace);
        var concrete = storage.responseChunkWriter(
            plan.finite_output.chunks.encoded_bytes_max,
        );
        defer concrete.abort();
        var writer = application_chunk_output.bind(&concrete);
        const result = try App.__prepareHeadPlannedWithChunks(
            &state,
            &workspace,
            &.{},
            &workspace.response_head_bytes,
            &plan,
            .{},
            &writer,
            scratch,
            &gzip,
        );
        const finite = result.prepared.source.finite_chain;
        try std.testing.expect(std.mem.allEqual(u8, scratch, 0));
        try expectBody(&storage, finite.body);
        storage.discardResponseChunks(finite.body);
        _ = try App.complete(&workspace);
        try std.testing.expectEqual(
            worker_limits.response_chunk_count,
            storage.response_chunks.available(),
        );
    }
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

fn expectBody(storage: *Storage, chain: anytype) !void {
    var actual: [256]u8 = undefined;
    var used: usize = 0;
    var iterator = storage.response_chunks.iterator(chain);
    while (iterator.next()) |bytes| {
        @memcpy(actual[used..][0..bytes.len], bytes);
        used += bytes.len;
    }
    try std.testing.expectEqualStrings(
        "<script type=\"application/json\" id=\"page-state\">" ++
            "{\"value\":\"\\u003c/script\\u003e\\u003csecret\\u003e\"}</script>",
        actual[0..used],
    );
}
