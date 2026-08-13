const std = @import("std");
const application_runtime = @import("runtime.zig");
const application_types = @import("types.zig");
const response = @import("../../response.zig");

pub fn initializedMask(comptime count: usize) u64 {
    return if (count == 64) std.math.maxInt(u64) else (@as(u64, 1) << count) - 1;
}

pub fn initializeMiddleware(comptime item: anytype, state: anytype) void {
    const State = @TypeOf(item).State;
    if (State == void) {
        state.* = {};
    } else {
        state.* = item.init();
    }
}

pub fn mapError(
    comptime mapper: anytype,
    context: anytype,
    problem: anytype,
) @TypeOf(context.empty(.internal_server_error)) {
    if (mapper) |map| return map(context, problem);
    return context.empty(.internal_server_error);
}

pub fn multipartHandler(comptime Handler: type) bool {
    return @typeInfo(Handler) == .@"struct" and
        @hasDecl(Handler, "ploof_multipart_endpoint") and
        Handler.ploof_multipart_endpoint;
}

pub fn multipartFinalizationEnabled(comptime Workspace: type) bool {
    if (!@hasField(Workspace, "multipart_abort_cause")) return false;
    return @typeInfo(@FieldType(Workspace, "multipart_abort_cause")) == .optional;
}

pub fn deferMultipartSerializationFailure(workspace: anytype, mapped_error: bool) bool {
    if (comptime !multipartFinalizationEnabled(@TypeOf(workspace.*))) return false;
    workspace.multipart_commit = false;
    workspace.multipart_abort_cause = .response_preparation;
    if (!application_types.multipartCleanupPending(workspace)) return false;
    workspace.multipart_abort_mapped_error = mapped_error;
    return true;
}

pub fn streamResponseValid(
    context: anytype,
    value: anytype,
    comptime selected_limits: response.HeadLimits,
) bool {
    if (value.headers != &context.response_workspace.headers) return false;
    if (!application_runtime.headLimitsEqual(
        value.selectedLimits(),
        selected_limits,
    )) return false;
    value.validate() catch return false;
    return true;
}

pub fn ensureOwnedResponse(
    context: anytype,
    value: anytype,
    comptime selected_limits: response.HeadLimits,
    mapped_error: *bool,
) void {
    if (value.headers != &context.response_workspace.headers or
        !application_runtime.headLimitsEqual(value.selectedLimits(), selected_limits))
    {
        context.response_workspace.reset(selected_limits);
        value.* = context.empty(.internal_server_error);
        mapped_error.* = true;
        return;
    }
    value.validate() catch {
        context.response_workspace.reset(selected_limits);
        value.* = context.empty(.internal_server_error);
        mapped_error.* = true;
    };
}

pub fn abandonStream(workspace: anytype, value: anytype) void {
    workspace.stream.init(value.stream);
    abortAndJoinStream(workspace);
}

pub fn abortAndJoinStream(workspace: anytype) void {
    workspace.stream.abort() catch unreachable;
    workspace.stream.join() catch unreachable;
}

test {
    std.testing.refAllDecls(@This());
}
