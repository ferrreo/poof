const std = @import("std");
const builtin = @import("builtin");
const sigbench = @import("sigbench");
const ploof = @import("../src/ploof.zig");
const request_head = @import("../src/internal/http1/request_head.zig");
const request_trailers = @import("../src/internal/http1/request_trailers.zig");
const connection_body = @import("../src/internal/runtime/connection/body.zig");
const body_driver_test = @import("../tests/unit/internal/runtime/connection_body_driver_test.zig");
const chunked_body = @import("../src/internal/runtime/connection/chunked_body.zig");
const csrf_benchmark = @import("csrf_benchmark.zig");
const gzip_decoder_pool = @import("../src/internal/runtime/gzip/decoder_pool.zig");
const gzip_fixture = @import("../tests/unit/internal/runtime/gzip_decoder_test.zig");
const gzip_request_benchmark = @import("gzip_request_benchmark.zig");
const application_html_benchmark = @import("application_html_benchmark.zig");
const asset_benchmark = @import("asset_benchmark.zig");
const live_static_benchmark = @import("live_static_benchmark.zig");
const html_render_benchmark = @import("html_render_benchmark.zig");
const html_template_benchmark = @import("html_template_benchmark.zig");
const multipart_benchmark = @import("multipart_benchmark.zig");
const multipart_dispatch_benchmark = @import("application_multipart_dispatch_benchmark.zig");
const multipart_file_sink_benchmark = @import("multipart_file_sink_benchmark.zig");
const multipart_upload_benchmark = @import("multipart_upload_benchmark.zig");
const observability_benchmark = @import("observability_benchmark.zig");
const server_clock_benchmark = @import("server_clock_benchmark.zig");
const server_lifecycle_benchmark = @import("server_lifecycle_benchmark.zig");
const input_json_benchmark = @import("input_json_benchmark.zig");
const input_json_pipeline_benchmark = @import("input_json_pipeline_benchmark.zig");
const proxy_cors_application_benchmark = @import("proxy_cors_application_benchmark.zig");
const proxy_cors_benchmark = @import("proxy_cors_benchmark.zig");
const proxy_runtime_benchmark = @import("proxy_runtime_benchmark.zig");
const request_head_benchmark = @import("request_head_benchmark.zig");
const response_gzip_benchmark = @import("response_gzip_benchmark.zig");
const response_stream_benchmark = @import("response_stream_benchmark.zig");
const route_graph_benchmark = @import("route_graph_benchmark.zig");
const url_benchmark = @import("url_benchmark.zig");
const url_for_benchmark = @import("url_for_benchmark.zig");
const worker_chunked_pool = @import("../src/internal/runtime/worker/chunked_pool.zig");

const fixed_body_payload = [_]u8{'x'} ** 4096;
const fixed_body_wire = fixed_body_payload ++ "tail";
const pipeline_tail = "NEXT";
const common_chunk_prefix = "1000\r\n";
const common_chunked_encoded =
    common_chunk_prefix ++ fixed_body_payload ++ "\r\n0\r\n\r\n";
const common_chunked_wire = common_chunked_encoded ++ pipeline_tail;

const fragmented_part_one = "alpha-bravo";
const fragmented_part_two = "charlie-delta";
const fragmented_part_three = "echo-foxtrot-golf";
const fragmented_prefix_one = "b;kind=a\r\n";
const fragmented_prefix_two = "\r\nd\r\n";
const fragmented_prefix_three = "\r\n11\r\n";
const fragmented_trailer_section =
    "X-Trace:  alpha \t\r\n" ++
    "X-Count:\t2\r\n" ++
    "\r\n";
const fragmented_chunked_encoded =
    fragmented_prefix_one ++ fragmented_part_one ++
    fragmented_prefix_two ++ fragmented_part_two ++
    fragmented_prefix_three ++ fragmented_part_three ++
    "\r\n0\r\n" ++ fragmented_trailer_section;
const fragmented_chunked_wire = fragmented_chunked_encoded ++ pipeline_tail;
const trailer_declaration_head = "TrailerX-Trace, X-Count";
const trailer_declaration_field = request_head.Field{
    .name = .{ .offset = 0, .length = "Trailer".len },
    .raw_value = .{ .offset = "Trailer".len, .length = "X-Trace, X-Count".len },
    .value = .{ .offset = "Trailer".len, .length = "X-Trace, X-Count".len },
};
const fragment_sizes = [_]u8{ 1, 2, 7, 3, 16, 4, 5, 1, 9 };
const RoutingContext = ploof.Context(void, ploof.response.standard_head_limits);

fn routeHandler(context: *RoutingContext) RoutingContext.ResponseType {
    return context.empty(.no_content);
}

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof benchmark validity check failed");
}

const RoutingApplication = ploof.Application(.{
    .State = void,
    .routes = .{
        ploof.get("/health", routeHandler),
        ploof.get("/api/v1/users", routeHandler),
        ploof.post("/api/v1/users", routeHandler),
        ploof.get("/api/v1/users/:id", routeHandler),
        ploof.patch("/api/v1/users/:id", routeHandler),
        ploof.delete("/api/v1/users/:id", routeHandler),
        ploof.get("/api/v1/projects", routeHandler),
        ploof.post("/api/v1/projects", routeHandler),
        ploof.get("/api/v1/projects/:project_id", routeHandler),
        ploof.get("/api/v1/projects/:project_id/events", routeHandler),
        ploof.post("/api/v1/projects/:project_id/events", routeHandler),
        ploof.get("/api/v1/projects/:project_id/events/:event_id", routeHandler),
    },
});

fn benchRuntimeFullHead(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runRuntimeHead(iterations, false);
        }
    }.run);
}

fn benchRuntimeFragmentedHead(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runRuntimeHead(iterations, true);
        }
    }.run);
}

fn runRuntimeHead(iterations: u64, comptime fragmented: bool) u64 {
    var harness: body_driver_test.Harness = undefined;
    harness.init() catch benchmarkFailure();
    const connection_index = harness.addConnection(1) catch benchmarkFailure();
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        if (fragmented) {
            const split = body_driver_test.ping_request.len / 2;
            _ = harness.receive(
                connection_index,
                body_driver_test.ping_request[0..split],
                false,
            ) catch benchmarkFailure();
            if (runtimeReceiveMultishot(&harness, connection_index)) benchmarkFailure();
            _ = harness.receive(
                connection_index,
                body_driver_test.ping_request[split..],
                false,
            ) catch benchmarkFailure();
        } else {
            _ = harness.receive(
                connection_index,
                body_driver_test.ping_request,
                false,
            ) catch benchmarkFailure();
        }
        harness.completeSendAll(connection_index) catch benchmarkFailure();
        harness.retireResponse(connection_index) catch benchmarkFailure();
        if (runtimeReceiveMultishot(&harness, connection_index)) benchmarkFailure();
        harness.state = .{};
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    std.mem.doNotOptimizeAway(&harness);
    return elapsed_ns;
}

fn runtimeReceiveMultishot(
    harness: *const body_driver_test.Harness,
    connection_index: u16,
) bool {
    const token = harness.storage.connections[connection_index].receive_token orelse {
        benchmarkFailure();
    };
    return switch (harness.io.operation(token) orelse benchmarkFailure()) {
        .receive => |receive| receive.multishot,
        else => benchmarkFailure(),
    };
}

const GzipBenchPool = gzip_decoder_pool.FixedPool(1, 128, 64, 2);

fn benchThreadedGzipHandoff(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runThreadedGzipHandoff(iterations, scope);
        }
    }.run);
}

fn runThreadedGzipHandoff(
    iterations: u64,
    scope: *sigbench.MeasurementScope,
) !void {
    var slots: [1]GzipBenchPool.Slot = undefined;
    var pool: GzipBenchPool = undefined;
    pool.init(&slots);
    pool.start(256 * 1024) catch benchmarkFailure();
    defer closeGzipBenchmarkPool(&pool);
    if (slots[0].counter != &pool.counter) {
        @panic("gzip benchmark moved pool after binding counter pointer");
    }
    const descriptor = pool.wakeDescriptor();
    var output: [64]u8 = undefined;
    var gzip: []const u8 = &gzip_fixture.stored_gzip;
    std.mem.doNotOptimizeAway(&gzip);
    runGzipHandoff(&pool, descriptor, &output, gzip, 0);
    try scope.includeThread(pool.workerThreadId(0) orelse benchmarkFailure());

    try scope.start();
    for (0..iterations) |iteration| {
        runGzipHandoff(&pool, descriptor, &output, gzip, @truncate(iteration +% 1));
    }
    try scope.stop();
    std.mem.doNotOptimizeAway(&output);
}

fn runGzipHandoff(
    pool: *GzipBenchPool,
    descriptor: std.os.linux.fd_t,
    output: *[64]u8,
    gzip: []const u8,
    generation: u32,
) void {
    const lease = pool.acquire(
        .{ .connection_index = 1, .request_index = 1, .generation = generation },
        output,
        .{ .encoded_max = gzip.len, .decoded_max = output.len },
    ) orelse benchmarkFailure();
    if (pool.feed(lease, gzip) catch benchmarkFailure() != .written) {
        benchmarkFailure();
    }
    pool.finish(lease) catch benchmarkFailure();
    waitGzipTerminal(pool, descriptor, lease.index);
    const result = (pool.result(lease) catch benchmarkFailure()) orelse benchmarkFailure();
    const complete = switch (result) {
        .complete => |value| value,
        else => benchmarkFailure(),
    };
    if (complete.encoded != gzip.len or
        complete.decoded != "stored-block".len or complete.members != 1)
    {
        benchmarkFailure();
    }
    if (!std.mem.eql(u8, output[0..complete.decoded], "stored-block")) benchmarkFailure();
    pool.ack(lease) catch benchmarkFailure();
    std.mem.doNotOptimizeAway(complete);
}

fn waitGzipTerminal(
    pool: *GzipBenchPool,
    descriptor: std.os.linux.fd_t,
    index: u16,
) void {
    var descriptors = [1]std.os.linux.pollfd{.{
        .fd = descriptor,
        .events = std.os.linux.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        descriptors[0].revents = 0;
        const polled = std.os.linux.poll(&descriptors, descriptors.len, 1_000);
        const errno_value = std.os.linux.errno(polled);
        if (errno_value == .INTR) continue;
        if (errno_value != .SUCCESS) {
            std.debug.panic("gzip benchmark poll failed: {t}", .{errno_value});
        }
        if (polled == 0) @panic("gzip benchmark poll timed out");
        if (polled != 1) @panic("gzip benchmark poll returned invalid count");
        if (descriptors[0].revents != std.os.linux.POLL.IN) {
            std.debug.panic(
                "gzip benchmark poll returned invalid events: 0x{x}",
                .{@as(u16, @bitCast(descriptors[0].revents))},
            );
        }
        const batch = switch (pool.consumeWake()) {
            .consumed => |value| value,
            .failed => |failure| std.debug.panic(
                "gzip benchmark eventfd drain failed: {t}/{t}",
                .{ failure.stage, failure.errno },
            ),
        };
        if (batch.slots[index].terminal) return;
    }
}

fn closeGzipBenchmarkPool(pool: *GzipBenchPool) void {
    if (pool.beginStop() != null) benchmarkFailure();
    pool.retireWakePoll() catch benchmarkFailure();
    if ((pool.finishStop() catch benchmarkFailure()) != null) benchmarkFailure();
}

fn benchRouteSelection(b: *sigbench.Bencher) void {
    b.iter(struct {
        fn run() void {
            var input = ploof.Input{
                .method = "GET",
                .path = "/api/v1/projects/alpha/events/42",
                .raw_target = "/api/v1/projects/alpha/events/42",
                .raw_path = "/api/v1/projects/alpha/events/42",
                .date = "Tue, 14 Jul 2026 12:00:00 GMT",
            };
            std.mem.doNotOptimizeAway(&input);
            var route_workspace: RoutingApplication.RouteSearchWorkspace = undefined;
            const plan = RoutingApplication.plan(input, &route_workspace);
            switch (plan.selection) {
                .selected => |selected| {
                    if (selected.route_id != 11) benchmarkFailure();
                    if (selected.capture_count != 2) benchmarkFailure();
                },
                else => benchmarkFailure(),
            }
            std.mem.doNotOptimizeAway(plan);
        }
    }.run);
}

const FixedBodyInput = struct {
    wire: []const u8,
    declared: u64,
    split: usize,
};

fn setupFixedBody() FixedBodyInput {
    var input = FixedBodyInput{
        .wire = fixed_body_wire,
        .declared = fixed_body_payload.len,
        .split = 1537,
    };
    std.mem.doNotOptimizeAway(&input);
    return input;
}

fn runFixedBody(input: *FixedBodyInput) void {
    const declared = std.math.cast(usize, input.declared) orelse benchmarkFailure();
    if (input.split == 0 or input.split >= declared) benchmarkFailure();
    if (input.wire.len != declared + "tail".len) benchmarkFailure();
    var receiver = switch (connection_body.FixedIdentity.init(
        input.declared,
        input.declared,
        input.declared,
    )) {
        .accepted => |value| value,
        .over_limit => benchmarkFailure(),
    };
    const first = receiver.feed(input.wire[0..input.split]) catch benchmarkFailure();
    if (first.body.len != input.split) benchmarkFailure();
    if (first.tail.len != 0) benchmarkFailure();
    if (first.progress != input.split) benchmarkFailure();
    if (first.complete) benchmarkFailure();

    const final = receiver.feed(input.wire[input.split..]) catch benchmarkFailure();
    if (final.body.len != declared - input.split) benchmarkFailure();
    if (final.tail.len != "tail".len) benchmarkFailure();
    if (final.progress != declared) benchmarkFailure();
    if (!final.complete or !receiver.complete()) benchmarkFailure();
    std.mem.doNotOptimizeAway(final);
}

fn benchFixedBody(b: *sigbench.Bencher) void {
    b.iterBatch(FixedBodyInput, setupFixedBody, runFixedBody, .per_iteration);
}

const PayloadSpan = struct {
    offset: usize,
    length: usize,
};

const common_payload_spans = [_]PayloadSpan{.{
    .offset = common_chunk_prefix.len,
    .length = fixed_body_payload.len,
}};
const fragmented_payload_spans = [_]PayloadSpan{
    .{ .offset = fragmented_prefix_one.len, .length = fragmented_part_one.len },
    .{
        .offset = fragmented_prefix_one.len + fragmented_part_one.len +
            fragmented_prefix_two.len,
        .length = fragmented_part_two.len,
    },
    .{
        .offset = fragmented_prefix_one.len + fragmented_part_one.len +
            fragmented_prefix_two.len + fragmented_part_two.len +
            fragmented_prefix_three.len,
        .length = fragmented_part_three.len,
    },
};

const ChunkedInput = struct {
    wire: []const u8,
    encoded_length: usize,
    decoded_length: usize,
    payload_spans: []const PayloadSpan,
    declarations: request_trailers.StandardDeclarations,
    head_bytes: []const u8,
    fragment_sizes: []const u8,
};

const BodyCursor = struct {
    span_index: usize = 0,
    span_offset: usize = 0,
    decoded: usize = 0,
};

fn setupCommonChunked() ChunkedInput {
    var input = ChunkedInput{
        .wire = common_chunked_wire,
        .encoded_length = common_chunked_encoded.len,
        .decoded_length = fixed_body_payload.len,
        .payload_spans = &common_payload_spans,
        .declarations = .{},
        .head_bytes = "",
        .fragment_sizes = &.{},
    };
    validatePayloadFixtures(&input);
    std.mem.doNotOptimizeAway(&input);
    return input;
}

fn setupFragmentedChunked() ChunkedInput {
    const declarations = request_trailers.StandardDeclarations.parse(
        &.{trailer_declaration_field},
        trailer_declaration_head,
    ) catch benchmarkFailure();
    var input = ChunkedInput{
        .wire = fragmented_chunked_wire,
        .encoded_length = fragmented_chunked_encoded.len,
        .decoded_length = fragmented_part_one.len + fragmented_part_two.len +
            fragmented_part_three.len,
        .payload_spans = &fragmented_payload_spans,
        .declarations = declarations,
        .head_bytes = trailer_declaration_head,
        .fragment_sizes = &fragment_sizes,
    };
    if (input.declarations.count() != 2) benchmarkFailure();
    validatePayloadFixtures(&input);
    std.mem.doNotOptimizeAway(&input);
    return input;
}

fn validatePayloadFixtures(input: *const ChunkedInput) void {
    var decoded: usize = 0;
    for (input.payload_spans) |span| {
        if (span.offset > input.encoded_length) benchmarkFailure();
        if (span.length > input.encoded_length - span.offset) benchmarkFailure();
        decoded += span.length;
    }
    if (decoded != input.decoded_length) benchmarkFailure();
    if (!std.mem.eql(u8, input.wire[input.encoded_length..], pipeline_tail)) {
        benchmarkFailure();
    }
}

fn validateChunkData(
    input: *const ChunkedInput,
    cursor: *BodyCursor,
    data: []const u8,
) void {
    if (data.len == 0) benchmarkFailure();
    if (cursor.span_index >= input.payload_spans.len) benchmarkFailure();
    const span = input.payload_spans[cursor.span_index];
    if (cursor.span_offset > span.length) benchmarkFailure();
    const remaining = span.length - cursor.span_offset;
    if (data.len > remaining) benchmarkFailure();
    const expected = input.wire.ptr + span.offset + cursor.span_offset;
    if (data.ptr != expected) benchmarkFailure();
    cursor.span_offset += data.len;
    cursor.decoded += data.len;
    if (cursor.span_offset == span.length) {
        cursor.span_index += 1;
        cursor.span_offset = 0;
    }
}

fn nextFragmentEnd(input: *const ChunkedInput, offset: usize, index: *usize) usize {
    if (input.fragment_sizes.len == 0) return input.wire.len;
    const fragment_length = input.fragment_sizes[index.* % input.fragment_sizes.len];
    if (fragment_length == 0) benchmarkFailure();
    index.* += 1;
    return @min(offset + fragment_length, input.wire.len);
}

fn validateChunkedReady(
    comptime declared_trailers: bool,
    input: *const ChunkedInput,
    state: *const chunked_body.State,
    cursor: BodyCursor,
    wire_offset: usize,
) void {
    if (wire_offset != input.encoded_length) benchmarkFailure();
    if (cursor.decoded != input.decoded_length) benchmarkFailure();
    if (cursor.span_index != input.payload_spans.len) benchmarkFailure();
    if (cursor.span_offset != 0) benchmarkFailure();
    if (!std.mem.eql(u8, input.wire[wire_offset..], pipeline_tail)) benchmarkFailure();
    if (state.wireBytesConsumed() != input.encoded_length) benchmarkFailure();
    if (state.decodedBytesProduced() != input.decoded_length) benchmarkFailure();
    const trailers = state.trailers() orelse benchmarkFailure();
    if (declared_trailers) {
        validateDeclaredTrailers(trailers);
    } else {
        if (!std.mem.eql(u8, trailers.bytes, "\r\n")) benchmarkFailure();
        if (trailers.fields.len != 0) benchmarkFailure();
    }
    std.mem.doNotOptimizeAway(state.wireBytesConsumed());
    std.mem.doNotOptimizeAway(state.decodedBytesProduced());
}

fn validateDeclaredTrailers(trailers: chunked_body.ReadyTrailers) void {
    if (!std.mem.eql(u8, trailers.bytes, fragmented_trailer_section)) benchmarkFailure();
    if (trailers.fields.len != 2) benchmarkFailure();
    const first = trailers.fields[0];
    const second = trailers.fields[1];
    if (!std.mem.eql(u8, first.name.slice(trailers.bytes), "X-Trace")) benchmarkFailure();
    if (!std.mem.eql(u8, first.value.slice(trailers.bytes), "alpha")) benchmarkFailure();
    if (!std.mem.eql(u8, first.raw_value.slice(trailers.bytes), "  alpha \t")) {
        benchmarkFailure();
    }
    if (!std.mem.eql(u8, second.name.slice(trailers.bytes), "X-Count")) benchmarkFailure();
    if (!std.mem.eql(u8, second.value.slice(trailers.bytes), "2")) benchmarkFailure();
    if (!std.mem.eql(u8, second.raw_value.slice(trailers.bytes), "\t2")) benchmarkFailure();
}

fn runChunked(
    comptime fragmented: bool,
    comptime declared_trailers: bool,
    input: *ChunkedInput,
) void {
    var state = chunked_body.State.init(
        input.encoded_length,
        input.decoded_length,
        input.declarations,
        input.head_bytes,
    );
    var cursor = BodyCursor{};
    var wire_offset: usize = 0;
    var fragment_index: usize = 0;
    var fragment_end = if (fragmented)
        nextFragmentEnd(input, wire_offset, &fragment_index)
    else
        input.wire.len;

    while (wire_offset < input.wire.len) {
        const result = state.feed(input.wire[wire_offset..fragment_end]);
        if (result.consumed > fragment_end - wire_offset) benchmarkFailure();
        wire_offset += result.consumed;
        switch (result.event) {
            .need_more => if (wire_offset != fragment_end) benchmarkFailure(),
            .data => |data| validateChunkData(input, &cursor, data),
            .ready => return validateChunkedReady(
                declared_trailers,
                input,
                &state,
                cursor,
                wire_offset,
            ),
            .rejected => benchmarkFailure(),
        }
        if (result.consumed == 0) benchmarkFailure();
        if (fragmented and wire_offset == fragment_end) {
            fragment_end = nextFragmentEnd(input, wire_offset, &fragment_index);
        }
    }
    benchmarkFailure();
}

fn runCommonChunked(input: *ChunkedInput) void {
    runChunked(false, false, input);
}

fn runFragmentedChunked(input: *ChunkedInput) void {
    runChunked(true, true, input);
}

fn benchCommonChunked(b: *sigbench.Bencher) void {
    b.iterBatch(ChunkedInput, setupCommonChunked, runCommonChunked, .per_iteration);
}

fn benchFragmentedChunked(b: *sigbench.Bencher) void {
    b.iterBatch(ChunkedInput, setupFragmentedChunked, runFragmentedChunked, .per_iteration);
}

const ChunkedClearInput = struct {
    free_indices: [1]u16,
    states: [1]chunked_body.State,
};

fn setupChunkedClear() ChunkedClearInput {
    var input: ChunkedClearInput = undefined;
    input.free_indices[0] = 0xa5a5;
    @memset(std.mem.asBytes(&input.states[0]), 0xa5);
    std.mem.doNotOptimizeAway(&input);
    return input;
}

fn runChunkedClear(input: *ChunkedClearInput) void {
    var pool = worker_chunked_pool.Pool(chunked_body.State, true){
        .free_indices = &input.free_indices,
        .states = &input.states,
        .pool = .{ .indices = &input.free_indices, .free_count = 0 },
    };
    worker_chunked_pool.clear(chunked_body.State, &pool, 0);
    pool.pool.release(0);
    const reused = pool.pool.acquire() orelse benchmarkFailure();
    const bytes = std.mem.asBytes(&input.states[0]);
    if (reused != 0) benchmarkFailure();
    if (pool.pool.available() != 0) benchmarkFailure();
    if (bytes[0] != 0) benchmarkFailure();
    if (bytes[bytes.len / 2] != 0) benchmarkFailure();
    if (bytes[bytes.len - 1] != 0) benchmarkFailure();
    std.mem.doNotOptimizeAway(&input.states[0]);
}

fn benchChunkedClear(b: *sigbench.Bencher) void {
    b.iterBatch(ChunkedClearInput, setupChunkedClear, runChunkedClear, .per_iteration);
}

const pure_boundaries = sigbench.groupWithId("pure", "Pure boundaries", .{
    request_head_benchmark.contiguous,
    request_head_benchmark.fragmented,
    request_head_benchmark.long_field,
    request_head_benchmark.overlong_line,
    sigbench.benchWithThroughput(
        "runtime-full-head",
        "one-shot full-head request lifecycle",
        .{ .bytes = body_driver_test.ping_request.len },
        benchRuntimeFullHead,
    ),
    sigbench.benchWithThroughput(
        "runtime-fragmented-head",
        "two one-shot head-completion request lifecycle",
        .{ .bytes = body_driver_test.ping_request.len },
        benchRuntimeFragmentedHead,
    ),
    sigbench.benchWithThroughput(
        "gzip-threaded-handoff",
        "persistent-thread gzip decode handoff",
        .{ .bytes = gzip_fixture.stored_gzip.len },
        benchThreadedGzipHandoff,
    ),
    sigbench.benchWithThroughput(
        "route-selection",
        "route selection",
        .{ .elements = 1 },
        benchRouteSelection,
    ),
    sigbench.benchWithThroughput(
        "fixed-body",
        "fragmented fixed body receiver",
        .{ .bytes = fixed_body_payload.len },
        benchFixedBody,
    ),
    sigbench.benchWithThroughput(
        "chunked-body-common",
        "4 KiB no-trailer chunked identity receiver",
        .{ .bytes = fixed_body_payload.len },
        benchCommonChunked,
    ),
    sigbench.benchWithThroughput(
        "chunked-body-fragmented-trailers",
        "fragmented multi-chunk identity receiver with declared trailers",
        .{
            .bytes = fragmented_part_one.len + fragmented_part_two.len +
                fragmented_part_three.len,
        },
        benchFragmentedChunked,
    ),
    sigbench.benchWithThroughput(
        "chunked-state-secure-clear",
        "secure clear and reuse pooled chunked state (9,736 B)",
        .{ .bytes = chunked_body.state_bytes },
        benchChunkedClear,
    ),
});

comptime {
    if (chunked_body.state_bytes != 9_736) {
        @compileError("update chunked-state benchmark label for changed state layout");
    }
}

pub fn main(init: std.process.Init) !void {
    const output_dir = switch (builtin.mode) {
        .ReleaseSafe => "zig-out/sigbench/release-safe",
        .ReleaseFast => "zig-out/sigbench/release-fast",
        else => @compileError("Ploof benchmarks require ReleaseSafe or ReleaseFast"),
    };
    try response_gzip_benchmark.writeMetricsReport(init, output_dir);
    try response_stream_benchmark.writeMetricsReport(init, output_dir);
    try application_html_benchmark.writeMetricsReport(init, output_dir);
    try multipart_benchmark.writeMetricsReport(init, output_dir);
    try multipart_upload_benchmark.writeMetricsReport(init, output_dir);
    try csrf_benchmark.writeMetricsReport(init, output_dir);
    sigbench.run(
        init,
        &.{
            pure_boundaries,
            csrf_benchmark.group,
            html_render_benchmark.group,
            html_template_benchmark.group,
            application_html_benchmark.group,
            gzip_request_benchmark.group,
            multipart_benchmark.parser_group,
            multipart_benchmark.group,
            multipart_dispatch_benchmark.classification_group,
            multipart_dispatch_benchmark.operation_group,
            multipart_upload_benchmark.group,
            multipart_file_sink_benchmark.group,
            asset_benchmark.group,
            live_static_benchmark.group,
            observability_benchmark.group,
            server_clock_benchmark.group,
            server_lifecycle_benchmark.group,
            input_json_benchmark.group,
            input_json_pipeline_benchmark.group,
            proxy_cors_application_benchmark.group,
            proxy_cors_benchmark.group,
            proxy_runtime_benchmark.group,
            response_gzip_benchmark.group,
            response_stream_benchmark.group,
            route_graph_benchmark.group,
            route_graph_benchmark.overlap_group,
            url_benchmark.group,
            url_for_benchmark.group,
        },
        .{ .output_dir = output_dir },
    ) catch |err| {
        std.debug.print("Ploof benchmark failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
