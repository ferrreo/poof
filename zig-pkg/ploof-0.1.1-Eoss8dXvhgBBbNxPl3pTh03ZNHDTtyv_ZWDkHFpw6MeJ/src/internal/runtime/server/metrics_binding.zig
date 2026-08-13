const std = @import("std");

const server_clock = @import("clock.zig");
const server_metrics_request = @import("metrics_request.zig");
const server_metrics_runtime = @import("metrics_runtime.zig");
const server_metrics_service = @import("metrics_service.zig");

pub const StartError = server_metrics_service.StartError;

pub fn Binding(comptime App: type, comptime Server: type) type {
    if (App.open_metrics_enabled) return Enabled(App, Server);
    return Disabled;
}

fn Enabled(comptime App: type, comptime Server: type) type {
    const Service = server_metrics_service.Service(App);
    const RequestRuntime = server_metrics_request.Runtime(App);
    return struct {
        const Self = @This();

        service: Service = .{},
        live: std.atomic.Value(bool) = .init(false),

        pub fn start(self: *Self, server: *Server, stack_bytes: usize) StartError!void {
            try self.service.start(server, takeSnapshot, stack_bytes);
            self.live.store(true, .release);
        }

        pub fn requestStop(self: *Self) void {
            if (!self.live.load(.acquire)) return;
            self.service.requestStop();
        }

        pub fn stopUntil(self: *Self, deadline_ns: u64) bool {
            if (!self.live.load(.acquire)) return true;
            self.service.requestStop();
            while (!self.service.isTerminal()) {
                const now_ns = server_clock.monotonicNow() catch return false;
                if (now_ns >= deadline_ns) return false;
                const event = self.service.terminalEvent();
                const observed = event.observe();
                if (self.service.isTerminal()) break;
                if (!event.arm(observed)) continue;
                switch (event.waitFor(observed, deadline_ns - now_ns)) {
                    .notified, .interrupted => {},
                    .timed_out => if (!self.service.isTerminal()) return false,
                }
            }
            self.service.join();
            self.live.store(false, .release);
            return true;
        }

        pub fn helperJobs(self: *const Self) u32 {
            if (!self.live.load(.acquire)) return 0;
            return @intFromBool(!self.service.isTerminal());
        }

        pub fn requestRuntime(
            self: *Self,
            server: *Server,
            timeout_ns: u64,
        ) RequestRuntime {
            return RequestRuntime.init(
                &self.service,
                server,
                notifyWorker,
                timeout_ns,
            );
        }

        fn notifyWorker(
            context: *anyopaque,
            ticket: server_metrics_service.Ticket,
            identity: server_metrics_service.WakeIdentity,
        ) void {
            const server: *Server = @ptrCast(@alignCast(context));
            if (ticket.generation == 0 or identity.service_generation != ticket.generation or
                identity.request_generation == 0 or
                identity.stream_generation == 0 or
                identity.worker_index >= server.worker_count)
            {
                return;
            }
            _ = server.nodes[identity.worker_index].storage.stream_wakes.notifyIdentity(
                identity.request_index,
                identity.stream_generation,
            );
        }

        fn takeSnapshot(
            context: *anyopaque,
            deadline_ns: u64,
            output: *Service.MetricsSnapshot,
        ) anyerror!void {
            const server: *Server = @ptrCast(@alignCast(context));
            return server.metricsSnapshot(deadline_ns, output);
        }
    };
}

const Disabled = struct {
    pub fn start(_: *Disabled, _: anytype, _: usize) StartError!void {}
    pub fn requestStop(_: *Disabled) void {}
    pub fn stopUntil(_: *Disabled, _: u64) bool {
        return true;
    }
    pub fn helperJobs(_: *const Disabled) u32 {
        return 0;
    }
    pub fn requestRuntime(_: *Disabled, _: anytype, _: u64) server_metrics_request.Disabled {
        return .init();
    }
};

pub fn snapshot(
    server: anytype,
    deadline_ns: u64,
    output: anytype,
) server_metrics_runtime.Error!void {
    if (!server.start_attempted.load(.acquire)) return error.ServerNotReady;
    _ = server.phase();
    return server_metrics_runtime.snapshot(server, deadline_ns, output);
}

pub fn publish(server: anytype, worker_index: u16) void {
    server.observability.publish(
        worker_index,
        &server.nodes[worker_index].observation,
    );
}

test "enabled binding owns and boundedly stops one helper" {
    const application = @import("../../../application.zig");
    const route = @import("../../../route.zig");
    const App = application.Application(.{
        .State = void,
        .routes = .{route.openMetrics("/metrics")},
    });
    const Wakes = struct {
        count: std.atomic.Value(u32) = .init(0),
        last_index: u16 = 0,
        last_generation: u64 = 0,

        fn notifyIdentity(self: *@This(), index: u16, generation: u64) void {
            self.last_index = index;
            self.last_generation = generation;
            self.count.store(1, .release);
        }
    };
    const Node = struct { storage: struct { stream_wakes: Wakes = .{} } = .{} };
    const FakeServer = struct {
        worker_count: u16 = 1,
        nodes: [1]Node = .{.{}},

        fn metricsSnapshot(
            _: *@This(),
            _: u64,
            output: anytype,
        ) !void {
            output.* = .{ .epoch = 1 };
        }
    };
    const TestBinding = Binding(App, FakeServer);
    var server = FakeServer{};
    var binding = TestBinding{};
    try binding.start(
        &server,
        server_metrics_service.thread_stack_bytes_max,
    );
    try std.testing.expectEqual(@as(u32, 1), binding.helperJobs());
    const runtime = binding.requestRuntime(&server, std.math.maxInt(u64));
    const ticket = switch (runtime.claimAt(0, .{
        .worker_index = 0,
        .request_index = 7,
        .request_generation = 3,
        .stream_generation = 11,
    })) {
        .accepted => |accepted| accepted,
        else => return error.UnexpectedClaimFailure,
    };
    for (0..1_000_000) |_| {
        if (server.nodes[0].storage.stream_wakes.count.load(.acquire) != 0) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(u16, 7), server.nodes[0].storage.stream_wakes.last_index);
    try std.testing.expectEqual(@as(u64, 11), server.nodes[0].storage.stream_wakes.last_generation);
    try std.testing.expect(runtime.release(ticket));
    try std.testing.expectEqual(
        server_metrics_request.Claim.deadline_overflow,
        runtime.claimAt(1, .{}),
    );
    binding.requestStop();
    try std.testing.expect(binding.stopUntil(std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u32, 0), binding.helperJobs());
}

test "disabled binding contributes no storage-backed helper" {
    const App = struct {
        pub const open_metrics_enabled = false;
    };
    const FakeServer = struct {};
    const TestBinding = Binding(App, FakeServer);
    var server = FakeServer{};
    var binding = TestBinding{};
    try binding.start(&server, 0);
    try std.testing.expect(binding.stopUntil(0));
    try std.testing.expectEqual(@as(u32, 0), binding.helperJobs());
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(TestBinding));
}
