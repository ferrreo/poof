const std = @import("std");
const sigbench = @import("sigbench");
const application = @import("../src/application.zig");
const body = @import("../src/body.zig");
const endpoint = @import("../src/endpoint.zig");
const json = @import("../src/json.zig");
const query = @import("../src/query.zig");
const response = @import("../src/response.zig");
const route = @import("../src/route.zig");
const application_body = @import("../src/internal/application/body.zig");
const application_input = @import("../src/internal/application/input.zig");
const application_adapter = @import("../src/internal/runtime/application_adapter.zig");
const body_runtime = @import("../src/internal/runtime/connection/body_runtime.zig");
const connection_body = @import("../src/internal/runtime/connection/body.zig");
const runtime_config = @import("../src/internal/runtime/config.zig");
const worker_storage = @import("../src/internal/runtime/worker/storage.zig");
const request_head = @import("../src/internal/http1/request_head.zig");

const date = "Tue, 14 Jul 2026 12:00:00 GMT";
const hash_key = [_]u8{
    0x91, 0x26, 0xd8, 0x43, 0x5b, 0xae, 0x70, 0x1f,
    0x0d, 0xe4, 0x39, 0xc7, 0x68, 0xb2, 0x54, 0xfa,
};
const RequestDecoder = request_head.Decoder(.{});

const EndpointJson = struct {
    name: []const u8,
    count: u16,
    tags: []const u16,
};

const endpoint_json_wire =
    "{\"name\":\"ploof\\n\\\"bench\\u003c\",\"count\":9,\"tags\":[2,4,8]}";
const expected_name = "ploof\n\"bench<";

const FragmentQuery = struct {
    trace: []const u8,
    page: u16,
};

const BoundaryQuery = struct {
    trace: []const u8,
    page: u16,
};

const FragmentDefinition = endpoint.Endpoint(.{
    .query = query.typed(FragmentQuery, .{
        .segments_max = 2,
        .unknown_fields = .reject,
    }),
    .body = json.typed(EndpointJson, .{
        .encoded_wire_bytes_max = 128,
        .decoded_bytes_max = 128,
        .parse_memory_bytes_max = 4096,
        .depth_max = 8,
        .unknown_fields = .reject,
    }),
    .response_json_bytes_max = 1,
});

const BoundaryDefinition = endpoint.Endpoint(.{
    .query = query.typed(BoundaryQuery, .{
        .segments_max = query.standard_segments_max,
        .unknown_fields = .ignore,
    }),
    .body = json.typed(EndpointJson, .{
        .encoded_wire_bytes_max = 128,
        .decoded_bytes_max = 128,
        .parse_memory_bytes_max = 4096,
        .depth_max = 8,
        .unknown_fields = .reject,
    }),
    .response_json_bytes_max = 1,
});

const InputContext = application.Context(u8, response.standard_head_limits);
const InputResponse = InputContext.ResponseType;

fn fragmentHandler(context: *InputContext, _: FragmentDefinition.InputType) InputResponse {
    return context.empty(.no_content);
}

fn boundaryHandler(context: *InputContext, _: BoundaryDefinition.InputType) InputResponse {
    return context.empty(.no_content);
}

const fragment_handler = FragmentDefinition.handle(fragmentHandler);
const boundary_handler = BoundaryDefinition.handle(boundaryHandler);
const InputApp = application.Application(.{
    .State = u8,
    .routes = .{
        route.post("/fragmented", fragment_handler),
        route.post("/boundary", boundary_handler),
    },
});

const fragment_query_wire = "trace=request%2D7&page=3";
const boundary_query_wire = "x=&" ** (query.standard_segments_max - 2) ++
    fragment_query_wire;
const fragment_request_wire = requestWire("/fragmented", fragment_query_wire);
const boundary_request_wire = requestWire("/boundary", boundary_query_wire);

fn requestWire(comptime path: []const u8, comptime raw_query: []const u8) []const u8 {
    return "POST " ++ path ++ "?" ++ raw_query ++ " HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Content-Type: application/problem+json; charset=\"utf-8\"\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n";
}

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof full input/JSON pipeline benchmark validity check failed");
}

fn Materialized(comptime handler: anytype) type {
    return struct {
        input: application_body.Input(handler),
        query_segments: u16,
        query_fields: u16,
        matched_media: usize,
    };
}

fn admitHead(
    wire: []const u8,
    split: usize,
    decoder: *RequestDecoder,
    decoded_path: []u8,
) application_adapter.Admission(4) {
    decoder.* = RequestDecoder.init();
    const result = if (split == 0) decoder.feed(wire) else split_result: {
        if (decoder.feed(wire[0..split]).state != .need_more) benchmarkFailure();
        break :split_result decoder.feed(wire[split..]);
    };
    const head = switch (result.state) {
        .ready => |value| value,
        else => benchmarkFailure(),
    };
    return switch (application_adapter.admit(4, decoder, head, decoded_path, date)) {
        .admitted => |value| value,
        .rejected => benchmarkFailure(),
    };
}

fn materializeOne(
    comptime handler: anytype,
    decoder: *const RequestDecoder,
    admission: application_adapter.Admission(4),
    payload: []const u8,
    workspace: []u8,
    runtime_hash_key: [16]u8,
) Materialized(handler) {
    var route_workspace: InputApp.RouteSearchWorkspace = undefined;
    const route_plan = InputApp.plan(admission.input, &route_workspace);
    const selected = switch (application_adapter.admitContent(
        route_plan.body,
        admission.analysis.framing.body,
        decoder.fields(),
        decoder.bytes(),
    )) {
        .admitted => |value| value,
        else => benchmarkFailure(),
    };
    const content = selected.content orelse benchmarkFailure();
    if (selected.plan.decoderKind() != .json) benchmarkFailure();
    const decoder_index = selected.plan.selected_decoder orelse benchmarkFailure();
    const layout = application_input.workspaceLayout(@TypeOf(handler));
    if (decoder_index >= layout.body_decoders.len) benchmarkFailure();
    const body_region = layout.body_decoders[decoder_index].body;
    if (payload.len > body_region.bytes) benchmarkFailure();
    const retained = workspace[body_region.offset..][0..payload.len];
    @memcpy(retained, payload);
    const pieces = [_]body.Chunk{
        body.Chunk.init(retained[0..17]),
        body.Chunk.init(retained[17..31]),
        body.Chunk.init(retained[31..]),
    };
    const decoded = body.Bytes.init(&pieces) catch benchmarkFailure();
    const input = application_body.materializeSelected(
        handler,
        .{ .bytes = decoded },
        selected.plan.selected_decoder,
        admission.input.raw_query,
        workspace,
        runtime_hash_key,
    ) catch benchmarkFailure();
    const parsed_query = admission.analysis.query orelse benchmarkFailure();
    return .{
        .input = input,
        .query_segments = parsed_query.segments_count,
        .query_fields = parsed_query.fields_count,
        .matched_media = content.matched_pattern,
    };
}

fn InputRunner(
    comptime handler: anytype,
    comptime wire: []const u8,
    comptime head_split: usize,
    comptime expected_segments: u16,
) type {
    const layout = application_input.workspaceLayout(@TypeOf(handler));
    return struct {
        fn bench(b: *sigbench.Bencher) void {
            b.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var runtime_wire: []const u8 = wire;
            var runtime_hash_key = hash_key;
            var decoder = RequestDecoder.init();
            var decoded_path: [wire.len]u8 = undefined;
            var workspace: [layout.total_bytes_max]u8 align(layout.alignment) = undefined;
            var runtime_payload: []const u8 = endpoint_json_wire;
            var last: Materialized(handler) = undefined;
            std.mem.doNotOptimizeAway(&runtime_wire);
            std.mem.doNotOptimizeAway(&runtime_payload);
            std.mem.doNotOptimizeAway(&runtime_hash_key);
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                const admitted = admitHead(
                    runtime_wire,
                    head_split,
                    &decoder,
                    &decoded_path,
                );
                last = materializeOne(
                    handler,
                    &decoder,
                    admitted,
                    runtime_payload,
                    &workspace,
                    runtime_hash_key,
                );
                std.mem.doNotOptimizeAway(&last);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            validateInput(last, expected_segments);
            return elapsed_ns;
        }
    };
}

fn validateInput(value: anytype, expected_segments: u16) void {
    if (value.query_segments != expected_segments or
        value.query_fields != expected_segments or value.matched_media != 1)
    {
        benchmarkFailure();
    }
    if (value.input.query.page != 3 or
        !std.mem.eql(u8, value.input.query.trace, "request-7"))
    {
        benchmarkFailure();
    }
    const decoded = value.input.body;
    if (decoded.count != 9 or !std.mem.eql(u8, decoded.name, expected_name) or
        decoded.tags.len != 3 or decoded.tags[0] != 2 or decoded.tags[2] != 8)
    {
        benchmarkFailure();
    }
}

const response_staging_bytes = (runtime_config.Limits{}).response_bytes_per_request;
const response_data_bytes = response_staging_bytes + 256;
const response_data = "x" ** response_data_bytes;
const expected_response_json = "{\"id\":7,\"data\":\"" ++ response_data ++ "\"}";

const ResponseQuery = struct { id: u16 };
const ResponseDefinition = endpoint.Endpoint(.{
    .query = query.typed(ResponseQuery, .{
        .segments_max = 1,
        .unknown_fields = .reject,
    }),
    .response_json_bytes_max = expected_response_json.len,
});

const ResponseState = struct {
    calls: u64 = 0,
    input_valid: bool = true,
    encode_valid: bool = true,
    data: []const u8 = response_data,
};

const ResponseContext = application.Context(ResponseState, response.standard_head_limits);
const ResponseValue = ResponseContext.ResponseType;

fn responseHandler(context: *ResponseContext, input: ResponseDefinition.InputType) ResponseValue {
    context.state.calls += 1;
    context.state.input_valid = context.state.input_valid and input.query.id == 7;
    return context.json(.ok, .{ .id = input.query.id, .data = context.state.data }) catch {
        context.state.encode_valid = false;
        return context.empty(.internal_server_error);
    };
}

const response_handler = ResponseDefinition.handle(responseHandler);
const ResponseApp = application.Application(.{
    .State = ResponseState,
    .response_gzip = application.ResponseGzip{
        .minimum_bytes = 0,
        .level = .fastest,
    },
    .routes = .{route.get("/response", response_handler)},
});

const response_limits = runtime_config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .body_workspace_slots = 1,
    .chunked_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 128,
    .pipeline_bytes_per_connection = 128,
    .submission_entries = 8,
    .completion_entries = 16,
});
const ResponseStorage = worker_storage.Storage(ResponseApp, response_limits);

fn responseInput(comptime gzip: bool) application.Input {
    return .{
        .method = "GET",
        .path = "/response",
        .raw_target = "/response?id=7",
        .raw_path = "/response",
        .raw_query = "id=7",
        .date = date,
        .accept_encoding = if (gzip)
            .{ .gzip = 1000, .identity = 0 }
        else
            .{ .gzip = 0, .identity = 1000 },
    };
}

fn runResponse(iterations: u64, comptime gzip: bool) u64 {
    if (iterations == 0) benchmarkFailure();
    var slab: [ResponseStorage.required_bytes]u8 align(ResponseStorage.slab_alignment) = undefined;
    var storage: ResponseStorage = undefined;
    storage.init(&slab) catch benchmarkFailure();
    const connection = storage.acquireConnection(.{ .value = 41 }) orelse benchmarkFailure();
    var input = responseInput(gzip);
    var route_workspace: ResponseApp.RouteSearchWorkspace = undefined;
    var plan = ResponseApp.plan(input, &route_workspace);
    const request = switch (storage.acquireRequestClassified(
        connection,
        plan.body.workspace_class,
        false,
    )) {
        .acquired => |value| value,
        else => benchmarkFailure(),
    };
    var state = ResponseState{};
    std.mem.doNotOptimizeAway(&input);
    std.mem.doNotOptimizeAway(&plan);
    std.mem.doNotOptimizeAway(&state.data);
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        runResponseOnce(&storage, request, &state, &plan);
        std.mem.doNotOptimizeAway(storage.responseReadable(request));
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    validateResponse(&storage, request, state, iterations, gzip);
    storage.releaseRequest(connection, request);
    return elapsed_ns;
}

fn runResponseOnce(
    storage: *ResponseStorage,
    request: u16,
    state: *ResponseState,
    plan: *const ResponseApp.Plan,
) void {
    const request_workspace = storage.bodyWorkspace(request) catch benchmarkFailure();
    const head = ResponseApp.prepareHeadPlannedIn(
        state,
        &storage.requests[request].workspace,
        request_workspace,
        storage.responseWritable(request),
        plan,
        .{},
    ) catch benchmarkFailure();
    switch (head) {
        .receive_body => |selected| if (selected.kind != .input) benchmarkFailure(),
        .prepared => benchmarkFailure(),
    }
    const receiver = switch (connection_body.FixedIdentity.init(0, 0, 0)) {
        .accepted => |value| value,
        .over_limit => benchmarkFailure(),
    };
    body_runtime.startFixed(storage, request, receiver, .none) catch benchmarkFailure();
    const finished = body_runtime.finish(ResponseApp, storage, request) catch benchmarkFailure();
    if (finished.event != .prepared or finished.close_connection) benchmarkFailure();
    _ = ResponseApp.complete(&storage.requests[request].workspace) catch benchmarkFailure();
}

fn validateResponse(
    storage: *const ResponseStorage,
    request: u16,
    state: ResponseState,
    iterations: u64,
    comptime gzip: bool,
) void {
    if (state.calls != iterations or !state.input_valid or !state.encode_valid) {
        benchmarkFailure();
    }
    if (storage.responseSource(request) != .body_workspace) benchmarkFailure();
    const wire = storage.responseReadable(request);
    const marker = std.mem.indexOf(u8, wire, "\r\n\r\n") orelse benchmarkFailure();
    const head = wire[0 .. marker + 4];
    const encoded = wire[marker + 4 ..];
    if (std.mem.indexOf(u8, head, "content-type: application/json; charset=utf-8\r\n") == null) {
        benchmarkFailure();
    }
    if (contentLength(head) != encoded.len or
        std.mem.indexOf(u8, head, "vary: Accept-Encoding\r\n") == null)
    {
        benchmarkFailure();
    }
    if (!gzip) {
        if (std.mem.indexOf(u8, head, "content-encoding: gzip\r\n") != null or
            !std.mem.eql(u8, encoded, expected_response_json))
        {
            benchmarkFailure();
        }
        return;
    }
    if (std.mem.indexOf(u8, head, "content-encoding: gzip\r\n") == null) {
        benchmarkFailure();
    }
    var decoded: [expected_response_json.len]u8 = undefined;
    var input_reader = std.Io.Reader.fixed(encoded);
    var decoder = std.compress.flate.Decompress.init(&input_reader, .gzip, &.{});
    var writer = std.Io.Writer.fixed(&decoded);
    const written = decoder.reader.streamRemaining(&writer) catch benchmarkFailure();
    if (written != expected_response_json.len or
        !std.mem.eql(u8, decoded[0..written], expected_response_json))
    {
        benchmarkFailure();
    }
}

fn contentLength(head: []const u8) usize {
    const prefix = "content-length: ";
    const start = (std.mem.indexOf(u8, head, prefix) orelse benchmarkFailure()) + prefix.len;
    const end = std.mem.indexOfPos(u8, head, start, "\r\n") orelse benchmarkFailure();
    return std.fmt.parseUnsigned(usize, head[start..end], 10) catch benchmarkFailure();
}

fn benchResponseIdentity(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runResponse(iterations, false);
        }
    }.run);
}

fn benchResponseGzip(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runResponse(iterations, true);
        }
    }.run);
}

const FragmentRunner = InputRunner(
    fragment_handler,
    fragment_request_wire,
    fragment_request_wire.len / 2,
    2,
);
const BoundaryRunner = InputRunner(
    boundary_handler,
    boundary_request_wire,
    0,
    query.standard_segments_max,
);

pub const group = sigbench.groupWithId(
    "m6-input-json-pipeline",
    "M6 production input and JSON response pipeline",
    .{
        sigbench.benchWithThroughput(
            "fragmented-escaped-full-input",
            "fragmented escaped full Endpoint input path",
            .{ .bytes = fragment_request_wire.len + endpoint_json_wire.len },
            FragmentRunner.bench,
        ),
        sigbench.benchWithThroughput(
            "standard-limit-full-input",
            "1,000-segment standard-limit full Endpoint input path",
            .{ .bytes = boundary_request_wire.len + endpoint_json_wire.len },
            BoundaryRunner.bench,
        ),
        sigbench.benchWithThroughput(
            "external-json-identity",
            "near-capacity Endpoint JSON serialize and external identity commit",
            .{ .bytes = expected_response_json.len },
            benchResponseIdentity,
        ),
        sigbench.benchWithThroughput(
            "external-json-gzip",
            "near-capacity Endpoint JSON serialize and external gzip commit",
            .{ .bytes = expected_response_json.len },
            benchResponseGzip,
        ),
    },
);
