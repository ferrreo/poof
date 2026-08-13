const application = @import("../../../application.zig");
const reactor = @import("../reactor.zig");

pub fn outcome(problem: reactor.CompletionError) application.TransportOutcome {
    return switch (problem) {
        .connection_aborted,
        .connection_reset,
        .broken_pipe,
        .not_connected,
        => .peer_aborted,
        .canceled => .framework_canceled,
        .transient_accept,
        .already_exists,
        .not_found,
        .invalid_path,
        .cross_device,
        .read_only,
        .quota_exceeded,
        .file_too_large,
        .no_space,
        .unsupported,
        .io_failure,
        .permission_denied,
        .resource_exhausted,
        .buffer_exhausted,
        .invalid_resource,
        .backend_failure,
        => .aborted,
    };
}
