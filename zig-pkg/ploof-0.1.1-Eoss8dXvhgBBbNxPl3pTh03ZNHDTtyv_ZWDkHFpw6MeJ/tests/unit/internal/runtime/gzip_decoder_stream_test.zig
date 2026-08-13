const std = @import("std");
const builtin = @import("builtin");
const gzip = @import("../../../../src/internal/runtime/gzip/decoder.zig");
const fixture = @import("gzip_decoder_test.zig");
const mailbox_module = @import("../../../../src/internal/runtime/gzip/output_mailbox.zig");

const stream_test_stack_size = if (builtin.sanitize_thread)
    std.Thread.SpawnConfig.default_stack_size
else
    128 * 1024;

const long_gzip = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xed, 0xc1,
    0x81, 0x00, 0x00, 0x00, 0x00, 0x80, 0x20, 0xb6, 0xfd, 0xa5, 0x16, 0xa9,
    0x0a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x6a, 0x80, 0x06, 0x9b, 0xa0, 0x00, 0x00, 0x01,
    0x00,
};

test "streaming gzip handles fragmented concatenated members" {
    var source: fixture.FragmentReader = undefined;
    source.init(&fixture.concatenated_gzip, 1, null);
    var output_bytes: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_bytes);
    const complete = try requireComplete(try gzip.Standard.decodeReaderToWriter(
        &source.interface,
        &output,
        fixture.concatenated_gzip.len,
        output_bytes.len,
    ));
    const expected = "stored-blockfixed Huffman stream: zig zig zig zig";
    try std.testing.expectEqualStrings(expected, output.buffered());
    try std.testing.expectEqual(expected.len, complete.decoded_count);
    try std.testing.expectEqual(fixture.concatenated_gzip.len, complete.encoded_consumed);
    try std.testing.expectEqual(@as(usize, 2), complete.member_count);
}

test "streaming gzip retains only DEFLATE window across long member" {
    var discard = std.Io.Writer.Discarding.init(&.{});
    const complete = try requireComplete(try gzip.Standard.decodeToWriter(
        &long_gzip,
        &discard.writer,
        long_gzip.len,
        65_536,
    ));
    try std.testing.expectEqual(@as(usize, 65_536), complete.decoded_count);
    try std.testing.expectEqual(@as(u64, 65_536), discard.fullCount());

    var limited = std.Io.Writer.Discarding.init(&.{});
    try expectLimit(try gzip.Standard.decodeToWriter(
        &long_gzip,
        &limited.writer,
        long_gzip.len,
        65_535,
    ), .decoded);
    try std.testing.expectEqual(@as(u64, 65_535), limited.fullCount());
}

const StackDecode = struct {
    succeeded: bool = false,

    fn run(self: *StackDecode) void {
        var discard = std.Io.Writer.Discarding.init(&.{});
        const result = gzip.Standard.decodeToWriter(
            &long_gzip,
            &discard.writer,
            long_gzip.len,
            65_536,
        ) catch return;
        self.succeeded = switch (result) {
            .complete => |complete| complete.decoded_count == 65_536,
            else => false,
        };
    }
};

test "streaming gzip fits configured 128 KiB decoder thread stack" {
    try std.testing.expectEqual(
        std.compress.flate.history_len + 4096,
        gzip.standard_stream_buffer_bytes,
    );
    try std.testing.expectEqual(@as(usize, 36_936), gzip.standard_stream_writer_bytes);
    try std.testing.expect(
        gzip.standard_stream_writer_bytes <= gzip.standard_stream_buffer_bytes + 128,
    );
    var decode = StackDecode{};
    const thread = try std.Thread.spawn(
        .{ .stack_size = stream_test_stack_size },
        StackDecode.run,
        .{&decode},
    );
    thread.join();
    try std.testing.expect(decode.succeeded);
}

test "streaming gzip enforces exact encoded decoded and member limits" {
    const expected_length = "stored-blockfixed Huffman stream: zig zig zig zig".len;
    var exact_bytes: [expected_length]u8 = undefined;
    var exact = std.Io.Writer.fixed(&exact_bytes);
    _ = try requireComplete(try gzip.Standard.decodeToWriter(
        &fixture.concatenated_gzip,
        &exact,
        fixture.concatenated_gzip.len,
        expected_length,
    ));

    var output_bytes: [128]u8 = undefined;
    var encoded = std.Io.Writer.fixed(&output_bytes);
    try expectLimit(try gzip.Standard.decodeToWriter(
        &fixture.stored_gzip,
        &encoded,
        fixture.stored_gzip.len - 1,
        output_bytes.len,
    ), .encoded);
    try std.testing.expectEqual(@as(usize, 0), encoded.end);

    var decoded = std.Io.Writer.fixed(&output_bytes);
    try expectLimit(try gzip.Standard.decodeToWriter(
        &fixture.concatenated_gzip,
        &decoded,
        fixture.concatenated_gzip.len,
        expected_length - 1,
    ), .decoded);

    var members = std.Io.Writer.fixed(&output_bytes);
    try expectLimit(try gzip.Decoder(1).decodeToWriter(
        &fixture.concatenated_gzip,
        &members,
        fixture.concatenated_gzip.len,
        output_bytes.len,
    ), .members);
}

test "streaming gzip reports source and sink failure exactly" {
    var failed_source: fixture.FragmentReader = undefined;
    failed_source.init(&fixture.stored_gzip, 3, 10);
    var output_bytes: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_bytes);
    try std.testing.expectError(error.ReadFailed, gzip.Standard.decodeReaderToWriter(
        &failed_source.interface,
        &output,
        fixture.stored_gzip.len,
        output_bytes.len,
    ));

    var failed_output: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, gzip.Standard.decodeToWriter(
        &fixture.stored_gzip,
        &failed_output,
        fixture.stored_gzip.len,
        output_bytes.len,
    ));

    var short_bytes: [5]u8 = undefined;
    var short = std.Io.Writer.fixed(&short_bytes);
    try std.testing.expectError(error.WriteFailed, gzip.Standard.decodeToWriter(
        &fixture.stored_gzip,
        &short,
        fixture.stored_gzip.len,
        output_bytes.len,
    ));
}

test "streaming gzip verifies incremental CRC and ISIZE before tail flush" {
    const Mailbox = mailbox_module.Mailbox(64);
    var bad_crc = fixture.stored_gzip;
    bad_crc[bad_crc.len - 8] ^= 1;
    var mailbox: Mailbox = undefined;
    mailbox.init(.{});
    switch (try gzip.Standard.decodeToWriter(
        &bad_crc,
        mailbox.writer(),
        bad_crc.len,
        64,
    )) {
        .malformed => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(mailbox_module.Poll.empty, mailbox.poll());
    try std.testing.expectEqual(@as(usize, "stored-block".len), mailbox.writer().end);
    mailbox.cancel();
    mailbox.reset();

    var bad_size = fixture.stored_gzip;
    bad_size[bad_size.len - 4] ^= 1;
    var discard = std.Io.Writer.Discarding.init(&.{});
    switch (try gzip.Standard.decodeToWriter(
        &bad_size,
        &discard.writer,
        bad_size.len,
        64,
    )) {
        .malformed => {},
        else => return error.TestUnexpectedResult,
    }
}

const TinyMailbox = mailbox_module.Mailbox(1);
const TinyOutcome = enum(u8) { pending, complete, failed };

const TinyDecode = struct {
    mailbox: *TinyMailbox,
    result: gzip.StreamComplete = undefined,
    outcome: std.atomic.Value(TinyOutcome) = .init(.pending),

    fn run(self: *TinyDecode) void {
        const decoded = gzip.Standard.decodeToWriter(
            &fixture.concatenated_gzip,
            self.mailbox.writer(),
            fixture.concatenated_gzip.len,
            128,
        ) catch {
            self.outcome.store(.failed, .release);
            return;
        };
        self.result = requireComplete(decoded) catch {
            self.outcome.store(.failed, .release);
            return;
        };
        self.outcome.store(.complete, .release);
    }
};

test "streaming gzip decodes through one-byte backpressure chunks" {
    const expected = "stored-blockfixed Huffman stream: zig zig zig zig";
    var output: [expected.len]u8 = undefined;
    var mailbox: TinyMailbox = undefined;
    mailbox.init(.{});
    var decode = TinyDecode{ .mailbox = &mailbox };
    const thread = try std.Thread.spawn(.{}, TinyDecode.run, .{&decode});

    for (&output) |*byte| {
        byte.* = waitForByte(&mailbox, &decode.outcome);
        try mailbox.acknowledge();
    }
    thread.join();
    try std.testing.expectEqualStrings(expected, &output);
    try std.testing.expectEqual(TinyOutcome.complete, decode.outcome.load(.acquire));
    try std.testing.expectEqual(expected.len, decode.result.decoded_count);
    try std.testing.expectEqual(@as(usize, 2), decode.result.member_count);
}

const CancelMailbox = mailbox_module.Mailbox(16);

const CancelDecode = struct {
    mailbox: *CancelMailbox,
    outcome: std.atomic.Value(TinyOutcome) = .init(.pending),

    fn run(self: *CancelDecode) void {
        _ = gzip.Standard.decodeToWriter(
            &fixture.bomb_gzip,
            self.mailbox.writer(),
            fixture.bomb_gzip.len,
            8192,
        ) catch {
            self.outcome.store(.failed, .release);
            return;
        };
        self.outcome.store(.complete, .release);
    }
};

test "streaming gzip cancellation fails writer and wakes decoder" {
    var mailbox: CancelMailbox = undefined;
    mailbox.init(.{});
    var decode = CancelDecode{ .mailbox = &mailbox };
    const thread = try std.Thread.spawn(.{}, CancelDecode.run, .{&decode});
    _ = waitForCancelChunk(&mailbox, &decode.outcome);
    mailbox.cancel();
    thread.join();
    try std.testing.expectEqual(TinyOutcome.failed, decode.outcome.load(.acquire));
    try std.testing.expect(mailbox.isCanceled());
    mailbox.reset();
}

fn requireComplete(result: gzip.StreamResult) !gzip.StreamComplete {
    return switch (result) {
        .complete => |complete| complete,
        .malformed, .over_limit => error.TestUnexpectedResult,
    };
}

fn expectLimit(result: gzip.StreamResult, expected: gzip.Limit) !void {
    switch (result) {
        .over_limit => |actual| try std.testing.expectEqual(expected, actual),
        .complete, .malformed => return error.TestUnexpectedResult,
    }
}

fn waitForByte(
    mailbox: *const TinyMailbox,
    outcome: *const std.atomic.Value(TinyOutcome),
) u8 {
    for (0..1_000_000) |_| {
        switch (mailbox.poll()) {
            .chunk => |chunk| return chunk[0],
            .canceled => @panic("tiny gzip mailbox canceled"),
            .empty => if (outcome.load(.acquire) != .pending) {
                @panic("tiny gzip decoder ended before output");
            },
        }
        std.Thread.yield() catch {};
    }
    @panic("tiny gzip mailbox timeout");
}

fn waitForCancelChunk(
    mailbox: *const CancelMailbox,
    outcome: *const std.atomic.Value(TinyOutcome),
) []const u8 {
    for (0..1_000_000) |_| {
        switch (mailbox.poll()) {
            .chunk => |chunk| return chunk,
            .canceled => @panic("cancel gzip mailbox canceled early"),
            .empty => if (outcome.load(.acquire) != .pending) {
                @panic("cancel gzip decoder ended before output");
            },
        }
        std.Thread.yield() catch {};
    }
    @panic("cancel gzip mailbox timeout");
}
