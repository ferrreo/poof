const std = @import("std");

const config = @import("../../src/multipart/file_sink_config.zig");
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

fn expectedCommitKind(comptime supplied: config.FileSinkConfig, index: usize) ?upload.IoKind {
    const C = config.Resolved(supplied);
    if (C.durable) {
        if (index == 0) return .sync;
        if (index == 1) return if (C.named) .rename_no_replace else .link;
        if (C.named and index == 2) return .sync;
        if (index == @as(usize, if (C.named) 3 else 2)) return .sync;
        if (index == @as(usize, if (C.named) 4 else 3)) return .close;
        return null;
    }
    return switch (index) {
        0 => if (C.named) .rename_no_replace else .link,
        1 => .close,
        else => null,
    };
}

fn expectCommitRequest(
    comptime supplied: config.FileSinkConfig,
    state: *request_module.Request(supplied).State,
    request: upload.IoRequest,
    index: usize,
) !void {
    const C = config.Resolved(supplied);
    const expected = expectedCommitKind(supplied, index).?;
    try std.testing.expectEqual(expected, std.meta.activeTag(request));
    switch (request) {
        .link => |value| {
            try std.testing.expect(value.source.eql(stage));
            try std.testing.expect(value.target_directory.eql(root));
            try std.testing.expectEqualStrings("final.bin", value.target_path);
        },
        .rename_no_replace => |value| {
            try std.testing.expect(value.source.eql(stage));
            try std.testing.expect(value.source_directory.eql(staging));
            try std.testing.expect(value.target_directory.eql(root));
            try std.testing.expectEqualStrings(state.temp_name.bytes(), value.source_path);
            try std.testing.expectEqualStrings("final.bin", value.target_path);
        },
        .sync => |value| {
            const expected_handle = if (index == 0)
                stage
            else if (C.named and index == 2)
                staging
            else
                root;
            try std.testing.expect(value.file.eql(expected_handle));
        },
        .close => |value| try std.testing.expect(value.file.eql(stage)),
        else => unreachable,
    }
}

fn exerciseCommit(comptime supplied: config.FileSinkConfig) !void {
    const Sink = request_module.Request(supplied);
    const C = config.Resolved(supplied);
    var sink_runtime = runtime(supplied);
    defer sink_runtime.generator.deinit();
    var state = Sink.initial_state;
    const key = try Sink.BeginInput.init("final.bin");

    const open = requestOf(try Sink.begin(&sink_runtime, &state, .{ .start = key }));
    try std.testing.expectEqual(upload.IoKind.open, std.meta.activeTag(open));
    try std.testing.expectEqual(
        if (C.named) upload.Create.exclusive else upload.Create.anonymous,
        open.open.create,
    );
    try expectDone(try Sink.begin(
        &sink_runtime,
        &state,
        .{ .completion = openSuccess(stage) },
    ));
    try expectReport(supplied, &sink_runtime, 1);
    const summary = (try Sink.finish(
        &sink_runtime,
        &state,
        .{ .start = .{ .bytes = 0 } },
    )).done;
    try std.testing.expectEqualStrings("final.bin", summary.storage_key);
    try std.testing.expectEqual(@as(u64, 0), summary.bytes);

    var poll = try Sink.commit(&sink_runtime, &state, .{ .start = {} });
    var index: usize = 0;
    while (expectedCommitKind(supplied, index)) |kind| : (index += 1) {
        const request = requestOf(poll);
        try expectCommitRequest(supplied, &state, request, index);
        try expectReport(supplied, &sink_runtime, @intFromBool(!state.published));
        poll = try Sink.commit(
            &sink_runtime,
            &state,
            .{ .completion = plainSuccess(kind) },
        );
        try expectReport(supplied, &sink_runtime, @intFromBool(!state.published));
    }
    try expectDone(poll);
    try std.testing.expect(state.published);
    try std.testing.expect(!state.stage.valid());
    try expectReport(supplied, &sink_runtime, 0);

    var abort_poll = try Sink.abort(&sink_runtime, &state, .{ .start = {} });
    const unlink = requestOf(abort_poll).unlink;
    try std.testing.expect(unlink.directory.eql(root));
    try std.testing.expectEqualStrings("final.bin", unlink.path);
    abort_poll = try Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = plainSuccess(.unlink) },
    );
    if (C.durable) {
        try std.testing.expect(requestOf(abort_poll).sync.file.eql(root));
        abort_poll = try Sink.abort(
            &sink_runtime,
            &state,
            .{ .completion = plainSuccess(.sync) },
        );
    }
    try expectDone(abort_poll);
    try expectDone(try Sink.abort(&sink_runtime, &state, .{ .start = {} }));
    try expectReport(supplied, &sink_runtime, 0);
}

test "four FileSink modes publish without replacement then compensate" {
    try std.testing.expect(upload.requestSinkIssue(
        request_module.Request(anonymous_buffered),
    ) == null);
    try exerciseCommit(anonymous_buffered);
    try exerciseCommit(anonymous_durable);
    try exerciseCommit(named_buffered);
    try exerciseCommit(named_durable);
}

fn exerciseAbortCounters(comptime supplied: config.FileSinkConfig) !void {
    const Sink = request_module.Request(supplied);
    var sink_runtime = runtime(supplied);
    defer sink_runtime.generator.deinit();
    var state = Sink.initial_state;
    const key = try Sink.BeginInput.init("abort.bin");
    _ = requestOf(try Sink.begin(&sink_runtime, &state, .{ .start = key }));
    try expectDone(try Sink.begin(
        &sink_runtime,
        &state,
        .{ .completion = openSuccess(stage) },
    ));
    try expectReport(supplied, &sink_runtime, 1);

    var poll = try Sink.abort(&sink_runtime, &state, .{ .start = {} });
    var first = true;
    while (true) switch (poll) {
        .done => break,
        .request => |request| {
            try expectReport(supplied, &sink_runtime, @intFromBool(first));
            poll = try Sink.abort(
                &sink_runtime,
                &state,
                .{ .completion = successForRequest(request) },
            );
            first = false;
            try expectReport(supplied, &sink_runtime, 0);
        },
    };
    try expectReport(supplied, &sink_runtime, 0);
}

test "abort reports exact staging cleanup in all four modes" {
    inline for (.{
        anonymous_buffered,
        anonymous_durable,
        named_buffered,
        named_durable,
    }) |supplied| try exerciseAbortCounters(supplied);
}

test "nested begin confines parent and keeps request paths stable" {
    const Sink = request_module.Request(named_durable);
    var sink_runtime = runtime(named_durable);
    defer sink_runtime.generator.deinit();
    var state = Sink.initial_state;
    const key = try Sink.BeginInput.init("users/alice/file.bin");

    const parent_request = requestOf(try Sink.begin(
        &sink_runtime,
        &state,
        .{ .start = key },
    )).open;
    try std.testing.expect(parent_request.base.handle.eql(root));
    try std.testing.expectEqualStrings("users/alice", parent_request.path);
    try std.testing.expect(parent_request.resolve.beneath);
    try std.testing.expect(parent_request.resolve.no_symlinks);
    try std.testing.expect(parent_request.resolve.no_magic_links);
    try std.testing.expect(parent_request.resolve.no_mount_crossing);
    try std.testing.expectEqual(@as(u8, 0), parent_request.path[parent_request.path.len]);

    const stage_request = requestOf(try Sink.begin(
        &sink_runtime,
        &state,
        .{ .completion = openSuccess(parent) },
    )).open;
    try std.testing.expectEqualStrings("users/alice/file.bin", state.key.bytes());
    try std.testing.expect(stage_request.base.handle.eql(staging));
    try std.testing.expectEqual(upload.Create.exclusive, stage_request.create);
    try std.testing.expect(std.mem.startsWith(u8, stage_request.path, config.stage_name_prefix));
    try expectDone(try Sink.begin(
        &sink_runtime,
        &state,
        .{ .completion = openSuccess(stage) },
    ));

    var poll = try Sink.abort(&sink_runtime, &state, .{ .start = {} });
    const unlink = requestOf(poll).unlink;
    try std.testing.expect(unlink.directory.eql(staging));
    try std.testing.expectEqualStrings(state.temp_name.bytes(), unlink.path);
    poll = try Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = .{ .failure = .not_found } },
    );
    try std.testing.expect(requestOf(poll).sync.file.eql(staging));
    poll = try Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = plainSuccess(.sync) },
    );
    try std.testing.expect(requestOf(poll).close.file.eql(stage));
    poll = try Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = plainSuccess(.close) },
    );
    try std.testing.expect(requestOf(poll).close.file.eql(parent));
    try expectDone(try Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = plainSuccess(.close) },
    ));
    try std.testing.expectEqual(@as(u32, 0), sink_runtime.live_named);
}

test "committed nested destination reopens securely for compensation" {
    const Sink = request_module.Request(named_durable);
    var sink_runtime = runtime(named_durable);
    defer sink_runtime.generator.deinit();
    var state = Sink.initial_state;
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
    try finishEmpty(named_durable, &sink_runtime, &state);
    var commit_poll = try Sink.commit(&sink_runtime, &state, .{ .start = {} });
    while (true) switch (commit_poll) {
        .done => break,
        .request => |request| {
            commit_poll = try Sink.commit(
                &sink_runtime,
                &state,
                .{ .completion = successForRequest(request) },
            );
        },
    };
    try std.testing.expect(!state.parent.valid());

    var abort_poll = try Sink.abort(&sink_runtime, &state, .{ .start = {} });
    const reopen = requestOf(abort_poll).open;
    try std.testing.expect(reopen.base.handle.eql(root));
    try std.testing.expectEqualStrings("nested", reopen.path);
    try std.testing.expect(reopen.resolve.beneath and reopen.resolve.no_symlinks);
    const reopened = upload.FileHandle.init(5);
    abort_poll = try Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = openSuccess(reopened) },
    );
    try std.testing.expectEqualStrings("nested/final.bin", state.key.bytes());
    const unlink = requestOf(abort_poll).unlink;
    try std.testing.expect(unlink.directory.eql(reopened));
    try std.testing.expectEqualStrings("final.bin", unlink.path);
    try drainAbortFromPoll(named_durable, &sink_runtime, &state, abort_poll);
    try std.testing.expect(!state.parent.valid());
}

fn drainAbortFromPoll(
    comptime supplied: config.FileSinkConfig,
    sink_runtime: *request_module.Request(supplied).Runtime,
    state: *request_module.Request(supplied).State,
    initial: upload.Poll(void),
) !void {
    const Sink = request_module.Request(supplied);
    var poll = initial;
    while (true) switch (poll) {
        .done => return,
        .request => |request| poll = try Sink.abort(
            sink_runtime,
            state,
            .{ .completion = successForRequest(request) },
        ),
    };
}

test "write preserves exact bytes and offset and finish borrows canonical key" {
    const Sink = request_module.Request(anonymous_buffered);
    var sink_runtime = runtime(anonymous_buffered);
    defer sink_runtime.generator.deinit();
    var state = Sink.initial_state;
    var write_state = Sink.initial_write_state;
    const key = try Sink.BeginInput.init("empty-or-data.bin");
    _ = requestOf(try Sink.begin(&sink_runtime, &state, .{ .start = key }));
    try expectDone(try Sink.begin(
        &sink_runtime,
        &state,
        .{ .completion = openSuccess(stage) },
    ));

    const bytes = "abc";
    const write_request = requestOf(try Sink.write(
        &sink_runtime,
        &state,
        &write_state,
        .{ .start = .{ .bytes = bytes, .offset = 42 } },
    )).write;
    try std.testing.expect(write_request.file.eql(stage));
    try std.testing.expectEqualStrings(bytes, write_request.bytes);
    try std.testing.expectEqual(@as(u64, 42), write_request.offset);
    try expectDone(try Sink.write(
        &sink_runtime,
        &state,
        &write_state,
        .{ .completion = .{ .success = .{ .write = 3 } } },
    ));

    const summary = (try Sink.finish(
        &sink_runtime,
        &state,
        .{ .start = .{ .bytes = 3 } },
    )).done;
    try std.testing.expectEqualStrings("empty-or-data.bin", summary.storage_key);
    try std.testing.expectEqual(
        @intFromPtr(state.key.bytes().ptr),
        @intFromPtr(summary.storage_key.ptr),
    );
    try std.testing.expectEqual(@as(u64, 3), summary.bytes);
}

test "write maps every normalized failure and rejects wrong aggregate length" {
    const Sink = request_module.Request(anonymous_buffered);
    var sink_runtime = runtime(anonymous_buffered);
    defer sink_runtime.generator.deinit();
    var state = Sink.initial_state;
    const key = try Sink.BeginInput.init("data.bin");
    _ = requestOf(try Sink.begin(&sink_runtime, &state, .{ .start = key }));
    try expectDone(try Sink.begin(
        &sink_runtime,
        &state,
        .{ .completion = openSuccess(stage) },
    ));

    for (std.enums.values(upload.IoError)) |failure| {
        var write_state = Sink.initial_write_state;
        _ = requestOf(try Sink.write(
            &sink_runtime,
            &state,
            &write_state,
            .{ .start = .{ .bytes = "x", .offset = 0 } },
        ));
        try std.testing.expectError(
            config.mapIoError(failure),
            Sink.write(
                &sink_runtime,
                &state,
                &write_state,
                .{ .completion = .{ .failure = failure } },
            ),
        );
    }
    var write_state = Sink.initial_write_state;
    _ = requestOf(try Sink.write(
        &sink_runtime,
        &state,
        &write_state,
        .{ .start = .{ .bytes = "xy", .offset = 0 } },
    ));
    try std.testing.expectError(error.ByteCountMismatch, Sink.write(
        &sink_runtime,
        &state,
        &write_state,
        .{ .completion = .{ .success = .{ .write = 1 } } },
    ));
}

test "named staging retries exactly eight collisions and abort closes nested parent" {
    const Sink = request_module.Request(named_buffered);
    var sink_runtime = runtime(named_buffered);
    defer sink_runtime.generator.deinit();
    var state = Sink.initial_state;
    const key = try Sink.BeginInput.init("nested/file.bin");
    _ = requestOf(try Sink.begin(&sink_runtime, &state, .{ .start = key }));
    var poll = try Sink.begin(
        &sink_runtime,
        &state,
        .{ .completion = openSuccess(parent) },
    );
    var previous: [config.name_bytes_max]u8 = undefined;
    var previous_length: usize = 0;
    for (0..8) |attempt| {
        const open = requestOf(poll).open;
        try std.testing.expect(std.mem.startsWith(u8, open.path, config.stage_name_prefix));
        if (attempt != 0) {
            try std.testing.expect(!std.mem.eql(u8, previous[0..previous_length], open.path));
        }
        @memcpy(previous[0..open.path.len], open.path);
        previous_length = open.path.len;
        if (attempt == 7) {
            try std.testing.expectError(error.StagingNameExhausted, Sink.begin(
                &sink_runtime,
                &state,
                .{ .completion = .{ .failure = .already_exists } },
            ));
        } else {
            poll = try Sink.begin(
                &sink_runtime,
                &state,
                .{ .completion = .{ .failure = .already_exists } },
            );
        }
    }
    const close = requestOf(try Sink.abort(
        &sink_runtime,
        &state,
        .{ .start = {} },
    )).close;
    try std.testing.expect(close.file.eql(parent));
    try expectDone(try Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = plainSuccess(.close) },
    ));
}

test "named staging propagates generator sequence exhaustion" {
    const Sink = request_module.Request(named_buffered);
    var sink_runtime = runtime(named_buffered);
    defer sink_runtime.generator.deinit();
    sink_runtime.generator.counter = std.math.maxInt(u64);
    var state = Sink.initial_state;
    const key = try Sink.BeginInput.init("file.bin");
    try std.testing.expectError(error.NameSequenceExhausted, Sink.begin(
        &sink_runtime,
        &state,
        .{ .start = key },
    ));
    try drainAbortSuccess(named_buffered, &sink_runtime, &state);
}

test "nested stage-open failure restores key and abort closes parent" {
    const Sink = request_module.Request(anonymous_buffered);
    var sink_runtime = runtime(anonymous_buffered);
    defer sink_runtime.generator.deinit();
    var state = Sink.initial_state;
    const key = try Sink.BeginInput.init("nested/file.bin");
    _ = requestOf(try Sink.begin(&sink_runtime, &state, .{ .start = key }));
    _ = requestOf(try Sink.begin(
        &sink_runtime,
        &state,
        .{ .completion = openSuccess(parent) },
    ));
    try std.testing.expectError(error.NoSpace, Sink.begin(
        &sink_runtime,
        &state,
        .{ .completion = .{ .failure = .no_space } },
    ));
    try std.testing.expectEqualStrings("nested/file.bin", state.key.bytes());
    try std.testing.expect(requestOf(try Sink.abort(
        &sink_runtime,
        &state,
        .{ .start = {} },
    )).close.file.eql(parent));
    try expectDone(try Sink.abort(
        &sink_runtime,
        &state,
        .{ .completion = plainSuccess(.close) },
    ));
    try std.testing.expect(!state.parent.valid());
}

test "public StorageKey is revalidated before any request" {
    const Sink = request_module.Request(anonymous_buffered);
    var sink_runtime = runtime(anonymous_buffered);
    defer sink_runtime.generator.deinit();
    var state = Sink.initial_state;
    var key = try Sink.BeginInput.init("safe.bin");
    key.storage[0] = '/';
    try std.testing.expectError(error.AbsolutePath, Sink.begin(
        &sink_runtime,
        &state,
        .{ .start = key },
    ));
    try expectDone(try Sink.abort(&sink_runtime, &state, .{ .start = {} }));
}

test {
    std.testing.refAllDecls(@This());
}
