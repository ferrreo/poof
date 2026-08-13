const std = @import("std");
const io = @import("../../src/upload_io.zig");

const directory = io.FileHandle.init(3);
const file = io.FileHandle.fromParts(4, 7);
const directory_base = io.OpenBase{ .handle = directory };

test "I/O requirements contain and merge exact operation kinds" {
    const first = io.IoRequirements{ .open = true, .close = true };
    const second = io.IoRequirements{ .write = true, .sync = true };
    const merged = first.merge(second);
    const invalid: io.IoRequirements = @bitCast(@as(u8, 0x80));

    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(io.IoRequirements.none)));
    try std.testing.expectEqual(@as(u8, 0x7f), @as(u8, @bitCast(io.IoRequirements.all)));
    try std.testing.expect(io.IoRequirements.none.valid());
    try std.testing.expect(io.IoRequirements.all.valid());
    try std.testing.expect(!invalid.valid());
    inline for (std.enums.values(io.IoKind)) |kind| {
        try std.testing.expectEqual(kind == .open or kind == .close, first.contains(kind));
        try std.testing.expectEqual(
            kind == .open or kind == .write or kind == .close or kind == .sync,
            merged.contains(kind),
        );
        try std.testing.expect(io.IoRequirements.all.contains(kind));
        try std.testing.expect(!io.IoRequirements.none.contains(kind));
    }
}

fn expectRequestIssue(expected: io.RequestIssue, request: io.IoRequest) !void {
    try std.testing.expectEqual(expected, request.validate().?);
}

test "normalized upload I/O accepts every FileSink operation" {
    const requests = [_]io.IoRequest{
        .{ .open = .{
            .base = directory_base,
            .path = "users/a",
            .access = .read_only,
            .kind = .directory,
            .resolve = .{
                .beneath = true,
                .no_symlinks = true,
                .no_magic_links = true,
                .no_mount_crossing = true,
            },
        } },
        .{ .open = .{
            .base = directory_base,
            .path = ".",
            .access = .read_write,
            .create = .anonymous,
            .mode = 0o600,
        } },
        .{ .write = .{ .file = file, .bytes = "abc", .offset = 9 } },
        .{ .sync = .{ .file = file } },
        .{ .link = .{
            .source = file,
            .target_directory = directory,
            .target_path = "a.bin",
        } },
        .{ .rename_no_replace = .{
            .source = file,
            .source_directory = directory,
            .source_path = ".ploof-stage",
            .target_directory = directory,
            .target_path = "a.bin",
        } },
        .{ .unlink = .{ .directory = directory, .path = ".ploof-stage" } },
        .{ .close = .{ .file = file } },
    };
    for (requests) |request| try std.testing.expect(request.validate() == null);
}

test "working-directory open accepts bootstrap paths" {
    const paths = [_][:0]const u8{
        "var/lib/ploof/uploads",
        "/srv/ploof/uploads",
    };
    for (paths) |path| {
        const request = io.IoRequest{ .open = .{
            .base = .working_directory,
            .path = path,
            .access = .read_only,
            .kind = .directory,
            .resolve = .{
                .no_symlinks = true,
                .no_magic_links = true,
            },
        } };
        try std.testing.expect(request.validate() == null);
    }
}

test "working-directory open rejects invalid bootstrap paths" {
    try expectRequestIssue(.empty_path, .{ .open = .{
        .base = .working_directory,
        .path = "",
        .access = .read_only,
    } });
    try expectRequestIssue(.path_contains_nul, .{ .open = .{
        .base = .working_directory,
        .path = "inside\x00tail",
        .access = .read_only,
    } });
    try expectRequestIssue(.invalid_open_combination, .{ .open = .{
        .base = .working_directory,
        .path = "/srv/ploof/uploads",
        .access = .read_only,
        .resolve = .{ .beneath = true },
    } });
}

test "logical file handles retain compact slot generations" {
    const initial = io.FileHandle.init(9);
    const later = io.FileHandle.fromParts(9, 2);

    try std.testing.expectEqual(@as(usize, 4), @sizeOf(io.FileHandle));
    try std.testing.expectEqual(@as(u16, 9), initial.index());
    try std.testing.expectEqual(@as(u16, 1), initial.generation());
    try std.testing.expect(initial.valid());
    try std.testing.expect(!initial.eql(later));
    try std.testing.expect(later.eql(io.FileHandle.fromParts(9, 2)));
    try std.testing.expect(!io.FileHandle.fromParts(9, 0).valid());
}

test "normalized upload I/O rejects invalid handles for every request" {
    const invalid = io.FileHandle.fromParts(0, 0);
    const requests = [_]io.IoRequest{
        .{ .open = .{
            .base = .{ .handle = invalid },
            .path = "a",
            .access = .read_only,
        } },
        .{ .write = .{ .file = invalid, .bytes = "a", .offset = 0 } },
        .{ .close = .{ .file = invalid } },
        .{ .link = .{
            .source = invalid,
            .target_directory = directory,
            .target_path = "b",
        } },
        .{ .link = .{
            .source = file,
            .target_directory = invalid,
            .target_path = "b",
        } },
        .{ .unlink = .{ .directory = invalid, .path = "a" } },
        .{ .rename_no_replace = .{
            .source = invalid,
            .source_directory = directory,
            .source_path = "a",
            .target_directory = directory,
            .target_path = "b",
        } },
        .{ .rename_no_replace = .{
            .source = file,
            .source_directory = invalid,
            .source_path = "a",
            .target_directory = directory,
            .target_path = "b",
        } },
        .{ .rename_no_replace = .{
            .source = file,
            .source_directory = directory,
            .source_path = "a",
            .target_directory = invalid,
            .target_path = "b",
        } },
        .{ .sync = .{ .file = invalid } },
    };
    for (requests) |request| try expectRequestIssue(.invalid_handle, request);
}

test "normalized upload I/O rejects every invalid path form" {
    const bad_paths = [_]struct {
        value: [:0]const u8,
        expected: io.RequestIssue,
    }{
        .{ .value = "", .expected = .empty_path },
        .{ .value = "/escape", .expected = .absolute_path },
        .{ .value = "inside\x00tail", .expected = .path_contains_nul },
    };
    for (bad_paths) |bad| {
        const requests = [_]io.IoRequest{
            .{ .open = .{
                .base = directory_base,
                .path = bad.value,
                .access = .read_only,
            } },
            .{ .link = .{
                .source = file,
                .target_directory = directory,
                .target_path = bad.value,
            } },
            .{ .unlink = .{ .directory = directory, .path = bad.value } },
            .{ .rename_no_replace = .{
                .source = file,
                .source_directory = directory,
                .source_path = bad.value,
                .target_directory = directory,
                .target_path = "b",
            } },
            .{ .rename_no_replace = .{
                .source = file,
                .source_directory = directory,
                .source_path = "a",
                .target_directory = directory,
                .target_path = bad.value,
            } },
        };
        for (requests) |request| try expectRequestIssue(bad.expected, request);
    }
}

test "normalized upload I/O rejects invalid open modes and creation" {
    const cases = [_]struct {
        request: io.Open,
        expected: io.RequestIssue,
    }{
        .{
            .request = .{
                .base = directory_base,
                .path = "a",
                .access = .read_only,
                .mode = 0o1000,
            },
            .expected = .invalid_mode,
        },
        .{
            .request = .{
                .base = directory_base,
                .path = "a",
                .access = .write_only,
                .mode = 0o600,
            },
            .expected = .invalid_open_combination,
        },
        .{
            .request = .{
                .base = directory_base,
                .path = "a",
                .access = .write_only,
                .create = .exclusive,
            },
            .expected = .invalid_open_combination,
        },
        .{
            .request = .{
                .base = directory_base,
                .path = "a",
                .access = .read_only,
                .create = .exclusive,
                .mode = 0o600,
            },
            .expected = .invalid_open_combination,
        },
        .{
            .request = .{
                .base = directory_base,
                .path = ".",
                .access = .read_write,
                .create = .anonymous,
            },
            .expected = .invalid_open_combination,
        },
        .{
            .request = .{
                .base = directory_base,
                .path = ".",
                .access = .write_only,
                .create = .anonymous,
                .mode = 0o600,
            },
            .expected = .invalid_open_combination,
        },
        .{
            .request = .{
                .base = directory_base,
                .path = ".",
                .access = .read_write,
                .create = .anonymous,
                .kind = .directory,
                .mode = 0o600,
            },
            .expected = .invalid_open_combination,
        },
        .{
            .request = .{
                .base = directory_base,
                .path = "a",
                .access = .write_only,
                .create = .exclusive,
                .kind = .directory,
                .mode = 0o600,
            },
            .expected = .invalid_open_combination,
        },
    };
    for (cases) |case| {
        try expectRequestIssue(case.expected, .{ .open = case.request });
    }
}

test "normalized upload I/O rejects invalid writes and link paths" {
    const pointer: [*]const u8 = "x";
    const oversized = pointer[0 .. @as(usize, std.math.maxInt(u32)) + 1];

    try expectRequestIssue(.empty_write, .{
        .write = .{ .file = file, .bytes = "", .offset = 0 },
    });
    try expectRequestIssue(.write_too_large, .{
        .write = .{ .file = file, .bytes = oversized, .offset = 0 },
    });
    try std.testing.expect((io.IoRequest{ .write = .{
        .file = file,
        .bytes = "a",
        .offset = std.math.maxInt(i64) - 1,
    } }).validate() == null);
    try expectRequestIssue(.write_overflow, .{ .write = .{
        .file = file,
        .bytes = "a",
        .offset = std.math.maxInt(i64),
    } });
    try expectRequestIssue(.write_overflow, .{ .write = .{
        .file = file,
        .bytes = "ab",
        .offset = std.math.maxInt(u64),
    } });
    try expectRequestIssue(.absolute_path, .{ .link = .{
        .source = file,
        .target_directory = directory,
        .target_path = "/final",
    } });
}

test "poll events and results retain typed boundaries" {
    const Event = io.PollEvent(u32);
    const Result = io.Poll(u64);
    const started = Event{ .start = 7 };
    const completed = Event{ .completion = .{ .success = .{ .write = 3 } } };
    const pending = Result{ .request = .{ .sync = .{ .file = file } } };
    const done = Result{ .done = 11 };

    try std.testing.expectEqual(@as(u32, 7), started.start);
    try std.testing.expectEqual(@as(u32, 3), completed.completion.success.write);
    try std.testing.expect(pending.request.validate() == null);
    try std.testing.expectEqual(@as(u64, 11), done.done);
}

test "normalized upload success rejects zero writes and forged handles" {
    try std.testing.expectEqual(
        io.SuccessIssue.zero_write,
        (io.IoSuccess{ .write = 0 }).validate().?,
    );
    try std.testing.expectEqual(
        io.SuccessIssue.invalid_handle,
        (io.IoSuccess{ .open = io.FileHandle.fromParts(7, 0) }).validate().?,
    );
}
