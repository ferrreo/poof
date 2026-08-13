const application = @import("../../../application.zig");
const connection_stream_transport = @import("../connection/stream_transport.zig");

pub const ReceiveFlags = packed struct(u16) {
    multishot: bool = false,
    paused: bool = false,
    upload_paused: bool = false,
    gzip_paused: bool = false,
    gzip_rejecting: bool = false,
    response_fallback: bool = false,
    close_outcome: u4 = 0,
    send_budget: u5 = 0,
    timeout_extended: bool = false,
};

pub const RequestFlags = packed struct(u8) {
    response_dirty_full: bool = false,
    upload_inflight: bool = false,
    upload_parser_paused: bool = false,
    upload_finalizing: bool = false,
    upload_response_failed: bool = false,
    upload_cancel_requested: bool = false,
    upload_cancel_peer: bool = false,
    upload_rejection_pending: bool = false,
};

pub fn StreamTransport(comptime App: type, comptime enabled: bool) type {
    if (!enabled) return struct {};
    return struct {
        state: connection_stream_transport.State(App) = undefined,
        active: bool = false,
        poll_ready: bool = false,
        full_clear_required: bool = false,
        timeout_cancel_target_sequence: u16 = 0,
        timeout_cancel_operation_sequence: u16 = 0,
        cancel_outcome: ?application.TransportOutcome = null,
    };
}
