const response = @import("../../response.zig");
const application_body = @import("body.zig");
const application_response_output = @import("response_output.zig");

pub const TransportOutcome = enum(u8) {
    completed,
    head_suppressed,
    exact_overrun,
    exact_underrun,
    producer_failed,
    write_stalled,
    peer_aborted,
    framework_canceled,
    aborted,
};

pub const Outcome = struct {
    status: ?response.Status,
    mapped_error: bool,
    transport: TransportOutcome,
};

pub const LifecycleError = error{
    RequestAlreadyPending,
    NoPendingRequest,
    NoPendingBody,
    NoPendingMetrics,
    StreamNotJoined,
    UploadFinalizationPending,
    UploadFinalizationFailed,
};

pub const MultipartFinalization = enum(u8) {
    not_required,
    required,
    active,
    committed,
    aborted,
    failed,
};

pub const Lifecycle = enum(u8) {
    idle,
    preparing,
    awaiting_body,
    awaiting_static,
    awaiting_metrics,
    pending,
    finishing,
};

pub fn multipartCleanupPending(workspace: anytype) bool {
    if (comptime !hasMultipartFinalization(@TypeOf(workspace.*))) return false;
    return switch (workspace.multipart_finalization) {
        .required, .active => true,
        .not_required, .committed, .aborted, .failed => false,
    };
}

pub fn requireMultipartComplete(workspace: anytype) LifecycleError!void {
    if (comptime !hasMultipartFinalization(@TypeOf(workspace.*))) return;
    return switch (workspace.multipart_finalization) {
        .required, .active => error.UploadFinalizationPending,
        .failed => error.UploadFinalizationFailed,
        .not_required, .committed, .aborted => {},
    };
}

pub fn requireMultipartAbort(workspace: anytype) LifecycleError!void {
    if (comptime !hasMultipartFinalization(@TypeOf(workspace.*))) return;
    return switch (workspace.multipart_finalization) {
        .required, .active => error.UploadFinalizationPending,
        .not_required, .committed, .aborted, .failed => {},
    };
}

pub fn multipartFinalizationTerminal(workspace: anytype) bool {
    if (comptime !hasMultipartFinalization(@TypeOf(workspace.*))) return false;
    return switch (workspace.multipart_finalization) {
        .committed, .aborted, .failed => true,
        .not_required, .required, .active => false,
    };
}

pub fn hasMultipartFinalization(comptime Workspace: type) bool {
    if (!@hasField(Workspace, "multipart_finalization")) return false;
    return @FieldType(Workspace, "multipart_finalization") == MultipartFinalization;
}

pub const PendingRoute = union(enum) {
    generated,
    asset,
    selected: u16,
};

pub const PendingTransmission = enum(u8) {
    finite,
    stream,
};

pub const Pending = struct {
    route: PendingRoute,
    status: response.Status,
    mapped_error: bool,
    success_transport: TransportOutcome,
    transmission: PendingTransmission = .finite,
};

pub fn PendingFor(comptime stream_enabled: bool) type {
    if (stream_enabled) return Pending;
    return struct {
        route: PendingRoute,
        status: response.Status,
        mapped_error: bool,
        success_transport: TransportOutcome,
    };
}

pub const CodingOutcome = application_response_output.CodingOutcome;
pub const Prepared = application_response_output.Prepared;
pub const BodyPlan = application_body.Plan;

pub const HeadResult = union(enum) {
    prepared: Prepared,
    receive_body: BodyPlan,
};
pub const DeferredMetrics = struct { route_id: u16 };
pub const MetricsResult = union(enum) {
    success: []const u8,
    unavailable,
};

pub fn HeadResultFor(comptime metrics_enabled: bool) type {
    if (!metrics_enabled) return HeadResult;
    return union(enum) {
        prepared: Prepared,
        receive_body: BodyPlan,
        deferred_metrics: DeferredMetrics,
    };
}
pub const LiveStaticPath = application_response_output.LiveStaticPath;
pub const LiveStaticIntent = application_response_output.LiveStaticIntent;
pub const LiveStaticFile = application_response_output.LiveStaticFile;

pub const HeadPolicy = struct {
    close_if_prepared: bool = false,
};

pub const ServeResult = struct {
    bytes: []const u8,
    status: response.Status,
    transport: TransportOutcome,
};

pub fn streamJoined(comptime enabled: bool, workspace: anytype) bool {
    if (comptime !enabled) return true;
    if (workspace.pending.transmission != .stream) return true;
    return workspace.stream.phase() == .joined;
}

pub fn isStream(prepared: Prepared) bool {
    return switch (prepared.transmission) {
        .finite => false,
        .stream => true,
    };
}

pub fn serveResult(prepared: Prepared, outcome: Outcome) ServeResult {
    return .{
        .bytes = switch (prepared.source) {
            .contiguous_wire => |bytes| bytes,
            .finite_chain => unreachable,
            .borrowed_static => |borrowed| if (borrowed.body.len == 0)
                borrowed.head
            else
                unreachable,
            .live_static => unreachable,
            .live_static_file => unreachable,
        },
        .status = prepared.status,
        .transport = outcome.transport,
    };
}

pub fn settleStreamForAbort(comptime enabled: bool, workspace: anytype) void {
    if (comptime !enabled) return;
    if (workspace.pending.transmission != .stream) return;
    switch (workspace.stream.phase()) {
        .polling, .canary, .failed => {
            workspace.stream.abort() catch unreachable;
            workspace.stream.join() catch unreachable;
        },
        .done, .aborted => workspace.stream.join() catch unreachable,
        .joined => {},
    }
}
