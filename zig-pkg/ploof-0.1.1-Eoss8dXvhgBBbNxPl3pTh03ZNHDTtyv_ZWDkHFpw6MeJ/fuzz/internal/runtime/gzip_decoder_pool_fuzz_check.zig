const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const gzip_decoder = @import("../../../src/internal/runtime/gzip/decoder.zig");
const pool_module = @import("../../../src/internal/runtime/gzip/decoder_pool.zig");
const regression_corpus = @import("gzip_decoder_pool_fuzz_corpus.zig");
const fixture = @import("../../../tests/unit/internal/runtime/gzip_decoder_test.zig");

const Pool = pool_module.FixedPool(1, 128, 16, 2);
const Decoder = gzip_decoder.Decoder(2);
const output_max = 256;
// Parallel fuzz shards can defer the helper thread beyond a small yield count.
const scheduler_progress_attempts_max = 1_000_000;
const stack_size = if (builtin.sanitize_thread)
    std.Thread.SpawnConfig.default_stack_size
else
    1024 * 1024;

const stored_seed = smithInput(&fixture.stored_gzip);
const fixed_seed = smithInput(&fixture.fixed_gzip);
const concatenated_seed = smithInput(&fixture.concatenated_gzip);
const malformed_seed = smithInput("malformed body longer than its encoded limit");
const streaming_stored_seed = streamingSmithInput(
    &fixture.stored_gzip,
    fixture.stored_gzip.len,
    12,
    3,
    .none,
    0,
);
const streaming_reject_seed = streamingSmithInput(
    &fixture.concatenated_gzip,
    fixture.concatenated_gzip.len,
    output_max,
    7,
    .reject_invalid,
    1,
);
const streaming_space_seed = streamingSmithInput(
    &fixture.dynamic_gzip,
    fixture.dynamic_gzip.len,
    output_max,
    16,
    .cancel,
    0,
);
const corpus = [_][]const u8{
    &stored_seed,
    &fixed_seed,
    &concatenated_seed,
    &malformed_seed,
    &reuse_seed,
    &streaming_stored_seed,
    &streaming_reject_seed,
    &streaming_space_seed,
    &regression_corpus.streaming_completion_regression,
    &regression_corpus.decoder_idle_regression,
};

const Context = struct {
    pool: *Pool,
    output: *[output_max]u8,
};

test "gzip decoder pool persistent-thread structured differential fuzz" {
    var slots: [1]Pool.Slot = undefined;
    var pool: Pool = undefined;
    pool.init(&slots);
    try pool.start(stack_size);
    defer closePool(&pool);
    var output: [output_max]u8 = undefined;
    try std.testing.fuzz(Context{ .pool = &pool, .output = &output }, fuzzPool, .{
        .corpus = &corpus,
    });
}

const reuse_seed = [_]u8{
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xbc, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x3a, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x62, 0xb0, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x13, 0x28, 0xe7, 0xd2, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

fn fuzzPool(context: Context, smith: *std.testing.Smith) !void {
    if (smith.value(bool)) {
        try fuzzDecode(context, smith);
    } else if (smith.value(bool)) {
        try fuzzStreaming(context, smith);
    } else {
        try fuzzCancel(context, smith);
    }
}

const StreamAction = enum(u8) {
    none,
    cancel,
    reject_invalid,
    reject_too_large,
    reject_unsupported,
};

const StreamRun = struct {
    result: pool_module.Result,
    output_length: usize,
    action_triggered: bool,
    expected_rejection: ?pool_module.OutputRejection,
};

const StreamState = struct {
    offset: usize = 0,
    output_length: usize = 0,
    chunk_index: usize = 0,
    finished: bool = false,
    action_triggered: bool = false,
    expected_rejection: ?pool_module.OutputRejection = null,
    event_pending: bool = false,
    space_armed: bool = false,
};

const FeedProgress = enum { idle, progressed, restart };

fn fuzzDecode(context: Context, smith: *std.testing.Smith) !void {
    var input_storage: [128]u8 = undefined;
    const input = input_storage[0..smith.slice(&input_storage)];
    const output_length = smith.valueRangeAtMost(u16, 0, output_max);
    const encoded_max = smith.valueRangeAtMost(u16, 0, input_storage.len);
    const decoded_max = smith.valueRangeAtMost(u16, 0, output_max);
    const limits: pool_module.Limits = .{
        .encoded_max = encoded_max,
        .decoded_max = decoded_max,
    };

    @memset(context.output, 0xa5);
    const lease = context.pool.acquire(
        fuzzOwner(smith),
        context.output[0..output_length],
        limits,
    ) orelse return error.PoolExhausted;
    const fragment_max = smith.valueRangeAtMost(u8, 1, 32);
    const fed_all = try feedAll(context.pool, lease, input, fragment_max);
    if (fed_all) context.pool.finish(lease) catch |err| switch (err) {
        error.JobTerminal => {},
        else => return err,
    };
    const streamed = try waitResult(context.pool, lease);

    var direct_output: [output_max]u8 = undefined;
    const direct = Decoder.decode(
        input,
        direct_output[0..output_length],
        encoded_max,
        decoded_max,
    );
    try expectEquivalent(
        streamed,
        direct,
        context.output,
        &direct_output,
        input.len,
        encoded_max,
    );
    if (streamed != .complete) try expectZero(context.output[0..output_length]);
    try ack(context.pool, lease);
    try std.testing.expectError(error.StaleLease, context.pool.feed(lease, "x"));
}

fn fuzzCancel(context: Context, smith: *std.testing.Smith) !void {
    const output_length = smith.valueRangeAtMost(u16, 0, output_max);
    @memset(context.output, 0xa5);
    const lease = context.pool.acquire(
        fuzzOwner(smith),
        context.output[0..output_length],
        .{ .encoded_max = fixture.stored_gzip.len, .decoded_max = output_max },
    ) orelse return error.PoolExhausted;
    if (smith.value(bool)) {
        try std.testing.expectEqual(
            .written,
            try context.pool.feed(lease, fixture.stored_gzip[0..5]),
        );
    }
    try context.pool.cancel(lease);
    const result = try waitResult(context.pool, lease);
    try std.testing.expectEqual(.canceled, std.meta.activeTag(result));
    try expectZero(context.output[0..output_length]);
    try ack(context.pool, lease);
}

fn fuzzStreaming(context: Context, smith: *std.testing.Smith) !void {
    var input_storage: [512]u8 = undefined;
    const input = input_storage[0..smith.slice(&input_storage)];
    const encoded_max = smith.valueRangeAtMost(u16, 0, input_storage.len);
    const decoded_max = smith.valueRangeAtMost(u16, 0, output_max);
    const fragment_max = smith.valueRangeAtMost(u8, 1, 64);
    const action = smith.value(StreamAction);
    const action_chunk = smith.valueRangeAtMost(u8, 0, 15);
    const limits: pool_module.Limits = .{
        .encoded_max = encoded_max,
        .decoded_max = decoded_max,
    };

    try drainQuiescentWake(context.pool);
    @memset(context.output, 0xa5);
    const lease = context.pool.acquireStreaming(
        fuzzOwner(smith),
        limits,
    ) orelse return error.PoolExhausted;
    const run = try driveStreaming(
        context,
        lease,
        input,
        fragment_max,
        action,
        action_chunk,
    );

    var direct_output: [output_max]u8 = undefined;
    var direct_writer = std.Io.Writer.fixed(&direct_output);
    const direct = Decoder.decodeToWriter(
        input,
        &direct_writer,
        encoded_max,
        decoded_max,
    ) catch return error.DirectWriteFailed;
    try expectStreamEquivalent(
        run,
        direct,
        context.output,
        direct_output[0..direct_writer.end],
        input.len,
        encoded_max,
    );
    try std.testing.expectEqual(
        run.expected_rejection,
        try context.pool.outputRejection(lease),
    );

    try context.pool.ack(lease);
    try expectZero(Pool.TestAccess.outputStorage(context.pool, lease.index));
    try std.testing.expectError(error.StaleLease, context.pool.output(lease));
    try std.testing.expectError(error.StaleLease, context.pool.acknowledgeOutput(lease));
    try std.testing.expectError(error.StaleLease, context.pool.outputRejection(lease));
    try exerciseStreamingReuse(context.pool, fuzzOwner(smith), limits);
}

fn driveStreaming(
    context: Context,
    lease: pool_module.Lease,
    input: []const u8,
    fragment_max: usize,
    action: StreamAction,
    action_chunk: usize,
) !StreamRun {
    var state: StreamState = .{};
    for (0..scheduler_progress_attempts_max) |_| {
        const feed = try advanceStreamingInput(
            context.pool,
            lease,
            input,
            fragment_max,
            &state,
        );
        if (feed == .restart) continue;
        var progressed = feed == .progressed;
        if (try consumeStreamingOutput(context, lease, action, action_chunk, &state)) {
            state.event_pending = true;
            progressed = true;
        }
        if (try completeStreamingRun(context.pool, lease, &state)) |run| return run;
        if (!progressed and !state.event_pending) {
            try waitForEvent(context.pool.wakeDescriptor());
            state.event_pending = true;
        } else if (!progressed) {
            std.Thread.yield() catch {};
        }
    }
    return error.StreamingCompletionUnbounded;
}

fn advanceStreamingInput(
    pool: *Pool,
    lease: pool_module.Lease,
    input: []const u8,
    fragment_max: usize,
    state: *StreamState,
) !FeedProgress {
    var progressed = false;
    if (!state.finished and state.offset < input.len) {
        const end = @min(input.len, state.offset + fragment_max);
        const feed = pool.feed(lease, input[state.offset..end]) catch |err| switch (err) {
            error.JobTerminal => {
                state.finished = true;
                return .restart;
            },
            else => return err,
        };
        switch (feed) {
            .written => {
                state.offset = end;
                progressed = true;
            },
            .full => {
                state.space_armed = true;
                const waiting = pool.shouldWaitForSpace(lease) catch |err| switch (err) {
                    error.JobTerminal => {
                        state.finished = true;
                        return .restart;
                    },
                    else => return err,
                };
                if (!waiting) progressed = true;
            },
        }
    }
    if (!state.finished and state.offset == input.len) {
        pool.finish(lease) catch |err| switch (err) {
            error.JobTerminal => {},
            else => return err,
        };
        state.finished = true;
        progressed = true;
    }
    return if (progressed) .progressed else .idle;
}

fn consumeStreamingOutput(
    context: Context,
    lease: pool_module.Lease,
    action: StreamAction,
    action_chunk: usize,
    state: *StreamState,
) !bool {
    const chunk = (try context.pool.output(lease)) orelse return false;
    if (!state.action_triggered and action != .none and state.chunk_index == action_chunk) {
        state.expected_rejection = try performStreamAction(context.pool, lease, action);
        state.action_triggered = true;
        try std.testing.expectError(
            error.Canceled,
            context.pool.acknowledgeOutput(lease),
        );
    } else {
        const stable = (try context.pool.output(lease)) orelse unreachable;
        try std.testing.expectEqualSlices(u8, chunk, stable);
        if (chunk.len > context.output.len - state.output_length) return error.OutputOverflow;
        @memcpy(context.output[state.output_length..][0..chunk.len], chunk);
        state.output_length += chunk.len;
        try context.pool.acknowledgeOutput(lease);
    }
    state.chunk_index += 1;
    return true;
}

fn completeStreamingRun(
    pool: *Pool,
    lease: pool_module.Lease,
    state: *const StreamState,
) !?StreamRun {
    const result = (try pool.result(lease)) orelse return null;
    const pending: pool_module.Signals = @bitCast(
        pool.slots[lease.index].signals.load(.acquire),
    );
    if (!pending.terminal) {
        std.Thread.yield() catch {};
        return null;
    }
    try waitForDecoderIdle(pool);
    const signals = try consumeTerminalSignals(pool, state.chunk_index, state.space_armed);
    try std.testing.expectEqual(@as(u64, 1), signals.counter_count);
    return .{
        .result = result,
        .output_length = state.output_length,
        .action_triggered = state.action_triggered,
        .expected_rejection = state.expected_rejection,
    };
}

fn performStreamAction(
    pool: *Pool,
    lease: pool_module.Lease,
    action: StreamAction,
) !?pool_module.OutputRejection {
    return switch (action) {
        .none => null,
        .cancel => canceled: {
            try pool.cancel(lease);
            break :canceled null;
        },
        .reject_invalid => try rejectStreaming(pool, lease, .invalid_input),
        .reject_too_large => try rejectStreaming(pool, lease, .input_too_large),
        .reject_unsupported => try rejectStreaming(pool, lease, .unsupported_media),
    };
}

fn rejectStreaming(
    pool: *Pool,
    lease: pool_module.Lease,
    reason: pool_module.OutputRejection,
) !pool_module.OutputRejection {
    try pool.rejectOutput(lease, reason);
    try pool.rejectOutput(lease, alternateRejection(reason));
    return reason;
}

fn alternateRejection(reason: pool_module.OutputRejection) pool_module.OutputRejection {
    return switch (reason) {
        .invalid_input => .unsupported_media,
        .input_too_large, .unsupported_media => .invalid_input,
    };
}

fn consumeTerminalSignals(
    pool: *Pool,
    chunk_count: usize,
    space_armed: bool,
) !Pool.WakeBatch {
    const batch = switch (pool.consumeWake()) {
        .consumed => |consumed| consumed,
        .failed => return error.WakeConsumeFailed,
    };
    try std.testing.expect(batch.slots[0].terminal);
    try std.testing.expectEqual(chunk_count != 0, batch.slots[0].output);
    if (batch.slots[0].space) try std.testing.expect(space_armed);

    const drained = switch (pool.consumeWake()) {
        .consumed => |consumed| consumed,
        .failed => return error.WakeConsumeFailed,
    };
    try std.testing.expectEqual(@as(u64, 0), drained.counter_count);
    try std.testing.expectEqual(pool_module.Signals{}, drained.slots[0]);
    return batch;
}

fn exerciseStreamingReuse(
    pool: *Pool,
    owner: pool_module.Owner,
    limits: pool_module.Limits,
) !void {
    const lease = pool.acquireStreaming(owner, limits) orelse return error.PoolExhausted;
    try std.testing.expectEqual(
        @as(?pool_module.OutputRejection, null),
        try pool.outputRejection(lease),
    );
    try std.testing.expectEqual(@as(?[]const u8, null), try pool.output(lease));
    try pool.cancel(lease);
    try std.testing.expectEqual(.canceled, std.meta.activeTag(try waitResult(pool, lease)));
    try ack(pool, lease);
    try expectZero(Pool.TestAccess.outputStorage(pool, lease.index));
    try drainQuiescentWake(pool);
}

fn drainQuiescentWake(pool: *Pool) !void {
    try waitForDecoderIdle(pool);
    for (0..4) |_| {
        const batch = switch (pool.consumeWake()) {
            .consumed => |consumed| consumed,
            .failed => return error.WakeConsumeFailed,
        };
        try std.testing.expectEqual(pool_module.Signals{}, batch.slots[0]);
        if (batch.counter_count == 0) return;
    }
    return error.WakeDrainUnbounded;
}

fn waitForDecoderIdle(pool: *const Pool) !void {
    for (0..scheduler_progress_attempts_max) |_| {
        if (Pool.TestAccess.threadWaiting(pool, 0)) return;
        std.Thread.yield() catch {};
    }
    return error.DecoderIdleUnbounded;
}

fn expectStreamEquivalent(
    run: StreamRun,
    direct: gzip_decoder.StreamResult,
    streamed_output: []const u8,
    direct_output: []const u8,
    input_length: usize,
    encoded_max: usize,
) !void {
    const direct_preflight = input_length > encoded_max and
        direct == .over_limit and direct.over_limit == .encoded;
    if (!direct_preflight) {
        if (run.output_length > direct_output.len) return error.OracleMismatch;
        try std.testing.expectEqualSlices(
            u8,
            direct_output[0..run.output_length],
            streamed_output[0..run.output_length],
        );
    }
    if (run.action_triggered) {
        return std.testing.expectEqual(.canceled, std.meta.activeTag(run.result));
    }
    if (direct_preflight) {
        return switch (run.result) {
            .malformed => {},
            .over_limit => {},
            else => error.OracleMismatch,
        };
    }
    switch (direct) {
        .complete => |complete| {
            const counts = switch (run.result) {
                .complete => |value| value,
                else => return error.OracleMismatch,
            };
            try std.testing.expectEqual(complete.encoded_consumed, counts.encoded);
            try std.testing.expectEqual(complete.decoded_count, counts.decoded);
            try std.testing.expectEqual(complete.member_count, counts.members);
            try std.testing.expectEqual(counts.decoded, run.output_length);
            try std.testing.expectEqual(direct_output.len, run.output_length);
        },
        .malformed => try std.testing.expectEqual(.malformed, std.meta.activeTag(run.result)),
        .over_limit => |limit| {
            try std.testing.expectEqual(.over_limit, std.meta.activeTag(run.result));
            try std.testing.expectEqual(limit, run.result.over_limit);
        },
    }
}

fn feedAll(
    pool: *Pool,
    lease: pool_module.Lease,
    input: []const u8,
    fragment_max: usize,
) !bool {
    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(input.len, offset + fragment_max);
        const feed = pool.feed(lease, input[offset..end]) catch |err| switch (err) {
            error.JobTerminal => return false,
            else => return err,
        };
        switch (feed) {
            .written => offset = end,
            .full => std.Thread.yield() catch {},
        }
    }
    return true;
}

fn waitResult(pool: *Pool, lease: pool_module.Lease) !pool_module.Result {
    for (0..64) |_| {
        try waitForEvent(pool.wakeDescriptor());
        if (try takeTerminal(pool, lease.index)) {
            return (try pool.result(lease)) orelse error.TerminalWithoutResult;
        }
    }
    return switch (pool.slots[lease.index].state.load(.acquire)) {
        .stopped => error.WaitStopped,
        .idle => error.WaitIdle,
        .ready => error.WaitReady,
        .running => error.WaitRunning,
        .canceling => error.WaitCanceling,
        .publishing => error.WaitPublishing,
        .terminal => error.WaitTerminal,
    };
}

fn waitForEvent(descriptor: linux.fd_t) !void {
    var descriptors = [1]linux.pollfd{.{
        .fd = descriptor,
        .events = linux.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        const result = linux.poll(&descriptors, descriptors.len, 1_000);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 1 and descriptors[0].revents & linux.POLL.IN != 0) return;
                return error.EventWaitTimedOut;
            },
            .INTR => continue,
            else => return error.EventWaitFailed,
        }
    }
}

fn takeTerminal(pool: *Pool, index: u16) !bool {
    const batch = switch (pool.consumeWake()) {
        .consumed => |consumed| consumed,
        .failed => return error.WakeConsumeFailed,
    };
    return batch.slots[index].terminal;
}

fn ack(pool: *Pool, lease: pool_module.Lease) !void {
    for (0..1_000_000) |_| {
        pool.ack(lease) catch |err| switch (err) {
            error.SignalsPending => {
                _ = switch (pool.consumeWake()) {
                    .consumed => |batch| batch,
                    .failed => return error.WakeConsumeFailed,
                };
                std.Thread.yield() catch {};
                continue;
            },
            else => return err,
        };
        return;
    }
    return error.AckTimedOut;
}

fn expectEquivalent(
    streamed: pool_module.Result,
    direct: gzip_decoder.Result,
    streamed_output: []const u8,
    direct_output: []const u8,
    input_length: usize,
    encoded_max: usize,
) !void {
    // Known slices preflight encoded length. Streaming can reject malformed
    // framing first; fixed CL transport preflights, while chunked limits wire bytes.
    if (input_length > encoded_max and direct == .over_limit and
        direct.over_limit == .encoded)
    {
        return switch (streamed) {
            .malformed => {},
            .over_limit => |limit| std.testing.expectEqual(.encoded, limit),
            else => error.OracleMismatch,
        };
    }
    switch (direct) {
        .complete => |complete| {
            const counts = switch (streamed) {
                .complete => |value| value,
                else => return error.OracleMismatch,
            };
            try std.testing.expectEqual(complete.encoded_consumed, counts.encoded);
            try std.testing.expectEqual(complete.decoded_count, counts.decoded);
            try std.testing.expectEqual(complete.member_count, counts.members);
            try std.testing.expectEqualSlices(
                u8,
                direct_output[0..counts.decoded],
                streamed_output[0..counts.decoded],
            );
        },
        .malformed => try std.testing.expectEqual(.malformed, std.meta.activeTag(streamed)),
        .over_limit => |limit| {
            try std.testing.expectEqual(.over_limit, std.meta.activeTag(streamed));
            try std.testing.expectEqual(limit, streamed.over_limit);
        },
    }
}

fn expectZero(bytes: []const u8) !void {
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

fn fuzzOwner(smith: *std.testing.Smith) pool_module.Owner {
    return .{
        .connection_index = smith.value(u16),
        .request_index = smith.value(u16),
        .generation = smith.value(u32),
    };
}

fn smithInput(comptime value: []const u8) [value.len + 4]u8 {
    var input: [value.len + 4]u8 = undefined;
    const length: u32 = @intCast(value.len);
    inline for (0..4) |index| input[index] = @truncate(length >> (index * 8));
    @memcpy(input[4..], value);
    return input;
}

fn streamingSmithInput(
    comptime value: []const u8,
    comptime encoded_max: usize,
    comptime decoded_max: usize,
    comptime fragment_max: u8,
    comptime action: StreamAction,
    comptime action_chunk: u8,
) [value.len + 84]u8 {
    var input = [_]u8{0} ** (value.len + 84);
    var offset: usize = 0;
    writeSmithInt(&input, &offset, 0);
    writeSmithInt(&input, &offset, 1);
    const length: u32 = @intCast(value.len);
    inline for (0..4) |index| input[offset + index] = @truncate(length >> (index * 8));
    offset += 4;
    @memcpy(input[offset..][0..value.len], value);
    offset += value.len;
    writeSmithInt(&input, &offset, encoded_max);
    writeSmithInt(&input, &offset, decoded_max);
    writeSmithInt(&input, &offset, fragment_max);
    writeSmithInt(&input, &offset, @intFromEnum(action));
    writeSmithInt(&input, &offset, action_chunk);
    writeSmithInt(&input, &offset, 1);
    writeSmithInt(&input, &offset, 2);
    writeSmithInt(&input, &offset, 3);
    return input;
}

fn writeSmithInt(
    input: anytype,
    offset: *usize,
    comptime value: u64,
) void {
    inline for (0..8) |index| input[offset.* + index] = @truncate(value >> (index * 8));
    offset.* += 8;
}

fn closePool(pool: *Pool) void {
    if (pool.beginStop() != null) @panic("gzip decoder pool fuzz join failed");
    pool.retireWakePoll() catch @panic("gzip decoder pool fuzz poll state failed");
    const failure = pool.finishStop() catch @panic("gzip decoder pool fuzz poll live");
    if (failure != null) @panic("gzip decoder pool fuzz close failed");
}
