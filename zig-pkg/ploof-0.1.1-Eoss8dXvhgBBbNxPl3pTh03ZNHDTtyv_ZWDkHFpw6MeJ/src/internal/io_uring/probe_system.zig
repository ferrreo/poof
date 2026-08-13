const std = @import("std");
const linux = std.os.linux;

const model = @import("probe_types.zig");

pub const KernelVersion = struct {
    major: u32,
    minor: u32,
};

pub const KernelVersionIssue = union(enum) {
    unavailable,
    too_old: KernelVersion,
};

pub fn captureSystemEvidence() model.SystemEvidence {
    var evidence = model.SystemEvidence{};
    var name: linux.utsname = undefined;
    if (linux.errno(linux.uname(&name)) == .SUCCESS) {
        const release = std.mem.sliceTo(&name.release, 0);
        evidence.kernel_release_len = @intCast(@min(
            release.len,
            evidence.kernel_release.len,
        ));
        for (
            evidence.kernel_release[0..evidence.kernel_release_len],
            release[0..evidence.kernel_release_len],
        ) |*destination, source| {
            destination.* = if (source >= 0x20 and source <= 0x7e) source else '?';
        }
        evidence.known.kernel_release = true;
    }

    if (readProcInt("/proc/sys/kernel/io_uring_disabled")) |value| {
        evidence.io_uring_disabled = value;
        evidence.known.io_uring_disabled = true;
    }
    if (readProcInt("/proc/sys/kernel/io_uring_group")) |value| {
        evidence.io_uring_group = value;
        evidence.known.io_uring_group = true;
    }

    const seccomp_result = linux.prctl(@intFromEnum(linux.PR.GET_SECCOMP), 0, 0, 0, 0);
    if (linux.errno(seccomp_result) == .SUCCESS and seccomp_result <= 2) {
        evidence.seccomp_mode = @intCast(seccomp_result);
        evidence.known.seccomp_mode = true;
    }

    var limit: linux.rlimit = undefined;
    if (linux.errno(linux.getrlimit(.NOFILE, &limit)) == .SUCCESS) {
        evidence.rlimit_nofile = limit.cur;
        evidence.known.rlimit_nofile = true;
    }
    if (linux.errno(linux.getrlimit(.MEMLOCK, &limit)) == .SUCCESS) {
        evidence.rlimit_memlock = limit.cur;
        evidence.known.rlimit_memlock = true;
    }
    return evidence;
}

pub fn validateKernelRelease(release: []const u8) ?KernelVersionIssue {
    const version = parseKernelVersion(release) orelse return .unavailable;
    if (version.major < 6 or (version.major == 6 and version.minor < 1)) {
        return .{ .too_old = version };
    }
    return null;
}

pub fn parseKernelVersion(release: []const u8) ?KernelVersion {
    const first_dot = std.mem.indexOfScalar(u8, release, '.') orelse return null;
    const remainder = release[first_dot + 1 ..];
    const minor_end = std.mem.indexOfNone(u8, remainder, "0123456789") orelse
        remainder.len;
    if (first_dot == 0 or minor_end == 0) return null;
    return .{
        .major = std.fmt.parseInt(u32, release[0..first_dot], 10) catch return null,
        .minor = std.fmt.parseInt(u32, remainder[0..minor_end], 10) catch return null,
    };
}

pub fn packVersion(major: u32, minor: u32) i64 {
    return @as(i64, major) << 32 | minor;
}

pub fn packQueueShape(submission_entries: u32, completion_entries: u32) i64 {
    return @as(i64, submission_entries) << 32 | completion_entries;
}

fn readProcInt(path: [*:0]const u8) ?i32 {
    const open_result = linux.openat(
        linux.AT.FDCWD,
        path,
        .{ .CLOEXEC = true },
        0,
    );
    if (linux.errno(open_result) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(open_result);
    defer _ = linux.close(fd);

    var buffer: [32]u8 = undefined;
    const read_result = linux.read(fd, &buffer, buffer.len);
    if (linux.errno(read_result) != .SUCCESS or read_result == 0) return null;
    const text = std.mem.trim(u8, buffer[0..read_result], " \t\r\n");
    return std.fmt.parseInt(i32, text, 10) catch null;
}

test "kernel version parser accepts release suffixes" {
    try std.testing.expectEqual(
        KernelVersion{ .major = 7, .minor = 1 },
        parseKernelVersion("7.1.3-custom").?,
    );
    try std.testing.expectEqual(
        KernelVersion{ .major = 6, .minor = 1 },
        parseKernelVersion("6.1").?,
    );
    try std.testing.expectEqual(null, parseKernelVersion("not-a-kernel"));
}

test "kernel floor classifier rejects missing and old versions" {
    try std.testing.expectEqual(KernelVersionIssue.unavailable, validateKernelRelease("").?);
    try std.testing.expectEqual(
        KernelVersionIssue.unavailable,
        validateKernelRelease("not-a-kernel").?,
    );
    try std.testing.expectEqual(
        KernelVersion{ .major = 5, .minor = 15 },
        validateKernelRelease("5.15.0").?.too_old,
    );
    try std.testing.expectEqual(null, validateKernelRelease("6.1.0"));
    try std.testing.expectEqual(null, validateKernelRelease("7.1.3-pikaos"));
}
