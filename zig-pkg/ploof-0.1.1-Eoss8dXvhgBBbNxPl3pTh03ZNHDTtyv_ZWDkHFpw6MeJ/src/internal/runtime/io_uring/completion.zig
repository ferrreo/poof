const std = @import("std");
const linux = std.os.linux;

const reactor = @import("../reactor.zig");

pub fn normalizedNegative(
    kind: reactor.OperationKind,
    errno_value: linux.E,
) reactor.CompletionResult {
    if (kind == .timeout and errno_value == .TIME) {
        return .{ .success = .{ .timeout = {} } };
    }
    if (kind == .cancel or kind == .upload_cancel or kind == .file_cancel) {
        if (errno_value == .ALREADY) return cancelResult(kind, .canceled);
        if (errno_value == .NOENT) return cancelResult(kind, .not_found);
    }
    if (reactor.isFileOperation(kind)) {
        return .{ .failure = fileFailure(errno_value) };
    }
    return .{ .failure = completionFailure(kind, errno_value) };
}

fn cancelResult(
    kind: reactor.OperationKind,
    result: reactor.CancelResult,
) reactor.CompletionResult {
    return .{ .success = switch (kind) {
        .cancel => .{ .cancel = result },
        .upload_cancel => .{ .upload_cancel = result },
        .file_cancel => .{ .file_cancel = result },
        else => unreachable,
    } };
}

fn fileFailure(errno_value: linux.E) reactor.CompletionError {
    return switch (errno_value) {
        .CANCELED => .canceled,
        .EXIST => .already_exists,
        .NOENT => .not_found,
        .ISDIR, .LOOP, .NAMETOOLONG, .NOTDIR => .invalid_path,
        .XDEV => .cross_device,
        .ROFS => .read_only,
        .DQUOT => .quota_exceeded,
        .FBIG => .file_too_large,
        .NOSPC => .no_space,
        .OPNOTSUPP, .NOSYS => .unsupported,
        .ACCES, .PERM => .permission_denied,
        .NOMEM, .MFILE, .NFILE => .resource_exhausted,
        .BADF, .FAULT, .NXIO, .NODEV => .invalid_resource,
        else => .io_failure,
    };
}

fn completionFailure(
    kind: reactor.OperationKind,
    errno_value: linux.E,
) reactor.CompletionError {
    if (kind == .accept and transientAcceptError(errno_value)) return .transient_accept;
    return switch (errno_value) {
        .CANCELED => .canceled,
        .CONNABORTED => .connection_aborted,
        .CONNRESET => .connection_reset,
        .PIPE => .broken_pipe,
        .NOTCONN => .not_connected,
        .ACCES, .PERM => .permission_denied,
        .NOBUFS => if (kind == .receive) .buffer_exhausted else .resource_exhausted,
        .NOMEM, .MFILE, .NFILE, .NOSPC => .resource_exhausted,
        .BADF, .INVAL, .FAULT => .invalid_resource,
        else => .backend_failure,
    };
}

fn transientAcceptError(errno_value: linux.E) bool {
    return switch (errno_value) {
        .AGAIN,
        .CONNABORTED,
        .NETDOWN,
        .PROTO,
        .NOPROTOOPT,
        .HOSTDOWN,
        .NONET,
        .HOSTUNREACH,
        .OPNOTSUPP,
        .NETUNREACH,
        .NOSR,
        .SOCKTNOSUPPORT,
        .PROTONOSUPPORT,
        .TIMEDOUT,
        => true,
        else => false,
    };
}

test "negative completion mapping preserves timeout cancel and network semantics" {
    try std.testing.expectEqualDeep(
        reactor.CompletionResult{ .success = .{ .timeout = {} } },
        normalizedNegative(.timeout, .TIME),
    );
    try std.testing.expectEqualDeep(
        reactor.CompletionResult{ .success = .{ .cancel = .canceled } },
        normalizedNegative(.cancel, .ALREADY),
    );
    try std.testing.expectEqualDeep(
        reactor.CompletionResult{ .success = .{ .cancel = .not_found } },
        normalizedNegative(.cancel, .NOENT),
    );
    try std.testing.expectEqualDeep(
        reactor.CompletionResult{ .success = .{ .upload_cancel = .not_found } },
        normalizedNegative(.upload_cancel, .NOENT),
    );
    try std.testing.expectEqualDeep(
        reactor.CompletionResult{ .failure = .buffer_exhausted },
        normalizedNegative(.receive, .NOBUFS),
    );
    try std.testing.expectEqualDeep(
        reactor.CompletionResult{ .failure = .resource_exhausted },
        normalizedNegative(.accept, .NOBUFS),
    );
    try std.testing.expectEqualDeep(
        reactor.CompletionResult{ .failure = .transient_accept },
        normalizedNegative(.accept, .CONNABORTED),
    );
    try std.testing.expectEqualDeep(
        reactor.CompletionResult{ .failure = .permission_denied },
        normalizedNegative(.accept, .PERM),
    );
    try std.testing.expectEqualDeep(
        reactor.CompletionResult{ .failure = .connection_reset },
        normalizedNegative(.receive, .CONNRESET),
    );
    try std.testing.expectEqualDeep(
        reactor.CompletionResult{ .failure = .canceled },
        normalizedNegative(.wake, .CANCELED),
    );
    try std.testing.expectEqualDeep(
        reactor.CompletionResult{ .failure = .invalid_resource },
        normalizedNegative(.wake, .BADF),
    );
}

test "negative file completions preserve bounded upload errors" {
    const Case = struct {
        errno_value: linux.E,
        failure: reactor.CompletionError,
    };
    const cases = [_]Case{
        .{ .errno_value = .CANCELED, .failure = .canceled },
        .{ .errno_value = .EXIST, .failure = .already_exists },
        .{ .errno_value = .NOENT, .failure = .not_found },
        .{ .errno_value = .NOTDIR, .failure = .invalid_path },
        .{ .errno_value = .XDEV, .failure = .cross_device },
        .{ .errno_value = .ROFS, .failure = .read_only },
        .{ .errno_value = .DQUOT, .failure = .quota_exceeded },
        .{ .errno_value = .FBIG, .failure = .file_too_large },
        .{ .errno_value = .NOSPC, .failure = .no_space },
        .{ .errno_value = .OPNOTSUPP, .failure = .unsupported },
        .{ .errno_value = .PERM, .failure = .permission_denied },
        .{ .errno_value = .NFILE, .failure = .resource_exhausted },
        .{ .errno_value = .BADF, .failure = .invalid_resource },
        .{ .errno_value = .IO, .failure = .io_failure },
    };
    for (cases) |case| {
        try std.testing.expectEqualDeep(
            reactor.CompletionResult{ .failure = case.failure },
            normalizedNegative(.file_open, case.errno_value),
        );
    }
}
