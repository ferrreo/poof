const std = @import("std");
const upload_io = @import("../../src/upload_io.zig");
const file_table = @import("../../src/internal/runtime/upload/file_table.zig");
const reactor = @import("../../src/internal/runtime/reactor.zig");

const Owner = file_table.Owner;
const runtime_owner = Owner{
    .scope = .runtime,
    .registry_index = 7,
    .instance_index = 0,
    .slot = .{ .worker_index = 1, .index = 100, .generation = 2 },
};
const request_owner = Owner{
    .scope = .request,
    .registry_index = 7,
    .instance_index = 3,
    .slot = .{ .worker_index = 1, .index = 10, .generation = 4 },
};
const sibling_owner = Owner{
    .scope = .request,
    .registry_index = 7,
    .instance_index = 4,
    .slot = .{ .worker_index = 1, .index = 10, .generation = 4 },
};
const cross_request_owner = Owner{
    .scope = .request,
    .registry_index = 7,
    .instance_index = 3,
    .slot = .{ .worker_index = 1, .index = 11, .generation = 4 },
};
const other_registry_owner = Owner{
    .scope = .request,
    .registry_index = 8,
    .instance_index = 3,
    .slot = .{ .worker_index = 1, .index = 10, .generation = 4 },
};
const other_worker_owner = Owner{
    .scope = .request,
    .registry_index = 7,
    .instance_index = 3,
    .slot = .{ .worker_index = 2, .index = 10, .generation = 4 },
};

fn open(
    table: anytype,
    owner: Owner,
    fd: i32,
    kind: upload_io.OpenKind,
    access: upload_io.Access,
) !upload_io.FileHandle {
    return openCreated(table, owner, fd, kind, access, .none);
}

fn openCreated(
    table: anytype,
    owner: Owner,
    fd: i32,
    kind: upload_io.OpenKind,
    access: upload_io.Access,
    create: upload_io.Create,
) !upload_io.FileHandle {
    const handle = if (create == .exclusive)
        try table.reserveOpenAt(owner, .working_directory, "fixture")
    else
        try table.reserveOpen(owner);
    try table.completeOpenPositive(
        handle,
        owner,
        fd,
        kind,
        access,
        create,
    );
    return handle;
}

test "maximum table capacity includes every u16 index" {
    const Table = file_table.Table(@as(usize, std.math.maxInt(u16)) + 1, 0);
    var table = Table{};
    try std.testing.expectEqual(@as(u32, 65_536), table.available());
}

test "zero-capacity table remains a bounded empty table" {
    const Table = file_table.Table(0, 0);
    var table = Table{};
    try std.testing.expectError(error.Full, table.reserveOpen(request_owner));
    var cursor = file_table.CleanupCursor{};
    try std.testing.expect(table.nextCleanup(&cursor) == null);
}

test "open reservation is bounded and rollback advances generation" {
    const Table = file_table.Table(2, 0);
    var table = Table{};
    const first = try table.reserveOpen(request_owner);
    const second = try table.reserveOpen(runtime_owner);

    try std.testing.expectEqual(@as(u16, 0), first.index());
    try std.testing.expectEqual(@as(u16, 1), second.index());
    try std.testing.expectError(error.Full, table.reserveOpen(request_owner));
    try std.testing.expectEqual(@as(u32, 2), table.active());
    try table.rollbackOpen(first, request_owner);
    try std.testing.expectEqual(@as(u32, 1), table.available());

    const reused = try table.reserveOpen(request_owner);
    try std.testing.expectEqual(first.index(), reused.index());
    try std.testing.expectEqual(@as(u16, 2), reused.generation());
    try std.testing.expectError(error.StaleGeneration, table.phase(first));
    try std.testing.expectError(error.WrongOwner, table.rollbackOpen(reused, sibling_owner));
    try table.completeOpenFailure(reused, request_owner);
    try table.completeOpenFailure(second, runtime_owner);
    try std.testing.expectEqual(@as(u32, 0), table.active());
}

test "slot generations wrap without producing zero" {
    const Table = file_table.Table(1, 0);
    var table = Table{};
    var handle = try table.reserveOpen(request_owner);

    for (0..std.math.maxInt(u16) - 1) |_| {
        try table.completeOpenFailure(handle, request_owner);
        handle = try table.reserveOpen(request_owner);
    }
    try std.testing.expectEqual(std.math.maxInt(u16), handle.generation());
    try table.completeOpenFailure(handle, request_owner);
    handle = try table.reserveOpen(request_owner);
    try std.testing.expectEqual(@as(u16, 1), handle.generation());
}

test "nonwrapping incarnations distinguish a recycled base after generation wrap" {
    const Table = file_table.Table(2, 1);
    var table = Table{};
    const original = try open(&table, runtime_owner, 14, .directory, .read_only);
    const original_incarnation = try table.incarnation(original);
    const source = try table.reserveOpenAt(
        request_owner,
        .{ .handle = original },
        ".ploof-upload-source",
    );
    try table.completeOpenPositive(
        source,
        request_owner,
        15,
        .file,
        .write_only,
        .exclusive,
    );
    _ = try table.beginClose(original, runtime_owner);
    try table.completeClose(original, runtime_owner, .closed);

    var replacement = try open(&table, runtime_owner, 16, .directory, .read_only);
    for (0..std.math.maxInt(u16) - 1) |_| {
        _ = try table.beginClose(replacement, runtime_owner);
        try table.completeClose(replacement, runtime_owner, .closed);
        replacement = try open(&table, runtime_owner, 16, .directory, .read_only);
    }
    try std.testing.expect(replacement.eql(original));
    try std.testing.expect(original_incarnation != try table.incarnation(replacement));

    try std.testing.expectError(error.WrongOpenIdentity, table.borrowOpenedAt(
        source,
        request_owner,
        .{ .kind = .file, .access = .write_only, .create = .exclusive },
        .{ .handle = replacement },
        ".ploof-upload-source",
    ));
    try std.testing.expectEqual(@as(u32, 0), try table.references(source, request_owner));
}

test "incarnation exhaustion fails before wrap without consuming a slot" {
    const Table = file_table.Table(1, 0);
    var table = Table{};
    table.incarnation_cursor = std.math.maxInt(u64) - 1;

    const last = try table.reserveOpen(request_owner);
    try std.testing.expectEqual(std.math.maxInt(u64), try table.incarnation(last));
    try table.rollbackOpen(last, request_owner);
    try std.testing.expectError(error.IncarnationExhausted, table.reserveOpen(request_owner));
    try std.testing.expectEqual(@as(u32, 0), table.active());
    try std.testing.expectEqual(@as(u32, 1), table.available());
}

test "exclusive reservation marker and provenance stay compact" {
    const Table = file_table.Table(2, 0);
    var table = Table{};
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(file_table.OpenIdentity));
    try std.testing.expectEqual(@as(usize, 64), Table.entry_bytes);

    const ordinary = try table.reserveOpen(request_owner);
    try std.testing.expectError(error.InvalidOpenIdentity, table.completeOpenPositive(
        ordinary,
        request_owner,
        17,
        .file,
        .write_only,
        .exclusive,
    ));
    const exclusive = try table.reserveOpenAt(request_owner, .working_directory, "stage");
    try std.testing.expectError(error.InvalidOpenIdentity, table.completeOpenPositive(
        exclusive,
        request_owner,
        18,
        .file,
        .write_only,
        .none,
    ));
    try table.rollbackOpen(exclusive, request_owner);
    try table.rollbackOpen(ordinary, request_owner);
    try std.testing.expectEqual(@as(u32, 0), table.active());
}

test "owners are exact except same-registry runtime directories" {
    const Table = file_table.Table(3, 2);
    var table = Table{};
    const request_file = try open(&table, request_owner, 20, .file, .read_write);
    const runtime_file = try open(&table, runtime_owner, 21, .file, .read_write);
    const runtime_directory = try open(&table, runtime_owner, 22, .directory, .read_only);
    const file_requirement = file_table.Requirement{ .kind = .file, .access = .read_only };
    const directory_requirement = file_table.Requirement{
        .kind = .directory,
        .access = .read_only,
    };

    const request_borrow = try table.borrow(request_file, request_owner, file_requirement);
    try table.releaseBorrow(request_borrow.lease, request_owner);
    try std.testing.expectError(
        error.WrongOwner,
        table.borrow(request_file, sibling_owner, file_requirement),
    );
    try std.testing.expectError(
        error.WrongOwner,
        table.borrow(request_file, cross_request_owner, file_requirement),
    );
    try std.testing.expectError(
        error.WrongOwner,
        table.borrow(runtime_file, request_owner, file_requirement),
    );

    const borrowed = try table.borrow(runtime_directory, request_owner, directory_requirement);
    try std.testing.expectEqual(@as(i32, 22), borrowed.descriptor.raw_fd);
    try std.testing.expectError(
        error.WrongOwner,
        table.releaseBorrow(borrowed.lease, sibling_owner),
    );
    try std.testing.expectEqual(
        @as(u32, 1),
        try table.references(runtime_directory, runtime_owner),
    );
    const sibling_borrow = try table.borrow(
        runtime_directory,
        sibling_owner,
        directory_requirement,
    );
    try std.testing.expectEqual(
        @as(u32, 2),
        try table.references(runtime_directory, runtime_owner),
    );
    try table.releaseBorrow(sibling_borrow.lease, sibling_owner);
    try table.releaseBorrow(borrowed.lease, request_owner);
    try std.testing.expectError(
        error.WrongOwner,
        table.borrow(runtime_directory, other_registry_owner, directory_requirement),
    );
    try std.testing.expectError(
        error.WrongOwner,
        table.borrow(runtime_directory, other_worker_owner, directory_requirement),
    );
    const invalid_borrower = Owner{
        .scope = .request,
        .registry_index = runtime_owner.registry_index,
        .instance_index = 9,
        .slot = .{ .worker_index = 1, .index = 12, .generation = 0 },
    };
    try std.testing.expectError(
        error.InvalidOwner,
        table.borrow(runtime_directory, invalid_borrower, directory_requirement),
    );
}

test "lease pool is bounded and reuse rejects malformed double and stale leases" {
    const Table = file_table.Table(1, 1);
    var table = Table{};
    const handle = try open(&table, request_owner, 25, .file, .read_only);
    const requirement = file_table.Requirement{ .kind = .file, .access = .read_only };
    const first = try table.borrow(handle, request_owner, requirement);

    try std.testing.expectError(error.Full, table.borrow(handle, request_owner, requirement));
    try std.testing.expectEqual(@as(u32, 1), try table.references(handle, request_owner));
    const malformed: Table.Lease = @enumFromInt(0);
    try std.testing.expectError(
        error.InvalidLease,
        table.releaseBorrow(malformed, request_owner),
    );
    const out_of_range: Table.Lease = @enumFromInt((@as(u64, 1) << 32) | 1);
    try std.testing.expectError(
        error.InvalidLease,
        table.releaseBorrow(out_of_range, request_owner),
    );
    try std.testing.expectEqual(@as(u32, 1), try table.references(handle, request_owner));
    try table.releaseBorrow(first.lease, request_owner);
    try std.testing.expectError(
        error.StaleLease,
        table.releaseBorrow(first.lease, request_owner),
    );

    const reused = try table.borrow(handle, request_owner, requirement);
    try std.testing.expectError(
        error.StaleLease,
        table.releaseBorrow(first.lease, request_owner),
    );
    try std.testing.expectEqual(@as(u32, 1), try table.references(handle, request_owner));
    try table.releaseBorrow(reused.lease, request_owner);
}

test "anonymous creation requirement rejects named files and survives cleanup" {
    const Table = file_table.Table(3, 1);
    var table = Table{};
    const existing = try open(&table, request_owner, 26, .file, .read_write);
    const named = try openCreated(
        &table,
        request_owner,
        27,
        .file,
        .read_write,
        .exclusive,
    );
    const anonymous = try openCreated(
        &table,
        request_owner,
        28,
        .file,
        .read_write,
        .anonymous,
    );
    const publish = file_table.Requirement{
        .kind = .file,
        .access = .read_only,
        .create = .anonymous,
    };

    try std.testing.expectError(
        error.WrongCreation,
        table.borrow(existing, request_owner, publish),
    );
    try std.testing.expectError(
        error.WrongCreation,
        table.borrow(named, request_owner, publish),
    );
    try std.testing.expectEqual(@as(u32, 0), try table.references(existing, request_owner));
    try std.testing.expectEqual(@as(u32, 0), try table.references(named, request_owner));
    const borrowed = try table.borrow(anonymous, request_owner, publish);
    try std.testing.expectEqual(upload_io.Create.anonymous, borrowed.descriptor.create);
    try table.releaseBorrow(borrowed.lease, request_owner);

    var cursor = file_table.CleanupCursor{};
    try std.testing.expectEqual(
        upload_io.Create.none,
        table.nextCleanup(&cursor).?.descriptor.?.create,
    );
    try std.testing.expectEqual(
        upload_io.Create.exclusive,
        table.nextCleanup(&cursor).?.descriptor.?.create,
    );
    try std.testing.expectEqual(
        upload_io.Create.anonymous,
        table.nextCleanup(&cursor).?.descriptor.?.create,
    );
}

test "exclusive file borrow requires its exact retained open identity" {
    const Table = file_table.Table(3, 1);
    var table = Table{};
    const directory = try open(&table, runtime_owner, 29, .directory, .read_only);
    const other_directory = try open(&table, runtime_owner, 30, .directory, .read_only);
    const named = try table.reserveOpenAt(
        request_owner,
        .{ .handle = directory },
        ".ploof-upload-a",
    );
    try table.completeOpenPositive(
        named,
        request_owner,
        31,
        .file,
        .write_only,
        .exclusive,
    );
    const requirement = file_table.Requirement{
        .kind = .file,
        .access = .write_only,
        .create = .exclusive,
    };

    try std.testing.expectError(error.WrongOpenIdentity, table.borrowOpenedAt(
        named,
        request_owner,
        requirement,
        .{ .handle = directory },
        ".ploof-upload-b",
    ));
    try std.testing.expectError(error.WrongOpenIdentity, table.borrowOpenedAt(
        named,
        request_owner,
        requirement,
        .{ .handle = other_directory },
        ".ploof-upload-a",
    ));
    try std.testing.expectEqual(@as(u32, 0), try table.references(named, request_owner));

    const borrowed = try table.borrowOpenedAt(
        named,
        request_owner,
        requirement,
        .{ .handle = directory },
        ".ploof-upload-a",
    );
    try table.releaseBorrow(borrowed.lease, request_owner);
}

test "only an exclusive requirement may borrow retained open identity" {
    const Table = file_table.Table(3, 1);
    var table = Table{};
    const directory = try open(&table, runtime_owner, 32, .directory, .read_only);
    const ordinary = try open(&table, request_owner, 33, .file, .write_only);
    const exclusive = try table.reserveOpenAt(
        request_owner,
        .{ .handle = directory },
        ".ploof-upload-source",
    );
    try table.completeOpenPositive(
        exclusive,
        request_owner,
        34,
        .file,
        .write_only,
        .exclusive,
    );

    inline for (.{
        file_table.Requirement{ .kind = .file, .access = .write_only },
        file_table.Requirement{
            .kind = .file,
            .access = .write_only,
            .create = .none,
        },
    }) |requirement| {
        try std.testing.expectError(error.InvalidOpenIdentity, table.borrowOpenedAt(
            ordinary,
            request_owner,
            requirement,
            .{ .handle = directory },
            ".ploof-upload-source",
        ));
    }
    try std.testing.expectEqual(@as(u32, 0), try table.references(ordinary, request_owner));
    try std.testing.expectEqual(@as(u32, 0), try table.references(directory, runtime_owner));

    const borrowed = try table.borrowOpenedAt(
        exclusive,
        request_owner,
        .{ .kind = .file, .access = .write_only, .create = .exclusive },
        .{ .handle = directory },
        ".ploof-upload-source",
    );
    try std.testing.expectEqual(@as(u32, 1), try table.references(exclusive, request_owner));
    try table.releaseBorrow(borrowed.lease, request_owner);
}

test "kind and access requirements cannot exceed descriptor authority" {
    const Table = file_table.Table(3, 1);
    var table = Table{};
    const read_file = try open(&table, request_owner, 30, .file, .read_only);
    const write_file = try open(&table, request_owner, 31, .file, .write_only);
    const both_file = try open(&table, request_owner, 32, .file, .read_write);

    try std.testing.expectError(error.WrongKind, table.borrow(read_file, request_owner, .{
        .kind = .directory,
        .access = .read_only,
    }));
    try std.testing.expectError(error.AccessDenied, table.borrow(read_file, request_owner, .{
        .kind = .file,
        .access = .write_only,
    }));
    try std.testing.expectError(error.AccessDenied, table.borrow(write_file, request_owner, .{
        .kind = .file,
        .access = .read_only,
    }));
    const borrowed = try table.borrow(both_file, request_owner, .{
        .kind = .file,
        .access = .read_write,
    });
    try table.releaseBorrow(borrowed.lease, request_owner);
}

test "references block close and canceled close restores open phase" {
    const Table = file_table.Table(1, 1);
    var table = Table{};
    const handle = try open(&table, request_owner, 40, .file, .write_only);
    const borrowed = try table.borrow(handle, request_owner, .{
        .kind = .file,
        .access = .write_only,
    });
    try std.testing.expectEqual(@as(i32, 40), borrowed.descriptor.raw_fd);
    try std.testing.expectEqual(@as(u32, 1), try table.references(handle, request_owner));
    try std.testing.expectError(error.Busy, table.beginClose(handle, request_owner));
    try table.releaseBorrow(borrowed.lease, request_owner);

    _ = try table.beginClose(handle, request_owner);
    try table.completeClose(handle, request_owner, .canceled);
    try std.testing.expectEqual(file_table.Phase.open, try table.phase(handle));
    _ = try table.beginClose(handle, request_owner);
    try table.completeClose(handle, request_owner, .closed);
    try std.testing.expectError(error.StaleGeneration, table.phase(handle));
}

test "positive open remains discoverable after upper rejection" {
    const Table = file_table.Table(1, 0);
    var table = Table{};
    const handle = try table.reserveOpen(request_owner);
    try table.completeOpenPositive(
        handle,
        request_owner,
        50,
        .file,
        .read_only,
        .none,
    );
    try std.testing.expectError(error.AccessDenied, table.borrow(handle, request_owner, .{
        .kind = .file,
        .access = .write_only,
    }));

    var cursor = file_table.CleanupCursor{};
    const retained = table.nextCleanup(&cursor).?;
    try std.testing.expect(retained.handle.eql(handle));
    try std.testing.expectEqual(@as(i32, 50), retained.descriptor.?.raw_fd);
    try std.testing.expect(table.nextCleanup(&cursor) == null);
}

test "uncertain close poisons reuse and retains exact cleanup identity" {
    const Table = file_table.Table(1, 0);
    var table = Table{};
    const handle = try open(&table, request_owner, 60, .file, .read_write);
    _ = try table.beginClose(handle, request_owner);
    try table.completeClose(handle, request_owner, .uncertain);

    try std.testing.expect(!table.ownershipProven());
    try std.testing.expectEqual(file_table.Phase.ownership_unproven, try table.phase(handle));
    try std.testing.expectError(error.OwnershipUnproven, table.reserveOpen(request_owner));
    var cursor = file_table.CleanupCursor{};
    const retained = table.nextCleanup(&cursor).?;
    try std.testing.expectEqual(request_owner, retained.owner);
    try std.testing.expectEqual(@as(i32, 60), retained.descriptor.?.raw_fd);
}

test "cleanup enumeration is stable in ascending slot order" {
    const Table = file_table.Table(3, 0);
    var table = Table{};
    const first = try open(&table, request_owner, 70, .file, .read_only);
    const rolled_back = try table.reserveOpen(request_owner);
    const third = try table.reserveOpen(runtime_owner);
    try table.rollbackOpen(rolled_back, request_owner);
    const second = try table.reserveOpen(request_owner);

    var cursor = file_table.CleanupCursor{};
    const entries = [_]file_table.CleanupEntry{
        table.nextCleanup(&cursor).?,
        table.nextCleanup(&cursor).?,
        table.nextCleanup(&cursor).?,
    };
    try std.testing.expectEqual(@as(u16, 0), entries[0].handle.index());
    try std.testing.expectEqual(@as(u16, 1), entries[1].handle.index());
    try std.testing.expectEqual(@as(u16, 2), entries[2].handle.index());
    try std.testing.expect(entries[0].handle.eql(first));
    try std.testing.expect(entries[1].handle.eql(second));
    try std.testing.expect(entries[2].handle.eql(third));
    try std.testing.expect(entries[1].descriptor == null);
    try std.testing.expectEqual(file_table.Phase.opening, entries[1].phase);
    try std.testing.expect(table.nextCleanup(&cursor) == null);
}

test "invalid owners and descriptors do not consume reservations" {
    const Table = file_table.Table(1, 0);
    var table = Table{};
    const invalid_owner = Owner{
        .scope = .request,
        .registry_index = 1,
        .instance_index = 1,
        .slot = .{ .worker_index = reactor.max_worker_index + 1, .index = 0, .generation = 1 },
    };
    try std.testing.expectError(error.InvalidOwner, table.reserveOpen(invalid_owner));
    const handle = try table.reserveOpen(request_owner);
    try std.testing.expectError(
        error.InvalidDescriptor,
        table.completeOpenPositive(
            handle,
            request_owner,
            -1,
            .file,
            .read_only,
            .none,
        ),
    );
    try std.testing.expectEqual(file_table.Phase.opening, try table.phase(handle));
}
