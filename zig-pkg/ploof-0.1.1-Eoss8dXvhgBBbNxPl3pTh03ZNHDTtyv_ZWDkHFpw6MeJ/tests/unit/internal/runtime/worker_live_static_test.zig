const split = @import("../../../../fuzz/internal/runtime/worker_live_static_fuzz_support.zig");
pub const std = @import("std");
pub const application = @import("../../../../src/application.zig");
pub const response = @import("../../../../src/response.zig");
pub const static_file = @import("../../../../src/static_file.zig");
pub const config = @import("../../../../src/internal/runtime/config.zig");
pub const connection_driver = @import("../../../../src/internal/runtime/connection/driver.zig");
pub const deterministic_reactor = @import(
    "../../../../src/internal/runtime/deterministic_reactor.zig",
);
pub const reactor = @import("../../../../src/internal/runtime/reactor.zig");
pub const worker_runtime = @import("../../../../src/internal/runtime/worker.zig");
pub const worker_storage = @import("../../../../src/internal/runtime/worker/storage.zig");

pub const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";

pub const State = struct {
    completed: u16 = 0,
    aborted: u16 = 0,
};
pub const Context = application.Context(State, response.standard_head_limits);
pub const Observe = struct {
    pub const State = void;

    pub fn init(_: Observe) void {}

    pub fn after(
        _: Observe,
        context: *const Context,
        _: *void,
        outcome: application.Outcome,
    ) void {
        switch (outcome.transport) {
            .completed, .head_suppressed => context.state.completed += 1,
            else => context.state.aborted += 1,
        }
    }
};

pub const App = application.Application(.{
    .State = State,
    .middleware = .{Observe{}},
    .live_static_slots_per_worker = 2,
    .live_static_read_bytes = 4096,
    .routes = .{
        static_file.StaticDir.configured("/assets", "/srv/assets", .{}, .{}, null),
    },
});

pub const limits = config.Limits.validate(.{
    .connection_slots = 3,
    .request_slots = 3,
    .receive_buffers = 4,
    .receive_buffer_bytes = 512,
    .pipeline_bytes_per_connection = 4096,
    .response_bytes_per_request = 4096,
    .response_chunk_count = 2,
    .submission_entries = 32,
    .completion_entries = 64,
});

pub const Storage = worker_storage.Storage(App, limits);
pub const TestReactor = deterministic_reactor.DeterministicReactor(32);
pub const Driver = connection_driver.Driver(App, Storage, TestReactor);
pub const Worker = worker_runtime.Worker(App, Storage, TestReactor);
pub const TinyTestReactor = deterministic_reactor.DeterministicReactor(1);
pub const TinyWorker = worker_runtime.Worker(App, Storage, TinyTestReactor);

pub const MultiRootApp = application.Application(.{
    .State = State,
    .middleware = .{Observe{}},
    .live_static_slots_per_worker = 1,
    .routes = .{
        static_file.StaticFile.configured("/one", "/srv/one", "one.txt", .{}, .{}, null),
        static_file.StaticFile.configured("/two", "/srv/two", "two.txt", .{}, .{}, null),
    },
});
pub const MultiRootStorage = worker_storage.Storage(MultiRootApp, limits);
pub const MultiRootDriver = connection_driver.Driver(MultiRootApp, MultiRootStorage, TestReactor);

pub const LiveHarness = struct {
    slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined,
    storage: Storage = undefined,
    io: TestReactor = .{},
    state: App.StateType = .{},
    driver: Driver = undefined,
    content: []const u8 = "",
    directory_path: ?[]const u8 = null,
    directory_descriptor: ?i32 = null,
    next_descriptor: i32 = 50,
    max_read: u32 = std.math.maxInt(u32),
    zero_read_at: ?u64 = null,
    mutate_on_verify: bool = false,
    regular_stat_count: u8 = 0,
    read_count: u16 = 0,
    written_bytes: [32 * 1024]u8 = undefined,
    written_used: usize = 0,
    opened_paths: [2][128]u8 = undefined,
    opened_lengths: [2]u8 = .{ 0, 0 },
    opened_descriptors: [2]i32 = undefined,
    opened_count: u8 = 0,
    closed_descriptors: [4]i32 = undefined,
    closed_count: u8 = 0,
    buffer_cursor: u16 = 0,
    buffer_generations: [limits.receive_buffers]u16 =
        [_]u16{1} ** limits.receive_buffers,

    pub fn init(self: *LiveHarness, content: []const u8) !void {
        self.io = .{};
        self.state = .{};
        try self.storage.init(&self.slab);
        self.driver = try Driver.init(
            &self.state,
            &self.storage,
            &self.io,
            0,
            .{ .date = fixed_date },
        );
        self.content = content;
        self.directory_path = null;
        self.directory_descriptor = null;
        self.next_descriptor = 50;
        self.max_read = std.math.maxInt(u32);
        self.zero_read_at = null;
        self.mutate_on_verify = false;
        self.regular_stat_count = 0;
        self.read_count = 0;
        self.written_used = 0;
        self.opened_count = 0;
        self.closed_count = 0;
        self.buffer_cursor = 0;
        self.buffer_generations = [_]u16{1} ** limits.receive_buffers;

        try std.testing.expectEqual(.pending, try self.driver.beginLiveStaticRoots(1));
        const root = self.findRoot(.file_open).?;
        const fields = try root.token.fields();
        try std.testing.expectEqual(reactor.OperationKind.file_open, fields.kind);
        try std.testing.expect(reactor.liveStaticRootIndex(fields.slot_index) != null);
        try std.testing.expectEqual(
            .none,
            try settleDriverRootTarget(
                &self.driver,
                &self.io,
                root,
                .{ .success = .{ .file_open = .{ .value = 41 } } },
                1,
            ),
        );
        const stat = self.findRoot(.file_stat).?;
        const stat_fields = try stat.token.fields();
        try std.testing.expectEqual(reactor.OperationKind.file_stat, stat_fields.kind);
        try std.testing.expectEqual(@as(u16, 0), stat_fields.worker_index);
        try std.testing.expect(reactor.liveStaticRootIndex(stat_fields.slot_index) != null);
        fillDirectoryStat(stat.operation.file_stat.output);
        try std.testing.expectEqual(
            .roots_ready,
            try settleDriverRootTarget(
                &self.driver,
                &self.io,
                stat,
                .{ .success = .{ .file_stat = {} } },
                1,
            ),
        );
    }

    pub fn request(self: *LiveHarness, wire: []const u8) !u16 {
        const connection_index = self.storage.acquireConnection(.{ .value = 91 }) orelse
            return error.TestUnexpectedResult;
        try self.driver.start(connection_index, 2);
        const token = self.storage.connections[connection_index].receive_token orelse
            return error.TestUnexpectedResult;
        const buffer_index = self.buffer_cursor;
        self.buffer_cursor = (self.buffer_cursor + 1) % limits.receive_buffers;
        const buffer_generation = self.buffer_generations[buffer_index];
        self.buffer_generations[buffer_index] = reactor.nextGeneration(buffer_generation);
        try self.io.complete(token, .{ .success = .{ .receive = .{ .bytes = .{
            .identity = .{
                .owner = try token.slot(),
                .buffer_index = buffer_index,
                .buffer_generation = buffer_generation,
            },
            .bytes = wire,
        } } } }, false);
        _ = try self.driver.handle(self.io.nextCompletion().?, 2);
        return connection_index;
    }

    pub fn runResponse(self: *LiveHarness, connection_index: u16) !void {
        var iterations: u16 = 0;
        while (iterations < 256) : (iterations += 1) {
            const connection = self.storage.connections[connection_index];
            if (self.driver.liveStaticRequests() == 0 and
                connection.active_request == null and connection.send_token == null) return;
            if (!try self.step(false)) return error.TestUnexpectedResult;
        }
        return error.TestUnexpectedResult;
    }

    pub fn runReleased(self: *LiveHarness, connection_index: u16) !void {
        var iterations: u16 = 0;
        while (iterations < 256) : (iterations += 1) {
            if (self.storage.connections[connection_index].phase == .free) return;
            if (!try self.step(true)) return error.TestUnexpectedResult;
        }
        return error.TestUnexpectedResult;
    }

    pub fn step(self: *LiveHarness, drain_connection: bool) !bool {
        var index: u16 = 0;
        while (index < self.io.activeCount()) : (index += 1) {
            const submission = self.io.activeSubmission(index).?;
            const fields = try submission.token.fields();
            if (reactor.liveStaticRequestIndex(fields.slot_index) != null) {
                try self.completeStatic(submission);
                return true;
            }
            if (fields.kind == .send) {
                try self.completeSend(submission);
                return true;
            }
            if (drain_connection and isDrainOperation(fields.kind)) {
                try self.completeConnection(submission);
                return true;
            }
        }
        return false;
    }

    pub fn completeStatic(self: *LiveHarness, submission: reactor.Submission) !void {
        const result: reactor.CompletionResult = switch (submission.operation) {
            .file_open => |open| result: {
                const path = open.path[0..open.path.len];
                const descriptor = self.next_descriptor;
                self.next_descriptor += 1;
                try self.recordOpen(path, descriptor);
                if (self.directory_path) |directory| {
                    if (std.mem.eql(u8, path, directory)) {
                        self.directory_descriptor = descriptor;
                    }
                }
                break :result .{ .success = .{ .file_open = .{ .value = descriptor } } };
            },
            .file_stat => |stat| result: {
                stat.output.* = std.mem.zeroes(std.os.linux.Statx);
                stat.output.mask = .{ .TYPE = true, .SIZE = true, .MTIME = true, .INO = true };
                const directory = self.directory_descriptor == stat.file.value;
                stat.output.mode = if (directory)
                    0o040755
                else
                    0o100644;
                stat.output.size = self.content.len;
                stat.output.ino = 7;
                stat.output.dev_major = 8;
                stat.output.dev_minor = 1;
                stat.output.mtime.sec = 1_700_000_000;
                stat.output.mtime.nsec = 123;
                if (!directory) {
                    self.regular_stat_count += 1;
                    if (self.mutate_on_verify and self.regular_stat_count > 1) {
                        stat.output.mtime.nsec += 1;
                    }
                }
                break :result .{ .success = .{ .file_stat = {} } };
            },
            .file_read => |read| result: {
                self.read_count += 1;
                if (self.zero_read_at == read.offset) {
                    break :result .{ .success = .{ .file_read = 0 } };
                }
                const available = self.content.len - @min(self.content.len, read.offset);
                const used = @min(read.bytes.len, @min(available, self.max_read));
                @memcpy(read.bytes[0..used], self.content[read.offset..][0..used]);
                break :result .{ .success = .{ .file_read = @intCast(used) } };
            },
            .file_close => |close| result: {
                try self.recordClose(close.file.value);
                break :result .{ .success = .{ .file_close = {} } };
            },
            .file_cancel => .{ .success = .{ .file_cancel = .canceled } },
            else => return error.TestUnexpectedResult,
        };
        try self.completeStaticResult(submission, result);
    }

    pub fn completeStaticResult(
        self: *LiveHarness,
        submission: reactor.Submission,
        result: reactor.CompletionResult,
    ) !void {
        try self.io.complete(submission.token, result, false);
        _ = try self.driver.handleLiveStatic(
            self.io.nextCompletion().?,
            1_784_030_400,
            3,
        );
    }

    pub fn findStatic(
        self: *const LiveHarness,
        kind: reactor.OperationKind,
    ) ?reactor.Submission {
        var index: u16 = 0;
        while (index < self.io.activeCount()) : (index += 1) {
            const submission = self.io.activeSubmission(index).?;
            const fields = submission.token.fields() catch unreachable;
            if (fields.kind == kind and
                reactor.liveStaticRequestIndex(fields.slot_index) != null) return submission;
        }
        return null;
    }

    pub fn findRoot(
        self: *const LiveHarness,
        kind: reactor.OperationKind,
    ) ?reactor.Submission {
        var index: u16 = 0;
        while (index < self.io.activeCount()) : (index += 1) {
            const submission = self.io.activeSubmission(index).?;
            const fields = submission.token.fields() catch unreachable;
            if (fields.kind == kind and
                reactor.liveStaticRootIndex(fields.slot_index) != null) return submission;
        }
        return null;
    }

    pub fn currentSend(
        self: *const LiveHarness,
        connection_index: u16,
    ) ?reactor.Submission {
        const token = self.storage.connections[connection_index].send_token orelse return null;
        const operation = self.io.operation(token) orelse return null;
        return .{ .token = token, .operation = operation };
    }

    pub fn completeSend(self: *LiveHarness, submission: reactor.Submission) !void {
        const bytes = submission.operation.send.bytes;
        if (bytes.len > self.written_bytes.len - self.written_used) {
            return error.TestUnexpectedResult;
        }
        @memcpy(self.written_bytes[self.written_used..][0..bytes.len], bytes);
        self.written_used += bytes.len;
        try self.io.complete(
            submission.token,
            .{ .success = .{ .send = @intCast(bytes.len) } },
            false,
        );
        _ = try self.driver.handle(self.io.nextCompletion().?, 3);
    }

    pub fn completeSendResult(
        self: *LiveHarness,
        submission: reactor.Submission,
        success: bool,
    ) !void {
        if (success) return self.completeSend(submission);
        try self.io.complete(submission.token, .{ .failure = .canceled }, false);
        _ = try self.driver.handle(self.io.nextCompletion().?, 3);
    }

    pub fn completeConnection(self: *LiveHarness, submission: reactor.Submission) !void {
        const result: reactor.CompletionResult = switch (submission.operation) {
            .cancel => .{ .success = .{ .cancel = .canceled } },
            .close => .{ .success = .{ .close = {} } },
            .timeout, .receive, .send => .{ .failure = .canceled },
            else => return error.TestUnexpectedResult,
        };
        try self.io.complete(submission.token, result, false);
        _ = try self.driver.handle(self.io.nextCompletion().?, 3);
    }

    pub fn recordOpen(self: *LiveHarness, path: []const u8, descriptor: i32) !void {
        if (self.opened_count >= self.opened_paths.len or
            path.len > self.opened_paths[0].len) return error.TestUnexpectedResult;
        for (self.opened_descriptors[0..self.opened_count]) |opened_descriptor| {
            if (opened_descriptor == descriptor) return error.TestUnexpectedResult;
        }
        const index = self.opened_count;
        @memcpy(self.opened_paths[index][0..path.len], path);
        self.opened_lengths[index] = @intCast(path.len);
        self.opened_descriptors[index] = descriptor;
        self.opened_count += 1;
    }

    pub fn recordClose(self: *LiveHarness, descriptor: i32) !void {
        var owned = false;
        for (self.opened_descriptors[0..self.opened_count]) |opened_descriptor| {
            owned = owned or opened_descriptor == descriptor;
        }
        if (!owned or self.closed_count >= self.closed_descriptors.len) {
            return error.TestUnexpectedResult;
        }
        for (self.closed_descriptors[0..self.closed_count]) |closed_descriptor| {
            if (closed_descriptor == descriptor) return error.TestUnexpectedResult;
        }
        self.closed_descriptors[self.closed_count] = descriptor;
        self.closed_count += 1;
    }

    pub fn opened(self: *const LiveHarness, index: u8) []const u8 {
        return self.opened_paths[index][0..self.opened_lengths[index]];
    }

    pub fn written(self: *const LiveHarness) []const u8 {
        return self.written_bytes[0..self.written_used];
    }

    pub fn body(self: *const LiveHarness) ![]const u8 {
        const marker = std.mem.indexOf(u8, self.written(), "\r\n\r\n") orelse
            return error.TestUnexpectedResult;
        return self.written()[marker + 4 ..];
    }
};

pub fn isDrainOperation(kind: reactor.OperationKind) bool {
    return switch (kind) {
        .receive, .close, .timeout, .cancel => true,
        else => false,
    };
}

pub const CancelSendStage = enum {
    get_head,
    head_complete,
    body_nonterminal,
    body_terminal,
};

pub const PendingSend = struct {
    connection: u16,
    submission: reactor.Submission,
};

pub const long_content = [_]u8{'x'} ** (4096 + 17);

pub fn reachPendingSend(harness: *LiveHarness, stage: CancelSendStage) !PendingSend {
    const wire = if (stage == .head_complete)
        "HEAD /assets/value.txt HTTP/1.1\r\nHost: example.test\r\n\r\n"
    else
        "GET /assets/value.txt HTTP/1.1\r\nHost: example.test\r\n\r\n";
    const connection = try harness.request(wire);
    try harness.completeStatic(harness.findStatic(.file_open).?);
    try harness.completeStatic(harness.findStatic(.file_stat).?);
    if (stage == .get_head or stage == .head_complete) {
        return .{ .connection = connection, .submission = harness.currentSend(connection).? };
    }
    try harness.completeSend(harness.currentSend(connection).?);
    try harness.completeStatic(harness.findStatic(.file_read).?);
    if (stage == .body_terminal) {
        try harness.completeStatic(harness.findStatic(.file_stat).?);
    }
    return .{ .connection = connection, .submission = harness.currentSend(connection).? };
}

pub fn expectRootOperation(
    submission: reactor.Submission,
    expected: reactor.OperationKind,
) !void {
    const fields = try submission.token.fields();
    try std.testing.expectEqual(expected, fields.kind);
    try std.testing.expectEqual(@as(u16, 3), fields.worker_index);
    try std.testing.expect(reactor.liveStaticRootIndex(fields.slot_index) != null);
}

pub fn findRootSubmission(
    io: anytype,
    kind: reactor.OperationKind,
) ?reactor.Submission {
    var index: u16 = 0;
    while (index < io.activeCount()) : (index += 1) {
        const submission = io.activeSubmission(index).?;
        const fields = submission.token.fields() catch unreachable;
        if (fields.kind == kind and
            reactor.liveStaticRootIndex(fields.slot_index) != null) return submission;
    }
    return null;
}

pub fn settleDriverRootTarget(
    driver: anytype,
    io: anytype,
    target: reactor.Submission,
    result: reactor.CompletionResult,
    now_ns: u64,
) !@import("../../../../src/internal/runtime/worker/live_static.zig").Event {
    try io.complete(target.token, result, false);
    try std.testing.expectEqual(
        @import("../../../../src/internal/runtime/worker/live_static.zig").Event.none,
        try driver.handleLiveStatic(io.nextCompletion().?, 1_784_030_400, now_ns),
    );
    const cancel = findRootSubmission(io, .cancel).?;
    const timeout = findRootSubmission(io, .timeout).?;
    try io.complete(cancel.token, .{ .success = .{ .cancel = .canceled } }, false);
    try std.testing.expectEqual(
        @import("../../../../src/internal/runtime/worker/live_static.zig").Event.none,
        try driver.handleLiveStatic(io.nextCompletion().?, 1_784_030_400, now_ns),
    );
    try io.complete(timeout.token, .{ .failure = .canceled }, false);
    return driver.handleLiveStatic(io.nextCompletion().?, 1_784_030_400, now_ns);
}

pub fn settleWorkerRootTarget(
    worker: *Worker,
    io: *TestReactor,
    target: reactor.Submission,
    result: reactor.CompletionResult,
    now_ns: u64,
) !worker_runtime.Step {
    try io.complete(target.token, result, false);
    try std.testing.expectEqual(
        worker_runtime.Step.progressed,
        try worker.handle(
            io.nextCompletion().?,
            .{ .monotonic_ns = now_ns, .epoch_second = 1_784_030_400 },
        ),
    );
    const cancel = findRootSubmission(io, .cancel).?;
    const timeout = findRootSubmission(io, .timeout).?;
    try io.complete(cancel.token, .{ .success = .{ .cancel = .canceled } }, false);
    try std.testing.expectEqual(
        worker_runtime.Step.progressed,
        try worker.handle(
            io.nextCompletion().?,
            .{ .monotonic_ns = now_ns, .epoch_second = 1_784_030_400 },
        ),
    );
    try io.complete(timeout.token, .{ .failure = .canceled }, false);
    return worker.handle(
        io.nextCompletion().?,
        .{ .monotonic_ns = now_ns, .epoch_second = 1_784_030_400 },
    );
}

pub fn completeAllStaticCloses(harness: *LiveHarness) !void {
    var count: u8 = 0;
    while (harness.findStatic(.file_close)) |close| : (count += 1) {
        if (count == 3) return error.TestUnexpectedResult;
        try harness.completeStatic(close);
    }
}

pub fn fillDirectoryStat(statx: *std.os.linux.Statx) void {
    statx.* = std.mem.zeroes(std.os.linux.Statx);
    statx.mask = std.os.linux.STATX.BASIC_STATS;
    statx.mode = 0o040755;
}

pub const ScheduleStage = split.ScheduleStage;

pub const RootSchedule = split.RootSchedule;

pub const fuzzLiveStaticControllerSchedule = split.fuzzLiveStaticControllerSchedule;

pub const fuzzRootSchedule = split.fuzzRootSchedule;

pub const settleLatePositiveRootTimeout = split.settleLatePositiveRootTimeout;

pub const expectFuzzRootIdle = split.expectFuzzRootIdle;

pub const settleFuzzRootTarget = split.settleFuzzRootTarget;

pub const completeRootControl = split.completeRootControl;

pub const fuzzRequestSchedule = split.fuzzRequestSchedule;

pub const reachScheduleStage = split.reachScheduleStage;

pub const RandomDrain = split.RandomDrain;

pub const expectScheduleClean = split.expectScheduleClean;

pub const expectDescriptorLedgerClosed = split.expectDescriptorLedgerClosed;

pub fn expectZeroed(bytes: []const u8) !void {
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test {
    _ = @import("worker_live_static_test_part_1.zig");
    _ = @import("worker_live_static_test_part_2.zig");
}
