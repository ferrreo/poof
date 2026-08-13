const std = @import("std");
const builtin = @import("builtin");
const fixture = @import("../../../tests/unit/internal/runtime/connection_body_driver_test.zig");
const fuzz_support = @import("../../../src/internal/http1/testing/smith.zig");

const TestPool = fixture.TestStorage.GzipDecoderPool;
const stack_size = if (builtin.sanitize_thread)
    std.Thread.SpawnConfig.default_stack_size
else
    fixture.test_limits.gzip.thread_stack_bytes;

const gzip_abcdef = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x4b, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x03, 0x00,
    0xef, 0x39, 0x8e, 0x4b, 0x06, 0x00, 0x00, 0x00,
};
const gzip_twelve = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x4b, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x4b, 0xcf,
    0xc8, 0xcc, 0xca, 0xce, 0x01, 0x00, 0x24, 0x1b, 0x78,
    0xf6, 0x0c, 0x00, 0x00, 0x00,
};

fn storedGzip(comptime payload: []const u8) [payload.len + 23]u8 {
    @setEvalBranchQuota(1_000_000);
    comptime std.debug.assert(payload.len <= std.math.maxInt(u16));
    var result = [_]u8{0} ** (payload.len + 23);
    const header = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
    };
    @memcpy(result[0..header.len], &header);
    result[10] = 0x01;
    const length: u16 = @intCast(payload.len);
    std.mem.writeInt(u16, result[11..13], length, .little);
    std.mem.writeInt(u16, result[13..15], ~length, .little);
    @memcpy(result[15..][0..payload.len], payload);
    const trailer = 15 + payload.len;
    std.mem.writeInt(u32, result[trailer..][0..4], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, result[trailer + 4 ..][0..4], @intCast(payload.len), .little);
    return result;
}

const gzip_multipart = storedGzip(fixture.multipart_large_body);
const gzip_multipart_invalid = storedGzip(fixture.multipart_invalid_body);
const multipart_fixed_head =
    "POST /multipart HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: multipart/form-data; boundary=" ++ fixture.multipart_boundary ++ "\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{gzip_multipart.len}) ++
    "\r\n\r\n";
const multipart_chunked_head =
    "POST /multipart HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: multipart/form-data; boundary=" ++ fixture.multipart_boundary ++ "\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Transfer-Encoding: chunked\r\n\r\n";
const multipart_valid_wire = multipart_fixed_head ++ gzip_multipart ++ fixture.ping_request;
const multipart_reject_wire = multipart_chunked_head ++
    std.fmt.comptimePrint("{x}\r\n", .{gzip_multipart_invalid.len}) ++
    gzip_multipart_invalid ++ "\r\n0\r\n\r\n";

const fixed_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Content-Length: 26\r\n\r\n";
const chunked_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Trailer: X-Check\r\n\r\n";
const trailer_wire = "0\r\nX-Check:  first \t\r\nx-CHECK:\tsecond\r\n\r\n";
const chunked_one = chunked_head ++ "1a\r\n" ++ gzip_abcdef ++ "\r\n" ++ trailer_wire;
const chunked_two = chunked_head ++ "7\r\n" ++ gzip_abcdef[0..7].* ++
    "\r\n13\r\n" ++ gzip_abcdef[7..].* ++ "\r\n" ++ trailer_wire;
const chunked_three = chunked_head ++ "1\r\n" ++ gzip_abcdef[0..1].* ++
    "\r\n9\r\n" ++ gzip_abcdef[1..10].* ++
    "\r\n10\r\n" ++ gzip_abcdef[10..].* ++ "\r\n" ++ trailer_wire;

const Harness = struct {
    base: fixture.Harness = undefined,
    output_dispatches: u16 = 0,

    fn init(self: *Harness) !void {
        try self.base.init();
        self.output_dispatches = 0;
        try self.pool().start(stack_size);
    }

    fn deinit(self: *Harness) void {
        const decoder_pool = self.pool();
        if (decoder_pool.lifecycleStatus() == .running and decoder_pool.beginStop() != null) {
            @panic("gzip transport fuzz pool join failed");
        }
        while (decoder_pool.lifecycleStatus() == .quiesced and
            decoder_pool.activeJobs() != 0)
        {
            const batch = consumedBatch(decoder_pool) catch {
                @panic("gzip transport fuzz wake drain failed");
            };
            for (batch.slots, 0..) |signals, index| {
                if (!signals.terminal) continue;
                self.base.driver.settleGzipAfterBackend(
                    @intCast(index),
                    signals,
                ) catch @panic("gzip transport fuzz terminal settlement failed");
            }
        }
        if (decoder_pool.lifecycleStatus() != .quiesced) return;
        if (decoder_pool.wake_descriptor_exposed and !decoder_pool.wake_poll_retired) {
            decoder_pool.retireWakePoll() catch {
                @panic("gzip transport fuzz poll retirement failed");
            };
        }
        const failure = decoder_pool.finishStop() catch {
            @panic("gzip transport fuzz stop state failed");
        };
        if (failure != null) @panic("gzip transport fuzz counter close failed");
    }

    fn pool(self: *Harness) *TestPool {
        return self.base.storage.gzipPool().?;
    }

    fn prepare(self: *Harness) !void {
        try self.expectQuiescent();
        self.base.state = .{};
        self.base.now_ns = 1;
        self.output_dispatches = 0;
    }

    fn dispatchUntilIdle(self: *Harness) !void {
        var attempts: u8 = 0;
        while (self.pool().activeJobs() != 0) {
            if (attempts == 32) return error.FuzzDispatchBoundExceeded;
            attempts += 1;
            const batch = try waitBatch(self.pool());
            for (batch.slots, 0..) |signals, index| {
                if (!signals.space and !signals.output and !signals.terminal) continue;
                if (signals.output) self.output_dispatches += 1;
                try self.base.driver.handleGzipSignals(
                    @intCast(index),
                    signals,
                    self.base.now_ns,
                );
            }
        }
    }

    fn closeConnection(self: *Harness, connection: u16) !void {
        if (self.base.storage.connections[connection].phase == .free) {
            return self.expectQuiescent();
        }
        if (self.base.storage.connections[connection].phase != .closing) {
            _ = try self.base.driver.stop(connection);
        }
        try self.dispatchUntilIdle();
        try self.base.drainClosing(connection);
        try self.expectQuiescent();
    }

    fn forceClose(self: *Harness, connection: u16) void {
        self.closeConnection(connection) catch {
            @panic("gzip transport fuzz cleanup failed");
        };
    }

    fn expectQuiescent(self: *Harness) !void {
        try std.testing.expectEqual(@as(u16, 0), self.pool().activeJobs());
        try std.testing.expectEqual(@as(u16, 0), self.base.io.activeCount());
        try std.testing.expectEqual(@as(u16, 0), self.base.io.pendingCompletionCount());
        try std.testing.expectEqual(@as(u16, 0), self.base.io.borrowedCount());
        try std.testing.expectEqual(
            fixture.test_limits.connection_slots,
            self.base.storage.connection_pool.available(),
        );
        try std.testing.expectEqual(
            fixture.test_limits.request_slots,
            self.base.storage.request_pool.available(),
        );
        try std.testing.expectEqual(
            fixture.test_limits.body_workspace_slots,
            self.base.storage.bodyWorkspaceAvailable(),
        );
        try std.testing.expectEqual(
            fixture.test_limits.chunked_workspace_slots,
            self.base.storage.chunkedWorkspaceAvailable(),
        );
        try std.testing.expectEqual(
            fixture.test_limits.gzip.decoder_slots,
            self.pool().available(),
        );
        try std.testing.expectEqual(
            self.base.state.after_calls,
            self.base.state.completed + self.base.state.aborted,
        );
    }
};

test "gzip transport structured fragmentation and security fuzz" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try std.testing.fuzz(&harness, fuzzTransport, .{ .corpus = &fuzz_corpus });
    try harness.expectQuiescent();
}

fn fuzzTransport(harness: *Harness, smith: *std.testing.Smith) !void {
    const scenario = smith.valueRangeAtMost(u8, 0, 9);
    var payload_storage: [64]u8 = undefined;
    const payload = payload_storage[0..smith.slice(&payload_storage)];
    var plan_storage: [64]u8 = undefined;
    const plan = plan_storage[0..smith.slice(&plan_storage)];

    try harness.prepare();
    switch (scenario) {
        0 => try fuzzFixedValid(harness, plan),
        1 => try fuzzChunkedValid(harness, payload, plan),
        2 => try fuzzMalformedGzip(harness, plan),
        3 => try fuzzMalformedChunk(harness, payload, plan),
        4 => try fuzzDecodedLimit(harness, plan),
        5 => try fuzzChunkWireLimit(harness, plan),
        6 => try fuzzRawFixed(harness, payload, plan),
        7 => try fuzzRawChunked(harness, payload, plan),
        8 => try fuzzMultipartValid(harness, plan),
        9 => try fuzzMultipartReject(harness, plan),
        else => unreachable,
    }
}

fn fuzzFixedValid(harness: *Harness, plan: []const u8) !void {
    const wire = fixed_head ++ gzip_abcdef ++ fixture.ping_request;
    const connection = try harness.base.addConnection(110);
    var cleanup = true;
    defer if (cleanup) harness.forceClose(connection);
    try expectFedAll(try feedWire(
        harness,
        connection,
        wire,
        plan,
        fixture.ping_request.len + 1,
    ), wire.len);
    try harness.dispatchUntilIdle();
    try std.testing.expectEqual(@as(u8, 1), harness.base.state.body_calls);
    try std.testing.expect(harness.base.state.body_is_abcdef);
    try expectStatus(harness, connection, "HTTP/1.1 200 OK\r\n");
    try harness.base.completeSendAll(connection);
    try harness.base.retireResponse(connection);
    try std.testing.expectEqual(@as(u8, 1), harness.base.state.ping_calls);
    try harness.closeConnection(connection);
    cleanup = false;
}

fn fuzzChunkedValid(
    harness: *Harness,
    payload: []const u8,
    plan: []const u8,
) !void {
    const layout = if (payload.len == 0) 0 else payload[0] % 3;
    const wire = switch (layout) {
        0 => chunked_one ++ fixture.ping_request,
        1 => chunked_two ++ fixture.ping_request,
        2 => chunked_three ++ fixture.ping_request,
        else => unreachable,
    };
    const connection = try harness.base.addConnection(111);
    var cleanup = true;
    defer if (cleanup) harness.forceClose(connection);
    try expectFedAll(try feedWire(
        harness,
        connection,
        wire,
        plan,
        fixture.ping_request.len + 1,
    ), wire.len);
    try harness.dispatchUntilIdle();
    try std.testing.expectEqual(@as(u8, 1), harness.base.state.body_calls);
    try std.testing.expect(harness.base.state.body_is_abcdef);
    try std.testing.expect(harness.base.state.body_saw_trailers);
    try harness.base.completeSendAll(connection);
    try harness.base.retireResponse(connection);
    try std.testing.expectEqual(@as(u8, 1), harness.base.state.ping_calls);
    try harness.closeConnection(connection);
    cleanup = false;
}

fn fuzzMalformedGzip(harness: *Harness, plan: []const u8) !void {
    const head =
        "POST /echo HTTP/1.1\r\nHost: example.test\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "Content-Encoding: gzip\r\nContent-Length: 4\r\n\r\n";
    const wire = head ++ "nope";
    const connection = try harness.base.addConnection(112);
    var cleanup = true;
    defer if (cleanup) harness.forceClose(connection);
    _ = try feedWire(harness, connection, wire, plan, 0);
    try harness.dispatchUntilIdle();
    try expectStatus(harness, connection, "HTTP/1.1 400 Bad Request\r\n");
    try std.testing.expectEqual(@as(u8, 0), harness.base.state.body_calls);
    try harness.closeConnection(connection);
    cleanup = false;
}

fn fuzzMalformedChunk(
    harness: *Harness,
    payload: []const u8,
    plan: []const u8,
) !void {
    const choice = if (payload.len == 0) 0 else payload[0] % 4;
    const malformed = switch (choice) {
        0 => "z\r\n",
        1 => "1\r\nxX",
        2 => "1\r\na\r\n1\r\nb\r\n1\r\nc\r\n1\r\nd\r\n",
        3 => "0\r\nY-Other: value\r\n\r\n",
        else => unreachable,
    };
    var wire_storage: [512]u8 = undefined;
    const wire = try joined(&wire_storage, chunked_head, malformed);
    const connection = try harness.base.addConnection(113);
    var cleanup = true;
    defer if (cleanup) harness.forceClose(connection);
    _ = try feedWire(harness, connection, wire, plan, 0);
    try harness.dispatchUntilIdle();
    try std.testing.expectEqual(@as(u8, 0), harness.base.state.body_calls);
    const record = &harness.base.storage.connections[connection];
    try std.testing.expectEqual(.responding, record.phase);
    try std.testing.expect(record.close_after_response);
    try expectStatus(harness, connection, "HTTP/1.1 400 Bad Request\r\n");
    try harness.closeConnection(connection);
    cleanup = false;
}

fn fuzzDecodedLimit(harness: *Harness, plan: []const u8) !void {
    const head =
        "POST /echo HTTP/1.1\r\nHost: example.test\r\n" ++
        "Content-Type: application/octet-stream\r\n" ++
        "Content-Encoding: gzip\r\nContent-Length: 32\r\n\r\n";
    const wire = head ++ gzip_twelve;
    const connection = try harness.base.addConnection(114);
    var cleanup = true;
    defer if (cleanup) harness.forceClose(connection);
    _ = try feedWire(harness, connection, wire, plan, 0);
    try harness.dispatchUntilIdle();
    try expectStatus(harness, connection, "HTTP/1.1 413 Payload Too Large\r\n");
    try std.testing.expectEqual(@as(u8, 0), harness.base.state.body_calls);
    try harness.closeConnection(connection);
    cleanup = false;
}

fn fuzzChunkWireLimit(harness: *Harness, plan: []const u8) !void {
    const wire = chunked_head ++ "80\r\n";
    const connection = try harness.base.addConnection(115);
    var cleanup = true;
    defer if (cleanup) harness.forceClose(connection);
    _ = try feedWire(harness, connection, wire, plan, 0);
    try harness.dispatchUntilIdle();
    try std.testing.expectEqual(@as(u8, 0), harness.base.state.body_calls);
    const record = &harness.base.storage.connections[connection];
    try std.testing.expectEqual(.responding, record.phase);
    try std.testing.expect(record.close_after_response);
    try expectStatus(harness, connection, "HTTP/1.1 413 Payload Too Large\r\n");
    try harness.closeConnection(connection);
    cleanup = false;
}

fn fuzzRawFixed(
    harness: *Harness,
    payload: []const u8,
    plan: []const u8,
) !void {
    var wire_storage: [512]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &wire_storage,
        "POST /echo HTTP/1.1\r\nHost: example.test\r\n" ++
            "Content-Type: application/octet-stream\r\n" ++
            "Content-Encoding: gzip\r\nContent-Length: {d}\r\n\r\n",
        .{payload.len},
    );
    @memcpy(wire_storage[head.len..][0..payload.len], payload);
    const wire = wire_storage[0 .. head.len + payload.len];
    const connection = try harness.base.addConnection(116);
    var cleanup = true;
    defer if (cleanup) harness.forceClose(connection);
    _ = try feedWire(harness, connection, wire, plan, 0);
    try harness.dispatchUntilIdle();
    try expectAllowedGzipStatus(harness, connection);
    try std.testing.expect(harness.base.state.body_calls <= 1);
    try harness.closeConnection(connection);
    cleanup = false;
}

fn fuzzRawChunked(
    harness: *Harness,
    payload: []const u8,
    plan: []const u8,
) !void {
    var wire_storage: [512]u8 = undefined;
    const wire = try joined(&wire_storage, chunked_head, payload);
    const connection = try harness.base.addConnection(117);
    var cleanup = true;
    defer if (cleanup) harness.forceClose(connection);
    _ = try feedWire(harness, connection, wire, plan, 0);
    const record = &harness.base.storage.connections[connection];
    if (record.phase != .closing and record.phase != .responding and
        record.receive_token != null)
    {
        _ = try harness.base.endOfStream(connection);
    }
    try harness.dispatchUntilIdle();
    try std.testing.expect(harness.base.state.body_calls <= 1);
    try harness.closeConnection(connection);
    cleanup = false;
}

fn fuzzMultipartValid(harness: *Harness, plan: []const u8) !void {
    const connection = try harness.base.addConnection(118);
    var cleanup = true;
    defer if (cleanup) harness.forceClose(connection);
    try expectFedAll(try feedWire(
        harness,
        connection,
        multipart_valid_wire,
        plan,
        fixture.ping_request.len + 1,
    ), multipart_valid_wire.len);
    try harness.dispatchUntilIdle();
    try std.testing.expect(harness.output_dispatches >= 2);
    try std.testing.expectEqual(
        fixture.test_limits.gzip.decoder_slots,
        harness.pool().available(),
    );
    try std.testing.expect(
        !harness.base.storage.connections[connection].receive_flags.gzip_rejecting,
    );
    try std.testing.expectEqual(@as(u8, 1), harness.base.state.multipart_calls);
    try std.testing.expectEqual(@as(u16, 23), harness.base.state.multipart_count);
    try expectStatus(harness, connection, "HTTP/1.1 200 OK\r\n");
    try harness.base.completeSendAll(connection);
    try harness.base.retireResponse(connection);
    try std.testing.expectEqual(@as(u8, 1), harness.base.state.ping_calls);
    try harness.closeConnection(connection);
    cleanup = false;
}

fn fuzzMultipartReject(harness: *Harness, plan: []const u8) !void {
    const connection = try harness.base.addConnection(119);
    var cleanup = true;
    defer if (cleanup) harness.forceClose(connection);
    try expectFedAll(
        try feedWire(harness, connection, multipart_reject_wire, plan, 0),
        multipart_reject_wire.len,
    );
    try harness.dispatchUntilIdle();
    try std.testing.expect(harness.output_dispatches > 0);
    try std.testing.expectEqual(
        fixture.test_limits.gzip.decoder_slots,
        harness.pool().available(),
    );
    try std.testing.expect(
        !harness.base.storage.connections[connection].receive_flags.gzip_rejecting,
    );
    try std.testing.expectEqual(@as(u8, 0), harness.base.state.multipart_calls);
    try expectStatus(harness, connection, "HTTP/1.1 400 Bad Request\r\n");
    try harness.closeConnection(connection);
    cleanup = false;
}

fn feedWire(
    harness: *Harness,
    connection: u16,
    input: []const u8,
    plan: []const u8,
    atomic_suffix: usize,
) !usize {
    if (atomic_suffix > input.len) return error.InvalidAtomicSuffix;
    const split = input.len - atomic_suffix;
    var offset: usize = 0;
    var step: usize = 0;
    while (offset < split) : (step += 1) {
        const record = &harness.base.storage.connections[connection];
        if (record.receive_token == null or record.phase == .closing or
            record.phase == .responding) break;
        const end = fragmentEnd(offset, split, plan, step);
        _ = try harness.base.receive(connection, input[offset..end], false);
        offset = end;
    }
    if (atomic_suffix == 0 or offset != split) return offset;
    const record = &harness.base.storage.connections[connection];
    if (record.receive_token == null or record.phase == .closing or
        record.phase == .responding) return offset;
    _ = try harness.base.receive(connection, input[offset..], false);
    return input.len;
}

fn fragmentEnd(
    offset: usize,
    limit: usize,
    plan: []const u8,
    step: usize,
) usize {
    const decision = if (plan.len == 0) 0 else plan[step % plan.len];
    return @min(limit, offset + @as(usize, decision % 64) + 1);
}

fn joined(storage: []u8, prefix: []const u8, suffix: []const u8) ![]const u8 {
    const used = std.math.add(usize, prefix.len, suffix.len) catch {
        return error.FuzzWireOverflow;
    };
    if (used > storage.len) return error.FuzzWireOverflow;
    @memcpy(storage[0..prefix.len], prefix);
    @memcpy(storage[prefix.len..used], suffix);
    return storage[0..used];
}

fn expectFedAll(actual: usize, expected: usize) !void {
    try std.testing.expectEqual(expected, actual);
}

fn expectStatus(harness: *const Harness, connection: u16, status: []const u8) !void {
    try std.testing.expect(std.mem.startsWith(
        u8,
        harness.base.sendBytes(connection),
        status,
    ));
}

fn expectAllowedGzipStatus(harness: *const Harness, connection: u16) !void {
    const response = harness.base.sendBytes(connection);
    const allowed = std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n") or
        std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request\r\n") or
        std.mem.startsWith(u8, response, "HTTP/1.1 413 Payload Too Large\r\n");
    try std.testing.expect(allowed);
}

fn waitBatch(pool: *TestPool) !TestPool.WakeBatch {
    var descriptors = [1]std.os.linux.pollfd{.{
        .fd = pool.wakeDescriptor(),
        .events = std.os.linux.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        descriptors[0].revents = 0;
        const count = std.os.linux.poll(&descriptors, descriptors.len, 1_000);
        switch (std.os.linux.errno(count)) {
            .SUCCESS => if (count == 1 and
                descriptors[0].revents == std.os.linux.POLL.IN)
            {
                return consumedBatch(pool);
            } else return error.FuzzWakeTimedOut,
            .INTR => continue,
            else => return error.FuzzWakeFailed,
        }
    }
}

fn consumedBatch(pool: *TestPool) !TestPool.WakeBatch {
    return switch (pool.consumeWake()) {
        .consumed => |batch| batch,
        .failed => error.FuzzWakeConsumeFailed,
    };
}

fn fuzzCase(
    comptime scenario: u64,
    comptime payload: []const u8,
    comptime plan: []const u8,
) [16 + payload.len + plan.len]u8 {
    const payload_input = fuzz_support.smithInput(payload);
    const plan_input = fuzz_support.smithInput(plan);
    var input: [16 + payload.len + plan.len]u8 = undefined;
    std.mem.writeInt(u64, input[0..8], scenario, .little);
    @memcpy(input[8..][0..payload_input.len], &payload_input);
    @memcpy(input[8 + payload_input.len ..], &plan_input);
    return input;
}

const fuzz_corpus = struct {
    const fixed_valid = fuzzCase(0, "", "\x00\x01\x07\x3f");
    const chunked_valid = fuzzCase(1, "\x02", "\x00\x03\x0f");
    const malformed_gzip = fuzzCase(2, "", "\x00\x01");
    const malformed_chunk = fuzzCase(3, "\x03", "\x00\x02\x08");
    const decoded_limit = fuzzCase(4, "", "\x01\x05\x1f");
    const chunk_wire_limit = fuzzCase(5, "", "\x00\x03");
    const raw_fixed = fuzzCase(6, "not gzip", "\x01\x07");
    const raw_chunked = fuzzCase(7, "z\r\n", "\x00\x02");
    const multipart_valid = fuzzCase(8, "", "\x00\x01\x07\x1f");
    const multipart_reject = fuzzCase(9, "", "\x00\x03\x0f\x3f");

    const values = [_][]const u8{
        &fixed_valid,
        &chunked_valid,
        &malformed_gzip,
        &malformed_chunk,
        &decoded_limit,
        &chunk_wire_limit,
        &raw_fixed,
        &raw_chunked,
        &multipart_valid,
        &multipart_reject,
    };
}.values;
