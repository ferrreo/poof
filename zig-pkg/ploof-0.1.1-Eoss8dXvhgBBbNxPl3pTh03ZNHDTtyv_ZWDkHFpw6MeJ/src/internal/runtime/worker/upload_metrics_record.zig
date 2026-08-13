const application_types = @import("../../application/types.zig");
const finalization = @import("../../application/multipart_finalization.zig");

pub const Error = error{ ApplicationFailure, StateInvariant };

pub fn terminal(workspace: anytype) bool {
    return application_types.multipartFinalizationTerminal(workspace);
}

pub fn recordReport(
    comptime App: type,
    metrics: anytype,
    workspace: anytype,
    request_workspace: []u8,
    report: finalization.Report,
) Error!void {
    if (comptime !@hasDecl(App, "__multipartFinalizationCleanupFailure")) {
        if (report.cleanup_failure_count != 0) return error.StateInvariant;
        metrics.recordFinalization(report);
        return;
    }
    if (comptime App.upload_finalization_instances_max == 0) {
        if (report.instance_count != 0 or report.cleanup_failure_count != 0) {
            return error.StateInvariant;
        }
        metrics.recordFinalization(report);
        return;
    }
    if (report.instance_count > App.upload_finalization_instances_max) {
        return error.StateInvariant;
    }
    var count: usize = 0;
    for (0..report.instance_count) |index| {
        const failure = App.__multipartFinalizationCleanupFailure(
            workspace,
            request_workspace,
            @intCast(index),
        ) catch return error.ApplicationFailure;
        if (failure != null) count += 1;
    }
    if (count != report.cleanup_failure_count) return error.StateInvariant;
    metrics.recordFinalization(report);
    for (0..report.instance_count) |index| {
        const failure = App.__multipartFinalizationCleanupFailure(
            workspace,
            request_workspace,
            @intCast(index),
        ) catch unreachable;
        if (failure) |value| metrics.recordFinalizationCleanup(value);
    }
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}
