const source = @import("gzip_decoder_pool_test.zig");
const std = source.std;
const builtin = source.builtin;
const event_counter = source.event_counter;
const futex_epoch = source.futex_epoch;
const gzip_input_queue = source.gzip_input_queue;
const pool_module = source.pool_module;
const fixture = source.fixture;
const Pool = source.Pool;
const SmallPool = source.SmallPool;
const MemberPool = source.MemberPool;
const StreamingPool = source.StreamingPool;
const SingleStreamingPool = source.SingleStreamingPool;
const stack_size = source.stack_size;
const waitBlockedOutput = source.waitBlockedOutput;
const runRejected = source.runRejected;
const feedFragmented = source.feedFragmented;
const feedWithBackpressure = source.feedWithBackpressure;
const FeedOutcome = source.FeedOutcome;
const feedWithBackpressureMember = source.feedWithBackpressureMember;
const waitAndTakeSpace = source.waitAndTakeSpace;
const waitResult = source.waitResult;
const waitForTerminalState = source.waitForTerminalState;
const waitForCondition = source.waitForCondition;
const takeTerminal = source.takeTerminal;
const ackEventually = source.ackEventually;
const expectComplete = source.expectComplete;
const expectStreamComplete = source.expectStreamComplete;
const expectTag = source.expectTag;
const expectSame = source.expectSame;
const expectZero = source.expectZero;
const cleanStop = source.cleanStop;
const consumedBatch = source.consumedBatch;
const exactLimits = source.exactLimits;
const owner = source.owner;

test "gzip decoder pool starts all slots exhausts and securely reuses" {
    var slots: [3]Pool.Slot = undefined;
    var pool: Pool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);
    try std.testing.expectEqual(Pool.Lifecycle.running, pool.lifecycleStatus());
    try std.testing.expectEqual(@as(u16, 0), pool.activeJobs());
    try std.testing.expectEqual(@as(?pool_module.Lease, null), pool.leaseAt(0));
    try std.testing.expectEqual(@as(?pool_module.Lease, null), pool.leaseAt(99));

    var outputs: [3][64]u8 = undefined;
    var leases: [3]pool_module.Lease = undefined;
    for (&leases, 0..) |*lease, index| {
        @memset(&outputs[index], 0xa5);
        lease.* = pool.acquire(
            owner(@intCast(index)),
            &outputs[index],
            exactLimits(&fixture.stored_gzip, outputs[index].len),
        ) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(owner(@intCast(index)), try pool.owner(lease.*));
        try std.testing.expectEqual(@as(?pool_module.Lease, lease.*), pool.leaseAt(lease.index));
    }
    try std.testing.expectEqual(@as(?pool_module.Lease, null), pool.acquire(
        owner(99),
        &outputs[0],
        exactLimits(&fixture.stored_gzip, outputs[0].len),
    ));
    try std.testing.expectEqual(@as(u16, 0), pool.available());
    try std.testing.expectEqual(@as(u16, 3), pool.activeJobs());

    for (leases, 0..) |lease, index| {
        try feedFragmented(&pool, lease, &fixture.stored_gzip, index + 1);
        try pool.finish(lease);
    }
    for (leases, 0..) |lease, index| {
        const result = try waitResult(&pool, lease);
        try expectComplete(result, fixture.stored_gzip.len, "stored-block", &outputs[index]);
        try ackEventually(&pool, lease);
    }
    const stale = leases[2];
    try std.testing.expectEqual(@as(u16, 3), pool.available());
    try std.testing.expectEqual(@as(u16, 0), pool.activeJobs());
    try std.testing.expectEqual(@as(?pool_module.Lease, null), pool.leaseAt(stale.index));
    const reused = pool.acquire(
        owner(7),
        &outputs[0],
        exactLimits(&fixture.stored_gzip, outputs[0].len),
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(stale.index, reused.index);
    try std.testing.expect(stale.generation != reused.generation);
    try std.testing.expectEqual(@as(?pool_module.Lease, reused), pool.leaseAt(reused.index));
    try std.testing.expectError(error.StaleLease, pool.feed(stale, "x"));
    try pool.cancel(reused);
    try expectTag(.canceled, try waitResult(&pool, reused));
    try expectZero(&outputs[0]);
    try ackEventually(&pool, reused);
}

test "gzip decoder pool exposes only live started worker thread ids" {
    var slots: [3]Pool.Slot = undefined;
    var pool: Pool = undefined;
    pool.init(&slots);
    try std.testing.expectEqual(@as(?std.Thread.Id, null), pool.workerThreadId(0));
    try std.testing.expectEqual(@as(?std.Thread.Id, null), pool.workerThreadId(99));
    try pool.start(stack_size);
    defer cleanStop(&pool);

    var ids: [3]std.Thread.Id = undefined;
    for (&ids, 0..) |*thread_id, index| {
        for (0..1_000_000) |_| {
            thread_id.* = pool.workerThreadId(index) orelse {
                std.Thread.yield() catch {};
                continue;
            };
            break;
        } else return error.TestUnexpectedResult;
        try std.testing.expect(thread_id.* != std.Thread.getCurrentId());
        for (ids[0..index]) |previous| try std.testing.expect(previous != thread_id.*);
    }

    try std.testing.expectEqual(@as(?event_counter.Failure, null), pool.beginStop());
    for (0..Pool.slots_len) |index| {
        try std.testing.expectEqual(@as(?std.Thread.Id, null), pool.workerThreadId(index));
    }
}

test "gzip decoder pool two-phase stop keeps counter open until poll retirement" {
    var slots: [3]Pool.Slot = undefined;
    var pool: Pool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);

    var output: [64]u8 = [_]u8{0xa5} ** 64;
    const lease = pool.acquire(
        owner(1),
        &output,
        exactLimits(&fixture.stored_gzip, output.len),
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(?event_counter.Failure, null),
        pool.beginStop(),
    );
    try std.testing.expectEqual(Pool.Lifecycle.quiesced, pool.lifecycleStatus());
    try std.testing.expectEqual(@as(u16, 0), pool.available());
    try std.testing.expectEqual(@as(u16, 1), pool.activeJobs());
    try std.testing.expectEqual(@as(?pool_module.Lease, lease), pool.leaseAt(lease.index));
    try std.testing.expectEqual(owner(1), try pool.owner(lease));
    try std.testing.expectError(error.NotRunning, pool.feed(lease, "x"));
    try std.testing.expectError(error.NotRunning, pool.finish(lease));
    try std.testing.expectError(error.NotRunning, pool.cancel(lease));
    try std.testing.expectEqual(@as(?pool_module.Lease, null), pool.acquire(
        owner(2),
        &output,
        exactLimits(&fixture.stored_gzip, output.len),
    ));
    const descriptor = pool.wakeDescriptor();
    const flags = std.os.linux.fcntl(descriptor, std.os.linux.F.GETFD, 0);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(flags));

    try std.testing.expectError(error.JobsPending, pool.finishStop());
    _ = try consumedBatch(Pool, &pool);
    try expectTag(.canceled, (try pool.result(lease)).?);
    try expectZero(&output);
    try pool.ack(lease);
    try std.testing.expectEqual(@as(u16, 0), pool.activeJobs());
    try std.testing.expectEqual(@as(?pool_module.Lease, null), pool.leaseAt(lease.index));
    try std.testing.expectError(error.WakePollLive, pool.finishStop());
    try pool.retireWakePoll();
    try std.testing.expectEqual(@as(?event_counter.Failure, null), try pool.finishStop());
    try std.testing.expectEqual(Pool.Lifecycle.stopped, pool.lifecycleStatus());
    switch (pool.consumeWake()) {
        .failed => |failure| try std.testing.expectEqual(std.os.linux.E.BADF, failure.errno),
        else => return error.TestUnexpectedResult,
    }
}

test "gzip decoder pool preserves successful output through quiesced ack" {
    var slots: [1]SmallPool.Slot = undefined;
    var pool: SmallPool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);

    var output: [64]u8 = [_]u8{0xa5} ** 64;
    const lease = pool.acquire(
        owner(8),
        &output,
        exactLimits(&fixture.stored_gzip, output.len),
    ) orelse return error.TestUnexpectedResult;
    try feedWithBackpressure(&pool, lease, &fixture.stored_gzip);
    try pool.finish(lease);
    try expectComplete(
        try waitResult(&pool, lease),
        fixture.stored_gzip.len,
        "stored-block",
        &output,
    );
    const before = output;

    try std.testing.expectEqual(@as(?event_counter.Failure, null), pool.beginStop());
    try std.testing.expectEqual(@as(u16, 0), pool.available());
    try std.testing.expectEqual(@as(u16, 1), pool.activeJobs());
    try std.testing.expectEqual(owner(8), try pool.owner(lease));
    try expectTag(.complete, (try pool.result(lease)).?);
    try std.testing.expectError(error.JobsPending, pool.finishStop());
    try pool.ack(lease);
    try std.testing.expectEqualSlices(u8, &before, &output);
    try pool.retireWakePoll();
    try std.testing.expectEqual(@as(?event_counter.Failure, null), try pool.finishStop());
    try std.testing.expectEqualSlices(u8, &before, &output);
}

test "gzip decoder pool queue preserves all-or-none feed and backpressure" {
    var slots: [1]SmallPool.Slot = undefined;
    var pool: SmallPool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);

    var output: [64]u8 = undefined;
    const lease = pool.acquire(
        owner(1),
        &output,
        exactLimits(&fixture.stored_gzip, output.len),
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectError(
        error.InputTooLarge,
        pool.feed(lease, "0123456789abcdefg"),
    );
    try feedWithBackpressure(&pool, lease, &fixture.stored_gzip);
    try pool.finish(lease);
    const result = try waitResult(&pool, lease);
    try expectComplete(result, fixture.stored_gzip.len, "stored-block", &output);
    try ackEventually(&pool, lease);
}

test "gzip decoder pool classifies strict decoder outcomes and clears failures" {
    var slots: [1]MemberPool.Slot = undefined;
    var pool: MemberPool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);

    var malformed = fixture.stored_gzip;
    malformed[0] = 0;
    try runRejected(&pool, &malformed, malformed.len, 64, 64, .malformed);
    try runRejected(
        &pool,
        &fixture.stored_gzip,
        fixture.stored_gzip.len - 1,
        64,
        64,
        .{ .over_limit = .encoded },
    );
    try runRejected(&pool, &fixture.stored_gzip, fixture.stored_gzip.len, 3, 64, .{
        .over_limit = .decoded,
    });
    try runRejected(&pool, &fixture.stored_gzip, fixture.stored_gzip.len, 64, 3, .{
        .over_limit = .output,
    });

    const three_members = fixture.optional_gzip ++ fixture.optional_gzip ++
        fixture.optional_gzip;
    try runRejected(&pool, &three_members, three_members.len, 0, 64, .{
        .over_limit = .members,
    });

    var output: [64]u8 = undefined;
    const lease = pool.acquire(
        owner(11),
        &output,
        exactLimits(&fixture.concatenated_gzip, output.len),
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        FeedOutcome.all_written,
        try feedWithBackpressureMember(&pool, lease, &fixture.concatenated_gzip),
    );
    try pool.finish(lease);
    const result = try waitResult(&pool, lease);
    const counts = switch (result) {
        .complete => |complete| complete,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), counts.members);
    try std.testing.expectEqualStrings(
        "stored-blockfixed Huffman stream: zig zig zig zig",
        output[0..counts.decoded],
    );
    try ackEventually(&pool, lease);
}

test "gzip decoder pool distinguishes cancellation and source failure" {
    var slots: [3]Pool.Slot = undefined;
    var pool: Pool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);

    var output: [128]u8 = undefined;
    @memset(&output, 0xa5);
    var lease = pool.acquire(
        owner(1),
        &output,
        exactLimits(&fixture.stored_gzip, output.len),
    ) orelse return error.TestUnexpectedResult;
    try pool.cancel(lease);
    try expectTag(.canceled, try waitResult(&pool, lease));
    try expectZero(&output);
    try ackEventually(&pool, lease);

    @memset(&output, 0xa5);
    lease = pool.acquire(
        owner(2),
        &output,
        exactLimits(&fixture.stored_gzip, output.len),
    ) orelse return error.TestUnexpectedResult;
    slots[lease.index].queue.cancel();
    try expectTag(.read_failed, try waitResult(&pool, lease));
    try expectZero(&output);
    try ackEventually(&pool, lease);

    @memset(&output, 0xa5);
    lease = pool.acquire(
        owner(3),
        &output,
        exactLimits(&fixture.stored_gzip, output.len),
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.written, try pool.feed(lease, fixture.stored_gzip[0..16]));
    try pool.cancel(lease);
    try expectTag(.canceled, try waitResult(&pool, lease));
    try expectZero(&output);
    try ackEventually(&pool, lease);
}

test "gzip decoder pool survives terminal publication and ack races" {
    var slots: [3]Pool.Slot = undefined;
    var pool: Pool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);

    var output: [64]u8 = undefined;
    for (0..512) |iteration| {
        const lease = pool.acquire(
            owner(@truncate(iteration)),
            &output,
            exactLimits(&fixture.stored_gzip, output.len),
        ) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(.written, try pool.feed(lease, &fixture.stored_gzip));
        try pool.finish(lease);
        _ = try waitResult(&pool, lease);
        try ackEventually(&pool, lease);
    }
    try std.testing.expectEqual(@as(u16, 3), pool.available());
}

test "gzip decoder pool stop preserves canceled jobs until quiesced ack" {
    var slots: [3]Pool.Slot = undefined;
    var pool: Pool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);

    var outputs: [3][64]u8 = undefined;
    var leases: [3]pool_module.Lease = undefined;
    for (&outputs, &leases, 0..) |*output, *lease, index| {
        @memset(output, 0xa5);
        lease.* = pool.acquire(
            owner(@intCast(index)),
            output,
            exactLimits(&fixture.stored_gzip, output.len),
        ) orelse return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(?event_counter.Failure, null), pool.beginStop());
    try std.testing.expectEqual(@as(u16, 3), pool.activeJobs());
    try std.testing.expectError(error.JobsPending, pool.finishStop());
    _ = try consumedBatch(Pool, &pool);
    for (leases, &outputs) |lease, *output| {
        try expectTag(.canceled, (try pool.result(lease)).?);
        try expectZero(output);
        try pool.ack(lease);
    }
    try std.testing.expectEqual(@as(u16, 0), pool.activeJobs());
    try std.testing.expectEqual(@as(?event_counter.Failure, null), try pool.finishStop());
    switch (pool.consumeWake()) {
        .failed => |failure| try std.testing.expectEqual(std.os.linux.E.BADF, failure.errno),
        else => return error.TestUnexpectedResult,
    }
}

test "gzip decoder pool repeated all-slot finish cancel stress is bounded" {
    var slots: [3]Pool.Slot = undefined;
    var pool: Pool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);

    var outputs: [3][64]u8 = undefined;
    for (0..128) |round| {
        var leases: [3]pool_module.Lease = undefined;
        for (&leases, 0..) |*lease, index| {
            @memset(&outputs[index], 0xa5);
            lease.* = pool.acquire(
                owner(@truncate(round * 3 + index)),
                &outputs[index],
                exactLimits(&fixture.stored_gzip, outputs[index].len),
            ) orelse return error.TestUnexpectedResult;
            if ((round + index) & 1 == 0) {
                try std.testing.expectEqual(.written, try pool.feed(lease.*, &fixture.stored_gzip));
                try pool.finish(lease.*);
            } else {
                try pool.cancel(lease.*);
            }
        }
        for (leases, 0..) |lease, index| {
            const result = try waitResult(&pool, lease);
            if ((round + index) & 1 == 0) {
                try expectTag(.complete, result);
            } else {
                try expectTag(.canceled, result);
                try expectZero(&outputs[index]);
            }
            try ackEventually(&pool, lease);
        }
    }
}

test "gzip decoder pool partial-start rollback joins before counter close" {
    const PartialPool = pool_module.FixedPool(2, 16, 8, 1);
    var slots: [2]PartialPool.Slot = undefined;
    var pool: PartialPool = undefined;
    pool.init(&slots);
    try PartialPool.TestAccess.startPrefix(&pool, stack_size, 1);
    defer cleanStop(&pool);
    PartialPool.TestAccess.rollback(&pool);

    try std.testing.expectEqual(@as(u16, 0), pool.available());
    try std.testing.expectEqual(@as(?event_counter.Failure, null), pool.startFailure());
    try expectZero(PartialPool.TestAccess.outputStorage(&pool, 0));
    switch (pool.consumeWake()) {
        .failed => |failure| try std.testing.expectEqual(std.os.linux.E.BADF, failure.errno),
        else => return error.TestUnexpectedResult,
    }
}

test "gzip decoder pool lease and storage constants are exact" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(pool_module.Lease));
    try std.testing.expectEqual(@as(usize, 3), Pool.slots_len);
    try std.testing.expectEqual(@as(usize, 64), Pool.input_queue_bytes);
    try std.testing.expectEqual(@as(usize, 16), Pool.receive_bytes);
    try std.testing.expectEqual(@as(usize, 16), Pool.output_mailbox_capacity_bytes);
    try std.testing.expectEqual(@as(usize, 128), Pool.output_mailbox_bytes);
    try std.testing.expectEqual(@as(usize, 2), Pool.member_limit);
}

test "gzip decoder pool coalesces slot signals into one eventfd edge" {
    const SignalPool = pool_module.FixedPool(1, 16, 8, 1);
    var slots: [1]SignalPool.Slot = undefined;
    var pool: SignalPool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);

    SignalPool.TestAccess.publishSpace(&pool, 0);
    SignalPool.TestAccess.publishSpace(&pool, 0);
    SignalPool.TestAccess.publishTerminal(&pool, 0);
    const batch = try consumedBatch(SignalPool, &pool);
    try std.testing.expectEqual(@as(u64, 1), batch.counter_count);
    try std.testing.expect(batch.slots[0].space);
    try std.testing.expect(batch.slots[0].terminal);
}

test "gzip decoder pool ack requires consumed terminal signal" {
    const SignalPool = pool_module.FixedPool(1, 16, 8, 1);
    var slots: [1]SignalPool.Slot = undefined;
    var pool: SignalPool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);

    var output: [1]u8 = .{0xa5};
    const lease = pool.acquire(
        owner(1),
        &output,
        .{ .encoded_max = 1, .decoded_max = 1 },
    ) orelse return error.TestUnexpectedResult;
    try pool.cancel(lease);
    try waitForTerminalState(SignalPool, &pool, lease);
    try std.testing.expectError(error.SignalsPending, pool.ack(lease));
    const batch = try consumedBatch(SignalPool, &pool);
    try std.testing.expect(batch.slots[0].terminal);
    try pool.ack(lease);
}

test "gzip decoder pool consume wake cannot lose publication after drain" {
    const SignalPool = pool_module.FixedPool(2, 16, 8, 1);
    const Harness = struct {
        pool: *SignalPool,
        batch: ?SignalPool.WakeBatch = null,
        failed: bool = false,

        fn run(harness: *@This()) void {
            switch (harness.pool.consumeWake()) {
                .consumed => |batch| harness.batch = batch,
                .failed => harness.failed = true,
            }
        }
    };

    var slots: [2]SignalPool.Slot = undefined;
    var pool: SignalPool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);
    SignalPool.TestAccess.pauseWake(false);
    defer SignalPool.TestAccess.pauseWake(false);

    SignalPool.TestAccess.publishSpace(&pool, 0);
    SignalPool.TestAccess.pauseWake(true);
    var harness = Harness{ .pool = &pool };
    const thread = try std.Thread.spawn(.{}, Harness.run, .{&harness});
    try waitForCondition(SignalPool.TestAccess.wakePaused);
    SignalPool.TestAccess.publishTerminal(&pool, 1);
    SignalPool.TestAccess.pauseWake(false);
    thread.join();

    try std.testing.expect(!harness.failed);
    const first = harness.batch orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), first.counter_count);
    try std.testing.expect(first.slots[0].space);
    try std.testing.expect(first.slots[1].terminal);
    const stale = try consumedBatch(SignalPool, &pool);
    try std.testing.expectEqual(@as(u64, 1), stale.counter_count);
    try std.testing.expect(!stale.slots[0].space and !stale.slots[1].terminal);
}

test "gzip decoder pool old thread notification preserves later waiter" {
    const SignalPool = pool_module.FixedPool(1, 16, 8, 1);
    const Harness = struct {
        pool: *SignalPool,

        fn run(self: *@This()) void {
            SignalPool.TestAccess.notifyThread(self.pool, 0);
        }
    };
    var slots: [1]SignalPool.Slot = undefined;
    var pool: SignalPool = undefined;
    pool.init(&slots);
    futex_epoch.TestAccess.pauseNotify(false);
    defer futex_epoch.TestAccess.pauseNotify(false);
    futex_epoch.TestAccess.pauseNotify(true);

    var harness = Harness{ .pool = &pool };
    const thread = try std.Thread.spawn(.{}, Harness.run, .{&harness});
    try waitForCondition(futex_epoch.TestAccess.notifyPaused);
    _ = SignalPool.TestAccess.armThreadWait(&pool, 0);
    futex_epoch.TestAccess.pauseNotify(false);
    thread.join();

    try std.testing.expect(SignalPool.TestAccess.threadWaiting(&pool, 0));
    try std.testing.expectEqual(@as(u32, 1), SignalPool.TestAccess.threadEpoch(&pool, 0));
    SignalPool.TestAccess.notifyThread(&pool, 0);
    try std.testing.expect(!SignalPool.TestAccess.threadWaiting(&pool, 0));
    try std.testing.expectEqual(@as(u32, 2), SignalPool.TestAccess.threadEpoch(&pool, 0));
}

test "gzip decoder pool streams independent stable mailbox chunks" {
    const encoded = [_][]const u8{ &fixture.stored_gzip, &fixture.fixed_gzip };
    const expected = [_][]const u8{
        "stored-block",
        "fixed Huffman stream: zig zig zig zig",
    };
    var slots: [2]StreamingPool.Slot = undefined;
    var pool: StreamingPool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);

    var leases: [2]pool_module.Lease = undefined;
    for (&leases, 0..) |*lease, index| {
        lease.* = pool.acquireStreaming(
            owner(@intCast(index + 20)),
            exactLimits(encoded[index], expected[index].len),
        ) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            gzip_input_queue.WriteResult.written,
            try pool.feed(lease.*, encoded[index]),
        );
        try pool.finish(lease.*);
    }

    var decoded: [2][64]u8 = undefined;
    var lengths = [_]usize{0} ** 2;
    var chunk_counts = [_]usize{0} ** 2;
    var results = [_]?pool_module.Result{null} ** 2;
    var saw_output_signal = [_]bool{false} ** 2;
    var completed: usize = 0;
    var iterations: usize = 0;
    while (completed != leases.len and iterations < 1_000_000) : (iterations += 1) {
        const batch = try consumedBatch(StreamingPool, &pool);
        for (leases, 0..) |lease, index| {
            saw_output_signal[index] = saw_output_signal[index] or batch.slots[index].output;
            if (try pool.output(lease)) |chunk| {
                const stable = (try pool.output(lease)) orelse unreachable;
                try std.testing.expect(chunk.ptr == stable.ptr);
                try std.testing.expectEqualSlices(u8, chunk, stable);
                @memcpy(decoded[index][lengths[index]..][0..chunk.len], chunk);
                lengths[index] += chunk.len;
                chunk_counts[index] += 1;
                try pool.acknowledgeOutput(lease);
            }
            if (results[index] == null) {
                if (try pool.result(lease)) |result| {
                    results[index] = result;
                    completed += 1;
                }
            }
        }
        std.Thread.yield() catch {};
    }
    if (completed != leases.len) return error.TestUnexpectedResult;

    for (leases, 0..) |lease, index| {
        try std.testing.expectEqualStrings(expected[index], decoded[index][0..lengths[index]]);
        try expectStreamComplete(results[index].?, encoded[index].len, expected[index].len);
        try std.testing.expect(chunk_counts[index] > 1);
        try std.testing.expect(saw_output_signal[index]);
        try std.testing.expectEqual(@as(?[]const u8, null), try pool.output(lease));
        try std.testing.expectError(error.NotReady, pool.acknowledgeOutput(lease));
        try ackEventually(&pool, lease);
        try expectZero(StreamingPool.TestAccess.outputStorage(&pool, lease.index));
    }
}

test "gzip decoder pool cancellation wakes blocked output and securely resets" {
    var slots: [1]SingleStreamingPool.Slot = undefined;
    var pool: SingleStreamingPool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);

    const lease = pool.acquireStreaming(
        owner(30),
        exactLimits(&fixture.stored_gzip, 12),
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        gzip_input_queue.WriteResult.written,
        try pool.feed(lease, &fixture.stored_gzip),
    );
    try pool.finish(lease);
    const borrowed = try waitBlockedOutput(&pool, lease);
    var snapshot: [8]u8 = undefined;
    @memcpy(snapshot[0..borrowed.len], borrowed);

    try pool.cancel(lease);
    try std.testing.expectEqualSlices(u8, snapshot[0..borrowed.len], borrowed);
    try std.testing.expectEqual(@as(?[]const u8, null), try pool.output(lease));
    try std.testing.expectError(error.Canceled, pool.acknowledgeOutput(lease));
    try expectTag(.canceled, try waitResult(&pool, lease));
    try std.testing.expectEqual(
        @as(?pool_module.OutputRejection, null),
        try pool.outputRejection(lease),
    );
    try pool.ack(lease);
    try expectZero(SingleStreamingPool.TestAccess.outputStorage(&pool, lease.index));

    try std.testing.expectError(error.StaleLease, pool.output(lease));
    try std.testing.expectError(error.StaleLease, pool.acknowledgeOutput(lease));
    try std.testing.expectError(
        error.StaleLease,
        pool.rejectOutput(lease, .invalid_input),
    );
    try std.testing.expectError(error.StaleLease, pool.outputRejection(lease));
}
