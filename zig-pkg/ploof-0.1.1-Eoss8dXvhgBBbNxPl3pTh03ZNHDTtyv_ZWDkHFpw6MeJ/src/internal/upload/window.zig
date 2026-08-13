const std = @import("std");
const upload = @import("../../multipart/upload.zig");
const sink_driver = @import("sink_driver.zig");

pub const window_hard_max: usize = upload.upload_window_hard_max;
pub const chunk_bytes_hard_max: usize = upload.upload_chunk_bytes_hard_max;

pub const ControlError = error{
    Busy,
    Canceled,
    Draining,
    Failed,
    InvalidSlot,
    NoPending,
    OffsetOverflow,
    Poisoned,
};

pub const Mode = enum(u8) {
    accepting,
    draining,
    canceled,
    failed,
    poisoned,
};

/// Fixed storage for one active multipart file. Asynchronous-capable sinks retain
/// bytes in stable slots; synchronous-only sinks borrow input until `write` returns.
pub fn Window(
    comptime Sink: type,
    comptime chunk_bytes: usize,
    comptime window: usize,
) type {
    upload.validateRequestSink(Sink);
    validateConfiguration(chunk_bytes, window);

    const WriteDriver = sink_driver.Write(Sink);
    const SlotIndex = u4;
    const retain_bytes = @as(u8, @bitCast(Sink.io_requirements)) != 0;
    const valid_mask: u16 = @truncate((@as(u32, 1) << @intCast(window)) - 1);

    return struct {
        const Self = @This();

        const Slot = struct {
            bytes: [if (retain_bytes) chunk_bytes else 0]u8 = undefined,
            driver: WriteDriver = .{},
        };

        pub const Error = Sink.Error || WriteDriver.Error || ControlError;
        pub const Submission = struct {
            slot: SlotIndex,
            request: upload.IoRequest,
        };
        pub const PushResult = struct {
            consumed: usize = 0,
            submission: ?Submission = null,
        };

        slots: [window]Slot = [_]Slot{.{}} ** window,
        occupied_mask: u16 = 0,
        pending_mask: u16 = 0,
        mode: Mode = .accepting,

        pub fn push(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            input: []const u8,
            absolute_offset: u64,
        ) Error!PushResult {
            try self.requireAccepting();
            var result = PushResult{};
            while (result.consumed < input.len) {
                const slot = self.lowestFree() orelse break;
                const remaining = input[result.consumed..];
                const length = @min(remaining.len, chunk_bytes);
                const offset = chunkOffset(absolute_offset, result.consumed, length) catch {
                    self.mode = .poisoned;
                    return error.OffsetOverflow;
                };
                const poll = self.startChunk(
                    runtime,
                    state,
                    slot,
                    remaining[0..length],
                    offset,
                ) catch |problem| {
                    self.acceptStartFailure(slot);
                    return problem;
                };
                result.consumed += length;
                if (poll == .request) {
                    result.submission = .{ .slot = slot, .request = poll.request };
                    break;
                }
            }
            return result;
        }

        pub fn complete(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            slot: SlotIndex,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(void) {
            return self.completeWith(runtime, state, slot, completion, false);
        }

        pub fn completeCanceled(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            slot: SlotIndex,
        ) Error!upload.Poll(void) {
            return self.completeWith(
                runtime,
                state,
                slot,
                .{ .failure = .canceled },
                true,
            );
        }

        fn completeWith(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            slot: SlotIndex,
            completion: upload.IoCompletion,
            cancel_requested: bool,
        ) Error!upload.Poll(void) {
            const bit = self.pendingBit(slot) catch |problem| {
                self.mode = .poisoned;
                return problem;
            };
            if (cancel_requested) {
                self.cancel();
                if (!self.slots[slot].driver.cancelActive()) {
                    self.mode = .poisoned;
                    return error.Poisoned;
                }
                self.release(slot, bit);
                return .{ .done = {} };
            }
            if (completion == .failure and completion.failure == .canceled) {
                self.cancel();
            }
            const poll = self.slots[slot].driver.resumeWrite(
                runtime,
                state,
                completion,
            ) catch |problem| {
                self.acceptResumeFailure(slot, bit);
                return problem;
            };
            self.pending_mask &= ~bit;
            return switch (poll) {
                .done => done: {
                    self.release(slot, bit);
                    break :done .{ .done = {} };
                },
                .request => |request| self.acceptResumeRequest(slot, bit, request),
            };
        }

        pub fn drain(self: *Self) ControlError!void {
            switch (self.mode) {
                .accepting => self.mode = .draining,
                .draining => {},
                .canceled => return error.Canceled,
                .failed => return error.Failed,
                .poisoned => return error.Poisoned,
            }
        }

        pub fn cancel(self: *Self) void {
            if (self.mode != .failed and self.mode != .poisoned) self.mode = .canceled;
        }

        pub fn reset(self: *Self) ControlError!void {
            if (self.mode == .poisoned) return error.Poisoned;
            if (!self.quiescent()) return error.Busy;
            std.debug.assert(self.pending_mask == 0);
            self.mode = .accepting;
        }

        pub fn quiescent(self: *const Self) bool {
            return self.occupied_mask == 0;
        }

        pub fn canAccept(self: *const Self) bool {
            return self.mode == .accepting and self.lowestFree() != null;
        }

        pub fn lowestPending(self: *const Self) ?SlotIndex {
            if (self.pending_mask == 0) return null;
            return @intCast(@ctz(self.pending_mask));
        }

        pub fn pendingRequest(self: *const Self, slot: SlotIndex) ?upload.IoRequest {
            if (@as(usize, slot) >= window) return null;
            if (self.pending_mask & bitFor(slot) == 0) return null;
            return self.slots[slot].driver.poller.pendingRequest();
        }

        fn startChunk(
            self: *Self,
            runtime: *Sink.Runtime,
            state: *Sink.State,
            slot: SlotIndex,
            bytes: []const u8,
            offset: u64,
        ) Error!upload.Poll(void) {
            std.debug.assert(bytes.len > 0 and bytes.len <= chunk_bytes);
            const bit = bitFor(slot);
            std.debug.assert(self.occupied_mask & bit == 0);
            const entry = &self.slots[slot];
            const stable_bytes = if (comptime retain_bytes) retained: {
                @memcpy(entry.bytes[0..bytes.len], bytes);
                break :retained entry.bytes[0..bytes.len];
            } else bytes;
            self.occupied_mask |= bit;
            const poll = try entry.driver.start(runtime, state, .{
                .bytes = stable_bytes,
                .offset = offset,
            });
            if (poll == .done) self.release(slot, bit) else self.pending_mask |= bit;
            return poll;
        }

        fn acceptStartFailure(self: *Self, slot: SlotIndex) void {
            const bit = bitFor(slot);
            const driver = &self.slots[slot].driver;
            const ownership_proven = driver.poller.ownershipProven();
            const source = driver.lastFailureSource();
            if (ownership_proven and driver.poller.pendingRequest() == null) {
                self.release(slot, bit);
            }
            self.mode = if (source == .sink and ownership_proven)
                .failed
            else
                .poisoned;
        }

        fn acceptResumeRequest(
            self: *Self,
            slot: SlotIndex,
            bit: u16,
            request: upload.IoRequest,
        ) Error!upload.Poll(void) {
            _ = slot;
            self.pending_mask |= bit;
            return .{ .request = request };
        }

        fn acceptResumeFailure(self: *Self, slot: SlotIndex, bit: u16) void {
            self.pending_mask &= ~bit;
            const driver = &self.slots[slot].driver;
            if (!driver.poller.ownershipProven()) {
                self.mode = .poisoned;
                return;
            }
            const source = driver.lastFailureSource();
            if (driver.poller.pendingRequest() == null) {
                self.release(slot, bit);
            }
            self.mode = if (source == .sink)
                .failed
            else
                .poisoned;
        }

        fn pendingBit(self: *const Self, slot: SlotIndex) ControlError!u16 {
            if (@as(usize, slot) >= window) return error.InvalidSlot;
            const bit = bitFor(slot);
            if (self.pending_mask & bit == 0) return error.NoPending;
            return bit;
        }

        fn requireAccepting(self: *const Self) ControlError!void {
            return switch (self.mode) {
                .accepting => {},
                .draining => error.Draining,
                .canceled => error.Canceled,
                .failed => error.Failed,
                .poisoned => error.Poisoned,
            };
        }

        fn lowestFree(self: *const Self) ?SlotIndex {
            const free = ~self.occupied_mask & valid_mask;
            if (free == 0) return null;
            return @intCast(@ctz(free));
        }

        fn release(self: *Self, slot: SlotIndex, bit: u16) void {
            std.debug.assert(self.occupied_mask & bit != 0);
            self.slots[slot].driver = .{};
            self.pending_mask &= ~bit;
            self.occupied_mask &= ~bit;
        }

        fn bitFor(slot: SlotIndex) u16 {
            return @as(u16, 1) << slot;
        }

        fn chunkOffset(base: u64, consumed: usize, length: usize) ControlError!u64 {
            const consumed_u64 = std.math.cast(u64, consumed) orelse {
                return error.OffsetOverflow;
            };
            const length_u64 = std.math.cast(u64, length) orelse {
                return error.OffsetOverflow;
            };
            const offset = std.math.add(u64, base, consumed_u64) catch {
                return error.OffsetOverflow;
            };
            _ = std.math.add(u64, offset, length_u64) catch {
                return error.OffsetOverflow;
            };
            return offset;
        }
    };
}

fn validateConfiguration(comptime chunk_bytes: usize, comptime window: usize) void {
    if (chunk_bytes == 0) @compileError("PLOOF-E3490 upload chunk size must be nonzero");
    if (chunk_bytes > chunk_bytes_hard_max) {
        @compileError("PLOOF-E3491 upload chunk size exceeds 1 MiB");
    }
    if (window == 0) @compileError("PLOOF-E3492 upload window must be nonzero");
    if (window > window_hard_max) @compileError("PLOOF-E3493 upload window exceeds 16");
}

test {
    std.testing.refAllDecls(@This());
}
