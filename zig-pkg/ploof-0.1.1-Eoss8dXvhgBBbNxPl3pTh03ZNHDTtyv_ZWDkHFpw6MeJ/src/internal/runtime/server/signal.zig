const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

var test_fail_next_open = std.atomic.Value(bool).init(false);
var test_fail_next_restore = std.atomic.Value(bool).init(false);

pub const Signal = enum(u8) {
    interrupt,
    terminate,
};

pub const Error = error{
    MaskBlockFailed,
    MaskRestoreFailed,
    SignalFdOpenFailed,
    SignalFdReadFailed,
    SignalFdCloseFailed,
    InvalidSignalRecord,
};

/// Synchronous SIGINT/SIGTERM source. Open before worker creation so every
/// later thread inherits the blocked mask.
pub const Source = struct {
    descriptor: linux.fd_t,
    previous_mask: linux.sigset_t,
    live: bool = true,

    pub fn open() Error!Source {
        var mask = signalMask();
        var previous: linux.sigset_t = undefined;
        if (linux.errno(linux.sigprocmask(linux.SIG.BLOCK, &mask, &previous)) != .SUCCESS) {
            return error.MaskBlockFailed;
        }
        errdefer _ = restoreMask(&previous);

        const result = if (comptime builtin.is_test)
            if (test_fail_next_open.swap(false, .acq_rel))
                std.math.maxInt(usize)
            else
                linux.signalfd(-1, &mask, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK)
        else
            linux.signalfd(-1, &mask, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK);
        if (linux.errno(result) != .SUCCESS) {
            if (!restoreMask(&previous)) return error.MaskRestoreFailed;
            return error.SignalFdOpenFailed;
        }
        return .{ .descriptor = @intCast(result), .previous_mask = previous };
    }

    pub fn next(source: *const Source) Error!?Signal {
        if (!source.live) return error.SignalFdReadFailed;
        var record: linux.signalfd_siginfo = undefined;
        while (true) {
            const result = linux.read(
                source.descriptor,
                std.mem.asBytes(&record).ptr,
                @sizeOf(linux.signalfd_siginfo),
            );
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result != @sizeOf(linux.signalfd_siginfo)) {
                        return error.InvalidSignalRecord;
                    }
                    return switch (record.signo) {
                        @intFromEnum(linux.SIG.INT) => .interrupt,
                        @intFromEnum(linux.SIG.TERM) => .terminate,
                        else => error.InvalidSignalRecord,
                    };
                },
                .INTR => continue,
                .AGAIN => return null,
                else => return error.SignalFdReadFailed,
            }
        }
    }

    pub fn closeAndRestore(source: *Source) Error!void {
        if (!source.live) return;
        var drain_problem: ?Error = null;
        drainPending(source) catch |problem| {
            drain_problem = problem;
        };
        source.live = false;
        const close_failed = linux.errno(linux.close(source.descriptor)) != .SUCCESS;
        const restore_failed = !restoreMask(&source.previous_mask);
        if (restore_failed) return error.MaskRestoreFailed;
        if (close_failed) return error.SignalFdCloseFailed;
        if (drain_problem) |problem| return problem;
    }
};

fn drainPending(source: *const Source) Error!void {
    while ((try source.next()) != null) {}
}

fn signalMask() linux.sigset_t {
    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, .INT);
    linux.sigaddset(&mask, .TERM);
    return mask;
}

fn restoreMask(previous: *const linux.sigset_t) bool {
    const restored = linux.errno(
        linux.sigprocmask(linux.SIG.SETMASK, previous, null),
    ) == .SUCCESS;
    if (comptime builtin.is_test) {
        if (test_fail_next_restore.swap(false, .acq_rel)) return false;
    }
    return restored;
}

pub const TestAccess = if (builtin.is_test) struct {
    pub fn failNextOpen() void {
        test_fail_next_open.store(true, .release);
    }

    pub fn failNextRestore() void {
        test_fail_next_restore.store(true, .release);
    }
} else struct {};

test "signalfd consumes blocked termination signals without a handler" {
    var source = try Source.open();
    defer if (source.live) source.closeAndRestore() catch {};

    try std.testing.expect((try source.next()) == null);
    try sendToSelf(.TERM);
    try std.testing.expectEqual(Signal.terminate, (try source.next()).?);
    try sendToSelf(.INT);
    try std.testing.expectEqual(Signal.interrupt, (try source.next()).?);
    try source.closeAndRestore();
}

test "signal source restores the caller mask exactly" {
    const before = currentMask();
    var source = try Source.open();
    const blocked = currentMask();
    try std.testing.expect(linux.sigismember(&blocked, .INT));
    try std.testing.expect(linux.sigismember(&blocked, .TERM));
    try source.closeAndRestore();
    const after = currentMask();
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&before),
        std.mem.asBytes(&after),
    );
}

test "close drains every coalesced termination record before restoring mask" {
    const before = currentMask();
    var source = try Source.open();
    try sendToSelf(.TERM);
    try sendToSelf(.INT);
    try sendToSelf(.TERM);
    try std.testing.expect((try source.next()) != null);
    try source.closeAndRestore();
    const after = currentMask();
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&before),
        std.mem.asBytes(&after),
    );
}

test "open reports rollback failure instead of hiding a changed mask" {
    const before = currentMask();
    TestAccess.failNextOpen();
    TestAccess.failNextRestore();
    try std.testing.expectError(error.MaskRestoreFailed, Source.open());
    const after = currentMask();
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&before),
        std.mem.asBytes(&after),
    );
}

fn currentMask() linux.sigset_t {
    var mask: linux.sigset_t = undefined;
    const result = linux.sigprocmask(linux.SIG.SETMASK, null, &mask);
    std.debug.assert(linux.errno(result) == .SUCCESS);
    return mask;
}

fn sendToSelf(signal: linux.SIG) !void {
    const result = linux.kill(linux.getpid(), signal);
    if (linux.errno(result) != .SUCCESS) return error.TestUnexpectedResult;
}
