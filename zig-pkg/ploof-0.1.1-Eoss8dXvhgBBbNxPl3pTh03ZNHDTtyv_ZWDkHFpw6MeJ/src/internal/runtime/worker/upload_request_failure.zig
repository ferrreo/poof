const request_cancel = @import("upload_request_cancel.zig");
const observe = @import("upload_request_observe.zig");

pub fn afterAbortRequested(
    comptime Error: type,
    comptime Event: type,
    controller: anytype,
    transport: anytype,
    metrics: anytype,
    worker_index: u16,
    storage: anytype,
    io: anytype,
    request_index: u16,
    request: anytype,
    state: anytype,
    now_ns: u64,
    failure_identity: anytype,
) Error!Event {
    observe.clearWindowFull(state);
    try request_cancel.cancelApplicationTargets(
        Error,
        transport,
        metrics,
        worker_index,
        io,
        request,
        state,
        failure_identity,
    );
    if (state.active != 0) return .none;
    if (request.flags.upload_rejection_pending and !request.flags.upload_finalizing and
        !request.flags.upload_parser_paused) return .none;
    return controller.startAbort(
        transport,
        metrics,
        worker_index,
        storage,
        io,
        request_index,
        request,
        state,
        now_ns,
    );
}

pub const RejectionStatus = enum(u8) {
    bad_request,
    payload_too_large,
    unsupported_media_type,
};

pub fn parserStatus(problem: anytype) !RejectionStatus {
    if (problem == error.InvalidMultipart or problem == error.InvalidField) {
        return .bad_request;
    }
    if (problem == error.LimitExceeded) return .payload_too_large;
    if (problem == error.UnsupportedMedia) return .unsupported_media_type;
    return error.StateInvariant;
}

pub fn parserEvent(
    comptime Event: type,
    request: anytype,
    request_index: u16,
    problem: anytype,
) !Event {
    request.flags.upload_parser_paused = false;
    return .{ .request_rejected = .{
        .connection_index = request.connection_index,
        .request_index = request_index,
        .status = try parserStatus(problem),
    } };
}

pub fn selectedEvent(
    comptime Event: type,
    request: anytype,
    request_index: u16,
) Event {
    request.flags.upload_parser_paused = false;
    return .{ .request_resumed = .{
        .connection_index = request.connection_index,
        .request_index = request_index,
        .progress = .{ .consumed = 0, .flow = .ready },
    } };
}

pub fn nonSink(
    comptime Error: type,
    comptime RequestCleanup: type,
    comptime Event: type,
    source: anytype,
    problem: anytype,
    transport: anytype,
    metrics: anytype,
    worker_index: u16,
    io: anytype,
    request_index: u16,
    request: anytype,
    state: anytype,
    now_ns: u64,
    failure_identity: anytype,
) Error!?Event {
    return switch (source) {
        .parser => parser: {
            state.abort_cause = .body;
            request.flags.upload_cancel_requested = true;
            try request_cancel.cancelApplicationTargets(
                Error,
                transport,
                metrics,
                worker_index,
                io,
                request,
                state,
                failure_identity,
            );
            break :parser try parserEvent(Event, request, request_index, problem);
        },
        .application, .rejection => selectedEvent(Event, request, request_index),
        .fatal => try fatal(
            Error,
            RequestCleanup,
            Event,
            transport,
            metrics,
            worker_index,
            io,
            request_index,
            request,
            state,
            now_ns,
            failure_identity,
        ),
        .none => error.StateInvariant,
        .sink => null,
    };
}

pub fn fatal(
    comptime Error: type,
    comptime RequestCleanup: type,
    comptime Event: type,
    transport: anytype,
    metrics: anytype,
    worker_index: u16,
    io: anytype,
    request_index: u16,
    request: anytype,
    state: anytype,
    now_ns: u64,
    failure_identity: anytype,
) Error!Event {
    state.failure = .fatal;
    request.flags.upload_cancel_requested = true;
    try request_cancel.cancelApplicationTargets(
        Error,
        transport,
        metrics,
        worker_index,
        io,
        request,
        state,
        failure_identity,
    );
    return RequestCleanup.continueFatal(
        transport,
        worker_index,
        io,
        request_index,
        request,
        state,
        now_ns,
        failure_identity,
    );
}

test {
    const std = @import("std");
    try std.testing.expectEqual(
        RejectionStatus.bad_request,
        try parserStatus(error.InvalidMultipart),
    );
    try std.testing.expectEqual(
        RejectionStatus.bad_request,
        try parserStatus(error.InvalidField),
    );
    try std.testing.expectEqual(
        RejectionStatus.payload_too_large,
        try parserStatus(error.LimitExceeded),
    );
    try std.testing.expectEqual(
        RejectionStatus.unsupported_media_type,
        try parserStatus(error.UnsupportedMedia),
    );
    try std.testing.expectError(error.StateInvariant, parserStatus(error.Broken));
    std.testing.refAllDecls(@This());
}
