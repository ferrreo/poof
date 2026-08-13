const std = @import("std");
const builtin = @import("builtin");
const futex_epoch = @import("../futex_epoch.zig");

pub const Notification = struct {
    context: ?*anyopaque = null,
    wake: *const fn (?*anyopaque) void = ignoreNotification,

    fn publish(self: Notification) void {
        self.wake(self.context);
    }
};

fn ignoreNotification(_: ?*anyopaque) void {}

pub const Poll = union(enum) {
    empty,
    chunk: []const u8,
    canceled,
};

pub const AcknowledgeError = error{
    NotReady,
    Canceled,
};

const Phase = enum(u8) {
    empty,
    ready,
    canceled,
};

/// One-chunk SPSC mailbox. Producer blocks until consumer acknowledges the
/// borrowed chunk, so its bytes remain stable without copying or allocation.
pub fn Mailbox(comptime capacity: usize) type {
    comptime {
        if (capacity == 0) @compileError("gzip output mailbox capacity must be positive");
        if (capacity > std.math.maxInt(u32)) {
            @compileError("gzip output mailbox capacity exceeds maxInt(u32)");
        }
    }

    return struct {
        const Self = @This();

        pub const capacity_bytes: usize = capacity;

        storage: [capacity]u8 = [_]u8{0} ** capacity,
        published_length: usize = 0,
        phase: std.atomic.Value(Phase) align(64) = .init(.empty),
        producer_event: futex_epoch.Event = .{},
        notification: Notification,
        interface: std.Io.Writer,

        pub fn init(self: *Self, notification: Notification) void {
            self.* = .{
                .notification = notification,
                .interface = .{
                    .vtable = &.{
                        .drain = drain,
                        .flush = flush,
                    },
                    .buffer = &self.storage,
                },
            };
        }

        pub fn writer(self: *Self) *std.Io.Writer {
            return &self.interface;
        }

        /// Consumer-only snapshot. Chunk is borrowed until `acknowledge`.
        pub fn poll(self: *const Self) Poll {
            return switch (self.phase.load(.acquire)) {
                .empty => .empty,
                .ready => .{ .chunk = self.storage[0..self.published_length] },
                .canceled => .canceled,
            };
        }

        /// Consumer-only release of the current borrowed chunk.
        pub fn acknowledge(self: *Self) AcknowledgeError!void {
            const previous = self.phase.cmpxchgStrong(
                .ready,
                .empty,
                .release,
                .acquire,
            ) orelse {
                self.producer_event.notify();
                return;
            };
            return switch (previous) {
                .empty => error.NotReady,
                .canceled => error.Canceled,
                .ready => unreachable,
            };
        }

        /// Consumer requests cooperative abort and wakes a blocked producer.
        pub fn cancel(self: *Self) void {
            self.phase.store(.canceled, .release);
            self.producer_event.notify();
        }

        pub fn isCanceled(self: *const Self) bool {
            return self.phase.load(.acquire) == .canceled;
        }

        /// Quiescent-only secure reuse after producer termination.
        pub fn reset(self: *Self) void {
            if (self.phase.load(.acquire) == .ready) {
                @panic("cannot reset gzip output mailbox with borrowed chunk");
            }
            if (self.producer_event.waiting()) {
                @panic("cannot reset gzip output mailbox with blocked producer");
            }
            std.crypto.secureZero(u8, &self.storage);
            self.published_length = 0;
            self.producer_event.reset();
            self.interface.end = 0;
            self.phase.store(.empty, .release);
        }

        fn drain(
            writer_interface: *std.Io.Writer,
            data: []const []const u8,
            splat: usize,
        ) std.Io.Writer.Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", writer_interface));
            if (self.isCanceled()) return error.WriteFailed;
            try self.publishBuffered(writer_interface);
            const length = self.fill(data, splat);
            writer_interface.end = length;
            return length;
        }

        fn flush(writer_interface: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *Self = @alignCast(@fieldParentPtr("interface", writer_interface));
            if (self.isCanceled()) return error.WriteFailed;
            try self.publishBuffered(writer_interface);
        }

        fn publishBuffered(
            self: *Self,
            writer_interface: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            if (writer_interface.end == 0) return;
            try self.publish(writer_interface.end);
            writer_interface.end = 0;
        }

        fn fill(self: *Self, data: []const []const u8, splat: usize) usize {
            var length: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                length += self.copyAt(length, bytes);
                if (length == capacity) return length;
            }
            const pattern = data[data.len - 1];
            for (0..splat) |_| {
                length += self.copyAt(length, pattern);
                if (length == capacity) return length;
            }
            return length;
        }

        fn copyAt(self: *Self, offset: usize, bytes: []const u8) usize {
            const length = @min(bytes.len, capacity - offset);
            @memcpy(self.storage[offset..][0..length], bytes[0..length]);
            return length;
        }

        fn publish(self: *Self, length: usize) std.Io.Writer.Error!void {
            self.published_length = length;
            const previous = self.phase.cmpxchgStrong(
                .empty,
                .ready,
                .release,
                .acquire,
            );
            if (previous) |phase| return switch (phase) {
                .canceled => error.WriteFailed,
                .empty, .ready => unreachable,
            };
            self.notification.publish();
            return self.waitForAcknowledgement();
        }

        fn waitForAcknowledgement(self: *Self) std.Io.Writer.Error!void {
            while (true) {
                const epoch = self.producer_event.observe();
                switch (self.phase.load(.acquire)) {
                    .empty => return,
                    .canceled => return error.WriteFailed,
                    .ready => {},
                }
                if (!self.producer_event.arm(epoch)) continue;
                self.producer_event.wait(epoch);
            }
        }

        pub const TestAccess = if (builtin.is_test) struct {
            pub fn storage(self: *const Self) []const u8 {
                return &self.storage;
            }

            pub fn producerWaiting(self: *const Self) bool {
                return self.producer_event.waiting();
            }
        } else struct {};
    };
}
