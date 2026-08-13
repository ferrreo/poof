const upload_io = @import("../../../upload_io.zig");
const reactor = @import("../reactor.zig");

pub const Terminal = union(enum) {
    completion: upload_io.IoCompletion,
    fatal,
};

pub fn normalizePlain(result: reactor.CompletionResult) Terminal {
    return switch (result) {
        .failure => |failure| normalizeFailure(failure),
        .success => |success| .{ .completion = .{ .success = switch (success) {
            .file_write => |written| .{ .write = written },
            .file_link => .{ .link = {} },
            .file_unlink => .{ .unlink = {} },
            .file_rename_no_replace => .{ .rename_no_replace = {} },
            .file_sync => .{ .sync = {} },
            else => unreachable,
        } } },
    };
}

pub fn normalizeFailure(failure: reactor.CompletionError) Terminal {
    const mapped: upload_io.IoError = switch (failure) {
        .canceled => .canceled,
        .already_exists => .already_exists,
        .not_found => .not_found,
        .invalid_path => .invalid_path,
        .cross_device => .cross_device,
        .read_only => .read_only,
        .quota_exceeded => .quota_exceeded,
        .file_too_large => .file_too_large,
        .no_space => .no_space,
        .unsupported => .unsupported,
        .io_failure => .io_failure,
        .permission_denied => .permission_denied,
        .resource_exhausted => .resource_exhausted,
        .invalid_resource,
        .transient_accept,
        .connection_aborted,
        .connection_reset,
        .broken_pipe,
        .not_connected,
        .buffer_exhausted,
        .backend_failure,
        => return .fatal,
    };
    return .{ .completion = .{ .failure = mapped } };
}

test {
    @import("std").testing.refAllDecls(@This());
}
