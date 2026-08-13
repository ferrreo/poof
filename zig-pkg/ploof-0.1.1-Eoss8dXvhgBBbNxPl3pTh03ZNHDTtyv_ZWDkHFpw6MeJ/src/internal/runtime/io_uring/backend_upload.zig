const std = @import("std");

const config = @import("../config.zig");
const io_uring_file = @import("file.zig");
const reactor = @import("../reactor.zig");
const runtime_capacity = @import("../runtime_capacity.zig");

pub const Inputs = runtime_capacity.Inputs;
pub const Capacity = runtime_capacity.Capacity;
pub const OpenHow = io_uring_file.OpenHow;
pub const AnonymousLinkPath = io_uring_file.AnonymousLinkPath;
pub const PrepareError = error{
    SubmissionQueueFull,
    InvalidSubmission,
    OpenStorageFull,
    LinkStorageFull,
};

pub fn Metadata(comptime enabled: bool, comptime entries: u16) type {
    if (!enabled) return struct {
        pub fn reset(self: *@This()) void {
            _ = self;
        }

        pub fn assertValid(self: *const @This()) void {
            _ = self;
        }
    };
    return struct {
        open_hows: [entries]OpenHow = undefined,
        link_paths: [entries]AnonymousLinkPath = undefined,
        open_count: u16 = 0,
        link_count: u16 = 0,

        pub fn reset(self: *@This()) void {
            self.open_count = 0;
            self.link_count = 0;
        }

        pub fn assertValid(self: *const @This()) void {
            std.debug.assert(self.open_count <= self.open_hows.len);
            std.debug.assert(self.link_count <= self.link_paths.len);
        }
    };
}

pub fn capacity(
    comptime limits: config.Limits,
    comptime inputs: ?Inputs,
) Capacity {
    if (inputs) |upload| {
        if (upload.connection_slots != limits.connection_slots) {
            @compileError("upload connection slots differ from runtime limits");
        }
        if (upload.body_workspace_slots != limits.body_workspace_slots) {
            @compileError("upload body workspace slots differ from runtime limits");
        }
        return runtime_capacity.validate(upload);
    }
    return runtime_capacity.validate(.{
        .connection_slots = limits.connection_slots,
        .body_workspace_slots = 0,
        .upload_window_max = 0,
        .request_handles_max = 0,
        .runtime_handles_max = 0,
        .async_sink_present = false,
    });
}

pub fn isSubmission(submission: reactor.Submission) bool {
    const kind = std.meta.activeTag(submission.operation);
    return reactor.isFileOperation(kind) or kind == .upload_cancel or kind == .file_cancel;
}

pub fn prepare(
    ring: anytype,
    metadata: anytype,
    submission: reactor.Submission,
) PrepareError!void {
    if (submission.validate() != null or !isSubmission(submission)) {
        return error.InvalidSubmission;
    }
    const is_open = std.meta.activeTag(submission.operation) == .file_open;
    const is_link = std.meta.activeTag(submission.operation) == .file_link;
    if (is_open and metadata.open_count >= metadata.open_hows.len) {
        return error.OpenStorageFull;
    }
    if (is_link and metadata.link_count >= metadata.link_paths.len) {
        return error.LinkStorageFull;
    }
    const sqe = ring.get_sqe() catch return error.SubmissionQueueFull;
    const token = submission.token;
    switch (submission.operation) {
        .file_open => |operation| try io_uring_file.prepareOpen(
            sqe,
            &metadata.open_hows[metadata.open_count],
            token,
            operation,
        ),
        .file_write => |operation| try io_uring_file.prepareWrite(sqe, token, operation),
        .file_read => |operation| try io_uring_file.prepareRead(sqe, token, operation),
        .file_stat => |operation| try io_uring_file.prepareStat(sqe, token, operation),
        .file_close => |operation| try io_uring_file.prepareClose(sqe, token, operation),
        .file_link => |operation| try io_uring_file.prepareLink(
            sqe,
            &metadata.link_paths[metadata.link_count],
            token,
            operation,
        ),
        .file_unlink => |operation| try io_uring_file.prepareUnlink(sqe, token, operation),
        .file_rename_no_replace => |operation| {
            try io_uring_file.prepareRenameNoReplace(sqe, token, operation);
        },
        .file_sync => |operation| try io_uring_file.prepareSync(sqe, token, operation),
        .upload_cancel => |operation| try io_uring_file.prepareCancel(sqe, token, operation),
        .file_cancel => |operation| try io_uring_file.prepareFileCancel(sqe, token, operation),
        else => return error.InvalidSubmission,
    }
    metadata.open_count += @intFromBool(is_open);
    metadata.link_count += @intFromBool(is_link);
}

test {
    std.testing.refAllDecls(@This());
}

test "invalid upload submission does not acquire an SQE" {
    const linux = std.os.linux;
    const FakeRing = struct {
        sqe: linux.io_uring_sqe = undefined,
        acquired: u8 = 0,

        fn get_sqe(self: *@This()) !*linux.io_uring_sqe {
            self.acquired += 1;
            return &self.sqe;
        }
    };
    var ring = FakeRing{};
    var metadata = Metadata(true, 1){};
    const operation_token = try testToken(.file_write, 1);
    try std.testing.expectError(error.InvalidSubmission, prepare(
        &ring,
        &metadata,
        .{ .token = operation_token, .operation = .{ .file_write = .{
            .file = .{ .value = -1 },
            .bytes = "x",
            .offset = 0,
        } } },
    ));
    try std.testing.expectEqual(@as(u8, 0), ring.acquired);
    try std.testing.expectEqual(@as(u16, 0), metadata.open_count);
    try std.testing.expectEqual(@as(u16, 0), metadata.link_count);
}

test "link path storage is stable bounded and reset explicitly" {
    const linux = std.os.linux;
    const FakeRing = struct {
        sqe: linux.io_uring_sqe = undefined,
        acquired: u8 = 0,

        fn get_sqe(self: *@This()) !*linux.io_uring_sqe {
            self.acquired += 1;
            return &self.sqe;
        }
    };
    var ring = FakeRing{};
    var metadata = Metadata(true, 1){};
    const operation = reactor.FileLink{
        .source = .{ .value = 81 },
        .target_directory = .{ .value = 82 },
        .target_path = "final.bin",
    };
    try prepare(&ring, &metadata, .{
        .token = try testToken(.file_link, 1),
        .operation = .{ .file_link = operation },
    });
    try std.testing.expectEqual(@as(u8, 1), ring.acquired);
    try std.testing.expectEqual(@as(u16, 1), metadata.link_count);
    try std.testing.expectEqualStrings(
        "/proc/self/fd/81",
        std.mem.sliceTo(&metadata.link_paths[0], 0),
    );
    try std.testing.expectEqual(@intFromPtr(&metadata.link_paths[0]), ring.sqe.addr);

    try std.testing.expectError(error.LinkStorageFull, prepare(&ring, &metadata, .{
        .token = try testToken(.file_link, 2),
        .operation = .{ .file_link = operation },
    }));
    try std.testing.expectEqual(@as(u8, 1), ring.acquired);
    metadata.reset();
    try std.testing.expectEqual(@as(u16, 0), metadata.link_count);
}

fn testToken(kind: reactor.OperationKind, sequence: u16) !reactor.OperationToken {
    return reactor.OperationToken.init(.{
        .kind = kind,
        .worker_index = 0,
        .slot_index = 1,
        .slot_generation = 1,
        .sequence = sequence,
    });
}
