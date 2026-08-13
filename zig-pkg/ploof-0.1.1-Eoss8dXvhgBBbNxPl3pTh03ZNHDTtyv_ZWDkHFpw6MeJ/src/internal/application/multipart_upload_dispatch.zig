const application_input = @import("input.zig");
pub const Finalization = @import("multipart_finalization.zig");
const legacy_runtime = @import("multipart_runtime.zig");
const application_upload_catalog = @import("upload_catalog.zig");
const upload_runtime = @import("multipart_upload_runtime.zig");
const multipart = @import("../../multipart.zig");
const multipart_parser = @import("../multipart/parser.zig");
const upload_finalizer = @import("../upload/finalizer.zig");

pub const FixedError = error{
    InvalidMultipart,
    InvalidField,
    LimitExceeded,
    UnsupportedMedia,
    FileRejected,
    UploadFailure,
    InvariantViolation,
    Terminal,
};

pub const Lane = union(enum) {
    lifecycle,
    write: u8,
};

pub const Submission = struct {
    lane: Lane,
    request: multipart.IoRequest,
    registry_index: u16,
    instance_index: u16,
};

pub const FinalizationFlow = enum(u8) {
    progress,
    paused,
    complete,
};

pub const FinalizationOutcome = Finalization.Outcome;
pub const UpstreamFailure = upload_finalizer.UpstreamFailure;
pub const TerminalSource = upload_runtime.TerminalSource;

const Operation = enum(u8) {
    begin,
    feed,
    finish,
    resume_parser,
    peek_submission,
    mark_submitted,
    complete_submission,
    complete_canceled_submission,
    mark_commit_ready,
    start_commit,
    start_abort,
    finalization_flow,
    finalization_report,
    finalization_cleanup_failure,
    terminal_source,
    rejection,
    application_failure,
};

pub fn Configured(
    comptime descriptors: anytype,
    comptime Context: type,
    comptime AppError: type,
    comptime Registry: type,
) type {
    const Routes = application_upload_catalog.DispatchRoutes(descriptors);

    return struct {
        const Self = @This();
        const Response = Context.ResponseType;

        pub const Error = FixedError || AppError;
        pub const Progress = multipart_parser.Progress;

        const Arguments = struct {
            boundary: []const u8 = "",
            context: ?*Context = null,
            registry: ?*Registry = null,
            input: []const u8 = "",
            lane: Lane = .lifecycle,
            completion: multipart.IoCompletion = .{ .failure = .canceled },
            cause: ?UpstreamFailure = null,
            instance_index: u16 = 0,
        };

        pub fn begin(
            route_id: u16,
            selected_decoder: ?u8,
            boundary: []const u8,
            context: *Context,
            registry: *Registry,
            workspace: []u8,
        ) Error!void {
            return requireDispatch(.begin, route_id, selected_decoder, workspace, .{
                .boundary = boundary,
                .context = context,
                .registry = registry,
            });
        }

        pub fn feed(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
            input: []const u8,
        ) Error!Progress {
            return requireDispatch(.feed, route_id, selected_decoder, workspace, .{
                .input = input,
            });
        }

        pub fn finish(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) Error!Progress {
            return requireDispatch(.finish, route_id, selected_decoder, workspace, .{});
        }

        pub fn resumeParser(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) Error!Progress {
            return requireDispatch(
                .resume_parser,
                route_id,
                selected_decoder,
                workspace,
                .{},
            );
        }

        pub fn peekSubmission(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) Error!?Submission {
            return requireDispatch(
                .peek_submission,
                route_id,
                selected_decoder,
                workspace,
                .{},
            );
        }

        pub fn markSubmitted(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
            lane: Lane,
        ) Error!void {
            return requireDispatch(.mark_submitted, route_id, selected_decoder, workspace, .{
                .lane = lane,
            });
        }

        pub fn completeSubmission(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
            lane: Lane,
            completion: multipart.IoCompletion,
        ) Error!void {
            return requireDispatch(
                .complete_submission,
                route_id,
                selected_decoder,
                workspace,
                .{ .lane = lane, .completion = completion },
            );
        }

        pub fn completeCanceledSubmission(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
            lane: Lane,
        ) Error!void {
            return requireDispatch(
                .complete_canceled_submission,
                route_id,
                selected_decoder,
                workspace,
                .{ .lane = lane },
            );
        }

        pub fn markCommitReady(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) Error!void {
            return requireDispatch(
                .mark_commit_ready,
                route_id,
                selected_decoder,
                workspace,
                .{},
            );
        }

        pub fn startCommit(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) Error!FinalizationFlow {
            return requireDispatch(.start_commit, route_id, selected_decoder, workspace, .{});
        }

        pub fn startAbort(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
            cause: ?UpstreamFailure,
        ) Error!FinalizationFlow {
            return requireDispatch(.start_abort, route_id, selected_decoder, workspace, .{
                .cause = cause,
            });
        }

        pub fn finalizationFlow(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) Error!FinalizationFlow {
            return requireDispatch(
                .finalization_flow,
                route_id,
                selected_decoder,
                workspace,
                .{},
            );
        }

        pub fn finalizationOutcome(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) Error!?FinalizationOutcome {
            const report = try finalizationReport(
                route_id,
                selected_decoder,
                workspace,
            );
            return if (report) |value| value.outcome else null;
        }

        pub fn finalizationReport(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) Error!?Finalization.Report {
            return requireDispatch(
                .finalization_report,
                route_id,
                selected_decoder,
                workspace,
                .{},
            );
        }

        pub fn finalizationCleanupFailure(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
            instance_index: u16,
        ) Error!?Finalization.CleanupFailure {
            return requireDispatch(
                .finalization_cleanup_failure,
                route_id,
                selected_decoder,
                workspace,
                .{ .instance_index = instance_index },
            );
        }

        pub fn terminalSourceForRoute(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) Error!TerminalSource {
            return requireDispatch(
                .terminal_source,
                route_id,
                selected_decoder,
                workspace,
                .{},
            );
        }

        pub fn rejectionForRoute(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) Error!?*const Response {
            return requireDispatch(
                .rejection,
                route_id,
                selected_decoder,
                workspace,
                .{},
            );
        }

        pub fn applicationFailureForRoute(
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
        ) Error!?AppError {
            return requireDispatch(
                .application_failure,
                route_id,
                selected_decoder,
                workspace,
                .{},
            );
        }

        pub fn statePointer(
            comptime Handler: type,
            selected_decoder: ?u8,
            workspace: []u8,
        ) Error!*Handler.MultipartState {
            const Runtime = upload_runtime.Runtime(Handler);
            const runtime = try runtimePointer(Handler, Runtime, selected_decoder, workspace);
            return runtime.state() catch |problem| return mapFailure(runtime, problem);
        }

        pub fn summaries(
            comptime Handler: type,
            selected_decoder: ?u8,
            workspace: []u8,
        ) Error!Handler.definition.MultipartBodySpec.Summaries {
            const Runtime = upload_runtime.Runtime(Handler);
            const runtime = try runtimePointer(Handler, Runtime, selected_decoder, workspace);
            return runtime.summaries() catch |problem| return mapFailure(runtime, problem);
        }

        pub fn rejection(
            comptime Handler: type,
            selected_decoder: ?u8,
            workspace: []u8,
        ) Error!?*const Response {
            const Runtime = upload_runtime.Runtime(Handler);
            const runtime = try runtimePointer(Handler, Runtime, selected_decoder, workspace);
            return runtime.rejection();
        }

        pub fn applicationFailure(
            comptime Handler: type,
            selected_decoder: ?u8,
            workspace: []u8,
        ) Error!?AppError {
            const Runtime = upload_runtime.Runtime(Handler);
            const runtime = try runtimePointer(Handler, Runtime, selected_decoder, workspace);
            const problem = runtime.applicationFailure() orelse return null;
            return @as(?AppError, problem);
        }

        fn requireDispatch(
            comptime operation: Operation,
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
            arguments: Arguments,
        ) Error!Result(operation, AppError, Response) {
            @setEvalBranchQuota(100_000);
            if (comptime Routes.file_route_count == 0) {
                return error.InvariantViolation;
            }
            return dispatchRange(
                operation,
                0,
                Routes.file_route_count,
                route_id,
                selected_decoder,
                workspace,
                arguments,
            );
        }

        fn dispatchRange(
            comptime operation: Operation,
            comptime first: usize,
            comptime end: usize,
            route_id: u16,
            selected_decoder: ?u8,
            workspace: []u8,
            arguments: Arguments,
        ) Error!Result(operation, AppError, Response) {
            if (comptime end - first == 1) {
                if (route_id != Routes.file_route_ids[first]) {
                    return error.InvariantViolation;
                }
                return dispatchRoute(
                    operation,
                    Routes.file_handler_types[first],
                    selected_decoder,
                    workspace,
                    arguments,
                );
            }
            const middle = first + (end - first) / 2;
            if (route_id < Routes.file_route_ids[middle]) {
                return dispatchRange(
                    operation,
                    first,
                    middle,
                    route_id,
                    selected_decoder,
                    workspace,
                    arguments,
                );
            }
            return dispatchRange(
                operation,
                middle,
                end,
                route_id,
                selected_decoder,
                workspace,
                arguments,
            );
        }

        fn dispatchRoute(
            comptime operation: Operation,
            comptime Handler: type,
            selected_decoder: ?u8,
            workspace: []u8,
            arguments: Arguments,
        ) Error!Result(operation, AppError, Response) {
            if (comptime !uploadHandler(Handler)) return error.InvariantViolation;
            const Runtime = upload_runtime.Runtime(Handler);
            const runtime = try runtimePointer(Handler, Runtime, selected_decoder, workspace);
            return switch (operation) {
                .begin => runtime.initInPlace(
                    arguments.boundary,
                    arguments.context orelse return error.InvariantViolation,
                    arguments.registry orelse return error.InvariantViolation,
                ) catch |problem| mapInitFailure(problem),
                .feed => runtime.feedProgress(arguments.input) catch |problem| {
                    return mapFailure(runtime, problem);
                },
                .finish => runtime.finishProgress() catch |problem| {
                    return mapFailure(runtime, problem);
                },
                .resume_parser => runtime.resumeParser() catch |problem| {
                    return mapFailure(runtime, problem);
                },
                .peek_submission => peek(Runtime, Registry, runtime) catch |problem| {
                    return mapFailure(runtime, problem);
                },
                .mark_submitted => runtime.markSubmitted(
                    typedLane(Runtime, arguments.lane),
                ) catch |problem| return mapFailure(runtime, problem),
                .complete_submission => runtime.completeSubmission(
                    typedLane(Runtime, arguments.lane),
                    arguments.completion,
                ) catch |problem| return mapFailure(runtime, problem),
                .complete_canceled_submission => runtime.completeCanceledSubmission(
                    typedLane(Runtime, arguments.lane),
                ) catch |problem| return mapFailure(runtime, problem),
                .mark_commit_ready => runtime.markCommitReady() catch |problem| {
                    return mapFailure(runtime, problem);
                },
                .start_commit => mapFlow(runtime.startCommit() catch |problem| {
                    return mapFailure(runtime, problem);
                }),
                .start_abort => mapFlow(runtime.startAbort(
                    arguments.cause,
                ) catch |problem| return mapFailure(runtime, problem)),
                .finalization_flow => mapFlow(
                    runtime.finalizationFlow() catch |problem| {
                        return mapFailure(runtime, problem);
                    },
                ),
                .finalization_report => normalizedFinalizationReport(Runtime, runtime),
                .finalization_cleanup_failure => normalizedCleanupFailure(
                    Runtime,
                    runtime,
                    arguments.instance_index,
                ),
                .terminal_source => runtime.terminalSource(),
                .rejection => runtime.rejection(),
                .application_failure => if (runtime.applicationFailure()) |problem|
                    @as(?AppError, problem)
                else
                    null,
            };
        }

        fn mapFailure(runtime: anytype, problem: anytype) Error {
            const Runtime = @typeInfo(@TypeOf(runtime)).pointer.child;
            return switch (runtime.terminalSource()) {
                .application => if (comptime Runtime.ApplicationError == error{})
                    error.InvariantViolation
                else blk: {
                    const application_problem = runtime.applicationFailure() orelse
                        return error.InvariantViolation;
                    break :blk @as(AppError, application_problem);
                },
                .rejection => error.FileRejected,
                .sink => error.UploadFailure,
                .fatal => error.InvariantViolation,
                .parser => mapParserFailure(problem),
                .none => switch (problem) {
                    error.Terminal => error.Terminal,
                    error.InvalidField => error.InvalidField,
                    else => error.InvariantViolation,
                },
            };
        }

        fn normalizedFinalizationReport(
            comptime Runtime: type,
            runtime: *Runtime,
        ) Error!?Finalization.Report {
            const raw = (runtime.report() catch |problem| {
                return mapFailure(runtime, problem);
            }) orelse return null;
            const instance_count = (runtime.reportRecordCount() catch |problem| {
                return mapFailure(runtime, problem);
            }) orelse return error.InvariantViolation;
            const primary = try normalizedPrimary(Runtime, runtime, raw.primary);
            return .{
                .outcome = raw.outcome,
                .primary = primary,
                .instance_count = instance_count,
                .commit_attempted_count = raw.commit_attempted_count,
                .commit_completed_count = raw.commit_completed_count,
                .abort_attempted_count = raw.abort_attempted_count,
                .abort_completed_count = raw.abort_completed_count,
                .cleanup_failure_count = raw.cleanup_failure_count,
            };
        }

        fn normalizedCleanupFailure(
            comptime Runtime: type,
            runtime: *Runtime,
            instance_index: u16,
        ) Error!?Finalization.CleanupFailure {
            if (comptime Runtime.report_record_capacity == 0) {
                return error.InvariantViolation;
            } else {
                const count = (runtime.reportRecordCount() catch |problem| {
                    return mapFailure(runtime, problem);
                }) orelse return error.InvariantViolation;
                if (instance_index >= count) return error.InvariantViolation;
                const record = (runtime.reportRecord(instance_index) catch |problem| {
                    return mapFailure(runtime, problem);
                }) orelse return error.InvariantViolation;
                const class = record.cleanup_failure orelse return null;
                return .{
                    .class = class,
                    .identity = .{
                        .registry_index = registryIndex(Registry, Runtime, record.file),
                        .instance_index = instance_index,
                    },
                };
            }
        }

        fn normalizedPrimary(
            comptime Runtime: type,
            runtime: *Runtime,
            raw: anytype,
        ) Error!?Finalization.PrimaryFailure {
            const failure = raw orelse return null;
            if (comptime Runtime.report_record_capacity == 0) {
                if (failure.entry_index != null) return error.InvariantViolation;
                return .{ .class = failure.class, .identity = null };
            } else {
                return .{
                    .class = failure.class,
                    .identity = if (failure.entry_index) |index|
                        try reportIdentity(Runtime, runtime, index)
                    else
                        null,
                };
            }
        }

        fn reportIdentity(
            comptime Runtime: type,
            runtime: *Runtime,
            index: usize,
        ) Error!Finalization.Identity {
            const record = (runtime.reportRecord(index) catch |problem| {
                return mapFailure(runtime, problem);
            }) orelse return error.InvariantViolation;
            return .{
                .registry_index = registryIndex(Registry, Runtime, record.file),
                .instance_index = @intCast(index),
            };
        }
    };
}

fn Result(
    comptime operation: Operation,
    comptime AppError: type,
    comptime Response: type,
) type {
    return switch (operation) {
        .begin,
        .mark_submitted,
        .complete_submission,
        .complete_canceled_submission,
        .mark_commit_ready,
        => void,
        .feed, .finish, .resume_parser => multipart_parser.Progress,
        .peek_submission => ?Submission,
        .start_commit, .start_abort, .finalization_flow => FinalizationFlow,
        .finalization_report => ?Finalization.Report,
        .finalization_cleanup_failure => ?Finalization.CleanupFailure,
        .terminal_source => TerminalSource,
        .rejection => ?*const Response,
        .application_failure => ?AppError,
    };
}

fn mapFlow(flow: anytype) FinalizationFlow {
    return @enumFromInt(@intFromEnum(flow));
}

fn peek(
    comptime Runtime: type,
    comptime Registry: type,
    runtime: *Runtime,
) Runtime.Error!?Submission {
    const pending = (try runtime.peekSubmission()) orelse return null;
    return .{
        .lane = publicLane(pending.lane),
        .request = pending.request,
        .registry_index = registryIndex(
            Registry,
            Runtime,
            pending.file,
        ),
        .instance_index = pending.instance_index,
    };
}

fn registryIndex(
    comptime Registry: type,
    comptime Runtime: type,
    file: Runtime.MultipartSpec.File,
) u16 {
    const Spec = Runtime.MultipartSpec;
    return switch (file) {
        inline else => |selected| Registry.indexOf(
            @TypeOf(@field(Spec.configured_schema, @tagName(selected))).SinkType,
        ),
    };
}

fn publicLane(lane: anytype) Lane {
    return switch (lane) {
        .lifecycle => .lifecycle,
        .write => |slot| .{ .write = @intCast(slot) },
    };
}

fn typedLane(comptime Runtime: type, lane: Lane) Runtime.Lane {
    return switch (lane) {
        .lifecycle => .lifecycle,
        .write => |slot| .{ .write = @intCast(slot) },
    };
}

fn runtimePointer(
    comptime Handler: type,
    comptime Runtime: type,
    selected_decoder: ?u8,
    workspace: []u8,
) FixedError!*Runtime {
    const decoder_index = legacy_runtime.decoderIndex(Handler);
    if (selected_decoder != decoder_index) return error.InvariantViolation;
    const layout = application_input.workspaceLayout(Handler);
    if (decoder_index >= layout.body_decoders.len) return error.InvariantViolation;
    const region = layout.body_decoders[decoder_index].parse;
    if (region.bytes != @sizeOf(Runtime) or region.alignment != @alignOf(Runtime)) {
        return error.InvariantViolation;
    }
    if (region.offset > workspace.len or region.bytes > workspace.len - region.offset) {
        return error.InvariantViolation;
    }
    const bytes = workspace[region.offset..][0..region.bytes];
    if (@intFromPtr(bytes.ptr) % @alignOf(Runtime) != 0) return error.InvariantViolation;
    return @ptrCast(@alignCast(bytes.ptr));
}

fn mapInitFailure(problem: anytype) FixedError {
    return switch (problem) {
        error.Malformed => error.InvalidMultipart,
        error.LimitExceeded => error.LimitExceeded,
        error.UnsupportedMedia => error.UnsupportedMedia,
        error.RuntimeUnavailable => error.InvariantViolation,
    };
}

fn mapParserFailure(problem: anytype) FixedError {
    if (problem == error.Malformed) return error.InvalidMultipart;
    if (problem == error.LimitExceeded) return error.LimitExceeded;
    if (problem == error.UnsupportedMedia) return error.UnsupportedMedia;
    if (problem == error.InvalidField) return error.InvalidField;
    return error.InvariantViolation;
}

fn uploadHandler(comptime Handler: type) bool {
    if (@typeInfo(Handler) != .@"struct" or
        !@hasDecl(Handler, "ploof_multipart_endpoint") or
        !Handler.ploof_multipart_endpoint)
    {
        return false;
    }
    return Handler.definition.MultipartBodySpec.File != void;
}
