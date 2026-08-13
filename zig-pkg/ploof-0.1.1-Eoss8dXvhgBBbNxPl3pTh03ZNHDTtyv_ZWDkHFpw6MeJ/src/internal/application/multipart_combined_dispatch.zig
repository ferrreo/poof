const application_upload_catalog = @import("upload_catalog.zig");
const legacy_dispatch = @import("multipart_dispatch.zig");
const multipart_parser = @import("../multipart/parser.zig");
const upload_dispatch = @import("multipart_upload_dispatch.zig");

pub const Error = legacy_dispatch.Error || upload_dispatch.FixedError;

pub fn Configured(
    comptime descriptors: anytype,
    comptime Context: type,
    comptime AppError: type,
    comptime Registry: type,
) type {
    const Legacy = legacy_dispatch.Configured(descriptors, Context);
    const Upload = upload_dispatch.Configured(descriptors, Context, AppError, Registry);
    const Routes = application_upload_catalog.DispatchRoutes(descriptors);

    return struct {
        pub const DispatchError = Error || AppError;
        pub const Progress = multipart_parser.Progress;
        pub const Lane = upload_dispatch.Lane;
        pub const Submission = upload_dispatch.Submission;
        pub const FinalizationFlow = upload_dispatch.FinalizationFlow;
        pub const FinalizationOutcome = upload_dispatch.FinalizationOutcome;
        pub const Finalization = upload_dispatch.Finalization;
        pub const UpstreamFailure = upload_dispatch.UpstreamFailure;
        pub const TerminalSource = upload_dispatch.TerminalSource;

        pub fn requiresFinalization(route_id: u16) DispatchError!bool {
            return routeHasFiles(Routes, route_id);
        }

        pub fn begin(
            route_id: u16,
            selected_decoder: ?u8,
            boundary: []const u8,
            context: *Context,
            registry: *Registry,
            workspace: []u8,
        ) DispatchError!void {
            if (try routeHasFiles(Routes, route_id)) {
                return Upload.begin(
                    route_id,
                    selected_decoder,
                    boundary,
                    context,
                    registry,
                    workspace,
                );
            }
            return Legacy.begin(
                route_id,
                selected_decoder,
                boundary,
                context,
                workspace,
            );
        }

        pub fn feedProgress(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
            input: []const u8,
        ) DispatchError!Progress {
            if (try routeHasFiles(Routes, route_id)) {
                return Upload.feed(route_id, selected_decoder, workspace, input);
            }
            try Legacy.feed(route_id, selected_decoder, workspace, input);
            return .{ .consumed = input.len, .flow = .ready };
        }

        pub fn finishProgress(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) DispatchError!Progress {
            if (try routeHasFiles(Routes, route_id)) {
                return Upload.finish(route_id, selected_decoder, workspace);
            }
            try Legacy.finish(route_id, selected_decoder, workspace);
            return .{ .consumed = 0, .flow = .complete };
        }

        pub fn resumeParser(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) DispatchError!Progress {
            if (!try routeHasFiles(Routes, route_id)) {
                return error.InvariantViolation;
            }
            return Upload.resumeParser(route_id, selected_decoder, workspace);
        }

        pub fn peekSubmission(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) DispatchError!?Submission {
            if (!try routeHasFiles(Routes, route_id)) return null;
            return Upload.peekSubmission(route_id, selected_decoder, workspace);
        }

        pub fn markSubmitted(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
            lane: Lane,
        ) DispatchError!void {
            if (!try routeHasFiles(Routes, route_id)) {
                return error.InvariantViolation;
            }
            return Upload.markSubmitted(route_id, selected_decoder, workspace, lane);
        }

        pub fn completeSubmission(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
            lane: Lane,
            completion: @import("../../multipart.zig").IoCompletion,
        ) DispatchError!void {
            if (!try routeHasFiles(Routes, route_id)) {
                return error.InvariantViolation;
            }
            return Upload.completeSubmission(
                route_id,
                selected_decoder,
                workspace,
                lane,
                completion,
            );
        }

        pub fn completeCanceledSubmission(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
            lane: Lane,
        ) DispatchError!void {
            if (!try routeHasFiles(Routes, route_id)) {
                return error.InvariantViolation;
            }
            return Upload.completeCanceledSubmission(
                route_id,
                selected_decoder,
                workspace,
                lane,
            );
        }

        pub fn startFinalization(
            commit: bool,
            cause: ?UpstreamFailure,
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) DispatchError!FinalizationFlow {
            if (!try routeHasFiles(Routes, route_id)) return .complete;
            if (commit) {
                try Upload.markCommitReady(route_id, selected_decoder, workspace);
                return Upload.startCommit(route_id, selected_decoder, workspace);
            }
            return Upload.startAbort(route_id, selected_decoder, workspace, cause);
        }

        pub fn finalizationFlow(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) DispatchError!FinalizationFlow {
            if (!try routeHasFiles(Routes, route_id)) return .complete;
            return Upload.finalizationFlow(route_id, selected_decoder, workspace);
        }

        pub fn finalizationOutcome(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) DispatchError!?FinalizationOutcome {
            const report = try finalizationReport(route_id, selected_decoder, workspace);
            return if (report) |value| value.outcome else null;
        }

        pub fn finalizationReport(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) DispatchError!?Finalization.Report {
            if (!try routeHasFiles(Routes, route_id)) return null;
            return Upload.finalizationReport(route_id, selected_decoder, workspace);
        }

        pub fn finalizationCleanupFailure(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
            instance_index: u16,
        ) DispatchError!?Finalization.CleanupFailure {
            if (!try routeHasFiles(Routes, route_id)) {
                return error.InvariantViolation;
            }
            return Upload.finalizationCleanupFailure(
                route_id,
                selected_decoder,
                workspace,
                instance_index,
            );
        }

        pub fn terminalSourceForRoute(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) DispatchError!TerminalSource {
            if (!try routeHasFiles(Routes, route_id)) {
                return Legacy.terminalSourceForRoute(
                    route_id,
                    selected_decoder,
                    workspace,
                );
            }
            return Upload.terminalSourceForRoute(route_id, selected_decoder, workspace);
        }

        pub fn rejectionForRoute(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) DispatchError!?*const Context.ResponseType {
            if (!try routeHasFiles(Routes, route_id)) return null;
            return Upload.rejectionForRoute(route_id, selected_decoder, workspace);
        }

        pub fn applicationFailureForRoute(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) DispatchError!?AppError {
            if (!try routeHasFiles(Routes, route_id)) return null;
            return Upload.applicationFailureForRoute(route_id, selected_decoder, workspace);
        }

        pub fn statePointer(
            comptime Handler: type,
            selected_decoder: ?u8,
            workspace: []u8,
        ) DispatchError!*Handler.MultipartState {
            if (comptime Handler.definition.MultipartBodySpec.File == void) {
                return legacy_dispatch.statePointer(Handler, selected_decoder, workspace);
            }
            return Upload.statePointer(Handler, selected_decoder, workspace);
        }

        pub fn summaries(
            comptime Handler: type,
            selected_decoder: ?u8,
            workspace: []u8,
        ) DispatchError!Handler.definition.MultipartBodySpec.Summaries {
            if (comptime Handler.definition.MultipartBodySpec.File == void) return .{};
            return Upload.summaries(Handler, selected_decoder, workspace);
        }

        pub fn rejection(
            comptime Handler: type,
            selected_decoder: ?u8,
            workspace: []u8,
        ) DispatchError!?*const Context.ResponseType {
            if (comptime Handler.definition.MultipartBodySpec.File == void) return null;
            return Upload.rejection(Handler, selected_decoder, workspace);
        }

        pub fn applicationFailure(
            comptime Handler: type,
            selected_decoder: ?u8,
            workspace: []u8,
        ) DispatchError!?AppError {
            if (comptime Handler.definition.MultipartBodySpec.File == void) return null;
            return Upload.applicationFailure(Handler, selected_decoder, workspace);
        }
    };
}

fn routeHasFiles(
    comptime Routes: type,
    route_id: u16,
) Error!bool {
    return Routes.hasFiles(route_id) orelse error.InvariantViolation;
}
