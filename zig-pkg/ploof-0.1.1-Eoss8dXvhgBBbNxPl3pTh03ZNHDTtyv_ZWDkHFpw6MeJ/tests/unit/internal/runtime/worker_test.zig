pub const std = @import("std");

pub const application = @import("../../../../src/application.zig");
pub const forwarding = @import("../../../../src/forwarding.zig");
pub const response = @import("../../../../src/response.zig");
pub const route = @import("../../../../src/route.zig");
pub const accept_controller = @import("../../../../src/internal/runtime/accept_controller.zig");
pub const buffer_ring = @import("../../../../src/internal/runtime/buffer_ring.zig");
pub const config = @import("../../../../src/internal/runtime/config.zig");
pub const deterministic_reactor = @import(
    "../../../../src/internal/runtime/deterministic_reactor.zig",
);
pub const fuzz_support = @import("../../../../src/internal/http1/testing/smith.zig");
pub const io_uring_backend = @import("../../../../src/internal/runtime/io_uring/backend.zig");
pub const reactor = @import("../../../../src/internal/runtime/reactor.zig");
pub const server_command = @import("../../../../src/internal/runtime/server/command.zig");
pub const worker_module = @import("../../../../src/internal/runtime/worker.zig");
pub const worker_storage = @import("../../../../src/internal/runtime/worker/storage.zig");

pub const fixed_epoch_second: i64 = 1_784_030_400;
pub const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
pub const next_date = "Tue, 14 Jul 2026 12:00:01 GMT";
pub const ping_request = "GET /ping HTTP/1.1\r\nHost: example.test\r\n\r\n";

pub const TestState = struct {
    calls: u16 = 0,
    started: u16 = 0,
    completed: u16 = 0,
    aborted: u16 = 0,
};

pub const TestContext = application.Context(TestState, response.standard_head_limits);

pub const Observe = struct {
    pub const State = void;

    pub fn init(_: Observe) void {}

    pub fn head(
        _: Observe,
        context: *TestContext,
        _: *void,
    ) ?TestContext.ResponseType {
        context.state.started += 1;
        return null;
    }

    pub fn after(
        _: Observe,
        context: *const TestContext,
        _: *void,
        outcome: application.Outcome,
    ) void {
        switch (outcome.transport) {
            .completed, .head_suppressed => context.state.completed += 1,
            else => context.state.aborted += 1,
        }
    }
};

pub fn ping(context: *TestContext) TestContext.ResponseType {
    context.state.calls += 1;
    return context.textStatic(.ok, "pong");
}

pub const TestApp = application.Application(.{
    .State = TestState,
    .middleware = .{Observe{}},
    .routes = .{route.get("/ping", ping)},
});

pub const test_limits = config.Limits.validate(.{
    .connection_slots = 2,
    .request_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 512,
    .pipeline_bytes_per_connection = 1024,
    .response_bytes_per_request = 2048,
    .submission_entries = 32,
    .completion_entries = 64,
    .timeouts = .{
        .first_head_ns = 100,
        .keepalive_idle_ns = 200,
        .reused_head_progress_ns = 100,
        .body_inactivity_ns = 200,
        .write_stall_ns = 100,
    },
});

pub const TestStorage = worker_storage.Storage(TestApp, test_limits);
pub const TestReactor = deterministic_reactor.DeterministicReactor(128);
pub const TestWorker = worker_module.Worker(TestApp, TestStorage, TestReactor);

pub const Harness = struct {
    slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined,
    storage: TestStorage = undefined,
    io: TestReactor = .{},
    state: TestState = .{},
    worker: TestWorker = undefined,
    sample: worker_module.ClockSample = .{
        .monotonic_ns = 1,
        .epoch_second = fixed_epoch_second,
    },
    buffer_cursor: u16 = 0,
    buffer_generations: [test_limits.receive_buffers]u16 =
        [_]u16{1} ** test_limits.receive_buffers,

    pub fn init(self: *Harness, start: bool) !void {
        self.io = .{};
        self.state = .{};
        try self.storage.init(&self.slab);
        self.sample = .{
            .monotonic_ns = 1,
            .epoch_second = fixed_epoch_second,
        };
        self.buffer_cursor = 0;
        self.buffer_generations = [_]u16{1} ** test_limits.receive_buffers;
        try self.worker.init(
            &self.state,
            &self.storage,
            &self.io,
            0,
            .{ .value = 4 },
            null,
        );
        if (start) {
            try std.testing.expectEqual(
                worker_module.Step.progressed,
                try self.worker.start(self.sample),
            );
        }
    }

    pub fn findToken(
        self: *const Harness,
        kind: reactor.OperationKind,
        slot_index: ?u16,
    ) ?reactor.OperationToken {
        var active_index: u16 = 0;
        while (active_index < self.io.activeCount()) : (active_index += 1) {
            const submission = self.io.activeSubmission(active_index).?;
            const fields = submission.token.fields() catch unreachable;
            if (fields.kind == kind and
                (slot_index == null or fields.slot_index == slot_index.?))
            {
                return submission.token;
            }
        }
        return null;
    }

    pub fn complete(
        self: *Harness,
        token: reactor.OperationToken,
        result: reactor.CompletionResult,
        more: bool,
    ) !worker_module.Step {
        try self.io.complete(token, result, more);
        const completion = self.io.nextCompletion() orelse {
            return error.TestUnexpectedResult;
        };
        return self.worker.handle(completion, self.sample);
    }

    pub fn accept(self: *Harness, socket: u64) !u16 {
        const token = self.findToken(.accept, std.math.maxInt(u16)) orelse {
            return error.TestUnexpectedResult;
        };
        _ = try self.complete(token, .{ .success = .{
            .accept = reactor.Accepted.loopback(.{ .value = socket }),
        } }, false);
        for (self.storage.connections, 0..) |connection, index| {
            if (connection.phase != .free and connection.socket.value == socket) {
                return @intCast(index);
            }
        }
        return error.TestUnexpectedResult;
    }

    pub fn receive(
        self: *Harness,
        connection_index: u16,
        bytes: []const u8,
        more: bool,
    ) !void {
        const token = self.storage.connections[connection_index].receive_token orelse {
            return error.TestUnexpectedResult;
        };
        const buffer_index = self.buffer_cursor;
        self.buffer_cursor = (buffer_index + 1) % test_limits.receive_buffers;
        const generation = self.buffer_generations[buffer_index];
        self.buffer_generations[buffer_index] = reactor.nextGeneration(generation);
        _ = try self.complete(token, .{ .success = .{ .receive = .{ .bytes = .{
            .identity = .{
                .owner = try token.slot(),
                .buffer_index = buffer_index,
                .buffer_generation = generation,
            },
            .bytes = bytes,
        } } } }, more);
    }

    pub fn sendBytes(self: *const Harness, connection_index: u16) []const u8 {
        const token = self.storage.connections[connection_index].send_token.?;
        return self.io.operation(token).?.send.bytes;
    }

    pub fn reapCancelRequestsReordered(self: *Harness) !void {
        var targets: [64]reactor.OperationToken = undefined;
        var target_count: usize = 0;
        while (self.findToken(.cancel, null)) |cancel_token| {
            if (target_count == targets.len) return error.TestUnexpectedResult;
            targets[target_count] = self.io.operation(cancel_token).?.cancel.target;
            target_count += 1;
            _ = try self.complete(
                cancel_token,
                .{ .success = .{ .cancel = .canceled } },
                false,
            );
        }
        while (target_count != 0) {
            target_count -= 1;
            const target = targets[target_count];
            if (self.io.operation(target) != null) {
                _ = try self.complete(target, .{ .failure = .canceled }, false);
            }
        }
    }

    pub fn stopAndDrain(self: *Harness) !void {
        var step = try self.worker.stop();
        var iterations: u16 = 0;
        while (step != .stopped) {
            if (iterations == 256) return error.TestUnexpectedResult;
            iterations += 1;
            if (step == .flush_retry) {
                step = try self.worker.retryFlush();
                continue;
            }
            const submission = self.io.activeSubmission(0) orelse {
                return error.TestUnexpectedResult;
            };
            const kind = (try submission.token.fields()).kind;
            const result: reactor.CompletionResult = switch (kind) {
                .accept, .receive, .send, .timeout => .{ .failure = .canceled },
                .close => .{ .success = .{ .close = {} } },
                .cancel => .{ .success = .{ .cancel = .canceled } },
                .wake,
                .file_open,
                .file_write,
                .file_close,
                .file_link,
                .file_unlink,
                .file_rename_no_replace,
                .file_sync,
                .upload_cancel,
                .file_read,
                .file_stat,
                .file_cancel,
                => .{ .failure = .canceled },
            };
            step = try self.complete(submission.token, result, false);
        }
    }
};

pub fn fuzzWorkerStateMachine(_: void, smith: *std.testing.Smith) !void {
    var action_storage: [64]u8 = undefined;
    const action_count = smith.slice(&action_storage);
    var harness: Harness = undefined;
    try harness.init(true);
    var next_socket: u64 = 100;

    for (action_storage[0..action_count]) |action| {
        if (!try fuzzWorkerStep(&harness, &next_socket, action)) break;
    }

    try harness.stopAndDrain();
    try expectFuzzQuiescent(&harness);
}

pub fn fuzzWorkerStep(harness: *Harness, next_socket: *u64, action: u8) !bool {
    harness.sample.monotonic_ns += @as(u64, action) + 1;
    if (action == 0xff) return try harness.worker.stop() != .stopped;
    const active_count = harness.io.activeCount();
    if (active_count == 0) return false;
    const active_index = @as(u16, action >> 3) % active_count;
    const submission = harness.io.activeSubmission(active_index).?;
    try fuzzCompletion(
        harness,
        next_socket,
        submission.token,
        submission.operation,
        action & 0x07,
    );
    return true;
}

pub fn fuzzCompletion(
    harness: *Harness,
    next_socket: *u64,
    token: reactor.OperationToken,
    operation: reactor.Operation,
    variant: u8,
) !void {
    switch (operation) {
        .accept => try fuzzAccept(harness, next_socket, token, variant),
        .receive => |receive| try fuzzReceive(
            harness,
            token,
            receive.multishot,
            variant,
        ),
        .send => |send| try fuzzSend(harness, token, send.bytes.len, variant),
        .close => _ = try harness.complete(
            token,
            .{ .success = .{ .close = {} } },
            false,
        ),
        .timeout => _ = try harness.complete(
            token,
            if (variant < 6)
                .{ .success = .{ .timeout = {} } }
            else
                .{ .failure = .canceled },
            false,
        ),
        .cancel => |cancel| try fuzzCancel(harness, token, cancel.target, variant),
        .wake,
        .file_open,
        .file_write,
        .file_close,
        .file_link,
        .file_unlink,
        .file_rename_no_replace,
        .file_sync,
        .upload_cancel,
        .file_read,
        .file_stat,
        .file_cancel,
        => _ = try harness.complete(token, .{ .failure = .canceled }, false),
    }
}

pub fn fuzzAccept(
    harness: *Harness,
    next_socket: *u64,
    token: reactor.OperationToken,
    variant: u8,
) !void {
    const result: reactor.CompletionResult = switch (variant) {
        4 => .{ .failure = .transient_accept },
        5 => .{ .failure = .resource_exhausted },
        6 => .{ .failure = .connection_aborted },
        else => result: {
            defer next_socket.* += 1;
            break :result .{ .success = .{
                .accept = reactor.Accepted.loopback(.{ .value = next_socket.* }),
            } };
        },
    };
    _ = try harness.complete(token, result, false);
}

pub fn fuzzSend(harness: *Harness, token: reactor.OperationToken, len: usize, variant: u8) !void {
    const result: reactor.CompletionResult = switch (variant) {
        6 => .{ .failure = .broken_pipe },
        7 => .{ .failure = .canceled },
        else => .{ .success = .{ .send = @intCast(switch (variant) {
            0 => 1,
            1 => @max(1, len / 2),
            else => len,
        }) } },
    };
    _ = try harness.complete(token, result, false);
}

pub fn fuzzCancel(
    harness: *Harness,
    token: reactor.OperationToken,
    target: reactor.OperationToken,
    variant: u8,
) !void {
    const canceled = variant & 1 == 0 and harness.io.operation(target) != null;
    _ = try harness.complete(token, .{ .success = .{ .cancel = if (canceled)
        .canceled
    else
        .not_found } }, false);
    if (!canceled) return;
    if (harness.io.operation(target) == null) return;
    _ = try harness.complete(target, .{ .failure = .canceled }, false);
}

pub fn expectFuzzQuiescent(harness: *Harness) !void {
    const status = harness.worker.cleanupStatus();
    try std.testing.expect(status.quiescent());
    try std.testing.expect(!status.fatal);
    try std.testing.expectEqual(@as(u32, 0), status.backend_queued);
    try std.testing.expectEqual(@as(u32, 0), status.backend_active);
    try std.testing.expectEqual(@as(u16, 0), status.borrowed_receives);
    try std.testing.expectEqual(@as(u16, 0), harness.io.pendingCompletionCount());
    try std.testing.expectEqual(
        harness.state.started,
        harness.state.completed + harness.state.aborted,
    );
    const metrics = harness.worker.metricsSnapshot();
    try std.testing.expectEqual(metrics.connections_accepted, metrics.connections_closed);
    try std.testing.expectEqual(@as(u16, 0), metrics.live_connections);
    try std.testing.expectEqual(@as(u64, 0), metrics.fatal_transitions);
}

pub fn fuzzReceive(
    harness: *Harness,
    token: reactor.OperationToken,
    multishot: bool,
    variant: u8,
) !void {
    if (variant == 4 or variant == 6) {
        _ = try harness.complete(
            token,
            .{ .failure = if (variant == 4) .buffer_exhausted else .canceled },
            false,
        );
        return;
    }
    if (variant == 5) {
        _ = try harness.complete(
            token,
            .{ .success = .{ .receive = .end_of_stream } },
            false,
        );
        return;
    }

    const bytes = switch (variant) {
        0 => ping_request,
        1 => "GET /pi",
        2 => "ng HTTP/1.1\r\nHost: example.test\r\n\r\n",
        3 => "X",
        7 => ping_request ++ ping_request,
        else => unreachable,
    };
    const buffer_index = harness.buffer_cursor;
    harness.buffer_cursor = (buffer_index + 1) % test_limits.receive_buffers;
    const generation = harness.buffer_generations[buffer_index];
    harness.buffer_generations[buffer_index] = reactor.nextGeneration(generation);
    const more = if (!multishot and variant == 3) true else multishot and variant != 7;
    _ = try harness.complete(token, .{ .success = .{ .receive = .{ .bytes = .{
        .identity = .{
            .owner = try token.slot(),
            .buffer_index = buffer_index,
            .buffer_generation = generation,
        },
        .bytes = bytes,
    } } } }, more);
}

pub const worker_state_fuzz_corpus = struct {
    const ping_actions = fuzz_support.smithInput("\x00\x08\x18\x0e\x1a\xff");
    const fragmented = fuzz_support.smithInput("\x00\x09\x0a\x12\x19\xff");
    const timeout = fuzz_support.smithInput("\x00\x10\x18\x0e\xff");
    const exhaustion = fuzz_support.smithInput("\x00\x0c\x05\x00\xff");
    const stop_race = fuzz_support.smithInput("\x00\xff\x18\x08\x10");
    const illegal_one_shot_more = fuzz_support.smithInput("\x00\x0b\xff");
    const generated_response = fuzz_support.smithInput(
        "\x86\xa4\x7c\xa5\x06\x43\x06\x83\x12\x47\xa4\xa1\x20\x7a\x20\x00" ++
            "\x01\xed\xd7\xdd\x3c",
    );
    const early_stop = fuzz_support.smithInput(
        "\xff\xae\x82\x22\x5b\x47\x4f\x65\x83\x56\x2f\x30",
    );
    const late_accept = fuzz_support.smithInput("\xff\xaf\x82");

    const values = [_][]const u8{
        &ping_actions,
        &fragmented,
        &timeout,
        &exhaustion,
        &stop_race,
        &illegal_one_shot_more,
        &generated_response,
        &early_stop,
        &late_accept,
    };
}.values;

test {
    _ = @import("worker_test_part_1.zig");
    _ = @import("worker_test_part_2.zig");
}
