const body_storage = @import("body_storage.zig");
const config = @import("../config.zig");
const worker_chunked_pool = @import("chunked_pool.zig");
const storage_slab = @import("storage_slab.zig");

pub fn Builder(
    comptime body_enabled: bool,
    comptime limits: anytype,
    comptime body_storage_bytes: usize,
    comptime layout: anytype,
    comptime ResponseChunkNode: type,
    comptime ResponseChunkPool: type,
    comptime ChunkedState: type,
    comptime Gzip: type,
) type {
    return struct {
        pub fn initResponseChunks(owned: []u8) ResponseChunkPool {
            const indices = storage_slab.typedSlice(
                u16,
                owned,
                layout.response_chunk_indices_offset,
                limits.response_chunk_count,
            );
            const nodes = storage_slab.typedSlice(
                ResponseChunkNode,
                owned,
                layout.response_chunk_nodes_offset,
                limits.response_chunk_count,
            );
            const storage = storage_slab.byteSlice(
                owned,
                layout.response_chunk_storage_offset,
                config.responseChunkStorageBytes(limits),
            );
            return ResponseChunkPool.init(indices, nodes, storage) catch unreachable;
        }

        pub fn initBody(owned: []u8) body_storage.Pool(body_enabled) {
            return body_storage.initPool(
                body_enabled,
                limits.body_workspace_slots,
                body_storage_bytes,
                owned,
                layout.body_indices_offset,
                layout.body_storage_offset,
            );
        }

        pub fn initChunked(owned: []u8) worker_chunked_pool.Pool(
            ChunkedState,
            body_enabled,
        ) {
            return worker_chunked_pool.init(
                ChunkedState,
                body_enabled,
                owned,
                layout.chunked_indices_offset,
                layout.chunked_storage_offset,
                limits.chunked_workspace_slots,
            );
        }

        pub fn initGzip(owned: []u8) Gzip.Field {
            return Gzip.init(
                owned,
                layout.gzip_pool_offset,
                layout.gzip_slots_offset,
            );
        }
    };
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}
