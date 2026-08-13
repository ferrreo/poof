const slot_pool = @import("../slot_pool.zig");
const storage_slab = @import("storage_slab.zig");
const worker_entropy = @import("entropy.zig");

pub const Error = error{
    SlabTooSmall,
    SlabMisaligned,
} || worker_entropy.Error;

pub fn init(comptime context: anytype, self: anytype, slab: []u8) Error!void {
    if (slab.len < context.required_bytes) return error.SlabTooSmall;
    if (@intFromPtr(slab.ptr) % context.slab_alignment != 0) {
        return error.SlabMisaligned;
    }
    const bound = bind(context, slab[0..context.required_bytes]);
    for (bound.connections) |*connection| connection.* = .{};
    for (bound.requests) |*request| request.* = .{};
    self.* = .{
        .connections = bound.connections,
        .requests = bound.requests,
        .connection_free_indices = bound.connection_indices,
        .request_free_indices = bound.request_indices,
        .decoded_path_storage = bound.decoded_paths,
        .pipeline_storage = bound.pipelines,
        .response_storage = bound.responses,
        .html_json_scratch = bound.html_scratch,
        .live_static_paths = bound.static_paths,
        .live_static_reads = bound.static_reads,
        .response_chunks = context.PoolInit.initResponseChunks(bound.owned),
        .body_workspaces = context.PoolInit.initBody(bound.owned),
        .chunked_workspaces = context.PoolInit.initChunked(bound.owned),
        .gzip_decoders = context.PoolInit.initGzip(bound.owned),
        .json_hash_key = undefined,
        .connection_pool = slot_pool.SlotPool.init(bound.connection_indices) catch unreachable,
        .request_pool = slot_pool.SlotPool.init(bound.request_indices) catch unreachable,
    };
    try worker_entropy.fill(&self.json_hash_key);
}

fn Bound(comptime context: anytype) type {
    return struct {
        owned: []u8,
        connections: []context.Connection,
        requests: []context.Request,
        connection_indices: []u16,
        request_indices: []u16,
        decoded_paths: []u8,
        pipelines: []u8,
        responses: []u8,
        html_scratch: context.HtmlJsonScratchStorage,
        static_paths: context.LiveStaticPathStorage,
        static_reads: context.LiveStaticReadStorage,
    };
}

fn bind(comptime context: anytype, owned: []u8) Bound(context) {
    const layout = context.layout;
    const limits = context.limits;
    return .{
        .owned = owned,
        .connections = storage_slab.typedSlice(
            context.Connection,
            owned,
            layout.connections_offset,
            limits.connection_slots,
        ),
        .requests = storage_slab.typedSlice(
            context.Request,
            owned,
            layout.requests_offset,
            limits.request_slots,
        ),
        .connection_indices = storage_slab.typedSlice(
            u16,
            owned,
            layout.connection_indices_offset,
            limits.connection_slots,
        ),
        .request_indices = storage_slab.typedSlice(
            u16,
            owned,
            layout.request_indices_offset,
            limits.request_slots,
        ),
        .decoded_paths = storage_slab.byteSlice(
            owned,
            layout.decoded_paths_offset,
            context.decoded_path_storage_bytes,
        ),
        .pipelines = storage_slab.byteSlice(
            owned,
            layout.pipelines_offset,
            context.pipeline_storage_bytes,
        ),
        .responses = storage_slab.byteSlice(
            owned,
            layout.responses_offset,
            context.response_storage_bytes,
        ),
        .html_scratch = optionalBytes(
            context.HtmlJsonScratchStorage,
            owned,
            layout.html_json_scratch_offset,
            context.html_json_scratch_bytes,
        ),
        .static_paths = optionalBytes(
            context.LiveStaticPathStorage,
            owned,
            layout.live_static_paths_offset,
            context.live_static_path_storage_bytes,
        ),
        .static_reads = optionalBytes(
            context.LiveStaticReadStorage,
            owned,
            layout.live_static_reads_offset,
            context.live_static_read_storage_bytes,
        ),
    };
}

fn optionalBytes(
    comptime Storage: type,
    owned: []u8,
    offset: usize,
    byte_count: usize,
) Storage {
    if (comptime Storage == []u8) return storage_slab.byteSlice(owned, offset, byte_count);
    return .{};
}
