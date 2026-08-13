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

test "gzip decoder pool begin stop wakes blocked streaming output" {
    var slots: [1]SingleStreamingPool.Slot = undefined;
    var pool: SingleStreamingPool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);

    const lease = pool.acquireStreaming(
        owner(35),
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

    try std.testing.expectEqual(@as(?event_counter.Failure, null), pool.beginStop());
    try std.testing.expectEqualSlices(u8, snapshot[0..borrowed.len], borrowed);
    try expectTag(.canceled, (try pool.result(lease)).?);
    try std.testing.expectError(error.Canceled, pool.acknowledgeOutput(lease));
    _ = try consumedBatch(SingleStreamingPool, &pool);
    try pool.ack(lease);
    try expectZero(SingleStreamingPool.TestAccess.outputStorage(&pool, lease.index));
    try pool.retireWakePoll();
    try std.testing.expectEqual(@as(?event_counter.Failure, null), try pool.finishStop());
}

test "gzip decoder pool output rejection is sticky through terminal" {
    var slots: [1]SingleStreamingPool.Slot = undefined;
    var pool: SingleStreamingPool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer cleanStop(&pool);

    const lease = pool.acquireStreaming(
        owner(40),
        exactLimits(&fixture.stored_gzip, 12),
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        gzip_input_queue.WriteResult.written,
        try pool.feed(lease, &fixture.stored_gzip),
    );
    try pool.finish(lease);
    _ = try waitBlockedOutput(&pool, lease);

    try pool.rejectOutput(lease, .invalid_input);
    try pool.rejectOutput(lease, .unsupported_media);
    try std.testing.expectEqual(
        pool_module.OutputRejection.invalid_input,
        (try pool.outputRejection(lease)).?,
    );
    try std.testing.expectError(error.Canceled, pool.acknowledgeOutput(lease));
    try expectTag(.canceled, try waitResult(&pool, lease));
    try std.testing.expectEqual(
        pool_module.OutputRejection.invalid_input,
        (try pool.outputRejection(lease)).?,
    );
    try pool.ack(lease);

    const reused = pool.acquireStreaming(
        owner(41),
        exactLimits(&fixture.stored_gzip, 12),
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(?pool_module.OutputRejection, null),
        try pool.outputRejection(reused),
    );
    try pool.cancel(reused);
    try expectTag(.canceled, try waitResult(&pool, reused));
    try pool.ack(reused);
}
