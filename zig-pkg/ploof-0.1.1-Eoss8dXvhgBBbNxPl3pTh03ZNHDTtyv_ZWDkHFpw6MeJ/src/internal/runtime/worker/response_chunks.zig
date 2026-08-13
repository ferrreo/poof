const std = @import("std");
const application_chunk_output = @import("../../application/chunk_output.zig");
const gzip_encoder = @import("../gzip/encoder.zig");
const response_chunk_chain = @import("../../response/chunk_chain.zig");
const slot_pool = @import("../slot_pool.zig");

pub const none = response_chunk_chain.none;
pub const Chain = response_chunk_chain.Chain;

pub const Node = struct {
    next: u16 = none,
    used: u16 = 0,
};

pub const InitError = slot_pool.InitError || error{
    CapacityMismatch,
    ChunkBytesZero,
};

pub const WriteError = error{
    ResponseBodyTooLarge,
    ResponseChunksExhausted,
    SourceAliasesPool,
    WriterTerminal,
};

pub fn Pool(comptime chunk_bytes: u16) type {
    comptime {
        if (chunk_bytes == 0) @compileError("response chunk bytes must be nonzero");
    }

    return struct {
        const Self = @This();

        indices: []u16,
        nodes: []Node,
        storage: []u8,
        free: slot_pool.SlotPool,
        live_chunks: u16 = 0,
        high_water: u16 = 0,
        last_required_chunks: u16 = 0,

        pub const Writer = struct {
            pool: *Self,
            chain: Chain = .{},
            compression_source: ?Chain = null,
            limit: u32,
            terminal: bool = false,

            pub fn write(self: *Writer, value: []const u8) WriteError!void {
                if (self.terminal or self.compression_source != null) {
                    return error.WriterTerminal;
                }
                if (value.len == 0) return;
                if (self.pool.aliasesStorage(value)) return self.fail(error.SourceAliasesPool);
                const value_length = std.math.cast(u32, value.len) orelse {
                    return self.fail(error.ResponseBodyTooLarge);
                };
                const next_length = std.math.add(u32, self.chain.bytes, value_length) catch {
                    return self.fail(error.ResponseBodyTooLarge);
                };
                if (next_length > self.limit) return self.fail(error.ResponseBodyTooLarge);

                const required = self.additionalChunks(value.len);
                if (required > @as(u32, self.pool.free.available())) {
                    const total = @as(u64, self.chain.chunks) + required;
                    self.pool.last_required_chunks = @intCast(@min(
                        total,
                        @as(u64, std.math.maxInt(u16)),
                    ));
                    return self.fail(error.ResponseChunksExhausted);
                }
                self.writeAssumeCapacity(value);
                self.chain.bytes = next_length;
            }

            pub fn finish(self: *Writer) WriteError!Chain {
                if (self.terminal) return error.WriterTerminal;
                self.terminal = true;
                if (self.compression_source) |source| self.pool.release(source);
                self.compression_source = null;
                const chain = self.chain;
                self.chain = .{};
                return chain;
            }

            pub fn reset(self: *Writer) void {
                if (self.terminal) return;
                self.pool.release(self.chain);
                if (self.compression_source) |source| self.pool.release(source);
                self.chain = .{};
                self.compression_source = null;
            }

            pub fn bytesWritten(self: *const Writer) u32 {
                return self.chain.bytes;
            }

            pub fn compress(
                self: *Writer,
                workspace: *gzip_encoder.Workspace,
                level: gzip_encoder.Level,
            ) application_chunk_output.Compression {
                if (self.terminal) return .failed;
                if (self.compression_source != null) return .failed;
                const bound = gzip_encoder.bound(self.chain.bytes) catch return .failed;
                const limit = std.math.cast(u32, bound) orelse return .failed;
                const chunks: u32 = @intCast((bound + chunk_bytes - 1) / chunk_bytes);
                if (chunks > self.pool.free.available()) {
                    self.pool.last_required_chunks = @intCast(@min(
                        @as(u32, std.math.maxInt(u16)),
                        @as(u32, self.chain.chunks) + chunks,
                    ));
                    return .capacity_unavailable;
                }
                var destination = self.pool.writer(limit);
                if (!compressInto(self, &destination, workspace, level)) {
                    destination.abort();
                    return .failed;
                }
                const encoded = destination.finish() catch return .failed;
                if (!self.pool.gzipValid(encoded)) {
                    self.pool.release(encoded);
                    return .failed;
                }
                self.compression_source = self.chain;
                self.chain = encoded;
                return .{ .success = encoded.bytes };
            }

            pub fn restoreIdentity(self: *Writer) bool {
                if (self.terminal) return false;
                const source = self.compression_source orelse return false;
                self.pool.release(self.chain);
                self.chain = source;
                self.compression_source = null;
                return true;
            }

            pub fn abort(self: *Writer) void {
                if (self.terminal) return;
                self.pool.release(self.chain);
                if (self.compression_source) |source| self.pool.release(source);
                self.chain = .{};
                self.compression_source = null;
                self.terminal = true;
            }

            fn fail(self: *Writer, err: WriteError) WriteError {
                self.abort();
                return err;
            }

            fn additionalChunks(self: *const Writer, length: usize) u32 {
                const tail_space = if (self.chain.tail == none)
                    0
                else
                    chunk_bytes - self.pool.nodes[self.chain.tail].used;
                if (length <= tail_space) return 0;
                const remaining = length - tail_space;
                return @intCast((remaining + chunk_bytes - 1) / chunk_bytes);
            }

            fn writeAssumeCapacity(self: *Writer, value: []const u8) void {
                var remaining = value;
                while (remaining.len != 0) {
                    if (self.chain.tail == none or
                        self.pool.nodes[self.chain.tail].used == chunk_bytes)
                    {
                        self.appendChunk();
                    }
                    const tail = self.chain.tail;
                    const node = &self.pool.nodes[tail];
                    const writable = chunk_bytes - node.used;
                    const copied = @min(remaining.len, writable);
                    const output = self.pool.region(tail);
                    @memcpy(output[node.used..][0..copied], remaining[0..copied]);
                    node.used += @intCast(copied);
                    remaining = remaining[copied..];
                }
            }

            fn appendChunk(self: *Writer) void {
                const index = self.pool.acquire() orelse unreachable;
                if (self.chain.tail == none) {
                    self.chain.head = index;
                } else {
                    self.pool.nodes[self.chain.tail].next = index;
                }
                self.chain.tail = index;
                self.chain.chunks += 1;
            }
        };

        pub const Iterator = struct {
            pool: *const Self,
            next_index: u16,
            remaining: u16,

            pub fn next(self: *Iterator) ?[]const u8 {
                if (self.remaining == 0) return null;
                const index = self.next_index;
                if (index >= self.pool.nodes.len) return null;
                const node = self.pool.nodes[index];
                if (node.used > chunk_bytes) return null;
                self.next_index = node.next;
                self.remaining -= 1;
                return self.pool.region(index)[0..node.used];
            }
        };

        pub fn init(indices: []u16, nodes: []Node, storage: []u8) InitError!Self {
            if (chunk_bytes == 0) return error.ChunkBytesZero;
            if (indices.len != nodes.len) return error.CapacityMismatch;
            const required = std.math.mul(usize, indices.len, chunk_bytes) catch {
                return error.CapacityMismatch;
            };
            if (storage.len != required) return error.CapacityMismatch;
            @memset(nodes, .{});
            return .{
                .indices = indices,
                .nodes = nodes,
                .storage = storage,
                .free = try slot_pool.SlotPool.init(indices),
            };
        }

        pub fn writer(self: *Self, limit: u32) Writer {
            return .{ .pool = self, .limit = limit };
        }

        pub fn iterator(self: *const Self, chain: Chain) Iterator {
            return .{
                .pool = self,
                .next_index = chain.head,
                .remaining = chain.chunks,
            };
        }

        pub fn release(self: *Self, chain: Chain) void {
            if (!self.validate(chain)) @panic("response chunk chain invariant");
            var index = chain.head;
            var remaining = chain.chunks;
            while (remaining != 0) : (remaining -= 1) {
                if (index >= self.nodes.len) @panic("response chunk chain invariant");
                const node = self.nodes[index];
                if (node.used > chunk_bytes) @panic("response chunk length invariant");
                const next = node.next;
                std.crypto.secureZero(u8, self.region(index)[0..node.used]);
                self.nodes[index] = .{};
                self.free.release(index);
                self.live_chunks -= 1;
                index = next;
            }
            if (index != none) @panic("response chunk terminal invariant");
        }

        pub fn validate(self: *const Self, chain: Chain) bool {
            if (chain.isEmpty()) {
                return chain.head == none and chain.tail == none and chain.bytes == 0;
            }
            if (chain.head == none or chain.tail == none or chain.bytes == 0) return false;
            if (chain.chunks > self.live_chunks) return false;
            var index = chain.head;
            var remaining = chain.chunks;
            var total: u32 = 0;
            var last: u16 = none;
            while (remaining != 0) : (remaining -= 1) {
                if (index >= self.nodes.len) return false;
                const node = self.nodes[index];
                if (node.used == 0 or node.used > chunk_bytes) return false;
                total = std.math.add(u32, total, node.used) catch return false;
                last = index;
                index = node.next;
            }
            return index == none and last == chain.tail and total == chain.bytes;
        }

        pub fn reset(self: *Self) void {
            std.crypto.secureZero(u8, self.storage);
            @memset(self.nodes, .{});
            self.free = slot_pool.SlotPool.init(self.indices) catch unreachable;
            self.live_chunks = 0;
            self.high_water = 0;
            self.last_required_chunks = 0;
        }

        pub fn available(self: *const Self) u16 {
            return self.free.available();
        }

        fn acquire(self: *Self) ?u16 {
            const index = self.free.acquire() orelse return null;
            self.nodes[index] = .{};
            self.live_chunks += 1;
            self.high_water = @max(self.high_water, self.live_chunks);
            return index;
        }

        fn gzipValid(self: *const Self, chain: Chain) bool {
            if (!self.validate(chain) or chain.bytes < 18 or chain.head >= self.nodes.len) {
                return false;
            }
            const first = self.region(chain.head);
            return self.nodes[chain.head].used >= 3 and
                first[0] == 0x1f and first[1] == 0x8b and first[2] == 0x08;
        }

        fn region(self: *const Self, index: u16) []u8 {
            const start = @as(usize, index) * chunk_bytes;
            return self.storage[start..][0..chunk_bytes];
        }

        fn aliasesStorage(self: *const Self, value: []const u8) bool {
            if (value.len == 0) return false;
            const source_start = @intFromPtr(value.ptr);
            const source_end = std.math.add(usize, source_start, value.len) catch return true;
            const pool_start = @intFromPtr(self.storage.ptr);
            const pool_end = std.math.add(usize, pool_start, self.storage.len) catch return true;
            return source_start < pool_end and pool_start < source_end;
        }
    };
}

fn compressInto(
    source: anytype,
    destination: anytype,
    workspace: *gzip_encoder.Workspace,
    level: gzip_encoder.Level,
) bool {
    var output: ChunkIo(@TypeOf(destination)) = undefined;
    output.init(destination);
    gzip_encoder.begin(workspace, &output.writer, level) catch return false;
    var chunks = source.pool.iterator(source.chain);
    while (chunks.next()) |bytes| {
        workspace.compressor.writer.writeAll(bytes) catch return false;
    }
    workspace.compressor.finish() catch return false;
    output.writer.flush() catch return false;
    return output.failure == null;
}

fn ChunkIo(comptime Destination: type) type {
    return struct {
        writer: std.Io.Writer,
        buffer: [4096]u8,
        destination: Destination,
        failure: ?WriteError = null,

        const Self = @This();
        const vtable = std.Io.Writer.VTable{ .drain = drain };

        fn init(self: *Self, destination: Destination) void {
            self.* = .{
                .writer = .{ .vtable = &vtable, .buffer = &self.buffer },
                .buffer = undefined,
                .destination = destination,
            };
        }

        fn drain(
            writer: *std.Io.Writer,
            data: []const []const u8,
            splat: usize,
        ) std.Io.Writer.Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("writer", writer));
            self.write(writer.buffered()) catch return error.WriteFailed;
            writer.end = 0;
            var consumed: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                self.write(bytes) catch return error.WriteFailed;
                consumed += bytes.len;
            }
            for (0..splat) |_| {
                self.write(data[data.len - 1]) catch return error.WriteFailed;
                consumed += data[data.len - 1].len;
            }
            return consumed;
        }

        fn write(self: *Self, bytes: []const u8) WriteError!void {
            self.destination.write(bytes) catch |problem| {
                self.failure = problem;
                return problem;
            };
        }
    };
}

test "response chunk writer links exact slices and securely reuses storage" {
    const TestPool = Pool(4);
    var indices: [3]u16 = undefined;
    var nodes: [3]Node = undefined;
    var storage: [12]u8 = undefined;
    var pool = try TestPool.init(&indices, &nodes, &storage);
    var writer = pool.writer(12);
    try writer.write("abc");
    try writer.write("defghi");
    const chain = try writer.finish();
    try std.testing.expectEqual(@as(u32, 9), chain.bytes);
    try std.testing.expectEqual(@as(u16, 3), chain.chunks);
    try std.testing.expectEqual(@as(u16, 3), pool.high_water);

    var iterator = pool.iterator(chain);
    try std.testing.expectEqualStrings("abcd", iterator.next().?);
    try std.testing.expectEqualStrings("efgh", iterator.next().?);
    try std.testing.expectEqualStrings("i", iterator.next().?);
    try std.testing.expect(iterator.next() == null);

    pool.release(chain);
    try std.testing.expectEqual(@as(u16, 3), pool.available());
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 9), storage[0..9]);
}

test "response chunk writer fails transactionally at every bound" {
    const TestPool = Pool(4);
    var indices: [2]u16 = undefined;
    var nodes: [2]Node = undefined;
    var storage: [8]u8 = undefined;
    var pool = try TestPool.init(&indices, &nodes, &storage);

    var too_large = pool.writer(3);
    try too_large.write("abc");
    try std.testing.expectError(error.ResponseBodyTooLarge, too_large.write("d"));
    try std.testing.expectEqual(@as(u16, 2), pool.available());

    var exhausted = pool.writer(12);
    try exhausted.write("abcde");
    try std.testing.expectError(error.ResponseChunksExhausted, exhausted.write("fghi"));
    try std.testing.expectEqual(@as(u16, 3), pool.last_required_chunks);
    try std.testing.expectEqual(@as(u16, 2), pool.available());
    try std.testing.expectError(error.WriterTerminal, exhausted.finish());
}

test "response chunk writer rejects pool aliases before mutation" {
    const TestPool = Pool(8);
    var indices: [1]u16 = undefined;
    var nodes: [1]Node = undefined;
    var storage: [8]u8 = undefined;
    var pool = try TestPool.init(&indices, &nodes, &storage);
    var writer = pool.writer(8);
    try writer.write("safe");
    const source = storage[0..4];
    try std.testing.expectError(error.SourceAliasesPool, writer.write(source));
    try std.testing.expectEqual(@as(u16, 1), pool.available());
}

test "response chunk writer gzip preserves source until destination completes" {
    const TestPool = Pool(4096);
    var indices: [4]u16 = undefined;
    var nodes: [4]Node = undefined;
    var storage: [4 * 4096]u8 = undefined;
    var pool = try TestPool.init(&indices, &nodes, &storage);
    const source: [5000]u8 = @splat('a');
    var workspace: gzip_encoder.Workspace = undefined;
    for ([_]gzip_encoder.Level{ .fastest, .default, .best }) |level| {
        std.crypto.secureZero(u8, std.mem.asBytes(&workspace));
        var writer = pool.writer(source.len);
        try writer.write(&source);
        const outcome = writer.compress(&workspace, level);
        const encoded_length = switch (outcome) {
            .success => |length| length,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expect(encoded_length < source.len);
        const chain = try writer.finish();
        var encoded: [5000]u8 = undefined;
        var used: usize = 0;
        var chunks = pool.iterator(chain);
        while (chunks.next()) |bytes| {
            @memcpy(encoded[used..][0..bytes.len], bytes);
            used += bytes.len;
        }
        var input = std.Io.Reader.fixed(encoded[0..used]);
        var decoder = std.compress.flate.Decompress.init(&input, .gzip, &.{});
        var decoded: [source.len]u8 = undefined;
        var output = std.Io.Writer.fixed(&decoded);
        const written = try decoder.reader.streamRemaining(&output);
        try std.testing.expectEqual(source.len, written);
        try std.testing.expectEqualStrings(&source, decoded[0..written]);
        pool.release(chain);
    }
}
