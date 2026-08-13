const std = @import("std");

const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const lifecycle = @import("../src/lifecycle.zig");
const server_report = @import("../src/internal/runtime/server/report.zig");

const ModelState = enum(u8) {
    starting,
    ready,
    grace,
    forced,
    stopped,
    failed,
};

test "server lifecycle Smith preserves irreversible transitions and exact reports" {
    try std.testing.fuzz({}, fuzzLifecycle, .{ .corpus = &corpus });
}

fn fuzzLifecycle(_: void, smith: *std.testing.Smith) !void {
    var controller = lifecycle.Controller{};
    var model: ModelState = .starting;
    const actions = smith.valueRangeAtMost(u8, 1, 128);
    for (0..actions) |_| {
        const action = smith.valueRangeAtMost(u8, 0, 4);
        const expected = applyModel(&model, action);
        const actual = applyController(&controller, action);
        try std.testing.expectEqual(expected, actual);
        try expectObservation(&controller, model);
    }
    try checkDeadlines(smith);
    try checkAggregation(smith);
}

fn applyModel(model: *ModelState, action: u8) lifecycle.Transition {
    const before = model.*;
    switch (action) {
        0 => if (before == .starting) {
            model.* = .ready;
        },
        1 => if (before == .starting) {
            model.* = .failed;
        },
        2 => if (before == .starting or before == .ready) {
            model.* = .grace;
        },
        3 => if (before == .grace) {
            model.* = .forced;
        },
        4 => if (before == .grace or before == .forced) {
            model.* = .stopped;
        },
        else => unreachable,
    }
    return if (before == model.*) .unchanged else .advanced;
}

fn applyController(controller: *lifecycle.Controller, action: u8) lifecycle.Transition {
    return switch (action) {
        0 => controller.markReady(),
        1 => controller.markFailed(),
        2 => controller.beginDrain(),
        3 => controller.beginForced(),
        4 => controller.markStopped(),
        else => unreachable,
    };
}

fn expectObservation(controller: *const lifecycle.Controller, model: ModelState) !void {
    const expected_phase: lifecycle.Phase = switch (model) {
        .starting => .starting,
        .ready => .ready,
        .grace, .forced => .draining,
        .stopped => .stopped,
        .failed => .failed,
    };
    const expected_stage: lifecycle.DrainStage = switch (model) {
        .grace => .grace,
        .forced => .forced,
        else => .none,
    };
    try std.testing.expectEqual(expected_phase, controller.phase());
    try std.testing.expectEqual(expected_stage, controller.drainStage());
}

fn checkDeadlines(smith: *std.testing.Smith) !void {
    const start = smith.value(u32);
    const grace = smith.value(u32);
    const force = smith.value(u32);
    const result = try lifecycle.deadlines(start, .{
        .grace_ns = grace,
        .force_ns = force,
    });
    try std.testing.expectEqual(@as(u64, start) + grace, result.grace_ns);
    try std.testing.expectEqual(@as(u64, start) + grace + force, result.force_ns);
    try std.testing.expectError(
        error.DeadlineOverflow,
        lifecycle.deadlines(std.math.maxInt(u64), .{ .grace_ns = 1 }),
    );
}

fn checkAggregation(smith: *std.testing.Smith) !void {
    const workers_a = smith.value(u8);
    const workers_b = smith.value(u8);
    const operations_a = smith.value(u16);
    const operations_b = smith.value(u16);
    const drops_a = smith.value(u32);
    const drops_b = smith.value(u32);
    var report = lifecycle.ShutdownIncomplete{
        .remaining = .{
            .workers = workers_a,
            .network_operations = operations_a,
        },
        .dropped_access_events = drops_a,
    };
    server_report.add(&report, .{
        .remaining = .{
            .workers = workers_b,
            .network_operations = operations_b,
        },
        .dropped_access_events = drops_b,
    });
    try std.testing.expectEqual(
        @as(u16, workers_a) + workers_b,
        report.remaining.workers,
    );
    try std.testing.expectEqual(
        @as(u32, operations_a) + operations_b,
        report.remaining.network_operations,
    );
    try std.testing.expectEqual(@as(u64, drops_a) + drops_b, report.dropped_access_events);
}

const corpus = struct {
    const empty = fuzz_support.smithInput("");
    const drain = fuzz_support.smithInput("ready-drain-force-stop-repeat");
    const failure = fuzz_support.smithInput("fail-before-ready-repeat");
    const values = [_][]const u8{ &empty, &drain, &failure };
}.values;
