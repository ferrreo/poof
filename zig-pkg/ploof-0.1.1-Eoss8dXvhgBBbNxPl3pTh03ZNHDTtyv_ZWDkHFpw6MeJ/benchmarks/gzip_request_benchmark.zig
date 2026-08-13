const std = @import("std");
const sigbench = @import("sigbench");
const body_driver_test = @import("../tests/unit/internal/runtime/connection_body_driver_test.zig");
const gzip_driver_test = @import("../tests/unit/internal/runtime/connection_gzip_driver_test.zig");
const gzip_decoder_pool = @import("../src/internal/runtime/gzip/decoder_pool.zig");
const gzip_fixture = @import("../tests/unit/internal/runtime/gzip_decoder_test.zig");

fn storedGzip(comptime payload: []const u8) [payload.len + 23]u8 {
    @setEvalBranchQuota(1_000_000);
    comptime std.debug.assert(payload.len <= std.math.maxInt(u16));
    var result = [_]u8{0} ** (payload.len + 23);
    const header = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
    };
    @memcpy(result[0..header.len], &header);
    result[10] = 0x01;
    const length: u16 = @intCast(payload.len);
    std.mem.writeInt(u16, result[11..13], length, .little);
    std.mem.writeInt(u16, result[13..15], ~length, .little);
    @memcpy(result[15..][0..payload.len], payload);
    const trailer = 15 + payload.len;
    std.mem.writeInt(u32, result[trailer..][0..4], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, result[trailer + 4 ..][0..4], @intCast(payload.len), .little);
    return result;
}

const gzip_abcdef = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x4b, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x03, 0x00,
    0xef, 0x39, 0x8e, 0x4b, 0x06, 0x00, 0x00, 0x00,
};
const gzip_twelve = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x4b, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x4b, 0xcf,
    0xc8, 0xcc, 0xca, 0xce, 0x01, 0x00, 0x24, 0x1b, 0x78,
    0xf6, 0x0c, 0x00, 0x00, 0x00,
};
const fixed_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Content-Length: 26\r\n\r\n";
const fixed_wire = fixed_head ++ gzip_abcdef;
const chunked_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Trailer: X-Check\r\n\r\n";
const chunked_wire = chunked_head ++ "1a\r\n" ++ gzip_abcdef ++
    "\r\n0\r\nX-Check:  first \t\r\nx-CHECK:\tsecond\r\n\r\n";
const malformed_wire =
    "POST /echo HTTP/1.1\r\nHost: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\nContent-Length: 4\r\n\r\nnope";
const limit_wire =
    "POST /echo HTTP/1.1\r\nHost: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\nContent-Length: 32\r\n\r\n" ++ gzip_twelve;
const large_payload = [_]u8{'a'} ** body_driver_test.large_body_decoded_bytes_max;
const large_gzip = storedGzip(&large_payload);
const large_fixed_head =
    "POST /large HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Content-Length: 61463\r\n\r\n";
const large_fixed_wire = large_fixed_head ++ large_gzip;
const large_chunked_head =
    "POST /large HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Trailer: X-Check\r\n\r\n";
const large_chunked_wire = large_chunked_head ++ "f017\r\n" ++ large_gzip ++
    "\r\n0\r\nX-Check:  first \t\r\nx-CHECK:\tsecond\r\n\r\n";
const multipart_gzip = storedGzip(body_driver_test.multipart_body);
const multipart_large_gzip = storedGzip(body_driver_test.multipart_large_body);
const multipart_fixed_head = std.fmt.comptimePrint(
    "POST /multipart HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Content-Type: multipart/form-data; boundary={s}\r\n" ++
        "Content-Encoding: gzip\r\n" ++
        "Content-Length: {d}\r\n\r\n",
    .{ body_driver_test.multipart_boundary, multipart_gzip.len },
);
const multipart_fixed_wire = multipart_fixed_head ++ multipart_gzip;
const multipart_large_head = std.fmt.comptimePrint(
    "POST /multipart HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Content-Type: multipart/form-data; boundary={s}\r\n" ++
        "Content-Encoding: gzip\r\n" ++
        "Content-Length: {d}\r\n\r\n",
    .{ body_driver_test.multipart_boundary, multipart_large_gzip.len },
);
const multipart_large_wire = multipart_large_head ++ multipart_large_gzip;
const contention_gzip = gzip_fixture.concatenated_gzip;
const contention_expected = "stored-block" ++ "fixed Huffman stream: zig zig zig zig";
const ContentionPool = gzip_decoder_pool.FixedPool(2, 256, 32, 2);
const contention_decoded_bytes = contention_expected.len;
const contention_output_bytes = contention_decoded_bytes + 1;

comptime {
    if (large_gzip.len != 61_463) @compileError("large gzip fixture length changed");
    if (large_gzip.len > body_driver_test.large_body_encoded_bytes_max) {
        @compileError("large gzip fixture exceeds benchmark route limit");
    }
}

const Case = enum {
    fixed_contiguous,
    fixed_fragmented,
    chunked_trailers,
    large_fixed,
    large_chunked,
    multipart_fixed,
    multipart_large,
    malformed,
    decoded_limit,
};

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof request-gzip benchmark validity check failed");
}

fn benchFixed(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runDriver(iterations, scope, .fixed_contiguous);
        }
    }.run);
}

fn benchFragmented(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runDriver(iterations, scope, .fixed_fragmented);
        }
    }.run);
}

fn benchChunked(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runDriver(iterations, scope, .chunked_trailers);
        }
    }.run);
}

fn benchLargeFixed(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runDriver(iterations, scope, .large_fixed);
        }
    }.run);
}

fn benchLargeChunked(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runDriver(iterations, scope, .large_chunked);
        }
    }.run);
}

fn benchMultipartFixed(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runDriver(iterations, scope, .multipart_fixed);
        }
    }.run);
}

fn benchMultipartLarge(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runDriver(iterations, scope, .multipart_large);
        }
    }.run);
}

fn benchMalformed(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runDriver(iterations, scope, .malformed);
        }
    }.run);
}

fn benchLimit(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runDriver(iterations, scope, .decoded_limit);
        }
    }.run);
}

fn runDriver(
    iterations: u64,
    scope: *sigbench.MeasurementScope,
    comptime case: Case,
) !void {
    var harness: gzip_driver_test.GzipHarness = undefined;
    harness.init() catch benchmarkFailure();
    defer harness.deinit();
    const rejected = case == .malformed or case == .decoded_limit;
    var wire: []const u8 = requestWire(case);
    std.mem.doNotOptimizeAway(&wire);
    var connection: u16 = if (rejected)
        undefined
    else
        harness.base.addConnection(200) catch benchmarkFailure();
    if (rejected) {
        connection = harness.base.addConnection(199) catch benchmarkFailure();
        _ = driveRequest(&harness, connection, wire, case);
        finishRejected(&harness, connection, case);
    } else {
        runSuccessIteration(&harness, connection, wire, case);
    }
    try includeStartedWorkers(scope, harness.pool());

    try scope.start();
    for (0..iterations) |iteration| {
        if (rejected) {
            connection = harness.base.addConnection(200 +% iteration) catch benchmarkFailure();
            _ = driveRequest(&harness, connection, wire, case);
            finishRejected(&harness, connection, case);
        } else {
            runSuccessIteration(&harness, connection, wire, case);
        }
    }
    try scope.stop();
    std.mem.doNotOptimizeAway(&harness.base.state);
}

fn runSuccessIteration(
    harness: *gzip_driver_test.GzipHarness,
    connection: u16,
    wire: []const u8,
    comptime case: Case,
) void {
    const outputs_before = harness.output_dispatches;
    const pauses = driveRequest(harness, connection, wire, case);
    if ((case == .large_fixed or case == .large_chunked) and pauses == 0) {
        benchmarkFailure();
    }
    if (case == .multipart_large and
        harness.output_dispatches -% outputs_before < 2) benchmarkFailure();
    if (case == .multipart_fixed or case == .multipart_large) {
        finishMultipartSuccess(harness, connection);
    } else {
        const trailers = case == .chunked_trailers or case == .large_chunked;
        finishSuccess(harness, connection, trailers, decodedLength(case));
    }
}

fn driveRequest(
    harness: *gzip_driver_test.GzipHarness,
    connection: u16,
    wire: []const u8,
    comptime case: Case,
) u32 {
    var pauses: u32 = 0;
    switch (case) {
        .fixed_contiguous => {
            _ = harness.base.receive(connection, wire, false) catch benchmarkFailure();
        },
        .fixed_fragmented => {
            const split = fixed_head.len + 10;
            _ = harness.base.receive(connection, wire[0..split], false) catch benchmarkFailure();
            _ = harness.base.receive(connection, wire[split..], false) catch benchmarkFailure();
        },
        .chunked_trailers => {
            _ = harness.base.receive(connection, wire, false) catch benchmarkFailure();
        },
        .large_fixed, .large_chunked, .multipart_large => {
            pauses = feedWindowed(harness, connection, wire);
        },
        .multipart_fixed => {
            _ = harness.base.receive(connection, wire, false) catch benchmarkFailure();
        },
        .malformed, .decoded_limit => {
            _ = harness.base.receive(connection, wire, false) catch benchmarkFailure();
        },
    }
    harness.dispatchUntilIdle() catch benchmarkFailure();
    return pauses;
}

fn requestWire(comptime case: Case) []const u8 {
    return switch (case) {
        .fixed_contiguous, .fixed_fragmented => fixed_wire,
        .chunked_trailers => chunked_wire,
        .large_fixed => large_fixed_wire,
        .large_chunked => large_chunked_wire,
        .multipart_fixed => multipart_fixed_wire,
        .multipart_large => multipart_large_wire,
        .malformed => malformed_wire,
        .decoded_limit => limit_wire,
    };
}

fn includeStartedWorkers(scope: *sigbench.MeasurementScope, pool: anytype) !void {
    const Pool = @TypeOf(pool.*);
    for (0..Pool.slots_len) |index| {
        try scope.includeThread(pool.workerThreadId(index) orelse benchmarkFailure());
    }
}

fn feedWindowed(
    harness: *gzip_driver_test.GzipHarness,
    connection: u16,
    wire: []const u8,
) u32 {
    var offset: usize = 0;
    var pauses: u32 = 0;
    while (offset < wire.len) {
        const record = &harness.base.storage.connections[connection];
        if (record.receive_token == null) {
            if (!record.receive_flags.gzip_paused) benchmarkFailure();
            pauses += 1;
            harness.dispatchOne() catch benchmarkFailure();
            continue;
        }
        const end = @min(offset + body_driver_test.test_limits.receive_buffer_bytes, wire.len);
        _ = harness.base.receive(connection, wire[offset..end], false) catch benchmarkFailure();
        offset = end;
    }
    return pauses;
}

fn decodedLength(comptime case: Case) usize {
    return switch (case) {
        .large_fixed, .large_chunked => large_payload.len,
        .fixed_contiguous, .fixed_fragmented, .chunked_trailers => 6,
        .multipart_fixed, .multipart_large, .malformed, .decoded_limit => 0,
    };
}

fn finishMultipartSuccess(harness: *gzip_driver_test.GzipHarness, connection: u16) void {
    const state = &harness.base.state;
    if (state.multipart_calls != 1 or state.multipart_count != 23) benchmarkFailure();
    if (!std.mem.endsWith(
        u8,
        harness.base.sendBytes(connection),
        "\r\n\r\nmultipart-ok",
    )) benchmarkFailure();
    const active = harness.base.storage.connections[connection].active_request orelse {
        benchmarkFailure();
    };
    if (harness.base.storage.requests[active].body.used != 0) benchmarkFailure();
    harness.base.completeSendAll(connection) catch benchmarkFailure();
    harness.base.retireResponse(connection) catch benchmarkFailure();
    if (state.after_calls != 1 or state.completed != 1 or state.aborted != 0) {
        benchmarkFailure();
    }
    validateResources(harness);
    const record = harness.base.storage.connections[connection];
    if (record.phase != .keepalive_idle or record.active_request != null) benchmarkFailure();
    harness.base.state = .{};
}

fn finishSuccess(
    harness: *gzip_driver_test.GzipHarness,
    connection: u16,
    trailers: bool,
    decoded_length: usize,
) void {
    const state = &harness.base.state;
    if (state.body_calls != 1 or state.body_length != decoded_length) {
        benchmarkFailure();
    }
    if (state.body_is_abcdef != (decoded_length == 6)) benchmarkFailure();
    if (state.body_saw_trailers != trailers) benchmarkFailure();
    if (!std.mem.endsWith(u8, harness.base.sendBytes(connection), "\r\n\r\nbody-ok")) {
        benchmarkFailure();
    }
    harness.base.completeSendAll(connection) catch benchmarkFailure();
    harness.base.retireResponse(connection) catch benchmarkFailure();
    if (state.after_calls != 1 or state.completed != 1 or state.aborted != 0) {
        benchmarkFailure();
    }
    if (state.after_saw_trailers != trailers) benchmarkFailure();
    validateResources(harness);
    const record = harness.base.storage.connections[connection];
    if (record.phase != .keepalive_idle or record.active_request != null) benchmarkFailure();
    if (record.receive_token == null or record.receive_flags.gzip_paused) benchmarkFailure();
    harness.base.state = .{};
}

fn finishRejected(
    harness: *gzip_driver_test.GzipHarness,
    connection: u16,
    comptime case: Case,
) void {
    const status = switch (case) {
        .malformed => "HTTP/1.1 400 Bad Request\r\n",
        .decoded_limit => "HTTP/1.1 413 Payload Too Large\r\n",
        else => unreachable,
    };
    if (!std.mem.startsWith(u8, harness.base.sendBytes(connection), status)) {
        benchmarkFailure();
    }
    if (harness.base.state.body_calls != 0 or
        !harness.base.storage.connections[connection].close_after_response)
    {
        benchmarkFailure();
    }
    harness.base.completeSendAll(connection) catch benchmarkFailure();
    harness.base.drainClosing(connection) catch benchmarkFailure();
    if (harness.base.state.after_calls != 1 or
        harness.base.state.completed != 1 or harness.base.state.aborted != 0)
    {
        benchmarkFailure();
    }
    validateResources(harness);
    if (harness.base.storage.connections[connection].phase != .free) benchmarkFailure();
    harness.base.state = .{};
}

fn validateResources(harness: *gzip_driver_test.GzipHarness) void {
    const storage = &harness.base.storage;
    const pool = harness.pool();
    if (pool.activeJobs() != 0 or
        pool.available() != body_driver_test.test_limits.gzip.decoder_slots)
    {
        benchmarkFailure();
    }
    if (storage.bodyWorkspaceAvailable() !=
        body_driver_test.test_limits.body_workspace_slots) benchmarkFailure();
    if (storage.chunkedWorkspaceAvailable() !=
        body_driver_test.test_limits.chunked_workspace_slots) benchmarkFailure();
    for (storage.requests) |request| {
        if (request.phase != .free) benchmarkFailure();
    }
}

fn benchTwoSlotMultistream(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runTwoSlotMultistream(iterations, scope);
        }
    }.run);
}

fn runTwoSlotMultistream(
    iterations: u64,
    scope: *sigbench.MeasurementScope,
) !void {
    var slots: [2]ContentionPool.Slot = undefined;
    var pool: ContentionPool = undefined;
    pool.init(&slots);
    pool.start(256 * 1024) catch |err| {
        std.debug.panic("two-slot gzip benchmark start failed: {s}", .{@errorName(err)});
    };
    defer closeContentionPool(&pool);
    const descriptor = pool.wakeDescriptor();
    var outputs: [2][contention_output_bytes]u8 = undefined;
    var gzip: []const u8 = &contention_gzip;
    std.mem.doNotOptimizeAway(&gzip);
    runContentionIteration(&pool, descriptor, &outputs, gzip, 0);
    try includeStartedWorkers(scope, &pool);

    try scope.start();
    for (0..iterations) |iteration| {
        runContentionIteration(
            &pool,
            descriptor,
            &outputs,
            gzip,
            @truncate(iteration +% 1),
        );
    }
    try scope.stop();
    std.mem.doNotOptimizeAway(&outputs);
}

fn runContentionIteration(
    pool: *ContentionPool,
    descriptor: std.os.linux.fd_t,
    outputs: *[2][contention_output_bytes]u8,
    gzip: []const u8,
    generation: u32,
) void {
    var leases: [2]gzip_decoder_pool.Lease = undefined;
    for (&leases, 0..) |*lease, index| {
        lease.* = pool.acquire(
            .{
                .connection_index = @intCast(index),
                .request_index = @intCast(index),
                .generation = generation,
            },
            &outputs[index],
            .{
                .encoded_max = gzip.len + 4,
                .decoded_max = contention_output_bytes,
            },
        ) orelse std.debug.panic(
            "two-slot gzip acquire {d} failed: available={d} jobs={d} lifecycle={t}",
            .{ index, pool.available(), pool.activeJobs(), pool.lifecycleStatus() },
        );
    }
    if (pool.available() != 0 or pool.activeJobs() != 2) benchmarkFailure();
    for (leases) |lease| {
        if (pool.feed(lease, gzip) catch benchmarkFailure() != .written) {
            benchmarkFailure();
        }
    }
    for (leases) |lease| pool.finish(lease) catch benchmarkFailure();
    waitContentionTerminals(pool, descriptor, leases);
    for (leases, outputs) |lease, *output| {
        validateContentionResult(pool, lease, output, gzip.len);
        pool.ack(lease) catch benchmarkFailure();
    }
    if (pool.available() != 2 or pool.activeJobs() != 0) {
        std.debug.panic(
            "two-slot gzip reuse failed: available={d} jobs={d}",
            .{ pool.available(), pool.activeJobs() },
        );
    }
}

fn waitContentionTerminals(
    pool: *ContentionPool,
    descriptor: std.os.linux.fd_t,
    leases: [2]gzip_decoder_pool.Lease,
) void {
    var terminal = [_]bool{false} ** 2;
    while (!terminal[0] or !terminal[1]) {
        const batch = waitContentionBatch(pool, descriptor);
        for (leases, 0..) |lease, index| {
            terminal[index] = terminal[index] or batch.slots[lease.index].terminal;
        }
    }
}

fn waitContentionBatch(
    pool: *ContentionPool,
    descriptor: std.os.linux.fd_t,
) ContentionPool.WakeBatch {
    var descriptors = [1]std.os.linux.pollfd{.{
        .fd = descriptor,
        .events = std.os.linux.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        descriptors[0].revents = 0;
        const count = std.os.linux.poll(&descriptors, descriptors.len, 5_000);
        const errno_value = std.os.linux.errno(count);
        if (errno_value == .INTR) continue;
        if (errno_value != .SUCCESS or count != 1 or
            descriptors[0].revents != std.os.linux.POLL.IN) benchmarkFailure();
        return switch (pool.consumeWake()) {
            .consumed => |batch| batch,
            .failed => benchmarkFailure(),
        };
    }
}

fn validateContentionResult(
    pool: *ContentionPool,
    lease: gzip_decoder_pool.Lease,
    output: *[contention_output_bytes]u8,
    encoded_bytes: usize,
) void {
    const result = (pool.result(lease) catch benchmarkFailure()) orelse benchmarkFailure();
    const complete = switch (result) {
        .complete => |value| value,
        .over_limit => |limit| std.debug.panic(
            "two-slot gzip benchmark exceeded {t} limit",
            .{limit},
        ),
        .malformed => @panic("two-slot gzip benchmark decoded malformed input"),
        .read_failed => @panic("two-slot gzip benchmark read failed"),
        .canceled => @panic("two-slot gzip benchmark was canceled"),
    };
    if (complete.encoded != encoded_bytes or
        complete.decoded != contention_decoded_bytes or complete.members != 2)
    {
        benchmarkFailure();
    }
    if (!std.mem.eql(u8, output[0..contention_decoded_bytes], contention_expected)) {
        benchmarkFailure();
    }
}

fn closeContentionPool(pool: *ContentionPool) void {
    if (pool.beginStop()) |failure| {
        std.debug.panic(
            "two-slot gzip benchmark join failed: {t}/{t}",
            .{ failure.stage, failure.errno },
        );
    }
    pool.retireWakePoll() catch |err| {
        std.debug.panic("two-slot gzip poll retirement failed: {s}", .{@errorName(err)});
    };
    const failure = pool.finishStop() catch |err| {
        std.debug.panic("two-slot gzip stop failed: {s}", .{@errorName(err)});
    };
    if (failure) |problem| {
        std.debug.panic(
            "two-slot gzip counter close failed: {t}/{t}",
            .{ problem.stage, problem.errno },
        );
    }
}

pub const group = sigbench.groupWithId(
    "gzip-request-driver",
    "Production request-gzip driver",
    .{
        sigbench.benchWithThroughput(
            "fixed-contiguous",
            "keepalive fixed gzip request, contiguous wire",
            .{ .bytes = fixed_wire.len },
            benchFixed,
        ),
        sigbench.benchWithThroughput(
            "fixed-fragmented",
            "keepalive fixed gzip request, two receive completions",
            .{ .bytes = fixed_wire.len },
            benchFragmented,
        ),
        sigbench.benchWithThroughput(
            "chunked-trailers",
            "keepalive chunked gzip request with declared trailers",
            .{ .bytes = chunked_wire.len },
            benchChunked,
        ),
        sigbench.benchWithThroughput(
            "large-fixed-queue-pressure",
            "keepalive 60 KiB fixed gzip through bounded decoder queue",
            .{ .bytes = large_fixed_wire.len },
            benchLargeFixed,
        ),
        sigbench.benchWithThroughput(
            "large-chunked-backpressure",
            "keepalive 60 KiB chunked gzip with backpressure and trailers",
            .{ .bytes = large_chunked_wire.len },
            benchLargeChunked,
        ),
        sigbench.benchWithThroughput(
            "multipart-fixed-stream",
            "keepalive stored-block multipart through decoded mailbox",
            .{ .bytes = multipart_fixed_wire.len },
            benchMultipartFixed,
        ),
        sigbench.benchWithThroughput(
            "multipart-multi-mailbox",
            "keepalive stored-block multipart crossing decoded mailboxes",
            .{ .bytes = multipart_large_wire.len },
            benchMultipartLarge,
        ),
        sigbench.benchWithThroughput(
            "two-slot-multistream-contention",
            "two concurrent two-member decoder jobs",
            .{ .bytes = contention_gzip.len * 2 },
            benchTwoSlotMultistream,
        ),
        sigbench.benchWithThroughput(
            "malformed-rejection",
            "new connection malformed gzip rejection and close",
            .{ .bytes = malformed_wire.len },
            benchMalformed,
        ),
        sigbench.benchWithThroughput(
            "decoded-limit-rejection",
            "new connection decoded gzip limit rejection and close",
            .{ .bytes = limit_wire.len },
            benchLimit,
        ),
    },
);
