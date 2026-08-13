const std = @import("std");

const config = @import("../../src/multipart/file_sink_config.zig");
const file_sink = @import("../../src/multipart/file_sink.zig");
const request_module = @import("../../src/internal/multipart/file_sink_request.zig");
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
    .staging = .{ .named_staging = ".stage" },
};
const named_durable = config.FileSinkConfig{
    .root = "/srv/uploads",
    .durability = .crash_durable,
    .staging = .{ .named_staging = ".stage" },
};

const root = upload.FileHandle.init(1);
const staging = upload.FileHandle.init(2);
const parent = upload.FileHandle.init(3);
const stage = upload.FileHandle.init(4);

fn runtime(comptime supplied: config.FileSinkConfig) request_module.Request(supplied).Runtime {
    const C = config.Resolved(supplied);
    return .{
        .root = root,
        .staging = if (C.named) staging else .{ .token = 0 },
        .generator = C.NameGenerator.init(&([_]u8{0x5a} ** 32), 7),
    };
}

fn expectReport(
    comptime supplied: config.FileSinkConfig,
    sink_runtime: *const request_module.Request(supplied).Runtime,
    expected_live: u32,
) !void {
    const C = config.Resolved(supplied);
    const report = request_module.Request(supplied).report(sink_runtime);
    try std.testing.expectEqual(C.startup_report.staging, report.staging);
    try std.testing.expectEqual(C.startup_report.durability, report.durability);
    try std.testing.expectEqual(
        if (C.named) @as(u32, 0) else expected_live,
        report.live_anonymous,
    );
    try std.testing.expectEqual(
        if (C.named) expected_live else @as(u32, 0),
        report.live_named,
    );
}

fn requestOf(poll: anytype) upload.IoRequest {
    return switch (poll) {
        .request => |request| request,
        .done => unreachable,
    };
}

fn expectDone(poll: anytype) !void {
    switch (poll) {
        .done => {},
        .request => return error.ExpectedDone,
    }
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

fn successForRequest(request: upload.IoRequest) upload.IoCompletion {
    return switch (request) {
        .open => openSuccess(parent),
        .write => |value| .{ .success = .{ .write = @intCast(value.bytes.len) } },
        inline else => |_, kind| plainSuccess(kind),
    };
}

fn drainAbortSuccess(
    comptime supplied: config.FileSinkConfig,
    sink_runtime: *request_module.Request(supplied).Runtime,
    state: *request_module.Request(supplied).State,
) !void {
    const Sink = request_module.Request(supplied);
    var poll = try Sink.abort(sink_runtime, state, .{ .start = {} });
    while (true) switch (poll) {
        .done => return,
        .request => |request| {
            poll = try Sink.abort(
                sink_runtime,
                state,
                .{ .completion = successForRequest(request) },
            );
        },
    };
}

fn beginFlat(
    comptime supplied: config.FileSinkConfig,
    sink_runtime: *request_module.Request(supplied).Runtime,
    state: *request_module.Request(supplied).State,
) !void {
    const Sink = request_module.Request(supplied);
    const key = try Sink.BeginInput.init("final.bin");
    _ = requestOf(try Sink.begin(sink_runtime, state, .{ .start = key }));
    try expectDone(try Sink.begin(
        sink_runtime,
        state,
        .{ .completion = openSuccess(stage) },
    ));
}

fn finishEmpty(
    comptime supplied: config.FileSinkConfig,
    sink_runtime: *request_module.Request(supplied).Runtime,
    state: *request_module.Request(supplied).State,
) !void {
    const Sink = request_module.Request(supplied);
    _ = (try Sink.finish(
        sink_runtime,
        state,
        .{ .start = .{ .bytes = 0 } },
    )).done;
}

fn commitNestedAnonymousDurable(
    sink_runtime: *request_module.Request(anonymous_durable).Runtime,
    state: *request_module.Request(anonymous_durable).State,
) !void {
    const Sink = request_module.Request(anonymous_durable);
    const key = try Sink.BeginInput.init("nested/final.bin");
    _ = requestOf(try Sink.begin(sink_runtime, state, .{ .start = key }));
    _ = requestOf(try Sink.begin(
        sink_runtime,
        state,
        .{ .completion = openSuccess(parent) },
    ));
    try expectDone(try Sink.begin(
        sink_runtime,
        state,
        .{ .completion = openSuccess(stage) },
    ));
    try finishEmpty(anonymous_durable, sink_runtime, state);
    var poll = try Sink.commit(sink_runtime, state, .{ .start = {} });
    while (true) switch (poll) {
        .done => return,
        .request => |request| poll = try Sink.commit(
            sink_runtime,
            state,
            .{ .completion = successForRequest(request) },
        ),
    };
}

fn expectSecureNestedOpen(request: upload.IoRequest) !void {
    try std.testing.expectEqual(upload.IoKind.open, std.meta.activeTag(request));
    const open = request.open;
    try std.testing.expect(open.base.handle.eql(root));
    try std.testing.expectEqualStrings("nested", open.path);
    try std.testing.expect(open.access == .read_only and open.kind == .directory);
    try std.testing.expect(open.no_follow and open.resolve.beneath);
    try std.testing.expect(open.resolve.no_symlinks);
    try std.testing.expect(open.resolve.no_magic_links);
    try std.testing.expect(open.resolve.no_mount_crossing);
}

fn failFirstCompensationParentSync(
    sink_runtime: *request_module.Request(anonymous_durable).Runtime,
    state: *request_module.Request(anonymous_durable).State,
) !void {
    const Sink = request_module.Request(anonymous_durable);
    var poll = try Sink.abort(sink_runtime, state, .{ .start = {} });
    try expectSecureNestedOpen(requestOf(poll));
    poll = try Sink.abort(
        sink_runtime,
        state,
        .{ .completion = openSuccess(upload.FileHandle.init(5)) },
    );
    try std.testing.expectEqualStrings("nested/final.bin", state.key.bytes());
    try std.testing.expectEqual(upload.IoKind.unlink, std.meta.activeTag(requestOf(poll)));
    poll = try Sink.abort(
        sink_runtime,
        state,
        .{ .completion = plainSuccess(.unlink) },
    );
    try std.testing.expectEqual(upload.IoKind.sync, std.meta.activeTag(requestOf(poll)));
    poll = try Sink.abort(
        sink_runtime,
        state,
        .{ .completion = .{ .failure = .io_failure } },
    );
    try std.testing.expectEqual(upload.IoKind.close, std.meta.activeTag(requestOf(poll)));
    try std.testing.expectError(error.IoFailure, Sink.abort(
        sink_runtime,
        state,
        .{ .completion = plainSuccess(.close) },
    ));
}

test "durable nested abort retries parent sync after unlink and close" {
    const Sink = request_module.Request(anonymous_durable);
    var sink_runtime = runtime(anonymous_durable);
    defer sink_runtime.generator.deinit();
    var state = Sink.initial_state;
    try commitNestedAnonymousDurable(&sink_runtime, &state);
    try failFirstCompensationParentSync(&sink_runtime, &state);
    try std.testing.expect(!state.published and state.parent_sync_pending);
    try std.testing.expect(!state.parent.valid() and !state.parent_owned);

    var poll = try Sink.abort(&sink_runtime, &state, .{ .start = {} });
    try expectSecureNestedOpen(requestOf(poll));
    poll = try Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = openSuccess(upload.FileHandle.init(6)) },
    );
    try std.testing.expectEqualStrings("nested/final.bin", state.key.bytes());
    try std.testing.expectEqual(upload.IoKind.sync, std.meta.activeTag(requestOf(poll)));
    poll = try Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = plainSuccess(.sync) },
    );
    try std.testing.expectEqual(upload.IoKind.close, std.meta.activeTag(requestOf(poll)));
    try expectDone(try Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = plainSuccess(.close) },
    ));
    try std.testing.expect(!state.parent_sync_pending and !state.parent.valid());
    try std.testing.expect(!state.parent_owned and !state.stage.valid());
    try expectDone(try Sink.abort(&sink_runtime, &state, .{ .start = {} }));
}

fn exerciseBeginFailures(
    comptime supplied: config.FileSinkConfig,
    comptime nested: bool,
    comptime fail_parent: bool,
) !void {
    @setEvalBranchQuota(100_000);
    const Sink = request_module.Request(supplied);
    const C = config.Resolved(supplied);
    inline for (std.enums.values(upload.IoError)) |failure| {
        if (C.named and !fail_parent and failure == .already_exists) continue;
        var sink_runtime = runtime(supplied);
        defer sink_runtime.generator.deinit();
        var state = Sink.initial_state;
        const key = try Sink.BeginInput.init(if (nested) "nested/file.bin" else "file.bin");
        _ = requestOf(try Sink.begin(&sink_runtime, &state, .{ .start = key }));
        if (nested and !fail_parent) {
            _ = requestOf(try Sink.begin(
                &sink_runtime,
                &state,
                .{ .completion = openSuccess(parent) },
            ));
        }
        try std.testing.expectError(config.mapIoError(failure), Sink.begin(
            &sink_runtime,
            &state,
            .{ .completion = .{ .failure = failure } },
        ));
        try drainAbortSuccess(supplied, &sink_runtime, &state);
        try std.testing.expect(!state.parent_owned);
        try std.testing.expectEqual(@as(u32, 0), sink_runtime.live_named);
    }
}

test "all begin I/O errors quiesce across paths and four modes" {
    inline for (.{
        anonymous_buffered,
        anonymous_durable,
        named_buffered,
        named_durable,
    }) |supplied| {
        try exerciseBeginFailures(supplied, false, false);
        try exerciseBeginFailures(supplied, true, true);
        try exerciseBeginFailures(supplied, true, false);
    }
}

test "publication failure never unlinks destination during abort" {
    inline for (.{ anonymous_buffered, named_buffered }) |supplied| {
        const Sink = request_module.Request(supplied);
        var sink_runtime = runtime(supplied);
        defer sink_runtime.generator.deinit();
        var state = Sink.initial_state;
        const key = try Sink.BeginInput.init("existing.bin");
        _ = requestOf(try Sink.begin(&sink_runtime, &state, .{ .start = key }));
        try expectDone(try Sink.begin(
            &sink_runtime,
            &state,
            .{ .completion = openSuccess(stage) },
        ));
        _ = (try Sink.finish(
            &sink_runtime,
            &state,
            .{ .start = .{ .bytes = 0 } },
        )).done;
        _ = requestOf(try Sink.commit(&sink_runtime, &state, .{ .start = {} }));
        try std.testing.expectError(error.AlreadyExists, Sink.commit(
            &sink_runtime,
            &state,
            .{ .completion = .{ .failure = .already_exists } },
        ));
        try std.testing.expect(!state.published);
        const first_cleanup = requestOf(try Sink.abort(
            &sink_runtime,
            &state,
            .{ .start = {} },
        ));
        try std.testing.expectEqual(
            if (config.Resolved(supplied).named) upload.IoKind.unlink else upload.IoKind.close,
            std.meta.activeTag(first_cleanup),
        );
    }
}

fn exercisePublicationFailures(comptime supplied: config.FileSinkConfig) !void {
    @setEvalBranchQuota(100_000);
    const Sink = request_module.Request(supplied);
    const C = config.Resolved(supplied);
    inline for (std.enums.values(upload.IoError)) |failure| {
        var sink_runtime = runtime(supplied);
        defer sink_runtime.generator.deinit();
        var state = Sink.initial_state;
        try beginFlat(supplied, &sink_runtime, &state);
        try expectReport(supplied, &sink_runtime, 1);
        try finishEmpty(supplied, &sink_runtime, &state);
        var publish = try Sink.commit(&sink_runtime, &state, .{ .start = {} });
        if (C.durable) publish = try Sink.commit(
            &sink_runtime,
            &state,
            .{ .completion = plainSuccess(.sync) },
        );
        try std.testing.expectEqual(
            if (C.named) upload.IoKind.rename_no_replace else upload.IoKind.link,
            std.meta.activeTag(requestOf(publish)),
        );
        try std.testing.expectError(config.mapIoError(failure), Sink.commit(
            &sink_runtime,
            &state,
            .{ .completion = .{ .failure = failure } },
        ));
        try std.testing.expect(!state.published);
        try expectReport(supplied, &sink_runtime, 1);
        try drainAbortSuccess(supplied, &sink_runtime, &state);
        try std.testing.expect(!state.stage.valid());
        try expectReport(supplied, &sink_runtime, 0);
    }
}

test "all publication I/O errors compensate across four modes" {
    inline for (.{
        anonymous_buffered,
        anonymous_durable,
        named_buffered,
        named_durable,
    }) |supplied| {
        try exercisePublicationFailures(supplied);
    }
}

fn exerciseCleanupCounterFailure(comptime supplied: config.FileSinkConfig) !void {
    const Sink = request_module.Request(supplied);
    const C = config.Resolved(supplied);
    var sink_runtime = runtime(supplied);
    defer sink_runtime.generator.deinit();
    var state = Sink.initial_state;
    try beginFlat(supplied, &sink_runtime, &state);
    try expectReport(supplied, &sink_runtime, 1);

    var poll = try Sink.abort(&sink_runtime, &state, .{ .start = {} });
    try std.testing.expectEqual(
        if (C.named) upload.IoKind.unlink else upload.IoKind.close,
        std.meta.activeTag(requestOf(poll)),
    );
    const failed = Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = .{ .failure = .permission_denied } },
    );
    if (C.named) {
        poll = try failed;
        try std.testing.expectEqual(upload.IoKind.close, std.meta.activeTag(requestOf(poll)));
        try std.testing.expectError(error.PermissionDenied, Sink.abort(
            &sink_runtime,
            &state,
            .{ .completion = plainSuccess(.close) },
        ));
    } else {
        try std.testing.expectError(error.PermissionDenied, failed);
    }
    try expectReport(supplied, &sink_runtime, 1);

    try drainAbortSuccess(supplied, &sink_runtime, &state);
    try expectReport(supplied, &sink_runtime, 0);
}

test "failed cleanup retains then retry clears counters in all four modes" {
    inline for (.{
        anonymous_buffered,
        anonymous_durable,
        named_buffered,
        named_durable,
    }) |supplied| try exerciseCleanupCounterFailure(supplied);
}

fn exerciseInitialSyncFailures(comptime supplied: config.FileSinkConfig) !void {
    @setEvalBranchQuota(100_000);
    const Sink = request_module.Request(supplied);
    inline for (std.enums.values(upload.IoError)) |failure| {
        var sink_runtime = runtime(supplied);
        defer sink_runtime.generator.deinit();
        var state = Sink.initial_state;
        try beginFlat(supplied, &sink_runtime, &state);
        try finishEmpty(supplied, &sink_runtime, &state);
        try std.testing.expectEqual(
            upload.IoKind.sync,
            std.meta.activeTag(requestOf(try Sink.commit(
                &sink_runtime,
                &state,
                .{ .start = {} },
            ))),
        );
        try std.testing.expectError(config.mapIoError(failure), Sink.commit(
            &sink_runtime,
            &state,
            .{ .completion = .{ .failure = failure } },
        ));
        try drainAbortSuccess(supplied, &sink_runtime, &state);
    }
}

test "all durable file-sync I/O errors compensate" {
    try exerciseInitialSyncFailures(anonymous_durable);
    try exerciseInitialSyncFailures(named_durable);
}

fn exerciseCommitCloseFailures(
    comptime supplied: config.FileSinkConfig,
    comptime nested: bool,
) !void {
    @setEvalBranchQuota(100_000);
    const Sink = request_module.Request(supplied);
    inline for (std.enums.values(upload.IoError)) |failure| {
        var sink_runtime = runtime(supplied);
        defer sink_runtime.generator.deinit();
        var state = Sink.initial_state;
        if (nested) {
            const key = try Sink.BeginInput.init("nested/final.bin");
            _ = requestOf(try Sink.begin(&sink_runtime, &state, .{ .start = key }));
            _ = requestOf(try Sink.begin(
                &sink_runtime,
                &state,
                .{ .completion = openSuccess(parent) },
            ));
            try expectDone(try Sink.begin(
                &sink_runtime,
                &state,
                .{ .completion = openSuccess(stage) },
            ));
        } else try beginFlat(supplied, &sink_runtime, &state);
        try finishEmpty(supplied, &sink_runtime, &state);
        var poll = try Sink.commit(&sink_runtime, &state, .{ .start = {} });
        while (std.meta.activeTag(requestOf(poll)) != .close) {
            const request = requestOf(poll);
            poll = try Sink.commit(
                &sink_runtime,
                &state,
                .{ .completion = successForRequest(request) },
            );
        }
        if (nested) poll = try Sink.commit(
            &sink_runtime,
            &state,
            .{ .completion = plainSuccess(.close) },
        );
        try std.testing.expectEqual(upload.IoKind.close, std.meta.activeTag(requestOf(poll)));
        try std.testing.expectError(config.mapIoError(failure), Sink.commit(
            &sink_runtime,
            &state,
            .{ .completion = .{ .failure = failure } },
        ));
        try drainAbortSuccess(supplied, &sink_runtime, &state);
        try std.testing.expect(!state.stage.valid() and !state.parent_owned);
    }
}

test "all close I/O errors compensate request handles" {
    inline for (.{
        anonymous_buffered,
        anonymous_durable,
        named_buffered,
        named_durable,
    }) |supplied| {
        try exerciseCommitCloseFailures(supplied, false);
    }
    try exerciseCommitCloseFailures(named_durable, true);
}

test "cleanup keeps first failure, continues, and can retry" {
    const Sink = request_module.Request(named_durable);
    var sink_runtime = runtime(named_durable);
    defer sink_runtime.generator.deinit();
    var state = Sink.initial_state;
    const key = try Sink.BeginInput.init("nested/file.bin");
    _ = requestOf(try Sink.begin(&sink_runtime, &state, .{ .start = key }));
    _ = requestOf(try Sink.begin(
        &sink_runtime,
        &state,
        .{ .completion = openSuccess(parent) },
    ));
    try expectDone(try Sink.begin(
        &sink_runtime,
        &state,
        .{ .completion = openSuccess(stage) },
    ));

    _ = requestOf(try Sink.abort(&sink_runtime, &state, .{ .start = {} })).unlink;
    var poll = try Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = .{ .failure = .permission_denied } },
    );
    try std.testing.expect(requestOf(poll).close.file.eql(stage));
    poll = try Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = plainSuccess(.close) },
    );
    try std.testing.expect(requestOf(poll).close.file.eql(parent));
    try std.testing.expectError(error.PermissionDenied, Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = plainSuccess(.close) },
    ));
    try std.testing.expectEqual(@as(u32, 1), sink_runtime.live_named);

    const retry_unlink = requestOf(try Sink.abort(
        &sink_runtime,
        &state,
        .{ .start = {} },
    )).unlink;
    try std.testing.expect(retry_unlink.directory.eql(staging));
    poll = try Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = .{ .failure = .not_found } },
    );
    try std.testing.expect(requestOf(poll).sync.file.eql(staging));
    try expectDone(try Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = plainSuccess(.sync) },
    ));
    try std.testing.expectEqual(@as(u32, 0), sink_runtime.live_named);
}

test "named cleanup classifies every unlink failure and remains retryable" {
    const Sink = request_module.Request(named_buffered);
    inline for (std.enums.values(upload.IoError)) |failure| {
        var sink_runtime = runtime(named_buffered);
        defer sink_runtime.generator.deinit();
        var state = Sink.initial_state;
        try beginFlat(named_buffered, &sink_runtime, &state);
        _ = requestOf(try Sink.abort(
            &sink_runtime,
            &state,
            .{ .start = {} },
        )).unlink;
        var poll = try Sink.abort(
            &sink_runtime,
            &state,
            .{ .completion = .{ .failure = failure } },
        );
        try std.testing.expect(requestOf(poll).close.file.eql(stage));
        const completion = Sink.abort(
            &sink_runtime,
            &state,
            .{ .completion = plainSuccess(.close) },
        );
        if (failure == .not_found) {
            try expectDone(try completion);
            try std.testing.expectEqual(@as(u32, 0), sink_runtime.live_named);
        } else {
            try std.testing.expectError(config.mapIoError(failure), completion);
            try std.testing.expectEqual(@as(u32, 1), sink_runtime.live_named);
            poll = try Sink.abort(&sink_runtime, &state, .{ .start = {} });
            try std.testing.expectEqual(upload.IoKind.unlink, std.meta.activeTag(requestOf(poll)));
            poll = try Sink.abort(
                &sink_runtime,
                &state,
                .{ .completion = .{ .failure = .not_found } },
            );
            try expectDone(poll);
            try std.testing.expectEqual(@as(u32, 0), sink_runtime.live_named);
        }
    }
}

test "anonymous abort close retries cancellation before runtime stop" {
    const Sink = file_sink.FileSink(anonymous_buffered);
    var sink_runtime = runtime(anonymous_buffered);
    var state = Sink.initial_state;
    try beginFlat(anonymous_buffered, &sink_runtime, &state);

    var poll = try Sink.abort(&sink_runtime, &state, .{ .start = {} });
    try std.testing.expect(requestOf(poll).close.file.eql(stage));
    inline for (0..2) |_| {
        poll = try Sink.abort(
            &sink_runtime,
            &state,
            .{ .completion = .{ .failure = .canceled } },
        );
        try std.testing.expect(requestOf(poll).close.file.eql(stage));
        try std.testing.expectEqual(@as(u32, 1), Sink.report(&sink_runtime).live_anonymous);
    }
    try std.testing.expectError(error.Canceled, Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = plainSuccess(.close) },
    ));
    try std.testing.expectEqual(@as(u32, 0), Sink.report(&sink_runtime).live_anonymous);

    const stop = requestOf(try Sink.runtimeStop(&sink_runtime, .{ .start = {} }));
    try std.testing.expect(stop.close.file.eql(root));
    try expectDone(try Sink.runtimeStop(
        &sink_runtime,
        .{ .completion = plainSuccess(.close) },
    ));
}

test "anonymous abort close cancellation bound is framework fatal" {
    const Sink = file_sink.FileSink(anonymous_buffered);
    var sink_runtime = runtime(anonymous_buffered);
    var state = Sink.initial_state;
    try beginFlat(anonymous_buffered, &sink_runtime, &state);

    var poll = try Sink.abort(&sink_runtime, &state, .{ .start = {} });
    try std.testing.expect(requestOf(poll).close.file.eql(stage));
    inline for (0..7) |_| {
        poll = try Sink.abort(
            &sink_runtime,
            &state,
            .{ .completion = .{ .failure = .canceled } },
        );
        try std.testing.expect(requestOf(poll).close.file.eql(stage));
    }
    try std.testing.expectError(error.CloseCancellationExhausted, Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = .{ .failure = .canceled } },
    ));
    try std.testing.expectEqual(
        Sink.LifecycleFailureSource.invalid_request,
        Sink.lifecycleStateFailureSource(&state),
    );
    try std.testing.expectEqual(@as(u32, 1), Sink.report(&sink_runtime).live_anonymous);
    try std.testing.expectError(
        error.CloseCancellationExhausted,
        Sink.abort(&sink_runtime, &state, .{ .start = {} }),
    );
}

test {
    std.testing.refAllDecls(@This());
}
