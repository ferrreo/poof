const std = @import("std");
const linux = std.os.linux;

const probe = @import("../../../src/internal/io_uring/probe.zig");

test "repeated active probes close every racing accept descriptor" {
    const before = try openFileDescriptorCount();
    for (0..2) |_| {
        switch (probe.check(.{})) {
            .ready => {},
            .failure => |failure| {
                var diagnostic: [768]u8 = undefined;
                std.debug.print("{s}", .{try failure.render(&diagnostic)});
                return error.TestUnexpectedResult;
            },
        }
    }
    try std.testing.expectEqual(before, try openFileDescriptorCount());
}

test "partial client startup failure proves accept ownership and leaves fd count flat" {
    const fork_result = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fork_result));
    if (fork_result == 0) runPartialClientFailure();

    var status: u32 = 0;
    const waited = linux.waitpid(@intCast(fork_result), &status, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(waited));
    try std.testing.expectEqual(@as(u32, 0), status & 0x7f);
    try std.testing.expectEqual(@as(u32, 0), (status >> 8) & 0xff);
}

fn runPartialClientFailure() noreturn {
    const before = openFileDescriptorCount() catch linux.exit_group(101);
    var limit: linux.rlimit = undefined;
    if (linux.errno(linux.getrlimit(.NOFILE, &limit)) != .SUCCESS) {
        linux.exit_group(102);
    }
    const constrained = std.math.add(u64, before, 2) catch linux.exit_group(103);
    if (constrained > limit.max) linux.exit_group(104);
    limit.cur = constrained;
    if (linux.errno(linux.setrlimit(.NOFILE, &limit)) != .SUCCESS) {
        linux.exit_group(105);
    }

    const failure = switch (probe.check(.{})) {
        .failure => |value| value,
        .ready => linux.exit_group(106),
    };
    if (failure.requiresProcessExit()) linux.exit_group(107);
    if (failure.phase != .listener and failure.phase != .multishot_accept) {
        linux.exit_group(108);
    }
    const after = openFileDescriptorCount() catch linux.exit_group(109);
    if (after != before) linux.exit_group(110);
    linux.exit_group(0);
}

fn openFileDescriptorCount() !u16 {
    const opened = linux.open(
        "/proc/self/fd",
        .{ .DIRECTORY = true, .CLOEXEC = true },
        0,
    );
    if (linux.errno(opened) != .SUCCESS) return error.FdDirectoryOpenFailed;
    const directory: linux.fd_t = @intCast(opened);
    defer _ = linux.close(directory);

    var entries: [4096]u8 align(@alignOf(u64)) = undefined;
    var count: u16 = 0;
    while (true) {
        const read_result = linux.getdents64(directory, &entries, entries.len);
        if (linux.errno(read_result) != .SUCCESS) return error.FdDirectoryReadFailed;
        if (read_result == 0) return count;

        var offset: usize = 0;
        while (offset < read_result) {
            if (read_result - offset < 19) return error.InvalidFdDirectoryEntry;
            const length = std.mem.readInt(u16, entries[offset + 16 ..][0..2], .little);
            if (length < 19 or length > read_result - offset) {
                return error.InvalidFdDirectoryEntry;
            }
            count = std.math.add(u16, count, 1) catch return error.TooManyFileDescriptors;
            offset += length;
        }
    }
}
