const std = @import("std");
const linux = std.os.linux;

const reactor = @import("../reactor.zig");
const upload_io = @import("../../../upload_io.zig");

const resolve_no_xdev: u64 = 0x01;
const resolve_no_magic_links: u64 = 0x02;
const resolve_no_symlinks: u64 = 0x04;
const resolve_beneath: u64 = 0x08;

pub const PrepareError = error{InvalidSubmission};

/// Caller-owned storage remains stable until successful submission returns.
pub const OpenHow = extern struct {
    flags: u64,
    mode: u64,
    resolve: u64,
};

pub const anonymous_link_path_bytes = "/proc/self/fd/".len + 10 + 1;
pub const AnonymousLinkPath = [anonymous_link_path_bytes]u8;

comptime {
    if (@sizeOf(OpenHow) != 24 or @alignOf(OpenHow) != 8) {
        @compileError("Linux open_how ABI mismatch");
    }
}

pub fn prepareOpen(
    sqe: *linux.io_uring_sqe,
    how: *OpenHow,
    token: reactor.OperationToken,
    operation: reactor.FileOpen,
) PrepareError!void {
    try requireValid(token, .{ .file_open = operation });
    how.* = .{
        .flags = @as(u32, @bitCast(openFlags(operation))),
        .mode = operation.mode,
        .resolve = resolveFlags(operation.resolve),
    };
    sqe.prep_rw(
        .OPENAT2,
        openBaseDescriptor(operation.base),
        @intFromPtr(operation.path.ptr),
        @sizeOf(OpenHow),
        @intFromPtr(how),
    );
    sqe.user_data = token.raw();
}

pub fn prepareWrite(
    sqe: *linux.io_uring_sqe,
    token: reactor.OperationToken,
    operation: reactor.FileWrite,
) PrepareError!void {
    try requireValid(token, .{ .file_write = operation });
    sqe.prep_write(operation.file.value, operation.bytes, operation.offset);
    sqe.user_data = token.raw();
}

pub fn prepareRead(
    sqe: *linux.io_uring_sqe,
    token: reactor.OperationToken,
    operation: reactor.FileRead,
) PrepareError!void {
    try requireValid(token, .{ .file_read = operation });
    sqe.prep_read(operation.file.value, operation.bytes, operation.offset);
    sqe.user_data = token.raw();
}

pub fn prepareStat(
    sqe: *linux.io_uring_sqe,
    token: reactor.OperationToken,
    operation: reactor.FileStat,
) PrepareError!void {
    try requireValid(token, .{ .file_stat = operation });
    sqe.prep_statx(
        operation.file.value,
        "",
        linux.AT.EMPTY_PATH,
        linux.STATX.BASIC_STATS,
        operation.output,
    );
    sqe.user_data = token.raw();
}

pub fn prepareClose(
    sqe: *linux.io_uring_sqe,
    token: reactor.OperationToken,
    operation: reactor.FileClose,
) PrepareError!void {
    try requireValid(token, .{ .file_close = operation });
    sqe.prep_close(operation.file.value);
    sqe.user_data = token.raw();
}

pub fn prepareLink(
    sqe: *linux.io_uring_sqe,
    source_path_storage: *AnonymousLinkPath,
    token: reactor.OperationToken,
    operation: reactor.FileLink,
) PrepareError!void {
    try requireValid(token, .{ .file_link = operation });
    const source_path = std.fmt.bufPrintZ(
        source_path_storage,
        "/proc/self/fd/{d}",
        .{operation.source.value},
    ) catch unreachable;
    sqe.prep_linkat(
        linux.AT.FDCWD,
        source_path.ptr,
        operation.target_directory.value,
        operation.target_path.ptr,
        linux.AT.SYMLINK_FOLLOW,
    );
    sqe.user_data = token.raw();
}

pub fn prepareUnlink(
    sqe: *linux.io_uring_sqe,
    token: reactor.OperationToken,
    operation: reactor.FileUnlink,
) PrepareError!void {
    try requireValid(token, .{ .file_unlink = operation });
    sqe.prep_unlinkat(operation.directory.value, operation.path.ptr, 0);
    sqe.user_data = token.raw();
}

pub fn prepareRenameNoReplace(
    sqe: *linux.io_uring_sqe,
    token: reactor.OperationToken,
    operation: reactor.FileRenameNoReplace,
) PrepareError!void {
    try requireValid(token, .{ .file_rename_no_replace = operation });
    const flags: u32 = @bitCast(linux.RENAME{ .NOREPLACE = true });
    sqe.prep_renameat(
        operation.source_directory.value,
        operation.source_path.ptr,
        operation.target_directory.value,
        operation.target_path.ptr,
        flags,
    );
    sqe.user_data = token.raw();
}

pub fn prepareSync(
    sqe: *linux.io_uring_sqe,
    token: reactor.OperationToken,
    operation: reactor.FileSync,
) PrepareError!void {
    try requireValid(token, .{ .file_sync = operation });
    sqe.prep_fsync(operation.file.value, 0);
    sqe.user_data = token.raw();
}

pub fn prepareCancel(
    sqe: *linux.io_uring_sqe,
    token: reactor.OperationToken,
    operation: reactor.UploadCancel,
) PrepareError!void {
    try requireValid(token, .{ .upload_cancel = operation });
    sqe.prep_cancel(operation.target.raw(), 0);
    sqe.user_data = token.raw();
}

pub fn prepareFileCancel(
    sqe: *linux.io_uring_sqe,
    token: reactor.OperationToken,
    operation: reactor.FileCancel,
) PrepareError!void {
    try requireValid(token, .{ .file_cancel = operation });
    sqe.prep_cancel(operation.target.raw(), 0);
    sqe.user_data = token.raw();
}

fn requireValid(
    token: reactor.OperationToken,
    operation: reactor.Operation,
) PrepareError!void {
    if ((reactor.Submission{ .token = token, .operation = operation }).validate() != null) {
        return error.InvalidSubmission;
    }
}

fn openBaseDescriptor(base: reactor.FileOpenBase) linux.fd_t {
    return switch (base) {
        .working_directory => linux.AT.FDCWD,
        .directory => |directory| directory.value,
    };
}

fn openFlags(operation: reactor.FileOpen) linux.O {
    const exclusive = operation.create == .exclusive;
    const anonymous = operation.create == .anonymous;
    return .{
        .ACCMODE = switch (operation.access) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        },
        .CREAT = exclusive,
        .EXCL = exclusive,
        .DIRECTORY = operation.kind == .directory or anonymous,
        .NOFOLLOW = operation.no_follow,
        .NONBLOCK = operation.non_blocking,
        .CLOEXEC = true,
        .TMPFILE = anonymous,
    };
}

fn resolveFlags(resolve: upload_io.Resolve) u64 {
    return @as(u64, @intFromBool(resolve.no_mount_crossing)) * resolve_no_xdev |
        @as(u64, @intFromBool(resolve.no_magic_links)) * resolve_no_magic_links |
        @as(u64, @intFromBool(resolve.no_symlinks)) * resolve_no_symlinks |
        @as(u64, @intFromBool(resolve.beneath)) * resolve_beneath;
}

test {
    std.testing.refAllDecls(@This());
}
