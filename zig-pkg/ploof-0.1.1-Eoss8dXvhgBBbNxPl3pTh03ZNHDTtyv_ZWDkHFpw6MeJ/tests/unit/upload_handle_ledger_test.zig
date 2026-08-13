const std = @import("std");
const upload_io = @import("../../src/upload_io.zig");
const upload_handle_ledger = @import("../../src/internal/upload/handle_ledger.zig");

const Owner = struct {
    request: u16,
    sink: u8,
};

const owner_a = Owner{ .request = 3, .sink = 1 };
const owner_b = Owner{ .request = 4, .sink = 2 };

test "handle ledger retains exact owners and rejects duplicate slots" {
    const Ledger = upload_handle_ledger.Ledger(Owner, 2, 1);
    const first = upload_io.FileHandle.fromParts(7, 1);
    const second = upload_io.FileHandle.fromParts(8, 4);
    const full = upload_io.FileHandle.fromParts(9, 1);
    var ledger = Ledger{};

    try ledger.recordOpen(first, owner_a);
    try ledger.recordOpen(second, owner_b);
    try std.testing.expectEqual(owner_a, try ledger.owner(first));
    try std.testing.expectEqual(upload_handle_ledger.Phase.open, try ledger.phase(
        first,
        owner_a,
    ));
    try std.testing.expectError(error.Duplicate, ledger.recordOpen(first, owner_a));
    try std.testing.expectError(
        error.Duplicate,
        ledger.recordOpen(upload_io.FileHandle.fromParts(7, 2), owner_a),
    );
    try std.testing.expectError(error.Full, ledger.recordOpen(full, owner_a));
    try std.testing.expectError(error.Unknown, ledger.owner(full));
    try std.testing.expect(ledger.ownershipProven());
    try std.testing.expectEqual(@as(usize, 2), ledger.expectedCount());
}

test "expected close transitions preserve generation ownership" {
    const Ledger = upload_handle_ledger.Ledger(Owner, 1, 0);
    const first = upload_io.FileHandle.fromParts(5, 1);
    const reused = upload_io.FileHandle.fromParts(5, 2);
    var ledger = Ledger{};
    try ledger.recordOpen(first, owner_a);

    try std.testing.expectError(error.WrongOwner, ledger.beginClose(first, owner_b));
    try ledger.beginClose(first, owner_a);
    try std.testing.expectEqual(upload_handle_ledger.Phase.closing, try ledger.phase(
        first,
        owner_a,
    ));
    try std.testing.expectError(error.AlreadyClosing, ledger.beginClose(first, owner_a));
    try ledger.rollbackClose(first, owner_a);
    try std.testing.expectError(error.NotClosing, ledger.rollbackClose(first, owner_a));
    try ledger.beginClose(first, owner_a);
    try ledger.completeClose(first, owner_a, .closed);

    try std.testing.expectError(error.Unknown, ledger.owner(first));
    try ledger.recordOpen(reused, owner_b);
    try std.testing.expectError(error.Unknown, ledger.phase(first, owner_a));
    try std.testing.expectEqual(owner_b, try ledger.owner(reused));
    try std.testing.expect(ledger.ownershipProven());
}

test "valid overflow is atomically retained in bounded emergency slots" {
    const Ledger = upload_handle_ledger.Ledger(Owner, 0, 1);
    const handle = upload_io.FileHandle.fromParts(12, 9);
    var ledger = Ledger{};

    const recorded = try ledger.recordOpenOrEmergency(handle, owner_a);
    const emergency = recorded.emergency;
    try std.testing.expect(emergency.valid());
    try std.testing.expect((try ledger.emergencyObserved(emergency)).eql(handle));
    try std.testing.expectEqual(
        upload_handle_ledger.EmergencyReason.unexpected_open,
        try ledger.emergencyReason(emergency),
    );
    try std.testing.expectEqual(upload_handle_ledger.Phase.open, try ledger.emergencyPhase(
        emergency,
        owner_a,
    ));
    try std.testing.expectEqual(@as(usize, 0), ledger.expectedCount());
    try std.testing.expectEqual(@as(usize, 1), ledger.emergencyCount());
    try std.testing.expect(ledger.ownershipProven());

    const overflow = upload_io.FileHandle.fromParts(13, 1);
    try std.testing.expectError(
        error.Full,
        ledger.recordOpenOrEmergency(overflow, owner_b),
    );
    try std.testing.expect(!ledger.ownershipProven());
}

test "duplicate logical handle never consumes an emergency slot" {
    const Ledger = upload_handle_ledger.Ledger(Owner, 1, 2);
    const handle = upload_io.FileHandle.fromParts(12, 9);
    var ledger = Ledger{};
    try ledger.recordOpen(handle, owner_a);

    try std.testing.expectError(
        error.Duplicate,
        ledger.recordOpenOrEmergency(handle, owner_b),
    );
    try std.testing.expectEqual(@as(usize, 1), ledger.expectedCount());
    try std.testing.expectEqual(@as(usize, 0), ledger.emergencyCount());
    try std.testing.expect(!ledger.ownershipProven());
}

test "malformed open retention is bounded but ownership is unproven" {
    const Ledger = upload_handle_ledger.Ledger(Owner, 1, 1);
    const malformed = upload_io.FileHandle.fromParts(2, 0);
    var ledger = Ledger{};

    try std.testing.expectError(
        error.InvalidHandle,
        ledger.recordOpen(malformed, owner_a),
    );
    try std.testing.expect(ledger.ownershipProven());
    const recorded = try ledger.recordOpenOrEmergency(malformed, owner_a);
    const emergency = recorded.emergency;
    try std.testing.expectEqual(
        upload_handle_ledger.EmergencyReason.malformed_open,
        try ledger.emergencyReason(emergency),
    );
    try std.testing.expect(!(try ledger.emergencyObserved(emergency)).valid());
    try std.testing.expect(!ledger.ownershipProven());
}

test "emergency close uses exact owner and generation" {
    const Ledger = upload_handle_ledger.Ledger(Owner, 0, 1);
    const observed = upload_io.FileHandle.fromParts(20, 3);
    var ledger = Ledger{};
    const first = (try ledger.recordOpenOrEmergency(observed, owner_a)).emergency;

    try std.testing.expectError(
        error.WrongOwner,
        ledger.beginEmergencyClose(first, owner_b),
    );
    try ledger.beginEmergencyClose(first, owner_a);
    try std.testing.expectError(
        error.AlreadyClosing,
        ledger.beginEmergencyClose(first, owner_a),
    );
    try ledger.rollbackEmergencyClose(first, owner_a);
    try std.testing.expectError(
        error.NotClosing,
        ledger.rollbackEmergencyClose(first, owner_a),
    );
    try ledger.beginEmergencyClose(first, owner_a);
    try ledger.completeEmergencyClose(first, owner_a, .closed);
    try std.testing.expectError(error.Unknown, ledger.emergencyReason(first));

    const second = (try ledger.recordOpenOrEmergency(observed, owner_b)).emergency;
    try std.testing.expect(!first.eql(second));
    try ledger.beginEmergencyClose(second, owner_b);
    try ledger.completeEmergencyClose(second, owner_b, .uncertain);
    try std.testing.expect(!ledger.ownershipProven());
    try std.testing.expectEqual(upload_handle_ledger.Phase.closing, try ledger.emergencyPhase(
        second,
        owner_b,
    ));
}

test "expected uncertain close is the only ordinary proof loss" {
    const Ledger = upload_handle_ledger.Ledger(Owner, 1, 1);
    const handle = upload_io.FileHandle.init(2);
    var ledger = Ledger{};
    try ledger.recordOpen(handle, owner_a);

    try std.testing.expectError(error.Unknown, ledger.owner(upload_io.FileHandle.init(3)));
    try std.testing.expectError(error.WrongOwner, ledger.beginClose(handle, owner_b));
    try std.testing.expect(ledger.ownershipProven());
    try ledger.beginClose(handle, owner_a);
    try ledger.completeClose(handle, owner_a, .uncertain);
    try std.testing.expect(!ledger.ownershipProven());
    try std.testing.expectEqual(upload_handle_ledger.Phase.closing, try ledger.phase(
        handle,
        owner_a,
    ));
}
