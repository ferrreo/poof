const std = @import("std");

const forwarding = @import("../forwarding.zig");
const listener = @import("../internal/runtime/listener.zig");
const memory_budget = @import("../internal/runtime/memory_budget.zig");
const file_sink_diagnostic = @import("../internal/multipart/file_sink_startup_diagnostic.zig");
const reactor = @import("../internal/runtime/reactor.zig");
const static_file = @import("../static_file.zig");
const worker_live_static = @import("../internal/runtime/worker/live_static.zig");
const startup = @import("../startup.zig");

pub const rendered_bytes_max: usize = @max(
    file_sink_diagnostic.rendered_bytes_max + 256,
    static_file.root_bytes_hard_max + 256,
);

comptime {
    std.debug.assert(rendered_bytes_max >= file_sink_diagnostic.rendered_bytes_max + 256);
    std.debug.assert(rendered_bytes_max >= static_file.root_bytes_hard_max + 256);
}

pub const Cleanup = enum(u8) {
    clean,
    process_exit_required,
};

pub const WorkerStage = enum(u8) {
    command,
    backend,
    storage,
    worker,
    clock,
    start,
    thread,
};

pub const ListenerFailure = struct {
    worker_index: u16,
    problem: listener.Failure,
};

pub const StaticRootFailure = struct {
    root_index: u16,
    path: []const u8,
    problem: reactor.CompletionError,
    kind: worker_live_static.StartupFailureKind = .io,
};

pub const WorkerFailure = struct {
    worker_index: u16,
    stage: WorkerStage,
    problem: anyerror,
    cleanup: Cleanup = .clean,
    static_root: ?StaticRootFailure = null,
    file_sink: ?file_sink_diagnostic.Diagnostic = null,
};

pub const ForwardingFailure = forwarding.ProfileFailure;

pub const ConfigurationIssue = enum(u8) {
    worker_count_zero,
    worker_count_above_compiled_max,
    shutdown_duration_overflow,
    server_already_started,
    startup_interrupted,
    access_log_descriptor_required,
    access_log_descriptor_unexpected,
    readiness_already_bound,
};

pub const Failure = union(enum) {
    configuration: ConfigurationIssue,
    capability: startup.Failure,
    application: startup.ApplicationFailure,
    forwarding: ForwardingFailure,
    listener: ListenerFailure,
    worker: WorkerFailure,
    completion_counter: anyerror,
    memory_budget: anyerror,
    access_logger: anyerror,
    metrics_service: anyerror,

    pub fn requiresProcessExit(failure: Failure) bool {
        return switch (failure) {
            .configuration => false,
            .capability => |value| value.cleanup_status == .process_exit_required,
            .worker => |value| value.cleanup == .process_exit_required,
            else => false,
        };
    }

    pub fn render(failure: Failure, output: []u8) std.fmt.BufPrintError![]const u8 {
        return switch (failure) {
            .configuration => |issue| std.fmt.bufPrint(
                output,
                "PLOOF startup failure: configuration={s}\n",
                .{@tagName(issue)},
            ),
            .capability => |value| value.render(output),
            .application => |value| startup.renderApplicationFailure(value, output),
            .forwarding => |value| renderForwarding(value, output),
            .listener => |value| renderListener(value, output),
            .worker => |value| renderWorker(value, output),
            .completion_counter => |problem| std.fmt.bufPrint(
                output,
                "PLOOF startup failure: completion counter error={s}\n",
                .{@errorName(problem)},
            ),
            .memory_budget => |problem| std.fmt.bufPrint(
                output,
                "PLOOF startup failure: memory budget error={s}\n",
                .{@errorName(problem)},
            ),
            .access_logger => |problem| std.fmt.bufPrint(
                output,
                "PLOOF startup failure: access logger error={s}\n",
                .{@errorName(problem)},
            ),
            .metrics_service => |problem| std.fmt.bufPrint(
                output,
                "PLOOF startup failure: OpenMetrics service error={s}\n",
                .{@errorName(problem)},
            ),
        };
    }
};

fn renderWorker(
    failure: WorkerFailure,
    output: []u8,
) std.fmt.BufPrintError![]const u8 {
    if (failure.file_sink) |sink| {
        const prefix = try std.fmt.bufPrint(
            output,
            "PLOOF startup failure: worker={d} stage={s} error={s} cleanup={s} ",
            .{
                failure.worker_index,
                @tagName(failure.stage),
                @errorName(failure.problem),
                @tagName(failure.cleanup),
            },
        );
        const detail = try sink.render(output[prefix.len..]);
        return output[0 .. prefix.len + detail.len];
    }
    if (failure.static_root) |root| {
        return std.fmt.bufPrint(
            output,
            "PLOOF startup failure: worker={d} stage={s} error={s} " ++
                "static_root={d} path={s} static_error={s} io_error={s} cleanup={s}\n",
            .{
                failure.worker_index,
                @tagName(failure.stage),
                @errorName(failure.problem),
                root.root_index,
                root.path,
                @tagName(root.kind),
                @tagName(root.problem),
                @tagName(failure.cleanup),
            },
        );
    }
    return std.fmt.bufPrint(
        output,
        "PLOOF startup failure: worker={d} stage={s} error={s} cleanup={s}\n",
        .{
            failure.worker_index,
            @tagName(failure.stage),
            @errorName(failure.problem),
            @tagName(failure.cleanup),
        },
    );
}

pub const MemoryReport = struct {
    runtime: memory_budget.Report,
    server_value_bytes: u64,
    /// Read-only comptime route index; not included in caller-owned totals.
    application_route_index_static_bytes: u64 = 0,
    worker_thread_requested_stack_bytes: u64,
    process_worker_thread_requested_stack_bytes: u64,
};

pub const Ready = struct {
    address: listener.Address,
    worker_count: u16,
    memory: MemoryReport,
};

pub const Result = union(enum) {
    ready: Ready,
    failure: Failure,
};

fn renderForwarding(
    failure: ForwardingFailure,
    output: []u8,
) std.fmt.BufPrintError![]const u8 {
    if (failure.trusted_matcher_index) |index| {
        return std.fmt.bufPrint(
            output,
            "PLOOF startup failure: forwarding error={s} matcher={d}\n",
            .{ @errorName(failure.reason), index },
        );
    }
    return std.fmt.bufPrint(
        output,
        "PLOOF startup failure: forwarding error={s}\n",
        .{@errorName(failure.reason)},
    );
}

fn renderListener(
    failure: ListenerFailure,
    output: []u8,
) std.fmt.BufPrintError![]const u8 {
    return switch (failure.problem) {
        .config => |issue| std.fmt.bufPrint(
            output,
            "PLOOF startup failure: worker={d} listener config={s}\n",
            .{ failure.worker_index, @tagName(issue) },
        ),
        .syscall => |problem| std.fmt.bufPrint(
            output,
            "PLOOF startup failure: worker={d} listener stage={s} errno={d}\n",
            .{ failure.worker_index, @tagName(problem.stage), @intFromEnum(problem.errno) },
        ),
        .bound_address => |issue| std.fmt.bufPrint(
            output,
            "PLOOF startup failure: worker={d} listener bound_address={s}\n",
            .{ failure.worker_index, @tagName(issue) },
        ),
    };
}

test "startup failure render is bounded and retains typed detail" {
    var output: [256]u8 = undefined;
    const failure = Failure{ .worker = .{
        .worker_index = 3,
        .stage = .backend,
        .problem = error.RequiredFeatureMissing,
        .cleanup = .process_exit_required,
    } };
    const rendered = try failure.render(&output);
    try std.testing.expectEqualStrings(
        "PLOOF startup failure: worker=3 stage=backend " ++
            "error=RequiredFeatureMissing cleanup=process_exit_required\n",
        rendered,
    );
    try std.testing.expect(failure.requiresProcessExit());
}

test "startup failure renders live static root detail" {
    var output: [320]u8 = undefined;
    const failure = Failure{ .worker = .{
        .worker_index = 1,
        .stage = .start,
        .problem = error.StaticFailure,
        .static_root = .{
            .root_index = 2,
            .path = "/srv/assets",
            .problem = .permission_denied,
            .kind = .deadline,
        },
    } };
    const rendered = try failure.render(&output);
    try std.testing.expectEqualStrings(
        "PLOOF startup failure: worker=1 stage=start error=StaticFailure " ++
            "static_root=2 path=/srv/assets static_error=deadline " ++
            "io_error=permission_denied cleanup=clean\n",
        rendered,
    );
}

test "startup failure retains bounded FileSink deadline diagnostic" {
    const sink = file_sink_diagnostic.Diagnostic{
        .sink_registry_index = 7,
        .failure = .{
            .code = "PLOOF-E3519",
            .root = "/srv/uploads",
            .staging = .named_staging,
            .mode = 0o600,
            .durability = .crash_durable,
            .phase = .open_root,
            .operation = .open,
            .cause = file_sink_diagnostic.Cause.init(error.StartupDeadline),
            .cleanup = .{},
            .anonymous_compatibility_hint = false,
            .deadline = .{
                .kind = .deadline,
                .timeout_ns = 10,
                .started_ns = 20,
                .deadline_ns = 30,
            },
        },
    };
    const failure = Failure{ .worker = .{
        .worker_index = 2,
        .stage = .start,
        .problem = error.FileSinkStartupFailed,
        .file_sink = sink,
    } };
    var output: [rendered_bytes_max]u8 = undefined;
    const rendered = try failure.render(&output);
    try std.testing.expect(rendered.len <= rendered_bytes_max);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "startup_deadline(kind=deadline,timeout_ns=10",
    ) != null);
}
