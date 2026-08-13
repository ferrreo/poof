const std = @import("std");

const upload = @import("../../../../src/multipart/upload.zig");
const upload_sink_driver = @import("../../../../src/internal/upload/sink_driver.zig");
const buffer_ring = @import("../../../../src/internal/runtime/buffer_ring.zig");
const config = @import("../../../../src/internal/runtime/config.zig");
const io_uring_backend = @import("../../../../src/internal/runtime/io_uring/backend.zig");
const reactor = @import("../../../../src/internal/runtime/reactor.zig");
const upload_transport = @import("../../../../src/internal/runtime/upload/transport.zig");
const upload_transport_validation = @import(
    "../../../../src/internal/runtime/upload/transport_validation.zig",
);

pub const HarnessError = error{
    DriverPollStepLimitExceeded,
    MissingUploadDelivery,
    SubmissionRetryExhausted,
    UnexpectedRollbackDelivery,
};

const driver_poll_steps_max: u8 = 64;
const driver_poll_limit_error: HarnessError = error.DriverPollStepLimitExceeded;

const limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .body_workspace_slots = 1,
    .chunked_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 64,
    .pipeline_bytes_per_connection = 64,
    .response_bytes_per_request = 128,
    .submission_entries = 8,
    .completion_entries = 16,
});

pub fn Harness(comptime Sink: type, comptime buffer_group: u16) type {
    upload.validateSink(Sink);
    const ReceiveBuffers = buffer_ring.BufferRing(2, 64, buffer_group);
    const Backend = io_uring_backend.IoUringBackendWithUploads(
        limits,
        ReceiveBuffers,
        .{
            .connection_slots = limits.connection_slots,
            .body_workspace_slots = limits.body_workspace_slots,
            .upload_window_max = 1,
            .request_handles_max = Sink.request_handles_max,
            .runtime_handles_max = Sink.runtime_handles_max,
            .async_sink_present = true,
        },
    );
    const Transport = upload_transport.Transport(
        u16,
        Backend.file_handle_capacity,
        Backend.file_target_capacity,
    );

    return struct {
        const Self = @This();
        const Owner = upload_transport.Owner;

        pub const RuntimeDriver = upload_sink_driver.Runtime(Sink);
        pub const LifecycleDriver = upload_sink_driver.Lifecycle(Sink);
        pub const WriteDriver = upload_sink_driver.Write(Sink);

        const runtime_owner = Owner{
            .scope = .runtime,
            .registry_index = 1,
            .instance_index = 0,
            .slot = .{
                .worker_index = 0,
                .index = reactor.upload_runtime_control_slot,
                .generation = 1,
            },
        };
        const request_owner = Owner{
            .scope = .request,
            .registry_index = 1,
            .instance_index = 0,
            .slot = .{ .worker_index = 0, .index = 0, .generation = 1 },
        };

        buffers: ReceiveBuffers.Buffers = undefined,
        backend: Backend = undefined,
        transport: Transport = Transport.init(),
        sequence: u16 = 1,
        backend_live: bool = false,

        pub fn init(self: *Self) !void {
            self.* = .{};
            try self.backend.init(&self.buffers);
            self.backend_live = true;
        }

        pub fn abortBackend(self: *Self) void {
            if (!self.backend_live) return;
            _ = self.backend.abort() catch {};
            self.backend_live = false;
        }

        pub fn deinit(self: *Self) !void {
            try self.expectQuiescent();
            try self.backend.deinit();
            self.backend_live = false;
        }

        pub fn runtimeStart(
            self: *Self,
            driver: *RuntimeDriver,
            input: upload.RuntimeStartInput,
        ) !void {
            std.debug.assert(input.worker_index == runtime_owner.slot.worker_index);
            var poll = try driver.startRuntime(input);
            for (0..driver_poll_steps_max) |_| switch (poll) {
                .request => |request| poll = try driver.resumeStart(
                    try self.execute(runtime_owner, request),
                ),
                .done => return,
            };
            return driver_poll_limit_error;
        }

        pub fn runtimeStop(self: *Self, driver: *RuntimeDriver) !void {
            var poll = try driver.startStop();
            for (0..driver_poll_steps_max) |_| switch (poll) {
                .request => |request| poll = try driver.resumeStop(
                    try self.execute(runtime_owner, request),
                ),
                .done => return,
            };
            return driver_poll_limit_error;
        }

        pub fn begin(
            self: *Self,
            driver: *LifecycleDriver,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            input: Sink.BeginInput,
        ) !void {
            var poll = try driver.startBegin(runtime, state, input);
            for (0..driver_poll_steps_max) |_| switch (poll) {
                .request => |request| poll = try driver.resumeBegin(
                    runtime,
                    state,
                    try self.execute(request_owner, request),
                ),
                .done => return,
            };
            return driver_poll_limit_error;
        }

        pub fn write(
            self: *Self,
            driver: *WriteDriver,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            input: upload.WriteInput,
        ) !void {
            var poll = try driver.start(runtime, state, input);
            for (0..driver_poll_steps_max) |_| switch (poll) {
                .request => |request| poll = try driver.resumeWrite(
                    runtime,
                    state,
                    try self.execute(request_owner, request),
                ),
                .done => return,
            };
            return driver_poll_limit_error;
        }

        pub fn finish(
            self: *Self,
            driver: *LifecycleDriver,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            input: upload.FinishInput,
        ) !Sink.Summary {
            var poll = try driver.startFinish(runtime, state, input);
            for (0..driver_poll_steps_max) |_| switch (poll) {
                .request => |request| poll = try driver.resumeFinish(
                    runtime,
                    state,
                    try self.execute(request_owner, request),
                ),
                .done => |summary| return summary,
            };
            return driver_poll_limit_error;
        }

        pub fn commit(
            self: *Self,
            driver: *LifecycleDriver,
            runtime: *Sink.Runtime,
            state: *Sink.State,
        ) !void {
            var poll = try driver.startCommit(runtime, state);
            for (0..driver_poll_steps_max) |_| switch (poll) {
                .request => |request| poll = try driver.resumeCommit(
                    runtime,
                    state,
                    try self.execute(request_owner, request),
                ),
                .done => return,
            };
            return driver_poll_limit_error;
        }

        pub fn abort(
            self: *Self,
            driver: *LifecycleDriver,
            runtime: *Sink.Runtime,
            state: *Sink.State,
        ) !void {
            var poll = try driver.startAbort(runtime, state);
            for (0..driver_poll_steps_max) |_| switch (poll) {
                .request => |request| poll = try driver.resumeAbort(
                    runtime,
                    state,
                    try self.execute(request_owner, request),
                ),
                .done => return,
            };
            return driver_poll_limit_error;
        }

        fn execute(
            self: *Self,
            owner: Owner,
            request: upload.IoRequest,
        ) !upload.IoCompletion {
            const sequence = self.sequence;
            self.sequence = reactor.nextSequence(sequence);
            const token = try reactor.OperationToken.init(.{
                .kind = upload_transport_validation.expectedKind(
                    std.meta.activeTag(request),
                ),
                .worker_index = owner.slot.worker_index,
                .slot_index = owner.slot.index,
                .slot_generation = owner.slot.generation,
                .sequence = sequence,
            });
            const submission = try self.transport.prepareTarget(
                owner,
                token,
                sequence,
                request,
            );
            self.backend.submit(submission) catch |problem| {
                const rolled_back = try self.transport.rollback(token);
                if (rolled_back != null) return error.UnexpectedRollbackDelivery;
                return problem;
            };
            try self.transport.markSubmitted(token);
            try self.flush();
            const delivery = (try self.transport.complete(try self.backend.wait())) orelse
                return error.MissingUploadDelivery;
            try std.testing.expectEqual(sequence, delivery.cookie);
            return delivery.completion;
        }

        fn flush(self: *Self) !void {
            var retries: u8 = 0;
            while (true) {
                _ = self.backend.flush() catch |problem| switch (problem) {
                    error.SubmissionRetry => {
                        if (retries == 63) return error.SubmissionRetryExhausted;
                        retries += 1;
                        continue;
                    },
                    else => return problem,
                };
                return;
            }
        }

        fn expectQuiescent(self: *Self) !void {
            try std.testing.expect(!self.transport.fatal());
            try std.testing.expect(self.transport.ownershipProven());
            try std.testing.expectEqual(@as(u32, 0), self.transport.pendingTargets());
            try std.testing.expectEqual(@as(u32, 0), self.transport.pendingCancellations());
            try std.testing.expectEqual(@as(u32, 0), self.transport.tableConst().active());
            try std.testing.expectEqual(@as(u32, 0), self.backend.queuedCount());
            try std.testing.expectEqual(@as(u32, 0), self.backend.activeCount());
            try std.testing.expectEqual(@as(u32, 0), self.backend.trackedTokenCount());
            try std.testing.expectEqual(@as(u16, 0), self.backend.borrowedCount());
        }
    };
}
