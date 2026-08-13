const std = @import("std");
const application_lifecycle = @import("lifecycle.zig");
const application_types = @import("types.zig");

pub fn abortInitialized(
    comptime middleware: anytype,
    workspace: anytype,
    status: anytype,
    comptime Outcome: type,
) void {
    if (comptime application_types.hasMultipartFinalization(@TypeOf(workspace.*))) {
        if (application_types.multipartCleanupPending(workspace)) {
            workspace.multipart_commit = false;
            if (workspace.multipart_abort_cause == null) {
                workspace.multipart_abort_cause = .verification;
            }
            workspace.multipart_abort_mapped_error = false;
            return;
        }
    }
    const outcome = Outcome{
        .status = status,
        .mapped_error = false,
        .transport = .aborted,
    };
    application_lifecycle.runAfter(middleware, workspace, outcome);
    workspace.lifecycle = .idle;
}

pub fn abortAwaitingBody(
    comptime routes: anytype,
    comptime middleware: anytype,
    workspace: anytype,
    transport: anytype,
    comptime Outcome: type,
) Outcome {
    return abortSelected(
        routes,
        middleware,
        workspace,
        false,
        transport,
        Outcome,
    );
}

pub fn abortAwaitingStatic(
    comptime routes: anytype,
    comptime middleware: anytype,
    workspace: anytype,
    transport: anytype,
    comptime Outcome: type,
) Outcome {
    const outcome = Outcome{
        .status = null,
        .mapped_error = false,
        .transport = transport,
    };
    workspace.lifecycle = .finishing;
    const found = application_lifecycle.finishSelected(
        routes,
        .{},
        middleware,
        0,
        workspace.live_static_route_id,
        workspace,
        outcome,
    );
    std.debug.assert(found);
    workspace.lifecycle = .idle;
    return outcome;
}

pub fn abortAwaitingMetrics(
    comptime routes: anytype,
    comptime middleware: anytype,
    workspace: anytype,
    transport: anytype,
    comptime Outcome: type,
) Outcome {
    const outcome = Outcome{
        .status = null,
        .mapped_error = workspace.metrics.mapped_error,
        .transport = transport,
    };
    workspace.lifecycle = .finishing;
    const found = application_lifecycle.finishSelected(
        routes,
        .{},
        middleware,
        0,
        workspace.metrics.route_id,
        workspace,
        outcome,
    );
    std.debug.assert(found);
    workspace.lifecycle = .idle;
    return outcome;
}

pub fn abortPreparingMultipart(
    comptime routes: anytype,
    comptime middleware: anytype,
    workspace: anytype,
    transport: anytype,
    comptime Outcome: type,
) Outcome {
    return abortSelected(
        routes,
        middleware,
        workspace,
        workspace.multipart_abort_mapped_error,
        transport,
        Outcome,
    );
}

fn abortSelected(
    comptime routes: anytype,
    comptime middleware: anytype,
    workspace: anytype,
    mapped_error: bool,
    transport: anytype,
    comptime Outcome: type,
) Outcome {
    const outcome = Outcome{
        .status = null,
        .mapped_error = mapped_error,
        .transport = transport,
    };
    workspace.lifecycle = .finishing;
    const found = application_lifecycle.finishSelected(
        routes,
        .{},
        middleware,
        0,
        workspace.request_data.awaiting.route_id,
        workspace,
        outcome,
    );
    std.debug.assert(found);
    workspace.lifecycle = .idle;
    return outcome;
}

pub fn finish(
    comptime routes: anytype,
    comptime middleware: anytype,
    workspace: anytype,
    transport: anytype,
    comptime Outcome: type,
) Outcome {
    std.debug.assert(workspace.lifecycle == .pending);
    const pending = workspace.pending;
    const outcome = Outcome{
        .status = pending.status,
        .mapped_error = pending.mapped_error,
        .transport = transport,
    };
    workspace.lifecycle = .finishing;
    switch (pending.route) {
        .generated => application_lifecycle.runAfter(middleware, workspace, outcome),
        .asset => {},
        .selected => |route_id| {
            const found = application_lifecycle.finishSelected(
                routes,
                .{},
                middleware,
                0,
                route_id,
                workspace,
                outcome,
            );
            std.debug.assert(found);
        },
    }
    workspace.lifecycle = .idle;
    return outcome;
}

test {
    std.testing.refAllDecls(@This());
}
