const std = @import("std");
const sigbench = @import("sigbench");

const application = @import("../src/application.zig");
const response_stream = @import("../src/response/stream.zig");
const Erased = @import("../src/internal/response/stream_erasure.zig").Erased(128, 16);
const response_framing = @import("../src/internal/http1/response_framing.zig");
const response_transfer = @import("../src/internal/http1/response_transfer.zig");
const deterministic_reactor = @import("../src/internal/runtime/deterministic_reactor.zig");
const reactor = @import("../src/internal/runtime/reactor.zig");
const stream_transport = @import("../src/internal/runtime/connection/stream_transport.zig");
const worker_stream_wake = @import("../src/internal/runtime/worker/stream_wake.zig");
const driver_benchmark = @import("response_stream_driver_benchmark.zig");
const support = @import("response_stream_benchmark_support.zig");
const wake_benchmark = @import("response_stream_wake_benchmark.zig");

const payload_bytes: usize = 4096;
const producer_chunk_bytes: usize = 512;
const staging_bytes: usize = 1024;
const payload = [_]u8{'r'} ** payload_bytes;
const raw_head = "stream-head";
const terminal = "0\r\n\r\n";

const RawKind = enum { exact, unknown };
const ProducerMode = enum { bytes, pending };

const Control = struct {
    mode: ProducerMode,
    offset: usize = 0,
    polls: u64 = 0,
    aborts: u64 = 0,
    joins: u64 = 0,
    wake: ?response_stream.Wake = null,
};

const Producer = struct {
    control: *Control,

    pub fn poll(
        self: *Producer,
        output: []u8,
        wake: response_stream.Wake,
    ) response_stream.PollError!response_stream.PollResult {
        self.control.polls += 1;
        if (self.control.mode == .pending) {
            self.control.wake = wake;
            return .pending;
        }
        if (self.control.offset == payload.len) return .{ .done = &.{} };
        const remaining = payload.len - self.control.offset;
        const count = @min(remaining, @min(output.len, producer_chunk_bytes));
        if (count == 0) return error.ProducerFailed;
        const end = self.control.offset + count;
        @memcpy(output[0..count], payload[self.control.offset..end]);
        self.control.offset = end;
        return .{ .progress = count };
    }

    pub fn abort(self: *Producer) void {
        self.control.aborts += 1;
    }

    pub fn join(self: *Producer) void {
        self.control.joins += 1;
    }
};

const FakeApp = struct {
    pub const Workspace = struct { stream: Erased = undefined };
};

const Transport = stream_transport.State(FakeApp);
const Wakes = worker_stream_wake.Fixed(1);
const TestIo = deterministic_reactor.DeterministicReactor(8);

const WakeHarness = struct {
    wakes: Wakes = undefined,
    io: TestIo = .{},
    value: worker_stream_wake.StreamWake = undefined,

    fn init(self: *WakeHarness) void {
        self.io = .{};
        self.wakes.init(0) catch benchmarkFailure();
        self.wakes.start(&self.io) catch benchmarkFailure();
        self.value = self.wakes.activate(0) catch benchmarkFailure();
    }

    fn invalidate(self: *WakeHarness) void {
        if (self.wakes.invalidateBeforeAbort(self.value) != .invalidated) {
            benchmarkFailure();
        }
    }

    fn deinit(self: *WakeHarness) void {
        self.wakes.confirmPublishersJoined() catch benchmarkFailure();
        self.wakes.beginFatalAfterPublishersJoined() catch benchmarkFailure();
        const status = self.io.abort() catch benchmarkFailure();
        if (!status.ownership_proven) benchmarkFailure();
        self.wakes.finishFatalAfterBackend() catch benchmarkFailure();
    }
};

const DriveStats = struct {
    wire_bytes: usize = 0,
    send_actions: usize = 0,
};

fn benchRawExact(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runRaw(.exact, iterations);
        }
    }.run);
}

fn benchRawUnknown(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runRaw(.unknown, iterations);
        }
    }.run);
}

fn runRaw(comptime kind: RawKind, iterations: u64) u64 {
    if (iterations == 0) benchmarkFailure();
    var wakes: WakeHarness = .{};
    wakes.init();
    defer wakes.deinit();
    var control = Control{ .mode = .bytes };
    var workspace: FakeApp.Workspace = undefined;
    var staging: [staging_bytes]u8 = undefined;
    var state: Transport = undefined;

    const expected = driveRaw(kind, &state, &workspace, &staging, wakes.value, &control, true);
    control = .{ .mode = .bytes };
    var total_wire: u64 = 0;
    var total_sends: u64 = 0;
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        const current = driveRaw(
            kind,
            &state,
            &workspace,
            &staging,
            wakes.value,
            &control,
            false,
        );
        if (!std.meta.eql(current, expected)) benchmarkFailure();
        total_wire += current.wire_bytes;
        total_sends += current.send_actions;
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    if (control.polls != iterations * rawProducerPolls()) benchmarkFailure();
    if (control.joins != iterations or control.aborts != 0) benchmarkFailure();
    wakes.invalidate();
    std.mem.doNotOptimizeAway(total_wire);
    std.mem.doNotOptimizeAway(total_sends);
    return elapsed_ns;
}

fn driveRaw(
    comptime kind: RawKind,
    state: *Transport,
    workspace: *FakeApp.Workspace,
    staging: *[staging_bytes]u8,
    wake: worker_stream_wake.StreamWake,
    control: *Control,
    validate: bool,
) DriveStats {
    control.offset = 0;
    workspace.stream.init(switch (kind) {
        .exact => response_stream.exact(payload.len, Producer{ .control = control }),
        .unknown => response_stream.unknown(Producer{ .control = control }, &.{}),
    });
    const initial = state.init(
        workspace,
        prepared(kind, payload.len),
        staging,
        wake,
        .completed,
    ) catch benchmarkFailure();
    validateHead(initial);
    var action = state.sent() catch benchmarkFailure();
    var stats = DriveStats{};
    while (true) switch (action) {
        .send => |send| {
            stats.wire_bytes += send.bytes.len;
            stats.send_actions += 1;
            if (validate) validateRawSend(kind, send);
            action = state.sent() catch benchmarkFailure();
        },
        .invalidate => |outcome| {
            if (outcome != .completed) benchmarkFailure();
            action = state.invalidated(.invalidated) catch benchmarkFailure();
        },
        .finished => |outcome| {
            if (outcome != .completed) benchmarkFailure();
            return stats;
        },
        .pending, .poll_ready => benchmarkFailure(),
    };
}

fn prepared(comptime kind: RawKind, exact_bytes: usize) application.Prepared {
    const framing: response_framing.Framing = switch (kind) {
        .exact => .{ .fixed = exact_bytes },
        .unknown => .chunked,
    };
    return .{
        .source = .{ .contiguous_wire = raw_head },
        .bytes = raw_head,
        .status = .ok,
        .close_connection = false,
        .coding_outcome = .identity_negotiated,
        .transmission = .{ .stream = .{
            .framing = .{
                .framing = framing,
                .send_body = true,
                .invoke_stream = true,
                .emit_content_type = true,
                .emit_trailers = false,
            },
            .trailers = emptyTrailerPlan(),
        } },
    };
}

fn emptyTrailerPlan() response_transfer.TrailerPlan {
    return .{ .emitted = false, .declarations = &.{}, .fingerprint = 0 };
}

fn validateHead(action: stream_transport.Action) void {
    switch (action) {
        .send => |send| if (send.kind != .head or
            !std.mem.eql(u8, send.bytes, raw_head)) benchmarkFailure(),
        else => benchmarkFailure(),
    }
}

fn validateRawSend(comptime kind: RawKind, send: stream_transport.Send) void {
    switch (send.kind) {
        .head => benchmarkFailure(),
        .body => switch (kind) {
            .exact => {
                if (send.bytes.len != producer_chunk_bytes) benchmarkFailure();
                for (send.bytes) |byte| if (byte != 'r') benchmarkFailure();
            },
            .unknown => {
                if (send.bytes.len != producer_chunk_bytes + 7) benchmarkFailure();
                if (!std.mem.startsWith(u8, send.bytes, "200\r\n")) benchmarkFailure();
                if (!std.mem.endsWith(u8, send.bytes, "\r\n")) benchmarkFailure();
            },
        },
        .terminal => {
            if (kind != .unknown or !std.mem.eql(u8, send.bytes, terminal)) {
                benchmarkFailure();
            }
        },
    }
}

fn rawProducerPolls() u64 {
    return payload_bytes / producer_chunk_bytes + 1;
}

fn benchWakePollResume(b: *sigbench.Bencher) void {
    b.iterCustom(runWakePollResume);
}

fn runWakePollResume(iterations: u64) u64 {
    if (iterations == 0) benchmarkFailure();
    var wakes: WakeHarness = .{};
    wakes.init();
    defer wakes.deinit();
    var control = Control{ .mode = .pending };
    var workspace: FakeApp.Workspace = undefined;
    workspace.stream.init(response_stream.exact(1, Producer{ .control = &control }));
    var staging: [staging_bytes]u8 = undefined;
    var state: Transport = undefined;
    validateHead(state.init(
        &workspace,
        prepared(.exact, 1),
        &staging,
        wakes.value,
        .completed,
    ) catch benchmarkFailure());
    if ((state.sent() catch benchmarkFailure()) != .pending) benchmarkFailure();
    wakeCycle(&wakes, &state, &control);
    control.polls = 0;

    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| wakeCycle(&wakes, &state, &control);
    const elapsed_ns = sigbench.nowNs() - start_ns;
    if (control.polls != iterations) benchmarkFailure();
    cleanupPending(&wakes, &state, &control);
    return elapsed_ns;
}

fn wakeCycle(wakes: *WakeHarness, state: *Transport, control: *Control) void {
    const wake = control.wake orelse benchmarkFailure();
    wake.notify();
    const token = wakes.wakes.currentPollToken() orelse benchmarkFailure();
    wakes.io.complete(token, .{ .success = .{ .wake = {} } }, false) catch {
        benchmarkFailure();
    };
    const completion = wakes.io.nextCompletion() orelse benchmarkFailure();
    const event = wakes.wakes.handle(&wakes.io, completion) catch benchmarkFailure();
    if (event.stopped or event.ready.counter_count != 1 or
        event.ready.count() != 1 or !event.ready.contains(0))
    {
        benchmarkFailure();
    }
    if ((state.ready() catch benchmarkFailure()) != .pending) benchmarkFailure();
}

fn cleanupPending(wakes: *WakeHarness, state: *Transport, control: *Control) void {
    const invalidation = state.cancel(.framework_canceled) catch benchmarkFailure();
    switch (invalidation) {
        .invalidate => |outcome| if (outcome != .framework_canceled) benchmarkFailure(),
        else => benchmarkFailure(),
    }
    wakes.invalidate();
    const finished = state.invalidated(.invalidated) catch benchmarkFailure();
    switch (finished) {
        .finished => |outcome| if (outcome != .framework_canceled) benchmarkFailure(),
        else => benchmarkFailure(),
    }
    if (control.aborts != 1 or control.joins != 1) benchmarkFailure();
}

fn benchDeterministicDriver(b: *sigbench.Bencher) void {
    b.iterCustom(driver_benchmark.benchmark);
}

pub fn writeMetricsReport(
    init: std.process.Init,
    default_output_root: []const u8,
) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    var output_root = default_output_root;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sigbench-exact")) return;
        if (std.mem.eql(u8, arg, "--output-dir")) {
            output_root = args.next() orelse return error.MissingArgument;
        }
    }

    const driver = driver_benchmark.inspect();
    const metrics = [_]support.Metric{
        rawMetric(.exact),
        rawMetric(.unknown),
        wakeMetric(),
        driverMetric(driver),
        dispatchMetric("wake-dispatch-sparse-64", 64, 1),
        dispatchMetric("wake-dispatch-sparse-1024", 1024, 1),
        dispatchMetric("wake-dispatch-sparse-8192", 8192, 1),
        dispatchMetric("wake-dispatch-dense-64", 64, wake_benchmark.dense_slots),
    };
    try support.writeMetrics(init, output_root, &metrics);
}

fn rawMetric(comptime kind: RawKind) support.Metric {
    return .{
        .id = if (kind == .exact) "exact-producer-framing" else "unknown-chunk-framing",
        .scope = "pure-transport",
        .framing = if (kind == .exact) "fixed" else "chunked",
        .payload_bytes = payload_bytes,
        .request_bytes = 0,
        .wire_bytes = if (kind == .exact) payload_bytes else payload_bytes + 8 * 7 + terminal.len,
        .producer_polls = rawProducerPolls(),
        .send_actions = if (kind == .exact) 8 else 9,
        .send_completions = 0,
        .eventfd_notifications = 0,
        .eventfd_drains = 0,
    };
}

fn dispatchMetric(id: []const u8, request_slots: usize, ready_slots: usize) support.Metric {
    return .{
        .id = id,
        .scope = "worker-wake-dispatch",
        .framing = if (ready_slots == 1) "sparse" else "dense",
        .payload_bytes = 0,
        .request_bytes = 0,
        .wire_bytes = 0,
        .producer_polls = 0,
        .send_actions = 0,
        .send_completions = 0,
        .eventfd_notifications = 1,
        .eventfd_drains = 1,
        .request_slots = request_slots,
        .ready_slots = ready_slots,
        .callback_dispatches = ready_slots,
        .runtime_completions = 1,
    };
}

fn wakeMetric() support.Metric {
    return .{
        .id = "wake-poll-resume",
        .scope = "kernel-eventfd-and-transport",
        .framing = "pending-fixed",
        .payload_bytes = 0,
        .request_bytes = 0,
        .wire_bytes = 0,
        .producer_polls = 1,
        .send_actions = 0,
        .send_completions = 0,
        .eventfd_notifications = 1,
        .eventfd_drains = 1,
        .request_slots = 1,
        .ready_slots = 1,
        .callback_dispatches = 1,
        .runtime_completions = 1,
    };
}

fn driverMetric(driver: driver_benchmark.Inspection) support.Metric {
    return .{
        .id = "deterministic-driver-exact",
        .scope = "deterministic-connection-driver",
        .framing = "fixed",
        .payload_bytes = driver_benchmark.payload_bytes,
        .request_bytes = driver_benchmark.request.len,
        .wire_bytes = driver.wire_bytes,
        .producer_polls = driver.producer_polls,
        .send_actions = driver.send_completions,
        .send_completions = driver.send_completions,
        .eventfd_notifications = 0,
        .eventfd_drains = 0,
        .request_slots = 1,
        .runtime_completions = driver.runtime_completions,
    };
}

pub const group = sigbench.groupWithId(
    "response-stream",
    "Production response stream",
    .{
        sigbench.benchWithThroughput(
            "exact-producer-framing",
            "raw exact producer and fixed framing",
            .{ .bytes = payload_bytes },
            benchRawExact,
        ),
        sigbench.benchWithThroughput(
            "unknown-chunk-framing",
            "raw unknown producer and chunk framing",
            .{ .bytes = payload_bytes },
            benchRawUnknown,
        ),
        sigbench.benchWithThroughput(
            "wake-poll-resume",
            "eventfd wake, poll dispatch, and producer resume",
            .{ .elements = 1 },
            benchWakePollResume,
        ),
        sigbench.benchWithThroughput(
            "deterministic-driver-exact",
            "deterministic connection-driver exact stream lifecycle",
            .{ .bytes = driver_benchmark.payload_bytes },
            benchDeterministicDriver,
        ),
        sigbench.benchWithThroughput(
            "wake-dispatch-sparse-64",
            "one ready request across 64 wake slots",
            .{ .elements = 1 },
            wake_benchmark.benchSparse64,
        ),
        sigbench.benchWithThroughput(
            "wake-dispatch-sparse-1024",
            "one ready request across 1,024 wake slots",
            .{ .elements = 1 },
            wake_benchmark.benchSparse1024,
        ),
        sigbench.benchWithThroughput(
            "wake-dispatch-sparse-8192",
            "one ready request across 8,192 wake slots",
            .{ .elements = 1 },
            wake_benchmark.benchSparse8192,
        ),
        sigbench.benchWithThroughput(
            "wake-dispatch-dense-64",
            "64 ready requests in one wake batch",
            .{ .elements = wake_benchmark.dense_slots },
            wake_benchmark.benchDense64,
        ),
    },
);

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof response-stream benchmark validity check failed");
}
