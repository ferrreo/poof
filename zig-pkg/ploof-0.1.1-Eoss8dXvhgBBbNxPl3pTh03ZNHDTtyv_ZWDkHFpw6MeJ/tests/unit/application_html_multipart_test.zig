const std = @import("std");
const application = @import("../../src/application.zig");
const application_chunk_output = @import("../../src/internal/application/chunk_output.zig");
const endpoint = @import("../../src/endpoint.zig");
const html_response = @import("../../src/html/response.zig");
const html_source = @import("../../src/html/source.zig");
const html_template = @import("../../src/html/template.zig");
const multipart = @import("../../src/multipart.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const worker_response_chunks = @import("../../src/internal/runtime/worker/response_chunks.zig");

const boundary = "html-boundary";
const body_limits = multipart.Limits.validate(.{
    .encoded_wire_bytes_max = 1024,
    .total_body_bytes_max = 512,
    .file_bytes_max = 128,
    .field_bytes_max = 32,
    .parts_max = 2,
    .files_max = 1,
    .part_headers_max = 3,
    .part_header_bytes_max = 256,
    .disposition_parameters_max = 4,
    .delimiter_transport_padding_bytes_max = 8,
    .name_bytes_max = 16,
    .filename_bytes_max = 32,
    .boundary_bytes_max = 16,
});
const MultipartBody = multipart.decode(.{
    .upload = multipart.file(multipart.DiscardSink, multipart.required),
}, .{ .limits = body_limits });
const Definition = endpoint.Endpoint(.{ .body = MultipartBody });
const Spec = @TypeOf(MultipartBody);
const State = struct { completed: bool = false };
const Context = application.Context(State, response.standard_head_limits);
const Response = Context.ResponseType;
const Page = html_template.Template(.{
    .View = struct { message: []const u8 },
    .encoded_bytes_max = 64,
    .source = html_source.SourceSpec{
        .kind = .fragment,
        .graph_name = "multipart-html",
        .file_path = "views/multipart.html",
        .bytes = "<p>{{view.message}}</p>",
    },
});

const Consumer = struct {
    pub const State = void;

    pub fn fileStart(
        _: Consumer,
        _: *Context,
        _: *Consumer.State,
        _: Spec.FileStart,
    ) Spec.FileAdmission(Response) {
        return .{ .accept = .{ .upload = {} } };
    }

    pub fn complete(
        _: Consumer,
        context: *Context,
        _: *Consumer.State,
        _: Definition.InputType,
        summaries: Spec.Summaries,
    ) multipart.Decision(html_response.TemplateResponse(Page)) {
        context.state.completed = summaries.upload.slice().len == 1;
        return multipart.commit(context.html(.created, Page, .{ .message = "stored" }));
    }
};

const App = application.Application(.{
    .State = State,
    .routes = .{route.post("/upload", Definition.handle(Consumer{}))},
});
const Pool = worker_response_chunks.Pool(16);
const request_workspace_bytes: usize = @intCast(App.body_workspace_bytes_max);
const body_bytes =
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"upload\"; filename=\"a.txt\"\r\n" ++
    "Content-Type: text/plain\r\n\r\n" ++
    "file-data\r\n" ++
    "--" ++ boundary ++ "--\r\n";

test "multipart file finalization can commit a typed HTML chunk chain" {
    var state = State{};
    var workspace = App.Workspace{};
    var request_workspace: [request_workspace_bytes]u8 align(App.body_workspace_alignment) =
        undefined;
    var registry = App.UploadRegistry{};
    var indices: [16]u16 = undefined;
    var nodes: [16]worker_response_chunks.Node = undefined;
    var storage: [16 * 16]u8 = undefined;
    var pool = try Pool.init(&indices, &nodes, &storage);
    var gzip: App.ResponseGzipWorkspace = undefined;
    var scratch: [App.html_json_scratch_bytes_max]u8 = undefined;

    const request = input();
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var plan = App.plan(request, &route_workspace);
    try App.__refinePlanBody(
        &plan,
        plan.body.selectMedia(0) orelse return error.TestUnexpectedResult,
    );
    var head_concrete = pool.writer(plan.finite_output.chunks.encoded_bytes_max);
    defer head_concrete.abort();
    var head_writer = application_chunk_output.bind(&head_concrete);
    const head = try App.__prepareHeadPlannedWithChunks(
        &state,
        &workspace,
        &request_workspace,
        &workspace.response_head_bytes,
        &plan,
        .{},
        &head_writer,
        &scratch,
        &gzip,
    );
    try std.testing.expect(head == .receive_body);
    try App.__beginMultipart(&workspace, &request_workspace, boundary, &registry);
    try App.__feedMultipart(&workspace, &request_workspace, body_bytes);
    try App.__finishMultipart(&workspace, &request_workspace);

    var body_concrete = pool.writer(plan.finite_output.chunks.encoded_bytes_max);
    defer body_concrete.abort();
    var body_writer = application_chunk_output.bind(&body_concrete);
    const prepared = try App.__prepareBodyWithChunks(
        &workspace,
        .none,
        .{},
        &request_workspace,
        [_]u8{0} ** 16,
        &workspace.response_head_bytes,
        &body_writer,
        &scratch,
        &gzip,
    );
    try std.testing.expectEqual(.complete, try App.__startMultipartFinalization(
        &workspace,
        &request_workspace,
    ));
    const finite = prepared.source.finite_chain;
    try std.testing.expectEqual(response.Status.created, prepared.status);
    try expectBody(&pool, finite.body, "<p>stored</p>");
    try std.testing.expect(state.completed);
    pool.release(finite.body);
    _ = try App.complete(&workspace);
    try std.testing.expectEqual(@as(u16, 16), pool.available());
}

fn input() application.Input {
    return .{
        .method = "POST",
        .path = "/upload",
        .raw_target = "/upload",
        .raw_path = "/upload",
        .date = "Thu, 16 Jul 2026 12:00:00 GMT",
    };
}

fn expectBody(pool: *Pool, chain: worker_response_chunks.Chain, expected: []const u8) !void {
    var actual: [64]u8 = undefined;
    var used: usize = 0;
    var iterator = pool.iterator(chain);
    while (iterator.next()) |bytes| {
        @memcpy(actual[used..][0..bytes.len], bytes);
        used += bytes.len;
    }
    try std.testing.expectEqualStrings(expected, actual[0..used]);
}
