const std = @import("std");
const linux = std.os.linux;

const event_counter = @import("../runtime/event_counter.zig");
const model = @import("probe_types.zig");
const runtime = @import("probe_runtime.zig");

const IoUring = linux.IoUring;
const wake_tag: u64 = 0x504c_0008;

pub fn proveWake(context: *const model.Context, ring: *IoUring) ?model.Failure {
    var counter = switch (event_counter.Counter.open()) {
        .opened => |opened| opened,
        .failed => |problem| return counterFailure(context, problem),
    };
    const proof_failure = proveOpenCounter(context, ring, &counter);
    if (counter.close()) |problem| return closeFailure(context, problem);
    return proof_failure;
}

fn proveOpenCounter(
    context: *const model.Context,
    ring: *IoUring,
    counter: *event_counter.Counter,
) ?model.Failure {
    if (counter.signal()) |problem| return counterFailure(context, problem);
    _ = ring.poll_add(wake_tag, counter.descriptor, linux.POLL.IN) catch {
        return runtime.submissionFailure(
            context,
            .event_wake,
            .poll_add,
            .SUCCESS,
            1,
            0,
        );
    };
    if (runtime.submitPending(context, ring, .event_wake, .poll_add)) |failure| {
        return failure;
    }

    const completion = switch (runtime.waitOne(ring)) {
        .cqe => |cqe| cqe,
        .failure => |problem| return runtime.waitFailure(
            context,
            .event_wake,
            .poll_add,
            .event_wake,
            problem,
        ),
    };
    if (!validCompletion(completion)) {
        return runtime.completionFailure(
            context,
            .event_wake,
            .poll_add,
            completion,
            wake_tag,
            linux.POLL.IN,
        );
    }
    return verifyDrain(context, counter.drain());
}

fn verifyDrain(
    context: *const model.Context,
    result: event_counter.DrainResult,
) ?model.Failure {
    return switch (result) {
        .count => |count| if (count == 1)
            null
        else
            context.failure(
                .runtime_invariant,
                .event_wake,
                .read,
                .event_wake,
                .SUCCESS,
                1,
                std.math.cast(i64, count) orelse std.math.maxInt(i64),
            ),
        .empty => context.failure(
            .runtime_invariant,
            .event_wake,
            .read,
            .event_wake,
            .AGAIN,
            1,
            0,
        ),
        .failed => |problem| counterFailure(context, problem),
    };
}

fn validCompletion(completion: linux.io_uring_cqe) bool {
    return completion.user_data == wake_tag and
        completion.res == linux.POLL.IN and
        completion.flags == 0;
}

fn counterFailure(
    context: *const model.Context,
    problem: event_counter.Failure,
) model.Failure {
    return context.failure(
        .event_counter_failed,
        .event_wake,
        operationForStage(problem.stage),
        .event_wake,
        problem.errno,
        0,
        0,
    );
}

fn closeFailure(
    context: *const model.Context,
    problem: event_counter.Failure,
) model.Failure {
    var result = context.failure(
        .cleanup_failed,
        .cleanup,
        .close,
        .event_wake,
        problem.errno,
        0,
        0,
    );
    result.markProcessExitRequired();
    return result;
}

fn operationForStage(stage: event_counter.Stage) model.Operation {
    return switch (stage) {
        .open => .eventfd,
        .signal => .write,
        .drain => .read,
        .close => .close,
    };
}

test "event wake completion accepts only exact poll readiness" {
    const valid = linux.io_uring_cqe{
        .user_data = wake_tag,
        .res = linux.POLL.IN,
        .flags = 0,
    };
    try std.testing.expect(validCompletion(valid));
    var changed = valid;
    changed.user_data += 1;
    try std.testing.expect(!validCompletion(changed));
    changed = valid;
    changed.res = 0;
    try std.testing.expect(!validCompletion(changed));
    changed = valid;
    changed.flags = linux.IORING_CQE_F_MORE;
    try std.testing.expect(!validCompletion(changed));
}
