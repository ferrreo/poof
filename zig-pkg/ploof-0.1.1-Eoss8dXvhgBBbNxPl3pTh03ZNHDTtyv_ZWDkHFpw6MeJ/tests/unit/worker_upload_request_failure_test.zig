const std = @import("std");

const multipart = @import("../../src/multipart.zig");
const finalization = @import("../../src/internal/application/multipart_finalization.zig");
const parser = @import("../../src/internal/multipart/parser.zig");
const upload_dispatch = @import("../../src/internal/application/multipart_upload_dispatch.zig");
const upload_finalizer = @import("../../src/internal/upload/finalizer.zig");
const reactor = @import("../../src/internal/runtime/reactor.zig");
const upload_transport = @import("../../src/internal/runtime/upload/transport.zig");
const worker_upload = @import("../../src/internal/runtime/worker/upload_transport.zig");
const worker_upload_metrics = @import("../../src/internal/runtime/worker/upload_metrics.zig");

const Mode = enum { normal, sink_failure, fatal, abort_close };
const paths = [_][:0]const u8{ "a", "b", "c", "d" };

fn TestApp(comptime mode: Mode) type {
    return struct {
        pub const upload_async_sink_present = true;
        pub const upload_request_handles_max: u32 = 4;
        pub const upload_window_max: u32 = 4;
        pub const UploadCatalog = struct {
            pub const sink_types = [_]type{};
        };

        pub const Workspace = struct {
            directory: multipart.FileHandle = .{ .token = 0 },
            handle: multipart.FileHandle = .{ .token = 0 },
            pending: u16 = if (mode == .fatal or mode == .abort_close) 1 else 0b1111,
            submitted: u16 = 0,
            completed: u16 = 0,
            abort_close_pending: bool = false,
            abort_close_submitted: bool = false,
            abort_close_done: bool = false,
            terminal: upload_dispatch.TerminalSource = .none,
            fail_once: bool = mode == .sink_failure,
            cancel_cause: ?upload_finalizer.UpstreamFailure = null,
            cancel_count: u8 = 0,
            finalization_starts: u8 = 0,
        };

        pub fn __peekUploadSubmission(
            workspace: *Workspace,
            _: []u8,
        ) error{TestFailure}!?upload_dispatch.Submission {
            if (mode == .abort_close and workspace.abort_close_pending) return .{
                .lane = .lifecycle,
                .request = .{ .close = .{ .file = workspace.handle } },
                .registry_index = 9,
                .instance_index = 0,
            };
            if (workspace.pending == 0) return null;
            const lane: u8 = @intCast(@ctz(workspace.pending));
            return .{
                .lane = .{ .write = lane },
                .request = if (mode == .fatal or mode == .abort_close)
                    .{ .open = .{
                        .base = .{ .handle = workspace.directory },
                        .path = "malformed.tmp",
                        .access = .write_only,
                        .create = .exclusive,
                        .mode = 0o600,
                    } }
                else
                    .{ .unlink = .{
                        .directory = workspace.directory,
                        .path = paths[lane],
                    } },
                .registry_index = 9,
                .instance_index = 0,
            };
        }

        pub fn __markUploadSubmitted(
            workspace: *Workspace,
            _: []u8,
            lane: upload_dispatch.Lane,
        ) error{TestFailure}!void {
            if (mode == .abort_close and lane == .lifecycle) {
                if (!workspace.abort_close_pending or workspace.abort_close_submitted) {
                    return error.TestFailure;
                }
                workspace.abort_close_pending = false;
                workspace.abort_close_submitted = true;
                return;
            }
            const slot = writeLane(lane) orelse return error.TestFailure;
            const bit = laneBit(slot);
            if (workspace.pending & bit == 0) return error.TestFailure;
            workspace.pending &= ~bit;
            workspace.submitted |= bit;
        }

        pub fn __completeUploadSubmission(
            workspace: *Workspace,
            _: []u8,
            lane: upload_dispatch.Lane,
            completion: multipart.IoCompletion,
        ) error{TestFailure}!void {
            if (mode == .abort_close and lane == .lifecycle) {
                if (!workspace.abort_close_submitted or completion != .failure or
                    completion.failure != .canceled)
                {
                    return error.TestFailure;
                }
                workspace.abort_close_submitted = false;
                workspace.abort_close_done = true;
                return;
            }
            const slot = writeLane(lane) orelse return error.TestFailure;
            const bit = laneBit(slot);
            if (workspace.submitted & bit == 0) return error.TestFailure;
            workspace.submitted &= ~bit;
            if (mode == .fatal) {
                workspace.terminal = .fatal;
                return error.TestFailure;
            }
            if (mode == .abort_close) workspace.handle = switch (completion) {
                .success => |success| switch (success) {
                    .open => |handle| handle,
                    else => return error.TestFailure,
                },
                .failure => return error.TestFailure,
            };
            if (workspace.fail_once and completion == .failure and
                completion.failure == .no_space)
            {
                workspace.fail_once = false;
                workspace.terminal = .sink;
                return error.TestFailure;
            }
            workspace.completed |= bit;
        }

        pub fn __resumeMultipart(
            workspace: *Workspace,
            _: []u8,
        ) error{TestFailure}!parser.Progress {
            return .{
                .consumed = 0,
                .flow = if (workspace.submitted == 0 and workspace.pending == 0)
                    .ready
                else
                    .paused,
            };
        }

        pub fn __cancelMultipart(
            workspace: *Workspace,
            cause: upload_finalizer.UpstreamFailure,
        ) error{TestFailure}!void {
            workspace.cancel_cause = cause;
            workspace.cancel_count += 1;
        }

        pub fn __startMultipartFinalization(
            workspace: *Workspace,
            _: []u8,
        ) error{TestFailure}!upload_dispatch.FinalizationFlow {
            workspace.finalization_starts += 1;
            if (mode == .abort_close) {
                if (workspace.abort_close_done) return .complete;
                if (!workspace.abort_close_submitted) workspace.abort_close_pending = true;
                return .paused;
            }
            return .complete;
        }

        pub fn __multipartFinalizationFlow(
            workspace: *Workspace,
            _: []u8,
        ) error{TestFailure}!upload_dispatch.FinalizationFlow {
            if (mode == .abort_close) {
                return if (workspace.abort_close_done) .complete else .paused;
            }
            return .complete;
        }

        pub fn __multipartFinalizationReport(
            workspace: *Workspace,
            _: []u8,
        ) error{TestFailure}!?finalization.Report {
            return report(workspace.cancel_cause);
        }

        pub fn __multipartTerminalSource(
            workspace: *Workspace,
            _: []u8,
        ) error{TestFailure}!upload_dispatch.TerminalSource {
            return workspace.terminal;
        }
    };
}

fn TestStorage(comptime App: type) type {
    return struct {
        pub const runtime_limits = .{
            .request_slots = 1,
            .timeouts = .{ .startup_io_ns = 10 * std.time.ns_per_s },
        };
        const Phase = enum(u8) { free, live };
        pub const Connection = struct { active_request: ?u16 = 0 };
        const Flags = packed struct(u8) {
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
            generation: u16 = 6,
            sequence: u16 = 30,
            connection_index: u16 = 0,
            flags: Flags = .{},
            workspace: App.Workspace = .{},
        };

        connections: [1]Connection = .{.{}},
        requests: [1]Request = .{.{}},
        body: [1]u8 = .{0},

        pub fn bodyWorkspace(self: *@This(), index: u16) error{Invalid}![]u8 {
            if (index != 0) return error.Invalid;
            return &self.body;
        }
    };
}

const TestReactor = struct {
    pub const file_handle_capacity = 8;
    pub const file_target_capacity = 4;

    submissions: [16]reactor.Submission = undefined,
    count: u8 = 0,

    pub fn submit(self: *TestReactor, submission: reactor.Submission) error{Full}!void {
        if (self.count == self.submissions.len) return error.Full;
        self.submissions[self.count] = submission;
        self.count += 1;
    }

    fn take(self: *TestReactor) reactor.Submission {
        const result = self.submissions[0];
        self.count -= 1;
        std.mem.copyForwards(
            reactor.Submission,
            self.submissions[0..self.count],
            self.submissions[1..][0..self.count],
        );
        return result;
    }
};

test "no-space sink failure aborts request and worker remains ready" {
    const App = TestApp(.sink_failure);
    const Storage = TestStorage(App);
    const Controller = worker_upload.Controller(App, Storage, TestReactor);
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try Controller.init(7);
    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x77} ** 32),
    ) == .registry_ready);
    const owner = runtimeOwner(7);
    storage.requests[0].workspace.directory = try addHandle(
        &controller,
        owner,
        70,
        .directory,
        .read_only,
    );

    _ = try controller.submitParserWork(&storage, &io, 0);
    var targets: [4]reactor.Submission = undefined;
    for (&targets) |*target| target.* = io.take();
    try std.testing.expect(try controller.complete(&storage, &io, .{
        .token = targets[0].token,
        .result = .{ .failure = .no_space },
        .more = false,
    }) == .none);
    try std.testing.expectEqual(@as(u8, 3), io.count);
    var cancels: [3]reactor.Submission = undefined;
    for (&cancels) |*cancel| cancel.* = io.take();
    for (1..4) |index| {
        try std.testing.expect(try controller.complete(&storage, &io, .{
            .token = cancels[index - 1].token,
            .result = .{ .success = .{ .upload_cancel = .canceled } },
            .more = false,
        }) == .none);
        const result = controller.complete(&storage, &io, .{
            .token = targets[index].token,
            .result = .{ .failure = .canceled },
            .more = false,
        });
        if (index != 3) try std.testing.expect(try result == .none) else {
            const event = try result;
            try std.testing.expect(event == .request_finalized);
            try std.testing.expect(event.request_finalized.response_failed);
        }
    }
    try std.testing.expect(controller.registryReady());
    try std.testing.expect(controller.ownershipProven());
    try std.testing.expectEqual(@as(u8, 1), storage.requests[0].workspace.cancel_count);
    try std.testing.expectEqual(@as(u8, 1), storage.requests[0].workspace.finalization_starts);
    const failed_metrics = controller.metricsSnapshot();
    try std.testing.expectEqual(
        @as(u64, 1),
        failed_metrics.recoverable_failures[@intFromEnum(multipart.IoError.no_space)],
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        failed_metrics.recoverable_failures[@intFromEnum(multipart.IoError.canceled)],
    );
    try std.testing.expectEqual(
        @as(u64, 3),
        failed_metrics.cancellations[
            @intFromEnum(
                worker_upload_metrics.CancellationOutcome.target_canceled,
            )
        ],
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        failed_metrics.finalization_outcomes[@intFromEnum(upload_finalizer.Outcome.failed)],
    );

    try controller.retireRequest(&storage, 0);
    storage.requests[0].sequence = 100;
    storage.requests[0].flags = .{};
    storage.requests[0].workspace = .{
        .directory = storage.requests[0].workspace.directory,
        .pending = 1,
        .fail_once = false,
    };
    _ = try controller.submitParserWork(&storage, &io, 0);
    const next = io.take();
    const resumed = try controller.complete(&storage, &io, .{
        .token = next.token,
        .result = .{ .success = .{ .file_unlink = {} } },
        .more = false,
    });
    try std.testing.expect(resumed == .request_resumed);
}

test "canceled abort close is framework-closed before final report and reuse" {
    const App = TestApp(.abort_close);
    const Storage = TestStorage(App);
    const Controller = worker_upload.Controller(App, Storage, TestReactor);
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try Controller.init(8);
    try reachCanceledAbortClose(&controller, &storage, &io, 8);

    try std.testing.expectEqual(@as(u8, 2), io.count);
    try std.testing.expectEqual(@as(u32, 2), controller.activeHandles());
    try std.testing.expectError(
        error.StateInvariant,
        controller.retireRequest(&storage, 0),
    );
    const first = io.take();
    try std.testing.expect(try controller.complete(&storage, &io, .{
        .token = first.token,
        .result = .{ .success = .{ .file_close = {} } },
        .more = false,
    }) == .none);
    try std.testing.expectEqual(@as(u32, 1), controller.activeHandles());
    const second = io.take();
    const event = try controller.complete(&storage, &io, .{
        .token = second.token,
        .result = .{ .success = .{ .file_close = {} } },
        .more = false,
    });
    try std.testing.expect(event == .request_finalized);
    try std.testing.expect(event.request_finalized.response_failed);
    try std.testing.expectEqual(@as(u32, 0), controller.activeHandles());
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try controller.retireRequest(&storage, 0);
    const metrics = controller.metricsSnapshot();
    try std.testing.expectEqual(
        @as(u64, 1),
        metrics.finalization_outcomes[@intFromEnum(upload_finalizer.Outcome.failed)],
    );
}

test "failed framework close poisons ownership and exits before final report" {
    const App = TestApp(.abort_close);
    const Storage = TestStorage(App);
    const Controller = worker_upload.Controller(App, Storage, TestReactor);
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try Controller.init(8);
    try reachCanceledAbortClose(&controller, &storage, &io, 8);

    const cleanup = io.take();
    try std.testing.expectError(error.TransportFailure, controller.complete(
        &storage,
        &io,
        .{
            .token = cleanup.token,
            .result = .{ .failure = .canceled },
            .more = false,
        },
    ));
    try std.testing.expect(!controller.ownershipProven());
    try std.testing.expectError(
        error.StateInvariant,
        controller.retireRequest(&storage, 0),
    );
    const metrics = controller.metricsSnapshot();
    try std.testing.expectEqual(
        @as(u64, 0),
        metrics.finalization_outcomes[@intFromEnum(upload_finalizer.Outcome.failed)],
    );
}

test "fatal malformed sink closes all request handles before worker stop" {
    const App = TestApp(.fatal);
    const Storage = TestStorage(App);
    const Controller = worker_upload.Controller(App, Storage, TestReactor);
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try Controller.init(8);
    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x88} ** 32),
    ) == .registry_ready);
    const owner = requestOwner(8, &storage.requests[0]);
    storage.requests[0].workspace.directory = try addHandle(
        &controller,
        owner,
        80,
        .directory,
        .read_only,
    );

    _ = try controller.submitParserWork(&storage, &io, 0);
    const opened = io.take();
    try std.testing.expect(try controller.complete(&storage, &io, .{
        .token = opened.token,
        .result = .{ .success = .{ .file_open = .{ .value = 81 } } },
        .more = false,
    }) == .none);
    try std.testing.expectEqual(@as(u8, 2), io.count);
    const first_close = io.take();
    const second_close = io.take();
    try std.testing.expect(try controller.complete(&storage, &io, .{
        .token = second_close.token,
        .result = .{ .success = .{ .file_close = {} } },
        .more = false,
    }) == .none);
    try std.testing.expectError(error.ApplicationFailure, controller.complete(
        &storage,
        &io,
        .{
            .token = first_close.token,
            .result = .{ .success = .{ .file_close = {} } },
            .more = false,
        },
    ));
    try std.testing.expectEqual(@as(u32, 0), controller.pending());
    try std.testing.expectEqual(@as(u32, 0), controller.activeHandles());
    try std.testing.expect(controller.ownershipProven());
    try std.testing.expectEqual(@as(u8, 0), storage.requests[0].workspace.cancel_count);
    const fatal_metrics = controller.metricsSnapshot();
    try std.testing.expectEqual(
        @as(u64, 1),
        fatal_metrics.fatal_failures[
            @intFromEnum(
                worker_upload_metrics.FatalFailureClass.application,
            )
        ],
    );
    try std.testing.expect(try controller.beginRegistryStop(&storage, &io) == .registry_stopped);
}

test "disconnect and send timeout after committed finalization do not finalize twice" {
    const App = TestApp(.normal);
    const Storage = TestStorage(App);
    const Controller = worker_upload.Controller(App, Storage, TestReactor);
    var storage = Storage{};
    var io = TestReactor{};
    var controller = try Controller.init(9);
    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x99} ** 32),
    ) == .registry_ready);
    const owner = runtimeOwner(9);
    storage.requests[0].workspace.directory = try addHandle(
        &controller,
        owner,
        90,
        .directory,
        .read_only,
    );
    storage.requests[0].workspace.pending = 1;
    storage.requests[0].workspace.finalization_starts = 1;

    _ = try controller.submitParserWork(&storage, &io, 0);
    storage.requests[0].flags.upload_finalizing = true;
    const target = io.take();
    const finalized = try controller.complete(&storage, &io, .{
        .token = target.token,
        .result = .{ .success = .{ .file_unlink = {} } },
        .more = false,
    });
    try std.testing.expect(finalized == .request_finalized);
    try std.testing.expect(!finalized.request_finalized.response_failed);
    try std.testing.expect(try controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .peer_disconnect,
    ) == .none);
    try std.testing.expect(try controller.beginRequestAbort(
        &storage,
        &io,
        0,
        .framework_canceled,
    ) == .none);
    try std.testing.expectEqual(@as(u8, 1), storage.requests[0].workspace.finalization_starts);
    try std.testing.expectEqual(@as(u8, 0), storage.requests[0].workspace.cancel_count);
    try std.testing.expectEqual(@as(u8, 0), io.count);
    const metrics = controller.metricsSnapshot();
    try std.testing.expectEqual(
        @as(u64, 1),
        metrics.finalization_outcomes[@intFromEnum(upload_finalizer.Outcome.committed)],
    );
}

fn reachCanceledAbortClose(
    controller: anytype,
    storage: anytype,
    io: *TestReactor,
    worker: u16,
) !void {
    try std.testing.expect(try controller.beginRegistryStart(
        storage,
        io,
        &([_]u8{0x89} ** 32),
    ) == .registry_ready);
    const owner = requestOwner(worker, &storage.requests[0]);
    storage.requests[0].workspace.directory = try addHandle(
        controller,
        owner,
        80,
        .directory,
        .read_only,
    );
    _ = try controller.submitParserWork(storage, io, 0);
    const opened = io.take();
    try std.testing.expect(try controller.complete(storage, io, .{
        .token = opened.token,
        .result = .{ .success = .{ .file_open = .{ .value = 81 } } },
        .more = false,
    }) == .request_resumed);
    try std.testing.expect(try controller.beginRequestAbort(
        storage,
        io,
        0,
        .peer_disconnect,
    ) == .none);
    const abort_close = io.take();
    try std.testing.expect(abort_close.operation == .file_close);
    try std.testing.expect(try controller.complete(storage, io, .{
        .token = abort_close.token,
        .result = .{ .failure = .canceled },
        .more = false,
    }) == .none);
}

fn requestOwner(worker: u16, request: anytype) upload_transport.Owner {
    return .{
        .scope = .request,
        .registry_index = 9,
        .instance_index = 0,
        .slot = .{
            .worker_index = worker,
            .index = 0,
            .generation = request.generation,
        },
    };
}

fn runtimeOwner(worker: u16) upload_transport.Owner {
    return .{
        .scope = .runtime,
        .registry_index = 9,
        .instance_index = 0,
        .slot = .{
            .worker_index = worker,
            .index = reactor.upload_runtime_control_slot,
            .generation = 1,
        },
    };
}

fn addHandle(
    controller: anytype,
    owner: upload_transport.Owner,
    raw_fd: i32,
    kind: multipart.OpenKind,
    access: multipart.Access,
) !multipart.FileHandle {
    const handle = try controller.transport.table().reserveOpen(owner);
    try controller.transport.table().completeOpenPositive(
        handle,
        owner,
        raw_fd,
        kind,
        access,
        .none,
    );
    return handle;
}

fn writeLane(lane: upload_dispatch.Lane) ?u8 {
    return switch (lane) {
        .write => |slot| if (slot < 4) slot else null,
        .lifecycle => null,
    };
}

fn laneBit(lane: u8) u16 {
    return @as(u16, 1) << @intCast(lane);
}

fn report(cause: ?upload_finalizer.UpstreamFailure) finalization.Report {
    return .{
        .outcome = if (cause == null) .committed else .failed,
        .primary = if (cause) |value| .{
            .class = .{ .upstream = value },
            .identity = null,
        } else null,
        .instance_count = 0,
        .commit_attempted_count = 0,
        .commit_completed_count = 0,
        .abort_attempted_count = 0,
        .abort_completed_count = 0,
        .cleanup_failure_count = 0,
    };
}
