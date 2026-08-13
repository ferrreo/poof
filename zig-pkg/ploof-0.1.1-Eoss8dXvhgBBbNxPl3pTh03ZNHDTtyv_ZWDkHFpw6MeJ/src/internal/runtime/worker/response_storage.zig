const std = @import("std");
const config = @import("../config.zig");
const response_chunk_chain = @import("../../response/chunk_chain.zig");
const storage_slab = @import("storage_slab.zig");
const worker_response_chunks = @import("response_chunks.zig");

pub const ChunkPool = worker_response_chunks.Pool(config.response_chunk_bytes);
pub const ChunkNode = worker_response_chunks.Node;
pub const Chain = response_chunk_chain.Chain;
pub const chunk_none = response_chunk_chain.none;

pub const SendProgress = struct {
    sent: u32,
    chunk_index: u16 = response_chunk_chain.none,
    chunk_offset: u16 = 0,
};

pub const Source = enum(u8) {
    internal,
    body_workspace,
    chunks,
    static,
};

pub fn source(request: anytype) Source {
    comptime std.debug.assert(@typeInfo(@TypeOf(request)) == .pointer);
    if (request.response_static_body != null) return .static;
    if (comptime @hasField(@TypeOf(request.*), "response_chain")) {
        const chain = request.response_chain;
        if (!chain.isEmpty() or chain.head != chunk_none or
            chain.tail != chunk_none or chain.bytes != 0)
        {
            return .chunks;
        }
    }
    if (comptime !@hasField(@TypeOf(request.body), "response_source_offset")) {
        return .internal;
    }
    return if (request.body.response_source_offset == 0) .internal else .body_workspace;
}

fn staticBody(request: anytype) ?[]const u8 {
    const pointer = request.response_static_body orelse return null;
    if (request.response_used < request.response_high_water) return null;
    const length: usize = @intCast(request.response_used - request.response_high_water);
    return pointer[0..length];
}

/// Fixed response staging metadata and secure-clear operations.
pub fn Helpers(
    comptime bytes_per_request: u32,
    comptime body_enabled: bool,
    comptime body_bytes_per_slot: u32,
    comptime body_slots: u16,
) type {
    comptime {
        if (bytes_per_request == 0) {
            @compileError("response staging requires at least one byte");
        }
    }
    return struct {
        pub fn region(storage: anytype, request_index: u16) []u8 {
            std.debug.assert(request_index < storage.requests.len);
            return storage_slab.region(
                storage.response_storage,
                request_index,
                bytes_per_request,
            );
        }

        pub fn writable(storage: anytype, request_index: u16) []u8 {
            const request = &storage.requests[request_index];
            if (source(request) == .chunks) releaseChunkSource(storage, request_index);
            request.response_static_body = null;
            if (body_enabled) request.body.response_source_offset = 0;
            request.response_used = 0;
            request.response_sent = 0;
            request.flags.response_dirty_full = true;
            return region(storage, request_index);
        }

        pub fn readable(storage: anytype, request_index: u16) []const u8 {
            const request = &storage.requests[request_index];
            return switch (source(request)) {
                .internal => region(storage, request_index),
                .body_workspace => externalReadable(storage, request),
                .chunks, .static => "",
            };
        }

        pub fn chunkWriter(storage: anytype, limit: u32) ChunkPool.Writer {
            return storage.response_chunks.writer(limit);
        }

        pub fn commitChunks(
            storage: anytype,
            request_index: u16,
            head: []const u8,
            chain: Chain,
        ) bool {
            if (request_index >= storage.requests.len) return false;
            const request = &storage.requests[request_index];
            if (request.phase != .live or !request.response_chain.isEmpty() or
                request.response_static_body != null)
            {
                return false;
            }
            if (request.response_used != 0 or request.response_sent != 0 or
                request.response_high_water != 0 or request.flags.response_dirty_full)
            {
                return false;
            }
            if (body_enabled and request.body.response_source_offset != 0) return false;
            if (head.len == 0 or head.len > region(storage, request_index).len) return false;
            if (!storage.response_chunks.validate(chain)) return false;
            const total = std.math.add(usize, head.len, chain.bytes) catch return false;
            const total_u32 = std.math.cast(u32, total) orelse return false;
            @memcpy(region(storage, request_index)[0..head.len], head);
            request.response_chain = chain;
            request.response_chunk_index = chain.head;
            request.response_chunk_offset = 0;
            request.response_high_water = @intCast(head.len);
            request.response_used = total_u32;
            return true;
        }

        pub fn commitStatic(
            storage: anytype,
            request_index: u16,
            head: []const u8,
            body: []const u8,
        ) bool {
            if (request_index >= storage.requests.len or head.len == 0 or body.len == 0) {
                return false;
            }
            const request = &storage.requests[request_index];
            if (request.phase != .live or !request.response_chain.isEmpty() or
                request.response_static_body != null or request.response_used != 0 or
                request.response_sent != 0 or
                request.response_high_water != 0)
            {
                return false;
            }
            if (body_enabled and request.body.response_source_offset != 0) return false;
            const output = region(storage, request_index);
            if (head.len > output.len) return false;
            const total = std.math.add(usize, head.len, body.len) catch return false;
            const total_u32 = std.math.cast(u32, total) orelse return false;
            if (@intFromPtr(output.ptr) != @intFromPtr(head.ptr)) {
                @memcpy(output[0..head.len], head);
            }
            request.response_static_body = body.ptr;
            request.response_high_water = @intCast(head.len);
            request.response_used = total_u32;
            return true;
        }

        pub fn commitBorrowedBody(
            storage: anytype,
            request_index: u16,
            body: []const u8,
        ) bool {
            if (request_index >= storage.requests.len or body.len == 0) return false;
            const request = &storage.requests[request_index];
            if (request.phase != .live or !request.response_chain.isEmpty() or
                request.response_static_body != null or request.response_used != 0 or
                request.response_sent != 0 or
                request.response_high_water != 0 or request.flags.response_dirty_full)
            {
                return false;
            }
            if (body_enabled and request.body.response_source_offset != 0) return false;
            const length = std.math.cast(u32, body.len) orelse return false;
            request.response_static_body = body.ptr;
            request.response_used = length;
            return true;
        }

        pub fn discardChunks(storage: anytype, chain: Chain) void {
            storage.response_chunks.release(chain);
        }

        pub fn commit(
            storage: anytype,
            request_index: u16,
            bytes: []const u8,
        ) bool {
            return commitWithDirtyPolicy(storage, request_index, bytes, false);
        }

        /// Keeps an earlier uncommitted writable exposure fully dirty.
        pub fn commitPreservingFullDirty(
            storage: anytype,
            request_index: u16,
            bytes: []const u8,
        ) bool {
            return commitWithDirtyPolicy(storage, request_index, bytes, true);
        }

        pub fn commitExternal(
            storage: anytype,
            request_index: u16,
            bytes: []const u8,
        ) bool {
            if (!body_enabled or bytes.len == 0) return false;
            if (request_index >= storage.requests.len) return false;
            const request = &storage.requests[request_index];
            if (!request.response_chain.isEmpty() or request.response_static_body != null) {
                return false;
            }
            if (request.phase != .live) return false;
            const workspace_index = request.body.workspace_index orelse return false;
            if (workspace_index >= body_slots) return false;
            const workspace = bodyRegion(storage, workspace_index);
            const workspace_address = @intFromPtr(workspace.ptr);
            const bytes_address = @intFromPtr(bytes.ptr);
            if (bytes_address < workspace_address) return false;
            const offset = bytes_address - workspace_address;
            if (offset > workspace.len or bytes.len > workspace.len - offset) return false;
            const encoded_offset = std.math.cast(u32, offset + 1) orelse {
                return false;
            };
            const length = std.math.cast(u32, bytes.len) orelse return false;
            request.body.response_source_offset = encoded_offset;
            request.response_used = length;
            request.response_sent = 0;
            request.response_high_water = 0;
            request.body.dirty_full = true;
            request.body.tainted_full = true;
            return true;
        }

        fn commitWithDirtyPolicy(
            storage: anytype,
            request_index: u16,
            bytes: []const u8,
            preserve_full_dirty: bool,
        ) bool {
            if (request_index >= storage.requests.len) return false;
            const request = &storage.requests[request_index];
            if (!request.response_chain.isEmpty() or request.response_static_body != null) {
                return false;
            }
            if (!request.flags.response_dirty_full) return false;
            const output = region(storage, request_index);
            if (bytes.len == 0 or bytes.len > output.len or
                @intFromPtr(bytes.ptr) != @intFromPtr(output.ptr))
            {
                return false;
            }
            request.response_high_water = @max(
                request.response_high_water,
                @as(u32, @intCast(bytes.len)),
            );
            if (body_enabled) request.body.response_source_offset = 0;
            request.response_used = @intCast(bytes.len);
            request.response_sent = 0;
            request.flags.response_dirty_full = preserve_full_dirty;
            return true;
        }

        pub fn clear(storage: anytype, request_index: u16) void {
            std.debug.assert(request_index < storage.requests.len);
            const request = &storage.requests[request_index];
            if (source(request) == .chunks) {
                releaseChunkSource(storage, request_index);
                return;
            }
            const output = region(storage, request_index);
            std.crypto.secureZero(
                u8,
                if (request.flags.response_dirty_full)
                    output
                else
                    output[0..request.response_high_water],
            );
            request.response_used = 0;
            request.response_sent = 0;
            request.response_high_water = 0;
            request.response_static_body = null;
            request.flags.response_dirty_full = false;
            if (body_enabled) request.body.response_source_offset = 0;
        }

        pub fn sendReadable(
            storage: anytype,
            request_index: u16,
        ) error{StateInvariant}![]const u8 {
            if (request_index >= storage.requests.len) return error.StateInvariant;
            const request = &storage.requests[request_index];
            if (request.response_sent > request.response_used) return error.StateInvariant;
            if (source(request) == .internal or source(request) == .body_workspace) {
                const response = readable(storage, request_index);
                if (request.response_used > response.len) return error.StateInvariant;
                return response[request.response_sent..request.response_used];
            }
            if (source(request) == .static) {
                if (request.response_sent < request.response_high_water) {
                    const head = region(storage, request_index)[0..request.response_high_water];
                    return head[request.response_sent..];
                }
                const offset = request.response_sent - request.response_high_water;
                const body = staticBody(request) orelse return error.StateInvariant;
                if (offset > body.len) return error.StateInvariant;
                return body[offset..];
            }
            if (request.response_sent == request.response_used) return "";
            if (request.response_sent < request.response_high_water) {
                const head = region(storage, request_index)[0..request.response_high_water];
                return head[request.response_sent..];
            }
            const index = request.response_chunk_index;
            if (index >= storage.response_chunks.nodes.len) return error.StateInvariant;
            const node = storage.response_chunks.nodes[index];
            if (node.used == 0 or node.used > config.response_chunk_bytes or
                request.response_chunk_offset >= node.used)
            {
                return error.StateInvariant;
            }
            const start = @as(usize, index) * config.response_chunk_bytes;
            const bytes = storage.response_chunks.storage[start..][0..node.used];
            return bytes[request.response_chunk_offset..];
        }

        pub fn planSendProgress(
            storage: anytype,
            request_index: u16,
            sent: usize,
        ) error{ StateInvariant, InvalidCompletion }!SendProgress {
            const remaining = try sendReadable(storage, request_index);
            if (sent > remaining.len) return error.InvalidCompletion;
            const request = &storage.requests[request_index];
            const added = std.math.cast(u32, sent) orelse return error.StateInvariant;
            const next = std.math.add(u32, request.response_sent, added) catch {
                return error.StateInvariant;
            };
            if (next > request.response_used) return error.InvalidCompletion;
            if (source(request) != .chunks) return .{ .sent = next };
            if (request.response_sent < request.response_high_water) {
                if (next <= request.response_high_water) return .{
                    .sent = next,
                    .chunk_index = request.response_chunk_index,
                };
                return error.InvalidCompletion;
            }
            const offset = std.math.add(
                usize,
                request.response_chunk_offset,
                sent,
            ) catch return error.StateInvariant;
            const node = storage.response_chunks.nodes[request.response_chunk_index];
            if (offset < node.used) return .{
                .sent = next,
                .chunk_index = request.response_chunk_index,
                .chunk_offset = @intCast(offset),
            };
            if (offset != node.used) return error.InvalidCompletion;
            if (next == request.response_used) return .{
                .sent = next,
                .chunk_index = request.response_chunk_index,
                .chunk_offset = node.used,
            };
            if (node.next == response_chunk_chain.none) return error.StateInvariant;
            return .{ .sent = next, .chunk_index = node.next };
        }

        pub fn commitSendProgress(
            storage: anytype,
            request_index: u16,
            progress: SendProgress,
        ) void {
            const request = &storage.requests[request_index];
            request.response_sent = progress.sent;
            if (source(request) != .chunks) return;
            request.response_chunk_index = progress.chunk_index;
            request.response_chunk_offset = progress.chunk_offset;
        }

        pub fn chunkStateValid(storage: anytype, request_index: u16) bool {
            const request = &storage.requests[request_index];
            if (source(request) != .chunks or request.flags.response_dirty_full or
                request.response_high_water == 0 or
                request.response_used != request.response_high_water +
                    request.response_chain.bytes)
            {
                return false;
            }
            if (!storage.response_chunks.validate(request.response_chain)) return false;
            if (request.response_sent < request.response_high_water) {
                return request.response_chunk_index == request.response_chain.head and
                    request.response_chunk_offset == 0;
            }
            const body_sent = request.response_sent - request.response_high_water;
            if (request.response_chain.isEmpty()) {
                return body_sent == 0 and
                    request.response_chunk_index == response_chunk_chain.none and
                    request.response_chunk_offset == 0;
            }
            const cursor = cursorAt(storage, request.response_chain, body_sent) orelse {
                return false;
            };
            return cursor.chunk_index == request.response_chunk_index and
                cursor.chunk_offset == request.response_chunk_offset;
        }

        fn externalReadable(storage: anytype, request: anytype) []const u8 {
            if (!body_enabled or request.phase != .live) return "";
            const workspace_index = request.body.workspace_index orelse return "";
            if (workspace_index >= body_slots or
                (!request.body.dirty_full and !request.body.tainted_full) or
                request.response_used == 0)
            {
                return "";
            }
            const workspace = bodyRegion(storage, workspace_index);
            const offset: usize = request.body.response_source_offset - 1;
            const length: usize = request.response_used;
            if (offset > workspace.len or length > workspace.len - offset) return "";
            return workspace[offset..][0..length];
        }

        fn bodyRegion(storage: anytype, workspace_index: u16) []u8 {
            if (!body_enabled) unreachable;
            return storage_slab.region(
                storage.body_workspaces.storage,
                workspace_index,
                body_bytes_per_slot,
            );
        }

        fn releaseChunkSource(storage: anytype, request_index: u16) void {
            const request = &storage.requests[request_index];
            storage.response_chunks.release(request.response_chain);
            std.crypto.secureZero(
                u8,
                region(storage, request_index)[0..request.response_high_water],
            );
            request.response_chain = .{};
            request.response_chunk_index = response_chunk_chain.none;
            request.response_chunk_offset = 0;
            request.response_used = 0;
            request.response_sent = 0;
            request.response_high_water = 0;
            request.response_static_body = null;
            request.flags.response_dirty_full = false;
            if (body_enabled) request.body.response_source_offset = 0;
        }

        fn cursorAt(storage: anytype, chain: Chain, sent: u32) ?SendProgress {
            if (sent > chain.bytes) return null;
            var index = chain.head;
            var remaining = sent;
            var chunks = chain.chunks;
            while (chunks != 0) : (chunks -= 1) {
                if (index >= storage.response_chunks.nodes.len) return null;
                const node = storage.response_chunks.nodes[index];
                if (remaining < node.used) return .{
                    .sent = sent,
                    .chunk_index = index,
                    .chunk_offset = @intCast(remaining),
                };
                if (remaining == node.used) {
                    if (sent == chain.bytes) return .{
                        .sent = sent,
                        .chunk_index = index,
                        .chunk_offset = node.used,
                    };
                    if (node.next == response_chunk_chain.none) return null;
                    return .{ .sent = sent, .chunk_index = node.next };
                }
                remaining -= node.used;
                index = node.next;
            }
            return null;
        }
    };
}
