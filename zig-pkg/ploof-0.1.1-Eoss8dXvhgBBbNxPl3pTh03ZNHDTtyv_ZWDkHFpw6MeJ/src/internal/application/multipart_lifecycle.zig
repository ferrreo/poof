const std = @import("std");
const body = @import("../../body.zig");
const multipart = @import("../../multipart.zig");
const application_multipart_dispatch = @import("multipart_combined_dispatch.zig");
const application_types = @import("types.zig");
const multipart_parser = @import("../multipart/parser.zig");

pub const Error = application_multipart_dispatch.Error;

pub const Phase = enum(u8) {
    not_selected,
    awaiting,
    started,
    finished,
};

pub fn RequestData(
    comptime body_enabled: bool,
    comptime Input: type,
    comptime JsonBinding: type,
) type {
    if (!body_enabled) return struct {};
    return union {
        awaiting: struct {
            route_id: u16,
            selected_decoder: ?u8,
            multipart_phase: Phase = .not_selected,
            input: Input,
        },
        json_response: JsonBinding,
    };
}

pub fn Configured(
    comptime body_enabled: bool,
    comptime multipart_enabled: bool,
    comptime descriptors: anytype,
    comptime Context: type,
    comptime Workspace: type,
    comptime AppError: type,
    comptime Registry: type,
) type {
    const Dispatch = application_multipart_dispatch.Configured(
        descriptors,
        Context,
        AppError,
        Registry,
    );

    return struct {
        pub const DispatchError = Dispatch.DispatchError;
        pub const Lane = Dispatch.Lane;
        pub const Submission = Dispatch.Submission;
        pub const FinalizationFlow = Dispatch.FinalizationFlow;
        pub const FinalizationOutcome = Dispatch.FinalizationOutcome;
        pub const Finalization = Dispatch.Finalization;
        pub const UpstreamFailure = Dispatch.UpstreamFailure;
        pub const TerminalSource = Dispatch.TerminalSource;

        pub fn begin(
            workspace: *Workspace,
            request_workspace: []u8,
            boundary: []const u8,
            registry: *Registry,
        ) DispatchError!void {
            if (comptime !body_enabled) return error.InvariantViolation;
            if (workspace.lifecycle != .awaiting_body) return error.InvariantViolation;
            const awaiting = &workspace.request_data.awaiting;
            if (awaiting.multipart_phase != .awaiting) return error.InvariantViolation;
            const finalization_required = try Dispatch.requiresFinalization(
                awaiting.route_id,
            );
            try Dispatch.begin(
                awaiting.route_id,
                awaiting.selected_decoder,
                boundary,
                &workspace.context,
                registry,
                request_workspace,
            );
            awaiting.multipart_phase = .started;
            if (comptime multipart_enabled) {
                if (finalization_required) workspace.multipart_finalization = .required;
            } else if (finalization_required) return error.InvariantViolation;
        }

        pub fn feed(
            workspace: *Workspace,
            request_workspace: []u8,
            input: []const u8,
        ) DispatchError!void {
            const progress = try feedProgress(workspace, request_workspace, input);
            if (progress.consumed != input.len or progress.flow != .ready) {
                return error.InvariantViolation;
            }
        }

        pub fn finish(
            workspace: *Workspace,
            request_workspace: []u8,
        ) DispatchError!void {
            const progress = try finishProgress(workspace, request_workspace);
            if (progress.flow != .complete) return error.InvariantViolation;
        }

        pub fn feedProgress(
            workspace: *Workspace,
            request_workspace: []u8,
            input: []const u8,
        ) DispatchError!multipart_parser.Progress {
            const awaiting = try started(workspace);
            return Dispatch.feedProgress(
                awaiting.route_id,
                awaiting.selected_decoder,
                request_workspace,
                input,
            ) catch |problem| {
                latchFailure(workspace, request_workspace, awaiting, problem);
                return problem;
            };
        }

        pub fn finishProgress(
            workspace: *Workspace,
            request_workspace: []u8,
        ) DispatchError!multipart_parser.Progress {
            const awaiting = try started(workspace);
            const progress = Dispatch.finishProgress(
                awaiting.route_id,
                awaiting.selected_decoder,
                request_workspace,
            ) catch |problem| {
                latchFailure(workspace, request_workspace, awaiting, problem);
                return problem;
            };
            if (progress.flow == .complete) {
                workspace.request_data.awaiting.multipart_phase = .finished;
            }
            return progress;
        }

        pub fn resumeParser(
            workspace: *Workspace,
            request_workspace: []u8,
        ) DispatchError!multipart_parser.Progress {
            const awaiting = try started(workspace);
            const progress = Dispatch.resumeParser(
                awaiting.route_id,
                awaiting.selected_decoder,
                request_workspace,
            ) catch |problem| {
                latchFailure(workspace, request_workspace, awaiting, problem);
                return problem;
            };
            if (progress.flow == .complete) {
                workspace.request_data.awaiting.multipart_phase = .finished;
            }
            return progress;
        }

        pub fn parserFinished(workspace: *const Workspace) bool {
            if (comptime !body_enabled) return false;
            if (workspace.lifecycle != .awaiting_body) return false;
            return workspace.request_data.awaiting.multipart_phase == .finished;
        }

        pub fn peekSubmission(
            workspace: *Workspace,
            request_workspace: []u8,
        ) DispatchError!?Submission {
            const awaiting = try runtimeSelected(workspace);
            return Dispatch.peekSubmission(
                awaiting.route_id,
                awaiting.selected_decoder,
                request_workspace,
            );
        }

        pub fn markSubmitted(
            workspace: *Workspace,
            request_workspace: []u8,
            lane: Lane,
        ) DispatchError!void {
            const awaiting = try runtimeSelected(workspace);
            return Dispatch.markSubmitted(
                awaiting.route_id,
                awaiting.selected_decoder,
                request_workspace,
                lane,
            );
        }

        pub fn completeSubmission(
            workspace: *Workspace,
            request_workspace: []u8,
            lane: Lane,
            completion: multipart.IoCompletion,
        ) DispatchError!void {
            const awaiting = try runtimeSelected(workspace);
            return Dispatch.completeSubmission(
                awaiting.route_id,
                awaiting.selected_decoder,
                request_workspace,
                lane,
                completion,
            );
        }

        pub fn completeCanceledSubmission(
            workspace: *Workspace,
            request_workspace: []u8,
            lane: Lane,
        ) DispatchError!void {
            const awaiting = try runtimeSelected(workspace);
            return Dispatch.completeCanceledSubmission(
                awaiting.route_id,
                awaiting.selected_decoder,
                request_workspace,
                lane,
            );
        }

        pub fn startFinalization(
            workspace: *Workspace,
            request_workspace: []u8,
        ) DispatchError!FinalizationFlow {
            if (comptime multipart_enabled) {
                const awaiting = try finalizationSelected(workspace, .required);
                workspace.multipart_finalization = .active;
                const flow = try Dispatch.startFinalization(
                    workspace.multipart_commit,
                    workspace.multipart_abort_cause,
                    awaiting.route_id,
                    awaiting.selected_decoder,
                    request_workspace,
                );
                return settleFlow(workspace, request_workspace, awaiting, flow);
            }
            return error.InvariantViolation;
        }

        pub fn cancel(
            workspace: *Workspace,
            cause: UpstreamFailure,
        ) DispatchError!void {
            if (comptime multipart_enabled) {
                _ = try finalizationSelected(workspace, .required);
                workspace.multipart_commit = false;
                workspace.multipart_abort_cause = cause;
                return;
            }
            return error.InvariantViolation;
        }

        pub fn finalizationFlow(
            workspace: *Workspace,
            request_workspace: []u8,
        ) DispatchError!FinalizationFlow {
            if (comptime multipart_enabled) {
                const awaiting = try finalizationSelected(workspace, .active);
                const flow = try Dispatch.finalizationFlow(
                    awaiting.route_id,
                    awaiting.selected_decoder,
                    request_workspace,
                );
                return settleFlow(workspace, request_workspace, awaiting, flow);
            }
            return error.InvariantViolation;
        }

        pub fn finalizationOutcome(
            workspace: *Workspace,
            request_workspace: []u8,
        ) DispatchError!?FinalizationOutcome {
            const report = try finalizationReport(workspace, request_workspace);
            return if (report) |value| value.outcome else null;
        }

        pub fn finalizationReport(
            workspace: *Workspace,
            request_workspace: []u8,
        ) DispatchError!?Finalization.Report {
            if (comptime !multipart_enabled) return null;
            const awaiting = try reportSelected(workspace);
            const report = try Dispatch.finalizationReport(
                awaiting.route_id,
                awaiting.selected_decoder,
                request_workspace,
            );
            if (report) |value| settleOutcome(workspace, value.outcome);
            return report;
        }

        pub fn finalizationCleanupFailure(
            workspace: *Workspace,
            request_workspace: []u8,
            instance_index: u16,
        ) DispatchError!?Finalization.CleanupFailure {
            if (comptime !multipart_enabled) return null;
            const awaiting = try reportSelected(workspace);
            return Dispatch.finalizationCleanupFailure(
                awaiting.route_id,
                awaiting.selected_decoder,
                request_workspace,
                instance_index,
            );
        }

        pub fn applicationFailure(
            workspace: *Workspace,
            request_workspace: []u8,
        ) DispatchError!?AppError {
            const awaiting = try reportSelected(workspace);
            return Dispatch.applicationFailureForRoute(
                awaiting.route_id,
                awaiting.selected_decoder,
                request_workspace,
            );
        }

        pub fn terminalSource(
            workspace: *Workspace,
            request_workspace: []u8,
        ) DispatchError!TerminalSource {
            const awaiting = try reportSelected(workspace);
            return Dispatch.terminalSourceForRoute(
                awaiting.route_id,
                awaiting.selected_decoder,
                request_workspace,
            );
        }

        pub fn rejection(
            workspace: *Workspace,
            request_workspace: []u8,
        ) DispatchError!?*const Context.ResponseType {
            const awaiting = try reportSelected(workspace);
            return Dispatch.rejectionForRoute(
                awaiting.route_id,
                awaiting.selected_decoder,
                request_workspace,
            );
        }

        pub fn validateCompletion(
            workspace: *Workspace,
            decoded: body.Decoded,
        ) error{ NoPendingBody, InvalidBodyInput }!void {
            if (comptime !body_enabled) return error.NoPendingBody;
            if (workspace.lifecycle != .awaiting_body) return error.NoPendingBody;
            switch (workspace.request_data.awaiting.multipart_phase) {
                .awaiting, .started => return error.InvalidBodyInput,
                .finished => if (std.meta.activeTag(decoded) != .none) {
                    return error.InvalidBodyInput;
                },
                .not_selected => {},
            }
        }

        fn started(workspace: *Workspace) DispatchError!*@FieldType(
            @FieldType(Workspace, "request_data"),
            "awaiting",
        ) {
            if (comptime !body_enabled) return error.InvariantViolation;
            if (workspace.lifecycle != .awaiting_body) return error.InvariantViolation;
            const awaiting = &workspace.request_data.awaiting;
            if (awaiting.multipart_phase != .started) return error.InvariantViolation;
            return awaiting;
        }

        fn runtimeSelected(workspace: *Workspace) DispatchError!*@FieldType(
            @FieldType(Workspace, "request_data"),
            "awaiting",
        ) {
            if (comptime multipart_enabled) {
                const awaiting = try selected(workspace);
                if (workspace.multipart_finalization == .not_required) {
                    return error.InvariantViolation;
                }
                return awaiting;
            }
            return error.InvariantViolation;
        }

        pub fn uploadRouteId(workspace: *Workspace) DispatchError!u16 {
            return (try selected(workspace)).route_id;
        }

        fn selected(workspace: *Workspace) DispatchError!*@FieldType(
            @FieldType(Workspace, "request_data"),
            "awaiting",
        ) {
            if (comptime !body_enabled) return error.InvariantViolation;
            switch (workspace.lifecycle) {
                .awaiting_body, .preparing, .pending => {},
                .idle, .awaiting_static => return error.InvariantViolation,
                .awaiting_metrics, .finishing => return error.InvariantViolation,
            }
            return &workspace.request_data.awaiting;
        }

        fn reportSelected(workspace: *Workspace) DispatchError!*@FieldType(
            @FieldType(Workspace, "request_data"),
            "awaiting",
        ) {
            if (comptime multipart_enabled) {
                const awaiting = try selected(workspace);
                const required = try Dispatch.requiresFinalization(awaiting.route_id);
                if (required and workspace.multipart_finalization == .not_required) {
                    return error.InvariantViolation;
                }
                return awaiting;
            }
            return error.InvariantViolation;
        }

        fn finalizationSelected(
            workspace: *Workspace,
            expected: application_types.MultipartFinalization,
        ) DispatchError!*@FieldType(
            @FieldType(Workspace, "request_data"),
            "awaiting",
        ) {
            if (comptime multipart_enabled) {
                if (workspace.multipart_finalization != expected) {
                    return error.InvariantViolation;
                }
                return runtimeSelected(workspace);
            }
            return error.InvariantViolation;
        }

        fn settleFlow(
            workspace: *Workspace,
            request_workspace: []u8,
            awaiting: *@FieldType(@FieldType(Workspace, "request_data"), "awaiting"),
            flow: FinalizationFlow,
        ) DispatchError!FinalizationFlow {
            if (flow != .complete) return flow;
            const outcome = (try Dispatch.finalizationOutcome(
                awaiting.route_id,
                awaiting.selected_decoder,
                request_workspace,
            )) orelse return error.InvariantViolation;
            settleOutcome(workspace, outcome);
            return flow;
        }

        fn settleOutcome(workspace: *Workspace, outcome: FinalizationOutcome) void {
            if (comptime multipart_enabled) {
                workspace.multipart_finalization = switch (outcome) {
                    .committed => .committed,
                    .aborted => .aborted,
                    .failed => .failed,
                };
            }
        }

        fn latchFailure(
            workspace: *Workspace,
            request_workspace: []u8,
            awaiting: *@FieldType(@FieldType(Workspace, "request_data"), "awaiting"),
            problem: DispatchError,
        ) void {
            if (comptime !multipart_enabled) return;
            const source = Dispatch.terminalSourceForRoute(
                awaiting.route_id,
                awaiting.selected_decoder,
                request_workspace,
            ) catch .fatal;
            workspace.multipart_commit = false;
            workspace.multipart_abort_cause = switch (source) {
                .none, .parser, .application, .rejection => null,
                .sink => .upload,
                .fatal => .verification,
            };
            const application_failure = Dispatch.applicationFailureForRoute(
                awaiting.route_id,
                awaiting.selected_decoder,
                request_workspace,
            ) catch null;
            if (problem == error.FileRejected or application_failure != null) {
                workspace.request_data.awaiting.multipart_phase = .finished;
            }
        }
    };
}
