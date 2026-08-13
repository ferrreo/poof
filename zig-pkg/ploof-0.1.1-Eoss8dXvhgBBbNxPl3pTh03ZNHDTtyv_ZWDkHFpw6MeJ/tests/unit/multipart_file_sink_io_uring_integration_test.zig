const std = @import("std");
const linux = std.os.linux;

const multipart = @import("../../src/multipart.zig");
const allocation_guard = @import("../../src/internal/runtime/allocation_guard.zig");
const harness_module = @import("internal/runtime/upload_io_uring_test_harness.zig");

const anonymous_buffered = multipart.FileSinkConfig{
    .root = "root",
    .durability = .buffered,
};
const anonymous_durable = multipart.FileSinkConfig{
    .root = "root",
    .durability = .crash_durable,
};
const named_buffered = multipart.FileSinkConfig{
    .root = "root",
    .durability = .buffered,
    .staging = .{ .named_staging = ".stage" },
};
const named_durable = multipart.FileSinkConfig{
    .root = "root",
    .durability = .crash_durable,
    .staging = .{ .named_staging = ".stage" },
};

const first_chunk = "ploof ";
const second_chunk = "upload";
const uploaded = first_chunk ++ second_chunk;
const sentinel = "existing destination";
const replacement = "must not replace";
const entropy = [_]u8{0x5a} ** 32;

test "public FileSink runs through real io_uring in all four modes" {
    @setEvalBranchQuota(1_000_000);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "root/nested");
    try temporary.dir.createDirPath(std.testing.io, "root/.stage");
    const original_cwd = try enterTemporary(temporary.dir.handle);
    defer restoreCwd(original_cwd);

    inline for (.{
        .{ anonymous_buffered, "nested/anonymous-buffered.bin", "nested/existing-ab.bin" },
        .{ anonymous_durable, "nested/anonymous-durable.bin", "nested/existing-ad.bin" },
        .{ named_buffered, "nested/named-buffered.bin", "nested/existing-nb.bin" },
        .{ named_durable, "nested/named-durable.bin", "nested/existing-nd.bin" },
    }) |case| try exercise(case[0], temporary.dir, case[1], case[2]);
}

test "FileSink rejects hostile symlink parents through real io_uring" {
    @setEvalBranchQuota(1_000_000);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "root/inside");
    try temporary.dir.createDirPath(std.testing.io, "root/.stage");
    try temporary.dir.createDirPath(std.testing.io, "outside");
    try temporary.dir.symLink(
        std.testing.io,
        "../outside",
        "root/escape",
        .{ .is_directory = true },
    );
    try temporary.dir.symLink(
        std.testing.io,
        "inside",
        "root/alias",
        .{ .is_directory = true },
    );
    const original_cwd = try enterTemporary(temporary.dir.handle);
    defer restoreCwd(original_cwd);

    inline for (.{ anonymous_buffered, named_buffered }) |supplied| {
        try exerciseSymlinkRejection(supplied, temporary.dir);
    }
    try expectFileAbsent(temporary.dir, "outside/escaped.bin");
    try expectFileAbsent(temporary.dir, "root/inside/aliased.bin");
}

test "FileSink retained parent prevents symlink replacement redirection" {
    @setEvalBranchQuota(1_000_000);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "root/live-anonymous");
    try temporary.dir.createDirPath(std.testing.io, "root/live-named");
    try temporary.dir.createDirPath(std.testing.io, "root/.stage");
    try temporary.dir.createDirPath(std.testing.io, "outside");
    const original_cwd = try enterTemporary(temporary.dir.handle);
    defer restoreCwd(original_cwd);

    try exercisePinnedParent(
        anonymous_buffered,
        temporary.dir,
        "live-anonymous",
        "pinned-anonymous",
    );
    try exercisePinnedParent(
        named_buffered,
        temporary.dir,
        "live-named",
        "pinned-named",
    );
}

test "FileSink named staging exposes the documented external-writer boundary" {
    @setEvalBranchQuota(1_000_000);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "root/nested");
    try temporary.dir.createDirPath(std.testing.io, "root/.stage");
    const original_cwd = try enterTemporary(temporary.dir.handle);
    defer restoreCwd(original_cwd);

    const Sink = multipart.FileSink(named_buffered);
    const RealHarness = harness_module.Harness(Sink, 76);
    var harness: RealHarness = undefined;
    try harness.init();
    defer harness.abortBackend();
    var runtime_driver = RealHarness.RuntimeDriver{};
    try harness.runtimeStart(&runtime_driver, .{ .worker_index = 0, .entropy = &entropy });
    const runtime = runtime_driver.runtimePointer() orelse return error.MissingSinkRuntime;

    var lifecycle = RealHarness.LifecycleDriver{};
    var writer = RealHarness.WriteDriver{};
    var state = Sink.initial_state;
    try harness.begin(
        &lifecycle,
        runtime,
        &state,
        try Sink.Key.init("nested/substituted.bin"),
    );
    try harness.write(&writer, runtime, &state, .{ .bytes = uploaded, .offset = 0 });

    var stage_path_storage: [128]u8 = undefined;
    const stage_path = try std.fmt.bufPrint(
        &stage_path_storage,
        "root/.stage/{s}",
        .{state.temp_name.bytes()},
    );
    try temporary.dir.rename(stage_path, temporary.dir, "root/.stage/retained", std.testing.io);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = stage_path,
        .data = replacement,
    });

    _ = try harness.finish(&lifecycle, runtime, &state, .{ .bytes = uploaded.len });
    try harness.commit(&lifecycle, runtime, &state);
    try expectFile(temporary.dir, "root/nested/substituted.bin", replacement);
    try expectFile(temporary.dir, "root/.stage/retained", uploaded);
    try harness.abort(&lifecycle, runtime, &state);
    try harness.runtimeStop(&runtime_driver);
    try harness.deinit();
}

test "FileSink request path allocates no address space after runtime readiness" {
    const fork_result = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fork_result));
    if (fork_result == 0) {
        runGuardedFileSink() catch linux.exit_group(177);
        linux.exit_group(0);
    }

    var status: u32 = 0;
    const waited = linux.waitpid(@intCast(fork_result), &status, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(waited));
    try std.testing.expectEqual(@as(u32, 0), status & 0x7f);
    try std.testing.expectEqual(@as(u32, 0), (status >> 8) & 0xff);
}

fn runGuardedFileSink() !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "root/nested");
    try temporary.dir.createDirPath(std.testing.io, "root/.stage");
    const original_cwd = try enterTemporary(temporary.dir.handle);
    defer restoreCwd(original_cwd);

    const Sink = multipart.FileSink(named_durable);
    const RealHarness = harness_module.Harness(Sink, 77);
    var harness: RealHarness = undefined;
    try harness.init();
    defer harness.abortBackend();
    var runtime_driver = RealHarness.RuntimeDriver{};
    try harness.runtimeStart(&runtime_driver, .{ .worker_index = 0, .entropy = &entropy });
    const runtime = runtime_driver.runtimePointer() orelse return error.MissingSinkRuntime;
    try allocation_guard.denyAddressSpaceGrowth();

    var lifecycle = RealHarness.LifecycleDriver{};
    var writer = RealHarness.WriteDriver{};
    var state = Sink.initial_state;
    try harness.begin(&lifecycle, runtime, &state, try Sink.Key.init("nested/guarded.bin"));
    try harness.write(&writer, runtime, &state, .{ .bytes = uploaded, .offset = 0 });
    _ = try harness.finish(&lifecycle, runtime, &state, .{ .bytes = uploaded.len });
    try harness.commit(&lifecycle, runtime, &state);
    try expectFile(temporary.dir, "root/nested/guarded.bin", uploaded);
    try harness.abort(&lifecycle, runtime, &state);
    try harness.runtimeStop(&runtime_driver);
    try harness.deinit();
}

fn exerciseSymlinkRejection(
    comptime supplied: multipart.FileSinkConfig,
    directory: std.Io.Dir,
) !void {
    const Sink = multipart.FileSink(supplied);
    const RealHarness = harness_module.Harness(Sink, 74);
    var harness: RealHarness = undefined;
    try harness.init();
    defer harness.abortBackend();
    var runtime_driver = RealHarness.RuntimeDriver{};
    try harness.runtimeStart(&runtime_driver, .{ .worker_index = 0, .entropy = &entropy });
    const runtime = runtime_driver.runtimePointer() orelse return error.MissingSinkRuntime;

    try expectRejectedParent(RealHarness, Sink, &harness, runtime, "escape/escaped.bin");
    try expectRejectedParent(RealHarness, Sink, &harness, runtime, "alias/aliased.bin");
    try harness.runtimeStop(&runtime_driver);
    if (comptime supplied.staging == .named_staging) {
        try expectDirectoryEmpty(directory, "root/.stage");
    }
    try harness.deinit();
}

fn expectRejectedParent(
    comptime RealHarness: type,
    comptime Sink: type,
    harness: *RealHarness,
    runtime: *Sink.Runtime,
    key_path: []const u8,
) !void {
    var lifecycle = RealHarness.LifecycleDriver{};
    var state = Sink.initial_state;
    try std.testing.expectError(
        error.InvalidPath,
        harness.begin(&lifecycle, runtime, &state, try Sink.Key.init(key_path)),
    );
    try harness.abort(&lifecycle, runtime, &state);
    try std.testing.expect(lifecycle.quiescent());
    try std.testing.expect(lifecycle.ownershipProven());
}

fn exercisePinnedParent(
    comptime supplied: multipart.FileSinkConfig,
    directory: std.Io.Dir,
    live_parent: []const u8,
    pinned_parent: []const u8,
) !void {
    const Sink = multipart.FileSink(supplied);
    const RealHarness = harness_module.Harness(Sink, 75);
    var harness: RealHarness = undefined;
    try harness.init();
    defer harness.abortBackend();
    var runtime_driver = RealHarness.RuntimeDriver{};
    try harness.runtimeStart(&runtime_driver, .{ .worker_index = 0, .entropy = &entropy });
    const runtime = runtime_driver.runtimePointer() orelse return error.MissingSinkRuntime;
    var key_storage: [64]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_storage, "{s}/upload.bin", .{live_parent});

    var lifecycle = RealHarness.LifecycleDriver{};
    var writer = RealHarness.WriteDriver{};
    var state = Sink.initial_state;
    try harness.begin(&lifecycle, runtime, &state, try Sink.Key.init(key));
    try harness.write(&writer, runtime, &state, .{ .bytes = uploaded, .offset = 0 });
    try replaceParentWithEscape(directory, live_parent, pinned_parent);
    _ = try harness.finish(&lifecycle, runtime, &state, .{ .bytes = uploaded.len });
    try harness.commit(&lifecycle, runtime, &state);

    var pinned_storage: [64]u8 = undefined;
    const pinned = try std.fmt.bufPrint(
        &pinned_storage,
        "root/{s}/upload.bin",
        .{pinned_parent},
    );
    try expectFile(directory, pinned, uploaded);
    try expectFileAbsent(directory, "outside/upload.bin");
    try harness.runtimeStop(&runtime_driver);
    try harness.deinit();
}

fn replaceParentWithEscape(
    directory: std.Io.Dir,
    live_parent: []const u8,
    pinned_parent: []const u8,
) !void {
    var live_storage: [64]u8 = undefined;
    const live = try std.fmt.bufPrint(&live_storage, "root/{s}", .{live_parent});
    var pinned_storage: [64]u8 = undefined;
    const pinned = try std.fmt.bufPrint(&pinned_storage, "root/{s}", .{pinned_parent});
    try directory.rename(live, directory, pinned, std.testing.io);
    try directory.symLink(std.testing.io, "../outside", live, .{ .is_directory = true });
}

fn exercise(
    comptime supplied: multipart.FileSinkConfig,
    directory: std.Io.Dir,
    key_path: []const u8,
    existing_key: []const u8,
) !void {
    const Sink = multipart.FileSink(supplied);
    const RealHarness = harness_module.Harness(Sink, 73);
    var file_path_storage: [64]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&file_path_storage, "root/{s}", .{key_path});
    var existing_path_storage: [64]u8 = undefined;
    const existing_path = try std.fmt.bufPrint(
        &existing_path_storage,
        "root/{s}",
        .{existing_key},
    );
    try directory.writeFile(std.testing.io, .{
        .sub_path = existing_path,
        .data = sentinel,
    });
    var harness: RealHarness = undefined;
    try harness.init();
    defer harness.abortBackend();

    var runtime_driver = RealHarness.RuntimeDriver{};
    try harness.runtimeStart(&runtime_driver, .{ .worker_index = 0, .entropy = &entropy });
    const runtime = runtime_driver.runtimePointer() orelse return error.MissingSinkRuntime;
    if (comptime supplied.staging == .named_staging) {
        try expectDirectoryEmpty(directory, "root/.stage");
    }

    var lifecycle = RealHarness.LifecycleDriver{};
    var writer = RealHarness.WriteDriver{};
    var state = Sink.initial_state;
    try harness.begin(&lifecycle, runtime, &state, try Sink.Key.init(key_path));
    try harness.write(&writer, runtime, &state, .{ .bytes = first_chunk, .offset = 0 });
    try harness.write(&writer, runtime, &state, .{
        .bytes = second_chunk,
        .offset = first_chunk.len,
    });
    const summary = try harness.finish(&lifecycle, runtime, &state, .{
        .bytes = uploaded.len,
    });
    try std.testing.expectEqualStrings(key_path, summary.storage_key);
    try std.testing.expectEqual(@as(u64, uploaded.len), summary.bytes);
    try std.testing.expectEqual(
        @intFromPtr(state.key.bytes().ptr),
        @intFromPtr(summary.storage_key.ptr),
    );
    try harness.commit(&lifecycle, runtime, &state);
    try expectFile(directory, file_path, uploaded);
    try expectMode(directory, file_path, supplied.mode);
    try harness.abort(&lifecycle, runtime, &state);
    try expectFileAbsent(directory, file_path);
    try std.testing.expect(lifecycle.quiescent());
    try std.testing.expect(lifecycle.ownershipProven());

    try expectNoOverwrite(
        RealHarness,
        Sink,
        &harness,
        runtime,
        directory,
        existing_key,
        existing_path,
    );
    if (comptime supplied.staging == .named_staging) {
        try expectDirectoryEmpty(directory, "root/.stage");
    }
    try harness.runtimeStop(&runtime_driver);
    if (comptime supplied.staging == .named_staging) {
        try expectDirectoryEmpty(directory, "root/.stage");
    }
    try harness.deinit();
}

fn expectNoOverwrite(
    comptime RealHarness: type,
    comptime Sink: type,
    harness: *RealHarness,
    runtime: *Sink.Runtime,
    directory: std.Io.Dir,
    existing_key: []const u8,
    existing_path: []const u8,
) !void {
    var lifecycle = RealHarness.LifecycleDriver{};
    var writer = RealHarness.WriteDriver{};
    var state = Sink.initial_state;
    try harness.begin(&lifecycle, runtime, &state, try Sink.Key.init(existing_key));
    try harness.write(&writer, runtime, &state, .{ .bytes = replacement, .offset = 0 });
    _ = try harness.finish(&lifecycle, runtime, &state, .{ .bytes = replacement.len });
    try std.testing.expectError(
        error.AlreadyExists,
        harness.commit(&lifecycle, runtime, &state),
    );
    try harness.abort(&lifecycle, runtime, &state);
    try expectFile(directory, existing_path, sentinel);
    try std.testing.expect(lifecycle.quiescent());
    try std.testing.expect(lifecycle.ownershipProven());
}

fn expectFile(directory: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    var storage: [64]u8 = undefined;
    const contents = try directory.readFile(std.testing.io, path, &storage);
    try std.testing.expectEqualStrings(expected, contents);
}

fn expectMode(directory: std.Io.Dir, path: []const u8, expected: u16) !void {
    const metadata = try directory.statFile(std.testing.io, path, .{});
    const actual = metadata.permissions.toMode() & 0o777;
    try std.testing.expectEqual(@as(std.posix.mode_t, expected), actual);
}

fn expectFileAbsent(directory: std.Io.Dir, path: []const u8) !void {
    var file = directory.openFile(std.testing.io, path, .{}) catch |problem| switch (problem) {
        error.FileNotFound => return,
        else => return problem,
    };
    defer file.close(std.testing.io);
    return error.ExpectedFileAbsent;
}

fn expectDirectoryEmpty(directory: std.Io.Dir, path: []const u8) !void {
    var target = try directory.openDir(std.testing.io, path, .{ .iterate = true });
    defer target.close(std.testing.io);
    var iterator = target.iterate();
    try std.testing.expect(try iterator.next(std.testing.io) == null);
}

fn enterTemporary(directory: linux.fd_t) !linux.fd_t {
    const opened = linux.open(".", .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.SaveCurrentDirectoryFailed;
    const original: linux.fd_t = @intCast(opened);
    if (linux.errno(linux.fchdir(directory)) != .SUCCESS) {
        _ = linux.close(original);
        return error.EnterTemporaryDirectoryFailed;
    }
    return original;
}

fn restoreCwd(original: linux.fd_t) void {
    if (linux.errno(linux.fchdir(original)) != .SUCCESS) {
        @panic("failed to restore test working directory");
    }
    if (linux.errno(linux.close(original)) != .SUCCESS) {
        @panic("failed to close saved working directory");
    }
}
