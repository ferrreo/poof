const std = @import("std");

const gzip_decoder_pool = @import("decoder_pool.zig");

pub const Limits = gzip_decoder_pool.Limits;

pub const Error = error{
    InvalidRequest,
    InvalidOwner,
    PoolFailure,
    BodyFailure,
};

pub const AcquireResult = union(enum) {
    acquired: gzip_decoder_pool.Lease,
    exhausted,
};

pub const Output = struct {
    owner: gzip_decoder_pool.Owner,
    lease: gzip_decoder_pool.Lease,
    bytes: []const u8,
};

pub const Event = union(enum) {
    none,
    space: gzip_decoder_pool.Owner,
    terminal: struct {
        owner: gzip_decoder_pool.Owner,
        result: gzip_decoder_pool.Result,
        rejection: ?gzip_decoder_pool.OutputRejection,
    },
};

/// Acquires decoder ownership only after making the complete output region dirty.
pub fn acquire(
    storage: anytype,
    connection_index: u16,
    request_index: u16,
    limits: gzip_decoder_pool.Limits,
) Error!AcquireResult {
    const request = try liveRequest(storage, connection_index, request_index);
    if (request.gzip_lease != null or request.body.used != 0) return error.InvalidRequest;
    const output = storage.bodyWritable(request_index) catch return error.BodyFailure;
    if (limits.decoded_max > output.len) return error.InvalidRequest;
    const pool = storage.gzipPool() orelse return error.InvalidRequest;
    const owner = gzip_decoder_pool.Owner{
        .connection_index = connection_index,
        .request_index = request_index,
        .generation = request.generation,
    };
    const lease = pool.acquire(owner, output, limits) orelse return .exhausted;
    request.gzip_lease = lease;
    return .{ .acquired = lease };
}

/// Acquires a decoder whose bounded output is borrowed from its slot mailbox.
pub fn acquireStreaming(
    storage: anytype,
    connection_index: u16,
    request_index: u16,
    limits: gzip_decoder_pool.Limits,
) Error!AcquireResult {
    const request = try liveRequest(storage, connection_index, request_index);
    if (request.gzip_lease != null or request.body.used != 0) return error.InvalidRequest;
    const pool = storage.gzipPool() orelse return error.InvalidRequest;
    const owner = requestOwner(connection_index, request_index, request.generation);
    const lease = pool.acquireStreaming(owner, limits) orelse return .exhausted;
    request.gzip_lease = lease;
    return .{ .acquired = lease };
}

pub fn feed(
    storage: anytype,
    connection_index: u16,
    request_index: u16,
    bytes: []const u8,
) Error!FeedResult {
    const lease = try requestLease(storage, connection_index, request_index);
    const pool = storage.gzipPool() orelse return error.InvalidRequest;
    return switch (pool.feed(lease, bytes) catch |problem| return switch (problem) {
        error.JobTerminal => .written,
        else => error.PoolFailure,
    }) {
        .written => .written,
        .full => .full,
    };
}

pub const FeedResult = enum(u8) { written, full };

pub fn finish(
    storage: anytype,
    connection_index: u16,
    request_index: u16,
) Error!void {
    const lease = try requestLease(storage, connection_index, request_index);
    const pool = storage.gzipPool() orelse return error.InvalidRequest;
    pool.finish(lease) catch |problem| return switch (problem) {
        error.JobTerminal => {},
        else => error.PoolFailure,
    };
}

pub fn shouldPause(
    storage: anytype,
    connection_index: u16,
    request_index: u16,
) Error!bool {
    const lease = try requestLease(storage, connection_index, request_index);
    const pool = storage.gzipPool() orelse return error.InvalidRequest;
    return pool.shouldWaitForSpace(lease) catch |problem| return switch (problem) {
        error.JobTerminal => true,
        else => error.PoolFailure,
    };
}

pub fn cancel(
    storage: anytype,
    connection_index: u16,
    request_index: u16,
) Error!void {
    const lease = try requestLease(storage, connection_index, request_index);
    const pool = storage.gzipPool() orelse return error.InvalidRequest;
    pool.cancel(lease) catch return error.PoolFailure;
}

/// Returns a slot-owned borrowed chunk only after its output signal is consumed.
pub fn consumeOutput(
    storage: anytype,
    slot_index: u16,
    signals: gzip_decoder_pool.Signals,
) Error!?Output {
    if (!signals.output) return null;
    const pool = storage.gzipPool() orelse return error.InvalidRequest;
    const lease = pool.leaseAt(slot_index) orelse return error.InvalidOwner;
    const owner = pool.owner(lease) catch return error.PoolFailure;
    _ = try matchingRequest(storage, owner, lease);
    const bytes = (pool.output(lease) catch return error.PoolFailure) orelse return null;
    if (bytes.len == 0) return error.PoolFailure;
    return .{ .owner = owner, .lease = lease, .bytes = bytes };
}

/// Re-borrows a signaled streaming chunk retained across application I/O.
pub fn pendingOutput(
    storage: anytype,
    connection_index: u16,
    request_index: u16,
) Error!?Output {
    const lease = try requestLease(storage, connection_index, request_index);
    const pool = storage.gzipPool() orelse return error.InvalidRequest;
    const owner = pool.owner(lease) catch return error.PoolFailure;
    _ = try matchingRequest(storage, owner, lease);
    const bytes = (pool.output(lease) catch return error.PoolFailure) orelse return null;
    if (bytes.len == 0) return error.PoolFailure;
    return .{ .owner = owner, .lease = lease, .bytes = bytes };
}

pub fn acknowledgeOutput(storage: anytype, output: Output) Error!void {
    _ = try matchingRequest(storage, output.owner, output.lease);
    const pool = storage.gzipPool() orelse return error.InvalidRequest;
    pool.acknowledgeOutput(output.lease) catch return error.PoolFailure;
}

pub fn rejectOutput(
    storage: anytype,
    output: Output,
    rejection: gzip_decoder_pool.OutputRejection,
) Error!void {
    _ = try matchingRequest(storage, output.owner, output.lease);
    const pool = storage.gzipPool() orelse return error.InvalidRequest;
    pool.rejectOutput(output.lease, rejection) catch return error.PoolFailure;
}

/// Called only after the owning worker consumes the eventfd and swaps signal bytes.
pub fn consumeSlot(
    storage: anytype,
    slot_index: u16,
    signals: gzip_decoder_pool.Signals,
) Error!Event {
    if (!signals.space and !signals.terminal) return .none;
    const pool = storage.gzipPool() orelse return error.InvalidRequest;
    const lease = pool.leaseAt(slot_index) orelse return error.InvalidOwner;
    const owner = pool.owner(lease) catch return error.PoolFailure;
    const request = try matchingRequest(storage, owner, lease);
    if (signals.terminal) return consumeTerminal(storage, pool, request, owner, lease);
    const waiting = pool.shouldWaitForSpace(lease) catch |problem| return switch (problem) {
        error.JobTerminal => .none,
        else => error.PoolFailure,
    };
    return if (waiting) .none else .{ .space = owner };
}

fn consumeTerminal(
    storage: anytype,
    pool: anytype,
    request: anytype,
    owner: gzip_decoder_pool.Owner,
    lease: gzip_decoder_pool.Lease,
) Error!Event {
    const result = (pool.result(lease) catch return error.PoolFailure) orelse {
        return error.PoolFailure;
    };
    const rejection = pool.outputRejection(lease) catch return error.PoolFailure;
    switch (result) {
        .complete => |counts| {
            const Storage = @TypeOf(storage.*);
            if (!request.body.multipart) {
                if (request.body.used != 0 or
                    counts.decoded > Storage.body_workspace_bytes_per_slot)
                {
                    return error.BodyFailure;
                }
                storage.commitBody(owner.request_index, counts.decoded) catch {
                    return error.BodyFailure;
                };
            }
        },
        .malformed, .over_limit, .read_failed, .canceled => {},
    }
    pool.ack(lease) catch return error.PoolFailure;
    request.gzip_lease = null;
    return .{ .terminal = .{
        .owner = owner,
        .result = result,
        .rejection = rejection,
    } };
}

fn requestOwner(
    connection_index: u16,
    request_index: u16,
    generation: u16,
) gzip_decoder_pool.Owner {
    return .{
        .connection_index = connection_index,
        .request_index = request_index,
        .generation = generation,
    };
}

fn requestLease(
    storage: anytype,
    connection_index: u16,
    request_index: u16,
) Error!gzip_decoder_pool.Lease {
    const request = try liveRequest(storage, connection_index, request_index);
    return request.gzip_lease orelse error.InvalidRequest;
}

fn matchingRequest(
    storage: anytype,
    owner: gzip_decoder_pool.Owner,
    lease: gzip_decoder_pool.Lease,
) Error!@TypeOf(&storage.requests[0]) {
    const request = try liveRequest(storage, owner.connection_index, owner.request_index);
    if (@as(u32, request.generation) != owner.generation) return error.InvalidOwner;
    const held = request.gzip_lease orelse return error.InvalidOwner;
    if (held.index != lease.index or held.generation != lease.generation) {
        return error.InvalidOwner;
    }
    return request;
}

fn liveRequest(
    storage: anytype,
    connection_index: u16,
    request_index: u16,
) Error!@TypeOf(&storage.requests[0]) {
    if (connection_index >= storage.connections.len or request_index >= storage.requests.len) {
        return error.InvalidRequest;
    }
    const connection = &storage.connections[connection_index];
    const request = &storage.requests[request_index];
    if (request.phase != .live or request.connection_index != connection_index or
        connection.active_request != request_index)
    {
        return error.InvalidRequest;
    }
    return request;
}

const builtin = @import("builtin");
const config = @import("../config.zig");
const worker_storage = @import("../worker/storage.zig");

const stored_gzip = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03, 0x01, 0x0c,
    0x00, 0xf3, 0xff, 0x73, 0x74, 0x6f, 0x72, 0x65, 0x64, 0x2d, 0x62, 0x6c,
    0x6f, 0x63, 0x6b, 0x4a, 0xb0, 0xba, 0x81, 0x0c, 0x00, 0x00, 0x00,
};

const TestApp = struct {
    pub const Workspace = struct {};
    pub const body_workspace_bytes_max: u64 = 64;
};

const test_limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .body_workspace_slots = 1,
    .chunked_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 64,
    .pipeline_bytes_per_connection = 64,
    .response_bytes_per_request = 64,
    .submission_entries = 8,
    .completion_entries = 16,
    .gzip = .{
        .decoder_slots = 1,
        .input_chunks_per_slot = 2,
        .members_max = 2,
        .thread_stack_bytes = 128 * 1024,
    },
});

const TestStorage = worker_storage.Storage(TestApp, test_limits);
const TestPool = TestStorage.GzipDecoderPool;
const test_stack_size = if (builtin.sanitize_thread)
    std.Thread.SpawnConfig.default_stack_size
else
    test_limits.gzip.thread_stack_bytes;

test "gzip request terminal transaction retains lease until validated ack" {
    var slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined;
    var storage: TestStorage = undefined;
    try storage.init(&slab);
    @memset(storage.body_workspaces.storage, 0xaa);
    const pool = storage.gzipPool().?;
    try pool.start(test_stack_size);
    defer cleanStop(pool);

    const connection = storage.acquireConnection(.{ .value = 7 }).?;
    const request = acquiredRequest(storage.acquireRequestClassified(connection, 1, false));
    const lease = switch (try acquire(&storage, connection, request, .{
        .encoded_max = stored_gzip.len,
        .decoded_max = TestStorage.body_workspace_bytes_per_slot,
    })) {
        .acquired => |value| value,
        .exhausted => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        worker_storage.RequestReleaseIssue.gzip_decoder_active,
        storage.requestReleaseIssue(connection, request).?,
    );
    try std.testing.expectError(
        error.PoolFailure,
        consumeSlot(&storage, lease.index, .{ .terminal = true }),
    );
    try std.testing.expectEqual(
        @as(?gzip_decoder_pool.Lease, lease),
        storage.requests[request].gzip_lease,
    );

    try std.testing.expectEqual(
        FeedResult.written,
        try feed(&storage, connection, request, &stored_gzip),
    );
    try finish(&storage, connection, request);
    const signals = try waitSignals(pool, lease.index);
    try std.testing.expect(signals.terminal);

    const generation = storage.requests[request].generation;
    storage.requests[request].generation = std.math.add(u16, generation, 1) catch unreachable;
    try std.testing.expectError(
        error.InvalidOwner,
        consumeSlot(&storage, lease.index, signals),
    );
    try std.testing.expectEqual(
        @as(?gzip_decoder_pool.Lease, lease),
        storage.requests[request].gzip_lease,
    );
    storage.requests[request].generation = generation;

    const event = try consumeSlot(&storage, lease.index, signals);
    const terminal = switch (event) {
        .terminal => |value| value,
        .none, .space => return error.TestUnexpectedResult,
    };
    const counts = switch (terminal.result) {
        .complete => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(stored_gzip.len, counts.encoded);
    try std.testing.expectEqual(@as(usize, 1), counts.members);
    try std.testing.expectEqualStrings("stored-block", try storage.bodyReadable(request));
    try std.testing.expect(storage.requests[request].gzip_lease == null);
    try std.testing.expect(storage.requestReleaseIssue(connection, request) == null);

    storage.releaseRequest(connection, request);
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** "stored-block".len),
        storage.body_workspaces.storage[0.."stored-block".len],
    );
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0xaa} ** (64 - "stored-block".len)),
        storage.body_workspaces.storage["stored-block".len..],
    );
}

test "gzip request cancellation acknowledges before clearing request ownership" {
    var slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined;
    var storage: TestStorage = undefined;
    try storage.init(&slab);
    const pool = storage.gzipPool().?;
    try pool.start(test_stack_size);
    defer cleanStop(pool);

    const connection = storage.acquireConnection(.{ .value = 8 }).?;
    const request = acquiredRequest(storage.acquireRequestClassified(connection, 1, false));
    const lease = switch (try acquire(&storage, connection, request, .{
        .encoded_max = stored_gzip.len,
        .decoded_max = TestStorage.body_workspace_bytes_per_slot,
    })) {
        .acquired => |value| value,
        .exhausted => return error.TestUnexpectedResult,
    };
    try cancel(&storage, connection, request);
    const signals = try waitSignals(pool, lease.index);
    const event = try consumeSlot(&storage, lease.index, signals);
    const terminal = switch (event) {
        .terminal => |value| value,
        .none, .space => return error.TestUnexpectedResult,
    };
    try std.testing.expect(terminal.result == .canceled);
    try std.testing.expect(storage.requests[request].gzip_lease == null);
    storage.releaseRequest(connection, request);
}

test "gzip request streams borrowed output without committing body workspace" {
    var slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined;
    var storage: TestStorage = undefined;
    try storage.init(&slab);
    const pool = storage.gzipPool().?;
    try pool.start(test_stack_size);
    defer cleanStop(pool);

    const connection = storage.acquireConnection(.{ .value = 9 }).?;
    const request = acquiredRequest(storage.acquireRequestClassified(connection, 1, false));
    const lease = try acquireStreamingLease(&storage, connection, request);
    storage.requests[request].body.multipart = true;
    try std.testing.expectEqual(
        FeedResult.written,
        try feed(&storage, connection, request, &stored_gzip),
    );
    try finish(&storage, connection, request);

    const output = try waitOutput(&storage, pool, lease);
    try std.testing.expectEqualStrings("stored-block", output.bytes);
    try acknowledgeOutput(&storage, output);
    const terminal = try waitTerminal(&storage, pool, lease);
    try std.testing.expect(terminal.result == .complete);
    try std.testing.expect(terminal.rejection == null);
    try std.testing.expectEqual(@as(u32, 0), storage.requests[request].body.used);
    try std.testing.expect(storage.requests[request].gzip_lease == null);
    storage.releaseRequest(connection, request);
}

test "gzip request preserves parser rejection through terminal acknowledgement" {
    var slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined;
    var storage: TestStorage = undefined;
    try storage.init(&slab);
    const pool = storage.gzipPool().?;
    try pool.start(test_stack_size);
    defer cleanStop(pool);

    const connection = storage.acquireConnection(.{ .value = 10 }).?;
    const request = acquiredRequest(storage.acquireRequestClassified(connection, 1, false));
    const lease = try acquireStreamingLease(&storage, connection, request);
    storage.requests[request].body.multipart = true;
    _ = try feed(&storage, connection, request, &stored_gzip);
    try finish(&storage, connection, request);

    const output = try waitOutput(&storage, pool, lease);
    try acknowledgeOutput(&storage, output);
    try rejectOutput(&storage, output, .invalid_input);
    const terminal = try waitTerminal(&storage, pool, lease);
    try std.testing.expectEqual(
        gzip_decoder_pool.OutputRejection.invalid_input,
        terminal.rejection.?,
    );
    try std.testing.expect(storage.requests[request].gzip_lease == null);
    storage.releaseRequest(connection, request);
}

fn acquireStreamingLease(
    storage: *TestStorage,
    connection: u16,
    request: u16,
) !gzip_decoder_pool.Lease {
    return switch (try acquireStreaming(storage, connection, request, .{
        .encoded_max = stored_gzip.len,
        .decoded_max = TestStorage.body_workspace_bytes_per_slot,
    })) {
        .acquired => |lease| lease,
        .exhausted => error.TestUnexpectedResult,
    };
}

fn waitOutput(
    storage: *TestStorage,
    pool: *TestPool,
    lease: gzip_decoder_pool.Lease,
) !Output {
    while (true) {
        const signals = try waitSignals(pool, lease.index);
        if (try consumeOutput(storage, lease.index, signals)) |output| return output;
        switch (try consumeSlot(storage, lease.index, signals)) {
            .terminal => return error.TestUnexpectedResult,
            .none, .space => {},
        }
    }
}

fn waitTerminal(
    storage: *TestStorage,
    pool: *TestPool,
    lease: gzip_decoder_pool.Lease,
) !@FieldType(Event, "terminal") {
    while (true) {
        const signals = try waitSignals(pool, lease.index);
        const event = try consumeSlot(storage, lease.index, signals);
        switch (event) {
            .terminal => |terminal| return terminal,
            .none, .space => {},
        }
    }
}

fn acquiredRequest(result: worker_storage.AcquireResult) u16 {
    return switch (result) {
        .acquired => |index| index,
        else => @panic("gzip request test workspace acquisition failed"),
    };
}

fn waitSignals(pool: *TestPool, slot_index: u16) !gzip_decoder_pool.Signals {
    var descriptors = [1]std.os.linux.pollfd{.{
        .fd = pool.wakeDescriptor(),
        .events = std.os.linux.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        const count = std.os.linux.poll(&descriptors, descriptors.len, 5_000);
        if (std.os.linux.errno(count) != .SUCCESS or count != 1) {
            return error.TestUnexpectedResult;
        }
        if (descriptors[0].revents & std.os.linux.POLL.IN == 0) {
            return error.TestUnexpectedResult;
        }
        const batch = switch (pool.consumeWake()) {
            .consumed => |value| value,
            .failed => return error.TestUnexpectedResult,
        };
        const signals = batch.slots[slot_index];
        if (signals.space or signals.output or signals.terminal) return signals;
    }
}

fn cleanStop(pool: *TestPool) void {
    if (pool.lifecycleStatus() == .running and pool.beginStop() != null) {
        @panic("gzip request test pool join failed");
    }
    if (pool.lifecycleStatus() != .quiesced) return;
    if (pool.wake_descriptor_exposed and !pool.wake_poll_retired) {
        pool.retireWakePoll() catch @panic("gzip request test poll retirement failed");
    }
    if ((pool.finishStop() catch @panic("gzip request test close state failed")) != null) {
        @panic("gzip request test counter close failed");
    }
}
