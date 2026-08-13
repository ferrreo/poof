const std = @import("std");

const application = @import("../../src/application.zig");
const barrier = @import("../../src/internal/runtime/server/metrics_claim_hook.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const service_module = @import("../../src/internal/runtime/server/metrics_service.zig");

const Context = application.Context(void, response.standard_head_limits);
const Handler = struct {
    fn get(context: *Context) Context.ResponseType {
        return context.empty(.no_content);
    }
};
const App = application.Application(.{
    .State = void,
    .routes = .{route.get("/fixture", Handler.get)},
});
const TestService = service_module.Service(App);
const ClaimOutcome = enum(u8) { pending, accepted, busy, stopping };

const ClaimContext = struct {
    service: *TestService,
    outcome: std.atomic.Value(ClaimOutcome) = .init(.pending),

    fn run(self: *@This()) void {
        const claim = self.service.claim(std.math.maxInt(u64), .{
            .context = self,
            .notify = notified,
        });
        self.outcome.store(switch (claim) {
            .accepted => .accepted,
            .busy => .busy,
            .stopping => .stopping,
        }, .release);
    }

    fn notified(_: *anyopaque, _: service_module.Ticket, _: service_module.WakeIdentity) void {}
};

test "metrics stop racing a claiming request wakes the helper after idle restoration" {
    var service = TestService{};
    try service.start(&service, snapshot, service_module.standard_thread_stack_bytes);
    var claim_thread: ?std.Thread = null;
    defer cleanup(&service, &claim_thread);
    try waitFor(helperWaiting, &service);

    barrier.TestAccess.pauseClaim(true);
    var claim = ClaimContext{ .service = &service };
    claim_thread = try std.Thread.spawn(.{}, ClaimContext.run, .{&claim});
    try waitFor(claimPaused, undefined);

    service.requestStop();
    try waitFor(helperWaiting, &service);
    barrier.TestAccess.pauseClaim(false);
    claim_thread.?.join();
    claim_thread = null;

    try waitFor(helperTerminal, &service);
    service.join();
    try std.testing.expectEqual(ClaimOutcome.stopping, claim.outcome.load(.acquire));
}

fn cleanup(service: *TestService, claim_thread: *?std.Thread) void {
    barrier.TestAccess.pauseClaim(false);
    if (claim_thread.*) |thread| thread.join();
    service.requestStop();
    service.join();
}

fn waitFor(comptime condition: anytype, context: anytype) !void {
    for (0..1_000_000) |_| {
        if (condition(context)) return;
        std.Thread.yield() catch {};
    }
    return error.ConditionTimeout;
}

fn helperWaiting(service: *TestService) bool {
    return service.terminalEvent().waiting();
}

fn helperTerminal(service: *TestService) bool {
    return service.isTerminal();
}

fn claimPaused(_: @TypeOf(undefined)) bool {
    return barrier.TestAccess.claimPaused();
}

fn snapshot(_: *anyopaque, _: u64, output: *TestService.MetricsSnapshot) !void {
    output.* = .{ .epoch = 1 };
}
