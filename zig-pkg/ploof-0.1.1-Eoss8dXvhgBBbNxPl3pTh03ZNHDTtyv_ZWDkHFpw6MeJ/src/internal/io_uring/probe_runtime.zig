const std = @import("std");
const linux = std.os.linux;

const IoUring = linux.IoUring;
const page_size_min = std.heap.page_size_min;
const model = @import("probe_types.zig");

const capabilities = model.reactor_capability_manifest;
const Context = model.Context;
const Failure = model.Failure;
const Operation = model.Operation;
const Phase = model.Phase;
const Requirement = model.Requirement;

pub const active_probe_timeout_ns = 2 * std.time.ns_per_s;
pub const poll_pause_ns = std.time.ns_per_ms;
pub const max_poll_iterations: u32 = 2048;
pub const buffer_group_id = capabilities.buffer_ring.group_id;
pub const buffer_count = capabilities.buffer_ring.buffer_count;
pub const buffer_size: usize = capabilities.buffer_ring.buffer_size;

pub const WaitFailureKind = enum(u8) {
    syscall,
    timed_out,
    clock_unavailable,
};

pub const WaitFailure = struct {
    errno: linux.E,
    kind: WaitFailureKind,
};

pub const WaitResult = union(enum) {
    cqe: linux.io_uring_cqe,
    failure: WaitFailure,
};

pub const Tag = enum(u64) {
    nop = 0x504c_0001,
    accept = 0x504c_0002,
    cancel_accept = 0x504c_0003,
    receive = 0x504c_0004,
    cancel_receive = 0x504c_0005,
    send = 0x504c_0006,
    timeout = 0x504c_0007,
};

const cancellation_canceled_result: i32 =
    -@as(i32, @intFromEnum(linux.E.CANCELED));

const CancellationState = packed struct(u2) {
    target_seen: bool = false,
    cancel_seen: bool = false,

    fn complete(state: CancellationState) bool {
        return state.target_seen and state.cancel_seen;
    }

    fn mask(state: CancellationState) u2 {
        return @as(u2, @intFromBool(state.target_seen)) |
            @as(u2, @intFromBool(state.cancel_seen)) << 1;
    }
};

const CancellationIssue = enum(u8) {
    unexpected_tag,
    duplicate_target,
    duplicate_cancel,
    target_result,
    target_flags,
    cancel_result,
    cancel_flags,
};

const CancellationClassification = union(enum) {
    accepted: CancellationState,
    issue: CancellationIssue,
};

fn classifyCancellationCqe(
    state: CancellationState,
    completion: linux.io_uring_cqe,
    target: Tag,
    cancel: Tag,
) CancellationClassification {
    std.debug.assert(target != cancel);

    var next = state;
    if (completion.user_data == @intFromEnum(target)) {
        if (state.target_seen) return .{ .issue = .duplicate_target };
        if (completion.res != cancellation_canceled_result) {
            return .{ .issue = .target_result };
        }
        if (completion.flags != 0) return .{ .issue = .target_flags };
        next.target_seen = true;
    } else if (completion.user_data == @intFromEnum(cancel)) {
        if (state.cancel_seen) return .{ .issue = .duplicate_cancel };
        if (completion.res != 0) return .{ .issue = .cancel_result };
        if (completion.flags != 0) return .{ .issue = .cancel_flags };
        next.cancel_seen = true;
    } else {
        return .{ .issue = .unexpected_tag };
    }
    return .{ .accepted = next };
}

pub const BufferRing = struct {
    mmap: []align(page_size_min) u8,
    ring: *align(page_size_min) linux.io_uring_buf_ring,

    pub fn create(context: *const Context, fd: linux.fd_t) union(enum) {
        buffer_ring: BufferRing,
        failure: Failure,
    } {
        const mmap_size: usize = capabilities.buffer_ring.ring_bytes;
        const mmap = std.posix.mmap(
            null,
            mmap_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch {
            return .{ .failure = context.failureWithoutErrno(
                .buffer_ring_failed,
                .buffer_registration,
                .register_buffer_ring,
                .non_incremental_buffer_ring,
                mmap_size,
                0,
            ) };
        };
        var mmap_live = true;
        defer if (mmap_live) std.posix.munmap(mmap);

        const ring: *align(page_size_min) linux.io_uring_buf_ring = @ptrCast(mmap.ptr);
        var registration = std.mem.zeroInit(linux.io_uring_buf_reg, .{
            .ring_addr = @intFromPtr(ring),
            .ring_entries = buffer_count,
            .bgid = buffer_group_id,
            .flags = linux.io_uring_buf_reg.Flags{
                .inc = capabilities.buffer_ring.incremental,
            },
        });
        const result = linux.io_uring_register(
            fd,
            .REGISTER_PBUF_RING,
            @ptrCast(&registration),
            1,
        );
        const errno_value = linux.errno(result);
        if (errno_value != .SUCCESS) {
            return .{ .failure = context.failure(
                .buffer_ring_failed,
                .buffer_registration,
                .register_buffer_ring,
                .non_incremental_buffer_ring,
                errno_value,
                buffer_count,
                0,
            ) };
        }

        IoUring.buf_ring_init(ring);
        mmap_live = false;
        return .{ .buffer_ring = .{ .mmap = mmap, .ring = ring } };
    }

    pub fn unregister(buffer_ring: *BufferRing, fd: linux.fd_t) linux.E {
        _ = buffer_ring;
        var registration = std.mem.zeroInit(linux.io_uring_buf_reg, .{
            .bgid = buffer_group_id,
        });
        const result = linux.io_uring_register(
            fd,
            .UNREGISTER_PBUF_RING,
            @ptrCast(&registration),
            1,
        );
        return linux.errno(result);
    }

    pub fn unmap(buffer_ring: *BufferRing) void {
        std.posix.munmap(buffer_ring.mmap);
        buffer_ring.* = undefined;
    }
};

pub fn proveNop(context: *const Context, ring: *IoUring) ?Failure {
    _ = ring.nop(@intFromEnum(Tag.nop)) catch {
        return submissionFailure(context, .nop, .nop, .SUCCESS, 1, 0);
    };
    if (submitPending(context, ring, .nop, .nop)) |failure| return failure;

    const cqe = switch (waitOne(ring)) {
        .cqe => |value| value,
        .failure => |wait_failure| {
            return waitFailure(context, .nop, .nop, .opcode, wait_failure);
        },
    };
    if (cqe.user_data != @intFromEnum(Tag.nop) or cqe.res != 0) {
        return completionFailure(
            context,
            .nop,
            .nop,
            cqe,
            @intFromEnum(Tag.nop),
            0,
        );
    }
    return null;
}

pub fn proveTimeout(context: *const Context, ring: *IoUring) ?Failure {
    const timeout = linux.kernel_timespec{ .sec = 0, .nsec = poll_pause_ns };
    _ = ring.timeout(@intFromEnum(Tag.timeout), &timeout, 0, 0) catch {
        return submissionFailure(context, .timeout, .timeout, .SUCCESS, 1, 0);
    };
    if (submitPending(context, ring, .timeout, .timeout)) |failure| return failure;

    const cqe = switch (waitOne(ring)) {
        .cqe => |value| value,
        .failure => |wait_failure| {
            return waitFailure(context, .timeout, .timeout, .timeout, wait_failure);
        },
    };
    if (cqe.user_data != @intFromEnum(Tag.timeout) or cqe.err() != .TIME) {
        return completionFailure(
            context,
            .timeout,
            .timeout,
            cqe,
            @intFromEnum(Tag.timeout),
            -@as(i64, @intFromEnum(linux.E.TIME)),
        );
    }
    return null;
}

pub fn cancelAndReap(
    context: *const Context,
    ring: *IoUring,
    target: Tag,
    cancel: Tag,
    phase: Phase,
    operation: Operation,
) ?Failure {
    _ = ring.cancel(@intFromEnum(cancel), @intFromEnum(target), 0) catch {
        return submissionFailure(context, .cancellation, .async_cancel, .SUCCESS, 1, 0);
    };
    if (submitPending(context, ring, .cancellation, .async_cancel)) |failure| {
        return failure;
    }

    var state = CancellationState{};
    const deadline = deadlineFromNow() orelse {
        return waitFailure(
            context,
            .cancellation,
            .async_cancel,
            .cancellation,
            .{ .errno = .SUCCESS, .kind = .clock_unavailable },
        );
    };
    var completions: u8 = 0;
    while (completions < 2) : (completions += 1) {
        const cqe = switch (waitOneUntil(ring, deadline)) {
            .cqe => |value| value,
            .failure => |wait_failure| {
                return waitFailure(
                    context,
                    .cancellation,
                    .async_cancel,
                    .cancellation,
                    wait_failure,
                );
            },
        };
        switch (classifyCancellationCqe(state, cqe, target, cancel)) {
            .accepted => |next| state = next,
            .issue => |issue| {
                return cancellationCompletionFailure(
                    context,
                    phase,
                    operation,
                    state,
                    cqe,
                    target,
                    cancel,
                    issue,
                );
            },
        }
    }
    std.debug.assert(state.complete());
    return null;
}

pub fn submitPending(
    context: *const Context,
    ring: *IoUring,
    phase: Phase,
    operation: Operation,
) ?Failure {
    const pending = ring.flush_sq();
    if (pending == 0) {
        return submissionFailure(context, phase, operation, .SUCCESS, 1, 0);
    }
    const result = linux.io_uring_enter(ring.fd, pending, 0, 0, null);
    const errno_value = linux.errno(result);
    if (errno_value != .SUCCESS) {
        return submissionFailure(context, phase, operation, errno_value, pending, 0);
    }
    if (result != pending) {
        return submissionFailure(
            context,
            phase,
            operation,
            .SUCCESS,
            pending,
            @intCast(result),
        );
    }
    return null;
}

pub fn waitOne(ring: *IoUring) WaitResult {
    const deadline = deadlineFromNow() orelse {
        return .{ .failure = .{ .errno = .SUCCESS, .kind = .clock_unavailable } };
    };
    return waitOneUntil(ring, deadline);
}

pub fn waitOneUntil(ring: *IoUring, deadline: u64) WaitResult {
    var iteration: u32 = 0;
    while (iteration < max_poll_iterations) : (iteration += 1) {
        if (popCompletion(ring)) |cqe| return .{ .cqe = cqe };

        const enter_result = linux.io_uring_enter(
            ring.fd,
            0,
            0,
            linux.IORING_ENTER_GETEVENTS,
            null,
        );
        const enter_errno = linux.errno(enter_result);
        if (enter_errno != .SUCCESS and enter_errno != .INTR) {
            return .{ .failure = .{ .errno = enter_errno, .kind = .syscall } };
        }

        const now = monotonicNanoseconds() orelse {
            return .{ .failure = .{ .errno = .SUCCESS, .kind = .clock_unavailable } };
        };
        if (now >= deadline) {
            return .{ .failure = .{ .errno = .SUCCESS, .kind = .timed_out } };
        }

        const pause = linux.timespec{ .sec = 0, .nsec = poll_pause_ns };
        const pause_errno = linux.errno(linux.nanosleep(&pause, null));
        if (pause_errno != .SUCCESS and pause_errno != .INTR) {
            return .{ .failure = .{ .errno = pause_errno, .kind = .syscall } };
        }
    }
    return .{ .failure = .{ .errno = .SUCCESS, .kind = .timed_out } };
}

pub fn popCompletion(ring: *IoUring) ?linux.io_uring_cqe {
    if (ring.cq_ready() == 0) return null;
    const index = ring.cq.head.* & ring.cq.mask;
    const cqe = ring.cq.cqes[index];
    ring.cq_advance(1);
    return cqe;
}

pub fn pumpUntilRetry(ring: *IoUring, deadline: u64) ?WaitFailure {
    const enter_result = linux.io_uring_enter(
        ring.fd,
        0,
        0,
        linux.IORING_ENTER_GETEVENTS,
        null,
    );
    const enter_errno = linux.errno(enter_result);
    if (enter_errno != .SUCCESS and enter_errno != .INTR) {
        return .{ .errno = enter_errno, .kind = .syscall };
    }
    const now = monotonicNanoseconds() orelse {
        return .{ .errno = .SUCCESS, .kind = .clock_unavailable };
    };
    if (now >= deadline) return .{ .errno = .SUCCESS, .kind = .timed_out };

    const pause = linux.timespec{ .sec = 0, .nsec = poll_pause_ns };
    const pause_errno = linux.errno(linux.nanosleep(&pause, null));
    if (pause_errno != .SUCCESS and pause_errno != .INTR) {
        return .{ .errno = pause_errno, .kind = .syscall };
    }
    return null;
}

pub fn submissionFailure(
    context: *const Context,
    phase: Phase,
    operation: Operation,
    errno_value: linux.E,
    expected: i64,
    observed: i64,
) Failure {
    return context.failure(
        .submission_failed,
        phase,
        operation,
        requirementFor(operation),
        errno_value,
        expected,
        observed,
    );
}

pub fn completionFailure(
    context: *const Context,
    phase: Phase,
    operation: Operation,
    cqe: linux.io_uring_cqe,
    expected_tag: u64,
    expected_result: i64,
) Failure {
    var failure = context.failure(
        .completion_failed,
        phase,
        operation,
        requirementFor(operation),
        cqe.err(),
        expected_result,
        cqe.res,
    );
    failure.expected_user_data = expected_tag;
    failure.observed_user_data = cqe.user_data;
    failure.observed_cqe_flags = cqe.flags;
    return failure;
}

fn cancellationCompletionFailure(
    context: *const Context,
    phase: Phase,
    operation: Operation,
    state: CancellationState,
    cqe: linux.io_uring_cqe,
    target: Tag,
    cancel: Tag,
    issue: CancellationIssue,
) Failure {
    const target_issue = switch (issue) {
        .duplicate_target, .target_result, .target_flags => true,
        .unexpected_tag, .duplicate_cancel, .cancel_result, .cancel_flags => false,
    };
    var failure = if (target_issue)
        completionFailure(
            context,
            phase,
            operation,
            cqe,
            @intFromEnum(target),
            cancellation_canceled_result,
        )
    else
        completionFailure(
            context,
            .cancellation,
            .async_cancel,
            cqe,
            @intFromEnum(cancel),
            0,
        );

    switch (issue) {
        .target_flags, .cancel_flags => {
            failure.expected = 0;
            failure.observed = cqe.flags;
        },
        .duplicate_target, .duplicate_cancel => {
            failure.expected = 0b11;
            failure.observed = state.mask();
        },
        .unexpected_tag, .target_result, .cancel_result => {},
    }
    return failure;
}

pub fn waitFailure(
    context: *const Context,
    phase: Phase,
    operation: Operation,
    requirement: Requirement,
    wait_failure: WaitFailure,
) Failure {
    if (wait_failure.kind == .clock_unavailable) {
        return context.failureWithoutErrno(
            .monotonic_clock_unavailable,
            phase,
            operation,
            .monotonic_clock,
            1,
            0,
        );
    }
    return context.failure(
        switch (wait_failure.kind) {
            .syscall => .completion_failed,
            .timed_out => .probe_timed_out,
            .clock_unavailable => unreachable,
        },
        phase,
        operation,
        requirement,
        wait_failure.errno,
        active_probe_timeout_ns,
        0,
    );
}

fn requirementFor(operation: Operation) Requirement {
    return switch (operation) {
        .accept => .multishot_accept,
        .recv => .multishot_receive,
        .send => .selected_send,
        .timeout => .timeout,
        .async_cancel => .cancellation,
        .poll_add => .event_wake,
        else => .opcode,
    };
}

fn monotonicNanoseconds() ?u64 {
    var time: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &time)) != .SUCCESS) return null;
    if (time.sec < 0 or time.nsec < 0) return null;
    const seconds = std.math.mul(
        u64,
        @intCast(time.sec),
        std.time.ns_per_s,
    ) catch return null;
    return std.math.add(u64, seconds, @intCast(time.nsec)) catch null;
}

pub fn deadlineFromNow() ?u64 {
    const now = monotonicNanoseconds() orelse return null;
    return std.math.add(u64, now, active_probe_timeout_ns) catch
        std.math.maxInt(u64);
}

fn cancellationTestCqe(
    user_data: u64,
    result: i32,
    flags: u32,
) linux.io_uring_cqe {
    return .{ .user_data = user_data, .res = result, .flags = flags };
}

test "cancellation CQE classifier covers every order and rejection" {
    const target = Tag.receive;
    const cancel = Tag.cancel_receive;
    const target_tag = @intFromEnum(target);
    const cancel_tag = @intFromEnum(cancel);
    const target_ok = cancellationTestCqe(
        target_tag,
        cancellation_canceled_result,
        0,
    );
    const cancel_ok = cancellationTestCqe(cancel_tag, 0, 0);

    const Case = struct {
        completions: [2]linux.io_uring_cqe,
        expected_issue: ?CancellationIssue,
        expected_state: CancellationState,
    };
    const cases = [_]Case{
        .{
            .completions = .{ target_ok, cancel_ok },
            .expected_issue = null,
            .expected_state = .{ .target_seen = true, .cancel_seen = true },
        },
        .{
            .completions = .{ cancel_ok, target_ok },
            .expected_issue = null,
            .expected_state = .{ .target_seen = true, .cancel_seen = true },
        },
        .{
            .completions = .{ target_ok, target_ok },
            .expected_issue = .duplicate_target,
            .expected_state = .{ .target_seen = true },
        },
        .{
            .completions = .{ cancel_ok, cancel_ok },
            .expected_issue = .duplicate_cancel,
            .expected_state = .{ .cancel_seen = true },
        },
        .{
            .completions = .{
                target_ok,
                cancellationTestCqe(0xdead_beef, 0, 0),
            },
            .expected_issue = .unexpected_tag,
            .expected_state = .{ .target_seen = true },
        },
        .{
            .completions = .{
                cancel_ok,
                cancellationTestCqe(target_tag, 0, 0),
            },
            .expected_issue = .target_result,
            .expected_state = .{ .cancel_seen = true },
        },
        .{
            .completions = .{
                cancel_ok,
                cancellationTestCqe(
                    target_tag,
                    cancellation_canceled_result,
                    linux.IORING_CQE_F_MORE,
                ),
            },
            .expected_issue = .target_flags,
            .expected_state = .{ .cancel_seen = true },
        },
        .{
            .completions = .{
                target_ok,
                cancellationTestCqe(
                    cancel_tag,
                    -@as(i32, @intFromEnum(linux.E.NOENT)),
                    0,
                ),
            },
            .expected_issue = .cancel_result,
            .expected_state = .{ .target_seen = true },
        },
        .{
            .completions = .{
                target_ok,
                cancellationTestCqe(
                    cancel_tag,
                    0,
                    linux.IORING_CQE_F_MORE,
                ),
            },
            .expected_issue = .cancel_flags,
            .expected_state = .{ .target_seen = true },
        },
    };

    var seen: std.EnumSet(CancellationIssue) = .empty;
    for (cases) |case| {
        var state = CancellationState{};
        var actual_issue: ?CancellationIssue = null;

        sequence: for (case.completions) |completion| {
            switch (classifyCancellationCqe(
                state,
                completion,
                target,
                cancel,
            )) {
                .accepted => |next| state = next,
                .issue => |issue| {
                    actual_issue = issue;
                    seen.insert(issue);
                    break :sequence;
                },
            }
        }

        try std.testing.expectEqual(case.expected_issue, actual_issue);
        try std.testing.expectEqual(case.expected_state, state);
        try std.testing.expectEqual(case.expected_issue == null, state.complete());
    }

    try std.testing.expect(seen.eql(std.EnumSet(CancellationIssue).full));
}

test "cancellation failure reports completion flags" {
    const context = Context{ .config = .{}, .system = .{} };
    const completion = cancellationTestCqe(
        @intFromEnum(Tag.receive),
        cancellation_canceled_result,
        linux.IORING_CQE_F_MORE,
    );
    const failure = cancellationCompletionFailure(
        &context,
        .multishot_receive,
        .recv,
        .{ .cancel_seen = true },
        completion,
        .receive,
        .cancel_receive,
        .target_flags,
    );
    try std.testing.expectEqual(linux.IORING_CQE_F_MORE, failure.observed_cqe_flags);
    try std.testing.expectEqual(@as(i64, 0), failure.expected);
    try std.testing.expectEqual(
        @as(i64, linux.IORING_CQE_F_MORE),
        failure.observed,
    );

    var buffer: [768]u8 = undefined;
    const rendered = try failure.render(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cqe_flags=0x2") != null);
}

test "wait failures preserve requirement and clock distinction" {
    const context = Context{ .config = .{}, .system = .{} };
    const syscall_failure = WaitFailure{ .errno = .AGAIN, .kind = .syscall };
    const receive_wait = waitFailure(
        &context,
        .multishot_receive,
        .send,
        .multishot_receive,
        syscall_failure,
    );
    try std.testing.expectEqual(
        model.Requirement.multishot_receive,
        receive_wait.requirement,
    );
    const send_wait = waitFailure(
        &context,
        .send,
        .recv,
        .selected_send,
        syscall_failure,
    );
    try std.testing.expectEqual(model.Requirement.selected_send, send_wait.requirement);

    const failure = waitFailure(
        &context,
        .nop,
        .nop,
        .opcode,
        .{ .errno = .SUCCESS, .kind = .clock_unavailable },
    );
    try std.testing.expectEqual(
        model.ErrorCode.monotonic_clock_unavailable,
        failure.code,
    );
    try std.testing.expectEqual(model.Requirement.monotonic_clock, failure.requirement);
    try std.testing.expectEqual(model.ErrnoStatus.unavailable, failure.errno_status);

    var buffer: [768]u8 = undefined;
    const rendered = try failure.render(&buffer);
    try std.testing.expect(std.mem.startsWith(u8, rendered, "PLOOF-E1017"));
}
