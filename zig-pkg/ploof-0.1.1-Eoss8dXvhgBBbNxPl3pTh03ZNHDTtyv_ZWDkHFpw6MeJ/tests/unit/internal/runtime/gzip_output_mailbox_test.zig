const std = @import("std");
const mailbox_module = @import("../../../../src/internal/runtime/gzip/output_mailbox.zig");

const Mailbox4 = mailbox_module.Mailbox(4);

const Outcome = enum(u8) {
    pending,
    complete,
    failed,
};

const Counter = struct {
    value: std.atomic.Value(u32) = .init(0),

    fn wake(context: ?*anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(context.?));
        _ = self.value.fetchAdd(1, .release);
    }
};

const Producer = struct {
    mailbox: *Mailbox4,
    input: []const u8,
    outcome: std.atomic.Value(Outcome) = .init(.pending),

    fn run(self: *Producer) void {
        self.mailbox.writer().writeAll(self.input) catch {
            self.outcome.store(.failed, .release);
            return;
        };
        self.mailbox.writer().flush() catch {
            self.outcome.store(.failed, .release);
            return;
        };
        self.outcome.store(.complete, .release);
    }
};

test "gzip output mailbox keeps borrowed chunk stable until acknowledgement" {
    var counter = Counter{};
    var mailbox: Mailbox4 = undefined;
    mailbox.init(.{ .context = &counter, .wake = Counter.wake });
    var producer = Producer{ .mailbox = &mailbox, .input = "abcdef" };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});

    const first = waitForChunk(&mailbox);
    try std.testing.expectEqualStrings("abcd", first);
    try waitForProducer(&mailbox);
    try std.testing.expectEqualStrings("abcd", chunkNow(&mailbox));
    try std.testing.expectEqual(Outcome.pending, producer.outcome.load(.acquire));
    try mailbox.acknowledge();

    const second = waitForChunk(&mailbox);
    try std.testing.expectEqualStrings("ef", second);
    try std.testing.expectEqual(Outcome.pending, producer.outcome.load(.acquire));
    try mailbox.acknowledge();
    thread.join();
    try std.testing.expectEqual(Outcome.complete, producer.outcome.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), counter.value.load(.acquire));
    try std.testing.expectError(error.NotReady, mailbox.acknowledge());

    mailbox.reset();
    for (Mailbox4.TestAccess.storage(&mailbox)) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "gzip output mailbox acknowledgement cannot lose producer wake" {
    for (0..128) |_| {
        var mailbox: Mailbox4 = undefined;
        mailbox.init(.{});
        var producer = Producer{ .mailbox = &mailbox, .input = "x" };
        const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
        try std.testing.expectEqualStrings("x", waitForChunk(&mailbox));
        try mailbox.acknowledge();
        thread.join();
        try std.testing.expectEqual(Outcome.complete, producer.outcome.load(.acquire));
    }
}

test "gzip output mailbox cancellation wakes blocked producer" {
    for (0..128) |_| {
        var mailbox: Mailbox4 = undefined;
        mailbox.init(.{});
        var producer = Producer{ .mailbox = &mailbox, .input = "stop" };
        const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
        _ = waitForChunk(&mailbox);
        try waitForProducer(&mailbox);
        mailbox.cancel();
        thread.join();

        try std.testing.expect(mailbox.isCanceled());
        try std.testing.expectEqual(Outcome.failed, producer.outcome.load(.acquire));
        try std.testing.expectError(error.Canceled, mailbox.acknowledge());
        mailbox.reset();
        try std.testing.expect(!mailbox.isCanceled());
    }
}

test "gzip output mailbox cancellation races publication without deadlock" {
    for (0..128) |_| {
        var mailbox: Mailbox4 = undefined;
        mailbox.init(.{});
        var producer = Producer{ .mailbox = &mailbox, .input = "race" };
        const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
        mailbox.cancel();
        thread.join();
        try std.testing.expectEqual(Outcome.failed, producer.outcome.load(.acquire));
        mailbox.reset();
    }
}

const TrafficMailbox = mailbox_module.Mailbox(3);
const traffic_bytes: usize = 4096;

const TrafficProducer = struct {
    mailbox: *TrafficMailbox,
    input: *const [traffic_bytes]u8,
    outcome: std.atomic.Value(Outcome) = .init(.pending),

    fn run(self: *TrafficProducer) void {
        self.mailbox.writer().writeAll(self.input) catch {
            self.outcome.store(.failed, .release);
            return;
        };
        self.mailbox.writer().flush() catch {
            self.outcome.store(.failed, .release);
            return;
        };
        self.outcome.store(.complete, .release);
    }
};

test "gzip output mailbox preserves long concurrent byte stream" {
    var input: [traffic_bytes]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @truncate(index *% 131);
    var output: [traffic_bytes]u8 = undefined;
    var mailbox: TrafficMailbox = undefined;
    mailbox.init(.{});
    var producer = TrafficProducer{ .mailbox = &mailbox, .input = &input };
    const thread = try std.Thread.spawn(.{}, TrafficProducer.run, .{&producer});

    var offset: usize = 0;
    while (offset < output.len) {
        const chunk = waitForTrafficChunk(&mailbox);
        @memcpy(output[offset..][0..chunk.len], chunk);
        offset += chunk.len;
        try mailbox.acknowledge();
    }
    thread.join();
    try std.testing.expectEqualSlices(u8, &input, &output);
    try std.testing.expectEqual(Outcome.complete, producer.outcome.load(.acquire));
}

fn waitForChunk(mailbox: *const Mailbox4) []const u8 {
    for (0..1_000_000) |_| {
        switch (mailbox.poll()) {
            .chunk => |chunk| return chunk,
            .empty => std.Thread.yield() catch {},
            .canceled => @panic("gzip output mailbox canceled while waiting for chunk"),
        }
    }
    @panic("gzip output mailbox chunk timeout");
}

fn chunkNow(mailbox: *const Mailbox4) []const u8 {
    return switch (mailbox.poll()) {
        .chunk => |chunk| chunk,
        .empty, .canceled => @panic("gzip output mailbox chunk unavailable"),
    };
}

fn waitForProducer(mailbox: *const Mailbox4) !void {
    for (0..1_000_000) |_| {
        if (Mailbox4.TestAccess.producerWaiting(mailbox)) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

fn waitForTrafficChunk(mailbox: *const TrafficMailbox) []const u8 {
    for (0..1_000_000) |_| {
        switch (mailbox.poll()) {
            .chunk => |chunk| return chunk,
            .empty => std.Thread.yield() catch {},
            .canceled => @panic("gzip output traffic canceled"),
        }
    }
    @panic("gzip output traffic timeout");
}
