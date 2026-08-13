const std = @import("std");

pub const FileHandle = struct {
    pub const ploof_template_helper_capability = true;

    token: u32,

    const index_mask: u32 = std.math.maxInt(u16);

    pub fn init(slot_index: u16) FileHandle {
        return fromParts(slot_index, 1);
    }

    pub fn fromParts(slot_index: u16, slot_generation: u16) FileHandle {
        return .{
            .token = @as(u32, slot_index) |
                (@as(u32, slot_generation) << 16),
        };
    }

    pub fn index(self: FileHandle) u16 {
        return @truncate(self.token & index_mask);
    }

    pub fn generation(self: FileHandle) u16 {
        return @truncate(self.token >> 16);
    }

    pub fn eql(left: FileHandle, right: FileHandle) bool {
        return left.token == right.token;
    }

    pub fn valid(self: FileHandle) bool {
        return self.generation() != 0;
    }
};

pub const Access = enum(u8) {
    read_only,
    write_only,
    read_write,
};

pub const Create = enum(u8) {
    none,
    exclusive,
    anonymous,
};

pub const OpenKind = enum(u8) {
    file,
    directory,
};

pub const OpenBase = union(enum) {
    working_directory,
    handle: FileHandle,
};

pub const Resolve = packed struct(u8) {
    beneath: bool = false,
    no_symlinks: bool = false,
    no_magic_links: bool = false,
    no_mount_crossing: bool = false,
    _: u4 = 0,
};

pub const Open = struct {
    base: OpenBase,
    /// Borrowed through the matching completion.
    path: [:0]const u8,
    access: Access,
    create: Create = .none,
    kind: OpenKind = .file,
    no_follow: bool = true,
    mode: u16 = 0,
    resolve: Resolve = .{},
};

pub const Write = struct {
    file: FileHandle,
    /// Borrowed through every short-write retry and the final completion.
    bytes: []const u8,
    offset: u64,
};

pub const Close = struct {
    file: FileHandle,
};

pub const Link = struct {
    source: FileHandle,
    target_directory: FileHandle,
    /// Borrowed through the matching completion.
    target_path: [:0]const u8,
};

pub const Unlink = struct {
    directory: FileHandle,
    /// Borrowed through the matching completion.
    path: [:0]const u8,
};

pub const RenameNoReplace = struct {
    /// Tracked file opened exclusively at source_directory/source_path.
    /// The source namespace must remain private from untrusted writers.
    source: FileHandle,
    source_directory: FileHandle,
    /// Both paths are borrowed through the matching completion.
    source_path: [:0]const u8,
    target_directory: FileHandle,
    target_path: [:0]const u8,
};

pub const Sync = struct {
    file: FileHandle,
};

pub const IoKind = enum(u8) {
    open,
    write,
    close,
    link,
    unlink,
    rename_no_replace,
    sync,
};

pub const IoRequirements = packed struct(u8) {
    open: bool = false,
    write: bool = false,
    close: bool = false,
    link: bool = false,
    unlink: bool = false,
    rename_no_replace: bool = false,
    sync: bool = false,
    _: u1 = 0,

    pub const none: @This() = .{};
    pub const all: @This() = .{
        .open = true,
        .write = true,
        .close = true,
        .link = true,
        .unlink = true,
        .rename_no_replace = true,
        .sync = true,
    };

    pub fn contains(self: @This(), kind: IoKind) bool {
        const shift: u3 = @intCast(@intFromEnum(kind));
        return @as(u8, @bitCast(self)) & (@as(u8, 1) << shift) != 0;
    }

    pub fn valid(self: @This()) bool {
        return @as(u8, @bitCast(self)) & 0x80 == 0;
    }

    pub fn merge(left: @This(), right: @This()) @This() {
        return @bitCast(@as(u8, @bitCast(left)) | @as(u8, @bitCast(right)));
    }
};

comptime {
    const singleton = [_]IoRequirements{
        .{ .open = true },
        .{ .write = true },
        .{ .close = true },
        .{ .link = true },
        .{ .unlink = true },
        .{ .rename_no_replace = true },
        .{ .sync = true },
    };
    for (std.enums.values(IoKind), 0..) |kind, index| {
        std.debug.assert(@intFromEnum(kind) == index);
        std.debug.assert(@as(u8, @bitCast(singleton[index])) == @as(u8, 1) << @intCast(index));
    }
}

pub const IoRequest = union(IoKind) {
    open: Open,
    write: Write,
    close: Close,
    link: Link,
    unlink: Unlink,
    rename_no_replace: RenameNoReplace,
    sync: Sync,

    pub fn validate(self: IoRequest) ?RequestIssue {
        return switch (self) {
            .open => |value| validateOpen(value),
            .write => |value| validateWrite(value),
            .close => |value| validateHandle(value.file),
            .link => |value| validateLink(value),
            .unlink => |value| validateUnlink(value),
            .rename_no_replace => |value| validateRenameNoReplace(value),
            .sync => |value| validateHandle(value.file),
        };
    }
};

pub const RequestIssue = enum(u8) {
    invalid_handle,
    empty_path,
    absolute_path,
    path_contains_nul,
    invalid_mode,
    invalid_open_combination,
    empty_write,
    write_too_large,
    write_overflow,
};

pub const IoError = enum(u8) {
    canceled,
    already_exists,
    not_found,
    invalid_path,
    cross_device,
    read_only,
    quota_exceeded,
    file_too_large,
    no_space,
    permission_denied,
    resource_exhausted,
    invalid_resource,
    unsupported,
    io_failure,
};

pub const IoSuccess = union(IoKind) {
    open: FileHandle,
    write: u32,
    close: void,
    link: void,
    unlink: void,
    rename_no_replace: void,
    sync: void,

    pub fn validate(self: IoSuccess) ?SuccessIssue {
        return switch (self) {
            .open => |handle| if (handle.valid()) null else .invalid_handle,
            .write => |written| if (written == 0) .zero_write else null,
            .close, .link, .unlink, .rename_no_replace, .sync => null,
        };
    }
};

pub const SuccessIssue = enum(u8) {
    invalid_handle,
    zero_write,
};

pub const IoCompletion = union(enum) {
    success: IoSuccess,
    failure: IoError,
};

pub fn PollEvent(comptime Start: type) type {
    return union(enum) {
        start: Start,
        completion: IoCompletion,
    };
}

pub fn Poll(comptime Output: type) type {
    return union(enum) {
        request: IoRequest,
        done: Output,
    };
}

fn validateOpen(value: Open) ?RequestIssue {
    switch (value.base) {
        .working_directory => {
            if (validatePath(value.path, false, true)) |problem| return problem;
            if (value.path[0] == '/' and value.resolve.beneath) {
                return .invalid_open_combination;
            }
        },
        .handle => |handle| {
            if (!handle.valid()) return .invalid_handle;
            if (validatePath(value.path, false, false)) |problem| return problem;
        },
    }
    if (value.mode > 0o777) return .invalid_mode;
    switch (value.create) {
        .none => if (value.mode != 0) return .invalid_open_combination,
        .exclusive => {
            if (value.mode == 0 or value.access == .read_only) {
                return .invalid_open_combination;
            }
        },
        .anonymous => {
            if (value.mode == 0 or value.access != .read_write or value.kind != .file) {
                return .invalid_open_combination;
            }
        },
    }
    if (value.kind == .directory and value.create != .none) {
        return .invalid_open_combination;
    }
    return null;
}

fn validateWrite(value: Write) ?RequestIssue {
    if (!value.file.valid()) return .invalid_handle;
    if (value.bytes.len == 0) return .empty_write;
    if (value.bytes.len > std.math.maxInt(u32)) return .write_too_large;
    const end = std.math.add(u64, value.offset, value.bytes.len) catch {
        return .write_overflow;
    };
    if (end > std.math.maxInt(i64)) return .write_overflow;
    return null;
}

fn validateLink(value: Link) ?RequestIssue {
    if (!value.source.valid() or !value.target_directory.valid()) return .invalid_handle;
    return validatePath(value.target_path, false, false);
}

fn validateUnlink(value: Unlink) ?RequestIssue {
    if (!value.directory.valid()) return .invalid_handle;
    return validatePath(value.path, false, false);
}

fn validateRenameNoReplace(value: RenameNoReplace) ?RequestIssue {
    if (!value.source.valid() or
        !value.source_directory.valid() or
        !value.target_directory.valid())
    {
        return .invalid_handle;
    }
    if (validatePath(value.source_path, false, false)) |problem| return problem;
    return validatePath(value.target_path, false, false);
}

fn validateHandle(value: FileHandle) ?RequestIssue {
    return if (value.valid()) null else .invalid_handle;
}

fn validatePath(
    path: [:0]const u8,
    allow_empty: bool,
    allow_absolute: bool,
) ?RequestIssue {
    if (path.len == 0 and !allow_empty) return .empty_path;
    if (path.len != 0 and path[0] == '/' and !allow_absolute) return .absolute_path;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return .path_contains_nul;
    return null;
}

test {
    std.testing.refAllDecls(@This());
}
