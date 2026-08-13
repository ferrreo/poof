pub const std = @import("std");
pub const builtin = @import("builtin");
pub const application = @import("../../../../src/application.zig");
pub const address = @import("../../../../src/address.zig");
pub const forwarding = @import("../../../../src/forwarding.zig");
pub const response = @import("../../../../src/response.zig");
pub const route = @import("../../../../src/route.zig");
pub const buffer_ring = @import("../../../../src/internal/runtime/buffer_ring.zig");
pub const config = @import("../../../../src/internal/runtime/config.zig");
pub const connection_driver = @import("../../../../src/internal/runtime/connection/driver.zig");
pub const deterministic_reactor = @import(
    "../../../../src/internal/runtime/deterministic_reactor.zig",
);
pub const io_uring_backend = @import("../../../../src/internal/runtime/io_uring/backend.zig");
pub const reactor = @import("../../../../src/internal/runtime/reactor.zig");
pub const worker_storage = @import("../../../../src/internal/runtime/worker/storage.zig");

pub const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
pub const ping_request = "GET /ping HTTP/1.1\r\nHost: example.test\r\n\r\n";
pub const proxy_signature = @import("../../../../src/internal/proxy/protocol_v2.zig").signature;
pub const proxy_tcp4_payload = [12]u8{
    203,  0,    113, 9,
    198,  51,   100, 7,
    0xd4, 0x31, 0,   80,
};
pub const proxy_tcp4 = proxy_signature ++
    [4]u8{ 0x21, 0x11, 0, proxy_tcp4_payload.len } ++ proxy_tcp4_payload;
pub const proxy_tcp6_payload = [36]u8{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9,
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7,
    0x01, 0xbb, 0x1f, 0x90,
};
pub const proxy_tcp6 = proxy_signature ++
    [4]u8{ 0x21, 0x21, 0, proxy_tcp6_payload.len } ++ proxy_tcp6_payload;
pub const proxy_local = proxy_signature ++
    [4]u8{ 0x20, 0xff, 0, 3 } ++ [3]u8{ 0xa5, 0x5a, 0xff };
pub const request_timeout_response =
    "HTTP/1.1 408 Request Timeout\r\n" ++
    "content-length: 0\r\n" ++
    "date: " ++ fixed_date ++ "\r\n" ++
    "connection: close\r\n\r\n";

pub const TestState = struct {
    calls: u16 = 0,
    completed: u16 = 0,
    aborted: u16 = 0,
    client: ?address.Endpoint = null,
    connection_source: ?forwarding.ConnectionSource = null,
    scheme: ?forwarding.Scheme = null,
};

pub const TestContext = application.Context(TestState, response.standard_head_limits);

pub const Observe = struct {
    pub const State = void;

    pub fn init(_: Observe) void {}

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
    const metadata = context.request.forwarding orelse @panic("missing forwarding metadata");
    context.state.calls += 1;
    context.state.client = metadata.client;
    context.state.connection_source = metadata.connection_source;
    context.state.scheme = metadata.scheme;
    return context.textStatic(.ok, "pong");
}

pub const TestApp = application.Application(.{
    .State = TestState,
    .middleware = .{Observe{}},
    .routes = .{route.get("/ping", ping)},
});

pub const test_limits = config.Limits.validate(.{
    .connection_slots = 3,
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
pub const TestReactor = deterministic_reactor.DeterministicReactor(64);
pub const test_forwarding_limits = forwarding.Limits{
    .trusted_matchers_max = 4,
    .hops_max = 4,
    .parameters_per_element_max = 4,
};
pub const TestForwardingProfile = forwarding.Profile(test_forwarding_limits);
pub const TestDriver = connection_driver.ConfiguredDriver(
    TestApp,
    TestStorage,
    TestReactor,
    test_forwarding_limits,
);
pub const undersized_limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 64,
    .pipeline_bytes_per_connection = 64,
    .response_bytes_per_request = 2048,
    .submission_entries = 8,
    .completion_entries = 16,
});
pub const UndersizedStorage = worker_storage.Storage(TestApp, undersized_limits);
pub const UndersizedDriver = connection_driver.Driver(TestApp, UndersizedStorage, TestReactor);

pub const Harness = struct {
    slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined,
    storage: TestStorage = undefined,
    io: TestReactor = .{},
    state: TestState = .{},
    forwarding_profile: TestForwardingProfile = undefined,
    driver: TestDriver = undefined,
    now_ns: u64 = 1,
    buffer_cursor: u16 = 0,
    buffer_generations: [test_limits.receive_buffers]u16 =
        [_]u16{1} ** test_limits.receive_buffers,

    pub fn init(self: *Harness) !void {
        return self.initialize(null);
    }

    pub fn initForwarding(self: *Harness, config_value: forwarding.Config) !void {
        self.forwarding_profile = try TestForwardingProfile.init(config_value);
        return self.initialize(&self.forwarding_profile);
    }

    pub fn initialize(self: *Harness, profile: ?*const TestForwardingProfile) !void {
        self.io = .{};
        self.state = .{};
        try self.storage.init(&self.slab);
        self.driver = if (profile) |value|
            try TestDriver.initForwarding(
                &self.state,
                &self.storage,
                &self.io,
                0,
                .{ .date = fixed_date },
                value,
            )
        else
            try TestDriver.init(
                &self.state,
                &self.storage,
                &self.io,
                0,
                .{ .date = fixed_date },
            );
        self.now_ns = 1;
        self.buffer_cursor = 0;
        self.buffer_generations = [_]u16{1} ** test_limits.receive_buffers;
    }

    pub fn addConnection(self: *Harness, socket: u64) !u16 {
        const index = self.storage.acquireConnection(.{ .value = socket }) orelse {
            return error.TestUnexpectedResult;
        };
        try self.driver.start(index, self.now_ns);
        return index;
    }

    pub fn addAcceptedConnection(
        self: *Harness,
        socket: u64,
        peer: address.Endpoint,
    ) !u16 {
        const index = self.storage.acquireAcceptedConnection(.{
            .socket = .{ .value = socket },
            .peer = peer,
        }) orelse return error.TestUnexpectedResult;
        try self.driver.start(index, self.now_ns);
        return index;
    }

    pub fn receive(
        self: *Harness,
        connection_index: u16,
        bytes: []const u8,
        more: bool,
    ) !connection_driver.Disposition {
        const token = self.storage.connections[connection_index].receive_token orelse {
            return error.TestUnexpectedResult;
        };
        const buffer_index = self.buffer_cursor;
        self.buffer_cursor = (buffer_index + 1) % test_limits.receive_buffers;
        const generation = self.buffer_generations[buffer_index];
        self.buffer_generations[buffer_index] = reactor.nextGeneration(generation);
        return self.complete(token, .{ .success = .{ .receive = .{ .bytes = .{
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
        const completion = self.io.nextCompletion() orelse return error.TestUnexpectedResult;
        return self.driver.handle(completion, self.now_ns);
    }

    pub fn findToken(
        self: *const Harness,
        connection_index: u16,
        kind: reactor.OperationKind,
    ) ?reactor.OperationToken {
        var active_index: u16 = 0;
        while (active_index < self.io.activeCount()) : (active_index += 1) {
            const submission = self.io.activeSubmission(active_index).?;
            const fields = submission.token.fields() catch unreachable;
            if (fields.slot_index == connection_index and fields.kind == kind) {
                return submission.token;
            }
        }
        return null;
    }

    pub fn sendBytes(self: *const Harness, connection_index: u16) []const u8 {
        const token = self.storage.connections[connection_index].send_token.?;
        return self.io.operation(token).?.send.bytes;
    }

    pub fn cancelCurrentTimeout(self: *Harness, connection_index: u16) !void {
        const token = self.storage.connections[connection_index].timeout_token.?;
        _ = try self.complete(token, .{ .failure = .canceled }, false);
    }

    pub fn drainClosing(self: *Harness, connection_index: u16) !void {
        var iterations: u16 = 0;
        while (self.storage.connections[connection_index].phase != .free) {
            if (iterations == 128) return error.TestUnexpectedResult;
            iterations += 1;
            const token = self.findToken(connection_index, .cancel) orelse
                self.findToken(connection_index, .close) orelse
                self.findToken(connection_index, .timeout) orelse
                self.findToken(connection_index, .receive) orelse
                self.findToken(connection_index, .send) orelse
                return error.TestUnexpectedResult;
            const kind = (try token.fields()).kind;
            const result: reactor.CompletionResult = switch (kind) {
                .cancel => .{ .success = .{ .cancel = .canceled } },
                .close => .{ .success = .{ .close = {} } },
                .timeout, .receive, .send => .{ .failure = .canceled },
                .accept,
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
                => return error.TestUnexpectedResult,
            };
            _ = try self.complete(token, result, false);
        }
    }

    pub fn drainRetirements(self: *Harness, connection_index: u16) !void {
        var iterations: u16 = 0;
        while (self.storage.connections[connection_index].phase == .responding and
            self.storage.connections[connection_index].active_request == null and
            self.storage.connections[connection_index].send_token == null)
        {
            if (iterations == 32) return error.TestUnexpectedResult;
            iterations += 1;
            const token = self.findToken(connection_index, .cancel) orelse
                self.findToken(connection_index, .timeout) orelse
                return error.TestUnexpectedResult;
            const kind = (try token.fields()).kind;
            const result: reactor.CompletionResult = if (kind == .cancel)
                .{ .success = .{ .cancel = .canceled } }
            else
                .{ .failure = .canceled };
            _ = try self.complete(token, result, false);
        }
    }
};

pub fn initRequiredProxy(harness: *Harness, trusted: []const []const u8) !void {
    return harness.initForwarding(.{
        .proxy_protocol = .v2_required,
        .untrusted_peer = .reject,
        .trusted = trusted,
    });
}

pub fn expectSilentClosing(harness: *const Harness, connection_index: u16) !void {
    const connection = harness.storage.connections[connection_index];
    try std.testing.expectEqual(worker_storage.ConnectionPhase.closing, connection.phase);
    try std.testing.expect(connection.send_token == null);
    try std.testing.expectEqual(@as(u32, 0), connection.pipeline_write);
    try std.testing.expectEqual(@as(usize, 0), connection.head_decoder.bytes().len);
    try std.testing.expectEqual(@as(u16, 0), harness.state.calls);
}

test {
    _ = @import("connection_driver_test_part_1.zig");
    _ = @import("connection_driver_test_part_2.zig");
}
