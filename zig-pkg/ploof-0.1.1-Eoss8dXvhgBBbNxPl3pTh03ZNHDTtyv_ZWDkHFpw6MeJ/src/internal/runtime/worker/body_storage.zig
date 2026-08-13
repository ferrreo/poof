const std = @import("std");
const body_api = @import("../../../body.zig");
const connection_body = @import("../connection/body.zig");
const gzip_decoder_pool = @import("../gzip/decoder_pool.zig");
const slot_pool = @import("../slot_pool.zig");
const storage_slab = @import("storage_slab.zig");
const worker_chunked_pool = @import("chunked_pool.zig");

pub const AccessError = error{
    RequestIndexOutOfRange,
    RequestNotLive,
    BodyWorkspaceNotLeased,
    BodyWorkspaceNotEmpty,
    BodyWorkspaceOverflow,
    ChunkedWorkspaceNotLeased,
    GzipDecoderActive,
    InvalidUtf8,
};

pub fn Lease(comptime enabled: bool) type {
    return if (enabled) struct {
        workspace_index: ?u16 = null,
        used: u32 = 0,
        /// Zero selects response staging; otherwise workspace response offset plus one.
        response_source_offset: u32 = 0,
        /// An uncommitted tail write requires full clearing until its length is committed.
        dirty_full: bool = false,
        /// Full-workspace exposure requires full clearing until the lease is released.
        tainted_full: bool = false,
        receiver: connection_body.FixedIdentity = .{ .expected_bytes = 0 },
        kind: body_api.Kind = .bytes,
        multipart: bool = false,
        terminal_response_pending: bool = false,
        chunks: [1]body_api.Chunk = .{body_api.Chunk.init("")},
    } else struct {};
}

pub fn Pool(comptime enabled: bool) type {
    return if (enabled) struct {
        free_indices: []u16,
        storage: []u8,
        pool: slot_pool.SlotPool,
    } else struct {};
}

pub fn GzipStorage(comptime enabled: bool, comptime limits: anytype) type {
    const queue_bytes: usize = if (enabled)
        storage_slab.checkedMultiply(
            limits.receive_buffer_bytes,
            limits.gzip.input_chunks_per_slot,
        )
    else
        0;
    const DecoderPool = if (enabled) gzip_decoder_pool.FixedPool(
        limits.gzip.decoder_slots,
        queue_bytes,
        limits.receive_buffer_bytes,
        limits.gzip.members_max,
    ) else struct {};
    const Slot = if (enabled) DecoderPool.Slot else struct {};

    return struct {
        pub const PoolType = DecoderPool;
        pub const SlotType = Slot;
        pub const LeaseField = if (enabled) ?gzip_decoder_pool.Lease else void;
        pub const Field = if (enabled) *DecoderPool else void;
        pub const thread_count: u16 = if (enabled) limits.gzip.decoder_slots else 0;
        pub const input_queue_bytes_per_slot: usize = queue_bytes;
        pub const output_mailbox_capacity_bytes_per_slot: usize = if (enabled)
            DecoderPool.output_mailbox_capacity_bytes
        else
            0;
        pub const output_mailbox_bytes_per_slot: usize = if (enabled)
            DecoderPool.output_mailbox_bytes
        else
            0;
        pub const control_bytes: usize = if (enabled) @sizeOf(DecoderPool) else 0;
        pub const slot_bytes: usize = if (enabled) @sizeOf(Slot) else 0;
        pub const slots_bytes: usize = if (enabled)
            storage_slab.checkedMultiply(@sizeOf(Slot), limits.gzip.decoder_slots)
        else
            0;
        pub const requested_stack_bytes: u64 = if (enabled)
            @as(u64, limits.gzip.decoder_slots) * limits.gzip.thread_stack_bytes
        else
            0;

        pub fn init(
            owned: []u8,
            pool_offset: usize,
            slots_offset: usize,
        ) Field {
            if (enabled) {
                const pool = &storage_slab.typedSlice(
                    DecoderPool,
                    owned,
                    pool_offset,
                    1,
                )[0];
                const slots: *[limits.gzip.decoder_slots]Slot = @ptrCast(
                    storage_slab.typedSlice(
                        Slot,
                        owned,
                        slots_offset,
                        limits.gzip.decoder_slots,
                    ).ptr,
                );
                pool.init(slots);
                return pool;
            }
            return {};
        }
    };
}

pub fn gzipEnabled(comptime App: type, comptime fallback: bool) bool {
    if (@hasDecl(App, "request_body_decoding_enabled")) {
        return App.request_body_decoding_enabled;
    }
    return fallback;
}

pub fn initPool(
    comptime enabled: bool,
    comptime slots: u16,
    comptime storage_bytes: usize,
    owned: []u8,
    indices_offset: usize,
    storage_offset: usize,
) Pool(enabled) {
    if (enabled) {
        const indices = storage_slab.typedSlice(u16, owned, indices_offset, slots);
        return .{
            .free_indices = indices,
            .storage = storage_slab.byteSlice(
                owned,
                storage_offset,
                storage_bytes,
            ),
            .pool = slot_pool.SlotPool.init(indices) catch unreachable,
        };
    }
    return .{};
}

pub fn Helpers(
    comptime enabled: bool,
    comptime bytes_per_slot: u32,
    comptime body_slots: u16,
    comptime chunked_slots: u16,
    comptime ChunkedState: type,
) type {
    return struct {
        const LeaseView = struct {
            workspace_index: u16,
            used: u32,
        };

        pub fn releaseUnused(storage: anytype, request_index: u16) AccessError!bool {
            if (request_index >= storage.requests.len) return error.RequestIndexOutOfRange;
            const request = &storage.requests[request_index];
            if (request.phase != .live) return error.RequestNotLive;
            if (enabled) return releaseUnusedEnabled(storage, request);
            if (request.chunked_workspace_index != null) {
                return error.ChunkedWorkspaceNotLeased;
            }
            return false;
        }

        pub fn writable(storage: anytype, request_index: u16) AccessError![]u8 {
            const view = try lease(storage, request_index);
            storage.requests[request_index].body.dirty_full = true;
            return region(storage, view.workspace_index)[view.used..];
        }

        pub fn readable(storage: anytype, request_index: u16) AccessError![]const u8 {
            const view = try lease(storage, request_index);
            return region(storage, view.workspace_index)[0..view.used];
        }

        pub fn workspace(storage: anytype, request_index: u16) AccessError![]u8 {
            const view = try lease(storage, request_index);
            storage.requests[request_index].body.dirty_full = true;
            storage.requests[request_index].body.tainted_full = true;
            return region(storage, view.workspace_index);
        }

        pub fn markDirty(storage: anytype, request_index: u16) AccessError!void {
            _ = try lease(storage, request_index);
            storage.requests[request_index].body.dirty_full = true;
            storage.requests[request_index].body.tainted_full = true;
        }

        pub fn commit(
            storage: anytype,
            request_index: u16,
            byte_count: usize,
        ) AccessError!void {
            const view = try lease(storage, request_index);
            const added = std.math.cast(u32, byte_count) orelse {
                return error.BodyWorkspaceOverflow;
            };
            const used = std.math.add(u32, view.used, added) catch {
                return error.BodyWorkspaceOverflow;
            };
            if (used > bytes_per_slot) return error.BodyWorkspaceOverflow;
            storage.requests[request_index].body.used = used;
            storage.requests[request_index].body.dirty_full = false;
        }

        pub fn finish(
            storage: anytype,
            request_index: u16,
            kind: body_api.Kind,
        ) AccessError!body_api.Decoded {
            const view = try lease(storage, request_index);
            const request = &storage.requests[request_index];
            const bytes = region(storage, view.workspace_index)[0..view.used];
            request.body.chunks[0] = body_api.Chunk.init(bytes);
            const body_bytes = body_api.Bytes.init(&request.body.chunks) catch unreachable;
            return switch (kind) {
                .none => if (body_bytes.len() == 0)
                    .none
                else
                    error.BodyWorkspaceOverflow,
                .bytes => .{ .bytes = body_bytes },
                .text => .{ .text = body_api.Text.fromBytes(body_bytes) catch {
                    return error.InvalidUtf8;
                } },
            };
        }

        pub fn clearReleased(storage: anytype, request: anytype, body_index: u16) void {
            const body_bytes = region(storage, body_index);
            std.crypto.secureZero(
                u8,
                if (request.body.dirty_full or request.body.tainted_full)
                    body_bytes
                else
                    body_bytes[0..request.body.used],
            );
            storage.body_workspaces.pool.release(body_index);
        }

        pub fn resetAll(storage: anytype) void {
            if (enabled) {
                std.crypto.secureZero(u8, storage.body_workspaces.storage);
                worker_chunked_pool.reset(ChunkedState, &storage.chunked_workspaces);
                for (storage.requests) |*request| {
                    request.body = .{};
                    request.chunked_workspace_index = null;
                    if (comptime @TypeOf(request.gzip_lease) != void) request.gzip_lease = null;
                }
                storage.body_workspaces.pool = slot_pool.SlotPool.init(
                    storage.body_workspaces.free_indices,
                ) catch unreachable;
            }
        }

        fn releaseUnusedEnabled(storage: anytype, request: anytype) AccessError!bool {
            if (comptime @TypeOf(request.gzip_lease) != void) {
                if (request.gzip_lease != null) return error.GzipDecoderActive;
            }
            if (request.body.workspace_index == null and
                (request.body.used != 0 or
                    request.body.dirty_full or
                    request.body.tainted_full))
            {
                return error.BodyWorkspaceNotLeased;
            }
            if (request.body.workspace_index) |index| {
                if (request.body.used != 0) return error.BodyWorkspaceNotEmpty;
                if (index >= body_slots) return error.BodyWorkspaceNotLeased;
            }
            if (request.chunked_workspace_index) |index| {
                if (index >= chunked_slots) return error.ChunkedWorkspaceNotLeased;
            }
            var released = false;
            if (request.chunked_workspace_index) |index| {
                worker_chunked_pool.clear(ChunkedState, &storage.chunked_workspaces, index);
                storage.chunked_workspaces.pool.release(index);
                request.chunked_workspace_index = null;
                released = true;
            }
            if (request.body.workspace_index) |index| {
                if (request.body.dirty_full or request.body.tainted_full) {
                    std.crypto.secureZero(u8, region(storage, index));
                }
                request.body = .{};
                storage.body_workspaces.pool.release(index);
                released = true;
            }
            return released;
        }

        fn lease(storage: anytype, request_index: u16) AccessError!LeaseView {
            if (request_index >= storage.requests.len) return error.RequestIndexOutOfRange;
            const request = &storage.requests[request_index];
            if (request.phase != .live) return error.RequestNotLive;
            if (!enabled) return error.BodyWorkspaceNotLeased;
            const workspace_index = request.body.workspace_index orelse {
                return error.BodyWorkspaceNotLeased;
            };
            if (workspace_index >= body_slots) return error.BodyWorkspaceNotLeased;
            if (request.body.used > bytes_per_slot) return error.BodyWorkspaceOverflow;
            return .{ .workspace_index = workspace_index, .used = request.body.used };
        }

        fn region(storage: anytype, workspace_index: u16) []u8 {
            return storage_slab.region(
                storage.body_workspaces.storage,
                workspace_index,
                bytes_per_slot,
            );
        }
    };
}
