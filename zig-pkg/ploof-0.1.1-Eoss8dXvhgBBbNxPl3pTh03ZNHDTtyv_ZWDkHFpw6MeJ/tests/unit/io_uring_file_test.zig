const std = @import("std");
const linux = std.os.linux;

const io_uring_file = @import("../../src/internal/runtime/io_uring/file.zig");
const reactor = @import("../../src/internal/runtime/reactor.zig");

test "open_how matches Linux ABI" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(io_uring_file.OpenHow));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(io_uring_file.OpenHow));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(io_uring_file.OpenHow, "flags"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(io_uring_file.OpenHow, "mode"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(io_uring_file.OpenHow, "resolve"));
}

test "OPENAT2 carries caller-owned open_how and exact policy" {
    const operation = reactor.FileOpen{
        .base = .working_directory,
        .path = "/srv/uploads",
        .access = .read_only,
        .kind = .directory,
        .resolve = .{
            .beneath = false,
            .no_symlinks = true,
            .no_magic_links = true,
            .no_mount_crossing = true,
        },
    };
    const operation_token = try token(.file_open, 1);
    var how: io_uring_file.OpenHow = undefined;
    var sqe: linux.io_uring_sqe = undefined;
    try io_uring_file.prepareOpen(&sqe, &how, operation_token, operation);

    const expected_flags: u32 = @bitCast(linux.O{
        .DIRECTORY = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    });
    try std.testing.expectEqual(@as(u64, expected_flags), how.flags);
    try std.testing.expectEqual(@as(u64, 0), how.mode);
    try std.testing.expectEqual(@as(u64, 0x07), how.resolve);
    try expectSqe(sqe, .{
        .opcode = .OPENAT2,
        .fd = linux.AT.FDCWD,
        .off = @intFromPtr(&how),
        .addr = @intFromPtr(operation.path.ptr),
        .len = @sizeOf(io_uring_file.OpenHow),
        .user_data = operation_token.raw(),
    });
}

test "OPENAT2 maps exclusive and anonymous creation flags exactly" {
    const Case = struct {
        operation: reactor.FileOpen,
        flags: linux.O,
    };
    const cases = [_]Case{
        .{
            .operation = .{
                .base = .{ .directory = .{ .value = 31 } },
                .path = "named.tmp",
                .access = .write_only,
                .create = .exclusive,
                .no_follow = false,
                .mode = 0o640,
            },
            .flags = .{
                .ACCMODE = .WRONLY,
                .CREAT = true,
                .EXCL = true,
                .CLOEXEC = true,
            },
        },
        .{
            .operation = .{
                .base = .{ .directory = .{ .value = 32 } },
                .path = ".",
                .access = .read_write,
                .create = .anonymous,
                .no_follow = false,
                .mode = 0o600,
            },
            .flags = .{
                .ACCMODE = .RDWR,
                .DIRECTORY = true,
                .CLOEXEC = true,
                .TMPFILE = true,
            },
        },
    };
    for (cases, 0..) |case, index| {
        const operation_token = try token(.file_open, @intCast(index + 2));
        var how: io_uring_file.OpenHow = undefined;
        var sqe: linux.io_uring_sqe = undefined;
        try io_uring_file.prepareOpen(&sqe, &how, operation_token, case.operation);
        try std.testing.expectEqual(@as(u64, @as(u32, @bitCast(case.flags))), how.flags);
        try std.testing.expectEqual(@as(u64, case.operation.mode), how.mode);
        try std.testing.expectEqual(case.operation.base.directory.value, sqe.fd);
    }
}

test "OPENAT2 maps every resolve restriction" {
    const operation = reactor.FileOpen{
        .base = .{ .directory = .{ .value = 33 } },
        .path = "child",
        .access = .read_only,
        .resolve = .{
            .beneath = true,
            .no_symlinks = true,
            .no_magic_links = true,
            .no_mount_crossing = true,
        },
    };
    var how: io_uring_file.OpenHow = undefined;
    var sqe: linux.io_uring_sqe = undefined;
    try io_uring_file.prepareOpen(&sqe, &how, try token(.file_open, 4), operation);
    try std.testing.expectEqual(@as(u64, 0x0f), how.resolve);
}

test "WRITE and CLOSE SQEs preserve descriptor buffer offset and token" {
    const bytes = "upload bytes";
    const write_token = try token(.file_write, 5);
    var sqe: linux.io_uring_sqe = undefined;
    try io_uring_file.prepareWrite(&sqe, write_token, .{
        .file = .{ .value = 41 },
        .bytes = bytes,
        .offset = 987,
    });
    try expectSqe(sqe, .{
        .opcode = .WRITE,
        .fd = 41,
        .off = 987,
        .addr = @intFromPtr(bytes.ptr),
        .len = bytes.len,
        .user_data = write_token.raw(),
    });

    const close_token = try token(.file_close, 6);
    try io_uring_file.prepareClose(&sqe, close_token, .{ .file = .{ .value = 42 } });
    try expectSqe(sqe, .{
        .opcode = .CLOSE,
        .fd = 42,
        .user_data = close_token.raw(),
    });
}

test "READ and STATX SQEs preserve buffers snapshots and tokens" {
    var bytes: [4096]u8 = undefined;
    const read_token = try token(.file_read, 17);
    var sqe: linux.io_uring_sqe = undefined;
    try io_uring_file.prepareRead(&sqe, read_token, .{
        .file = .{ .value = 43 },
        .bytes = &bytes,
        .offset = 1234,
    });
    try expectSqe(sqe, .{
        .opcode = .READ,
        .fd = 43,
        .off = 1234,
        .addr = @intFromPtr(&bytes),
        .len = bytes.len,
        .user_data = read_token.raw(),
    });

    var statx: linux.Statx = undefined;
    const stat_token = try token(.file_stat, 18);
    try io_uring_file.prepareStat(&sqe, stat_token, .{
        .file = .{ .value = 44 },
        .output = &statx,
    });
    try std.testing.expectEqual(linux.IORING_OP.STATX, sqe.opcode);
    try std.testing.expectEqual(@as(i32, 44), sqe.fd);
    try std.testing.expectEqual(@intFromPtr(&statx), sqe.off);
    try std.testing.expectEqual(@as(u8, 0), @as([*]const u8, @ptrFromInt(sqe.addr))[0]);
    try std.testing.expectEqual(@as(u32, @bitCast(linux.STATX.BASIC_STATS)), sqe.len);
    try std.testing.expectEqual(@as(u32, linux.AT.EMPTY_PATH), sqe.rw_flags);
    try std.testing.expectEqual(stat_token.raw(), sqe.user_data);
}

test "LINKAT publishes an anonymous file through procfs without privilege" {
    try std.testing.expectEqual(@as(usize, 25), io_uring_file.anonymous_link_path_bytes);
    const operation_token = try token(.file_link, 7);
    const operation = reactor.FileLink{
        .source = .{ .value = 51 },
        .target_directory = .{ .value = 52 },
        .target_path = "final.bin",
    };
    var source_path: io_uring_file.AnonymousLinkPath = undefined;
    var sqe: linux.io_uring_sqe = undefined;
    try io_uring_file.prepareLink(&sqe, &source_path, operation_token, operation);
    try std.testing.expectEqualStrings("/proc/self/fd/51", std.mem.sliceTo(&source_path, 0));
    try expectSqe(sqe, .{
        .opcode = .LINKAT,
        .fd = linux.AT.FDCWD,
        .off = @intFromPtr(operation.target_path.ptr),
        .addr = @intFromPtr(&source_path),
        .len = 52,
        .rw_flags = linux.AT.SYMLINK_FOLLOW,
        .user_data = operation_token.raw(),
    });

    const maximum = reactor.FileLink{
        .source = .{ .value = std.math.maxInt(i32) },
        .target_directory = .{ .value = 52 },
        .target_path = "maximum.bin",
    };
    try io_uring_file.prepareLink(&sqe, &source_path, operation_token, maximum);
    try std.testing.expectEqualStrings(
        "/proc/self/fd/2147483647",
        std.mem.sliceTo(&source_path, 0),
    );
}

test "UNLINKAT RENAMEAT and FSYNC use exact flags" {
    var sqe: linux.io_uring_sqe = undefined;
    const unlink_token = try token(.file_unlink, 9);
    const unlink_path: [:0]const u8 = "old.bin";
    try io_uring_file.prepareUnlink(&sqe, unlink_token, .{
        .directory = .{ .value = 61 },
        .path = unlink_path,
    });
    try expectSqe(sqe, .{
        .opcode = .UNLINKAT,
        .fd = 61,
        .addr = @intFromPtr(unlink_path.ptr),
        .user_data = unlink_token.raw(),
    });

    const rename_token = try token(.file_rename_no_replace, 10);
    const source_path: [:0]const u8 = "staged.bin";
    const target_path: [:0]const u8 = "final.bin";
    try io_uring_file.prepareRenameNoReplace(&sqe, rename_token, .{
        .source_directory = .{ .value = 62 },
        .source_path = source_path,
        .target_directory = .{ .value = 63 },
        .target_path = target_path,
    });
    const rename_flags: u32 = @bitCast(linux.RENAME{ .NOREPLACE = true });
    try expectSqe(sqe, .{
        .opcode = .RENAMEAT,
        .fd = 62,
        .off = @intFromPtr(target_path.ptr),
        .addr = @intFromPtr(source_path.ptr),
        .len = 63,
        .rw_flags = rename_flags,
        .user_data = rename_token.raw(),
    });

    const sync_token = try token(.file_sync, 11);
    try io_uring_file.prepareSync(&sqe, sync_token, .{ .file = .{ .value = 64 } });
    try expectSqe(sqe, .{
        .opcode = .FSYNC,
        .fd = 64,
        .user_data = sync_token.raw(),
    });
}

test "ASYNC_CANCEL targets only matching upload operation token" {
    const target = try token(.file_write, 12);
    const cancel_token = try token(.upload_cancel, 13);
    var sqe: linux.io_uring_sqe = undefined;
    try io_uring_file.prepareCancel(&sqe, cancel_token, .{ .target = target });
    try expectSqe(sqe, .{
        .opcode = .ASYNC_CANCEL,
        .fd = -1,
        .addr = target.raw(),
        .user_data = cancel_token.raw(),
    });

    const network_target = try token(.receive, 14);
    try std.testing.expectError(
        error.InvalidSubmission,
        io_uring_file.prepareCancel(&sqe, cancel_token, .{ .target = network_target }),
    );
}

test "ASYNC_CANCEL targets only matching live file operation owner" {
    const target = try token(.file_read, 19);
    const cancel_token = try token(.file_cancel, 20);
    var sqe: linux.io_uring_sqe = undefined;
    try io_uring_file.prepareFileCancel(&sqe, cancel_token, .{ .target = target });
    try expectSqe(sqe, .{
        .opcode = .ASYNC_CANCEL,
        .fd = -1,
        .addr = target.raw(),
        .user_data = cancel_token.raw(),
    });

    const network_target = try token(.receive, 21);
    try std.testing.expectError(
        error.InvalidSubmission,
        io_uring_file.prepareFileCancel(&sqe, cancel_token, .{ .target = network_target }),
    );
}

test "preparation rejects invalid token kind and operation before mutation" {
    const bytes = "x";
    const wrong_token = try token(.file_close, 15);
    var sqe = zeroSqe();
    const before = sqe;
    try std.testing.expectError(
        error.InvalidSubmission,
        io_uring_file.prepareWrite(&sqe, wrong_token, .{
            .file = .{ .value = 71 },
            .bytes = bytes,
            .offset = 0,
        }),
    );
    try std.testing.expectEqualDeep(before, sqe);

    const write_token = try token(.file_write, 16);
    try std.testing.expectError(
        error.InvalidSubmission,
        io_uring_file.prepareWrite(&sqe, write_token, .{
            .file = .{ .value = -1 },
            .bytes = bytes,
            .offset = 0,
        }),
    );
    try std.testing.expectEqualDeep(before, sqe);
}

const ExpectedSqe = struct {
    opcode: linux.IORING_OP,
    fd: i32 = 0,
    off: u64 = 0,
    addr: u64 = 0,
    len: u32 = 0,
    rw_flags: u32 = 0,
    user_data: u64,
};

fn expectSqe(actual: linux.io_uring_sqe, expected: ExpectedSqe) !void {
    try std.testing.expectEqualDeep(linux.io_uring_sqe{
        .opcode = expected.opcode,
        .flags = 0,
        .ioprio = 0,
        .fd = expected.fd,
        .off = expected.off,
        .addr = expected.addr,
        .len = expected.len,
        .rw_flags = expected.rw_flags,
        .user_data = expected.user_data,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .resv = 0,
    }, actual);
}

fn token(kind: reactor.OperationKind, sequence: u16) !reactor.OperationToken {
    return reactor.OperationToken.init(.{
        .kind = kind,
        .worker_index = 3,
        .slot_index = 17,
        .slot_generation = 5,
        .sequence = sequence,
    });
}

fn zeroSqe() linux.io_uring_sqe {
    var sqe: linux.io_uring_sqe = undefined;
    sqe.prep_nop();
    return sqe;
}
