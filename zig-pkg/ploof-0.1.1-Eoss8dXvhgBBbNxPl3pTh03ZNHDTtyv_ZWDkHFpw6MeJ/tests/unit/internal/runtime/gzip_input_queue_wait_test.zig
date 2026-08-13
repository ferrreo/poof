const std = @import("std");
const futex_epoch = @import("../../../../src/internal/runtime/futex_epoch.zig");
const gzip_input_queue = @import("../../../../src/internal/runtime/gzip/input_queue.zig");

const TestQueue = gzip_input_queue.Queue(8, 4);

const Harness = struct {
    queue: *TestQueue,
    complete: std.atomic.Value(bool) = .init(false),

    fn produce(self: *Harness) void {
        const result = self.queue.tryWrite("a") catch {
            @panic("gzip input queue delayed producer failed");
        };
        if (result != .written) @panic("gzip input queue delayed producer was full");
    }

    fn consume(self: *Harness) void {
        const first = self.queue.reader().takeByte() catch {
            @panic("gzip input queue delayed first read failed");
        };
        const second = self.queue.reader().takeByte() catch {
            @panic("gzip input queue delayed second read failed");
        };
        if (first != 'a' or second != 'b') @panic("gzip input queue delayed bytes mismatch");
        self.complete.store(true, .release);
    }
};

test "gzip input queue old notification cannot clear later consumer wait" {
    var queue: TestQueue = undefined;
    queue.init(.{});
    var harness = Harness{ .queue = &queue };
    futex_epoch.TestAccess.pauseNotify(false);
    defer futex_epoch.TestAccess.pauseNotify(false);
    futex_epoch.TestAccess.pauseNotify(true);

    const producer = try std.Thread.spawn(.{}, Harness.produce, .{&harness});
    waitForNotifyPause();
    const consumer = try std.Thread.spawn(.{}, Harness.consume, .{&harness});
    waitForConsumer(&queue.consumer_event);
    futex_epoch.TestAccess.pauseNotify(false);
    producer.join();

    try std.testing.expect(queue.consumer_event.waiting());
    try std.testing.expectEqual(.written, try queue.tryWrite("b"));
    waitForComplete(&harness.complete);
    consumer.join();
}

fn waitForNotifyPause() void {
    for (0..1_000_000) |_| {
        if (futex_epoch.TestAccess.notifyPaused()) return;
        std.Thread.yield() catch {};
    }
    @panic("gzip input queue notification pause timeout");
}

fn waitForConsumer(event: *const futex_epoch.Event) void {
    for (0..1_000_000) |_| {
        if (event.waiting()) return;
        std.Thread.yield() catch {};
    }
    @panic("gzip input queue consumer wait timeout");
}

fn waitForComplete(complete: *const std.atomic.Value(bool)) void {
    for (0..1_000_000) |_| {
        if (complete.load(.acquire)) return;
        std.Thread.yield() catch {};
    }
    @panic("gzip input queue delayed consumer timeout");
}
