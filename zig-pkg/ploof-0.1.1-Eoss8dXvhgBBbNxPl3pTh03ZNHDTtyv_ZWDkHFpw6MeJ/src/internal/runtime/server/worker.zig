const std = @import("std");

const startup_api = @import("../../../server/startup.zig");
const worker_runtime = @import("../worker.zig");

const flush_retries_max: u8 = 16;
const InitializeResult = union(enum) {
    ready,
    stopped,
    failure: startup_api.WorkerFailure,
    runtime_failure: anyerror,
};

pub fn main(comptime App: type, server: anytype, state: anytype, worker_index: u16) void {
    const node = &server.nodes[worker_index];
    switch (initialize(App, server, node, state, worker_index)) {
        .failure => |problem| {
            node.failure = problem;
            node.status.store(.startup_failed, .release);
            server.startup_event.notify();
            return;
        },
        .runtime_failure => |problem| {
            failRuntime(server, node, worker_index, problem);
            return;
        },
        .stopped => {
            publishStatus(server, node, worker_index);
            node.status.store(.stopped, .release);
            server.startup_event.notify();
            _ = server.completion.signal();
            return;
        },
        .ready => {},
    }
    publishStatus(server, node, worker_index);
    node.status.store(.ready, .release);
    server.startup_event.notify();
    run(server, node, worker_index) catch |problem| {
        failRuntime(server, node, worker_index, problem);
        return;
    };
    publishStatus(server, node, worker_index);
    node.status.store(.stopped, .release);
    _ = server.completion.signal();
}

fn initialize(
    comptime App: type,
    server: anytype,
    node: anytype,
    state: anytype,
    worker_index: u16,
) InitializeResult {
    const sample = node.clock.sample() catch |problem| {
        return .{ .failure = startupFailure(node, worker_index, .clock, problem, false) };
    };
    node.backend.init(&node.receive_buffers) catch |problem| {
        return .{ .failure = startupFailure(node, worker_index, .backend, problem, false) };
    };
    node.storage.init(workerSlab(node)) catch |problem| {
        return .{ .failure = startupFailure(node, worker_index, .storage, problem, true) };
    };
    node.command.start(&node.backend) catch |problem| {
        return .{ .failure = startupFailure(node, worker_index, .command, problem, true) };
    };
    node.worker.initForwardingControlled(
        state,
        &node.storage,
        &node.backend,
        worker_index,
        node.listener.socket,
        App.runtime_server_identity,
        &server.forwarding_profile,
        server.metrics.requestRuntime(
            server,
            @TypeOf(server.*).compiled_options.open_metrics.snapshot_timeout_ns,
        ),
        @TypeOf(node.worker).ObservationRuntime.init(&node.observation),
        &server.lifecycle_controller,
    ) catch |problem| {
        return .{ .failure = startupFailure(node, worker_index, .worker, problem, true) };
    };
    var step = node.worker.startDeferred(sample) catch |problem| {
        return .{ .failure = workerStartupFailure(node, worker_index, problem) };
    };
    var retries: u8 = 0;
    while (step == .flush_retry) : (retries += 1) {
        if (retries == flush_retries_max) {
            return .{ .failure = workerStartupFailure(
                node,
                worker_index,
                error.StartupFlushRetryLimit,
            ) };
        }
        step = node.worker.retryFlush() catch |problem| {
            return .{ .failure = workerStartupFailure(node, worker_index, problem) };
        };
    }
    if (step == .stopped) return finishStartupStop(node);
    while (!node.worker.bootstrapReady()) {
        step = nextStep(node) catch |problem| return .{ .runtime_failure = problem };
        closeListenerWhenReady(node) catch |problem| {
            return .{ .runtime_failure = problem };
        };
        publishStatus(server, node, worker_index);
        if (step == .stopped) return finishStartupStop(node);
    }
    node.status.store(.bootstrapped, .release);
    server.startup_event.notify();
    while (!node.worker.startupReady()) {
        step = nextStep(node) catch |problem| return .{ .runtime_failure = problem };
        closeListenerWhenReady(node) catch |problem| {
            return .{ .runtime_failure = problem };
        };
        publishStatus(server, node, worker_index);
        if (step == .stopped) return finishStartupStop(node);
    }
    return .ready;
}

pub fn workerSlab(node: anytype) []u8 {
    const Storage = @TypeOf(node.storage);
    const base = @intFromPtr(&node.slab);
    const aligned = std.mem.alignForward(usize, base, Storage.slab_alignment);
    const offset = aligned - base;
    return node.slab[offset .. offset + Storage.required_bytes];
}

fn finishStartupStop(node: anytype) InitializeResult {
    finishNode(node) catch |problem| return .{ .runtime_failure = problem };
    return .stopped;
}

fn startupFailure(
    node: anytype,
    worker_index: u16,
    stage: startup_api.WorkerStage,
    problem: anyerror,
    backend_live: bool,
) startup_api.WorkerFailure {
    var cleanup: startup_api.Cleanup = .clean;
    if (backend_live) {
        const status = node.backend.abort() catch null;
        if (status == null or !status.?.ownership_proven) {
            cleanup = .process_exit_required;
        }
    }
    node.command.abortAfterBackend();
    if (node.listener.close() != null) cleanup = .process_exit_required;
    return .{
        .worker_index = worker_index,
        .stage = stage,
        .problem = problem,
        .cleanup = cleanup,
    };
}

fn workerStartupFailure(
    node: anytype,
    worker_index: u16,
    problem: anyerror,
) startup_api.WorkerFailure {
    const file_sink = if (node.worker.uploadStartupDiagnostic()) |value|
        value.*
    else
        null;
    const static_root: ?startup_api.StaticRootFailure = if (node.worker.startupFailure()) |value|
        .{
            .root_index = value.root_index,
            .path = value.path,
            .problem = value.problem,
            .kind = value.kind,
        }
    else
        null;
    var cleanup_status = node.worker.cleanupStatus();
    if (cleanup_status.fatal_cleanup == .not_required) {
        const cleanup_problem = node.worker.failBackend();
        if (cleanup_problem != error.BackendFailure) unreachable;
        cleanup_status = node.worker.cleanupStatus();
    }
    node.command.abortAfterBackend();
    var cleanup: startup_api.Cleanup = if (cleanup_status.requiresProcessExit())
        .process_exit_required
    else
        .clean;
    if (node.listener.close() != null) cleanup = .process_exit_required;
    node.published.publish(cleanup_status, .{});
    return .{
        .worker_index = worker_index,
        .stage = .start,
        .problem = problem,
        .cleanup = cleanup,
        .static_root = static_root,
        .file_sink = file_sink,
    };
}

fn run(server: anytype, node: anytype, worker_index: u16) !void {
    while (true) {
        if (node.worker.loopStatus().phase == .stopped) break;
        const step = try nextStep(node);
        try closeListenerWhenReady(node);
        publishStatus(server, node, worker_index);
        if (step == .stopped) break;
    }
    try finishNode(node);
}

fn nextStep(node: anytype) !worker_runtime.Step {
    if (node.worker.loopStatus().flush_pending) {
        return reconcileStop(node, try node.worker.retryFlush());
    }
    const completion = while (true) {
        break node.backend.wait() catch |problem| switch (problem) {
            error.WaitInterrupted, error.WaitRetry => continue,
            else => return problem,
        };
    };
    if (node.command.isCompletion(completion.token)) {
        const sample = node.clock.sample() catch |problem| {
            const cleanup_problem = node.worker.failBackend();
            if (cleanup_problem != error.BackendFailure) unreachable;
            return problem;
        };
        const event = try node.command.handle(&node.backend, completion);
        const step: worker_runtime.Step = switch (event.command) {
            .none => .progressed,
            .serve => try node.worker.allowServices(),
            .drain => try node.worker.beginDrainAt(sample),
            .force => try node.worker.stopAt(sample),
        };
        return reconcileStop(node, step);
    }
    const sample = node.clock.sample() catch |problem| {
        const cleanup_problem = node.worker.failClock(completion);
        if (cleanup_problem != error.InvalidClock) unreachable;
        return problem;
    };
    return reconcileStop(node, try node.worker.handle(completion, sample));
}

fn reconcileStop(node: anytype, step: worker_runtime.Step) worker_runtime.Step {
    if (step != .progressed) return step;
    node.worker.reconcileStopWithExternalOperations(node.command.operationTokens());
    return if (node.worker.loopStatus().phase == .stopped) .stopped else step;
}

fn finishNode(node: anytype) !void {
    try closeListenerWhenReady(node);
    try stopCommand(node);
    if (node.listener.live) return error.ListenerStillLive;
    try node.backend.deinit();
    try node.command.finish();
}

fn failRuntime(server: anytype, node: anytype, worker_index: u16, problem: anyerror) void {
    var cleanup_status = node.worker.cleanupStatus();
    if (cleanup_status.fatal_cleanup == .not_required) {
        const cleanup_problem = node.worker.failBackend();
        if (cleanup_problem != error.BackendFailure) unreachable;
        cleanup_status = node.worker.cleanupStatus();
    }
    node.command.abortAfterBackend();
    var cleanup: startup_api.Cleanup = if (cleanup_status.requiresProcessExit())
        .process_exit_required
    else
        .clean;
    if (node.listener.close() != null) cleanup = .process_exit_required;
    node.published.publish(cleanup_status, .{});
    node.failure = .{
        .worker_index = worker_index,
        .stage = .start,
        .problem = problem,
        .cleanup = cleanup,
    };
    node.status.store(.runtime_failed, .release);
    server.startup_event.notify();
    server.__notifyWorkerFailure();
}

fn stopCommand(node: anytype) !void {
    var stopped = try node.command.beginStop(&node.backend);
    try flushBackend(&node.backend);
    while (!stopped) {
        const completion = node.backend.wait() catch |problem| switch (problem) {
            error.WaitInterrupted, error.WaitRetry => continue,
            else => return problem,
        };
        if (!node.command.isCompletion(completion.token)) {
            return error.UnexpectedCompletionAfterWorkerStop;
        }
        stopped = (try node.command.handle(&node.backend, completion)).stopped;
    }
}

fn flushBackend(backend: anytype) !void {
    var retries: u8 = 0;
    while (true) : (retries += 1) {
        _ = backend.flush() catch |problem| switch (problem) {
            error.SubmissionRetry => {
                if (retries == flush_retries_max) return error.FlushRetryLimitExceeded;
                continue;
            },
            else => return problem,
        };
        return;
    }
}

fn publishStatus(server: anytype, node: anytype, worker_index: u16) void {
    const status = node.worker.cleanupStatus();
    node.published.publish(status, .{
        .listener_live = node.listener.live,
        .control_operations = node.command.operationCount(),
    });
    server.__publishMetrics(worker_index);
}

fn closeListenerWhenReady(node: anytype) !void {
    if (!node.listener.live or !node.worker.listenerReadyToClose()) return;
    if (node.listener.close() != null) return error.ListenerCloseFailed;
}
