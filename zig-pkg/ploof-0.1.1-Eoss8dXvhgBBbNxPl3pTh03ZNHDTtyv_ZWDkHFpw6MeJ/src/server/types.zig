const std = @import("std");

const lifecycle = @import("../lifecycle.zig");
const forwarding = @import("../forwarding.zig");
const listener_runtime = @import("../internal/runtime/listener.zig");
const runtime_config = @import("../internal/runtime/config.zig");
const reactor = @import("../internal/runtime/reactor.zig");
const server_clock = @import("../internal/runtime/server/clock.zig");
const server_command = @import("../internal/runtime/server/command.zig");
const server_metrics_service = @import("../internal/runtime/server/metrics_service.zig");
const server_wait = @import("../internal/runtime/server/wait.zig");
const access_logger = @import("../internal/runtime/access_logger.zig");

pub const standard_worker_thread_stack_bytes: usize = 512 * 1024;
pub const minimum_worker_thread_stack_bytes: usize = 64 * 1024;
pub const maximum_worker_thread_stack_bytes: usize = 8 * 1024 * 1024;
pub const worker_thread_stack_alignment: usize = 4096;

pub const AccessLogOptions = struct {
    enabled: bool = false,
    ring_capacity: u16 = 256,
    drain_batch_per_ring: u16 = 32,
    thread_stack_bytes: usize = access_logger.standard_thread_stack_bytes,
};

pub const OpenMetricsOptions = struct {
    snapshot_timeout_ns: u64 = std.time.ns_per_s,
    thread_stack_bytes: usize = server_metrics_service.standard_thread_stack_bytes,
};

pub const Options = struct {
    limits: runtime_config.Limits = .{},
    forwarding_limits: forwarding.Limits = .{},
    workers_max: u16 = 1,
    receive_buffer_group: u16 = 47,
    worker_thread_stack_bytes: usize = standard_worker_thread_stack_bytes,
    access_log: AccessLogOptions = .{},
    open_metrics: OpenMetricsOptions = .{},
};

pub const StartConfig = struct {
    listener: listener_runtime.Config = .{},
    forwarding: forwarding.Config = .{},
    worker_count: u16 = 1,
    shutdown: lifecycle.ShutdownProfile = .{},
    access_log_descriptor: ?std.os.linux.fd_t = null,
    readiness: ?*lifecycle.Readiness = null,
};

pub const ShutdownResult = union(enum) {
    stopped,
    incomplete: lifecycle.ShutdownIncomplete,
};

pub const ShutdownError = lifecycle.DeadlineError || server_clock.Error ||
    server_command.Error || server_wait.Error || error{
    CompletionCounterFailed,
    ServerNotRunning,
    ServerStillStarting,
};

pub fn validated(comptime options: Options) Options {
    if (options.workers_max == 0) @compileError("PLOOF-E6001 workers_max must be positive");
    if (options.workers_max > reactor.max_worker_index + 1) {
        @compileError("PLOOF-E6002 workers_max exceeds reactor worker identity capacity");
    }
    if (options.worker_thread_stack_bytes < minimum_worker_thread_stack_bytes) {
        @compileError("PLOOF-E6003 worker thread stack must be at least 65536 bytes");
    }
    if (options.worker_thread_stack_bytes > maximum_worker_thread_stack_bytes) {
        @compileError("PLOOF-E6004 worker thread stack must not exceed 8388608 bytes");
    }
    if (options.worker_thread_stack_bytes % worker_thread_stack_alignment != 0) {
        @compileError("PLOOF-E6005 worker thread stack must be aligned to 4096 bytes");
    }
    if (options.access_log.enabled) validateAccessLog(options.access_log);
    validateOpenMetrics(options.open_metrics);
    _ = runtime_config.Limits.validate(options.limits);
    _ = forwarding.Profile(options.forwarding_limits);
    return options;
}

fn validateOpenMetrics(comptime options: OpenMetricsOptions) void {
    if (options.snapshot_timeout_ns == 0) {
        @compileError("PLOOF-E6011 OpenMetrics snapshot timeout must be positive");
    }
    if (options.thread_stack_bytes < server_metrics_service.thread_stack_bytes_min) {
        @compileError("PLOOF-E6012 OpenMetrics stack must be at least 65536 bytes");
    }
    if (options.thread_stack_bytes > server_metrics_service.thread_stack_bytes_max) {
        @compileError("PLOOF-E6013 OpenMetrics stack must not exceed 8388608 bytes");
    }
    if (options.thread_stack_bytes % worker_thread_stack_alignment != 0) {
        @compileError("PLOOF-E6014 OpenMetrics stack must be aligned to 4096 bytes");
    }
}

fn validateAccessLog(comptime options: AccessLogOptions) void {
    if (options.ring_capacity == 0) {
        @compileError("PLOOF-E6006 access log ring capacity must be positive");
    }
    if (options.drain_batch_per_ring == 0) {
        @compileError("PLOOF-E6007 access log drain batch must be positive");
    }
    if (options.thread_stack_bytes < access_logger.thread_stack_bytes_min) {
        @compileError("PLOOF-E6008 access logger stack must be at least 65536 bytes");
    }
    if (options.thread_stack_bytes > access_logger.thread_stack_bytes_max) {
        @compileError("PLOOF-E6009 access logger stack must not exceed 8388608 bytes");
    }
    if (options.thread_stack_bytes % worker_thread_stack_alignment != 0) {
        @compileError("PLOOF-E6010 access logger stack must be aligned to 4096 bytes");
    }
}
