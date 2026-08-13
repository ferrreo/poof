const std = @import("std");

const reactor = @import("reactor.zig");

pub const Phase = enum(u8) {
    idle,
    accepting,
    paused,
    backoff,
    stopping,
    stopped,
};

pub const Event = union(enum) {
    none,
    accepted: u16,
    stopped,
};

pub const Error = error{
    AlreadyStarted,
    InvalidCompletion,
    AcceptFailed,
    CancelFailed,
    RetryFailed,
    ClockOverflow,
    CloseFailed,
};

const resource_backoff_ns: u64 = 10 * std.time.ns_per_ms;

/// Owns one worker listener's single-shot accept lifetime and slot backpressure.
pub const Controller = struct {
    const listener_slot = std.math.maxInt(u16);

    listener: reactor.Socket,
    worker_index: u16,
    generation: u16 = 1,
    sequence: u16 = 1,
    phase: Phase = .idle,
    accept_token: ?reactor.OperationToken = null,
    cancel_token: ?reactor.OperationToken = null,
    retry_token: ?reactor.OperationToken = null,

    pub fn init(worker_index: u16, listener: reactor.Socket) Controller {
        std.debug.assert(worker_index <= reactor.max_worker_index);
        const controller = Controller{ .listener = listener, .worker_index = worker_index };
        controller.assertInvariants();
        return controller;
    }

    pub fn start(self: *Controller, storage: anytype, backend: anytype) !void {
        if (self.phase != .idle) return error.AlreadyStarted;
        if (storage.connection_pool.available() == 0) {
            self.phase = .paused;
            self.assertInvariants();
            return;
        }
        try self.armAccept(backend);
        self.phase = .accepting;
        self.assertInvariants();
    }

    pub fn handle(
        self: *Controller,
        completion: reactor.Completion,
        storage: anytype,
        backend: anytype,
        now_ns: u64,
    ) !Event {
        if (completion.validate() != null) {
            try discardAccepted(completion, backend);
            return error.InvalidCompletion;
        }
        const fields = completion.token.fields() catch return error.InvalidCompletion;
        if (fields.worker_index != self.worker_index) return error.InvalidCompletion;
        if (fields.slot_index != listener_slot) return error.InvalidCompletion;
        if (fields.slot_generation != self.generation) return error.InvalidCompletion;

        const event = switch (fields.kind) {
            .accept => try self.handleAccept(completion, storage, backend, now_ns),
            .cancel => try self.handleCancel(completion),
            .timeout => try self.handleRetry(completion, storage, backend),
            .receive,
            .send,
            .close,
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
            => error.InvalidCompletion,
        };
        self.assertInvariants();
        return event;
    }

    fn discardAccepted(completion: reactor.Completion, backend: anytype) !void {
        switch (completion.result) {
            .failure => {},
            .success => |success| switch (success) {
                .accept => |accepted| backend.discard(accepted.socket) catch
                    return error.CloseFailed,
                else => {},
            },
        }
    }

    /// Call only after storage has returned one connection slot.
    pub fn capacityReturned(self: *Controller, storage: anytype, backend: anytype) !void {
        std.debug.assert(storage.connection_pool.available() != 0);
        switch (self.phase) {
            .paused => {
                std.debug.assert(self.accept_token == null);
                std.debug.assert(self.cancel_token == null);
                std.debug.assert(self.retry_token == null);
                try self.armAccept(backend);
                self.phase = .accepting;
            },
            else => {},
        }
        self.assertInvariants();
    }

    pub fn stop(self: *Controller, backend: anytype) !void {
        switch (self.phase) {
            .idle => self.phase = .stopped,
            .accepting => {
                try self.cancelAccept(backend);
                self.phase = .stopping;
            },
            .paused => self.phase = .stopped,
            .backoff => {
                try self.cancelRetry(backend);
                self.phase = .stopping;
            },
            .stopping, .stopped => {},
        }
        self.assertInvariants();
    }

    pub fn isStopped(self: *const Controller) bool {
        self.assertInvariants();
        return self.phase == .stopped;
    }

    /// Fatal-only userspace reset after reactor ownership has been resolved.
    pub fn abort(self: *Controller) void {
        self.accept_token = null;
        self.cancel_token = null;
        self.retry_token = null;
        self.generation = reactor.nextGeneration(self.generation);
        self.phase = .stopped;
        self.assertInvariants();
    }

    fn handleAccept(
        self: *Controller,
        completion: reactor.Completion,
        storage: anytype,
        backend: anytype,
        now_ns: u64,
    ) !Event {
        const current = self.accept_token orelse return error.InvalidCompletion;
        if (!current.eql(completion.token)) return error.InvalidCompletion;
        self.accept_token = null;

        var event: Event = .none;
        switch (completion.result) {
            .success => |success| switch (success) {
                .accept => |accepted| {
                    if (storage.acquireAcceptedConnection(accepted)) |connection_index| {
                        event = .{ .accepted = connection_index };
                    } else {
                        backend.discard(accepted.socket) catch return error.CloseFailed;
                    }
                },
                else => return error.InvalidCompletion,
            },
            .failure => |failure| {
                switch (failure) {
                    .transient_accept, .connection_aborted => {},
                    .resource_exhausted => if (self.phase == .accepting) {
                        try self.armRetry(backend, now_ns);
                        self.phase = .backoff;
                        return .none;
                    },
                    .canceled => switch (self.phase) {
                        .stopping => {},
                        else => return error.AcceptFailed,
                    },
                    .connection_reset,
                    .broken_pipe,
                    .not_connected,
                    .already_exists,
                    .not_found,
                    .invalid_path,
                    .cross_device,
                    .read_only,
                    .quota_exceeded,
                    .file_too_large,
                    .no_space,
                    .unsupported,
                    .io_failure,
                    .permission_denied,
                    .buffer_exhausted,
                    .invalid_resource,
                    .backend_failure,
                    => return error.AcceptFailed,
                }
            },
        }

        try self.updateAcceptState(storage, backend);
        if (self.phase == .stopped and event == .none) return .stopped;
        return event;
    }

    fn handleCancel(
        self: *Controller,
        completion: reactor.Completion,
    ) !Event {
        const current = self.cancel_token orelse return error.InvalidCompletion;
        if (!current.eql(completion.token) or completion.more) {
            return error.InvalidCompletion;
        }
        self.cancel_token = null;
        switch (completion.result) {
            .success => |success| switch (success) {
                .cancel => {},
                else => return error.InvalidCompletion,
            },
            .failure => return error.CancelFailed,
        }
        self.settle();
        return if (self.phase == .stopped) .stopped else .none;
    }

    fn handleRetry(
        self: *Controller,
        completion: reactor.Completion,
        storage: anytype,
        backend: anytype,
    ) !Event {
        const current = self.retry_token orelse return error.InvalidCompletion;
        if (!current.eql(completion.token) or completion.more) {
            return error.InvalidCompletion;
        }
        self.retry_token = null;
        switch (completion.result) {
            .success => |success| if (success != .timeout) return error.InvalidCompletion,
            .failure => |failure| if (failure != .canceled) return error.RetryFailed,
        }
        if (self.phase == .backoff) {
            if (storage.connection_pool.available() == 0) {
                self.phase = .paused;
            } else {
                try self.armAccept(backend);
                self.phase = .accepting;
            }
        } else if (self.phase == .stopping) {
            self.settle();
        } else {
            return error.InvalidCompletion;
        }
        return if (self.phase == .stopped) .stopped else .none;
    }

    fn updateAcceptState(self: *Controller, storage: anytype, backend: anytype) !void {
        switch (self.phase) {
            .accepting => {
                if (storage.connection_pool.available() == 0) {
                    std.debug.assert(self.accept_token == null);
                    self.phase = .paused;
                } else {
                    std.debug.assert(self.accept_token == null);
                    try self.armAccept(backend);
                }
            },
            .stopping => self.settle(),
            .idle, .paused, .backoff, .stopped => return error.InvalidCompletion,
        }
    }

    fn settle(self: *Controller) void {
        if (self.accept_token != null or self.cancel_token != null or
            self.retry_token != null) return;
        std.debug.assert(self.phase == .stopping);
        self.phase = .stopped;
    }

    fn armAccept(self: *Controller, backend: anytype) !void {
        std.debug.assert(self.accept_token == null);
        const token = try self.makeToken(.accept);
        try backend.submit(.{
            .token = token,
            .operation = .{ .accept = .{ .listener = self.listener } },
        });
        self.accept_token = token;
        self.advanceSequence();
    }

    fn cancelAccept(self: *Controller, backend: anytype) !void {
        const target = self.accept_token orelse return;
        std.debug.assert(self.cancel_token == null);
        const token = try self.makeToken(.cancel);
        try backend.submit(.{
            .token = token,
            .operation = .{ .cancel = .{ .target = target } },
        });
        self.cancel_token = token;
        self.advanceSequence();
    }

    fn armRetry(self: *Controller, backend: anytype, now_ns: u64) !void {
        std.debug.assert(self.retry_token == null);
        const deadline_ns = std.math.add(u64, now_ns, resource_backoff_ns) catch {
            return error.ClockOverflow;
        };
        const token = try self.makeToken(.timeout);
        try backend.submit(.{
            .token = token,
            .operation = .{ .timeout = .{ .deadline_ns = deadline_ns } },
        });
        self.retry_token = token;
        self.advanceSequence();
    }

    fn cancelRetry(self: *Controller, backend: anytype) !void {
        const target = self.retry_token orelse return;
        std.debug.assert(self.cancel_token == null);
        const token = try self.makeToken(.cancel);
        try backend.submit(.{
            .token = token,
            .operation = .{ .cancel = .{ .target = target } },
        });
        self.cancel_token = token;
        self.advanceSequence();
    }

    fn makeToken(
        self: *const Controller,
        kind: reactor.OperationKind,
    ) reactor.TokenError!reactor.OperationToken {
        return reactor.OperationToken.init(.{
            .kind = kind,
            .worker_index = self.worker_index,
            .slot_index = listener_slot,
            .slot_generation = self.generation,
            .sequence = self.sequence,
        });
    }

    fn advanceSequence(self: *Controller) void {
        self.sequence = reactor.nextSequence(self.sequence);
    }

    fn assertInvariants(self: *const Controller) void {
        std.debug.assert(self.worker_index <= reactor.max_worker_index);
        std.debug.assert(self.generation != 0);
        std.debug.assert(self.sequence != 0);
        switch (self.phase) {
            .idle, .paused, .stopped => {
                std.debug.assert(self.accept_token == null);
                std.debug.assert(self.cancel_token == null);
                std.debug.assert(self.retry_token == null);
            },
            .accepting => {
                std.debug.assert(self.accept_token != null);
                std.debug.assert(self.cancel_token == null);
                std.debug.assert(self.retry_token == null);
            },
            .backoff => {
                std.debug.assert(self.accept_token == null);
                std.debug.assert(self.cancel_token == null);
                std.debug.assert(self.retry_token != null);
            },
            .stopping => {
                if (self.accept_token == null) {
                    if (self.cancel_token == null) std.debug.assert(self.retry_token != null);
                }
            },
        }
    }
};

const config = @import("config.zig");
const deterministic_reactor = @import("deterministic_reactor.zig");
const worker_storage = @import("worker/storage.zig");

const TestApp = struct {
    pub const Workspace = struct { marker: u8 = 0 };
};
const test_limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 64,
    .pipeline_bytes_per_connection = 64,
    .response_bytes_per_request = 256,
    .submission_entries = 8,
    .completion_entries = 16,
});
const TestStorage = worker_storage.Storage(TestApp, test_limits);
const TestReactor = deterministic_reactor.DeterministicReactor(8);

test "single-shot accept stops at capacity and rearms only after release" {
    var slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined;
    var storage: TestStorage = undefined;
    try storage.init(&slab);
    var backend = TestReactor{};
    var controller = Controller.init(0, .{ .value = 4 });
    try controller.start(&storage, &backend);

    const accept = controller.accept_token.?;
    try std.testing.expectError(
        error.InvalidCompletion,
        controller.handle(.{
            .token = accept,
            .result = .{ .success = .{ .accept = reactor.Accepted.loopback(.{ .value = 10 }) } },
            .more = true,
        }, &storage, &backend, 1),
    );
    try std.testing.expectEqual(@as(u64, 1), backend.discardedCount());
    try backend.complete(
        accept,
        .{ .success = .{ .accept = reactor.Accepted.loopback(.{ .value = 11 }) } },
        false,
    );
    const first = try controller.handle(backend.nextCompletion().?, &storage, &backend, 1);
    const connection_index = switch (first) {
        .accepted => |index| index,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(Phase.paused, controller.phase);
    try std.testing.expectEqual(@as(u16, 0), storage.connection_pool.available());
    try std.testing.expectEqual(@as(u16, 0), backend.activeCount());
    try std.testing.expect(controller.accept_token == null);

    storage.connections[connection_index].phase = .closing;
    storage.connections[connection_index].receive_terminal_reaped = true;
    storage.connections[connection_index].socket_closed = true;
    storage.releaseConnection(connection_index);
    try controller.capacityReturned(&storage, &backend);
    try std.testing.expectEqual(Phase.accepting, controller.phase);
    const resumed_accept = controller.accept_token.?;
    try std.testing.expect(!resumed_accept.eql(accept));

    try controller.stop(&backend);
    const stop_cancel = controller.cancel_token.?;
    try backend.complete(stop_cancel, .{ .success = .{ .cancel = .canceled } }, false);
    _ = try controller.handle(backend.nextCompletion().?, &storage, &backend, 1);
    try std.testing.expectEqual(Phase.stopping, controller.phase);
    try backend.complete(resumed_accept, .{ .failure = .canceled }, false);
    try std.testing.expectEqual(
        Event.stopped,
        try controller.handle(backend.nextCompletion().?, &storage, &backend, 1),
    );
    try std.testing.expect(controller.isStopped());
    try std.testing.expectEqual(@as(u16, 0), backend.activeCount());
}

test "accept success after stop preserves socket ownership event" {
    var slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined;
    var storage: TestStorage = undefined;
    try storage.init(&slab);
    var backend = TestReactor{};
    var controller = Controller.init(0, .{ .value = 4 });
    try controller.start(&storage, &backend);

    const accept = controller.accept_token.?;
    try controller.stop(&backend);
    const cancel = controller.cancel_token.?;
    try backend.complete(cancel, .{ .success = .{ .cancel = .not_found } }, false);
    try std.testing.expectEqual(
        Event.none,
        try controller.handle(backend.nextCompletion().?, &storage, &backend, 1),
    );

    try backend.complete(
        accept,
        .{ .success = .{ .accept = reactor.Accepted.loopback(.{ .value = 12 }) } },
        false,
    );
    const event = try controller.handle(backend.nextCompletion().?, &storage, &backend, 1);
    const connection_index = switch (event) {
        .accepted => |index| index,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(controller.isStopped());
    try std.testing.expectEqual(@as(u16, 0), storage.connection_pool.available());

    storage.connections[connection_index].phase = .closing;
    storage.connections[connection_index].receive_terminal_reaped = true;
    storage.connections[connection_index].socket_closed = true;
    storage.releaseConnection(connection_index);
}

test "accept retries peer failures and backs off resource exhaustion" {
    var slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined;
    var storage: TestStorage = undefined;
    try storage.init(&slab);
    var backend = TestReactor{};
    var controller = Controller.init(0, .{ .value = 4 });
    try controller.start(&storage, &backend);

    const first_accept = controller.accept_token.?;
    try backend.complete(first_accept, .{ .failure = .transient_accept }, false);
    _ = try controller.handle(backend.nextCompletion().?, &storage, &backend, 100);
    try std.testing.expectEqual(Phase.accepting, controller.phase);
    try std.testing.expect(!controller.accept_token.?.eql(first_accept));

    const second_accept = controller.accept_token.?;
    try backend.complete(second_accept, .{ .failure = .resource_exhausted }, false);
    _ = try controller.handle(backend.nextCompletion().?, &storage, &backend, 200);
    try std.testing.expectEqual(Phase.backoff, controller.phase);
    try std.testing.expect(controller.accept_token == null);
    const retry = controller.retry_token.?;
    try std.testing.expectEqual(
        @as(u64, 200 + resource_backoff_ns),
        backend.operation(retry).?.timeout.deadline_ns,
    );

    try backend.complete(retry, .{ .success = .{ .timeout = {} } }, false);
    _ = try controller.handle(backend.nextCompletion().?, &storage, &backend, 201);
    try std.testing.expectEqual(Phase.accepting, controller.phase);
    try std.testing.expect(controller.accept_token != null);
}

test "accept stop cancels resource backoff with cancel completion first" {
    var slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined;
    var storage: TestStorage = undefined;
    try storage.init(&slab);
    var backend = TestReactor{};
    var controller = Controller.init(0, .{ .value = 4 });
    try controller.start(&storage, &backend);

    const accept = controller.accept_token.?;
    try backend.complete(accept, .{ .failure = .resource_exhausted }, false);
    _ = try controller.handle(backend.nextCompletion().?, &storage, &backend, 100);
    const retry = controller.retry_token.?;
    try controller.stop(&backend);
    const cancel = controller.cancel_token.?;
    try std.testing.expectEqual(Phase.stopping, controller.phase);

    try backend.complete(cancel, .{ .success = .{ .cancel = .canceled } }, false);
    _ = try controller.handle(backend.nextCompletion().?, &storage, &backend, 101);
    try std.testing.expectEqual(Phase.stopping, controller.phase);
    try backend.complete(retry, .{ .failure = .canceled }, false);
    try std.testing.expectEqual(
        Event.stopped,
        try controller.handle(backend.nextCompletion().?, &storage, &backend, 101),
    );
    try std.testing.expect(controller.isStopped());
    try std.testing.expectEqual(@as(u16, 0), backend.activeCount());
}

test "accept stop settles when resource timeout completion wins cancellation race" {
    var slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined;
    var storage: TestStorage = undefined;
    try storage.init(&slab);
    var backend = TestReactor{};
    var controller = Controller.init(0, .{ .value = 4 });
    try controller.start(&storage, &backend);

    const accept = controller.accept_token.?;
    try backend.complete(accept, .{ .failure = .resource_exhausted }, false);
    _ = try controller.handle(backend.nextCompletion().?, &storage, &backend, 100);
    const retry = controller.retry_token.?;
    try controller.stop(&backend);
    const cancel = controller.cancel_token.?;

    try backend.complete(retry, .{ .success = .{ .timeout = {} } }, false);
    _ = try controller.handle(backend.nextCompletion().?, &storage, &backend, 101);
    try std.testing.expectEqual(Phase.stopping, controller.phase);
    try backend.complete(cancel, .{ .success = .{ .cancel = .not_found } }, false);
    try std.testing.expectEqual(
        Event.stopped,
        try controller.handle(backend.nextCompletion().?, &storage, &backend, 101),
    );
    try std.testing.expectEqual(@as(u16, 0), backend.activeCount());
}
