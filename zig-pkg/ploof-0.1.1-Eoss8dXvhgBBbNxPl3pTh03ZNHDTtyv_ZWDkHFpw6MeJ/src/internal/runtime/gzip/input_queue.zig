const std = @import("std");
const futex_epoch = @import("../futex_epoch.zig");
const gzip_decoder = @import("decoder.zig");

pub const Notification = struct {
    context: ?*anyopaque = null,
    wake: *const fn (?*anyopaque) void = ignoreNotification,

    fn publish(self: Notification) void {
        self.wake(self.context);
    }
};

fn ignoreNotification(_: ?*anyopaque) void {}

pub const WriteResult = enum(u8) {
    written,
    full,
};

pub const WriteError = error{
    Closed,
    InputTooLarge,
};

pub const FinishError = error{Closed};

const Terminal = enum(u8) {
    open,
    finished,
    canceled,
};

/// Fixed byte ring with one I/O-thread producer and one decoder-thread consumer.
/// The value must remain at a stable address while its reader or callback is live.
pub fn Queue(comptime capacity: usize, comptime space_threshold: usize) type {
    comptime {
        if (capacity == 0) @compileError("gzip input queue capacity must be positive");
        if (capacity > std.math.maxInt(u32)) {
            @compileError("gzip input queue capacity exceeds maxInt(u32)");
        }
        if (space_threshold == 0 or space_threshold > capacity) {
            @compileError("gzip input queue space threshold must be in 1...capacity");
        }
    }

    return struct {
        const Self = @This();
        const AtomicPosition = std.atomic.Value(u64);
        const position_cycle: u64 = @as(u64, capacity) * 2;

        pub const capacity_bytes: usize = capacity;
        pub const notification_threshold: usize = space_threshold;

        storage: [capacity]u8 = [_]u8{0} ** capacity,

        // Producer-owned cursor. Its release store publishes storage writes.
        write_position: AtomicPosition align(64) = .init(0),
        terminal: std.atomic.Value(Terminal) = .init(.open),
        consumer_event: futex_epoch.Event = .{},

        // Consumer-owned cursor. Its release store permits producer overwrites.
        read_position: AtomicPosition align(64) = .init(0),
        space_ready: std.atomic.Value(bool) = .init(true),
        space_notification: std.atomic.Value(bool) = .init(false),

        notification: Notification,
        reader_buffer: [1]u8,
        interface: std.Io.Reader,

        pub fn init(self: *Self, notification: Notification) void {
            self.* = .{
                .notification = notification,
                .reader_buffer = undefined,
                .interface = .{
                    .vtable = &.{ .stream = stream },
                    .buffer = &self.reader_buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        pub fn reader(self: *Self) *std.Io.Reader {
            return &self.interface;
        }

        /// Copies all bytes or none. Only producer may call this method.
        pub fn tryWrite(self: *Self, bytes: []const u8) WriteError!WriteResult {
            if (bytes.len > capacity) return error.InputTooLarge;
            if (self.terminal.load(.acquire) != .open) return error.Closed;

            const write_position = self.write_position.load(.monotonic);
            const read_position = self.read_position.load(.acquire);
            const used = distance(write_position, read_position);
            if (bytes.len > capacity - used) return .full;

            self.copyIn(write_position, bytes);
            self.write_position.store(advance(write_position, bytes.len), .release);
            if (bytes.len != 0) self.wakeConsumer();
            return .written;
        }

        /// Publishes clean end-of-input after all queued bytes are consumed.
        pub fn finish(self: *Self) FinishError!void {
            if (self.terminal.load(.monotonic) != .open) return error.Closed;
            self.terminal.store(.finished, .release);
            self.wakeConsumer();
        }

        /// Requests cooperative abort; caller discards output after consumer ack.
        pub fn cancel(self: *Self) void {
            self.terminal.store(.canceled, .release);
            self.wakeConsumer();
        }

        /// Producer-only capacity snapshot used to decide whether to submit a receive.
        pub fn producerFreeBytes(self: *const Self) usize {
            const write_position = self.write_position.load(.monotonic);
            const read_position = self.read_position.load(.acquire);
            return capacity - distance(write_position, read_position);
        }

        /// Clears stale notification, consumes readiness, then rechecks before pause.
        pub fn shouldWaitForSpace(self: *Self) bool {
            _ = self.space_notification.swap(false, .acquire);
            _ = self.space_ready.swap(false, .acq_rel);
            if (self.producerFreeBytes() < space_threshold) return true;
            self.space_ready.store(true, .release);
            return false;
        }

        pub fn spaceNotificationPending(self: *const Self) bool {
            return self.space_notification.load(.acquire);
        }

        /// Clears one coalesced edge. Producer must then recheck `producerFreeBytes`.
        pub fn takeSpaceNotification(self: *Self) bool {
            return self.space_notification.swap(false, .acquire);
        }

        /// Quiescent-only secure reuse after decoder thread acknowledges termination.
        pub fn reset(self: *Self) void {
            std.crypto.secureZero(u8, &self.storage);
            self.write_position.store(0, .monotonic);
            self.read_position.store(0, .monotonic);
            self.consumer_event.reset();
            self.space_ready.store(true, .monotonic);
            self.space_notification.store(false, .monotonic);
            self.terminal.store(.open, .release);
            std.crypto.secureZero(u8, &self.reader_buffer);
            self.interface.seek = 0;
            self.interface.end = 0;
        }

        fn stream(
            reader_interface: *std.Io.Reader,
            writer: *std.Io.Writer,
            limit: std.Io.Limit,
        ) std.Io.Reader.StreamError!usize {
            if (limit == .nothing) return 0;
            const self: *Self = @alignCast(@fieldParentPtr("interface", reader_interface));
            while (true) {
                const epoch = self.consumer_event.observe();
                const terminal = self.terminal.load(.acquire);
                if (terminal == .canceled) return error.ReadFailed;

                const read_position = self.read_position.load(.monotonic);
                const write_position = self.write_position.load(.acquire);
                const available = distance(write_position, read_position);
                if (available != 0) {
                    return self.copyOut(writer, limit, read_position, available);
                }
                if (terminal == .finished) return error.EndOfStream;
                if (!self.consumer_event.arm(epoch)) continue;
                self.consumer_event.wait(epoch);
            }
        }

        fn copyIn(self: *Self, write_position: u64, bytes: []const u8) void {
            const start = ringIndex(write_position);
            const first_length = @min(bytes.len, capacity - start);
            @memcpy(self.storage[start..][0..first_length], bytes[0..first_length]);
            @memcpy(self.storage[0 .. bytes.len - first_length], bytes[first_length..]);
        }

        fn copyOut(
            self: *Self,
            writer: *std.Io.Writer,
            limit: std.Io.Limit,
            read_position: u64,
            available: usize,
        ) std.Io.Writer.Error!usize {
            const start = ringIndex(read_position);
            const contiguous = @min(available, capacity - start);
            const selected = limit.sliceConst(self.storage[start..][0..contiguous]);
            const count = try writer.write(selected);
            if (count == 0) return 0;

            const next_read = advance(read_position, count);
            self.read_position.store(next_read, .release);
            self.publishSpaceIfReady(next_read);
            return count;
        }

        fn publishSpaceIfReady(self: *Self, read_position: u64) void {
            const write_position = self.write_position.load(.acquire);
            const free = capacity - distance(write_position, read_position);
            if (free < space_threshold) return;
            if (self.space_ready.swap(true, .acq_rel)) return;
            self.publishSpaceNotification();
        }

        fn publishSpaceNotification(self: *Self) void {
            if (self.space_notification.swap(true, .acq_rel)) return;
            self.notification.publish();
        }

        fn wakeConsumer(self: *Self) void {
            self.consumer_event.notify();
        }

        fn ringIndex(position: u64) usize {
            return @intCast(position % capacity);
        }

        fn advance(position: u64, count: usize) u64 {
            return (position + count) % position_cycle;
        }

        fn distance(write_position: u64, read_position: u64) usize {
            const value = if (write_position >= read_position)
                write_position - read_position
            else
                position_cycle - read_position + write_position;
            if (value > capacity) @panic("gzip input queue cursor invariant");
            return @intCast(value);
        }
    };
}

const NotificationCounter = struct {
    count: std.atomic.Value(u32) = .init(0),

    fn wake(context: ?*anyopaque) void {
        const self: *NotificationCounter = @ptrCast(@alignCast(context.?));
        _ = self.count.fetchAdd(1, .release);
    }
};

test "gzip input queue preflights writes wraps and publishes threshold edge" {
    const TestQueue = Queue(8, 4);
    var counter = NotificationCounter{};
    var queue: TestQueue = undefined;
    queue.init(.{ .context = &counter, .wake = NotificationCounter.wake });
    try std.testing.expect(!queue.shouldWaitForSpace());
    try std.testing.expect(!queue.spaceNotificationPending());

    try std.testing.expectEqual(WriteResult.written, try queue.tryWrite("abcdef"));
    try std.testing.expectEqual(WriteResult.full, try queue.tryWrite("xyz"));
    try std.testing.expectError(error.InputTooLarge, queue.tryWrite("123456789"));
    try std.testing.expectEqual(@as(usize, 2), queue.producerFreeBytes());
    try std.testing.expect(queue.shouldWaitForSpace());

    var first: [4]u8 = undefined;
    try queue.reader().readSliceAll(&first);
    try std.testing.expectEqualStrings("abcd", &first);
    try std.testing.expect(queue.spaceNotificationPending());
    try std.testing.expectEqual(@as(u32, 1), counter.count.load(.acquire));
    try std.testing.expect(queue.takeSpaceNotification());

    try std.testing.expectEqual(WriteResult.written, try queue.tryWrite("WXYZ"));
    try std.testing.expect(queue.shouldWaitForSpace());
    try queue.finish();
    var rest: [6]u8 = undefined;
    try queue.reader().readSliceAll(&rest);
    try std.testing.expectEqualStrings("efWXYZ", &rest);
    try std.testing.expectEqual(@as(u32, 2), counter.count.load(.acquire));
    try std.testing.expect(queue.spaceNotificationPending());
    try std.testing.expectError(error.EndOfStream, queue.reader().takeByte());
    try std.testing.expectError(error.Closed, queue.tryWrite("x"));
    try std.testing.expectError(error.Closed, queue.finish());
}

test "gzip input queue non-power-of-two cursor survives exact cycle wrap" {
    var queue: Queue(7, 3) = undefined;
    queue.init(.{});
    const input = "1234567";

    for (0..4) |_| {
        try std.testing.expectEqual(WriteResult.written, try queue.tryWrite(input));
        try std.testing.expectEqual(@as(usize, 0), queue.producerFreeBytes());
        try std.testing.expectEqual(WriteResult.full, try queue.tryWrite("x"));
        try std.testing.expect(queue.shouldWaitForSpace());
        var output: [input.len]u8 = undefined;
        try queue.reader().readSliceAll(&output);
        try std.testing.expectEqualStrings(input, &output);
        try std.testing.expectEqual(@as(usize, 7), queue.producerFreeBytes());
        _ = queue.takeSpaceNotification();
    }

    try std.testing.expectEqual(WriteResult.written, try queue.tryWrite("tail"));
    try queue.finish();
    var tail: [4]u8 = undefined;
    try queue.reader().readSliceAll(&tail);
    try std.testing.expectEqualStrings("tail", &tail);
    try std.testing.expectError(error.EndOfStream, queue.reader().takeByte());
}

const WaitOutcome = enum(u8) {
    pending,
    byte,
    ended,
    failed,
};

const WaitHarness = struct {
    queue: *Queue(8, 4),
    ready: std.atomic.Value(bool) = .init(false),
    outcome: std.atomic.Value(WaitOutcome) = .init(.pending),

    fn consume(self: *WaitHarness) void {
        self.ready.store(true, .release);
        const byte = self.queue.reader().takeByte() catch |err| {
            const outcome: WaitOutcome = switch (err) {
                error.EndOfStream => .ended,
                error.ReadFailed => .failed,
            };
            self.outcome.store(outcome, .release);
            return;
        };
        if (byte != 'q') @panic("gzip input queue test byte mismatch");
        self.outcome.store(.byte, .release);
    }
};

test "gzip input queue cannot lose producer wake or cancellation" {
    for (0..96) |iteration| {
        var queue: Queue(8, 4) = undefined;
        queue.init(.{});
        var harness = WaitHarness{ .queue = &queue };
        const thread = try std.Thread.spawn(.{}, WaitHarness.consume, .{&harness});
        waitForBool(&harness.ready);
        waitForConsumer(&queue.consumer_event);

        const expected: WaitOutcome = switch (iteration % 3) {
            0 => result: {
                try std.testing.expectEqual(WriteResult.written, try queue.tryWrite("q"));
                break :result .byte;
            },
            1 => result: {
                try queue.finish();
                break :result .ended;
            },
            else => result: {
                queue.cancel();
                break :result .failed;
            },
        };
        waitForOutcome(&harness.outcome, &queue);
        thread.join();
        try std.testing.expectEqual(expected, harness.outcome.load(.acquire));
    }
}

const FinishHarness = struct {
    queue: *Queue(8, 4),
    ready: std.atomic.Value(bool) = .init(false),
    complete: std.atomic.Value(bool) = .init(false),

    fn consume(self: *FinishHarness) void {
        self.ready.store(true, .release);
        const byte = self.queue.reader().takeByte() catch {
            @panic("gzip input queue lost byte published before finish");
        };
        if (byte != 'q') @panic("gzip input queue finish byte mismatch");
        _ = self.queue.reader().takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                self.complete.store(true, .release);
                return;
            },
            error.ReadFailed => @panic("gzip input queue finish failed"),
        };
        @panic("gzip input queue exposed byte after finish");
    }
};

test "gzip input queue drains bytes published immediately before finish" {
    for (0..96) |_| {
        var queue: Queue(8, 4) = undefined;
        queue.init(.{});
        var harness = FinishHarness{ .queue = &queue };
        const thread = try std.Thread.spawn(.{}, FinishHarness.consume, .{&harness});
        waitForBool(&harness.ready);
        waitForConsumer(&queue.consumer_event);
        try std.testing.expectEqual(WriteResult.written, try queue.tryWrite("q"));
        try queue.finish();
        thread.join();
        try std.testing.expect(harness.complete.load(.acquire));
    }
}

const SpaceRaceHarness = struct {
    queue: *Queue(8, 4),
    go: std.atomic.Value(bool) = .init(false),

    fn consume(self: *SpaceRaceHarness) void {
        waitForBool(&self.go);
        var output: [4]u8 = undefined;
        self.queue.reader().readSliceAll(&output) catch {
            @panic("gzip input queue space-race read failed");
        };
        if (!std.mem.eql(u8, &output, "abcd")) {
            @panic("gzip input queue space-race bytes mismatch");
        }
    }
};

test "gzip input queue space readiness cannot lose concurrent consumption" {
    for (0..96) |_| {
        var counter = NotificationCounter{};
        var queue: Queue(8, 4) = undefined;
        queue.init(.{ .context = &counter, .wake = NotificationCounter.wake });
        try std.testing.expectEqual(WriteResult.written, try queue.tryWrite("abcdefgh"));
        var harness = SpaceRaceHarness{ .queue = &queue };
        const thread = try std.Thread.spawn(.{}, SpaceRaceHarness.consume, .{&harness});
        harness.go.store(true, .release);
        const waiting = queue.shouldWaitForSpace();
        thread.join();

        try std.testing.expectEqual(@as(usize, 4), queue.producerFreeBytes());
        if (waiting) {
            try std.testing.expect(queue.spaceNotificationPending());
            try std.testing.expectEqual(@as(u32, 1), counter.count.load(.acquire));
        }
    }
}

fn waitForBool(value: *const std.atomic.Value(bool)) void {
    for (0..1_000_000) |_| {
        if (value.load(.acquire)) return;
        std.Thread.yield() catch {};
    }
    @panic("gzip input queue test synchronization timeout");
}

fn waitForConsumer(event: *const futex_epoch.Event) void {
    for (0..1_000_000) |_| {
        if (event.waiting()) return;
        std.Thread.yield() catch {};
    }
    @panic("gzip input queue consumer wait timeout");
}

fn waitForOutcome(value: *const std.atomic.Value(WaitOutcome), queue: *Queue(8, 4)) void {
    for (0..1_000_000) |_| {
        if (value.load(.acquire) != .pending) return;
        std.Thread.yield() catch {};
    }
    queue.cancel();
    @panic("gzip input queue test consumer timeout");
}

const DecodeOutcome = enum(u8) {
    pending,
    complete,
    rejected,
};

const DecodeHarness = struct {
    queue: *Queue(16, 8),
    output: [32]u8 = undefined,
    decoded_length: usize = 0,
    outcome: std.atomic.Value(DecodeOutcome) = .init(.pending),

    fn decode(self: *DecodeHarness) void {
        const result = gzip_decoder.Standard.decodeReader(
            self.queue.reader(),
            &self.output,
            stored_gzip.len,
            self.output.len,
        ) catch {
            self.outcome.store(.rejected, .release);
            return;
        };
        switch (result) {
            .complete => |complete| {
                self.decoded_length = complete.decoded_count;
                self.outcome.store(.complete, .release);
            },
            else => self.outcome.store(.rejected, .release),
        }
    }
};

const stored_gzip = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03, 0x01, 0x0c,
    0x00, 0xf3, 0xff, 0x73, 0x74, 0x6f, 0x72, 0x65, 0x64, 0x2d, 0x62, 0x6c,
    0x6f, 0x63, 0x6b, 0x4a, 0xb0, 0xba, 0x81, 0x0c, 0x00, 0x00, 0x00,
};

test "gzip decoder consumes fragmented queue without allocation" {
    var counter = NotificationCounter{};
    var queue: Queue(16, 8) = undefined;
    queue.init(.{
        .context = &counter,
        .wake = NotificationCounter.wake,
    });
    var harness = DecodeHarness{ .queue = &queue };
    const thread = try std.Thread.spawn(.{}, DecodeHarness.decode, .{&harness});

    var offset: usize = 0;
    while (offset < stored_gzip.len) {
        const length = @min(@as(usize, 5), stored_gzip.len - offset);
        switch (try queue.tryWrite(stored_gzip[offset..][0..length])) {
            .written => offset += length,
            .full => {
                const before = counter.count.load(.acquire);
                if (queue.shouldWaitForSpace()) {
                    try waitForNotificationAfter(&counter, before);
                }
            },
        }
    }
    try queue.finish();
    waitForDecode(&harness.outcome, &queue);
    thread.join();

    try std.testing.expectEqual(DecodeOutcome.complete, harness.outcome.load(.acquire));
    try std.testing.expectEqualStrings("stored-block", harness.output[0..harness.decoded_length]);
}

fn waitForNotificationAfter(counter: *const NotificationCounter, before: u32) !void {
    for (0..1_000_000) |_| {
        if (counter.count.load(.acquire) > before) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

fn waitForDecode(value: *const std.atomic.Value(DecodeOutcome), queue: *Queue(16, 8)) void {
    for (0..1_000_000) |_| {
        if (value.load(.acquire) != .pending) return;
        std.Thread.yield() catch {};
    }
    queue.cancel();
    @panic("gzip input queue decoder timeout");
}

test "gzip input queue cancellation rejects later reads and reset securely clears state" {
    var queue: Queue(8, 4) = undefined;
    queue.init(.{});
    try std.testing.expectEqual(WriteResult.written, try queue.tryWrite("secret"));
    queue.cancel();
    try std.testing.expectError(error.ReadFailed, queue.reader().takeByte());
    queue.reset();

    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 8), &queue.storage);
    try std.testing.expectEqual(@as(usize, 8), queue.producerFreeBytes());
    try std.testing.expectEqual(WriteResult.written, try queue.tryWrite("new"));
    try queue.finish();
    var output: [3]u8 = undefined;
    try queue.reader().readSliceAll(&output);
    try std.testing.expectEqualStrings("new", &output);
}

test "gzip input queue bounded wrap and terminal invariants fuzz" {
    try std.testing.fuzz({}, fuzzQueue, .{ .corpus = &queue_fuzz_corpus });
}

const queue_fuzz_corpus = struct {
    const wrap = smithInput("\x00\x01\x02\x03\x04\x05\x06\x07" ++
        "\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f");
    const full = smithInput("\x00\x04\x08\x0c\x10\x14\x18\x1c\x20");
    const alternating = smithInput("\x00\x01" ** 32);
    const values = [_][]const u8{ &wrap, &full, &alternating };
}.values;

fn smithInput(comptime value: []const u8) [value.len + 4]u8 {
    var input: [value.len + 4]u8 = undefined;
    const length: u32 = @intCast(value.len);
    inline for (0..4) |index| input[index] = @truncate(length >> (index * 8));
    @memcpy(input[4..], value);
    return input;
}

const QueueFuzzModel = struct {
    storage: [7]u8 = undefined,
    head: usize = 0,
    length: usize = 0,
    space_ready: bool = true,
    notification_pending: bool = false,
    notification_count: u32 = 0,

    fn free(self: *const QueueFuzzModel) usize {
        return self.storage.len - self.length;
    }

    fn write(self: *QueueFuzzModel, queue: *Queue(7, 3), bytes: []const u8) !void {
        if (bytes.len > self.storage.len) {
            return std.testing.expectError(error.InputTooLarge, queue.tryWrite(bytes));
        }
        const result = try queue.tryWrite(bytes);
        if (bytes.len > self.free()) {
            return std.testing.expectEqual(WriteResult.full, result);
        }
        try std.testing.expectEqual(WriteResult.written, result);
        for (bytes) |byte| {
            self.storage[(self.head + self.length) % self.storage.len] = byte;
            self.length += 1;
        }
    }

    fn read(self: *QueueFuzzModel, queue: *Queue(7, 3)) !void {
        if (self.length == 0) return;
        try std.testing.expectEqual(self.storage[self.head], try queue.reader().takeByte());
        self.head = (self.head + 1) % self.storage.len;
        self.length -= 1;
        if (self.free() < 3) return;
        const was_ready = self.space_ready;
        self.space_ready = true;
        if (was_ready) return;
        if (!self.notification_pending) self.notification_count += 1;
        self.notification_pending = true;
    }

    fn prepareWait(self: *QueueFuzzModel, queue: *Queue(7, 3)) !void {
        self.notification_pending = false;
        self.space_ready = false;
        const expected = self.free() < 3;
        if (!expected) self.space_ready = true;
        try std.testing.expectEqual(expected, queue.shouldWaitForSpace());
    }

    fn takeNotification(self: *QueueFuzzModel, queue: *Queue(7, 3)) !void {
        try std.testing.expectEqual(
            self.notification_pending,
            queue.takeSpaceNotification(),
        );
        self.notification_pending = false;
    }

    fn expectState(
        self: *const QueueFuzzModel,
        queue: *const Queue(7, 3),
        counter: *const NotificationCounter,
    ) !void {
        try std.testing.expectEqual(self.free(), queue.producerFreeBytes());
        try std.testing.expectEqual(
            self.notification_pending,
            queue.spaceNotificationPending(),
        );
        try std.testing.expectEqual(
            self.notification_count,
            counter.count.load(.acquire),
        );
    }
};

fn fuzzQueue(_: void, smith: *std.testing.Smith) !void {
    var actions_storage: [128]u8 = undefined;
    const actions = actions_storage[0..smith.slice(&actions_storage)];
    var counter = NotificationCounter{};
    var queue: Queue(7, 3) = undefined;
    queue.init(.{ .context = &counter, .wake = NotificationCounter.wake });
    var model = QueueFuzzModel{};

    for (actions) |action| {
        switch (action & 7) {
            0, 5 => {
                var bytes: [8]u8 = undefined;
                for (&bytes, 0..) |*byte, index| byte.* = action +% @as(u8, @intCast(index));
                const length = (action >> 3) % 9;
                try model.write(&queue, bytes[0..length]);
            },
            1 => try model.read(&queue),
            2 => try model.prepareWait(&queue),
            3 => try model.takeNotification(&queue),
            else => {},
        }
        try model.expectState(&queue, &counter);
    }

    if (smith.value(bool)) {
        queue.cancel();
        try std.testing.expectError(error.ReadFailed, queue.reader().takeByte());
    } else {
        try queue.finish();
        while (model.length != 0) try model.read(&queue);
        try std.testing.expectError(error.EndOfStream, queue.reader().takeByte());
        try model.expectState(&queue, &counter);
    }

    queue.reset();
    model.head = 0;
    model.length = 0;
    model.space_ready = true;
    model.notification_pending = false;
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 7), &queue.storage);
    try model.expectState(&queue, &counter);
    if (smith.value(bool)) {
        try std.testing.expectEqual(WriteResult.written, try queue.tryWrite("z"));
        try queue.finish();
        try std.testing.expectEqual(@as(u8, 'z'), try queue.reader().takeByte());
        try std.testing.expectError(error.EndOfStream, queue.reader().takeByte());
    } else {
        queue.cancel();
        try std.testing.expectError(error.ReadFailed, queue.reader().takeByte());
    }
}
