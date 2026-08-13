const std = @import("std");
const connection_send = @import("send.zig");
const reactor = @import("../reactor.zig");

pub fn assertRecord(storage: anytype, connection_index: u16) void {
    std.debug.assert(connection_index < storage.connections.len);
    const connection = &storage.connections[connection_index];
    const pipeline = storage.pipeline(connection_index);
    std.debug.assert(connection.pipeline_read <= connection.pipeline_write);
    std.debug.assert(connection.pipeline_write <= pipeline.len);
    std.debug.assert(connection.pipeline_high_water <= pipeline.len);
    std.debug.assert(
        connection.decoded_path_used <= @TypeOf(storage.*).decoded_path_bytes_per_connection,
    );

    const owned_operations = @as(u16, @intFromBool(connection.receive_token != null)) +
        @as(u16, @intFromBool(connection.send_token != null)) +
        @as(u16, @intFromBool(connection.timeout_token != null)) +
        @as(u16, @intFromBool(connection.close_token != null));
    std.debug.assert(connection.inflight_operations >= owned_operations);
    std.debug.assert(connection.inflight_operations <= reactor.connection_operation_capacity);
    if (connection.receive_token == null) std.debug.assert(!connection.receive_flags.multishot);
    if (connection.receive_flags.paused and !connection.receive_flags.upload_paused) {
        std.debug.assert(connection.receive_token == null);
    }
    if (connection.receive_flags.upload_paused) {
        std.debug.assert(connection.receive_flags.paused);
        std.debug.assert(!connection.receive_flags.multishot);
        std.debug.assert(connection.phase == .receiving_body or connection.phase == .closing);
    }
    if (connection.receive_flags.gzip_paused) {
        std.debug.assert(connection.receive_token == null);
        std.debug.assert(connection.phase == .receiving_body);
    }
    if (connection.receive_flags.gzip_rejecting) {
        std.debug.assert(!connection.receive_flags.multishot);
        std.debug.assert(!connection.receive_flags.paused);
        std.debug.assert(!connection.receive_flags.gzip_paused);
        std.debug.assert(connection.phase == .receiving_body);
    }
    if (connection.socket_closed) std.debug.assert(connection.close_token == null);
    if (connection.phase == .closing) std.debug.assert(connection.close_after_response);
    if (connection.proxy_protocol.pending()) {
        std.debug.assert(connection.phase == .first_head);
        std.debug.assert(connection.connection_source == .transport);
        std.debug.assert(connection.connection_peer.eql(connection.transport_peer));
        std.debug.assert(connection.proxy_destination == null);
    }
    std.debug.assert(connection.continue_cursor <= connection_send.continue_response.len);
    if (connection.continue_cursor != 0) {
        std.debug.assert(connection.send_token != null);
    }

    if (connection.active_request) |request_index| {
        std.debug.assert(request_index < storage.requests.len);
        std.debug.assert(storage.requests[request_index].phase == .live);
    }
    if (connection.receive_flags.response_fallback) {
        std.debug.assert(connection.active_request != null);
        std.debug.assert(connection.continue_cursor == 0);
        std.debug.assert(connection.phase == .responding or connection.phase == .closing);
    }
    if (connection.phase == .receiving_body) {
        std.debug.assert(connection.active_request != null);
    }
    if (connection.phase == .free) {
        std.debug.assert(owned_operations == 0);
        std.debug.assert(connection.inflight_operations == 0);
        std.debug.assert(connection.active_request == null);
        std.debug.assert(!connection.receive_flags.response_fallback);
        std.debug.assert(connection.continue_cursor == 0);
        std.debug.assert(!connection.receive_flags.gzip_rejecting);
    }
}

pub fn headTimeoutResponseSafe(connection: anytype) bool {
    return (connection.phase == .first_head or connection.phase == .reused_head) and
        connection.active_request == null and
        connection.send_token == null and
        connection.close_token == null and
        !connection.close_after_response;
}
