const std = @import("std");

const reactor = @import("../../../src/internal/runtime/reactor.zig");
const worker_upload = @import("../../../src/internal/runtime/worker/upload_transport.zig");

pub fn drainRollback(
    controller: anytype,
    storage: anytype,
    io: anytype,
    expected: anyerror,
    cleanup_failure: bool,
) !void {
    const close_b = io.takeKind(.file_close);
    try std.testing.expectEqual(@as(i32, 81), close_b.operation.file_close.file.value);
    try std.testing.expect(try completeTimedTarget(
        controller,
        storage,
        io,
        close_b,
        if (cleanup_failure)
            .{ .failure = .canceled }
        else
            .{ .success = .{ .file_close = {} } },
        false,
    ) == .none);
    if (cleanup_failure) try completeOwnerCleanup(controller, storage, io, 81);
    const close_a = io.takeKind(.file_close);
    try std.testing.expectEqual(@as(i32, 80), close_a.operation.file_close.file.value);
    const result = completeTimedTarget(
        controller,
        storage,
        io,
        close_a,
        .{ .success = .{ .file_close = {} } },
        false,
    );
    try std.testing.expectError(expected, result);
    try std.testing.expectEqual(worker_upload.Phase.failed, controller.phase);
    try std.testing.expectEqual(cleanup_failure, controller.rollback_cleanup_failed);
    try std.testing.expectEqual(@as(u32, 0), controller.activeHandles());
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expect(controller.ownershipProven());
}

fn completeOwnerCleanup(controller: anytype, storage: anytype, io: anytype, fd: i32) !void {
    const close = io.takeKind(.file_close);
    try std.testing.expectEqual(fd, close.operation.file_close.file.value);
    try std.testing.expect(try completeTimedTarget(
        controller,
        storage,
        io,
        close,
        .{ .success = .{ .file_close = {} } },
        false,
    ) == .none);
}

pub fn completeTimedTarget(
    controller: anytype,
    storage: anytype,
    io: anytype,
    target: reactor.Submission,
    result: reactor.CompletionResult,
    fail_before_resume: bool,
) !worker_upload.Event {
    const timeout = io.takeKind(.timeout);
    try std.testing.expect(try controller.complete(storage, io, .{
        .token = target.token,
        .result = result,
        .more = false,
    }) == .none);
    const cancel = io.takeKind(.cancel);
    try std.testing.expect(try controller.complete(storage, io, .{
        .token = timeout.token,
        .result = .{ .failure = .canceled },
        .more = false,
    }) == .none);
    if (fail_before_resume) io.fail_next_submit = true;
    return controller.complete(storage, io, .{
        .token = cancel.token,
        .result = .{ .success = .{ .cancel = .canceled } },
        .more = false,
    });
}

test {
    std.testing.refAllDecls(@This());
}
