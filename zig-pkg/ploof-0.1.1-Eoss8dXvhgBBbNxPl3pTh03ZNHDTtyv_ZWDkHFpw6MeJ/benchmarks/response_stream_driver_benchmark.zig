const std = @import("std");
const sigbench = @import("sigbench");

const application = @import("../src/application.zig");
const response = @import("../src/response.zig");
const response_stream = @import("../src/response/stream.zig");
const route = @import("../src/route.zig");
const config = @import("../src/internal/runtime/config.zig");
const connection_driver = @import("../src/internal/runtime/connection/driver.zig");
const deterministic_reactor = @import("../src/internal/runtime/deterministic_reactor.zig");
const reactor = @import("../src/internal/runtime/reactor.zig");
const worker_storage = @import("../src/internal/runtime/worker/storage.zig");

pub const payload_bytes: usize = 1024;
pub const request = "GET /stream HTTP/1.1\r\nHost: example.test\r\n\r\n";

const payload = [_]u8{'s'} ** payload_bytes;
const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";

pub const Inspection = struct {
    wire_bytes: usize,
    producer_polls: usize,
    send_completions: usize,
    runtime_completions: usize,
};

const ProducerControl = struct {
    offset: usize = 0,
    polls: usize = 0,
    aborts: usize = 0,
    joins: usize = 0,
};

const BenchState = struct {
    producer: ProducerControl = .{},
};

const BenchContext = application.Context(BenchState, response.standard_head_limits);
const StreamResponse = BenchContext.StreamResponse(Producer);

const Producer = struct {
    control: *ProducerControl,

    pub fn poll(
        self: *Producer,
        output: []u8,
        _: response_stream.Wake,
    ) response_stream.PollError!response_stream.PollResult {
        self.control.polls += 1;
        if (self.control.offset == payload.len) return .{ .done = &.{} };
        const remaining = payload.len - self.control.offset;
        const count = @min(remaining, output.len);
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

fn stream(context: *BenchContext) StreamResponse {
    context.state.producer.offset = 0;
    return context.streamExact(
        .ok,
        response.media.text,
        payload.len,
        Producer{ .control = &context.state.producer },
    );
}

const BenchApp = application.Application(.{
    .State = BenchState,
    .routes = .{route.get("/stream", stream)},
});

const bench_limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .body_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 512,
    .pipeline_bytes_per_connection = 512,
    .response_bytes_per_request = 2048,
    .submission_entries = 16,
    .completion_entries = 32,
    .timeouts = .{
        .first_head_ns = 100,
        .keepalive_idle_ns = 200,
        .reused_head_progress_ns = 100,
        .body_inactivity_ns = 200,
        .write_stall_ns = 100,
    },
});

const BenchStorage = worker_storage.Storage(BenchApp, bench_limits);
const BenchReactor = deterministic_reactor.DeterministicReactor(64);
const BenchDriver = connection_driver.Driver(BenchApp, BenchStorage, BenchReactor);

const Harness = struct {
    slab: [BenchStorage.required_bytes]u8 align(BenchStorage.slab_alignment) = undefined,
    storage: BenchStorage = undefined,
    io: BenchReactor = .{},
    state: BenchState = .{},
    driver: BenchDriver = undefined,
    now_ns: u64 = 1,
    buffer_generation: u16 = 1,

    fn init(self: *Harness) void {
        self.io = .{};
        self.state = .{};
        self.storage.init(&self.slab) catch benchmarkFailure();
        self.storage.stream_wakes = BenchStorage.StreamWakeLifecycle.init(0) catch {
            benchmarkFailure();
        };
        self.storage.stream_wakes.start(&self.io) catch benchmarkFailure();
        self.driver = BenchDriver.init(
            &self.state,
            &self.storage,
            &self.io,
            0,
            .{ .date = fixed_date },
        ) catch benchmarkFailure();
        self.now_ns = 1;
        self.buffer_generation = 1;
    }

    fn deinit(self: *Harness) void {
        self.storage.stream_wakes.confirmPublishersJoined() catch benchmarkFailure();
        self.storage.stream_wakes.beginFatalAfterPublishersJoined() catch benchmarkFailure();
        const status = self.io.abort() catch benchmarkFailure();
        if (!status.ownership_proven) benchmarkFailure();
        self.storage.stream_wakes.finishFatalAfterBackend() catch benchmarkFailure();
    }

    fn addConnection(self: *Harness) u16 {
        const index = self.storage.acquireConnection(.{ .value = 1 }) orelse {
            benchmarkFailure();
        };
        self.driver.start(index, self.now_ns) catch benchmarkFailure();
        return index;
    }

    fn receive(self: *Harness, connection_index: u16) void {
        const token = self.storage.connections[connection_index].receive_token orelse {
            benchmarkFailure();
        };
        const generation = self.buffer_generation;
        self.buffer_generation = reactor.nextGeneration(generation);
        _ = self.complete(token, .{ .success = .{ .receive = .{ .bytes = .{
            .identity = .{
                .owner = token.slot() catch benchmarkFailure(),
                .buffer_index = 0,
                .buffer_generation = generation,
            },
            .bytes = request,
        } } } });
    }

    fn complete(
        self: *Harness,
        token: reactor.OperationToken,
        result: reactor.CompletionResult,
    ) connection_driver.Disposition {
        self.io.complete(token, result, false) catch benchmarkFailure();
        const completion = self.io.nextCompletion() orelse benchmarkFailure();
        return self.driver.handle(completion, self.now_ns) catch benchmarkFailure();
    }

    fn retireTimeouts(self: *Harness) usize {
        var completions: usize = 0;
        while (self.findCancel()) |cancel| {
            if (completions == 16) benchmarkFailure();
            const target = switch (self.io.operation(cancel) orelse benchmarkFailure()) {
                .cancel => |operation| operation.target,
                else => benchmarkFailure(),
            };
            _ = self.complete(cancel, .{ .success = .{ .cancel = .canceled } });
            _ = self.complete(target, .{ .failure = .canceled });
            completions += 2;
        }
        if (completions == 0) benchmarkFailure();
        return completions;
    }

    fn findCancel(self: *const Harness) ?reactor.OperationToken {
        var index: u16 = 0;
        while (index < self.io.activeCount()) : (index += 1) {
            const submission = self.io.activeSubmission(index).?;
            if (submission.operation != .cancel) continue;
            return submission.token;
        }
        return null;
    }

    fn runRequest(self: *Harness, connection_index: u16, validate: bool) Inspection {
        const polls_before = self.state.producer.polls;
        const joins_before = self.state.producer.joins;
        const aborts_before = self.state.producer.aborts;
        self.receive(connection_index);

        var wire_bytes: usize = 0;
        var sends: usize = 0;
        while (self.storage.connections[connection_index].send_token) |token| {
            if (sends == 2) benchmarkFailure();
            const bytes = switch (self.io.operation(token) orelse benchmarkFailure()) {
                .send => |send| send.bytes,
                else => benchmarkFailure(),
            };
            if (validate) validateSend(sends, bytes);
            wire_bytes += bytes.len;
            sends += 1;
            _ = self.complete(token, .{ .success = .{ .send = @intCast(bytes.len) } });
        }
        if (sends != 2) benchmarkFailure();
        const retired = self.retireTimeouts();
        self.now_ns += 1;
        validateSettled(self, connection_index, polls_before, joins_before, aborts_before);
        return .{
            .wire_bytes = wire_bytes,
            .producer_polls = self.state.producer.polls - polls_before,
            .send_completions = sends,
            .runtime_completions = sends + retired + 1,
        };
    }
};

pub fn benchmark(iterations: u64) u64 {
    if (iterations == 0) benchmarkFailure();
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();
    const connection_index = harness.addConnection();
    _ = harness.runRequest(connection_index, true);
    const expected = harness.runRequest(connection_index, true);

    const polls_before = harness.state.producer.polls;
    var wire_bytes: u64 = 0;
    var send_completions: u64 = 0;
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        const current = harness.runRequest(connection_index, false);
        if (!std.meta.eql(current, expected)) benchmarkFailure();
        wire_bytes += current.wire_bytes;
        send_completions += current.send_completions;
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    if (harness.state.producer.polls - polls_before != iterations * expected.producer_polls) {
        benchmarkFailure();
    }
    std.mem.doNotOptimizeAway(wire_bytes);
    std.mem.doNotOptimizeAway(send_completions);
    return elapsed_ns;
}

pub fn inspect() Inspection {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();
    const connection_index = harness.addConnection();
    _ = harness.runRequest(connection_index, true);
    return harness.runRequest(connection_index, true);
}

fn validateSend(index: usize, bytes: []const u8) void {
    if (index == 0) {
        if (!std.mem.startsWith(u8, bytes, "HTTP/1.1 200 OK\r\n")) benchmarkFailure();
        if (std.mem.indexOf(u8, bytes, "content-length: 1024\r\n") == null) {
            benchmarkFailure();
        }
        return;
    }
    if (!std.mem.eql(u8, bytes, &payload)) benchmarkFailure();
}

fn validateSettled(
    harness: *const Harness,
    connection_index: u16,
    polls_before: usize,
    joins_before: usize,
    aborts_before: usize,
) void {
    const connection = harness.storage.connections[connection_index];
    if (connection.active_request != null or connection.receive_token == null) {
        benchmarkFailure();
    }
    if (harness.state.producer.polls - polls_before != 2) benchmarkFailure();
    if (harness.state.producer.joins - joins_before != 1) benchmarkFailure();
    if (harness.state.producer.aborts != aborts_before) benchmarkFailure();
}

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof response-stream driver benchmark validity check failed");
}
