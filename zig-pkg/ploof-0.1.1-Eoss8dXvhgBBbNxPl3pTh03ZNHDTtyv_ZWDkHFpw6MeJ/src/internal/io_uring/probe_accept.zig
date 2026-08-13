const std = @import("std");
const linux = std.os.linux;

const IoUring = linux.IoUring;
const model = @import("probe_types.zig");
const runtime = @import("probe_runtime.zig");

const Context = model.Context;
const Failure = model.Failure;
const Tag = runtime.Tag;

const canceled_result: i32 = -@as(i32, @intFromEnum(linux.E.CANCELED));
const accept_success_flags: u32 =
    linux.IORING_CQE_F_MORE | linux.IORING_CQE_F_SOCK_NONEMPTY;

pub const State = struct {
    target_armed: bool = false,
    target_terminal_seen: bool = false,
    cancel_armed: bool = false,
    cancel_seen: bool = false,
    ownership_proven: bool = true,
};

pub fn submit(
    context: *const Context,
    ring: *IoUring,
    listener: linux.fd_t,
    state: *State,
) ?Failure {
    std.debug.assert(!state.target_armed);
    _ = ring.accept_multishot(
        @intFromEnum(Tag.accept),
        listener,
        null,
        null,
        linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
    ) catch {
        return runtime.submissionFailure(
            context,
            .multishot_accept,
            .accept,
            .SUCCESS,
            1,
            0,
        );
    };
    state.target_armed = true;
    return runtime.submitPending(context, ring, .multishot_accept, .accept);
}

pub fn reapTwo(
    context: *const Context,
    ring: *IoUring,
    accepted: *[2]linux.fd_t,
    state: *State,
) ?Failure {
    std.debug.assert(state.target_armed);
    std.debug.assert(!state.target_terminal_seen);
    const deadline = runtime.deadlineFromNow() orelse {
        return runtime.waitFailure(
            context,
            .multishot_accept,
            .accept,
            .multishot_accept,
            .{ .errno = .SUCCESS, .kind = .clock_unavailable },
        );
    };
    for (accepted) |*slot| {
        const cqe = switch (runtime.waitOneUntil(ring, deadline)) {
            .cqe => |value| value,
            .failure => |problem| return runtime.waitFailure(
                context,
                .multishot_accept,
                .accept,
                .multishot_accept,
                problem,
            ),
        };
        if (cqe.user_data == @intFromEnum(Tag.accept) and
            cqe.flags & linux.IORING_CQE_F_MORE == 0)
        {
            state.target_terminal_seen = true;
        }
        if (cqe.user_data == @intFromEnum(Tag.accept) and
            cqe.res >= 0 and
            acceptContinues(cqe.flags))
        {
            slot.* = @intCast(cqe.res);
            continue;
        }
        closeRejectedPositive(context, cqe, state);
        return runtime.completionFailure(
            context,
            .multishot_accept,
            .accept,
            cqe,
            @intFromEnum(Tag.accept),
            0,
        );
    }
    return null;
}

pub fn cancelAndDrain(context: *const Context, ring: *IoUring, state: *State) ?Failure {
    std.debug.assert(state.target_armed);
    std.debug.assert(!state.target_terminal_seen);
    var first_failure = submitCancel(context, ring, state);
    if (!state.cancel_armed) return finalize(context, state, first_failure);

    const deadline = runtime.deadlineFromNow() orelse {
        remember(&first_failure, runtime.waitFailure(
            context,
            .cancellation,
            .async_cancel,
            .cancellation,
            .{ .errno = .SUCCESS, .kind = .clock_unavailable },
        ));
        return finalize(context, state, first_failure);
    };
    const completion_limit = std.math.add(
        u32,
        @max(context.returned_completion_entries, 4),
        2,
    ) catch std.math.maxInt(u32);
    var completion_count: u32 = 0;
    while (completion_count < completion_limit) {
        const cqe = switch (nextCompletion(ring, state, deadline)) {
            .cqe => |value| value,
            .empty => break,
            .failure => |wait_failure| {
                remember(&first_failure, runtime.waitFailure(
                    context,
                    .cleanup,
                    .accept,
                    .multishot_accept,
                    wait_failure,
                ));
                if (drainSource(state) == .poll) state.ownership_proven = false;
                break;
            },
        };
        completion_count += 1;
        observe(context, cqe, state, &first_failure, closeAccepted);
    }
    if (completion_count == completion_limit) {
        state.ownership_proven = false;
        remember(&first_failure, context.failure(
            .cleanup_failed,
            .cleanup,
            .accept,
            .multishot_accept,
            .SUCCESS,
            completion_limit,
            completion_count,
        ));
    }
    return finalize(context, state, first_failure);
}

const DrainSource = enum(u8) { wait, poll };

const NextCompletion = union(enum) {
    cqe: linux.io_uring_cqe,
    empty,
    failure: runtime.WaitFailure,
};

fn drainSource(state: *const State) DrainSource {
    if (!state.target_terminal_seen) return .wait;
    if (!state.cancel_seen) return .wait;
    return .poll;
}

fn nextCompletion(
    ring: *IoUring,
    state: *const State,
    deadline: u64,
) NextCompletion {
    return switch (drainSource(state)) {
        .wait => switch (runtime.waitOneUntil(ring, deadline)) {
            .cqe => |cqe| .{ .cqe = cqe },
            .failure => |failure| .{ .failure = failure },
        },
        .poll => pollCompletion(ring),
    };
}

fn pollCompletion(ring: *IoUring) NextCompletion {
    if (runtime.popCompletion(ring)) |cqe| return .{ .cqe = cqe };
    const enter_result = linux.io_uring_enter(
        ring.fd,
        0,
        0,
        linux.IORING_ENTER_GETEVENTS,
        null,
    );
    const enter_errno = linux.errno(enter_result);
    if (pollEnterFailure(enter_errno)) |failure| return .{ .failure = failure };
    if (runtime.popCompletion(ring)) |cqe| return .{ .cqe = cqe };
    if (ring.cq_ring_needs_flush()) {
        return .{ .failure = .{ .errno = .SUCCESS, .kind = .timed_out } };
    }
    return .empty;
}

fn pollEnterFailure(errno_value: linux.E) ?runtime.WaitFailure {
    if (errno_value == .SUCCESS) return null;
    return .{ .errno = errno_value, .kind = .syscall };
}

pub fn unwind(
    context: *const Context,
    ring: *IoUring,
    state: *State,
    original: Failure,
) Failure {
    var failure = original;
    if (state.target_armed and !state.target_terminal_seen) {
        if (cancelAndDrain(context, ring, state)) |cleanup_failure| {
            if (cleanup_failure.requiresProcessExit()) failure.markProcessExitRequired();
        }
    }
    if (!state.ownership_proven or
        (state.target_armed and !state.target_terminal_seen))
    {
        failure.markProcessExitRequired();
    }
    return failure;
}

fn submitCancel(context: *const Context, ring: *IoUring, state: *State) ?Failure {
    std.debug.assert(!state.cancel_armed);
    _ = ring.cancel(
        @intFromEnum(Tag.cancel_accept),
        @intFromEnum(Tag.accept),
        0,
    ) catch {
        state.ownership_proven = false;
        return runtime.submissionFailure(
            context,
            .cancellation,
            .async_cancel,
            .SUCCESS,
            1,
            0,
        );
    };
    state.cancel_armed = true;
    return runtime.submitPending(context, ring, .cancellation, .async_cancel);
}

fn observe(
    context: *const Context,
    cqe: linux.io_uring_cqe,
    state: *State,
    first_failure: *?Failure,
    comptime close_fn: fn (linux.fd_t) linux.E,
) void {
    if (cqe.user_data == @intFromEnum(Tag.accept)) {
        observeAccept(context, cqe, state, first_failure, close_fn);
        return;
    }
    if (cqe.user_data == @intFromEnum(Tag.cancel_accept)) {
        if (state.cancel_seen or cqe.res != 0 or cqe.flags != 0) {
            remember(first_failure, runtime.completionFailure(
                context,
                .cancellation,
                .async_cancel,
                cqe,
                @intFromEnum(Tag.cancel_accept),
                0,
            ));
        }
        state.cancel_seen = true;
        return;
    }

    remember(first_failure, runtime.completionFailure(
        context,
        .cancellation,
        .async_cancel,
        cqe,
        @intFromEnum(Tag.cancel_accept),
        0,
    ));
    if (cqe.res >= 0) state.ownership_proven = false;
}

fn observeAccept(
    context: *const Context,
    cqe: linux.io_uring_cqe,
    state: *State,
    first_failure: *?Failure,
    comptime close_fn: fn (linux.fd_t) linux.E,
) void {
    if (state.target_terminal_seen) {
        state.ownership_proven = false;
        if (cqe.res >= 0) {
            const close_errno = close_fn(@intCast(cqe.res));
            if (close_errno != .SUCCESS) {
                remember(first_failure, context.failure(
                    .cleanup_failed,
                    .cleanup,
                    .close,
                    .multishot_accept,
                    close_errno,
                    1,
                    0,
                ));
            }
        }
        remember(first_failure, runtime.completionFailure(
            context,
            .multishot_accept,
            .accept,
            cqe,
            @intFromEnum(Tag.accept),
            canceled_result,
        ));
        return;
    }
    if (cqe.res >= 0) {
        const close_errno = close_fn(@intCast(cqe.res));
        if (close_errno != .SUCCESS) {
            state.ownership_proven = false;
            remember(first_failure, context.failure(
                .cleanup_failed,
                .cleanup,
                .close,
                .multishot_accept,
                close_errno,
                1,
                0,
            ));
        }
        if (acceptContinues(cqe.flags)) return;
    } else if (cqe.res == canceled_result and cqe.flags == 0) {
        state.target_terminal_seen = true;
        return;
    }

    if (cqe.flags & linux.IORING_CQE_F_MORE == 0) {
        state.target_terminal_seen = true;
    }
    remember(first_failure, runtime.completionFailure(
        context,
        .multishot_accept,
        .accept,
        cqe,
        @intFromEnum(Tag.accept),
        canceled_result,
    ));
}

fn closeRejectedPositive(
    context: *const Context,
    cqe: linux.io_uring_cqe,
    state: *State,
) void {
    if (cqe.res < 0) return;
    if (cqe.user_data != @intFromEnum(Tag.accept)) {
        state.ownership_proven = false;
        return;
    }
    const close_errno = closeAccepted(@intCast(cqe.res));
    if (close_errno != .SUCCESS) {
        _ = context;
        state.ownership_proven = false;
    }
}

fn finalize(context: *const Context, state: *State, first: ?Failure) ?Failure {
    var failure = first;
    if (!state.target_terminal_seen or !state.cancel_seen) {
        remember(&failure, context.failure(
            .cleanup_failed,
            .cleanup,
            .accept,
            .multishot_accept,
            .SUCCESS,
            1,
            0,
        ));
    }
    if (!state.ownership_proven or !state.target_terminal_seen) {
        if (failure == null) {
            failure = context.failure(
                .cleanup_failed,
                .cleanup,
                .accept,
                .multishot_accept,
                .SUCCESS,
                1,
                0,
            );
        }
        failure.?.markProcessExitRequired();
    }
    return failure;
}

fn remember(first: *?Failure, failure: Failure) void {
    if (first.* == null) first.* = failure;
}

fn closeAccepted(fd: linux.fd_t) linux.E {
    return linux.errno(linux.close(fd));
}

fn acceptContinues(flags: u32) bool {
    return flags & linux.IORING_CQE_F_MORE != 0 and
        flags & ~accept_success_flags == 0;
}

fn closeOk(_: linux.fd_t) linux.E {
    return .SUCCESS;
}

fn closeFails(_: linux.fd_t) linux.E {
    return .IO;
}

fn testCompletion(tag: u64, result: i32, flags: u32) linux.io_uring_cqe {
    return .{ .user_data = tag, .res = result, .flags = flags };
}

fn injectTestCompletion(ring: *IoUring, completion: linux.io_uring_cqe) void {
    const tail = @atomicLoad(u32, ring.cq.tail, .acquire);
    std.debug.assert(tail -% ring.cq.head.* < ring.cq.cqes.len);
    ring.cq.cqes[tail & ring.cq.mask] = completion;
    @atomicStore(u32, ring.cq.tail, tail +% 1, .release);
}

test "accept cancellation observation closes races and proves terminal ownership" {
    const context = Context{ .config = .{}, .system = .{} };
    var state = State{ .target_armed = true, .cancel_armed = true };
    var failure: ?Failure = null;
    observe(
        &context,
        testCompletion(
            @intFromEnum(Tag.accept),
            42,
            linux.IORING_CQE_F_MORE | linux.IORING_CQE_F_SOCK_NONEMPTY,
        ),
        &state,
        &failure,
        closeOk,
    );
    observe(
        &context,
        testCompletion(@intFromEnum(Tag.cancel_accept), 0, 0),
        &state,
        &failure,
        closeOk,
    );
    observe(
        &context,
        testCompletion(@intFromEnum(Tag.accept), canceled_result, 0),
        &state,
        &failure,
        closeOk,
    );
    try std.testing.expectEqual(@as(?Failure, null), failure);
    try std.testing.expect(state.target_terminal_seen);
    try std.testing.expect(state.cancel_seen);
    try std.testing.expect(state.ownership_proven);
}

test "accept cancellation drains multiple positives with target before cancel" {
    const context = Context{ .config = .{}, .system = .{} };
    var state = State{ .target_armed = true, .cancel_armed = true };
    var failure: ?Failure = null;
    for (42..44) |fd| {
        observe(
            &context,
            testCompletion(@intFromEnum(Tag.accept), @intCast(fd), linux.IORING_CQE_F_MORE),
            &state,
            &failure,
            closeOk,
        );
    }
    observe(
        &context,
        testCompletion(@intFromEnum(Tag.accept), canceled_result, 0),
        &state,
        &failure,
        closeOk,
    );
    observe(
        &context,
        testCompletion(@intFromEnum(Tag.cancel_accept), 0, 0),
        &state,
        &failure,
        closeOk,
    );
    try std.testing.expectEqual(@as(?Failure, null), finalize(&context, &state, failure));
}

test "accept cancellation marks every unprovable descriptor outcome" {
    const context = Context{ .config = .{}, .system = .{} };
    var close_state = State{ .target_armed = true };
    var close_failure: ?Failure = null;
    observe(
        &context,
        testCompletion(@intFromEnum(Tag.accept), 42, linux.IORING_CQE_F_MORE),
        &close_state,
        &close_failure,
        closeFails,
    );
    try std.testing.expect(!close_state.ownership_proven);
    try std.testing.expect(close_failure != null);
    close_state.target_terminal_seen = true;
    close_state.cancel_seen = true;
    try std.testing.expect(
        finalize(&context, &close_state, close_failure).?.requiresProcessExit(),
    );

    var unknown_state = State{ .target_armed = true };
    var unknown_failure: ?Failure = null;
    observe(
        &context,
        testCompletion(0xdead_beef, 7, 0),
        &unknown_state,
        &unknown_failure,
        closeOk,
    );
    try std.testing.expect(!unknown_state.ownership_proven);
    try std.testing.expect(unknown_failure != null);
    unknown_state.target_terminal_seen = true;
    unknown_state.cancel_seen = true;
    try std.testing.expect(
        finalize(&context, &unknown_state, unknown_failure).?.requiresProcessExit(),
    );
}

test "accept cancellation records terminal success and cancel miss without ownership loss" {
    const context = Context{ .config = .{}, .system = .{} };
    for ([_]linux.E{ .NOENT, .ALREADY }) |cancel_errno| {
        var state = State{ .target_armed = true, .cancel_armed = true };
        var failure: ?Failure = null;
        observe(
            &context,
            testCompletion(@intFromEnum(Tag.accept), 42, 0),
            &state,
            &failure,
            closeOk,
        );
        observe(
            &context,
            testCompletion(
                @intFromEnum(Tag.cancel_accept),
                -@as(i32, @intFromEnum(cancel_errno)),
                0,
            ),
            &state,
            &failure,
            closeOk,
        );
        try std.testing.expect(state.target_terminal_seen);
        try std.testing.expect(state.cancel_seen);
        try std.testing.expect(state.ownership_proven);
        try std.testing.expect(failure != null);
        try std.testing.expect(!finalize(&context, &state, failure).?.requiresProcessExit());
    }
}

test "accept cancellation rejects malformed positive flags after closing descriptor" {
    const context = Context{ .config = .{}, .system = .{} };
    var state = State{ .target_armed = true, .cancel_armed = true };
    var failure: ?Failure = null;
    observe(
        &context,
        testCompletion(
            @intFromEnum(Tag.accept),
            42,
            linux.IORING_CQE_F_MORE | linux.IORING_CQE_F_BUFFER,
        ),
        &state,
        &failure,
        closeOk,
    );
    observe(
        &context,
        testCompletion(@intFromEnum(Tag.accept), canceled_result, 0),
        &state,
        &failure,
        closeOk,
    );
    observe(
        &context,
        testCompletion(@intFromEnum(Tag.cancel_accept), 0, 0),
        &state,
        &failure,
        closeOk,
    );
    const result = finalize(&context, &state, failure).?;
    try std.testing.expect(!result.requiresProcessExit());
    try std.testing.expect(state.ownership_proven);
}

test "accept cancellation rejects every completion after target terminal" {
    const context = Context{ .config = .{}, .system = .{} };

    var duplicate_state = State{ .target_armed = true, .cancel_armed = true };
    var duplicate_failure: ?Failure = null;
    observe(
        &context,
        testCompletion(@intFromEnum(Tag.accept), canceled_result, 0),
        &duplicate_state,
        &duplicate_failure,
        closeOk,
    );
    observe(
        &context,
        testCompletion(@intFromEnum(Tag.accept), canceled_result, 0),
        &duplicate_state,
        &duplicate_failure,
        closeOk,
    );
    duplicate_state.cancel_seen = true;
    const duplicate = finalize(&context, &duplicate_state, duplicate_failure).?;
    try std.testing.expect(duplicate.requiresProcessExit());

    var positive_state = State{ .target_armed = true, .cancel_armed = true };
    var positive_failure: ?Failure = null;
    try std.testing.expectEqual(DrainSource.wait, drainSource(&positive_state));
    observe(
        &context,
        testCompletion(@intFromEnum(Tag.cancel_accept), 0, 0),
        &positive_state,
        &positive_failure,
        closeOk,
    );
    try std.testing.expectEqual(DrainSource.wait, drainSource(&positive_state));
    observe(
        &context,
        testCompletion(@intFromEnum(Tag.accept), canceled_result, 0),
        &positive_state,
        &positive_failure,
        closeOk,
    );
    try std.testing.expectEqual(DrainSource.poll, drainSource(&positive_state));
    observe(
        &context,
        testCompletion(@intFromEnum(Tag.accept), 42, 0),
        &positive_state,
        &positive_failure,
        closeFails,
    );
    const positive = finalize(&context, &positive_state, positive_failure).?;
    try std.testing.expectEqual(model.Operation.close, positive.operation);
    try std.testing.expect(positive.requiresProcessExit());
}

test "accept cleanup treats interrupted poll enter as unproven" {
    try std.testing.expectEqual(@as(?runtime.WaitFailure, null), pollEnterFailure(.SUCCESS));
    const interrupted = pollEnterFailure(.INTR).?;
    try std.testing.expectEqual(linux.E.INTR, interrupted.errno);
    try std.testing.expectEqual(runtime.WaitFailureKind.syscall, interrupted.kind);
}

test "accept cleanup polls a queued positive after both terminals" {
    const context = Context{ .config = .{}, .system = .{} };
    var ring = try IoUring.init(
        8,
        linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN,
    );
    defer ring.deinit();
    const descriptor_result = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(descriptor_result));
    const descriptor: linux.fd_t = @intCast(descriptor_result);
    defer _ = linux.close(descriptor);
    injectTestCompletion(&ring, testCompletion(
        @intFromEnum(Tag.accept),
        descriptor,
        0,
    ));

    var state = State{
        .target_armed = true,
        .target_terminal_seen = true,
        .cancel_armed = true,
        .cancel_seen = true,
    };
    var failure: ?Failure = null;
    const cqe = switch (nextCompletion(&ring, &state, 0)) {
        .cqe => |value| value,
        .empty, .failure => return error.TestUnexpectedResult,
    };
    observe(&context, cqe, &state, &failure, closeAccepted);
    try std.testing.expectEqual(NextCompletion.empty, nextCompletion(&ring, &state, 0));
    const result = finalize(&context, &state, failure).?;
    try std.testing.expect(result.requiresProcessExit());
    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(descriptor, linux.F.GETFD, 0)),
    );
}

test "accept cleanup synthesizes failure when ownership alone is unproven" {
    const context = Context{ .config = .{}, .system = .{} };
    var state = State{
        .target_armed = true,
        .target_terminal_seen = true,
        .cancel_armed = true,
        .cancel_seen = true,
        .ownership_proven = false,
    };
    const failure = finalize(&context, &state, null).?;
    try std.testing.expectEqual(model.ErrorCode.cleanup_failed, failure.code);
    try std.testing.expect(failure.requiresProcessExit());
}
