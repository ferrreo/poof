pub const std = @import("std");
pub const builtin = @import("builtin");
pub const fixture = @import("connection_body_driver_test.zig");
pub const gzip_decoder_pool = @import("../../../../src/internal/runtime/gzip/decoder_pool.zig");
pub const reactor = @import("../../../../src/internal/runtime/reactor.zig");

pub const TestPool = fixture.TestStorage.GzipDecoderPool;
pub const stack_size = if (builtin.sanitize_thread)
    std.Thread.SpawnConfig.default_stack_size
else
    fixture.test_limits.gzip.thread_stack_bytes;

pub fn storedGzip(comptime payload: []const u8) [payload.len + 23]u8 {
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

pub const gzip_abcdef = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x4b, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x03, 0x00,
    0xef, 0x39, 0x8e, 0x4b, 0x06, 0x00, 0x00, 0x00,
};
pub const gzip_twelve = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x4b, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x4b, 0xcf,
    0xc8, 0xcc, 0xca, 0xce, 0x01, 0x00, 0x24, 0x1b, 0x78,
    0xf6, 0x0c, 0x00, 0x00, 0x00,
};
pub const gzip_multipart = storedGzip(fixture.multipart_body);
pub const gzip_multipart_large = storedGzip(fixture.multipart_large_body);
pub const gzip_multipart_bad_footer = bad: {
    var encoded = gzip_multipart_large;
    encoded[encoded.len - 8] ^= 1;
    break :bad encoded;
};
pub const gzip_multipart_invalid = storedGzip(fixture.multipart_invalid_body);
pub const gzip_multipart_field_limit = storedGzip(fixture.multipart_field_limit_body);
pub const gzip_multipart_file_limit = storedGzip(fixture.multipart_file_limit_body);
pub const gzip_multipart_total_limit = storedGzip(&fixture.multipart_total_limit_body);
pub const gzip_multipart_unsupported = storedGzip(fixture.multipart_unsupported_body);
pub const Framing = enum { fixed, chunked };
pub const gzip_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Content-Length: 26\r\n\r\n";
pub const expect_gzip_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Content-Length: 26\r\n" ++
    "Expect: 100-continue\r\n\r\n";
pub const chunked_gzip_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Trailer: X-Check\r\n\r\n";
pub const large_gzip_head =
    "POST /large HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Content-Length: 2100\r\n\r\n";
pub const GzipHarness = struct {
    base: fixture.Harness = undefined,
    output_dispatches: u64 = 0,

    pub fn init(self: *GzipHarness) !void {
        try self.base.init();
        self.output_dispatches = 0;
        try self.pool().start(stack_size);
    }

    pub fn deinit(self: *GzipHarness) void {
        const decoder_pool = self.pool();
        if (decoder_pool.lifecycleStatus() == .running and decoder_pool.beginStop() != null) {
            @panic("gzip driver test pool join failed");
        }
        while (decoder_pool.lifecycleStatus() == .quiesced and decoder_pool.activeJobs() != 0) {
            const batch = consumedBatch(decoder_pool) catch {
                @panic("gzip driver test wake drain failed");
            };
            for (batch.slots, 0..) |signals, slot_index| {
                if (!signals.terminal) continue;
                self.base.driver.settleGzipAfterBackend(
                    @intCast(slot_index),
                    signals,
                ) catch @panic("gzip driver test terminal settlement failed");
            }
        }
        if (decoder_pool.lifecycleStatus() != .quiesced) return;
        if (decoder_pool.wake_descriptor_exposed and !decoder_pool.wake_poll_retired) {
            decoder_pool.retireWakePoll() catch @panic("gzip driver test poll retirement failed");
        }
        const failure = decoder_pool.finishStop() catch {
            @panic("gzip driver test stop state failed");
        };
        if (failure != null) {
            @panic("gzip driver test counter close failed");
        }
    }

    pub fn pool(self: *GzipHarness) *TestPool {
        return self.base.storage.gzipPool().?;
    }

    pub fn dispatchOne(self: *GzipHarness) !void {
        const batch = try waitBatch(self.pool());
        for (batch.slots, 0..) |signals, slot_index| {
            if (!signals.space and !signals.output and !signals.terminal) continue;
            if (signals.output) self.output_dispatches += 1;
            try self.base.driver.handleGzipSignals(
                @intCast(slot_index),
                signals,
                self.base.now_ns,
            );
        }
    }

    pub fn dispatchUntilIdle(self: *GzipHarness) !void {
        var iterations: u8 = 0;
        while (self.pool().activeJobs() != 0) {
            if (iterations == 16) return error.TestUnexpectedResult;
            iterations += 1;
            try self.dispatchOne();
        }
    }
};

pub fn expectMultipartResponse(harness: *GzipHarness, connection: u16) !void {
    try std.testing.expectEqual(@as(u8, 1), harness.base.state.multipart_calls);
    try std.testing.expectEqual(@as(u16, 23), harness.base.state.multipart_count);
    try std.testing.expect(std.mem.endsWith(
        u8,
        harness.base.sendBytes(connection),
        "\r\n\r\nmultipart-ok",
    ));
    const request = harness.base.storage.connections[connection]
        .active_request orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), harness.base.storage.requests[request].body.used);
}

pub fn submitMultipart(
    harness: *GzipHarness,
    connection: u16,
    encoded: []const u8,
    framing: Framing,
    expect_continue: bool,
) !void {
    try beginMultipart(harness, connection, encoded.len, framing, expect_continue);
    try feedMultipartWire(harness, connection, encoded, framing);
}

pub fn beginMultipart(
    harness: *GzipHarness,
    connection: u16,
    encoded_length: usize,
    framing: Framing,
    expect_continue: bool,
) !void {
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writer.print(
        "POST /multipart HTTP/1.1\r\nHost: example.test\r\n" ++
            "Content-Type: multipart/form-data; boundary={s}\r\n" ++
            "Content-Encoding: gzip\r\n",
        .{fixture.multipart_boundary},
    );
    switch (framing) {
        .fixed => try writer.print("Content-Length: {d}\r\n", .{encoded_length}),
        .chunked => try writer.writeAll("Transfer-Encoding: chunked\r\n"),
    }
    if (expect_continue) try writer.writeAll("Expect: 100-continue\r\n");
    try writer.writeAll("\r\n");
    _ = try harness.base.receive(connection, writer.buffered(), false);
}

pub fn feedMultipartWire(
    harness: *GzipHarness,
    connection: u16,
    encoded: []const u8,
    framing: Framing,
) !void {
    if (framing == .chunked) {
        var storage: [16]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try writer.print("{x}\r\n", .{encoded.len});
        _ = try harness.base.receive(connection, writer.buffered(), false);
    }
    const fragments = [_]usize{ 1, 31, 127, 509 };
    var offset: usize = 0;
    var fragment: usize = 0;
    while (offset < encoded.len) : (fragment += 1) {
        const end = @min(encoded.len, offset + fragments[fragment % fragments.len]);
        _ = try harness.base.receive(connection, encoded[offset..end], false);
        offset = end;
    }
    if (framing == .chunked) {
        _ = try harness.base.receive(connection, "\r\n0\r\n\r\n", false);
    }
}

pub fn drainNetwork(harness: *fixture.Harness, connection: u16) !void {
    var iterations: u8 = 0;
    while (harness.io.activeCount() != 0) {
        if (iterations == 32) return error.TestUnexpectedResult;
        iterations += 1;
        var selected: ?reactor.OperationToken = null;
        var active_index: u16 = 0;
        while (active_index < harness.io.activeCount()) : (active_index += 1) {
            const submission = harness.io.activeSubmission(active_index).?;
            if ((try submission.token.fields()).slot_index == connection) {
                selected = submission.token;
                break;
            }
        }
        const token = selected orelse return error.TestUnexpectedResult;
        const result: reactor.CompletionResult = switch ((try token.fields()).kind) {
            .cancel => .{ .success = .{ .cancel = .canceled } },
            .close => .{ .success = .{ .close = {} } },
            .timeout, .receive, .send => .{ .failure = .canceled },
            .accept,
            .wake,
            .file_open,
            .file_write,
            .file_close,
            .file_link,
            .file_unlink,
            .file_rename_no_replace,
            .file_sync,
            .upload_cancel,
            .file_read,
            .file_stat,
            .file_cancel,
            => return error.TestUnexpectedResult,
        };
        _ = try harness.complete(token, result, false);
    }
}

pub fn waitBatch(pool: *TestPool) !TestPool.WakeBatch {
    var descriptors = [1]std.os.linux.pollfd{.{
        .fd = pool.wakeDescriptor(),
        .events = std.os.linux.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        descriptors[0].revents = 0;
        const count = std.os.linux.poll(&descriptors, descriptors.len, 5_000);
        switch (std.os.linux.errno(count)) {
            .SUCCESS => if (count == 1 and descriptors[0].revents == std.os.linux.POLL.IN) {
                return consumedBatch(pool);
            } else return error.TestUnexpectedResult,
            .INTR => continue,
            else => return error.TestUnexpectedResult,
        }
    }
}

pub fn waitDecodePaused() !void {
    var attempts: u32 = 0;
    while (attempts < 100_000) : (attempts += 1) {
        if (TestPool.TestAccess.decodePaused()) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

pub fn consumedBatch(pool: *TestPool) !TestPool.WakeBatch {
    return switch (pool.consumeWake()) {
        .consumed => |batch| batch,
        .failed => error.TestUnexpectedResult,
    };
}

test {
    _ = @import("connection_gzip_driver_test_part_1.zig");
}
