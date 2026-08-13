const std = @import("std");
const linux = std.os.linux;

const buffer_ring = @import("../buffer_ring.zig");
const config = @import("../config.zig");
const io_uring_abort = @import("abort.zig");
const io_uring_backend_flush = @import("backend_flush.zig");
const io_uring_backend_upload = @import("backend_upload.zig");
const io_uring_completion = @import("completion.zig");
const io_uring_errors = @import("errors.zig");
const io_uring_peer = @import("peer.zig");
const io_uring_token_table = @import("token_table.zig");
const io_uring_wake = @import("wake.zig");
const io_uring_probe_types = @import("../../io_uring/probe_types.zig");
const reactor = @import("../reactor.zig");
const runtime_socket = @import("../socket.zig");

const IoUring = linux.IoUring;
const nanoseconds_per_second: u64 = std.time.ns_per_s;
const required_setup_flags = io_uring_probe_types.reactor_capability_manifest.setup_flags;
const required_features = io_uring_probe_types.reactor_capability_manifest.feature_mask;

pub const SubmitError = error{
    BackendClosed,
    FatalInvariant,
    InvalidSubmission,
    InvalidSocket,
    InvalidWakeSource,
    DuplicateToken,
    AcceptAlreadyPending,
    FlushRequired,
    OperationCapacityExhausted,
    SendTooLarge,
    SubmissionQueueFull,
};

pub const FlushError = error{ BackendClosed, FatalInvariant, SubmissionFailed, SubmissionRetry };

pub const PollError = error{
    BackendClosed,
    FatalInvariant,
    InvalidCompletion,
    ReceiveBufferFailure,
    WaitFailed,
    WaitInterrupted,
    WaitRetry,
    NoActiveOperation,
    UnflushedSubmissions,
};

pub const RecycleError = error{ BackendClosed, InvalidBorrow, StaleBorrow, ReceiveBufferFailure };

pub const DeinitError = error{ BackendClosed, NotQuiescent, ReceiveBufferFailure };

pub const DiscardError = runtime_socket.DiscardError;
pub const AbortError = error{BackendClosed};
pub const RingInitError = io_uring_errors.RingInitError;
const State = enum(u8) { ready, fatal, closed };

pub fn completionWorkPending(active_count: u32, cq_ready: u32, cq_needs_flush: bool) bool {
    return active_count != 0 or cq_ready != 0 or cq_needs_flush;
}

pub fn IoUringBackend(
    comptime limits_value: config.Limits,
    comptime ReceiveBufferRing: type,
) type {
    return backendType(limits_value, ReceiveBufferRing, null);
}

pub fn IoUringBackendWithUploads(
    comptime limits_value: config.Limits,
    comptime ReceiveBufferRing: type,
    comptime upload_inputs: io_uring_backend_upload.Inputs,
) type {
    return backendType(limits_value, ReceiveBufferRing, upload_inputs);
}

pub fn IoUringBackendWithFiles(
    comptime limits_value: config.Limits,
    comptime ReceiveBufferRing: type,
    comptime file_inputs: io_uring_backend_upload.Inputs,
) type {
    return backendType(limits_value, ReceiveBufferRing, file_inputs);
}

fn backendType(
    comptime limits_value: config.Limits,
    comptime ReceiveBufferRing: type,
    comptime upload_inputs: ?io_uring_backend_upload.Inputs,
) type {
    const limits = config.Limits.validate(limits_value);
    const capacity = io_uring_backend_upload.capacity(limits, upload_inputs);
    const files_enabled = capacity.file_target_capacity != 0 or
        capacity.file_handle_capacity != 0;
    comptime {
        if (ReceiveBufferRing.count != limits.receive_buffers) {
            @compileError("receive buffer ring count differs from runtime limits");
        }
        if (ReceiveBufferRing.size != limits.receive_buffer_bytes) {
            @compileError("receive buffer ring size differs from runtime limits");
        }
    }

    return struct {
        const Self = @This();
        pub const operation_capacity = capacity.operation_capacity;
        pub const file_target_capacity = capacity.file_target_capacity;
        pub const file_lease_capacity = capacity.file_lease_capacity;
        pub const file_handle_capacity = capacity.file_handle_capacity;
        pub const direct = true;
        const token_table_size = io_uring_token_table.size(operation_capacity);
        const BufferOwners = [ReceiveBufferRing.count]?reactor.SlotIdentity;
        const BufferGenerations = [ReceiveBufferRing.count]u16;
        const TimeoutStorage = [limits.submission_entries]linux.kernel_timespec;
        const UploadMetadata = io_uring_backend_upload.Metadata(
            files_enabled,
            limits.submission_entries,
        );
        const TokenTable = [token_table_size]u64;

        pub const InitError = ReceiveBufferRing.RegisterError || RingInitError;
        pub const external_provided_buffer_bytes = @sizeOf(ReceiveBufferRing.Buffers);
        pub const MemoryMappings = struct {
            provided_buffer_descriptors: usize,
            sq_cq: usize,
            sqes: usize,
        };

        ring: IoUring,
        receive_buffers: ReceiveBufferRing,
        timeout_storage: TimeoutStorage = undefined,
        upload_metadata: UploadMetadata = .{},
        buffer_owners: BufferOwners = [_]?reactor.SlotIdentity{null} **
            ReceiveBufferRing.count,
        buffer_generations: BufferGenerations = [_]u16{1} ** ReceiveBufferRing.count,
        tokens: TokenTable = [_]u64{0} ** token_table_size,
        accept_address: linux.sockaddr.storage = undefined,
        accept_address_length: linux.socklen_t = @sizeOf(linux.sockaddr.storage),
        accept_pending: bool = false,
        queued_count: u32 = 0,
        queued_timeouts: u16 = 0,
        active_count: u32 = 0,
        token_count: u32 = 0,
        accepted_sockets_discarded: u32 = 0,
        submission_retry_pending: bool = false,
        ownership_unproven: bool = false,
        state: State = .ready,

        pub fn init(self: *Self, buffers: *ReceiveBufferRing.Buffers) InitError!void {
            self.* = .{
                .ring = undefined,
                .receive_buffers = ReceiveBufferRing.init(),
                .state = .closed,
            };
            var parameters = std.mem.zeroInit(linux.io_uring_params, .{
                .flags = required_setup_flags,
                .cq_entries = limits.completion_entries,
            });
            self.ring = IoUring.init_params(limits.submission_entries, &parameters) catch |err| {
                return io_uring_errors.ringInitError(err);
            };
            errdefer self.ring.deinit();

            if (parameters.sq_entries != limits.submission_entries or
                parameters.cq_entries != limits.completion_entries or
                parameters.flags != required_setup_flags)
            {
                return error.RingShapeMismatch;
            }
            if (parameters.features & required_features != required_features) {
                return error.RequiredFeatureMissing;
            }
            if (self.ring.sq.dropped.* != 0 or self.ring.cq.overflow.* != 0) {
                return error.RingInvariantViolated;
            }

            try self.receive_buffers.register(&self.ring, buffers);
            self.state = .ready;
            self.assertInvariants();
        }

        pub fn submit(self: *Self, submission: reactor.Submission) SubmitError!void {
            try self.requireReadyForSubmit();
            if (submission.validate() != null) return error.InvalidSubmission;
            const upload = io_uring_backend_upload.isSubmission(submission);
            if (!files_enabled and upload) return error.InvalidSubmission;
            if (self.queued_count >= limits.submission_entries) return error.SubmissionQueueFull;
            const token = submission.token.raw();
            const token_slot = try self.vacantTokenSlot(token);
            if (upload) try self.queueUpload(submission) else try self.queueNetwork(submission);
            self.tokens[token_slot] = token;
            self.token_count += 1;
            self.queued_count += 1;
            self.assertInvariants();
        }

        fn queueNetwork(self: *Self, submission: reactor.Submission) SubmitError!void {
            const token = submission.token.raw();
            switch (submission.operation) {
                .accept => |operation| {
                    if (self.accept_pending) return error.AcceptAlreadyPending;
                    const fd = try runtime_socket.descriptor(operation.listener);
                    self.accept_address_length = @sizeOf(linux.sockaddr.storage);
                    _ = self.ring.accept(
                        token,
                        fd,
                        @ptrCast(&self.accept_address),
                        &self.accept_address_length,
                        linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
                    ) catch return error.SubmissionQueueFull;
                    self.accept_pending = true;
                },
                .receive => |operation| {
                    const fd = try runtime_socket.descriptor(operation.socket);
                    const sqe = self.ring.recv(token, fd, .{ .buffer_selection = .{
                        .group_id = ReceiveBufferRing.group,
                        .len = 0,
                    } }, 0) catch return error.SubmissionQueueFull;
                    if (operation.multishot) sqe.ioprio |= linux.IORING_RECV_MULTISHOT;
                },
                .send => |operation| {
                    const fd = try runtime_socket.descriptor(operation.socket);
                    if (operation.bytes.len > std.math.maxInt(u32)) return error.SendTooLarge;
                    _ = self.ring.send(
                        token,
                        fd,
                        operation.bytes,
                        linux.MSG.NOSIGNAL,
                    ) catch return error.SubmissionQueueFull;
                },
                .close => |operation| {
                    const fd = try runtime_socket.descriptor(operation.socket);
                    _ = self.ring.close(token, fd) catch return error.SubmissionQueueFull;
                },
                .timeout => |operation| {
                    std.debug.assert(self.queued_timeouts < limits.submission_entries);
                    const index = self.queued_timeouts;
                    self.timeout_storage[index] = deadlineTimespec(operation.deadline_ns);
                    _ = self.ring.timeout(
                        token,
                        &self.timeout_storage[index],
                        0,
                        linux.IORING_TIMEOUT_ABS,
                    ) catch return error.SubmissionQueueFull;
                    self.queued_timeouts += 1;
                },
                .wake => |operation| try io_uring_wake.submit(
                    &self.ring,
                    token,
                    operation.source,
                ),
                .cancel => |operation| {
                    _ = self.ring.cancel(token, operation.target.raw(), 0) catch
                        return error.SubmissionQueueFull;
                },
                else => unreachable,
            }
        }

        fn queueUpload(self: *Self, submission: reactor.Submission) SubmitError!void {
            if (comptime files_enabled) {
                io_uring_backend_upload.prepare(
                    &self.ring,
                    &self.upload_metadata,
                    submission,
                ) catch |problem| switch (problem) {
                    error.SubmissionQueueFull => return error.SubmissionQueueFull,
                    error.InvalidSubmission,
                    error.OpenStorageFull,
                    error.LinkStorageFull,
                    => {
                        self.state = .fatal;
                        return error.FatalInvariant;
                    },
                };
            } else unreachable;
        }

        pub fn flush(self: *Self) FlushError!u32 {
            try self.requireReadyForFlush();
            if (self.queued_count == 0) return 0;

            const outcome = io_uring_backend_flush.submit(
                &self.ring,
                &self.queued_count,
                &self.active_count,
                &self.submission_retry_pending,
            ) catch |problem| {
                self.state = .fatal;
                return switch (problem) {
                    error.InvalidState => error.FatalInvariant,
                    error.SubmissionFailed => error.SubmissionFailed,
                };
            };
            self.assertInvariants();
            switch (outcome) {
                .retry_without_progress => {},
                .retry_partial, .complete => try self.checkCounters(FlushError),
            }
            io_uring_backend_flush.releaseStableStorage(
                outcome,
                &self.queued_timeouts,
                &self.upload_metadata,
            );
            return switch (outcome) {
                .retry_without_progress, .retry_partial => error.SubmissionRetry,
                .complete => |submitted| submitted,
            };
        }

        pub fn poll(self: *Self) PollError!?reactor.Completion {
            try self.requireReadyForCompletion();
            if (!completionWorkPending(
                self.active_count,
                self.ring.cq_ready(),
                self.ring.cq_ring_needs_flush(),
            )) return null;
            var raw: [1]linux.io_uring_cqe = undefined;
            var count = self.ring.copy_cqes(&raw, 0) catch |err| {
                return self.waitError(err);
            };
            if (count == 0) {
                _ = self.ring.enter(0, 0, linux.IORING_ENTER_GETEVENTS) catch |err| {
                    return self.waitError(err);
                };
                count = self.ring.copy_cqes(&raw, 0) catch |err| {
                    return self.waitError(err);
                };
            }
            try self.checkCounters(PollError);
            if (count == 0) {
                if (self.unconsumedCompletionWork()) return error.WaitRetry;
                return null;
            }
            std.debug.assert(count == 1);
            return try self.consume(raw[0]);
        }

        pub fn wait(self: *Self) PollError!reactor.Completion {
            try self.requireReadyForCompletion();
            if (self.active_count == 0) {
                if (self.queued_count != 0) return error.UnflushedSubmissions;
                if (!self.unconsumedCompletionWork()) return error.NoActiveOperation;
                return (try self.poll()) orelse error.NoActiveOperation;
            }

            var raw: [1]linux.io_uring_cqe = undefined;
            while (true) {
                std.debug.assert(self.active_count != 0);
                const count = self.ring.copy_cqes(&raw, 1) catch |err| {
                    return self.waitError(err);
                };
                try self.checkCounters(PollError);
                if (count != 0) return try self.consume(raw[0]);
            }
        }

        pub fn recycle(
            self: *Self,
            borrowed: reactor.BorrowedReceive,
        ) (RecycleError || ReceiveBufferRing.RecycleError)!void {
            if (self.state == .closed) return error.BackendClosed;
            if (borrowed.identity.validate() != null) return error.InvalidBorrow;
            const buffer_index = borrowed.identity.buffer_index;
            if (buffer_index >= ReceiveBufferRing.count) return error.InvalidBorrow;
            const owner = self.buffer_owners[buffer_index] orelse return error.StaleBorrow;
            if (!owner.eql(borrowed.identity.owner)) return error.StaleBorrow;
            if (self.buffer_generations[buffer_index] !=
                borrowed.identity.buffer_generation) return error.StaleBorrow;

            try self.receive_buffers.recycle(.{
                .buffer_id = buffer_index,
                .bytes = borrowed.bytes,
            });
            self.buffer_owners[buffer_index] = null;
            self.buffer_generations[buffer_index] = reactor.nextGeneration(
                self.buffer_generations[buffer_index],
            );
            self.assertInvariants();
        }

        pub fn deinit(
            self: *Self,
        ) (DeinitError || ReceiveBufferRing.UnregisterError ||
            ReceiveBufferRing.UnmapError)!void {
            if (self.state == .closed) return error.BackendClosed;
            if (self.state == .fatal) return error.NotQuiescent;
            if (self.ownership_unproven) return error.NotQuiescent;
            if (self.queued_count != 0) return error.NotQuiescent;
            if (self.active_count != 0) return error.NotQuiescent;
            if (self.token_count != 0) return error.NotQuiescent;
            if (self.receive_buffers.borrowedCount() != 0) return error.NotQuiescent;
            if (self.unconsumedCompletionWork()) return error.NotQuiescent;
            try self.receive_buffers.deinit();
            self.ring.deinit();
            self.state = .closed;
            self.assertInvariants();
        }

        /// Fatal-only teardown. Unproven descriptor ownership requires process exit.
        pub fn abort(self: *Self) AbortError!reactor.AbortStatus {
            if (self.state == .closed) return error.BackendClosed;
            var status = io_uring_abort.drain(
                &self.ring,
                &self.tokens,
                limits.completion_entries,
            );
            status.accepted_sockets_discarded +|= self.accepted_sockets_discarded;
            if (self.ownership_unproven or
                io_uring_abort.hasTrackedDescriptorRisk(&self.tokens))
            {
                status.ownership_proven = false;
            }
            self.ring.deinit();
            self.state = .closed;
            self.receive_buffers.forceAbandonAfterRingClose();
            self.buffer_owners = [_]?reactor.SlotIdentity{null} ** ReceiveBufferRing.count;
            self.tokens = [_]u64{0} ** token_table_size;
            self.queued_count = 0;
            self.queued_timeouts = 0;
            self.upload_metadata.reset();
            self.active_count = 0;
            self.token_count = 0;
            self.accepted_sockets_discarded = 0;
            self.accept_pending = false;
            self.submission_retry_pending = false;
            self.ownership_unproven = false;
            self.assertInvariants();
            return status;
        }

        pub fn queuedCount(self: *const Self) u32 {
            return self.queued_count;
        }
        pub fn activeCount(self: *Self) u32 {
            if (self.state == .closed) return self.active_count;
            return @max(
                self.active_count,
                @as(u32, @intFromBool(self.unconsumedCompletionWork())),
            );
        }
        pub fn borrowedCount(self: *const Self) u16 {
            return self.receive_buffers.borrowedCount();
        }
        pub fn discard(self: *Self, socket: reactor.Socket) DiscardError!void {
            _ = self;
            return runtime_socket.discard(socket);
        }

        pub fn memoryMappings(self: *const Self) ?MemoryMappings {
            if (self.state == .closed) return null;
            return .{
                .provided_buffer_descriptors = self.receive_buffers.mappedBytes() orelse
                    return null,
                .sq_cq = self.ring.sq.mmap.len,
                .sqes = self.ring.sq.mmap_sqes.len,
            };
        }

        pub fn trackedTokenCount(self: *const Self) u32 {
            return self.token_count;
        }
        pub fn tokenActive(self: *const Self, token: reactor.OperationToken) bool {
            return io_uring_token_table.contains(&self.tokens, token.raw());
        }
        fn unconsumedCompletionWork(self: *Self) bool {
            return self.ring.cq_ready() != 0 or self.ring.cq_ring_needs_flush();
        }
        pub fn consume(self: *Self, raw: linux.io_uring_cqe) PollError!reactor.Completion {
            const token = reactor.OperationToken.fromRaw(raw.user_data) catch {
                return self.invalidUnclassified(raw.res);
            };
            if (!io_uring_token_table.contains(&self.tokens, token.raw())) {
                return self.invalidUnclassified(raw.res);
            }
            const token_fields = token.fields() catch return self.invalidUnclassified(raw.res);
            const more = raw.flags & linux.IORING_CQE_F_MORE != 0;
            if (token_fields.kind == .accept and !self.accept_pending) {
                return self.invalidCompletion();
            }
            const result = if (raw.res < 0)
                try self.negativeResult(token_fields.kind, raw)
            else
                try self.successResult(token, token_fields.kind, raw);
            const completion = reactor.Completion{
                .token = token,
                .result = result,
                .more = more,
            };
            if (completion.validate() != null) return self.invalidCompletion();
            if (!more) {
                if (self.active_count == 0) return self.invalidCompletion();
                if (!io_uring_token_table.remove(&self.tokens, token.raw())) {
                    return self.invalidCompletion();
                }
                self.token_count -= 1;
                self.active_count -= 1;
                if (token_fields.kind == .accept) self.accept_pending = false;
            }
            self.assertInvariants();
            return completion;
        }

        fn negativeResult(
            self: *Self,
            kind: reactor.OperationKind,
            raw: linux.io_uring_cqe,
        ) PollError!reactor.CompletionResult {
            if (raw.flags != 0) return self.invalidCompletion();
            const errno_value = raw.err();
            if (errno_value == .SUCCESS) return self.invalidCompletion();
            return io_uring_completion.normalizedNegative(kind, errno_value);
        }

        fn successResult(
            self: *Self,
            token: reactor.OperationToken,
            kind: reactor.OperationKind,
            raw: linux.io_uring_cqe,
        ) PollError!reactor.CompletionResult {
            return .{ .success = switch (kind) {
                .accept => .{ .accept = try self.acceptResult(raw) },
                .receive => .{ .receive = try self.receiveResult(token, raw) },
                .send => if (raw.res == 0 or raw.flags != 0)
                    return self.invalidCompletion()
                else
                    .{ .send = @intCast(raw.res) },
                .close => .{ .close = try self.exactVoidResult(raw) },
                .timeout => return self.invalidCompletion(),
                .wake => if (!io_uring_wake.isExactPositive(raw))
                    return self.invalidCompletion()
                else
                    .{ .wake = {} },
                .cancel => .{ .cancel = try self.cancelResult(raw) },
                .file_open => .{ .file_open = try self.fileOpenResult(raw) },
                .file_write => .{ .file_write = try self.fileWriteResult(raw) },
                .file_read => .{ .file_read = try self.fileReadResult(raw) },
                .file_stat => .{ .file_stat = try self.exactVoidResult(raw) },
                .file_close => .{ .file_close = try self.exactVoidResult(raw) },
                .file_link => .{ .file_link = try self.exactVoidResult(raw) },
                .file_unlink => .{ .file_unlink = try self.exactVoidResult(raw) },
                .file_rename_no_replace => .{
                    .file_rename_no_replace = try self.exactVoidResult(raw),
                },
                .file_sync => .{ .file_sync = try self.exactVoidResult(raw) },
                .upload_cancel => .{ .upload_cancel = try self.cancelResult(raw) },
                .file_cancel => .{ .file_cancel = try self.cancelResult(raw) },
            } };
        }

        fn fileOpenResult(
            self: *Self,
            raw: linux.io_uring_cqe,
        ) PollError!reactor.FileDescriptor {
            if (raw.res < 0) return self.invalidCompletion();
            if (raw.flags != 0) {
                if (linux.errno(linux.close(raw.res)) != .SUCCESS) {
                    self.ownership_unproven = true;
                }
                return self.invalidCompletion();
            }
            return .{ .value = raw.res };
        }

        fn fileWriteResult(self: *Self, raw: linux.io_uring_cqe) PollError!u32 {
            if (raw.res == 0 or raw.flags != 0) return self.invalidCompletion();
            return @intCast(raw.res);
        }

        fn fileReadResult(self: *Self, raw: linux.io_uring_cqe) PollError!u32 {
            if (raw.flags != 0) return self.invalidCompletion();
            return @intCast(raw.res);
        }

        fn exactVoidResult(self: *Self, raw: linux.io_uring_cqe) PollError!void {
            if (raw.res != 0 or raw.flags != 0) return self.invalidCompletion();
        }

        fn cancelResult(self: *Self, raw: linux.io_uring_cqe) PollError!reactor.CancelResult {
            try self.exactVoidResult(raw);
            return .canceled;
        }

        fn acceptResult(self: *Self, raw: linux.io_uring_cqe) PollError!reactor.Accepted {
            const allowed_flags: u32 = linux.IORING_CQE_F_SOCK_NONEMPTY;
            if (raw.flags & ~allowed_flags != 0) {
                runtime_socket.discard(.{ .value = @intCast(raw.res) }) catch {
                    self.ownership_unproven = true;
                    return self.invalidCompletion();
                };
                self.accepted_sockets_discarded +|= 1;
                return self.invalidCompletion();
            }
            const socket = reactor.Socket{ .value = @intCast(raw.res) };
            const peer = io_uring_peer.accepted(
                &self.accept_address,
                self.accept_address_length,
            ) orelse {
                runtime_socket.discard(socket) catch {
                    self.ownership_unproven = true;
                    return self.invalidCompletion();
                };
                self.accepted_sockets_discarded +|= 1;
                return self.invalidCompletion();
            };
            return .{ .socket = socket, .peer = peer };
        }

        fn receiveResult(
            self: *Self,
            token: reactor.OperationToken,
            raw: linux.io_uring_cqe,
        ) PollError!reactor.ReceiveResult {
            if (raw.res == 0) {
                const allowed_flags: u32 = linux.IORING_CQE_F_SOCK_NONEMPTY;
                if (raw.flags & ~allowed_flags != 0) {
                    return self.invalidCompletion();
                }
                return .end_of_stream;
            }
            const allowed_flags = linux.IORING_CQE_F_BUFFER |
                linux.IORING_CQE_F_MORE |
                linux.IORING_CQE_F_SOCK_NONEMPTY |
                (@as(u32, std.math.maxInt(u16)) << linux.IORING_CQE_BUFFER_SHIFT);
            if (raw.flags & ~allowed_flags != 0 or
                raw.flags & linux.IORING_CQE_F_BUFFER == 0)
            {
                return self.invalidCompletion();
            }
            const loan = self.receive_buffers.borrow(raw.res, raw.flags) catch {
                self.state = .fatal;
                return error.ReceiveBufferFailure;
            };
            const owner = token.slot() catch return self.invalidCompletion();
            if (self.buffer_owners[loan.buffer_id] != null) {
                self.state = .fatal;
                return error.ReceiveBufferFailure;
            }
            self.buffer_owners[loan.buffer_id] = owner;
            return .{ .bytes = .{
                .identity = .{
                    .owner = owner,
                    .buffer_index = loan.buffer_id,
                    .buffer_generation = self.buffer_generations[loan.buffer_id],
                },
                .bytes = loan.bytes,
            } };
        }

        fn requireReadyForSubmit(self: *Self) SubmitError!void {
            if (self.state == .closed) return error.BackendClosed;
            if (self.state == .fatal) return error.FatalInvariant;
            if (self.submission_retry_pending) return error.FlushRequired;
            self.assertInvariants();
            self.checkCounters(SubmitError) catch return error.FatalInvariant;
        }

        fn requireReadyForFlush(self: *Self) FlushError!void {
            if (self.state == .closed) return error.BackendClosed;
            if (self.state == .fatal) return error.FatalInvariant;
            self.assertInvariants();
            try self.checkCounters(FlushError);
        }

        fn requireReadyForCompletion(self: *Self) PollError!void {
            if (self.state == .closed) return error.BackendClosed;
            if (self.state == .fatal) return error.FatalInvariant;
            self.assertInvariants();
            try self.checkCounters(PollError);
        }

        fn vacantTokenSlot(self: *Self, token: u64) SubmitError!usize {
            const slot = io_uring_token_table.vacant(&self.tokens, token) catch |problem| {
                if (problem == error.DuplicateToken) return error.DuplicateToken;
                self.state = .fatal;
                return error.FatalInvariant;
            };
            if (self.token_count == operation_capacity) {
                return error.OperationCapacityExhausted;
            }
            return slot;
        }

        fn assertInvariants(self: *const Self) void {
            std.debug.assert(self.token_count == self.queued_count + self.active_count);
            std.debug.assert(self.token_count <= operation_capacity);
            std.debug.assert(self.queued_count <= limits.submission_entries);
            std.debug.assert(self.active_count <= operation_capacity);
            std.debug.assert(self.queued_timeouts <= limits.submission_entries);
            self.upload_metadata.assertValid();
            if (self.accept_pending) std.debug.assert(self.token_count != 0);
            if (self.submission_retry_pending) std.debug.assert(self.queued_count != 0);
        }

        fn checkCounters(self: *Self, comptime ErrorSet: type) ErrorSet!void {
            if (@atomicLoad(u32, self.ring.sq.dropped, .acquire) != 0) {
                self.state = .fatal;
                return error.FatalInvariant;
            }
            if (@atomicLoad(u32, self.ring.cq.overflow, .acquire) != 0) {
                self.state = .fatal;
                return error.FatalInvariant;
            }
        }

        fn waitError(self: *Self, err: anyerror) PollError {
            if (err == error.SignalInterrupt) return error.WaitInterrupted;
            if (io_uring_errors.retryableWaitError(err)) return error.WaitRetry;
            self.state = .fatal;
            return error.WaitFailed;
        }

        fn invalidCompletion(self: *Self) PollError {
            self.state = .fatal;
            return error.InvalidCompletion;
        }

        fn invalidUnclassified(self: *Self, _: i32) PollError {
            self.ownership_unproven = true;
            return self.invalidCompletion();
        }
    };
}

pub fn deadlineTimespec(deadline_ns: u64) linux.kernel_timespec {
    return .{
        .sec = @intCast(deadline_ns / nanoseconds_per_second),
        .nsec = @intCast(deadline_ns % nanoseconds_per_second),
    };
}
