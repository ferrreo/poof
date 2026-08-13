const std = @import("std");

const lifecycle = @import("../lifecycle.zig");
const server_module = @import("../server.zig");
const startup = @import("startup.zig");
const server_signal = @import("../internal/runtime/server/signal.zig");
const runner_exit = @import("../internal/runtime/server/runner_exit.zig");
const server_wait = @import("../internal/runtime/server/wait.zig");

pub const Result = union(enum) {
    startup_failure: startup.Failure,
    stopped,
    incomplete: lifecycle.ShutdownIncomplete,
};

pub const Error = server_module.SignalShutdownError;
pub const exit = struct {
    pub const success = runner_exit.success;
    pub const startup_failure = runner_exit.startup_failure;
    pub const shutdown_incomplete = runner_exit.shutdown_incomplete;
    pub const runner_failure = runner_exit.runner_failure;
};

/// Caller-owned convenience runner. Keep it at one address from `run` until
/// return, just like the contained Server. Global declarations must spell
/// `align(@alignOf(RunnerType))`.
pub fn Runner(
    comptime App: type,
    comptime options: server_module.Options,
) type {
    const RuntimeServer = server_module.Server(App, options);
    return struct {
        const Self = @This();

        server: RuntimeServer = RuntimeServer.init(),

        pub fn init() Self {
            return .{};
        }

        pub fn run(
            self: *Self,
            state: *App.StateType,
            config: server_module.StartConfig,
        ) Error!Result {
            var source = try server_signal.Source.open();
            const outcome = self.runOpen(state, config, &source) catch |problem| {
                source.closeAndRestore() catch |close_problem| return close_problem;
                return problem;
            };
            try source.closeAndRestore();
            return outcome;
        }

        pub fn runOrExit(
            self: *Self,
            state: *App.StateType,
            config: server_module.StartConfig,
        ) noreturn {
            runner_exit.run(self, state, config, 2);
        }

        pub fn runOrExitTo(
            self: *Self,
            state: *App.StateType,
            config: server_module.StartConfig,
            diagnostic_descriptor: std.os.linux.fd_t,
        ) noreturn {
            runner_exit.run(self, state, config, diagnostic_descriptor);
        }

        fn runOpen(
            self: *Self,
            state: *App.StateType,
            config: server_module.StartConfig,
            source: *server_signal.Source,
        ) Error!Result {
            switch (self.server.start(state, config)) {
                .failure => |failure| return .{ .startup_failure = failure },
                .ready => {},
            }
            return waitAndShutdown(&self.server, source) catch |problem| {
                return self.stopAfterControlFailure(problem);
            };
        }

        fn stopAfterControlFailure(self: *Self, problem: Error) Error!Result {
            _ = self.server.beginDrain() catch {};
            _ = self.server.beginForced() catch {};
            return switch (self.server.shutdown() catch return problem) {
                .stopped => return problem,
                .incomplete => |report| .{ .incomplete = report },
            };
        }
    };
}

fn waitAndShutdown(server: anytype, source: *server_signal.Source) Error!Result {
    while (true) {
        switch (try server_wait.until(
            server.completion.descriptor,
            source.descriptor,
            std.math.maxInt(u64),
        )) {
            .signal => {
                if ((try source.next()) == null) continue;
                _ = try server.beginDrain();
                break;
            },
            .completion => break,
            .deadline => unreachable,
        }
    }
    return mapShutdown(try server.shutdownSignaled(source));
}

fn mapShutdown(result: server_module.ShutdownResult) Result {
    return switch (result) {
        .stopped => .stopped,
        .incomplete => |report| .{ .incomplete = report },
    };
}

test "runner consumes first and repeated blocked signals through signalfd" {
    const application = @import("../application.zig");
    const response = @import("../response.zig");
    const route = @import("../route.zig");
    const State = struct {};
    const Context = application.Context(State, response.standard_head_limits);
    const Handler = struct {
        fn ping(context: *Context) Context.ResponseType {
            return context.textStatic(.ok, "pong");
        }
    };
    const App = application.Application(.{
        .State = State,
        .routes = .{route.get("/ping", Handler.ping)},
    });
    const RuntimeServer = server_module.Server(App, .{ .limits = testLimits() });

    var source = try server_signal.Source.open();
    defer if (source.live) source.closeAndRestore() catch {};
    const server = try std.testing.allocator.create(RuntimeServer);
    defer std.testing.allocator.destroy(server);
    server.* = RuntimeServer.init();
    var state = State{};
    switch (server.start(&state, .{ .shutdown = .{
        .grace_ns = std.time.ns_per_s,
        .force_ns = std.time.ns_per_s,
    } })) {
        .ready => {},
        .failure => return error.UnexpectedStartupFailure,
    }
    var stopped = false;
    defer if (!stopped) {
        _ = server.beginDrain() catch {};
        _ = server.beginForced() catch {};
        _ = server.shutdown() catch {};
    };

    const sender = try std.Thread.spawn(.{}, sendRepeatedSignals, .{});
    const result = try waitAndShutdown(server, &source);
    sender.join();
    try std.testing.expectEqual(Result.stopped, result);
    stopped = true;
    try source.closeAndRestore();
}

fn testLimits() @import("../internal/runtime/config.zig").Limits {
    return .{
        .connection_slots = 1,
        .request_slots = 1,
        .receive_buffers = 2,
        .receive_buffer_bytes = 1024,
        .pipeline_bytes_per_connection = 1024,
        .response_bytes_per_request = 4096,
        .response_chunk_count = 2,
        .submission_entries = 32,
        .completion_entries = 64,
    };
}

fn sendRepeatedSignals() void {
    const linux = std.os.linux;
    inline for (.{ .TERM, .INT, .TERM, .INT, .TERM, .INT }) |signal| {
        if (linux.errno(linux.kill(linux.getpid(), signal)) != .SUCCESS) unreachable;
    }
}
