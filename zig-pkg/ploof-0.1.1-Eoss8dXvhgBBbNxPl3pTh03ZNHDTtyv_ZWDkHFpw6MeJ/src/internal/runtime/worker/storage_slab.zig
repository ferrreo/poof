const std = @import("std");
const config = @import("../config.zig");

pub const Layout = struct {
    connections_offset: usize,
    requests_offset: usize,
    connection_indices_offset: usize,
    request_indices_offset: usize,
    decoded_paths_offset: usize,
    pipelines_offset: usize,
    responses_offset: usize,
    response_chunk_indices_offset: usize,
    response_chunk_nodes_offset: usize,
    response_chunk_storage_offset: usize,
    html_json_scratch_offset: usize,
    body_indices_offset: usize,
    body_storage_offset: usize,
    chunked_indices_offset: usize,
    chunked_storage_offset: usize,
    gzip_pool_offset: usize,
    gzip_slots_offset: usize,
    live_static_paths_offset: usize,
    live_static_reads_offset: usize,
    bytes: usize,
};

pub fn make(
    comptime Connection: type,
    comptime Request: type,
    comptime ResponseChunkNode: type,
    comptime ChunkedState: type,
    comptime GzipPool: type,
    comptime GzipSlot: type,
    comptime limits: config.Limits,
    comptime decoded_path_bytes: u32,
    comptime body_workspace_bytes: u32,
    comptime body_workspace_alignment: u32,
    comptime html_json_scratch_bytes: u32,
    comptime live_static_path_storage_bytes: usize,
    comptime live_static_read_storage_bytes: usize,
) Layout {
    var cursor: usize = 0;
    const base = reserveBase(&cursor, Connection, Request, limits, decoded_path_bytes);
    const extra = reserveExtra(
        &cursor,
        ResponseChunkNode,
        ChunkedState,
        GzipPool,
        GzipSlot,
        limits,
        body_workspace_bytes,
        body_workspace_alignment,
        html_json_scratch_bytes,
        live_static_path_storage_bytes,
        live_static_read_storage_bytes,
    );
    const alignment = slabAlignment(
        Connection,
        Request,
        ResponseChunkNode,
        ChunkedState,
        GzipPool,
        GzipSlot,
        body_workspace_bytes != 0,
        body_workspace_alignment,
    );
    return .{
        .connections_offset = base.connections,
        .requests_offset = base.requests,
        .connection_indices_offset = base.connection_indices,
        .request_indices_offset = base.request_indices,
        .decoded_paths_offset = base.decoded_paths,
        .pipelines_offset = base.pipelines,
        .responses_offset = base.responses,
        .response_chunk_indices_offset = extra.response_chunk_indices,
        .response_chunk_nodes_offset = extra.response_chunk_nodes,
        .response_chunk_storage_offset = extra.response_chunk_storage,
        .html_json_scratch_offset = extra.html_json_scratch,
        .body_indices_offset = extra.body_indices,
        .body_storage_offset = extra.body_storage,
        .chunked_indices_offset = extra.chunked_indices,
        .chunked_storage_offset = extra.chunked_storage,
        .gzip_pool_offset = extra.gzip.pool,
        .gzip_slots_offset = extra.gzip.slots,
        .live_static_paths_offset = extra.live_static_paths,
        .live_static_reads_offset = extra.live_static_reads,
        .bytes = checkedAlignForward(cursor, alignment),
    };
}

const ExtraLayout = struct {
    response_chunk_indices: usize,
    response_chunk_nodes: usize,
    response_chunk_storage: usize,
    html_json_scratch: usize,
    body_indices: usize,
    body_storage: usize,
    chunked_indices: usize,
    chunked_storage: usize,
    gzip: GzipOffsets,
    live_static_paths: usize,
    live_static_reads: usize,
};

fn reserveExtra(
    cursor: *usize,
    comptime ResponseChunkNode: type,
    comptime ChunkedState: type,
    comptime GzipPool: type,
    comptime GzipSlot: type,
    comptime limits: config.Limits,
    comptime body_workspace_bytes: u32,
    comptime body_workspace_alignment: u32,
    comptime html_json_scratch_bytes: u32,
    comptime live_static_path_storage_bytes: usize,
    comptime live_static_read_storage_bytes: usize,
) ExtraLayout {
    const body_enabled = body_workspace_bytes != 0;
    const body_storage_bytes = checkedMultiply(
        limits.body_workspace_slots,
        body_workspace_bytes,
    );
    return .{
        .response_chunk_indices = reserve(cursor, u16, limits.response_chunk_count),
        .response_chunk_nodes = reserve(cursor, ResponseChunkNode, limits.response_chunk_count),
        .response_chunk_storage = reserveBytes(
            cursor,
            config.responseChunkStorageBytes(limits),
        ),
        .html_json_scratch = reserveBytes(cursor, html_json_scratch_bytes),
        .body_indices = reserveOptional(
            cursor,
            u16,
            limits.body_workspace_slots,
            body_enabled,
        ),
        .body_storage = reserveOptionalAlignedBytes(
            cursor,
            body_storage_bytes,
            body_workspace_alignment,
            body_enabled,
        ),
        .chunked_indices = reserveOptional(
            cursor,
            u16,
            limits.chunked_workspace_slots,
            body_enabled,
        ),
        .chunked_storage = reserveOptional(
            cursor,
            ChunkedState,
            limits.chunked_workspace_slots,
            body_enabled,
        ),
        .gzip = reserveGzip(
            cursor,
            GzipPool,
            GzipSlot,
            limits.gzip.decoder_slots,
            body_enabled,
        ),
        .live_static_paths = reserveBytes(cursor, live_static_path_storage_bytes),
        .live_static_reads = reserveBytes(cursor, live_static_read_storage_bytes),
    };
}

const GzipOffsets = struct { pool: usize, slots: usize };

fn reserveGzip(
    cursor: *usize,
    comptime Pool: type,
    comptime Slot: type,
    comptime slot_count: u16,
    comptime enabled: bool,
) GzipOffsets {
    const pool = reserveOptional(cursor, Pool, 1, enabled);
    const slots = reserveOptional(cursor, Slot, slot_count, enabled);
    return .{
        .pool = pool,
        .slots = slots,
    };
}

const BaseLayout = struct {
    connections: usize,
    requests: usize,
    connection_indices: usize,
    request_indices: usize,
    decoded_paths: usize,
    pipelines: usize,
    responses: usize,
};

fn reserveBase(
    cursor: *usize,
    comptime Connection: type,
    comptime Request: type,
    comptime limits: config.Limits,
    comptime decoded_path_bytes: u32,
) BaseLayout {
    const connections = reserve(cursor, Connection, limits.connection_slots);
    const requests = reserve(cursor, Request, limits.request_slots);
    const connection_indices = reserve(cursor, u16, limits.connection_slots);
    const request_indices = reserve(cursor, u16, limits.request_slots);
    const decoded_paths = reserveBytes(
        cursor,
        checkedMultiply(limits.connection_slots, decoded_path_bytes),
    );
    const pipelines = reserveBytes(
        cursor,
        checkedMultiply(limits.connection_slots, limits.pipeline_bytes_per_connection),
    );
    const responses = reserveBytes(
        cursor,
        checkedMultiply(limits.request_slots, limits.response_bytes_per_request),
    );
    return .{
        .connections = connections,
        .requests = requests,
        .connection_indices = connection_indices,
        .request_indices = request_indices,
        .decoded_paths = decoded_paths,
        .pipelines = pipelines,
        .responses = responses,
    };
}

pub fn slabAlignment(
    comptime Connection: type,
    comptime Request: type,
    comptime ResponseChunkNode: type,
    comptime ChunkedState: type,
    comptime GzipPool: type,
    comptime GzipSlot: type,
    comptime body_enabled: bool,
    comptime body_workspace_alignment: u32,
) usize {
    const record_alignment = @max(
        @max(@alignOf(Connection), @alignOf(Request)),
        @alignOf(ResponseChunkNode),
    );
    const body_alignment = if (body_enabled) @max(
        @alignOf(ChunkedState),
        @max(@alignOf(GzipPool), @alignOf(GzipSlot)),
    ) else @alignOf(u16);
    const workspace_alignment = if (body_enabled) body_workspace_alignment else 1;
    return @max(
        @max(record_alignment, body_alignment),
        @max(@alignOf(u16), workspace_alignment),
    );
}

pub fn typedSlice(
    comptime T: type,
    storage: []u8,
    offset: usize,
    count: usize,
) []T {
    const pointer: [*]T = @ptrCast(@alignCast(storage.ptr + offset));
    return pointer[0..count];
}

pub fn byteSlice(storage: []u8, offset: usize, count: usize) []u8 {
    std.debug.assert(offset <= storage.len);
    std.debug.assert(count <= storage.len - offset);
    return storage[offset..][0..count];
}

pub fn region(storage: []u8, index: u16, comptime bytes_per_item: u32) []u8 {
    const start = @as(usize, index) * bytes_per_item;
    return storage[start..][0..bytes_per_item];
}

pub fn checkedMultiply(comptime left: anytype, comptime right: anytype) usize {
    return std.math.mul(usize, @intCast(left), @intCast(right)) catch {
        @compileError("worker storage slab byte count overflows usize");
    };
}

fn reserveOptional(
    cursor: *usize,
    comptime T: type,
    comptime count: usize,
    comptime enabled: bool,
) usize {
    if (!enabled) return cursor.*;
    return reserve(cursor, T, count);
}

fn reserveOptionalBytes(
    cursor: *usize,
    comptime count: usize,
    comptime enabled: bool,
) usize {
    if (!enabled) return cursor.*;
    return reserveBytes(cursor, count);
}

fn reserveOptionalAlignedBytes(
    cursor: *usize,
    comptime count: usize,
    comptime alignment: usize,
    comptime enabled: bool,
) usize {
    if (!enabled) return cursor.*;
    cursor.* = checkedAlignForward(cursor.*, alignment);
    return reserveBytes(cursor, count);
}

fn reserve(cursor: *usize, comptime T: type, comptime count: usize) usize {
    cursor.* = checkedAlignForward(cursor.*, @alignOf(T));
    const offset = cursor.*;
    cursor.* = checkedAdd(cursor.*, checkedMultiply(@sizeOf(T), count));
    return offset;
}

fn reserveBytes(cursor: *usize, comptime count: usize) usize {
    const offset = cursor.*;
    cursor.* = checkedAdd(cursor.*, count);
    return offset;
}

fn checkedAlignForward(comptime value: usize, comptime alignment: usize) usize {
    const mask = alignment - 1;
    return checkedAdd(value, mask) & ~mask;
}

fn checkedAdd(comptime left: usize, comptime right: usize) usize {
    return std.math.add(usize, left, right) catch {
        @compileError("worker storage slab byte count overflows usize");
    };
}
