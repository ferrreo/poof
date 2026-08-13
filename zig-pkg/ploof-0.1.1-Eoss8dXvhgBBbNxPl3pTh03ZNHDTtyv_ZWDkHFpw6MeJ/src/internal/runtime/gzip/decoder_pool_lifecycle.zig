const std = @import("std");
const event_counter = @import("../event_counter.zig");

const CloseError = error{
    JobsPending,
    NotQuiesced,
    WakePollLive,
};

pub fn spawnPrefix(
    pool: anytype,
    stack_size: usize,
    count: usize,
    comptime thread_main: anytype,
) std.Thread.SpawnError!void {
    for (pool.slots[0..count], 0..) |*slot, index| {
        slot.thread = try std.Thread.spawn(
            .{ .stack_size = stack_size },
            thread_main,
            .{slot},
        );
        pool.started_count = @intCast(index + 1);
    }
}

pub fn beginStop(pool: anytype) ?event_counter.Failure {
    if (pool.lifecycle != .running) return pool.counter_failure;
    requestShutdown(pool);
    joinStarted(pool);
    prepareQuiescedSlots(pool);
    pool.lifecycle = .quiesced;
    return pool.counter_failure;
}

pub fn retireWakePoll(pool: anytype) CloseError!void {
    if (pool.lifecycle != .quiesced) return error.NotQuiesced;
    pool.wake_poll_retired = true;
}

pub fn finishStop(pool: anytype) CloseError!?event_counter.Failure {
    if (pool.lifecycle == .initialized) {
        pool.lifecycle = .stopped;
        pool.free_count = 0;
        return pool.counter_failure;
    }
    if (pool.lifecycle == .running) return error.NotQuiesced;
    if (pool.lifecycle != .quiesced) return pool.counter_failure;
    if (pool.activeJobs() != 0) return error.JobsPending;
    if (pool.wake_descriptor_exposed and !pool.wake_poll_retired) {
        return error.WakePollLive;
    }
    const close_failure = if (pool.counter_open) pool.counter.close() else null;
    pool.counter_open = false;
    pool.lifecycle = .stopped;
    pool.free_count = 0;
    pool.counter_failure = pool.counter_failure orelse close_failure;
    return pool.counter_failure;
}

pub fn rollbackStarted(pool: anytype) void {
    requestShutdown(pool);
    joinStarted(pool);
    clearStoppedSlots(pool);
    pool.counter_failure = if (pool.counter_open) pool.counter.close() else null;
    pool.counter_open = false;
    pool.lifecycle = .stopped;
}

fn requestShutdown(pool: anytype) void {
    for (pool.slots[0..pool.started_count]) |*slot| {
        cancelForShutdown(slot);
        slot.shutdown.store(true, .release);
        slot.event.notify();
    }
}

fn cancelForShutdown(slot: anytype) void {
    while (true) {
        const state = slot.state.load(.acquire);
        switch (state) {
            .ready, .running => {
                if (slot.state.cmpxchgStrong(
                    state,
                    .canceling,
                    .acq_rel,
                    .acquire,
                ) != null) continue;
                slot.queue.cancel();
                slot.mailbox.cancel();
                return;
            },
            .canceling => {
                slot.queue.cancel();
                slot.mailbox.cancel();
            },
            else => {},
        }
        return;
    }
}

fn joinStarted(pool: anytype) void {
    for (pool.slots[0..pool.started_count]) |*slot| {
        if (slot.thread) |thread| thread.join();
        slot.thread = null;
    }
}

fn clearStoppedSlots(pool: anytype) void {
    for (pool.slots) |*slot| {
        if (slot.occupied) switch (slot.job.output) {
            .buffered => |output_bytes| std.crypto.secureZero(u8, output_bytes),
            .streaming => {},
        };
        slot.queue.reset();
        slot.mailbox.reset();
        slot.job = .{};
        slot.output_rejection = null;
        slot.occupied = false;
        slot.terminal_consumed = false;
        slot.signals.store(0, .monotonic);
        slot.state.store(.stopped, .release);
    }
    pool.started_count = 0;
    pool.free_count = 0;
}

fn prepareQuiescedSlots(pool: anytype) void {
    for (pool.slots) |*slot| {
        if (slot.occupied) {
            if (slot.state.load(.acquire) != .terminal) {
                @panic("gzip decoder pool quiesced job is not terminal");
            }
            continue;
        }
        slot.queue.reset();
        slot.mailbox.reset();
        slot.job = .{};
        slot.output_rejection = null;
        slot.terminal_consumed = false;
        slot.signals.store(0, .monotonic);
        slot.state.store(.stopped, .release);
    }
    pool.started_count = 0;
}
