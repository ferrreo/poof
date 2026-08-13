const std = @import("std");

pub const Error = error{
    CompletionFailed,
    CompletionLimitExceeded,
    InvalidOperation,
    PollFailed,
    PollTimeout,
    WorkerFailed,
};

pub fn drive(
    io: anytype,
    worker: anytype,
    sample: anytype,
    connection_index: u16,
) Error!void {
    var completions: u8 = 0;
    while (!hasSend(io, connection_index)) : (completions += 1) {
        if (completions == 32) return error.CompletionLimitExceeded;
        const submission = findWake(io) orelse return error.InvalidOperation;
        const source = switch (submission.operation) {
            .wake => |operation| operation.source,
            else => return error.InvalidOperation,
        };
        try waitReadable(@intCast(source.value));
        io.complete(
            submission.token,
            .{ .success = .{ .wake = {} } },
            false,
        ) catch return error.CompletionFailed;
        const completion = io.nextCompletion() orelse return error.CompletionFailed;
        var step = worker.handle(completion, sample) catch return error.WorkerFailed;
        var retries: u8 = 0;
        while (step == .flush_retry) : (retries += 1) {
            if (retries == 8) return error.CompletionLimitExceeded;
            step = worker.retryFlush() catch return error.WorkerFailed;
        }
    }
}

fn hasSend(io: anytype, connection_index: u16) bool {
    var index: u16 = 0;
    while (index < io.activeCount()) : (index += 1) {
        const submission = io.activeSubmission(index).?;
        const fields = submission.token.fields() catch continue;
        if (fields.kind == .send and fields.slot_index == connection_index) return true;
    }
    return false;
}

fn findWake(io: anytype) ?@TypeOf(io.activeSubmission(0).?) {
    var index: u16 = 0;
    while (index < io.activeCount()) : (index += 1) {
        const submission = io.activeSubmission(index).?;
        const fields = submission.token.fields() catch continue;
        if (fields.kind == .wake) return submission;
    }
    return null;
}

fn waitReadable(descriptor: std.os.linux.fd_t) Error!void {
    var descriptors = [1]std.os.linux.pollfd{.{
        .fd = descriptor,
        .events = std.os.linux.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        descriptors[0].revents = 0;
        const count = std.os.linux.poll(&descriptors, descriptors.len, 5_000);
        switch (std.os.linux.errno(count)) {
            .SUCCESS => {
                if (count == 0) return error.PollTimeout;
                if (count != 1 or descriptors[0].revents & std.os.linux.POLL.IN == 0) {
                    return error.PollFailed;
                }
                return;
            },
            .INTR => continue,
            else => return error.PollFailed,
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
