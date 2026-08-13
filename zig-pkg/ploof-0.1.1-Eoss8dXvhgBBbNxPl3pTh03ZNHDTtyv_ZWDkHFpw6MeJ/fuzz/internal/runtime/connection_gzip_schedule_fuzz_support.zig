const source = @import("connection_gzip_schedule_fuzz_check.zig");
const std = source.std;
const builtin = source.builtin;
const application = source.application;
const body = source.body;
const endpoint = source.endpoint;
const multipart = source.multipart;
const response = source.response;
const route = source.route;
const fuzz_support = source.fuzz_support;
const config = source.config;
const connection_driver = source.connection_driver;
const deterministic_reactor = source.deterministic_reactor;
const reactor = source.reactor;
const worker_storage = source.worker_storage;
const fixed_date = source.fixed_date;
const gzip_abcdef = source.gzip_abcdef;
const fixed_head = source.fixed_head;
const expect_head = source.expect_head;
const chunked_head = source.chunked_head;
const malformed_head = source.malformed_head;
const pressure_head = source.pressure_head;
const pressure_body = source.pressure_body;
const storedGzip = source.storedGzip;
const multipart_boundary = source.multipart_boundary;
const multipart_valid_body = source.multipart_valid_body;
const multipart_reject_body = source.multipart_reject_body;
const multipart_valid_gzip = source.multipart_valid_gzip;
const multipart_reject_gzip = source.multipart_reject_gzip;
const multipart_valid_head = source.multipart_valid_head;
const multipart_reject_head = source.multipart_reject_head;
const multipart_reject_wire = source.multipart_reject_wire;
const TestState = source.TestState;
const TestContext = source.TestContext;
const Observe = source.Observe;
const echo = source.echo;
const MultipartBody = source.MultipartBody;
const MultipartEndpoint = source.MultipartEndpoint;
const MultipartSpec = source.MultipartSpec;
const MultipartConsumer = source.MultipartConsumer;
const TestApp = source.TestApp;
const test_limits = source.test_limits;
const TestStorage = source.TestStorage;
const TestReactor = source.TestReactor;
const TestDriver = source.TestDriver;
const TestPool = source.TestPool;
const stack_size = source.stack_size;
const ScenarioKind = source.ScenarioKind;
const Scenario = source.Scenario;
const scenarios = source.scenarios;
const Client = source.Client;
const ActionKind = source.ActionKind;
const action_kind_count = source.action_kind_count;
const fragment_lengths = source.fragment_lengths;
const stop_drain_attempts_max: u32 = 10_000;

pub const Harness = struct {
    slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined,
    storage: TestStorage = undefined,
    io: TestReactor = .{},
    state: TestState = .{},
    driver: TestDriver = undefined,
    clients: [2]Client = .{ .{}, .{} },
    client_count: u8 = 0,
    decode_released: bool = false,
    multipart_valid_terminals: u8 = 0,
    multipart_reject_terminals: u8 = 0,
    now_ns: u64 = 1,
    buffer_cursor: u16 = 0,
    buffer_generations: [test_limits.receive_buffers]u16 =
        [_]u16{1} ** test_limits.receive_buffers,

    pub fn init(self: *Harness) !void {
        self.io = .{};
        self.state = .{};
        self.client_count = 0;
        self.decode_released = false;
        self.multipart_valid_terminals = 0;
        self.multipart_reject_terminals = 0;
        self.now_ns = 1;
        self.buffer_cursor = 0;
        self.buffer_generations = [_]u16{1} ** test_limits.receive_buffers;
        try self.storage.init(&self.slab);
        self.driver = try TestDriver.init(
            &self.state,
            &self.storage,
            &self.io,
            0,
            .{ .date = fixed_date },
        );
        try self.pool().start(stack_size);
        _ = self.pool().wakeDescriptor();
    }

    pub fn deinit(self: *Harness) void {
        TestPool.TestAccess.pauseDecode(false);
        self.drain() catch @panic("gzip schedule fuzz cleanup failed");
        const decoder_pool = self.pool();
        if (decoder_pool.beginStop() != null) {
            @panic("gzip schedule fuzz pool join failed");
        }
        var attempts: u32 = 0;
        while (decoder_pool.activeJobs() != 0) : (attempts += 1) {
            if (attempts == stop_drain_attempts_max) {
                @panic("gzip schedule fuzz stop drain deadline exceeded");
            }
            const batch = consumeReadyTimeout(decoder_pool, 1) catch {
                @panic("gzip schedule fuzz stop drain failed");
            } orelse continue;
            for (batch.slots, 0..) |signals, index| {
                if (!signals.terminal) continue;
                self.driver.settleGzipAfterBackend(
                    @intCast(index),
                    signals,
                ) catch @panic("gzip schedule fuzz stop settlement failed");
            }
        }
        decoder_pool.retireWakePoll() catch {
            @panic("gzip schedule fuzz poll retirement failed");
        };
        const failure = decoder_pool.finishStop() catch {
            @panic("gzip schedule fuzz stop state failed");
        };
        if (failure != null) @panic("gzip schedule fuzz counter close failed");
    }

    pub fn pool(self: *Harness) *TestPool {
        return self.storage.gzipPool().?;
    }

    pub fn prepare(self: *Harness, selected: [2]u8) !void {
        try self.expectQuiescent();
        self.state = .{};
        self.client_count = 0;
        self.decode_released = false;
        self.multipart_valid_terminals = 0;
        self.multipart_reject_terminals = 0;
        self.now_ns = 1;
        TestPool.TestAccess.pauseDecode(true);
        for (selected, 0..) |scenario_index, client_index| {
            const connection = self.storage.acquireConnection(.{
                .value = 200 + client_index,
            }) orelse return error.FuzzConnectionExhausted;
            self.clients[client_index] = .{
                .connection = connection,
                .wire = scenarios[scenario_index].wire,
                .head_boundary = scenarios[scenario_index].head_boundary,
                .scenario_index = scenario_index,
            };
            self.client_count += 1;
            try self.driver.start(connection, self.now_ns);
        }
    }

    pub fn step(self: *Harness, action: u8) !void {
        self.now_ns +|= @as(u64, action) + 1;
        const client_index: u8 = action & 1;
        const variant: u8 = action >> 5;
        const raw_kind = (action >> 1) & 0x0f;
        const kind: ActionKind = @enumFromInt(raw_kind % action_kind_count);
        switch (kind) {
            .receive => try self.receiveNext(client_index, variant, false),
            .illegal_more => try self.receiveNext(client_index, variant, true),
            .buffer_exhausted => try self.failReceive(client_index, .buffer_exhausted),
            .eof => try self.endReceive(client_index),
            .send => try self.completeSend(client_index, variant),
            .timeout => try self.completeTimeout(client_index, variant),
            .cancel => try self.completeCancel(client_index, variant),
            .close => try self.completeClose(client_index),
            .wake => try self.dispatchWakeAction(variant),
            .stop => try self.stop(client_index),
            .resume_receive => try self.resumeReceiveAction(client_index),
            .release_decode => self.releaseDecode(),
            .arbitrary => try self.completeArbitrary(action),
        }
        std.Thread.yield() catch {};
    }

    pub fn receiveNext(self: *Harness, client_index: u8, variant: u8, more: bool) !void {
        const client = self.getClient(client_index) orelse return;
        const token = self.receiveToken(client.connection) orelse return;
        if (client.cursor == client.wire.len) return;
        const requested = fragment_lengths[variant];
        var end = @min(client.wire.len, client.cursor + requested);
        if (client.head_boundary > client.cursor) {
            end = @min(end, client.head_boundary);
        }
        const bytes = client.wire[client.cursor..end];
        client.cursor = end;
        try self.completeBorrowed(token, bytes, more);
    }

    pub fn failReceive(
        self: *Harness,
        client_index: u8,
        failure: reactor.CompletionError,
    ) !void {
        const client = self.getClient(client_index) orelse return;
        const token = self.receiveToken(client.connection) orelse return;
        _ = try self.complete(token, .{ .failure = failure }, false);
    }

    pub fn endReceive(self: *Harness, client_index: u8) !void {
        const client = self.getClient(client_index) orelse return;
        const token = self.receiveToken(client.connection) orelse return;
        _ = try self.complete(
            token,
            .{ .success = .{ .receive = .end_of_stream } },
            false,
        );
    }

    pub fn completeSend(self: *Harness, client_index: u8, variant: u8) !void {
        const client = self.getClient(client_index) orelse return;
        const token = self.tokenFor(client.connection, .send) orelse return;
        const operation = self.io.operation(token) orelse return;
        const length = operation.send.bytes.len;
        if (variant >= 6) {
            const failure: reactor.CompletionError = if (variant == 6)
                .broken_pipe
            else
                .canceled;
            _ = try self.complete(token, .{ .failure = failure }, false);
            return;
        }
        const count = switch (variant) {
            0 => 1,
            1 => @max(1, length / 2),
            else => length,
        };
        _ = try self.complete(
            token,
            .{ .success = .{ .send = @intCast(count) } },
            false,
        );
    }

    pub fn completeTimeout(self: *Harness, client_index: u8, variant: u8) !void {
        const client = self.getClient(client_index) orelse return;
        const token = self.tokenFor(client.connection, .timeout) orelse return;
        if (variant >= 4) {
            _ = try self.complete(token, .{ .failure = .canceled }, false);
            return;
        }
        const record = &self.storage.connections[client.connection];
        self.now_ns = @max(self.now_ns, record.timeout_deadline_ns);
        _ = try self.complete(
            token,
            .{ .success = .{ .timeout = {} } },
            false,
        );
    }

    pub fn completeCancel(self: *Harness, client_index: u8, variant: u8) !void {
        const client = self.getClient(client_index) orelse return;
        const token = self.tokenFor(client.connection, .cancel) orelse return;
        try self.completeCancelToken(token, variant & 2 != 0);
    }

    pub fn completeCancelToken(self: *Harness, token: reactor.OperationToken, follow: bool) !void {
        const operation = self.io.operation(token) orelse return;
        const target = operation.cancel.target;
        const canceled = self.io.operation(target) != null;
        _ = try self.complete(token, .{ .success = .{ .cancel = if (canceled)
            .canceled
        else
            .not_found } }, false);
        if (follow and canceled and self.io.operation(target) != null) {
            _ = try self.complete(target, .{ .failure = .canceled }, false);
        }
    }

    pub fn completeClose(self: *Harness, client_index: u8) !void {
        const client = self.getClient(client_index) orelse return;
        const token = self.tokenFor(client.connection, .close) orelse return;
        _ = try self.complete(token, .{ .success = .{ .close = {} } }, false);
    }

    pub fn completeArbitrary(self: *Harness, action: u8) !void {
        const count = self.io.activeCount();
        if (count == 0) return;
        const submission = self.io.activeSubmission(@as(u16, action) % count).?;
        switch (submission.operation) {
            .cancel => try self.completeCancelToken(submission.token, action & 1 != 0),
            .close => _ = try self.complete(
                submission.token,
                .{ .success = .{ .close = {} } },
                false,
            ),
            .receive, .send, .timeout => _ = try self.complete(
                submission.token,
                .{ .failure = .canceled },
                false,
            ),
            else => return error.FuzzUnexpectedOperation,
        }
    }

    pub fn stop(self: *Harness, client_index: u8) !void {
        const client = self.getClient(client_index) orelse return;
        _ = try self.driver.stop(client.connection);
    }

    pub fn resumeReceiveAction(self: *Harness, client_index: u8) !void {
        const client = self.getClient(client_index) orelse return;
        _ = try self.driver.resumeReceive(client.connection);
    }

    pub fn releaseDecode(self: *Harness) void {
        self.decode_released = true;
        TestPool.TestAccess.pauseDecode(false);
    }

    pub fn dispatchWakeAction(self: *Harness, variant: u8) !void {
        if (try self.dispatchWake()) return;
        if (variant != 7 or !self.decode_released or self.pool().activeJobs() == 0) return;
        _ = try self.dispatchWakeTimeout(1);
    }

    pub fn dispatchWake(self: *Harness) !bool {
        return self.dispatchWakeTimeout(0);
    }

    fn dispatchWakeTimeout(self: *Harness, timeout_ms: i32) !bool {
        const batch = (try consumeReadyTimeout(self.pool(), timeout_ms)) orelse return false;
        for (batch.slots, 0..) |signals, index| {
            if (!signals.space and !signals.output and !signals.terminal) continue;
            const lease = self.pool().leaseAt(@intCast(index));
            const owner = if (lease) |held| try self.pool().owner(held) else null;
            const client = if (owner) |held| self.clientForConnection(
                held.connection_index,
            ) else null;
            if (signals.output and lease != null and
                try self.pool().output(lease.?) != null)
            {
                if (client) |value| value.output_dispatches +|= 1;
            }
            const calls_before = self.state.multipart_calls;
            {
                self.state.gzip_terminal_dispatching = signals.terminal;
                defer self.state.gzip_terminal_dispatching = false;
                try self.driver.handleGzipSignals(@intCast(index), signals, self.now_ns);
            }
            if (signals.terminal) try self.expectMultipartTerminal(
                client,
                calls_before,
            );
        }
        return true;
    }

    pub fn expectMultipartTerminal(
        self: *Harness,
        client: ?*Client,
        calls_before: u16,
    ) !void {
        const value = client orelse return;
        if (self.storage.connections[value.connection].phase != .responding) return;
        switch (scenarios[value.scenario_index].kind) {
            .echo => {},
            .multipart_valid => {
                try std.testing.expectEqual(calls_before + 1, self.state.multipart_calls);
                try std.testing.expectEqual(@as(u16, 23), self.state.multipart_count);
                try std.testing.expect(value.output_dispatches >= 2);
                try self.expectResponseStatus(value.connection, "HTTP/1.1 200 OK\r\n");
                self.multipart_valid_terminals += 1;
            },
            .multipart_reject => {
                try std.testing.expectEqual(calls_before, self.state.multipart_calls);
                try std.testing.expect(value.output_dispatches != 0);
                try self.expectResponseStatus(
                    value.connection,
                    "HTTP/1.1 400 Bad Request\r\n",
                );
                self.multipart_reject_terminals += 1;
            },
        }
    }

    pub fn expectResponseStatus(
        self: *const Harness,
        connection: u16,
        expected: []const u8,
    ) !void {
        const token = self.tokenFor(connection, .send) orelse {
            return error.FuzzResponseMissing;
        };
        const bytes = self.io.operation(token).?.send.bytes;
        try std.testing.expect(std.mem.startsWith(u8, bytes, expected));
    }

    pub fn completeBorrowed(
        self: *Harness,
        token: reactor.OperationToken,
        bytes: []const u8,
        more: bool,
    ) !void {
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

    pub fn complete(
        self: *Harness,
        token: reactor.OperationToken,
        result: reactor.CompletionResult,
        more: bool,
    ) !connection_driver.Disposition {
        try self.io.complete(token, result, more);
        const completion = self.io.nextCompletion() orelse {
            return error.FuzzCompletionMissing;
        };
        return self.driver.handle(completion, self.now_ns);
    }

    pub fn drain(self: *Harness) !void {
        TestPool.TestAccess.pauseDecode(false);
        for (self.clients[0..self.client_count]) |client| {
            if (self.storage.connections[client.connection].phase != .free) {
                _ = try self.driver.stop(client.connection);
            }
        }
        var attempts: u32 = 0;
        while (!self.isQuiescent()) : (attempts += 1) {
            if (attempts == 100_000) return error.FuzzDrainBoundExceeded;
            var progressed = try self.dispatchWake();
            if (self.io.activeCount() != 0) {
                try self.completeDrainSubmission(self.io.activeSubmission(0).?);
                progressed = true;
            }
            if (!progressed) std.Thread.yield() catch {};
        }
    }

    pub fn completeDrainSubmission(self: *Harness, submission: reactor.Submission) !void {
        switch (submission.operation) {
            .cancel => try self.completeCancelToken(submission.token, false),
            .close => _ = try self.complete(
                submission.token,
                .{ .success = .{ .close = {} } },
                false,
            ),
            .receive, .send, .timeout => _ = try self.complete(
                submission.token,
                .{ .failure = .canceled },
                false,
            ),
            else => return error.FuzzUnexpectedOperation,
        }
    }

    pub fn forceDrain(self: *Harness) void {
        self.drain() catch |problem| {
            std.debug.panic(
                "gzip schedule fuzz iteration cleanup failed: {s}",
                .{@errorName(problem)},
            );
        };
    }

    pub fn isQuiescent(self: *Harness) bool {
        return self.pool().activeJobs() == 0 and
            self.io.activeCount() == 0 and
            self.io.pendingCompletionCount() == 0 and
            self.io.borrowedCount() == 0 and
            self.storage.connection_pool.available() == test_limits.connection_slots;
    }

    pub fn expectQuiescent(self: *Harness) !void {
        try std.testing.expect(self.isQuiescent());
        try std.testing.expectEqual(test_limits.gzip.decoder_slots, self.pool().available());
        try std.testing.expectEqual(
            test_limits.request_slots,
            self.storage.request_pool.available(),
        );
        try std.testing.expectEqual(
            test_limits.body_workspace_slots,
            self.storage.bodyWorkspaceAvailable(),
        );
        try std.testing.expectEqual(
            test_limits.chunked_workspace_slots,
            self.storage.chunkedWorkspaceAvailable(),
        );
        try std.testing.expect(!self.state.invalid_body);
        try std.testing.expect(!self.state.multipart_invalid);
        try std.testing.expect(!self.state.gzip_terminal_dispatching);
        try std.testing.expectEqual(
            self.state.started,
            self.state.completed + self.state.aborted,
        );
        try std.testing.expect(self.state.body_calls <= 2);
    }

    pub fn getClient(self: *Harness, index: u8) ?*Client {
        if (index >= self.client_count) return null;
        return &self.clients[index];
    }

    pub fn clientForConnection(self: *Harness, connection: u16) ?*Client {
        for (self.clients[0..self.client_count]) |*client| {
            if (client.connection == connection) return client;
        }
        return null;
    }

    pub fn receiveToken(self: *Harness, connection: u16) ?reactor.OperationToken {
        const record = &self.storage.connections[connection];
        if (record.phase == .free or record.phase == .closing) return null;
        return record.receive_token;
    }

    pub fn tokenFor(
        self: *const Harness,
        connection: u16,
        kind: reactor.OperationKind,
    ) ?reactor.OperationToken {
        var index: u16 = 0;
        while (index < self.io.activeCount()) : (index += 1) {
            const submission = self.io.activeSubmission(index).?;
            const fields = submission.token.fields() catch unreachable;
            if (fields.slot_index == connection and fields.kind == kind) {
                return submission.token;
            }
        }
        return null;
    }
};

pub fn consumeReady(pool: *TestPool) !?TestPool.WakeBatch {
    return consumeReadyTimeout(pool, 0);
}

fn consumeReadyTimeout(pool: *TestPool, timeout_ms: i32) !?TestPool.WakeBatch {
    var descriptors = [1]std.os.linux.pollfd{.{
        .fd = pool.wakeDescriptor(),
        .events = std.os.linux.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        const count = std.os.linux.poll(&descriptors, descriptors.len, timeout_ms);
        switch (std.os.linux.errno(count)) {
            .SUCCESS => {
                if (count == 0) return null;
                if (count != 1 or descriptors[0].revents != std.os.linux.POLL.IN) {
                    return error.FuzzWakeInvalid;
                }
                return switch (pool.consumeWake()) {
                    .consumed => |batch| batch,
                    .failed => error.FuzzWakeConsumeFailed,
                };
            },
            .INTR => continue,
            else => return error.FuzzWakePollFailed,
        }
    }
}

pub fn fuzzSchedule(harness: *Harness, smith: *std.testing.Smith) !void {
    const selected = [2]u8{
        smith.valueRangeAtMost(u8, 0, scenarios.len - 1),
        smith.valueRangeAtMost(u8, 0, scenarios.len - 1),
    };
    var action_storage: [96]u8 = undefined;
    const actions = action_storage[0..smith.slice(&action_storage)];
    defer harness.forceDrain();
    try harness.prepare(selected);
    for (actions) |action| try harness.step(action);
    try harness.drain();
    try harness.expectQuiescent();
}

pub fn encodedAction(
    comptime kind: ActionKind,
    comptime client: u1,
    comptime variant: u3,
) u8 {
    return @as(u8, client) |
        (@as(u8, @intFromEnum(kind)) << 1) |
        (@as(u8, variant) << 5);
}

pub fn fuzzCase(
    comptime first: u64,
    comptime second: u64,
    comptime actions: []const u8,
) [20 + actions.len]u8 {
    const action_input = fuzz_support.smithInput(actions);
    var input: [20 + actions.len]u8 = undefined;
    std.mem.writeInt(u64, input[0..8], first, .little);
    std.mem.writeInt(u64, input[8..16], second, .little);
    @memcpy(input[16..], &action_input);
    return input;
}

pub const fuzz_corpus = struct {
    const dual_complete = fuzzCase(0, 2, &.{
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 1, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 1, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 1, 7),
        encodedAction(.release_decode, 0, 0),
        encodedAction(.wake, 0, 0),
        encodedAction(.wake, 1, 0),
        encodedAction(.send, 0, 2),
        encodedAction(.send, 1, 2),
    });
    const partial_continue = fuzzCase(1, 0, &.{
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.send, 0, 0),
        encodedAction(.send, 0, 2),
        encodedAction(.receive, 0, 7),
        encodedAction(.release_decode, 0, 0),
        encodedAction(.wake, 0, 0),
        encodedAction(.send, 0, 2),
    });
    const backpressure = fuzzCase(4, 4, &.{
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 1, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 1, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 1, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 1, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 1, 7),
        encodedAction(.resume_receive, 0, 0),
        encodedAction(.resume_receive, 1, 0),
        encodedAction(.release_decode, 0, 0),
        encodedAction(.wake, 0, 7),
        encodedAction(.wake, 1, 0),
    });
    const network_first = fuzzCase(0, 3, &.{
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.stop, 0, 0),
        encodedAction(.cancel, 0, 2),
        encodedAction(.close, 0, 0),
        encodedAction(.arbitrary, 0, 0),
        encodedAction(.release_decode, 0, 0),
        encodedAction(.wake, 0, 0),
    });
    const terminal_first = fuzzCase(0, 3, &.{
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.stop, 0, 0),
        encodedAction(.release_decode, 0, 0),
        encodedAction(.wake, 0, 7),
        encodedAction(.wake, 0, 0),
        encodedAction(.cancel, 0, 2),
        encodedAction(.close, 0, 0),
    });
    const exhausted_and_more = fuzzCase(0, 0, &.{
        encodedAction(.buffer_exhausted, 0, 0),
        encodedAction(.resume_receive, 0, 0),
        encodedAction(.illegal_more, 1, 7),
        encodedAction(.cancel, 1, 2),
        encodedAction(.close, 1, 0),
        encodedAction(.receive, 0, 7),
        encodedAction(.timeout, 0, 0),
        encodedAction(.release_decode, 0, 0),
        encodedAction(.wake, 0, 0),
    });
    const multipart_valid = fuzzCase(5, 0, &.{
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.release_decode, 0, 0),
        encodedAction(.wake, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.send, 0, 2),
    });
    const multipart_reject = fuzzCase(6, 0, &.{
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.release_decode, 0, 0),
        encodedAction(.wake, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.wake, 0, 7),
        encodedAction(.send, 0, 2),
    });
    const upload_rejection_rendezvous = fuzzCase(4, 6, &.{
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 1, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 1, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 1, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 1, 7),
        encodedAction(.receive, 0, 7),
        encodedAction(.receive, 1, 7),
        encodedAction(.resume_receive, 0, 0),
        encodedAction(.resume_receive, 1, 0),
        encodedAction(.release_decode, 0, 0),
        encodedAction(.wake, 0, 7),
        encodedAction(.wake, 1, 0),
    });

    const values = [_][]const u8{
        &dual_complete,
        &partial_continue,
        &backpressure,
        &network_first,
        &terminal_first,
        &exhausted_and_more,
        &upload_rejection_rendezvous,
        &multipart_valid,
        &multipart_reject,
    };
}.values;
