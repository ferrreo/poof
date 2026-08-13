const std = @import("std");
const linux = std.os.linux;

const address = @import("../../../../src/address.zig");
const buffer_ring = @import("../../../../src/internal/runtime/buffer_ring.zig");
const config = @import("../../../../src/internal/runtime/config.zig");
const io_uring_abort = @import("../../../../src/internal/runtime/io_uring/abort.zig");
const io_uring_backend = @import("../../../../src/internal/runtime/io_uring/backend.zig");
const io_uring_token_table = @import("../../../../src/internal/runtime/io_uring/token_table.zig");
const reactor = @import("../../../../src/internal/runtime/reactor.zig");

const test_limits = config.Limits.validate(.{
    .connection_slots = 4,
    .request_slots = 2,
    .receive_buffers = 4,
    .receive_buffer_bytes = 64,
    .pipeline_bytes_per_connection = 64,
    .response_bytes_per_request = 128,
    .submission_entries = 8,
    .completion_entries = 16,
});
const TestReceiveBufferRing = buffer_ring.BufferRing(4, 64, 1);
const TestBackend = io_uring_backend.IoUringBackend(test_limits, TestReceiveBufferRing);
const UploadBackend = io_uring_backend.IoUringBackendWithUploads(
    test_limits,
    TestReceiveBufferRing,
    .{
        .connection_slots = test_limits.connection_slots,
        .body_workspace_slots = test_limits.body_workspace_slots,
        .upload_window_max = 3,
        .request_handles_max = 4,
        .runtime_handles_max = 2,
        .async_sink_present = true,
    },
);
const StaticBackend = io_uring_backend.IoUringBackendWithFiles(
    test_limits,
    TestReceiveBufferRing,
    .{
        .connection_slots = test_limits.connection_slots,
        .body_workspace_slots = test_limits.body_workspace_slots,
        .upload_window_max = 0,
        .request_handles_max = 0,
        .runtime_handles_max = 0,
        .async_sink_present = false,
        .live_static_slots = 2,
        .live_static_roots = 1,
    },
);

fn testBackend(token: reactor.OperationToken) !TestBackend {
    var backend = TestBackend{
        .ring = undefined,
        .receive_buffers = TestReceiveBufferRing.init(),
    };
    backend.active_count = 1;
    backend.token_count = 1;
    const slot = try io_uring_token_table.vacant(&backend.tokens, token.raw());
    backend.tokens[slot] = token.raw();
    if ((try token.fields()).kind == .accept) setTestPeer(&backend);
    return backend;
}

fn uploadTestBackend(token: reactor.OperationToken) !UploadBackend {
    var backend = UploadBackend{
        .ring = undefined,
        .receive_buffers = TestReceiveBufferRing.init(),
    };
    backend.active_count = 1;
    backend.token_count = 1;
    const slot = try io_uring_token_table.vacant(&backend.tokens, token.raw());
    backend.tokens[slot] = token.raw();
    return backend;
}

fn setTestPeer(backend: *TestBackend) void {
    const peer: *linux.sockaddr.in = @ptrCast(&backend.accept_address);
    peer.* = .{
        .port = std.mem.nativeToBig(u16, 4321),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    backend.accept_address_length = @sizeOf(linux.sockaddr.in);
    backend.accept_pending = true;
}

test "absolute timeout conversion is bounded and exact" {
    try std.testing.expectEqualDeep(
        linux.kernel_timespec{ .sec = 3, .nsec = 5 },
        io_uring_backend.deadlineTimespec(3 * std.time.ns_per_s + 5),
    );
}

test "completion work stays visible without a tracked active operation" {
    try std.testing.expect(!io_uring_backend.completionWorkPending(0, 0, false));
    try std.testing.expect(io_uring_backend.completionWorkPending(0, 1, false));
    try std.testing.expect(io_uring_backend.completionWorkPending(0, 0, true));
    try std.testing.expect(io_uring_backend.completionWorkPending(1, 0, false));
}

test "upload backend capacity is exact while legacy capacity stays unchanged" {
    try std.testing.expectEqual(@as(u32, 58), TestBackend.operation_capacity);
    try std.testing.expectEqual(@as(u32, 0), TestBackend.file_target_capacity);
    try std.testing.expectEqual(@as(u32, 0), TestBackend.file_lease_capacity);
    try std.testing.expectEqual(@as(u32, 66), UploadBackend.operation_capacity);
    try std.testing.expectEqual(@as(u32, 3), UploadBackend.file_target_capacity);
    try std.testing.expectEqual(@as(u32, 9), UploadBackend.file_lease_capacity);
    try std.testing.expectEqual(@as(u32, 6), UploadBackend.file_handle_capacity);
    try std.testing.expectEqual(@as(u32, 63), StaticBackend.operation_capacity);
    try std.testing.expectEqual(@as(u32, 0), StaticBackend.file_target_capacity);
    try std.testing.expectEqual(@as(u32, 0), StaticBackend.file_lease_capacity);
    try std.testing.expectEqual(@as(u32, 3), StaticBackend.file_handle_capacity);
}

test "raw upload completions normalize exact success shapes" {
    const open_token = try uploadToken(.file_open, 1);
    const descriptor_result = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(descriptor_result));
    const descriptor: linux.fd_t = @intCast(descriptor_result);
    defer _ = linux.close(descriptor);
    var backend = try uploadTestBackend(open_token);
    const opened = try backend.consume(.{
        .user_data = open_token.raw(),
        .res = descriptor,
        .flags = 0,
    });
    try std.testing.expectEqual(descriptor, opened.result.success.file_open.value);

    const write_token = try uploadToken(.file_write, 2);
    backend = try uploadTestBackend(write_token);
    const written = try backend.consume(.{
        .user_data = write_token.raw(),
        .res = 7,
        .flags = 0,
    });
    try std.testing.expectEqual(@as(u32, 7), written.result.success.file_write);

    const void_kinds = [_]reactor.OperationKind{
        .file_close,
        .file_link,
        .file_unlink,
        .file_rename_no_replace,
        .file_sync,
    };
    for (void_kinds, 0..) |kind, index| {
        const operation_token = try uploadToken(kind, @intCast(index + 3));
        backend = try uploadTestBackend(operation_token);
        const completion = try backend.consume(.{
            .user_data = operation_token.raw(),
            .res = 0,
            .flags = 0,
        });
        try std.testing.expectEqual(kind, std.meta.activeTag(completion.result.success));
    }

    const cancel_token = try uploadToken(.upload_cancel, 9);
    backend = try uploadTestBackend(cancel_token);
    const canceled = try backend.consume(.{
        .user_data = cancel_token.raw(),
        .res = 0,
        .flags = 0,
    });
    try std.testing.expectEqual(
        reactor.CancelResult.canceled,
        canceled.result.success.upload_cancel,
    );
}

test "raw live file completions normalize short reads stat and cancellation" {
    var backend: UploadBackend = undefined;
    for ([_]i32{ 0, 7 }) |read_count| {
        const read_token = try uploadToken(.file_read, @intCast(read_count + 1));
        backend = try uploadTestBackend(read_token);
        const read = try backend.consume(.{
            .user_data = read_token.raw(),
            .res = read_count,
            .flags = 0,
        });
        try std.testing.expectEqual(@as(u32, @intCast(read_count)), read.result.success.file_read);
    }

    const stat_token = try uploadToken(.file_stat, 9);
    backend = try uploadTestBackend(stat_token);
    const stat = try backend.consume(.{
        .user_data = stat_token.raw(),
        .res = 0,
        .flags = 0,
    });
    try std.testing.expect(stat.result.success == .file_stat);

    const cancel_token = try uploadToken(.file_cancel, 10);
    backend = try uploadTestBackend(cancel_token);
    const canceled = try backend.consume(.{
        .user_data = cancel_token.raw(),
        .res = -@as(i32, @intFromEnum(linux.E.NOENT)),
        .flags = 0,
    });
    try std.testing.expectEqual(
        reactor.CancelResult.not_found,
        canceled.result.success.file_cancel,
    );
}

test "malformed positive file open closes the tracked descriptor" {
    const operation_token = try uploadToken(.file_open, 1);
    const descriptor_result = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(descriptor_result));
    const descriptor: linux.fd_t = @intCast(descriptor_result);
    defer _ = linux.close(descriptor);
    var backend = try uploadTestBackend(operation_token);

    try std.testing.expectError(error.InvalidCompletion, backend.consume(.{
        .user_data = operation_token.raw(),
        .res = descriptor,
        .flags = linux.IORING_CQE_F_BUFFER,
    }));

    try std.testing.expect(backend.state == .fatal);
    try std.testing.expect(!backend.ownership_unproven);
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(descriptor, linux.F.GETFD, 0)),
    );
}

test "file and cancellation completions reject malformed positives" {
    const void_kinds = [_]reactor.OperationKind{
        .file_close,
        .file_link,
        .file_unlink,
        .file_rename_no_replace,
        .file_sync,
        .file_stat,
        .upload_cancel,
        .file_cancel,
    };
    for (void_kinds, 0..) |kind, index| {
        const operation_token = try uploadToken(kind, @intCast(index + 1));
        var backend = try uploadTestBackend(operation_token);
        try std.testing.expectError(error.InvalidCompletion, backend.consume(.{
            .user_data = operation_token.raw(),
            .res = 1,
            .flags = 0,
        }));
        try std.testing.expect(backend.state == .fatal);
    }

    const write_token = try uploadToken(.file_write, 8);
    var backend = try uploadTestBackend(write_token);
    try std.testing.expectError(error.InvalidCompletion, backend.consume(.{
        .user_data = write_token.raw(),
        .res = 0,
        .flags = 0,
    }));

    const cancel_token = try uploadToken(.upload_cancel, 9);
    backend = try uploadTestBackend(cancel_token);
    const missed = try backend.consume(.{
        .user_data = cancel_token.raw(),
        .res = -@as(i32, @intFromEnum(linux.E.NOENT)),
        .flags = 0,
    });
    try std.testing.expectEqual(
        reactor.CancelResult.not_found,
        missed.result.success.upload_cancel,
    );
}

test "untracked negative completion cannot prove descriptor ownership" {
    const tracked = try uploadToken(.file_write, 1);
    const unknown = try uploadToken(.file_close, 2);
    var backend = try uploadTestBackend(tracked);

    try std.testing.expectError(error.InvalidCompletion, backend.consume(.{
        .user_data = unknown.raw(),
        .res = -@as(i32, @intFromEnum(linux.E.IO)),
        .flags = 0,
    }));

    try std.testing.expect(backend.state == .fatal);
    try std.testing.expect(backend.ownership_unproven);
    try std.testing.expect(backend.tokenActive(tracked));
}

test "abort drain closes tracked positive file open and retires its token" {
    const operation_token = try uploadToken(.file_open, 1);
    const descriptor_result = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(descriptor_result));
    const descriptor: linux.fd_t = @intCast(descriptor_result);
    defer _ = linux.close(descriptor);
    var tokens = [_]u64{0} ** 8;
    tokens[try io_uring_token_table.vacant(&tokens, operation_token.raw())] =
        operation_token.raw();
    var completions = [_]linux.io_uring_cqe{.{
        .user_data = operation_token.raw(),
        .res = descriptor,
        .flags = 0,
    }};
    var ring = AbortRing{ .completions = &completions };

    const status = io_uring_abort.drain(&ring, &tokens, tokens.len);

    try std.testing.expect(status.ownership_proven);
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(descriptor, linux.F.GETFD, 0)),
    );
    try std.testing.expect(!io_uring_token_table.contains(&tokens, operation_token.raw()));
}

test "abort drain marks failed file close ownership unproven" {
    const operation_token = try uploadToken(.file_close, 1);
    var tokens = [_]u64{0} ** 8;
    tokens[try io_uring_token_table.vacant(&tokens, operation_token.raw())] =
        operation_token.raw();
    var completions = [_]linux.io_uring_cqe{.{
        .user_data = operation_token.raw(),
        .res = -@as(i32, @intFromEnum(linux.E.IO)),
        .flags = 0,
    }};
    var ring = AbortRing{ .completions = &completions };

    const status = io_uring_abort.drain(&ring, &tokens, tokens.len);

    try std.testing.expect(!status.ownership_proven);
    try std.testing.expect(!io_uring_token_table.contains(&tokens, operation_token.raw()));
}

test "abort drain treats every untracked completion as unproven" {
    const tracked = try uploadToken(.file_write, 1);
    const unknown = try uploadToken(.file_close, 2);
    var tokens = [_]u64{0} ** 8;
    tokens[try io_uring_token_table.vacant(&tokens, tracked.raw())] = tracked.raw();
    var completions = [_]linux.io_uring_cqe{.{
        .user_data = unknown.raw(),
        .res = -@as(i32, @intFromEnum(linux.E.IO)),
        .flags = 0,
    }};
    var ring = AbortRing{ .completions = &completions };

    const status = io_uring_abort.drain(&ring, &tokens, tokens.len);

    try std.testing.expect(!status.ownership_proven);
    try std.testing.expect(io_uring_token_table.contains(&tokens, tracked.raw()));
}

test "abort drain enters once before consuming deferred completion" {
    const operation_token = try uploadToken(.file_close, 1);
    var tokens = try trackedAbortTokens(operation_token);
    var completions = [_]linux.io_uring_cqe{.{
        .user_data = operation_token.raw(),
        .res = 0,
        .flags = 0,
    }};
    var ring = AbortRing{
        .completions = &completions,
        .deferred_until_enter = true,
    };

    const status = io_uring_abort.drain(&ring, &tokens, tokens.len);

    try std.testing.expect(status.ownership_proven);
    try std.testing.expectEqual(@as(u8, 1), ring.enter_calls);
    try std.testing.expectEqual(@as(usize, 1), ring.consumed);
    try std.testing.expect(!io_uring_token_table.contains(&tokens, operation_token.raw()));
}

test "abort drain enter failure remains unproven but consumes visible completion" {
    const operation_token = try uploadToken(.file_close, 1);
    var tokens = try trackedAbortTokens(operation_token);
    var completions = [_]linux.io_uring_cqe{.{
        .user_data = operation_token.raw(),
        .res = 0,
        .flags = 0,
    }};
    var ring = AbortRing{ .completions = &completions, .enter_fails = true };

    const status = io_uring_abort.drain(&ring, &tokens, tokens.len);

    try std.testing.expect(!status.ownership_proven);
    try std.testing.expectEqual(@as(u8, 1), ring.enter_calls);
    try std.testing.expectEqual(@as(usize, 1), ring.consumed);
    try std.testing.expect(!io_uring_token_table.contains(&tokens, operation_token.raw()));
}

test "abort drain copy failure preserves token and marks ownership unproven" {
    const operation_token = try uploadToken(.file_close, 1);
    var tokens = try trackedAbortTokens(operation_token);
    var completions = [_]linux.io_uring_cqe{.{
        .user_data = operation_token.raw(),
        .res = 0,
        .flags = 0,
    }};
    var ring = AbortRing{ .completions = &completions, .copy_fails = true };

    const status = io_uring_abort.drain(&ring, &tokens, tokens.len);

    try std.testing.expect(!status.ownership_proven);
    try std.testing.expectEqual(@as(u8, 1), ring.enter_calls);
    try std.testing.expect(io_uring_token_table.contains(&tokens, operation_token.raw()));
}

test "abort drain rejects residual ready flush and exact completion bound" {
    const operation_token = try uploadToken(.file_write, 1);
    const completion = linux.io_uring_cqe{
        .user_data = operation_token.raw(),
        .res = 1,
        .flags = 0,
    };
    var completions = [_]linux.io_uring_cqe{ completion, completion };
    var residual_tokens = try trackedAbortTokens(operation_token);
    var residual = AbortRing{ .completions = &completions };
    try std.testing.expect(
        !io_uring_abort.drain(&residual, &residual_tokens, 1).ownership_proven,
    );
    try std.testing.expectEqual(@as(u32, 1), residual.cq_ready());
    try std.testing.expectEqual(@as(u8, 1), residual.enter_calls);

    var flush_tokens = [_]u64{0} ** 8;
    var flush = AbortRing{ .completions = &.{}, .needs_flush = true };
    try std.testing.expect(
        !io_uring_abort.drain(&flush, &flush_tokens, flush_tokens.len).ownership_proven,
    );
    try std.testing.expectEqual(@as(u8, 1), flush.enter_calls);

    var bound_tokens = try trackedAbortTokens(operation_token);
    var bound = AbortRing{ .completions = completions[0..1] };
    try std.testing.expect(
        !io_uring_abort.drain(&bound, &bound_tokens, 1).ownership_proven,
    );
    try std.testing.expectEqual(@as(u32, 0), bound.cq_ready());
    try std.testing.expectEqual(@as(u8, 1), bound.enter_calls);
}

test "outstanding socket and file ownership operations retain abort risk" {
    const cases = [_]struct { kind: reactor.OperationKind, risky: bool }{
        .{ .kind = .accept, .risky = true },
        .{ .kind = .close, .risky = true },
        .{ .kind = .file_open, .risky = true },
        .{ .kind = .file_close, .risky = true },
        .{ .kind = .file_write, .risky = false },
        .{ .kind = .upload_cancel, .risky = false },
    };
    for (cases, 0..) |case, index| {
        const operation_token = try uploadToken(case.kind, @intCast(index + 1));
        var tokens = [_]u64{0} ** 8;
        tokens[try io_uring_token_table.vacant(&tokens, operation_token.raw())] =
            operation_token.raw();
        try std.testing.expectEqual(
            case.risky,
            io_uring_abort.hasTrackedDescriptorRisk(&tokens),
        );
    }
}

test "raw completions normalize single-shot accept and receive terminal state" {
    const accept_token = try reactor.OperationToken.init(.{
        .kind = .accept,
        .worker_index = 0,
        .slot_index = 1,
        .slot_generation = 2,
        .sequence = 3,
    });
    var backend = try testBackend(accept_token);
    const accepted = try backend.consume(.{
        .user_data = accept_token.raw(),
        .res = 9,
        .flags = linux.IORING_CQE_F_SOCK_NONEMPTY,
    });
    try std.testing.expectEqual(@as(u64, 9), accepted.result.success.accept.socket.value);
    try std.testing.expectEqualDeep(
        address.Endpoint.initIpv4(.{ 127, 0, 0, 1 }, 4321),
        accepted.result.success.accept.peer,
    );
    const accepted_fd = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(accepted_fd));
    backend = try testBackend(accept_token);
    try std.testing.expectError(error.InvalidCompletion, backend.consume(.{
        .user_data = accept_token.raw(),
        .res = @intCast(accepted_fd),
        .flags = linux.IORING_CQE_F_MORE,
    }));
    try std.testing.expect(backend.state == .fatal);
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(@intCast(accepted_fd), linux.F.GETFD, 0)),
    );
    const receive_token = try reactor.OperationToken.init(.{
        .kind = .receive,
        .worker_index = 0,
        .slot_index = 1,
        .slot_generation = 2,
        .sequence = 4,
    });
    backend = try testBackend(receive_token);
    const end_of_stream = try backend.consume(.{
        .user_data = receive_token.raw(),
        .res = 0,
        .flags = linux.IORING_CQE_F_SOCK_NONEMPTY,
    });
    switch (end_of_stream.result.success.receive) {
        .end_of_stream => {},
        .bytes => return error.TestUnexpectedResult,
    }
}

test "raw completion flags and invalid errno encodings fail closed" {
    const send_token = try reactor.OperationToken.init(.{
        .kind = .send,
        .worker_index = 0,
        .slot_index = 1,
        .slot_generation = 2,
        .sequence = 3,
    });
    var backend = try testBackend(send_token);
    try std.testing.expectError(error.InvalidCompletion, backend.consume(.{
        .user_data = send_token.raw(),
        .res = 1,
        .flags = linux.IORING_CQE_F_BUFFER,
    }));
    try std.testing.expect(backend.state == .fatal);
    backend = try testBackend(send_token);
    try std.testing.expectError(error.InvalidCompletion, backend.consume(.{
        .user_data = send_token.raw(),
        .res = -5000,
        .flags = 0,
    }));
    try std.testing.expect(backend.state == .fatal);
}

test "unclassified positive completions persist ownership uncertainty" {
    const unknown = try reactor.OperationToken.init(.{
        .kind = .send,
        .worker_index = 0,
        .slot_index = 1,
        .slot_generation = 2,
        .sequence = 3,
    });
    var backend = TestBackend{
        .ring = undefined,
        .receive_buffers = TestReceiveBufferRing.init(),
    };
    try std.testing.expectError(error.InvalidCompletion, backend.consume(.{
        .user_data = unknown.raw(),
        .res = 1,
        .flags = 0,
    }));
    try std.testing.expect(backend.ownership_unproven);
    try std.testing.expectError(error.NotQuiescent, backend.deinit());
    backend.state = .ready;
    backend.ownership_unproven = false;
    try std.testing.expectError(error.InvalidCompletion, backend.consume(.{
        .user_data = 0,
        .res = 0,
        .flags = 0,
    }));
    try std.testing.expect(backend.ownership_unproven);
}

fn uploadToken(kind: reactor.OperationKind, sequence: u16) !reactor.OperationToken {
    return reactor.OperationToken.init(.{
        .kind = kind,
        .worker_index = 1,
        .slot_index = 3,
        .slot_generation = 2,
        .sequence = sequence,
    });
}

fn trackedAbortTokens(token: reactor.OperationToken) ![8]u64 {
    var tokens = [_]u64{0} ** 8;
    tokens[try io_uring_token_table.vacant(&tokens, token.raw())] = token.raw();
    return tokens;
}

const AbortRing = struct {
    completions: []const linux.io_uring_cqe,
    consumed: usize = 0,
    deferred_until_enter: bool = false,
    enter_fails: bool = false,
    copy_fails: bool = false,
    needs_flush: bool = false,
    entered: bool = false,
    enter_calls: u8 = 0,

    pub fn cq_ready(self: *const AbortRing) u32 {
        return @intCast(self.visibleLen() - self.consumed);
    }

    pub fn enter(
        self: *AbortRing,
        to_submit: u32,
        min_complete: u32,
        flags: u32,
    ) !u32 {
        self.enter_calls += 1;
        if (to_submit != 0 or min_complete != 0 or
            flags != linux.IORING_ENTER_GETEVENTS)
        {
            return error.InvalidEnterArguments;
        }
        if (self.enter_fails) return error.EnterFailed;
        self.entered = true;
        return 0;
    }

    pub fn copy_cqes(
        self: *AbortRing,
        output: []linux.io_uring_cqe,
        wait_count: u32,
    ) !u32 {
        _ = wait_count;
        if (self.copy_fails) return error.CopyFailed;
        const count = @min(output.len, self.visibleLen() - self.consumed);
        @memcpy(output[0..count], self.completions[self.consumed..][0..count]);
        self.consumed += count;
        return @intCast(count);
    }

    pub fn cq_ring_needs_flush(self: *const AbortRing) bool {
        return self.needs_flush;
    }

    fn visibleLen(self: *const AbortRing) usize {
        if (self.deferred_until_enter and !self.entered) return 0;
        return self.completions.len;
    }
};
