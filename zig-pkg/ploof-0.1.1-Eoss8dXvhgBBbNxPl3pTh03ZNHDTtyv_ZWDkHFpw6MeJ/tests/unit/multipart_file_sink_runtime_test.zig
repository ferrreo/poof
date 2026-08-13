const std = @import("std");

const config = @import("../../src/multipart/file_sink_config.zig");
const runtime_module = @import("../../src/internal/multipart/file_sink_runtime.zig");
const upload = @import("../../src/multipart/upload.zig");

const anonymous_buffered = config.FileSinkConfig{
    .root = "/srv/uploads",
    .durability = .buffered,
};
const anonymous_durable = config.FileSinkConfig{
    .root = "/srv/uploads",
    .durability = .crash_durable,
};
const named_buffered = config.FileSinkConfig{
    .root = "/srv/uploads",
    .durability = .buffered,
    .staging = .{ .named_staging = ".private/stage" },
};
const named_durable = config.FileSinkConfig{
    .root = "/srv/uploads",
    .durability = .crash_durable,
    .staging = .{ .named_staging = ".private/stage" },
    .mode = 0o640,
};

const root = upload.FileHandle.init(1);
const staging = upload.FileHandle.init(2);
const probe = upload.FileHandle.init(3);
const entropy = [_]u8{0x5a} ** 32;

fn requestOf(poll: anytype) upload.IoRequest {
    return switch (poll) {
        .request => |request| request,
        .done => unreachable,
    };
}

fn openSuccess(handle: upload.FileHandle) upload.IoCompletion {
    return .{ .success = .{ .open = handle } };
}

fn plainSuccess(kind: upload.IoKind) upload.IoCompletion {
    return .{ .success = switch (kind) {
        .close => .{ .close = {} },
        .link => .{ .link = {} },
        .unlink => .{ .unlink = {} },
        .rename_no_replace => .{ .rename_no_replace = {} },
        .sync => .{ .sync = {} },
        .open, .write => unreachable,
    } };
}

fn successFor(request: upload.IoRequest) upload.IoCompletion {
    return switch (request) {
        .open => |operation| openSuccess(switch (operation.base) {
            .working_directory => root,
            .handle => if (operation.kind == .directory) staging else probe,
        }),
        .write => |operation| .{
            .success = .{ .write = @intCast(operation.bytes.len) },
        },
        inline else => |_, kind| plainSuccess(kind),
    };
}

fn expectedSequence(comptime supplied: config.FileSinkConfig) []const upload.IoKind {
    const C = config.Resolved(supplied);
    if (C.named and C.durable) return &.{
        .open, .open, .open,   .write, .sync,  .rename_no_replace,
        .sync, .sync, .unlink, .sync,  .close,
    };
    if (C.named) return &.{
        .open, .open, .open, .write, .rename_no_replace, .unlink, .close,
    };
    if (C.durable) return &.{
        .open, .open, .write, .sync, .link, .sync, .unlink, .sync, .close,
    };
    return &.{ .open, .open, .write, .link, .unlink, .close };
}

fn validateRequest(
    comptime supplied: config.FileSinkConfig,
    state: *const runtime_module.Lifecycle(supplied).StartupState,
    request: upload.IoRequest,
) !void {
    const C = config.Resolved(supplied);
    try std.testing.expectEqual(@as(?upload.RequestIssue, null), request.validate());
    switch (request) {
        .open => |operation| switch (operation.base) {
            .working_directory => {
                try std.testing.expectEqualStrings(C.config.root, operation.path);
                try std.testing.expect(!operation.resolve.beneath);
                try std.testing.expect(!operation.resolve.no_mount_crossing);
                try std.testing.expect(operation.no_follow);
            },
            .handle => |base| if (operation.kind == .directory) {
                try std.testing.expect(base.eql(root));
                try std.testing.expectEqualStrings(C.staging_z.?, operation.path);
                try std.testing.expect(operation.resolve.beneath);
                try std.testing.expect(operation.resolve.no_symlinks);
                try std.testing.expect(operation.resolve.no_magic_links);
                try std.testing.expect(operation.resolve.no_mount_crossing);
            } else {
                try std.testing.expectEqual(C.config.mode, operation.mode);
                try std.testing.expectEqual(upload.Access.read_write, operation.access);
                if (C.named) {
                    try std.testing.expect(base.eql(staging));
                    try std.testing.expectEqual(upload.Create.exclusive, operation.create);
                    try std.testing.expect(operation.path.ptr == state.stage_name.sentinel().ptr);
                } else {
                    try std.testing.expect(base.eql(root));
                    try std.testing.expectEqual(upload.Create.anonymous, operation.create);
                    try std.testing.expectEqualStrings(".", operation.path);
                }
            },
        },
        .write => |operation| {
            try std.testing.expect(operation.file.eql(probe));
            try std.testing.expectEqualSlices(u8, &.{0xa5}, operation.bytes);
            try std.testing.expectEqual(@as(u64, 0), operation.offset);
        },
        .link => |operation| {
            try std.testing.expect(operation.source.eql(probe));
            try std.testing.expect(operation.target_directory.eql(root));
            try std.testing.expect(operation.target_path.ptr == state.final_name.sentinel().ptr);
        },
        .rename_no_replace => |operation| {
            try std.testing.expect(operation.source.eql(probe));
            try std.testing.expect(operation.source_directory.eql(staging));
            try std.testing.expect(operation.target_directory.eql(root));
            try std.testing.expect(operation.source_path.ptr == state.stage_name.sentinel().ptr);
            try std.testing.expect(operation.target_path.ptr == state.final_name.sentinel().ptr);
        },
        .unlink => |operation| {
            try std.testing.expect(operation.directory.eql(root));
            try std.testing.expect(operation.path.ptr == state.final_name.sentinel().ptr);
        },
        .sync, .close => {},
    }
}

fn startToSuccess(
    comptime supplied: config.FileSinkConfig,
    state: *runtime_module.Lifecycle(supplied).StartupState,
) !runtime_module.Lifecycle(supplied).Runtime {
    const Lifecycle = runtime_module.Lifecycle(supplied);
    const expected = expectedSequence(supplied);
    var poll = try Lifecycle.runtimeStart(state, .{ .start = .{
        .worker_index = 7,
        .entropy = &entropy,
    } });
    var index: usize = 0;
    while (true) switch (poll) {
        .request => |request| {
            try std.testing.expect(index < expected.len);
            try std.testing.expectEqual(expected[index], std.meta.activeTag(request));
            try validateRequest(supplied, state, request);
            index += 1;
            poll = try Lifecycle.runtimeStart(
                state,
                .{ .completion = successFor(request) },
            );
        },
        .done => |runtime| {
            try std.testing.expectEqual(expected.len, index);
            return runtime;
        },
    };
}

fn stopSuccess(
    comptime supplied: config.FileSinkConfig,
    runtime: *runtime_module.Lifecycle(supplied).Runtime,
) !void {
    const Lifecycle = runtime_module.Lifecycle(supplied);
    var poll = try Lifecycle.runtimeStop(runtime, .{ .start = {} });
    while (true) switch (poll) {
        .request => |request| poll = try Lifecycle.runtimeStop(
            runtime,
            .{ .completion = successFor(request) },
        ),
        .done => return,
    };
}

test "startup probes exact selected I/O sequence in all four modes" {
    inline for (.{
        anonymous_buffered,
        anonymous_durable,
        named_buffered,
        named_durable,
    }) |supplied| {
        const Lifecycle = runtime_module.Lifecycle(supplied);
        const C = config.Resolved(supplied);
        var state = Lifecycle.initial_startup_state;
        var runtime = try startToSuccess(supplied, &state);
        try std.testing.expect(runtime.root.eql(root));
        try std.testing.expectEqual(C.named, runtime.staging.eql(staging));
        try std.testing.expect(!state.root.valid());
        try std.testing.expect(!state.staging.valid());
        try std.testing.expect(!state.probe.valid());
        try std.testing.expect(!state.source_live);
        try std.testing.expect(!state.destination_live);
        try std.testing.expect(!state.generator_live);
        try std.testing.expect(std.mem.allEqual(u8, &state.generator.key, 0));
        try std.testing.expectEqual(runtime_module.StartupPhase.complete, state.phase);

        state = Lifecycle.initial_startup_state;
        const next_name = try runtime.generator.next(.stage);
        try std.testing.expect(std.mem.startsWith(
            u8,
            next_name.bytes(),
            config.stage_name_prefix,
        ));
        try stopSuccess(supplied, &runtime);
        try std.testing.expect(runtime.stopped);
        try std.testing.expect(std.mem.allEqual(u8, &runtime.generator.key, 0));
    }
}

fn failAt(
    comptime supplied: config.FileSinkConfig,
    comptime failure_index: usize,
) !void {
    const Lifecycle = runtime_module.Lifecycle(supplied);
    var state = Lifecycle.initial_startup_state;
    var poll = try Lifecycle.runtimeStart(&state, .{ .start = .{
        .worker_index = 11,
        .entropy = &entropy,
    } });
    var index: usize = 0;
    var caught: ?Lifecycle.Error = null;
    while (true) switch (poll) {
        .request => |request| {
            const completion: upload.IoCompletion = if (index == failure_index)
                .{ .failure = .io_failure }
            else
                successFor(request);
            index += 1;
            poll = Lifecycle.runtimeStart(
                &state,
                .{ .completion = completion },
            ) catch |problem| {
                caught = problem;
                break;
            };
        },
        .done => return error.ExpectedStartupFailure,
    };
    try std.testing.expectEqual(error.IoFailure, caught.?);
    const failure = Lifecycle.startupFailure(&state).?;
    try std.testing.expectEqualStrings(runtime_module.startup_failure_code, failure.code);
    try std.testing.expectEqualStrings(supplied.root, failure.root);
    try std.testing.expectEqual(supplied.mode, failure.mode);
    try std.testing.expectEqual(supplied.durability.?, failure.durability);
    try std.testing.expectEqual(error.IoFailure, failure.cause);
    try std.testing.expectEqual(
        expectedSequence(supplied)[failure_index],
        failure.operation,
    );
    try std.testing.expect(failure.cleanup.generator_cleared);
    inline for (.{
        failure.cleanup.destination_unlink,
        failure.cleanup.source_unlink,
        failure.cleanup.staging_sync,
        failure.cleanup.root_sync,
        failure.cleanup.probe_close,
        failure.cleanup.staging_close,
        failure.cleanup.root_close,
    }) |action| try std.testing.expect(action != .pending);
    try std.testing.expectEqual(runtime_module.StartupPhase.failed, state.phase);
    try std.testing.expect(!state.root.valid());
    try std.testing.expect(!state.staging.valid());
    try std.testing.expect(!state.probe.valid());
    try std.testing.expect(std.mem.allEqual(u8, &state.generator.key, 0));
}

test "every startup probe operation failure rolls back before returning" {
    @setEvalBranchQuota(200_000);
    inline for (.{
        anonymous_buffered,
        anonymous_durable,
        named_buffered,
        named_durable,
    }) |supplied| {
        const expected_len = comptime expectedSequence(supplied).len;
        inline for (0..expected_len) |failure_index| {
            try failAt(supplied, failure_index);
        }
    }
}

fn advanceNamedDurableToPublishedSync(
    state: *runtime_module.Lifecycle(named_durable).StartupState,
) !upload.Poll(runtime_module.Lifecycle(named_durable).Runtime) {
    const Lifecycle = runtime_module.Lifecycle(named_durable);
    var poll = try Lifecycle.runtimeStart(state, .{ .start = .{
        .worker_index = 4,
        .entropy = &entropy,
    } });
    while (true) {
        const request = requestOf(poll);
        if (state.phase == .sync_published_staging) return poll;
        poll = try Lifecycle.runtimeStart(state, .{ .completion = successFor(request) });
    }
}

test "rollback attempts every remaining cleanup after cleanup failures" {
    const Lifecycle = runtime_module.Lifecycle(named_durable);
    var state = Lifecycle.initial_startup_state;
    var poll = try advanceNamedDurableToPublishedSync(&state);
    try std.testing.expectEqual(upload.IoKind.sync, std.meta.activeTag(requestOf(poll)));
    poll = try Lifecycle.runtimeStart(&state, .{ .completion = .{ .failure = .io_failure } });

    var cleanup_kinds: [6]upload.IoKind = undefined;
    var cleanup_count: usize = 0;
    var caught: ?Lifecycle.Error = null;
    while (true) switch (poll) {
        .request => |request| {
            cleanup_kinds[cleanup_count] = std.meta.activeTag(request);
            cleanup_count += 1;
            poll = Lifecycle.runtimeStart(
                &state,
                .{ .completion = .{ .failure = .permission_denied } },
            ) catch |problem| {
                caught = problem;
                break;
            };
        },
        .done => return error.ExpectedStartupFailure,
    };
    try std.testing.expectEqual(error.IoFailure, caught.?);
    try std.testing.expectEqualSlices(upload.IoKind, &.{
        .unlink, .sync, .sync, .close, .close, .close,
    }, cleanup_kinds[0..cleanup_count]);
    const cleanup = Lifecycle.startupFailure(&state).?.cleanup;
    try std.testing.expectEqual(runtime_module.CleanupAction.failed, cleanup.destination_unlink);
    try std.testing.expectEqual(runtime_module.CleanupAction.failed, cleanup.staging_sync);
    try std.testing.expectEqual(runtime_module.CleanupAction.failed, cleanup.root_sync);
    try std.testing.expectEqual(runtime_module.CleanupAction.failed, cleanup.probe_close);
    try std.testing.expectEqual(runtime_module.CleanupAction.failed, cleanup.staging_close);
    try std.testing.expectEqual(runtime_module.CleanupAction.failed, cleanup.root_close);
}

fn startNamedDirectories(
    state: *runtime_module.Lifecycle(named_buffered).StartupState,
) !upload.Poll(runtime_module.Lifecycle(named_buffered).Runtime) {
    const Lifecycle = runtime_module.Lifecycle(named_buffered);
    var poll = try Lifecycle.runtimeStart(state, .{ .start = .{
        .worker_index = 2,
        .entropy = &entropy,
    } });
    poll = try Lifecycle.runtimeStart(state, .{ .completion = openSuccess(root) });
    return Lifecycle.runtimeStart(state, .{ .completion = openSuccess(staging) });
}

test "named stage collisions stop after eight fresh names" {
    const Lifecycle = runtime_module.Lifecycle(named_buffered);
    var state = Lifecycle.initial_startup_state;
    var poll = try startNamedDirectories(&state);
    var names: [8]config.Name = undefined;
    for (0..8) |index| {
        const operation = requestOf(poll).open;
        try std.testing.expect(operation.path.ptr == state.stage_name.sentinel().ptr);
        names[index] = state.stage_name;
        if (index > 0) try std.testing.expect(!std.mem.eql(
            u8,
            names[index - 1].bytes(),
            names[index].bytes(),
        ));
        poll = try Lifecycle.runtimeStart(
            &state,
            .{ .completion = .{ .failure = .already_exists } },
        );
    }
    try std.testing.expectEqual(upload.IoKind.close, std.meta.activeTag(requestOf(poll)));
    poll = try Lifecycle.runtimeStart(&state, .{ .completion = plainSuccess(.close) });
    try std.testing.expectEqual(upload.IoKind.close, std.meta.activeTag(requestOf(poll)));
    try std.testing.expectError(error.StagingNameExhausted, Lifecycle.runtimeStart(
        &state,
        .{ .completion = plainSuccess(.close) },
    ));
    try std.testing.expectEqual(@as(u4, 8), state.stage_attempts);
}

fn advanceNamedToPublish(
    state: *runtime_module.Lifecycle(named_buffered).StartupState,
) !upload.Poll(runtime_module.Lifecycle(named_buffered).Runtime) {
    const Lifecycle = runtime_module.Lifecycle(named_buffered);
    var poll = try startNamedDirectories(state);
    poll = try Lifecycle.runtimeStart(state, .{ .completion = openSuccess(probe) });
    return Lifecycle.runtimeStart(
        state,
        .{ .completion = .{ .success = .{ .write = 1 } } },
    );
}

test "final publication collisions stop after eight fresh no-replace names" {
    const Lifecycle = runtime_module.Lifecycle(named_buffered);
    var state = Lifecycle.initial_startup_state;
    var poll = try advanceNamedToPublish(&state);
    var names: [8]config.Name = undefined;
    for (0..8) |index| {
        const operation = requestOf(poll).rename_no_replace;
        try std.testing.expect(operation.source.eql(probe));
        try std.testing.expect(operation.source_path.ptr == state.stage_name.sentinel().ptr);
        try std.testing.expect(operation.target_path.ptr == state.final_name.sentinel().ptr);
        names[index] = state.final_name;
        if (index > 0) try std.testing.expect(!std.mem.eql(
            u8,
            names[index - 1].bytes(),
            names[index].bytes(),
        ));
        poll = try Lifecycle.runtimeStart(
            &state,
            .{ .completion = .{ .failure = .already_exists } },
        );
    }
    try std.testing.expectEqual(upload.IoKind.unlink, std.meta.activeTag(requestOf(poll)));
    poll = try Lifecycle.runtimeStart(
        &state,
        .{ .completion = .{ .failure = .not_found } },
    );
    try std.testing.expectEqual(upload.IoKind.close, std.meta.activeTag(requestOf(poll)));
    poll = try Lifecycle.runtimeStart(&state, .{ .completion = plainSuccess(.close) });
    try std.testing.expectEqual(upload.IoKind.close, std.meta.activeTag(requestOf(poll)));
    poll = try Lifecycle.runtimeStart(&state, .{ .completion = plainSuccess(.close) });
    try std.testing.expectEqual(upload.IoKind.close, std.meta.activeTag(requestOf(poll)));
    try std.testing.expectError(error.NameSequenceExhausted, Lifecycle.runtimeStart(
        &state,
        .{ .completion = plainSuccess(.close) },
    ));
    try std.testing.expectEqual(@as(u4, 8), state.final_attempts);
    try std.testing.expectEqual(
        runtime_module.CleanupAction.succeeded,
        Lifecycle.startupFailure(&state).?.cleanup.source_unlink,
    );
}

test "startup failure diagnostics retain primary cause and compatibility hint" {
    const Lifecycle = runtime_module.Lifecycle(anonymous_buffered);
    var state = Lifecycle.initial_startup_state;
    var poll = try Lifecycle.runtimeStart(&state, .{ .start = .{
        .worker_index = 0,
        .entropy = &entropy,
    } });
    poll = try Lifecycle.runtimeStart(&state, .{ .completion = openSuccess(root) });
    poll = try Lifecycle.runtimeStart(
        &state,
        .{ .completion = .{ .failure = .unsupported } },
    );
    try std.testing.expectEqual(upload.IoKind.close, std.meta.activeTag(requestOf(poll)));
    try std.testing.expectError(error.Unsupported, Lifecycle.runtimeStart(
        &state,
        .{ .completion = plainSuccess(.close) },
    ));
    const failure = Lifecycle.startupFailure(&state).?;
    try std.testing.expectEqual(runtime_module.StartupPhase.open_probe, failure.phase);
    try std.testing.expectEqual(upload.IoKind.open, failure.operation);
    try std.testing.expectEqual(error.Unsupported, failure.cause);
    try std.testing.expect(failure.anonymous_compatibility_hint);
    try std.testing.expectEqual(runtime_module.CleanupAction.succeeded, failure.cleanup.root_close);
}

test "runtime stop rejects live staging then closes staging and root in order" {
    const Lifecycle = runtime_module.Lifecycle(named_buffered);
    var state = Lifecycle.initial_startup_state;
    var runtime = try startToSuccess(named_buffered, &state);
    runtime.live_named = 1;
    try std.testing.expectError(error.LiveNamedStaging, Lifecycle.runtimeStop(
        &runtime,
        .{ .start = {} },
    ));
    try std.testing.expect(runtime.staging.eql(staging));
    runtime.live_named = 0;

    var poll = try Lifecycle.runtimeStop(&runtime, .{ .start = {} });
    try std.testing.expect(requestOf(poll).close.file.eql(staging));
    poll = try Lifecycle.runtimeStop(
        &runtime,
        .{ .completion = .{ .failure = .permission_denied } },
    );
    try std.testing.expect(requestOf(poll).close.file.eql(root));
    try std.testing.expectError(error.PermissionDenied, Lifecycle.runtimeStop(
        &runtime,
        .{ .completion = plainSuccess(.close) },
    ));
    try std.testing.expect(runtime.stopped);
    try std.testing.expect(!runtime.root.valid());
    try std.testing.expect(!runtime.staging.valid());
    try std.testing.expect(std.mem.allEqual(u8, &runtime.generator.key, 0));
    try std.testing.expectEqual(error.PermissionDenied, runtime.stop_error.?);
}

test "runtime stop rejects live anonymous staging" {
    const Lifecycle = runtime_module.Lifecycle(anonymous_buffered);
    var state = Lifecycle.initial_startup_state;
    var runtime = try startToSuccess(anonymous_buffered, &state);
    runtime.live_anonymous = 1;
    try std.testing.expectError(error.LiveAnonymousStaging, Lifecycle.runtimeStop(
        &runtime,
        .{ .start = {} },
    ));
    try std.testing.expect(runtime.root.eql(root));
    runtime.live_anonymous = 0;

    const close = requestOf(try Lifecycle.runtimeStop(&runtime, .{ .start = {} }));
    try std.testing.expect(close.close.file.eql(root));
    switch (try Lifecycle.runtimeStop(
        &runtime,
        .{ .completion = plainSuccess(.close) },
    )) {
        .done => {},
        .request => return error.ExpectedDone,
    }
    try std.testing.expect(runtime.stopped);
}
