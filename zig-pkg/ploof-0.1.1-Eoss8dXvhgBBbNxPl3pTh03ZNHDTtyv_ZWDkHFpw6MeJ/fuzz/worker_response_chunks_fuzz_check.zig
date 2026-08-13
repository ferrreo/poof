const std = @import("std");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const response_chunks = @import("../src/internal/runtime/worker/response_chunks.zig");

const chunk_bytes: u16 = 17;
const chunk_count: u16 = 8;
const capacity = chunk_bytes * chunk_count;
const TestPool = response_chunks.Pool(chunk_bytes);

test "response chunk transaction structured differential fuzz" {
    try std.testing.fuzz({}, fuzzTransaction, .{ .corpus = &corpus });
}

fn fuzzTransaction(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [256]u8 = undefined;
    const input = input_storage[0..smith.slice(&input_storage)];
    const limit = smith.valueRangeAtMost(u32, 0, 192);
    const fragment_seed = smith.value(u8);

    var indices: [chunk_count]u16 = undefined;
    var nodes: [chunk_count]response_chunks.Node = undefined;
    var storage: [capacity]u8 = @splat(0);
    var pool = try TestPool.init(&indices, &nodes, &storage);
    var writer = pool.writer(limit);
    var offset: usize = 0;
    var failed = false;

    while (offset < input.len) {
        const requested = 1 + ((input[offset] ^ fragment_seed) % 31);
        const end = @min(input.len, offset + requested);
        const next_length = end;
        const expected_error: ?WriteError = if (next_length > limit)
            .too_large
        else if (chunksFor(next_length) > chunk_count)
            .exhausted
        else
            null;
        if (expected_error) |expected| {
            switch (expected) {
                .too_large => try std.testing.expectError(
                    error.ResponseBodyTooLarge,
                    writer.write(input[offset..end]),
                ),
                .exhausted => try std.testing.expectError(
                    error.ResponseChunksExhausted,
                    writer.write(input[offset..end]),
                ),
            }
            failed = true;
            break;
        }
        try writer.write(input[offset..end]);
        offset = end;
    }

    if (failed) {
        try std.testing.expectEqual(chunk_count, pool.available());
        try std.testing.expectError(error.WriterTerminal, writer.finish());
    } else {
        const chain = try writer.finish();
        try std.testing.expectEqual(@as(u32, @intCast(input.len)), chain.bytes);
        try std.testing.expectEqual(chunksFor(input.len), chain.chunks);
        var actual: [capacity]u8 = undefined;
        var used: usize = 0;
        var iterator = pool.iterator(chain);
        while (iterator.next()) |part| {
            @memcpy(actual[used..][0..part.len], part);
            used += part.len;
        }
        try std.testing.expectEqualSlices(u8, input, actual[0..used]);
        pool.release(chain);
    }
    try std.testing.expectEqual(chunk_count, pool.available());
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** capacity), &storage);

    var aborted = pool.writer(capacity);
    const prefix_length = @min(input.len, capacity);
    try aborted.write(input[0..prefix_length]);
    aborted.abort();
    try std.testing.expectEqual(chunk_count, pool.available());
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** capacity), &storage);
}

const WriteError = enum { too_large, exhausted };

fn chunksFor(bytes: usize) u16 {
    if (bytes == 0) return 0;
    return @intCast((bytes + chunk_bytes - 1) / chunk_bytes);
}

const empty = fuzz_support.smithInput("");
const boundary = fuzz_support.smithInput("0123456789abcdefg");
const full = fuzz_support.smithInput("x" ** capacity);
const oversized = fuzz_support.smithInput("y" ** (capacity + 1));
const mixed = fuzz_support.smithInput("<tag>&\x00\xff response chunks");
const corpus = [_][]const u8{ &empty, &boundary, &full, &oversized, &mixed };
