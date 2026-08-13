pub const std = @import("std");

pub const application = @import("../../src/application.zig");
pub const endpoint = @import("../../src/endpoint.zig");
pub const multipart = @import("../../src/multipart.zig");
pub const multipart_finalization = @import(
    "../../src/internal/application/multipart_finalization.zig",
);
pub const application_types = @import("../../src/internal/application/types.zig");
pub const multipart_parser = @import("../../src/internal/multipart/parser.zig");
pub const upload_finalizer = @import("../../src/internal/upload/finalizer.zig");
pub const upload_dispatch = @import("../../src/internal/application/multipart_upload_dispatch.zig");
pub const reactor = @import("../../src/internal/runtime/reactor.zig");
pub const upload_transport = @import("../../src/internal/runtime/upload/transport.zig");
pub const worker_upload_transport = @import(
    "../../src/internal/runtime/worker/upload_transport.zig",
);
pub const upload_metrics = @import("../../src/internal/runtime/worker/upload_metrics.zig");
pub const response = @import("../../src/response.zig");
pub const route = @import("../../src/route.zig");

pub const Stage = enum(u8) {
    open_pending,
    open_submitted,
    close_pending,
    close_submitted,
    done,
};

pub fn GeneratedSink(comptime requirements: multipart.IoRequirements) type {
    return struct {
        pub const ploof_multipart_sink = true;
        pub const State = multipart.DiscardSink.State;
        pub const WriteState = multipart.DiscardSink.WriteState;
        pub const Summary = multipart.DiscardSink.Summary;
        pub const BeginInput = multipart.DiscardSink.BeginInput;
        pub const Runtime = multipart.DiscardSink.Runtime;
        pub const StartupState = multipart.DiscardSink.StartupState;
        pub const io_requirements = requirements;
        pub const request_handles_max = multipart.DiscardSink.request_handles_max;
        pub const runtime_handles_max = multipart.DiscardSink.runtime_handles_max;
        pub const Error = multipart.DiscardSink.Error;
        pub const initial_state = multipart.DiscardSink.initial_state;
        pub const initial_write_state = multipart.DiscardSink.initial_write_state;
        pub const initial_startup_state = multipart.DiscardSink.initial_startup_state;
        pub const runtimeStart = multipart.DiscardSink.runtimeStart;
        pub const runtimeStop = multipart.DiscardSink.runtimeStop;
        pub const begin = multipart.DiscardSink.begin;
        pub const write = multipart.DiscardSink.write;
        pub const finish = multipart.DiscardSink.finish;
        pub const commit = multipart.DiscardSink.commit;
        pub const abort = multipart.DiscardSink.abort;
    };
}

pub const GeneratedAsyncSink = GeneratedSink(.{ .sync = true });
pub const GeneratedSyncSink = GeneratedSink(.{});
pub const GeneratedContext = application.Context(void, response.standard_head_limits);

pub fn GeneratedFileConsumer(comptime Spec: type, comptime Definition: type) type {
    return struct {
        pub const State = void;

        pub fn fileStart(
            _: @This(),
            _: *GeneratedContext,
            _: *State,
            _: Spec.FileStart,
        ) Spec.FileAdmission(GeneratedContext.ResponseType) {
            return .{ .accept = .{ .upload = {} } };
        }

        pub fn complete(
            _: @This(),
            context: *GeneratedContext,
            _: *State,
            _: Definition.InputType,
            _: Spec.Summaries,
        ) multipart.Decision(GeneratedContext.ResponseType) {
            return multipart.commit(context.empty(.no_content));
        }
    };
}

pub const generated_async_spec = multipart.decode(.{
    .upload = multipart.file(GeneratedAsyncSink, multipart.optional),
}, .{
    .limits = .{ .parts_max = 1, .files_max = 1 },
    .upload = .{ .window = 4, .chunk_bytes = 32 },
});
pub const GeneratedAsyncDefinition = endpoint.Endpoint(.{ .body = generated_async_spec });
pub const generated_async_handler = GeneratedAsyncDefinition.handle(
    GeneratedFileConsumer(@TypeOf(generated_async_spec), GeneratedAsyncDefinition){},
);

pub const generated_sync_spec = multipart.decode(.{
    .upload = multipart.file(GeneratedSyncSink, multipart.required),
}, .{
    .limits = .{ .parts_max = 1, .files_max = 1 },
    .upload = .{ .window = 13, .chunk_bytes = 32 },
});
pub const GeneratedSyncDefinition = endpoint.Endpoint(.{ .body = generated_sync_spec });
pub const generated_sync_handler = GeneratedSyncDefinition.handle(
    GeneratedFileConsumer(@TypeOf(generated_sync_spec), GeneratedSyncDefinition){},
);

pub const generated_field_spec = multipart.decode(.{
    .token = multipart.bytesField(multipart.optional),
}, .{ .limits = .{ .parts_max = 1, .files_max = 0 } });
pub const GeneratedFieldDefinition = endpoint.Endpoint(.{ .body = generated_field_spec });
pub const GeneratedFieldConsumer = struct {
    pub const State = void;

    pub fn field(_: @This(), _: *State, _: @TypeOf(generated_field_spec).Field) void {}

    pub fn complete(
        _: @This(),
        context: *GeneratedContext,
        _: *State,
        _: GeneratedFieldDefinition.InputType,
        _: @TypeOf(generated_field_spec).Summaries,
    ) multipart.Decision(GeneratedContext.ResponseType) {
        return multipart.commit(context.empty(.no_content));
    }
};
pub const generated_field_handler = GeneratedFieldDefinition.handle(GeneratedFieldConsumer{});

pub const GeneratedApp = application.Application(.{
    .State = void,
    .routes = .{
        route.post("/async", generated_async_handler),
        route.post("/sync", generated_sync_handler),
        route.post("/field", generated_field_handler),
    },
});

pub const TestApp = struct {
    pub const upload_async_sink_present = true;
    pub const upload_request_handles_max: u32 = 4;
    pub const upload_window_max: u32 = 2;
    pub const upload_finalization_instances_max: u16 = 1;
    pub const upload_route_profiles = [_]struct { route_id: u16, window: u8 }{
        .{ .route_id = 12, .window = 2 },
    };
    pub const UploadCatalog = struct {
        pub const sink_types = [_]type{};
    };

    pub const Workspace = struct {
        route_id: u16 = 12,
        multipart_finalization: application_types.MultipartFinalization = .required,
        stage: Stage = .open_pending,
        directory: multipart.FileHandle = .{ .token = 0 },
        handle: multipart.FileHandle = .{ .token = 0 },
        completion_count: u8 = 0,
        resume_count: u8 = 0,
        cancel_cause: ?upload_finalizer.UpstreamFailure = null,
        cleanup_failure: bool = false,
    };

    pub fn __multipartUploadRouteId(workspace: *Workspace) error{}!u16 {
        return workspace.route_id;
    }

    pub fn __peekUploadSubmission(
        workspace: *Workspace,
        _: []u8,
    ) error{TestFailure}!?upload_dispatch.Submission {
        return switch (workspace.stage) {
            .open_pending => .{
                .lane = .{ .write = 2 },
                .request = .{ .open = .{
                    .base = .{ .handle = workspace.directory },
                    .path = "upload.tmp",
                    .access = .write_only,
                    .create = .exclusive,
                    .mode = 0o600,
                } },
                .registry_index = 7,
                .instance_index = 3,
            },
            .close_pending => .{
                .lane = .lifecycle,
                .request = .{ .close = .{ .file = workspace.handle } },
                .registry_index = 7,
                .instance_index = 3,
            },
            .open_submitted, .close_submitted, .done => null,
        };
    }

    pub fn __markUploadSubmitted(
        workspace: *Workspace,
        _: []u8,
        lane: upload_dispatch.Lane,
    ) error{TestFailure}!void {
        switch (workspace.stage) {
            .open_pending => {
                if (lane != .write or lane.write != 2) return error.TestFailure;
                workspace.stage = .open_submitted;
            },
            .close_pending => {
                if (lane != .lifecycle) return error.TestFailure;
                workspace.stage = .close_submitted;
            },
            else => return error.TestFailure,
        }
    }

    pub fn __completeUploadSubmission(
        workspace: *Workspace,
        _: []u8,
        lane: upload_dispatch.Lane,
        completion: multipart.IoCompletion,
    ) error{TestFailure}!void {
        switch (workspace.stage) {
            .open_submitted => {
                if (lane != .write or lane.write != 2) return error.TestFailure;
                workspace.handle = switch (completion) {
                    .success => |success| switch (success) {
                        .open => |handle| handle,
                        else => return error.TestFailure,
                    },
                    .failure => return error.TestFailure,
                };
                workspace.stage = .close_pending;
            },
            .close_submitted => {
                if (lane != .lifecycle or completion != .success or
                    completion.success != .close)
                {
                    return error.TestFailure;
                }
                workspace.stage = .done;
            },
            else => return error.TestFailure,
        }
        workspace.completion_count += 1;
    }

    pub fn __resumeMultipart(
        workspace: *Workspace,
        _: []u8,
    ) error{TestFailure}!multipart_parser.Progress {
        if (workspace.stage != .done) return .{ .consumed = 0, .flow = .paused };
        workspace.resume_count += 1;
        return .{ .consumed = 0, .flow = .ready };
    }

    pub fn __multipartFinalizationFlow(
        workspace: *Workspace,
        _: []u8,
    ) error{TestFailure}!upload_dispatch.FinalizationFlow {
        if (workspace.cancel_cause == null or workspace.stage == .done) return .complete;
        if (workspace.stage == .close_pending or workspace.stage == .close_submitted) {
            return .paused;
        }
        return error.TestFailure;
    }

    pub fn __startMultipartFinalization(
        workspace: *Workspace,
        _: []u8,
    ) error{TestFailure}!upload_dispatch.FinalizationFlow {
        const flow = try __multipartFinalizationFlow(workspace, &.{});
        if (flow == .complete) workspace.multipart_finalization = .failed;
        return flow;
    }

    pub fn __cancelMultipart(
        workspace: *Workspace,
        cause: upload_finalizer.UpstreamFailure,
    ) error{TestFailure}!void {
        workspace.cancel_cause = cause;
    }

    pub fn __multipartFinalizationReport(
        workspace: *Workspace,
        _: []u8,
    ) error{TestFailure}!?multipart_finalization.Report {
        return .{
            .outcome = if (workspace.cancel_cause == null) .committed else .failed,
            .primary = if (workspace.cancel_cause) |cause| .{
                .class = .{ .upstream = cause },
                .identity = null,
            } else null,
            .instance_count = @intFromBool(workspace.cleanup_failure),
            .commit_attempted_count = 0,
            .commit_completed_count = 0,
            .abort_attempted_count = 0,
            .abort_completed_count = 0,
            .cleanup_failure_count = @intFromBool(workspace.cleanup_failure),
        };
    }

    pub fn __multipartFinalizationCleanupFailure(
        workspace: *Workspace,
        _: []u8,
        index: u16,
    ) error{TestFailure}!?multipart_finalization.CleanupFailure {
        if (!workspace.cleanup_failure or index != 0) return null;
        return .{
            .class = .sink,
            .identity = .{ .registry_index = 7, .instance_index = 3 },
        };
    }

    pub fn __multipartFinalizationOutcome(
        _: *Workspace,
        _: []u8,
    ) error{TestFailure}!?upload_dispatch.FinalizationOutcome {
        return .committed;
    }

    pub fn __multipartTerminalSource(
        _: *Workspace,
        _: []u8,
    ) error{TestFailure}!upload_dispatch.TerminalSource {
        return .fatal;
    }
};

pub const TestStorage = struct {
    pub const runtime_limits = .{
        .request_slots = 1,
        .timeouts = .{ .startup_io_ns = 10 * std.time.ns_per_s },
    };
    const Phase = enum(u8) { free, live };
    pub const Connection = struct { active_request: ?u16 = 0 };
    const RequestFlags = packed struct(u8) {
        response_dirty_full: bool = false,
        upload_inflight: bool = false,
        upload_parser_paused: bool = false,
        upload_finalizing: bool = false,
        upload_response_failed: bool = false,
        upload_cancel_requested: bool = false,
        upload_cancel_peer: bool = false,
        upload_rejection_pending: bool = false,
    };
    pub const Request = struct {
        phase: Phase = .live,
        generation: u16 = 9,
        sequence: u16 = 11,
        connection_index: u16 = 0,
        flags: RequestFlags = .{},
        workspace: TestApp.Workspace = .{},
    };

    connections: [1]Connection = .{.{}},
    requests: [1]Request = .{.{}},
    body: [1]u8 = .{0},

    pub fn bodyWorkspace(self: *TestStorage, request_index: u16) error{Invalid}![]u8 {
        if (request_index != 0) return error.Invalid;
        return &self.body;
    }
};

pub const TestReactor = struct {
    pub const file_handle_capacity = 4;
    pub const file_target_capacity = 2;

    submissions: [8]reactor.Submission = undefined,
    submission_head: u8 = 0,
    submission_count: u8 = 0,
    submit_count: u8 = 0,
    submit_attempt_count: u8 = 0,
    fail_submit_attempt: ?u8 = null,
    fail_next_submit: bool = false,

    pub fn submit(self: *TestReactor, submission: reactor.Submission) error{Full}!void {
        self.submit_attempt_count += 1;
        if (self.fail_submit_attempt == self.submit_attempt_count) return error.Full;
        if (self.fail_next_submit) {
            self.fail_next_submit = false;
            return error.Full;
        }
        if (self.submission_count == self.submissions.len) return error.Full;
        const index = (self.submission_head + self.submission_count) %
            @as(u8, self.submissions.len);
        self.submissions[index] = submission;
        self.submission_count += 1;
        self.submit_count += 1;
    }

    pub fn take(self: *TestReactor) reactor.Submission {
        std.debug.assert(self.submission_count != 0);
        const submission = self.submissions[self.submission_head];
        self.submission_head = (self.submission_head + 1) %
            @as(u8, self.submissions.len);
        self.submission_count -= 1;
        return submission;
    }

    pub fn takeKind(
        self: *TestReactor,
        kind: reactor.OperationKind,
    ) reactor.Submission {
        var offset: u8 = 0;
        while (offset < self.submission_count) : (offset += 1) {
            const index = (self.submission_head + offset) %
                @as(u8, self.submissions.len);
            if (std.meta.activeTag(self.submissions[index].operation) != kind) continue;
            const submission = self.submissions[index];
            var shift = offset;
            while (shift + 1 < self.submission_count) : (shift += 1) {
                const current = (self.submission_head + shift) %
                    @as(u8, self.submissions.len);
                const next = (current + 1) % @as(u8, self.submissions.len);
                self.submissions[current] = self.submissions[next];
            }
            self.submission_count -= 1;
            return submission;
        }
        unreachable;
    }
};

pub const generated_workspace_bytes: usize = @intCast(GeneratedApp.body_workspace_bytes_max);
pub const GeneratedStorage = struct {
    pub const runtime_limits = .{
        .request_slots = 1,
        .timeouts = .{ .startup_io_ns = 10 * std.time.ns_per_s },
    };
    const Phase = enum(u8) { free, live };
    pub const Connection = struct { active_request: ?u16 = 0 };
    const RequestFlags = packed struct(u8) {
        response_dirty_full: bool = false,
        upload_inflight: bool = false,
        upload_parser_paused: bool = false,
        upload_finalizing: bool = false,
        upload_response_failed: bool = false,
        upload_cancel_requested: bool = false,
        upload_cancel_peer: bool = false,
        upload_rejection_pending: bool = false,
    };
    pub const Request = struct {
        phase: Phase = .live,
        generation: u16 = 17,
        sequence: u16 = 23,
        connection_index: u16 = 0,
        flags: RequestFlags = .{},
        workspace: GeneratedApp.Workspace = .{},
    };

    connections: [1]Connection = .{.{}},
    requests: [1]Request = .{.{}},
    body: [generated_workspace_bytes]u8 align(GeneratedApp.body_workspace_alignment) =
        undefined,
    upload_registry: GeneratedApp.UploadRegistry = .{},

    pub fn bodyWorkspace(self: *@This(), request_index: u16) error{Invalid}![]u8 {
        if (request_index != 0) return error.Invalid;
        return &self.body;
    }
};

pub const GeneratedReactor = struct {
    pub const file_handle_capacity = 4;
    pub const file_target_capacity = 4;

    submit_count: u8 = 0,

    pub fn submit(self: *@This(), _: reactor.Submission) error{Full}!void {
        self.submit_count += 1;
    }
};

pub const GeneratedController = worker_upload_transport.Controller(
    GeneratedApp,
    GeneratedStorage,
    GeneratedReactor,
);

pub fn generatedInput(path: []const u8) application.Input {
    return .{
        .method = "POST",
        .path = path,
        .raw_target = path,
        .raw_path = path,
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
    };
}

pub fn beginGenerated(
    storage: *GeneratedStorage,
    state: *void,
    output: []u8,
    path: []const u8,
) !void {
    const input = generatedInput(path);
    var route_workspace = GeneratedApp.RouteSearchWorkspace{};
    var plan = GeneratedApp.plan(input, &route_workspace);
    try GeneratedApp.__refinePlanBody(
        &plan,
        plan.body.selectMedia(0) orelse return error.TestUnexpectedResult,
    );
    const head = try GeneratedApp.prepareHeadPlannedIn(
        state,
        &storage.requests[0].workspace,
        &storage.body,
        output,
        &plan,
        .{},
    );
    if (head != .receive_body) return error.TestUnexpectedResult;
    try GeneratedApp.__beginMultipart(
        &storage.requests[0].workspace,
        &storage.body,
        "B",
        &storage.upload_registry,
    );
}

pub fn startGeneratedSync(storage: *GeneratedStorage) !void {
    const started = try storage.upload_registry.driver(GeneratedSyncSink).startRuntime(.{
        .worker_index = 0,
        .entropy = &([_]u8{0xa5} ** 32),
    });
    if (started != .done) return error.TestUnexpectedResult;
}

pub const generated_sync_wire = "--B\r\n" ++
    "Content-Disposition: form-data; name=upload; filename=x\r\n" ++
    "Content-Type: application/octet-stream\r\n\r\n" ++
    "data\r\n--B--";

pub const Controller = worker_upload_transport.Controller(TestApp, TestStorage, TestReactor);

pub fn expectFailureIdentity(controller: *Controller, registry: u16, instance: u16) !void {
    const identity = controller.requests.failureIdentity().?;
    try std.testing.expectEqual(registry, identity.registry_index);
    try std.testing.expectEqual(instance, identity.instance_index);
}

pub fn expectFatalMetricIdentity(controller: *Controller, registry: u16, instance: u16) !void {
    const snapshot = controller.metricsSnapshot();
    if (snapshot.event_count == 0) return error.TestUnexpectedResult;
    const event = snapshot.events[snapshot.event_count - 1];
    const fatal = switch (event.detail) {
        .fatal_failure => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const identity = fatal.identity orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(registry, identity.registry_index);
    try std.testing.expectEqual(instance, identity.instance_index);
    try std.testing.expectEqual(@as(?u16, 12), event.route_id);
    const route_snapshot = controller.routeMetricsSnapshot(12).?;
    const backend = @intFromEnum(upload_metrics.FatalFailureClass.backend);
    try std.testing.expectEqual(@as(u64, 1), route_snapshot.cell.fatal_failures[backend]);
    try std.testing.expectEqual(
        snapshot.fatal_failures[backend],
        route_snapshot.cell.fatal_failures[backend],
    );
}

pub fn runtimeOwner(worker_index: u16, registry_index: u16) upload_transport.Owner {
    return .{
        .scope = .runtime,
        .registry_index = registry_index,
        .instance_index = 0,
        .slot = .{
            .worker_index = worker_index,
            .index = reactor.upload_runtime_control_slot,
            .generation = 1,
        },
    };
}

pub fn seedDirectory(controller: *Controller, storage: *TestStorage, worker_index: u16) !void {
    const token = try reactor.OperationToken.init(.{
        .kind = .file_open,
        .worker_index = worker_index,
        .slot_index = reactor.upload_runtime_control_slot,
        .slot_generation = 1,
        .sequence = 1,
    });
    _ = try controller.transport.prepareTarget(
        runtimeOwner(worker_index, 7),
        token,
        undefined,
        .{ .open = .{
            .base = .working_directory,
            .path = ".",
            .access = .read_only,
            .kind = .directory,
        } },
    );
    try controller.transport.markSubmitted(token);
    const directory = (try controller.transport.complete(.{
        .token = token,
        .result = .{ .success = .{ .file_open = .{ .value = 80 } } },
        .more = false,
    })).?;
    storage.requests[0].workspace.directory = directory.completion.success.open;
}

test {
    _ = @import("worker_upload_transport_test_part_1.zig");
}
