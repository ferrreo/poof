const application_finish = @import("finish.zig");
const application_types = @import("types.zig");

pub fn Configured(
    comptime routes: anytype,
    comptime middleware: anytype,
    comptime body_enabled: bool,
    comptime live_static_enabled: bool,
    comptime metrics_enabled: bool,
    comptime multipart_enabled: bool,
    comptime stream_enabled: bool,
    comptime Outcome: type,
    comptime LifecycleError: type,
    comptime TransportOutcome: type,
) type {
    return struct {
        pub fn complete(workspace: anytype) LifecycleError!Outcome {
            if (workspace.lifecycle != .pending) return error.NoPendingRequest;
            try application_types.requireMultipartComplete(workspace);
            if (!application_types.streamJoined(stream_enabled, workspace)) {
                return error.StreamNotJoined;
            }
            return application_finish.finish(
                routes,
                middleware,
                workspace,
                workspace.pending.success_transport,
                Outcome,
            );
        }

        pub fn abort(workspace: anytype) LifecycleError!Outcome {
            return abortWithTransport(workspace, .aborted);
        }

        pub fn abortWithTransport(
            workspace: anytype,
            transport: TransportOutcome,
        ) LifecycleError!Outcome {
            return switch (workspace.lifecycle) {
                .pending => abortPending(workspace, transport),
                .awaiting_body => if (comptime body_enabled) abortBody(
                    workspace,
                    transport,
                ) else error.NoPendingRequest,
                .awaiting_static => if (comptime live_static_enabled)
                    application_finish.abortAwaitingStatic(
                        routes,
                        middleware,
                        workspace,
                        transport,
                        Outcome,
                    )
                else
                    error.NoPendingRequest,
                .awaiting_metrics => if (comptime metrics_enabled)
                    application_finish.abortAwaitingMetrics(
                        routes,
                        middleware,
                        workspace,
                        transport,
                        Outcome,
                    )
                else
                    error.NoPendingRequest,
                .preparing => if (comptime multipart_enabled) abortPreparing(
                    workspace,
                    transport,
                ) else error.NoPendingRequest,
                else => error.NoPendingRequest,
            };
        }

        fn abortPending(workspace: anytype, transport: TransportOutcome) !Outcome {
            try application_types.requireMultipartAbort(workspace);
            application_types.settleStreamForAbort(stream_enabled, workspace);
            return application_finish.finish(
                routes,
                middleware,
                workspace,
                transport,
                Outcome,
            );
        }

        fn abortBody(workspace: anytype, transport: TransportOutcome) !Outcome {
            try application_types.requireMultipartAbort(workspace);
            return application_finish.abortAwaitingBody(
                routes,
                middleware,
                workspace,
                transport,
                Outcome,
            );
        }

        fn abortPreparing(workspace: anytype, transport: TransportOutcome) !Outcome {
            if (!application_types.multipartFinalizationTerminal(workspace)) {
                return error.NoPendingRequest;
            }
            try application_types.requireMultipartAbort(workspace);
            return application_finish.abortPreparingMultipart(
                routes,
                middleware,
                workspace,
                transport,
                Outcome,
            );
        }
    };
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}
