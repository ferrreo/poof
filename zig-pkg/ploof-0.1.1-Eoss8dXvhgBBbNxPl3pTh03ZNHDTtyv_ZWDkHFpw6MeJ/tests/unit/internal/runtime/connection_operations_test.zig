const std = @import("std");
const connection_operations = @import("../../../../src/internal/runtime/connection/operations.zig");
const deterministic_reactor = @import("../../../../src/internal/runtime/deterministic_reactor.zig");
const reactor = @import("../../../../src/internal/runtime/reactor.zig");

const TestError = error{
    BackendFailure,
    ClockOverflow,
    StateInvariant,
};

const TestConnection = struct {
    const ReceiveFlags = struct {
        timeout_extended: bool = false,
    };

    timeout_token: ?reactor.OperationToken = null,
    timeout_deadline_ns: u64 = 0,
    receive_flags: ReceiveFlags = .{},
    inflight_operations: u16 = 0,
    generation: u16 = 1,
    sequence: u16 = 1,
};

const TestStorage = struct {
    connections: [1]TestConnection = .{.{}},
};

const TestReactor = deterministic_reactor.DeterministicReactor(8);
const TestOperations = connection_operations.Operations(
    TestStorage,
    TestReactor,
    TestError,
);

test "timeout retarget reuses extensions and replaces arbitrary shortenings" {
    var io = TestReactor{};
    var storage = TestStorage{};
    const operations = TestOperations.init(&io, 0);
    try operations.submitTimeoutAt(&storage, 0, 100);
    const first = storage.connections[0].timeout_token.?;

    try operations.retargetTimeout(&storage, 0, 50, 100);
    try std.testing.expect(storage.connections[0].timeout_token.?.eql(first));
    try std.testing.expectEqual(@as(u64, 150), storage.connections[0].timeout_deadline_ns);
    try std.testing.expectEqual(@as(u16, 1), io.activeCount());
    try std.testing.expectEqual(@as(u64, 100), io.operation(first).?.timeout.deadline_ns);

    try operations.retargetTimeout(&storage, 0, 60, 20);
    const shortened = storage.connections[0].timeout_token.?;
    try std.testing.expect(!shortened.eql(first));
    try std.testing.expectEqual(@as(u64, 80), storage.connections[0].timeout_deadline_ns);
    try std.testing.expectEqual(@as(u64, 80), io.operation(shortened).?.timeout.deadline_ns);
    try std.testing.expectEqual(@as(u16, 3), io.activeCount());
}

test "connection sequence wrap skips a retained identical raw token" {
    var io = TestReactor{};
    var storage = TestStorage{};
    const operations = TestOperations.init(&io, 0);
    storage.connections[0].sequence = reactor.max_sequence;
    try operations.submitTimeoutAt(&storage, 0, 100);
    const retained = storage.connections[0].timeout_token.?;
    try std.testing.expectEqual(
        reactor.max_sequence,
        (try retained.fields()).sequence,
    );

    // Models 32,766 intervening terminal operations while this timeout stays active.
    storage.connections[0].sequence = reactor.max_sequence;
    try operations.submitTimeoutAt(&storage, 0, 200);
    const current = storage.connections[0].timeout_token.?;
    try std.testing.expect(!current.eql(retained));
    try std.testing.expectEqual(@as(u16, 1), (try current.fields()).sequence);
    try std.testing.expectEqual(@as(u16, 2), storage.connections[0].sequence);
    try std.testing.expectEqual(@as(u16, 2), io.activeCount());
}
