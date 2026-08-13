const std = @import("std");
const linux = std.os.linux;

const upload_io = @import("../../src/upload_io.zig");
const file_table = @import("../../src/internal/runtime/upload/file_table.zig");
const upload_transport = @import("../../src/internal/runtime/upload/transport.zig");
const reactor = @import("../../src/internal/runtime/reactor.zig");
const base = @import("upload_transport_test.zig");

const TestTransport = base.TestTransport;
const request_owner = base.request_owner;
const runtime_owner = base.runtime_owner;
const addHandle = base.addHandle;
const addHandleWithCreate = base.addHandleWithCreate;
const completion = base.completion;
const expectFailure = base.expectFailure;
const token = base.token;

test "target and cancellation tokens retain owner until pair retires" {
    var transport = TestTransport.init();
    const handle = try addHandle(&transport, request_owner, 79, .file, .write_only);
    const target_token = token(request_owner, .file_write, 1);
    _ = try transport.prepareTarget(request_owner, target_token, 7, .{ .write = .{
        .file = handle,
        .bytes = "x",
        .offset = 0,
    } });
    try transport.markSubmitted(target_token);

    const cancel_token = token(request_owner, .upload_cancel, 2);
    _ = try transport.prepareCancel(target_token, cancel_token);
    try transport.markSubmitted(cancel_token);
    try std.testing.expectEqualDeep(request_owner, transport.targetOwner(target_token).?);
    try std.testing.expectEqualDeep(request_owner, transport.targetOwner(cancel_token).?);

    try std.testing.expect((try transport.complete(completion(target_token, .{
        .failure = .canceled,
    }))) == null);
    try std.testing.expectEqualDeep(request_owner, transport.targetOwner(target_token).?);
    try std.testing.expectEqualDeep(request_owner, transport.targetOwner(cancel_token).?);

    _ = (try transport.complete(completion(cancel_token, .{ .success = .{
        .upload_cancel = .canceled,
    } }))).?;
    try std.testing.expect(transport.targetOwner(target_token) == null);
    try std.testing.expect(transport.targetOwner(cancel_token) == null);
}

test "fixed target capacity retains records until explicit rollback" {
    const TinyTransport = upload_transport.Transport(u8, 2, 1);
    var transport = TinyTransport.init();
    const handle = try transport.table().reserveOpen(request_owner);
    try transport.table().completeOpenPositive(
        handle,
        request_owner,
        80,
        .file,
        .write_only,
        .none,
    );
    const first = token(request_owner, .file_write, 1);
    _ = try transport.prepareTarget(request_owner, first, 1, .{ .write = .{
        .file = handle,
        .bytes = "a",
        .offset = 0,
    } });
    try std.testing.expectError(error.DuplicateToken, transport.prepareTarget(
        request_owner,
        first,
        2,
        .{ .write = .{ .file = handle, .bytes = "b", .offset = 1 } },
    ));
    try std.testing.expectError(error.Full, transport.prepareTarget(
        request_owner,
        token(request_owner, .file_write, 2),
        2,
        .{ .write = .{ .file = handle, .bytes = "b", .offset = 1 } },
    ));
    try std.testing.expect((try transport.rollback(first)) == null);
    try std.testing.expectEqual(@as(u32, 0), transport.pendingTargets());
}

test "partial resolution failure releases borrows and open reservations" {
    var transport = TestTransport.init();
    const file = try addHandleWithCreate(
        &transport,
        request_owner,
        82,
        .file,
        .read_write,
        .anonymous,
    );
    const invalid = upload_io.FileHandle.fromParts(99, 1);
    try std.testing.expectError(error.InvalidHandle, transport.prepareTarget(
        request_owner,
        token(request_owner, .file_link, 1),
        1,
        .{ .link = .{
            .source = file,
            .target_directory = invalid,
            .target_path = "target",
        } },
    ));
    try std.testing.expectEqual(
        @as(u32, 0),
        try transport.tableConst().references(file, request_owner),
    );
    const active_before = transport.tableConst().active();
    try std.testing.expectError(error.InvalidHandle, transport.prepareTarget(
        request_owner,
        token(request_owner, .file_open, 2),
        2,
        .{ .open = .{
            .base = .{ .handle = invalid },
            .path = "target",
            .access = .write_only,
        } },
    ));
    try std.testing.expectEqual(active_before, transport.tableConst().active());
    try std.testing.expectEqual(@as(u32, 0), transport.pendingTargets());
}

test "submitted target cannot roll back and remains completable" {
    var transport = TestTransport.init();
    const handle = try addHandle(&transport, request_owner, 83, .file, .write_only);
    const target_token = token(request_owner, .file_write, 1);
    _ = try transport.prepareTarget(request_owner, target_token, 9, .{ .write = .{
        .file = handle,
        .bytes = "x",
        .offset = 0,
    } });
    try transport.markSubmitted(target_token);
    try std.testing.expectError(error.InvalidPhase, transport.rollback(target_token));
    const delivered = (try transport.complete(completion(target_token, .{ .success = .{
        .file_write = 1,
    } }))).?;
    try std.testing.expectEqual(@as(u32, 9), delivered.cookie);
    try std.testing.expectEqual(@as(u32, 1), delivered.completion.success.write);
}

test "target-first cancellation withholds cookie until cancel terminal" {
    var transport = TestTransport.init();
    const handle = try addHandle(&transport, request_owner, 90, .file, .write_only);
    const target_token = token(request_owner, .file_write, 1);
    _ = try transport.prepareTarget(request_owner, target_token, 101, .{ .write = .{
        .file = handle,
        .bytes = "payload",
        .offset = 0,
    } });
    try transport.markSubmitted(target_token);
    const cancel_token = token(request_owner, .upload_cancel, 2);
    const cancel = try transport.prepareCancel(target_token, cancel_token);
    try std.testing.expect(cancel.operation == .upload_cancel);
    try std.testing.expect(cancel.operation.upload_cancel.target.eql(target_token));
    try transport.markSubmitted(cancel_token);

    try std.testing.expect((try transport.complete(completion(target_token, .{
        .failure = .canceled,
    }))) == null);
    try std.testing.expectEqual(@as(u32, 1), transport.pendingTargets());
    try std.testing.expectEqual(@as(u32, 1), transport.pendingCancellations());
    try std.testing.expectError(error.DuplicateToken, transport.prepareTarget(
        request_owner,
        target_token,
        102,
        .{ .write = .{ .file = handle, .bytes = "x", .offset = 0 } },
    ));
    const delivered = (try transport.complete(completion(cancel_token, .{ .success = .{
        .upload_cancel = .canceled,
    } }))).?;
    try expectFailure(delivered, 101, .canceled);
    try std.testing.expectEqual(@as(u32, 0), transport.pendingTargets());
    try std.testing.expectEqual(@as(u32, 0), transport.pendingCancellations());
}

test "cancel-first not-found still waits for successful target" {
    var transport = TestTransport.init();
    const handle = try addHandle(&transport, request_owner, 91, .file, .write_only);
    const target_token = token(request_owner, .file_write, 1);
    _ = try transport.prepareTarget(request_owner, target_token, 201, .{ .write = .{
        .file = handle,
        .bytes = "payload",
        .offset = 0,
    } });
    try transport.markSubmitted(target_token);
    const cancel_token = token(request_owner, .upload_cancel, 2);
    _ = try transport.prepareCancel(target_token, cancel_token);
    try transport.markSubmitted(cancel_token);
    try std.testing.expect((try transport.complete(completion(cancel_token, .{ .success = .{
        .upload_cancel = .not_found,
    } }))) == null);
    try std.testing.expectEqual(@as(u32, 1), transport.pendingTargets());
    const delivered = (try transport.complete(completion(target_token, .{ .success = .{
        .file_write = 7,
    } }))).?;
    try std.testing.expectEqual(@as(u32, 201), delivered.cookie);
    try std.testing.expect(delivered.completion == .success);
    try std.testing.expectEqual(@as(u32, 7), delivered.completion.success.write);
    try std.testing.expectEqual(@as(u32, 0), transport.pendingTargets());
    try std.testing.expectEqual(@as(u32, 0), transport.pendingCancellations());
}

test "cancel enqueue rollback releases a target that completed meanwhile" {
    var transport = TestTransport.init();
    const handle = try addHandle(&transport, request_owner, 92, .file, .write_only);
    const target_token = token(request_owner, .file_write, 1);
    _ = try transport.prepareTarget(request_owner, target_token, 301, .{ .write = .{
        .file = handle,
        .bytes = "payload",
        .offset = 0,
    } });
    try transport.markSubmitted(target_token);
    const cancel_token = token(request_owner, .upload_cancel, 2);
    _ = try transport.prepareCancel(target_token, cancel_token);
    try std.testing.expect((try transport.complete(completion(target_token, .{ .success = .{
        .file_write = 7,
    } }))) == null);
    const delivered = (try transport.rollback(cancel_token)).?;
    try std.testing.expectEqual(@as(u32, 301), delivered.cookie);
    try std.testing.expectEqual(@as(u32, 7), delivered.completion.success.write);
    try std.testing.expectEqual(@as(u32, 0), transport.pendingTargets());
    try std.testing.expectEqual(@as(u32, 0), transport.pendingCancellations());
    try std.testing.expectError(error.UnknownToken, transport.markSubmitted(cancel_token));
}

test "cancellation preparation validates phase identity and uniqueness" {
    var transport = TestTransport.init();
    const handle = try addHandle(&transport, request_owner, 93, .file, .write_only);
    const target_token = token(request_owner, .file_write, 1);
    _ = try transport.prepareTarget(request_owner, target_token, 1, .{ .write = .{
        .file = handle,
        .bytes = "x",
        .offset = 0,
    } });
    const cancel_token = token(request_owner, .upload_cancel, 2);
    try std.testing.expectError(
        error.NotCancelable,
        transport.prepareCancel(target_token, cancel_token),
    );
    try transport.markSubmitted(target_token);
    try std.testing.expectError(
        error.TokenKindMismatch,
        transport.prepareCancel(target_token, token(request_owner, .file_sync, 2)),
    );
    try std.testing.expectError(
        error.TokenOwnerMismatch,
        transport.prepareCancel(target_token, token(runtime_owner, .upload_cancel, 2)),
    );
    _ = try transport.prepareCancel(target_token, cancel_token);
    try std.testing.expectError(
        error.CancellationAlreadyPending,
        transport.prepareCancel(target_token, token(request_owner, .upload_cancel, 3)),
    );
    try transport.markSubmitted(cancel_token);
    try std.testing.expectError(error.InvalidPhase, transport.rollback(cancel_token));
}

test "cancel completion before submission mark is fatal but pair remains retained" {
    var transport = TestTransport.init();
    const handle = try addHandle(&transport, request_owner, 94, .file, .write_only);
    const target_token = token(request_owner, .file_write, 1);
    _ = try transport.prepareTarget(request_owner, target_token, 401, .{ .write = .{
        .file = handle,
        .bytes = "x",
        .offset = 0,
    } });
    try transport.markSubmitted(target_token);
    const cancel_token = token(request_owner, .upload_cancel, 2);
    _ = try transport.prepareCancel(target_token, cancel_token);
    try std.testing.expect((try transport.complete(completion(cancel_token, .{ .success = .{
        .upload_cancel = .not_found,
    } }))) == null);
    try std.testing.expect(transport.fatal());
    try std.testing.expect(!transport.ownershipProven());
    try std.testing.expectEqual(@as(u32, 1), transport.pendingTargets());
    try std.testing.expectEqual(@as(u32, 1), transport.pendingCancellations());
    try std.testing.expectError(
        error.TransportFatal,
        transport.complete(completion(target_token, .{ .success = .{ .file_write = 1 } })),
    );
    try std.testing.expectEqual(@as(u32, 0), transport.pendingTargets());
    try std.testing.expectEqual(@as(u32, 0), transport.pendingCancellations());
}

test "every normalized file failure is delivered without poisoning ownership" {
    const Case = struct {
        reactor_failure: reactor.CompletionError,
        upload_failure: upload_io.IoError,
    };
    const cases = [_]Case{
        .{ .reactor_failure = .canceled, .upload_failure = .canceled },
        .{ .reactor_failure = .already_exists, .upload_failure = .already_exists },
        .{ .reactor_failure = .not_found, .upload_failure = .not_found },
        .{ .reactor_failure = .invalid_path, .upload_failure = .invalid_path },
        .{ .reactor_failure = .cross_device, .upload_failure = .cross_device },
        .{ .reactor_failure = .read_only, .upload_failure = .read_only },
        .{ .reactor_failure = .quota_exceeded, .upload_failure = .quota_exceeded },
        .{ .reactor_failure = .file_too_large, .upload_failure = .file_too_large },
        .{ .reactor_failure = .no_space, .upload_failure = .no_space },
        .{ .reactor_failure = .unsupported, .upload_failure = .unsupported },
        .{ .reactor_failure = .io_failure, .upload_failure = .io_failure },
        .{ .reactor_failure = .permission_denied, .upload_failure = .permission_denied },
        .{ .reactor_failure = .resource_exhausted, .upload_failure = .resource_exhausted },
    };
    var transport = TestTransport.init();
    const handle = try addHandle(&transport, request_owner, 100, .file, .write_only);
    for (cases, 1..) |case, sequence| {
        const target_token = token(request_owner, .file_write, @intCast(sequence));
        _ = try transport.prepareTarget(request_owner, target_token, @intCast(sequence), .{
            .write = .{ .file = handle, .bytes = "x", .offset = 0 },
        });
        try transport.markSubmitted(target_token);
        const delivered = (try transport.complete(completion(target_token, .{
            .failure = case.reactor_failure,
        }))).?;
        try expectFailure(delivered, @intCast(sequence), case.upload_failure);
    }
    try std.testing.expect(!transport.fatal());
    try std.testing.expect(transport.ownershipProven());
}

test "invalid-resource and impossible network failures poison transport" {
    const failures = [_]reactor.CompletionError{ .invalid_resource, .connection_reset };
    for (failures, 1..) |failure, sequence| {
        var transport = TestTransport.init();
        const handle = try addHandle(&transport, request_owner, 110, .file, .write_only);
        const target_token = token(request_owner, .file_write, @intCast(sequence));
        _ = try transport.prepareTarget(request_owner, target_token, 1, .{ .write = .{
            .file = handle,
            .bytes = "x",
            .offset = 0,
        } });
        try transport.markSubmitted(target_token);
        try std.testing.expectError(
            error.TransportFatal,
            transport.complete(completion(target_token, .{ .failure = failure })),
        );
        try std.testing.expect(transport.fatal());
        try std.testing.expect(!transport.ownershipProven());
        try std.testing.expectEqual(
            @as(u32, 0),
            try transport.tableConst().references(handle, request_owner),
        );
        try std.testing.expectEqual(@as(u32, 0), transport.pendingTargets());
    }
}

test "fatal ownership suppresses later cookies while still reaping targets" {
    var transport = TestTransport.init();
    const handle = try addHandle(&transport, request_owner, 111, .file, .write_only);
    const first = token(request_owner, .file_write, 1);
    const second = token(request_owner, .file_write, 2);
    _ = try transport.prepareTarget(request_owner, first, 1, .{ .write = .{
        .file = handle,
        .bytes = "a",
        .offset = 0,
    } });
    _ = try transport.prepareTarget(request_owner, second, 2, .{ .write = .{
        .file = handle,
        .bytes = "b",
        .offset = 1,
    } });
    try transport.markSubmitted(first);
    try transport.markSubmitted(second);
    try std.testing.expectError(
        error.TransportFatal,
        transport.complete(completion(first, .{ .failure = .invalid_resource })),
    );
    try std.testing.expectError(
        error.TransportFatal,
        transport.complete(completion(second, .{ .success = .{ .file_write = 1 } })),
    );
    try std.testing.expectEqual(@as(u32, 0), transport.pendingTargets());
    try std.testing.expectEqual(
        @as(u32, 0),
        try transport.tableConst().references(handle, request_owner),
    );
}

test "canceled close restores handle but every other close failure is uncertain" {
    var transport = TestTransport.init();
    const handle = try addHandle(&transport, request_owner, 120, .file, .write_only);
    const canceled_token = token(request_owner, .file_close, 1);
    _ = try transport.prepareTarget(request_owner, canceled_token, 1, .{
        .close = .{ .file = handle },
    });
    try transport.markSubmitted(canceled_token);
    const canceled = (try transport.complete(completion(canceled_token, .{
        .failure = .canceled,
    }))).?;
    try expectFailure(canceled, 1, .canceled);
    try std.testing.expectEqual(file_table.Phase.open, try transport.tableConst().phase(handle));
    try std.testing.expect(transport.ownershipProven());

    const failed_token = token(request_owner, .file_close, 2);
    _ = try transport.prepareTarget(request_owner, failed_token, 2, .{
        .close = .{ .file = handle },
    });
    try transport.markSubmitted(failed_token);
    try std.testing.expectError(
        error.TransportFatal,
        transport.complete(completion(failed_token, .{ .failure = .io_failure })),
    );
    try std.testing.expectEqual(
        file_table.Phase.ownership_unproven,
        try transport.tableConst().phase(handle),
    );
    try std.testing.expect(transport.fatal());
    try std.testing.expect(!transport.ownershipProven());
    var cursor = file_table.CleanupCursor{};
    const cleanup = transport.nextCleanup(&cursor).?;
    try std.testing.expect(cleanup.handle.eql(handle));
    try std.testing.expectEqual(file_table.Phase.ownership_unproven, cleanup.phase);
}

test "rejected positive open bookkeeping closes the raw descriptor" {
    var transport = TestTransport.init();
    const target_token = token(runtime_owner, .file_open, 1);
    _ = try transport.prepareTarget(runtime_owner, target_token, 1, .{ .open = .{
        .base = .working_directory,
        .path = "/srv/uploads",
        .access = .read_only,
        .kind = .directory,
    } });
    var cursor = file_table.CleanupCursor{};
    const reserved = transport.nextCleanup(&cursor).?.handle;
    try transport.markSubmitted(target_token);
    try transport.table().rollbackOpen(reserved, runtime_owner);

    const descriptor_result = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(descriptor_result));
    const raw_fd: linux.fd_t = @intCast(descriptor_result);
    try std.testing.expectError(
        error.TransportFatal,
        transport.complete(completion(target_token, .{ .success = .{
            .file_open = .{ .value = raw_fd },
        } })),
    );
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.close(raw_fd)));
    try std.testing.expectEqual(@as(u32, 0), transport.pendingTargets());
    try std.testing.expect(transport.fatal());
}

test "invalid completion tags are fatal before borrowed state changes" {
    var transport = TestTransport.init();
    const handle = try addHandle(&transport, request_owner, 130, .file, .write_only);
    const target_token = token(request_owner, .file_write, 1);
    _ = try transport.prepareTarget(request_owner, target_token, 1, .{ .write = .{
        .file = handle,
        .bytes = "x",
        .offset = 0,
    } });
    try transport.markSubmitted(target_token);
    try std.testing.expectError(
        error.TransportFatal,
        transport.complete(completion(target_token, .{ .success = .{ .file_sync = {} } })),
    );
    try std.testing.expectEqual(
        @as(u32, 1),
        try transport.tableConst().references(handle, request_owner),
    );
    try std.testing.expectEqual(@as(u32, 1), transport.pendingTargets());
    try std.testing.expect(!transport.ownershipProven());
}
