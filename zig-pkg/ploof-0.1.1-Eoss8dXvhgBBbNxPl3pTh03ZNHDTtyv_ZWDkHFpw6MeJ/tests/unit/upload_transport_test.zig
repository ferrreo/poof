const std = @import("std");
const linux = std.os.linux;

const upload_io = @import("../../src/upload_io.zig");
const file_table = @import("../../src/internal/runtime/upload/file_table.zig");
const upload_transport = @import("../../src/internal/runtime/upload/transport.zig");
const reactor = @import("../../src/internal/runtime/reactor.zig");

pub const TestTransport = upload_transport.Transport(u32, 8, 4);
pub const Owner = file_table.Owner;

pub const runtime_owner = Owner{
    .scope = .runtime,
    .registry_index = 7,
    .instance_index = 0,
    .slot = .{
        .worker_index = 1,
        .index = reactor.upload_runtime_control_slot,
        .generation = 2,
    },
};
pub const request_owner = Owner{
    .scope = .request,
    .registry_index = 7,
    .instance_index = 3,
    .slot = .{ .worker_index = 1, .index = 10, .generation = 4 },
};

pub fn token(owner: Owner, kind: reactor.OperationKind, sequence: u16) reactor.OperationToken {
    return reactor.OperationToken.init(.{
        .kind = kind,
        .worker_index = owner.slot.worker_index,
        .slot_index = owner.slot.index,
        .slot_generation = owner.slot.generation,
        .sequence = sequence,
    }) catch unreachable;
}

pub fn completion(
    operation_token: reactor.OperationToken,
    result: reactor.CompletionResult,
) reactor.Completion {
    return .{ .token = operation_token, .result = result, .more = false };
}

pub fn addHandle(
    transport: *TestTransport,
    owner: Owner,
    raw_fd: i32,
    kind: upload_io.OpenKind,
    access: upload_io.Access,
) !upload_io.FileHandle {
    return addHandleWithCreate(transport, owner, raw_fd, kind, access, .none);
}

pub fn addHandleWithCreate(
    transport: *TestTransport,
    owner: Owner,
    raw_fd: i32,
    kind: upload_io.OpenKind,
    access: upload_io.Access,
    create: upload_io.Create,
) !upload_io.FileHandle {
    return addHandleOpenedAt(
        transport,
        owner,
        raw_fd,
        kind,
        access,
        create,
        .working_directory,
        "fixture",
    );
}

pub fn addHandleOpenedAt(
    transport: *TestTransport,
    owner: Owner,
    raw_fd: i32,
    kind: upload_io.OpenKind,
    access: upload_io.Access,
    create: upload_io.Create,
    base: upload_io.OpenBase,
    path: []const u8,
) !upload_io.FileHandle {
    const handle = if (create == .exclusive)
        try transport.table().reserveOpenAt(owner, base, path)
    else
        try transport.table().reserveOpen(owner);
    try transport.table().completeOpenPositive(
        handle,
        owner,
        raw_fd,
        kind,
        access,
        create,
    );
    return handle;
}

pub fn expectFailure(
    delivery: TestTransport.Delivery,
    cookie: u32,
    failure: upload_io.IoError,
) !void {
    try std.testing.expectEqual(cookie, delivery.cookie);
    try std.testing.expect(delivery.completion == .failure);
    try std.testing.expectEqual(failure, delivery.completion.failure);
}

test "target record does not duplicate open provenance" {
    try std.testing.expectEqual(@as(usize, 80), TestTransport.target_bytes);
}

test "working-directory bootstrap is runtime-control-only and reversible" {
    var transport = TestTransport.init();
    const request = upload_io.IoRequest{ .open = .{
        .base = .working_directory,
        .path = "/srv/uploads",
        .access = .read_only,
        .kind = .directory,
        .no_follow = false,
        .resolve = .{
            .no_symlinks = true,
            .no_magic_links = true,
            .no_mount_crossing = true,
        },
    } };
    try std.testing.expectError(
        error.WorkingDirectoryDenied,
        transport.prepareTarget(
            request_owner,
            token(request_owner, .file_open, 1),
            10,
            request,
        ),
    );
    try std.testing.expectEqual(@as(u32, 0), transport.tableConst().active());
    try std.testing.expectEqual(@as(u32, 0), transport.pendingTargets());

    const operation_token = token(runtime_owner, .file_open, 1);
    const submission = try transport.prepareTarget(runtime_owner, operation_token, 11, request);
    try std.testing.expect(submission.operation == .file_open);
    try std.testing.expect(submission.operation.file_open.base == .working_directory);
    try std.testing.expectEqualStrings(
        request.open.path,
        submission.operation.file_open.path,
    );
    try std.testing.expect(!submission.operation.file_open.no_follow);
    try std.testing.expect(submission.operation.file_open.resolve.no_symlinks);
    try std.testing.expect(submission.operation.file_open.resolve.no_magic_links);
    try std.testing.expect(submission.operation.file_open.resolve.no_mount_crossing);
    try std.testing.expectEqual(@as(u32, 1), transport.tableConst().active());
    try std.testing.expect((try transport.rollback(operation_token)) == null);
    try std.testing.expectEqual(@as(u32, 0), transport.tableConst().active());
    try std.testing.expectEqual(@as(u32, 0), transport.pendingTargets());
}

test "working-directory bootstrap rejects every non-directory read-only shape" {
    const invalid = [_]upload_io.Open{
        .{
            .base = .working_directory,
            .path = "/srv/uploads",
            .access = .read_write,
            .kind = .directory,
        },
        .{
            .base = .working_directory,
            .path = "/srv/uploads",
            .access = .write_only,
            .kind = .directory,
        },
        .{
            .base = .working_directory,
            .path = "/srv/uploads",
            .access = .read_only,
            .kind = .file,
        },
        .{
            .base = .working_directory,
            .path = "/srv/uploads",
            .access = .read_write,
            .create = .anonymous,
            .kind = .file,
            .mode = 0o600,
        },
        .{
            .base = .working_directory,
            .path = "/srv/uploads",
            .access = .write_only,
            .create = .exclusive,
            .kind = .file,
            .mode = 0o600,
        },
    };
    var transport = TestTransport.init();
    for (invalid, 1..) |open, sequence| {
        try std.testing.expectError(
            error.WorkingDirectoryDenied,
            transport.prepareTarget(
                runtime_owner,
                token(runtime_owner, .file_open, @intCast(sequence)),
                @intCast(sequence),
                .{ .open = open },
            ),
        );
        try std.testing.expectEqual(@as(u32, 0), transport.tableConst().active());
        try std.testing.expectEqual(@as(u32, 0), transport.pendingTargets());
        try std.testing.expectEqual(@as(u32, 0), transport.pendingCancellations());
    }
}

test "working-directory bootstrap rejects a runtime non-control slot" {
    var non_control = runtime_owner;
    non_control.slot.index = reactor.upload_runtime_control_slot + 1;
    var transport = TestTransport.init();
    try std.testing.expectError(
        error.WorkingDirectoryDenied,
        transport.prepareTarget(
            non_control,
            token(non_control, .file_open, 1),
            1,
            .{ .open = .{
                .base = .working_directory,
                .path = "/srv/uploads",
                .access = .read_only,
                .kind = .directory,
            } },
        ),
    );
    try std.testing.expectEqual(@as(u32, 0), transport.tableConst().active());
    try std.testing.expectEqual(@as(u32, 0), transport.pendingTargets());
}

test "target identity and normalized request validation precede table mutation" {
    var transport = TestTransport.init();
    const request = upload_io.IoRequest{ .open = .{
        .base = .working_directory,
        .path = "/srv/uploads",
        .access = .read_only,
        .kind = .directory,
    } };
    try std.testing.expectError(
        error.TokenKindMismatch,
        transport.prepareTarget(
            runtime_owner,
            token(runtime_owner, .file_write, 1),
            1,
            request,
        ),
    );
    try std.testing.expectError(
        error.TokenOwnerMismatch,
        transport.prepareTarget(
            runtime_owner,
            token(request_owner, .file_open, 1),
            1,
            request,
        ),
    );
    var invalid = request;
    invalid.open.path = "";
    try std.testing.expectError(
        error.InvalidRequest,
        transport.prepareTarget(
            runtime_owner,
            token(runtime_owner, .file_open, 2),
            1,
            invalid,
        ),
    );
    try std.testing.expectEqual(@as(u32, 0), transport.tableConst().active());
}

test "open success publishes logical handle before delivery and close is two phase" {
    var transport = TestTransport.init();
    const open_token = token(runtime_owner, .file_open, 1);
    _ = try transport.prepareTarget(runtime_owner, open_token, 41, .{ .open = .{
        .base = .working_directory,
        .path = "/srv/uploads",
        .access = .read_only,
        .kind = .directory,
    } });
    try transport.markSubmitted(open_token);
    const opened = (try transport.complete(completion(open_token, .{ .success = .{
        .file_open = .{ .value = 50 },
    } }))).?;
    try std.testing.expectEqual(@as(u32, 41), opened.cookie);
    try std.testing.expect(opened.completion == .success);
    const handle = opened.completion.success.open;
    try std.testing.expectEqual(file_table.Phase.open, try transport.tableConst().phase(handle));

    const close_token = token(runtime_owner, .file_close, 2);
    _ = try transport.prepareTarget(runtime_owner, close_token, 42, .{
        .close = .{ .file = handle },
    });
    try std.testing.expectEqual(file_table.Phase.closing, try transport.tableConst().phase(handle));
    try std.testing.expect((try transport.rollback(close_token)) == null);
    try std.testing.expectEqual(file_table.Phase.open, try transport.tableConst().phase(handle));

    const final_close = token(runtime_owner, .file_close, 3);
    _ = try transport.prepareTarget(runtime_owner, final_close, 43, .{
        .close = .{ .file = handle },
    });
    try transport.markSubmitted(final_close);
    const closed = (try transport.complete(completion(final_close, .{ .success = .{
        .file_close = {},
    } }))).?;
    try std.testing.expectEqual(@as(u32, 43), closed.cookie);
    try std.testing.expect(closed.completion == .success);
    try std.testing.expect(closed.completion.success == .close);
    try std.testing.expectEqual(@as(u32, 0), transport.tableConst().active());
}

test "resolved handles retain exact access kind and duplicate borrow counts" {
    var transport = TestTransport.init();
    const directory = try addHandle(
        &transport,
        runtime_owner,
        60,
        .directory,
        .read_only,
    );
    const file = try addHandleWithCreate(
        &transport,
        request_owner,
        61,
        .file,
        .read_write,
        .anonymous,
    );

    const open_token = token(request_owner, .file_open, 1);
    const opened = try transport.prepareTarget(request_owner, open_token, 1, .{ .open = .{
        .base = .{ .handle = directory },
        .path = "old.bin",
        .access = .write_only,
        .create = .exclusive,
        .mode = 0o600,
    } });
    try std.testing.expectEqual(@as(i32, 60), opened.operation.file_open.base.directory.value);
    try std.testing.expectEqual(
        @as(u32, 1),
        try transport.tableConst().references(directory, runtime_owner),
    );
    try transport.markSubmitted(open_token);
    const open_delivery = (try transport.complete(completion(open_token, .{ .success = .{
        .file_open = .{ .value = 62 },
    } }))).?;
    const named = open_delivery.completion.success.open;
    try std.testing.expectEqual(
        @as(u32, 0),
        try transport.tableConst().references(directory, runtime_owner),
    );

    const write_token = token(request_owner, .file_write, 2);
    const write = try transport.prepareTarget(request_owner, write_token, 2, .{ .write = .{
        .file = file,
        .bytes = "abc",
        .offset = 9,
    } });
    try std.testing.expectEqual(@as(i32, 61), write.operation.file_write.file.value);
    try std.testing.expectEqual(
        @as(u32, 1),
        try transport.tableConst().references(file, request_owner),
    );
    try std.testing.expect((try transport.rollback(write_token)) == null);
    try std.testing.expectEqual(
        @as(u32, 0),
        try transport.tableConst().references(file, request_owner),
    );

    const link_token = token(request_owner, .file_link, 3);
    _ = try transport.prepareTarget(request_owner, link_token, 3, .{ .link = .{
        .source = file,
        .target_directory = directory,
        .target_path = "new.bin",
    } });
    try std.testing.expectEqual(
        @as(u32, 1),
        try transport.tableConst().references(directory, runtime_owner),
    );
    try std.testing.expectEqual(
        @as(u32, 1),
        try transport.tableConst().references(file, request_owner),
    );
    try transport.markSubmitted(link_token);
    const linked = (try transport.complete(completion(link_token, .{ .success = .{
        .file_link = {},
    } }))).?;
    try std.testing.expectEqual(@as(u32, 3), linked.cookie);
    try std.testing.expect(linked.completion.success == .link);
    try std.testing.expectEqual(
        @as(u32, 0),
        try transport.tableConst().references(directory, runtime_owner),
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        try transport.tableConst().references(file, request_owner),
    );

    const rename_token = token(request_owner, .file_rename_no_replace, 4);
    _ = try transport.prepareTarget(request_owner, rename_token, 4, .{
        .rename_no_replace = .{
            .source = named,
            .source_directory = directory,
            .source_path = "old.bin",
            .target_directory = directory,
            .target_path = "new.bin",
        },
    });
    try std.testing.expectEqual(
        @as(u32, 2),
        try transport.tableConst().references(directory, runtime_owner),
    );
    try std.testing.expectEqual(
        @as(u32, 1),
        try transport.tableConst().references(named, request_owner),
    );
    try transport.markSubmitted(rename_token);
    const renamed = (try transport.complete(completion(rename_token, .{ .success = .{
        .file_rename_no_replace = {},
    } }))).?;
    try std.testing.expect(renamed.completion.success == .rename_no_replace);
    try std.testing.expectEqual(
        @as(u32, 0),
        try transport.tableConst().references(directory, runtime_owner),
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        try transport.tableConst().references(named, request_owner),
    );
}

test "rename proves exact exclusive source open identity" {
    var transport = TestTransport.init();
    const staging = try addHandle(&transport, runtime_owner, 63, .directory, .read_only);
    const destination = try addHandle(&transport, runtime_owner, 64, .directory, .read_only);
    const source = try addHandleOpenedAt(
        &transport,
        request_owner,
        65,
        .file,
        .write_only,
        .exclusive,
        .{ .handle = staging },
        ".ploof-upload-source",
    );
    const unrelated = try addHandleOpenedAt(
        &transport,
        request_owner,
        66,
        .file,
        .write_only,
        .exclusive,
        .{ .handle = staging },
        ".ploof-upload-other",
    );
    const nonexclusive = try addHandleOpenedAt(
        &transport,
        request_owner,
        67,
        .file,
        .write_only,
        .none,
        .{ .handle = staging },
        ".ploof-upload-existing",
    );

    try std.testing.expectError(error.WrongOpenIdentity, transport.prepareTarget(
        request_owner,
        token(request_owner, .file_rename_no_replace, 1),
        1,
        .{ .rename_no_replace = .{
            .source = unrelated,
            .source_directory = staging,
            .source_path = ".ploof-upload-source",
            .target_directory = destination,
            .target_path = "final",
        } },
    ));
    try std.testing.expectError(error.WrongOpenIdentity, transport.prepareTarget(
        request_owner,
        token(request_owner, .file_rename_no_replace, 7),
        7,
        .{ .rename_no_replace = .{
            .source = source,
            .source_directory = destination,
            .source_path = ".ploof-upload-source",
            .target_directory = destination,
            .target_path = "final",
        } },
    ));
    try std.testing.expectError(error.WrongOpenIdentity, transport.prepareTarget(
        request_owner,
        token(request_owner, .file_rename_no_replace, 2),
        2,
        .{ .rename_no_replace = .{
            .source = source,
            .source_directory = staging,
            .source_path = ".ploof-upload-other",
            .target_directory = destination,
            .target_path = "final",
        } },
    ));
    try std.testing.expectError(error.StaleGeneration, transport.prepareTarget(
        request_owner,
        token(request_owner, .file_rename_no_replace, 3),
        3,
        .{ .rename_no_replace = .{
            .source = source,
            .source_directory = upload_io.FileHandle.fromParts(
                staging.index(),
                staging.generation() + 1,
            ),
            .source_path = ".ploof-upload-source",
            .target_directory = destination,
            .target_path = "final",
        } },
    ));
    try std.testing.expectError(error.WrongCreation, transport.prepareTarget(
        request_owner,
        token(request_owner, .file_rename_no_replace, 4),
        4,
        .{ .rename_no_replace = .{
            .source = nonexclusive,
            .source_directory = staging,
            .source_path = ".ploof-upload-existing",
            .target_directory = destination,
            .target_path = "final",
        } },
    ));
    try std.testing.expectError(error.InvalidHandle, transport.prepareTarget(
        request_owner,
        token(request_owner, .file_rename_no_replace, 5),
        5,
        .{ .rename_no_replace = .{
            .source = source,
            .source_directory = staging,
            .source_path = ".ploof-upload-source",
            .target_directory = upload_io.FileHandle.fromParts(99, 1),
            .target_path = "final",
        } },
    ));
    try std.testing.expectEqual(@as(u32, 0), try transport.tableConst().references(
        source,
        request_owner,
    ));
    try std.testing.expectEqual(@as(u32, 0), try transport.tableConst().references(
        unrelated,
        request_owner,
    ));
    try std.testing.expectEqual(@as(u32, 0), try transport.tableConst().references(
        nonexclusive,
        request_owner,
    ));
    try std.testing.expectEqual(@as(u32, 0), try transport.tableConst().references(
        staging,
        runtime_owner,
    ));
    try std.testing.expectEqual(@as(u32, 0), try transport.tableConst().references(
        destination,
        runtime_owner,
    ));

    const rename_token = token(request_owner, .file_rename_no_replace, 6);
    _ = try transport.prepareTarget(request_owner, rename_token, 6, .{
        .rename_no_replace = .{
            .source = source,
            .source_directory = staging,
            .source_path = ".ploof-upload-source",
            .target_directory = destination,
            .target_path = "final",
        },
    });
    try std.testing.expectEqual(@as(u32, 1), try transport.tableConst().references(
        source,
        request_owner,
    ));
    try std.testing.expectEqual(@as(u32, 1), try transport.tableConst().references(
        staging,
        runtime_owner,
    ));
    try std.testing.expectEqual(@as(u32, 1), try transport.tableConst().references(
        destination,
        runtime_owner,
    ));
    try std.testing.expect((try transport.rollback(rename_token)) == null);
    try std.testing.expectEqual(@as(u32, 0), try transport.tableConst().references(
        source,
        request_owner,
    ));
    try std.testing.expectEqual(@as(u32, 0), try transport.tableConst().references(
        staging,
        runtime_owner,
    ));
    try std.testing.expectEqual(@as(u32, 0), try transport.tableConst().references(
        destination,
        runtime_owner,
    ));
}

test "unlink anonymous link and file or directory sync map without allocation" {
    var transport = TestTransport.init();
    const directory = try addHandle(
        &transport,
        runtime_owner,
        70,
        .directory,
        .read_only,
    );
    const file = try addHandleWithCreate(
        &transport,
        request_owner,
        71,
        .file,
        .read_write,
        .anonymous,
    );
    const link_token = token(request_owner, .file_link, 1);
    const link = try transport.prepareTarget(request_owner, link_token, 5, .{ .link = .{
        .source = file,
        .target_directory = directory,
        .target_path = "done.bin",
    } });
    try std.testing.expectEqual(@as(i32, 71), link.operation.file_link.source.value);
    try std.testing.expectEqual(@as(i32, 70), link.operation.file_link.target_directory.value);
    try std.testing.expect((try transport.rollback(link_token)) == null);

    const unlink_token = token(request_owner, .file_unlink, 2);
    const unlink = try transport.prepareTarget(request_owner, unlink_token, 6, .{ .unlink = .{
        .directory = directory,
        .path = "done.bin",
    } });
    try std.testing.expectEqual(@as(i32, 70), unlink.operation.file_unlink.directory.value);
    try transport.markSubmitted(unlink_token);
    const unlinked = (try transport.complete(completion(unlink_token, .{ .success = .{
        .file_unlink = {},
    } }))).?;
    try std.testing.expect(unlinked.completion.success == .unlink);

    const directory_sync = token(request_owner, .file_sync, 3);
    const sync_directory = try transport.prepareTarget(request_owner, directory_sync, 7, .{
        .sync = .{ .file = directory },
    });
    try std.testing.expectEqual(@as(i32, 70), sync_directory.operation.file_sync.file.value);
    try transport.markSubmitted(directory_sync);
    const synced = (try transport.complete(completion(directory_sync, .{ .success = .{
        .file_sync = {},
    } }))).?;
    try std.testing.expect(synced.completion.success == .sync);
    const file_sync = token(request_owner, .file_sync, 4);
    const sync_file = try transport.prepareTarget(request_owner, file_sync, 8, .{
        .sync = .{ .file = file },
    });
    try std.testing.expectEqual(@as(i32, 71), sync_file.operation.file_sync.file.value);
    try std.testing.expect((try transport.rollback(file_sync)) == null);

    const named = try addHandle(&transport, request_owner, 72, .file, .read_write);
    try std.testing.expectError(error.WrongCreation, transport.prepareTarget(
        request_owner,
        token(request_owner, .file_link, 5),
        9,
        .{ .link = .{
            .source = named,
            .target_directory = directory,
            .target_path = "named.bin",
        } },
    ));
    try std.testing.expectEqual(
        @as(u32, 0),
        try transport.tableConst().references(named, request_owner),
    );
}
