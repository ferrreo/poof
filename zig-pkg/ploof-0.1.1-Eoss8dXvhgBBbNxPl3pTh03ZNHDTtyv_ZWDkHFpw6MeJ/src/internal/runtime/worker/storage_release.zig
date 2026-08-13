const std = @import("std");
const reactor = @import("../reactor.zig");
const worker_chunked_pool = @import("chunked_pool.zig");
const worker_response_storage = @import("response_storage.zig");

pub const ConnectionReleaseIssue = enum(u8) {
    index_out_of_range,
    not_live,
    request_still_active,
    decoded_path_not_released,
    invalid_pipeline_cursors,
    not_closing,
    receive_active,
    send_active,
    timeout_active,
    close_active,
    operations_inflight,
    receive_terminal_not_reaped,
    socket_not_closed,
};

pub const RequestReleaseIssue = enum(u8) {
    connection_index_out_of_range,
    request_index_out_of_range,
    connection_not_live,
    request_not_live,
    wrong_connection,
    connection_owns_other_request,
    decoded_path_out_of_range,
    response_range_out_of_range,
    response_workspace_not_leased,
    response_workspace_not_dirty,
    body_workspace_out_of_range,
    body_metadata_without_workspace,
    body_range_out_of_range,
    chunked_workspace_out_of_range,
    gzip_decoder_active,
    stream_not_finished,
    metrics_active,
    upload_active,
};

pub fn Actions(
    comptime body_enabled: bool,
    comptime BodyHelpers: type,
    comptime ChunkedState: type,
) type {
    const enabled = body_enabled;
    const Helpers = BodyHelpers;
    const State = ChunkedState;
    return struct {
        pub fn request(storage: anytype, connection_index: u16, request_index: u16) void {
            if (storage.requestReleaseIssue(connection_index, request_index) != null) {
                @panic("worker request release invariant");
            }
            const live_connection = &storage.connections[connection_index];
            const live_request = &storage.requests[request_index];
            std.crypto.secureZero(
                u8,
                storage.decodedPath(connection_index)[0..live_connection.decoded_path_used],
            );
            storage.clearResponse(request_index);
            if (comptime enabled) {
                if (live_request.body.workspace_index) |body_index| {
                    Helpers.clearReleased(storage, live_request, body_index);
                }
                if (live_request.chunked_workspace_index) |chunked_index| {
                    worker_chunked_pool.clear(
                        State,
                        &storage.chunked_workspaces,
                        chunked_index,
                    );
                    storage.chunked_workspaces.pool.release(chunked_index);
                }
            }
            std.crypto.secureZero(u8, std.mem.asBytes(&live_request.workspace));
            resetHead(live_connection);
            const next_generation = reactor.nextGeneration(live_request.generation);
            live_request.* = .{ .generation = next_generation };
            live_connection.active_request = null;
            live_connection.decoded_path_used = 0;
            storage.request_pool.release(request_index);
        }

        pub fn connection(storage: anytype, connection_index: u16) void {
            if (storage.connectionReleaseIssue(connection_index) != null) {
                @panic("worker connection release invariant");
            }
            const live_connection = &storage.connections[connection_index];
            const used_head = @constCast(live_connection.head_decoder.bytes());
            std.crypto.secureZero(
                u8,
                storage.pipeline(connection_index)[0..live_connection.pipeline_high_water],
            );
            const next_generation = reactor.nextGeneration(live_connection.generation);
            live_connection.* = .{ .generation = next_generation };
            std.crypto.secureZero(u8, used_head);
            storage.connection_pool.release(connection_index);
        }

        pub fn resetHead(connection_record: anytype) void {
            connection_record.head_decoder.reset();
            connection_record.receive_flags.close_outcome = 0;
            connection_record.receive_flags.response_fallback = false;
        }
    };
}

pub fn connectionIssue(
    comptime Issue: type,
    storage: anytype,
    connection_index: u16,
    comptime pipeline_bytes: u32,
) ?Issue {
    if (connection_index >= storage.connections.len) return .index_out_of_range;
    const connection = &storage.connections[connection_index];
    if (connection.phase == .free) return .not_live;
    if (connection.active_request != null or connection.receive_flags.response_fallback) {
        return .request_still_active;
    }
    if (connection.decoded_path_used != 0) return .decoded_path_not_released;
    if (connection.pipeline_read > connection.pipeline_write or
        connection.pipeline_write > connection.pipeline_high_water or
        connection.pipeline_high_water > pipeline_bytes)
    {
        return .invalid_pipeline_cursors;
    }
    if (connection.phase != .closing) return .not_closing;
    if (connection.receive_token != null) return .receive_active;
    if (connection.send_token != null) return .send_active;
    if (connection.timeout_token != null) return .timeout_active;
    if (connection.close_token != null) return .close_active;
    if (connection.inflight_operations != 0) return .operations_inflight;
    if (!connection.receive_terminal_reaped) return .receive_terminal_not_reaped;
    if (!connection.socket_closed) return .socket_not_closed;
    return null;
}

pub fn requestIssue(
    comptime Issue: type,
    storage: anytype,
    connection_index: u16,
    request_index: u16,
    comptime settings: anytype,
) ?Issue {
    if (connection_index >= storage.connections.len) {
        return .connection_index_out_of_range;
    }
    if (request_index >= storage.requests.len) return .request_index_out_of_range;
    const connection = &storage.connections[connection_index];
    const request = &storage.requests[request_index];
    if (connection.phase == .free) return .connection_not_live;
    if (request.phase != .live) return .request_not_live;
    if (request.connection_index != connection_index) return .wrong_connection;
    if (connection.active_request != request_index) return .connection_owns_other_request;
    if (request.flags.upload_inflight or request.flags.upload_parser_paused or
        request.flags.upload_finalizing or request.flags.upload_cancel_requested or
        request.flags.upload_rejection_pending)
    {
        return .upload_active;
    }
    if (comptime @hasField(@TypeOf(request.*), "live_static_slot") and
        @FieldType(@TypeOf(request.*), "live_static_slot") == ?u16)
    {
        if (request.live_static_slot != null) return .upload_active;
    }
    if (comptime settings.body_enabled) {
        if (request.body.terminal_response_pending) return .upload_active;
    }
    if (comptime @TypeOf(request.gzip_lease) != void) {
        if (request.gzip_lease != null) return .gzip_decoder_active;
    }
    if (comptime settings.stream_enabled) {
        if (request.stream_transport.poll_ready or
            request.stream_transport.full_clear_required or
            request.stream_transport.timeout_cancel_target_sequence != 0 or
            request.stream_transport.timeout_cancel_operation_sequence != 0 or
            request.stream_transport.cancel_outcome != null or
            (request.stream_transport.active and
                request.stream_transport.state.phase() != .finished))
        {
            return .stream_not_finished;
        }
    }
    if (comptime settings.metrics_enabled) {
        if (request.metrics.phase != .idle) return .metrics_active;
    }
    if (connection.decoded_path_used > settings.decoded_path_bytes) {
        return .decoded_path_out_of_range;
    }
    if (responseIssue(Issue, storage, request_index, settings)) |issue| return issue;
    if (settings.body_enabled) {
        if (request.body.workspace_index) |body_index| {
            if (body_index >= settings.body_slots) return .body_workspace_out_of_range;
            if (request.body.used > settings.body_bytes) return .body_range_out_of_range;
        } else if (request.body.used != 0 or
            request.body.dirty_full or
            request.body.tainted_full)
        {
            return .body_metadata_without_workspace;
        }
    }
    if (request.chunked_workspace_index) |chunked_index| {
        if (!settings.body_enabled or chunked_index >= settings.chunked_slots) {
            return .chunked_workspace_out_of_range;
        }
    }
    return null;
}

fn responseIssue(
    comptime Issue: type,
    storage: anytype,
    request_index: u16,
    comptime settings: anytype,
) ?Issue {
    const request = &storage.requests[request_index];
    if (request.response_sent > request.response_used or
        request.response_high_water > settings.response_internal_bytes)
    {
        return .response_range_out_of_range;
    }
    return switch (worker_response_storage.source(request)) {
        .internal => internalResponseIssue(Issue, request, settings),
        .body_workspace => externalResponseIssue(Issue, request, settings),
        .chunks => if (storage.responseChunkStateValid(request_index))
            null
        else
            .response_range_out_of_range,
        .static => staticResponseIssue(Issue, request, settings),
    };
}

fn staticResponseIssue(
    comptime Issue: type,
    request: anytype,
    comptime settings: anytype,
) ?Issue {
    if (request.response_static_body == null or
        request.response_used < request.response_high_water or
        request.response_high_water > settings.response_internal_bytes)
    {
        return .response_range_out_of_range;
    }
    return null;
}

fn internalResponseIssue(
    comptime Issue: type,
    request: anytype,
    comptime settings: anytype,
) ?Issue {
    if (request.response_used > settings.response_internal_bytes or
        (!request.flags.response_dirty_full and
            request.response_used > request.response_high_water))
    {
        return .response_range_out_of_range;
    }
    return null;
}

fn externalResponseIssue(
    comptime Issue: type,
    request: anytype,
    comptime settings: anytype,
) ?Issue {
    if (!settings.body_enabled or request.response_used == 0) {
        return .response_range_out_of_range;
    }
    const workspace_index = request.body.workspace_index orelse {
        return .response_workspace_not_leased;
    };
    if (workspace_index >= settings.body_slots) {
        return .response_workspace_not_leased;
    }
    const offset: u64 = request.body.response_source_offset - 1;
    const length: u64 = request.response_used;
    if (offset + length > settings.response_external_bytes) {
        return .response_range_out_of_range;
    }
    if (!request.body.dirty_full and !request.body.tainted_full) {
        return .response_workspace_not_dirty;
    }
    return null;
}
