const std = @import("std");

const application = @import("../../../../src/application.zig");
const response_stream = @import("../../../../src/response/stream.zig");
const response_framing = @import("../../../../src/internal/http1/response_framing.zig");
const response_transfer = @import("../../../../src/internal/http1/response_transfer.zig");
const deterministic_reactor = @import("../../../../src/internal/runtime/deterministic_reactor.zig");
const stream_transport = @import(
    "../../../../src/internal/runtime/connection/stream_transport.zig",
);
const worker_stream_wake = @import("../../../../src/internal/runtime/worker/stream_wake.zig");

const Erased = @import("../../../../src/internal/response/stream_erasure.zig").Erased(128, 16);
const FakeApp = struct {
    pub const Workspace = struct { stream: Erased = undefined };
};
const Transport = stream_transport.State(FakeApp);
const TestIo = deterministic_reactor.DeterministicReactor(4);
const Wakes = worker_stream_wake.Fixed(1);

const Counts = struct {
    polls: u8 = 0,
    aborts: u8 = 0,
    joins: u8 = 0,
};

const Step = union(enum) {
    bytes: []const u8,
    done: []const response_stream.TrailerField,
    pending,
    pending_notify,
    fail,
};

const Producer = struct {
    steps: []const Step,
    counts: *Counts,
    index: usize = 0,

    pub fn poll(
        self: *@This(),
        output: []u8,
        wake: response_stream.Wake,
    ) response_stream.PollError!response_stream.PollResult {
        self.counts.polls += 1;
        const step = self.steps[self.index];
        self.index += 1;
        return switch (step) {
            .bytes => |bytes| blk: {
                if (bytes.len <= output.len) @memcpy(output[0..bytes.len], bytes);
                break :blk .{ .progress = bytes.len };
            },
            .done => |fields| .{ .done = fields },
            .pending => .pending,
            .pending_notify => blk: {
                wake.notify();
                break :blk .pending;
            },
            .fail => error.ProducerFailed,
        };
    }

    pub fn abort(self: *@This()) void {
        self.counts.aborts += 1;
    }

    pub fn join(self: *@This()) void {
        self.counts.joins += 1;
    }
};

const WakeHarness = struct {
    wakes: Wakes = undefined,
    io: TestIo = .{},
    value: worker_stream_wake.StreamWake = undefined,
    invalidated: bool = false,

    fn init(self: *@This()) !void {
        try self.wakes.init(0);
        try self.wakes.start(&self.io);
        self.value = try self.wakes.activate(0);
    }

    fn invalidate(self: *@This()) worker_stream_wake.InvalidateResult {
        const result = self.wakes.invalidateBeforeAbort(self.value);
        self.invalidated = result == .invalidated;
        return result;
    }

    fn deinit(self: *@This()) !void {
        try std.testing.expect(self.invalidated);
        try self.wakes.confirmPublishersJoined();
        try self.wakes.beginFatalAfterPublishersJoined();
        const status = try self.io.abort();
        try std.testing.expect(status.ownership_proven);
        try self.wakes.finishFatalAfterBackend();
    }
};

fn activePrepared(
    head: []const u8,
    framing: response_framing.Framing,
    trailers: response_transfer.TrailerPlan,
) application.Prepared {
    return .{
        .source = .{ .contiguous_wire = head },
        .bytes = head,
        .status = .ok,
        .close_connection = false,
        .coding_outcome = .identity_negotiated,
        .transmission = .{ .stream = .{
            .framing = .{
                .framing = framing,
                .send_body = true,
                .invoke_stream = true,
                .emit_content_type = true,
                .emit_trailers = trailers.emitted,
            },
            .trailers = trailers,
        } },
    };
}

fn suppressedPrepared(head: []const u8, framing: response_framing.Framing) application.Prepared {
    return .{
        .source = .{ .contiguous_wire = head },
        .bytes = head,
        .status = .ok,
        .close_connection = false,
        .coding_outcome = .identity_negotiated,
        .transmission = .{ .stream = .{
            .framing = .{
                .framing = framing,
                .send_body = false,
                .invoke_stream = false,
                .emit_content_type = true,
                .emit_trailers = false,
            },
            .trailers = emptyTrailerPlan(),
        } },
    };
}

fn emptyTrailerPlan() response_transfer.TrailerPlan {
    return .{ .emitted = false, .declarations = &.{}, .fingerprint = 0 };
}

fn expectSend(
    action: stream_transport.Action,
    kind: stream_transport.SendKind,
    expected: []const u8,
) !void {
    switch (action) {
        .send => |value| {
            try std.testing.expectEqual(kind, value.kind);
            try std.testing.expectEqualSlices(u8, expected, value.bytes);
        },
        else => return error.TestExpectedEqual,
    }
}

fn expectActionOutcome(
    action: stream_transport.Action,
    comptime tag: std.meta.Tag(stream_transport.Action),
    expected: application.TransportOutcome,
) !void {
    switch (action) {
        tag => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.TestExpectedEqual,
    }
}

fn settle(
    state: *Transport,
    wakes: *WakeHarness,
    action: stream_transport.Action,
) !stream_transport.Action {
    switch (action) {
        .invalidate => {},
        else => return error.TestExpectedEqual,
    }
    return state.invalidated(wakes.invalidate());
}

test "exact stream drains head and raw body before canary completion" {
    var counts = Counts{};
    const steps = [_]Step{
        .{ .bytes = "abc" },
        .{ .bytes = "de" },
        .{ .done = &.{} },
    };
    var workspace: FakeApp.Workspace = undefined;
    workspace.stream.init(response_stream.exact(5, Producer{
        .steps = &steps,
        .counts = &counts,
    }));
    var wakes = WakeHarness{};
    try wakes.init();
    var staging: [64]u8 = undefined;
    var state: Transport = undefined;

    const prepared = activePrepared("head", .{ .fixed = 5 }, emptyTrailerPlan());
    try expectSend(
        try state.init(&workspace, prepared, &staging, wakes.value, .completed),
        .head,
        "head",
    );
    try std.testing.expectEqual(@as(u8, 0), counts.polls);
    try expectSend(try state.sent(), .body, "abc");
    try std.testing.expectError(error.InvalidLifecycle, state.ready());
    try expectSend(try state.sent(), .body, "de");
    const invalidation = try state.sent();
    try expectActionOutcome(invalidation, .invalidate, .completed);
    const finished = try settle(&state, &wakes, invalidation);
    try expectActionOutcome(finished, .finished, .completed);
    try std.testing.expectEqual(Counts{ .polls = 3, .joins = 1 }, counts);
    try wakes.deinit();
}

test "unknown stream chunks in place retains wake and writes terminal trailers" {
    const declarations = [_][]const u8{"X-Checksum"};
    const fields = [_]response_stream.TrailerField{
        .{ .name = "x-checksum", .value = "done" },
    };
    const steps = [_]Step{
        .{ .bytes = "hello" },
        .pending_notify,
        .{ .done = &fields },
    };
    var counts = Counts{};
    var workspace: FakeApp.Workspace = undefined;
    workspace.stream.init(response_stream.unknown(Producer{
        .steps = &steps,
        .counts = &counts,
    }, &declarations));
    var wakes = WakeHarness{};
    try wakes.init();
    var staging: [128]u8 = undefined;
    var state: Transport = undefined;
    const trailer_plan = (try response_transfer.prepareTrailerPlan(
        response_transfer.standard_trailer_limits,
        &declarations,
        true,
    )).plan;

    const prepared = activePrepared("head", .chunked, trailer_plan);
    _ = try state.init(&workspace, prepared, &staging, wakes.value, .completed);
    try expectSend(try state.sent(), .body, "5\r\nhello\r\n");
    try std.testing.expectEqual(
        worker_stream_wake.NotifyResult.published,
        state.wake().?.notify(),
    );
    try std.testing.expectError(error.InvalidLifecycle, state.ready());
    try std.testing.expect((try state.sent()) == .poll_ready);
    const invalidation = try state.ready();
    try expectActionOutcome(invalidation, .invalidate, .completed);
    const terminal = try settle(&state, &wakes, invalidation);
    try expectSend(terminal, .terminal, "0\r\nx-checksum: done\r\n\r\n");
    try std.testing.expectError(error.InvalidLifecycle, state.ready());
    try expectActionOutcome(try state.sent(), .finished, .completed);
    try std.testing.expectEqual(Counts{ .polls = 3, .joins = 1 }, counts);
    try wakes.deinit();
}

test "pending stream waits for a later claimed wake" {
    const steps = [_]Step{ .pending, .{ .done = &.{} } };
    var counts = Counts{};
    var workspace: FakeApp.Workspace = undefined;
    workspace.stream.init(response_stream.unknown(Producer{
        .steps = &steps,
        .counts = &counts,
    }, &.{}));
    var wakes = WakeHarness{};
    try wakes.init();
    var staging: [64]u8 = undefined;
    var state: Transport = undefined;
    const prepared = activePrepared("head", .chunked, emptyTrailerPlan());
    _ = try state.init(&workspace, prepared, &staging, wakes.value, .completed);

    try std.testing.expect((try state.sent()) == .pending);
    try std.testing.expect((try state.ready()) == .pending);
    try std.testing.expectEqual(
        worker_stream_wake.NotifyResult.published,
        state.wake().?.notify(),
    );
    const invalidation = try state.ready();
    const terminal = try settle(&state, &wakes, invalidation);
    try expectSend(terminal, .terminal, "0\r\n\r\n");
    try expectActionOutcome(try state.sent(), .finished, .completed);
    try std.testing.expectEqual(Counts{ .polls = 2, .joins = 1 }, counts);
    try wakes.deinit();
}

test "suppressed HEAD and rejection join without wake poll or abort" {
    const cases = [_]struct {
        framing: response_stream.Framing,
        wire: response_framing.Framing,
        outcome: application.TransportOutcome,
    }{
        .{ .framing = .{ .exact = 9 }, .wire = .{ .fixed = 9 }, .outcome = .head_suppressed },
        .{ .framing = .unknown, .wire = .{ .fixed = 0 }, .outcome = .completed },
    };
    for (cases) |case| {
        var counts = Counts{};
        const steps = [_]Step{.{ .done = &.{} }};
        var workspace: FakeApp.Workspace = undefined;
        workspace.stream.init(response_stream.Response(Producer){
            .framing = case.framing,
            .trailer_names = &.{},
            .producer = .{ .steps = &steps, .counts = &counts },
        });
        var staging: [64]u8 = undefined;
        var state: Transport = undefined;
        const prepared = suppressedPrepared("head", case.wire);

        try expectSend(
            try state.init(&workspace, prepared, &staging, null, case.outcome),
            .head,
            "head",
        );
        try std.testing.expectEqual(Counts{ .joins = 1 }, counts);
        try std.testing.expect(state.wake() == null);
        try expectActionOutcome(try state.sent(), .finished, case.outcome);
    }
}

fn expectCanceled(outcome: application.TransportOutcome) !void {
    var counts = Counts{};
    const steps = [_]Step{.{ .bytes = "body" }};
    var workspace: FakeApp.Workspace = undefined;
    workspace.stream.init(response_stream.unknown(Producer{
        .steps = &steps,
        .counts = &counts,
    }, &.{}));
    var wakes = WakeHarness{};
    try wakes.init();
    var staging: [64]u8 = undefined;
    var state: Transport = undefined;
    const prepared = activePrepared("head", .chunked, emptyTrailerPlan());
    _ = try state.init(&workspace, prepared, &staging, wakes.value, .completed);

    const invalidation = try state.cancel(outcome);
    try expectActionOutcome(invalidation, .invalidate, outcome);
    const finished = try settle(&state, &wakes, invalidation);
    try expectActionOutcome(finished, .finished, outcome);
    try std.testing.expectEqual(Counts{ .aborts = 1, .joins = 1 }, counts);
    try wakes.deinit();
}

test "external cancellation retains detailed transport outcome" {
    try expectCanceled(.write_stalled);
    try expectCanceled(.peer_aborted);
    try expectCanceled(.framework_canceled);
    try expectCanceled(.aborted);
}

test "cancellation settles sending body waiting and terminal phases once" {
    const phases = [_]Step{ .{ .bytes = "body" }, .pending };
    for (phases, 0..) |first, index| {
        var counts = Counts{};
        const steps = [_]Step{ first, .{ .done = &.{} } };
        var workspace: FakeApp.Workspace = undefined;
        workspace.stream.init(response_stream.unknown(Producer{
            .steps = &steps,
            .counts = &counts,
        }, &.{}));
        var wakes = WakeHarness{};
        try wakes.init();
        var staging: [64]u8 = undefined;
        var state: Transport = undefined;
        _ = try state.init(
            &workspace,
            activePrepared("head", .chunked, emptyTrailerPlan()),
            &staging,
            wakes.value,
            .completed,
        );
        const driven = try state.sent();
        try std.testing.expect(if (index == 0) driven == .send else driven == .pending);
        const invalidation = try state.cancel(.aborted);
        const finished = try settle(&state, &wakes, invalidation);
        try expectActionOutcome(finished, .finished, .aborted);
        try std.testing.expectEqual(@as(u8, 1), counts.aborts);
        try std.testing.expectEqual(@as(u8, 1), counts.joins);
        try wakes.deinit();
    }

    var terminal_counts = Counts{};
    const terminal_steps = [_]Step{.{ .done = &.{} }};
    var terminal_workspace: FakeApp.Workspace = undefined;
    terminal_workspace.stream.init(response_stream.unknown(Producer{
        .steps = &terminal_steps,
        .counts = &terminal_counts,
    }, &.{}));
    var terminal_wakes = WakeHarness{};
    try terminal_wakes.init();
    var terminal_staging: [64]u8 = undefined;
    var terminal_state: Transport = undefined;
    _ = try terminal_state.init(
        &terminal_workspace,
        activePrepared("head", .chunked, emptyTrailerPlan()),
        &terminal_staging,
        terminal_wakes.value,
        .completed,
    );
    const terminal = try settle(&terminal_state, &terminal_wakes, try terminal_state.sent());
    try expectSend(terminal, .terminal, "0\r\n\r\n");
    try expectActionOutcome(try terminal_state.cancel(.aborted), .finished, .aborted);
    try std.testing.expectEqual(Counts{ .polls = 1, .joins = 1 }, terminal_counts);
    try terminal_wakes.deinit();
}

test "repeated synchronous notifications yield one poll action per caller turn" {
    const steps = [_]Step{ .pending_notify, .pending_notify, .{ .done = &.{} } };
    var counts = Counts{};
    var workspace: FakeApp.Workspace = undefined;
    workspace.stream.init(response_stream.unknown(Producer{
        .steps = &steps,
        .counts = &counts,
    }, &.{}));
    var wakes = WakeHarness{};
    try wakes.init();
    var staging: [64]u8 = undefined;
    var state: Transport = undefined;
    _ = try state.init(
        &workspace,
        activePrepared("head", .chunked, emptyTrailerPlan()),
        &staging,
        wakes.value,
        .completed,
    );

    try std.testing.expect((try state.sent()) == .poll_ready);
    try std.testing.expect((try state.ready()) == .poll_ready);
    const terminal = try settle(&state, &wakes, try state.ready());
    try expectSend(terminal, .terminal, "0\r\n\r\n");
    try expectActionOutcome(try state.sent(), .finished, .completed);
    try std.testing.expectEqual(Counts{ .polls = 3, .joins = 1 }, counts);
    try wakes.deinit();
}

test "externally invalidated waiting wake settles stale generation safely" {
    const steps = [_]Step{.pending};
    var counts = Counts{};
    var workspace: FakeApp.Workspace = undefined;
    workspace.stream.init(response_stream.unknown(Producer{
        .steps = &steps,
        .counts = &counts,
    }, &.{}));
    var wakes = WakeHarness{};
    try wakes.init();
    var staging: [64]u8 = undefined;
    var state: Transport = undefined;
    _ = try state.init(
        &workspace,
        activePrepared("head", .chunked, emptyTrailerPlan()),
        &staging,
        wakes.value,
        .completed,
    );
    try std.testing.expect((try state.sent()) == .pending);
    _ = wakes.invalidate();
    try expectActionOutcome(try state.ready(), .finished, .framework_canceled);
    try std.testing.expectEqual(Counts{ .polls = 1, .aborts = 1, .joins = 1 }, counts);
    try wakes.deinit();
}

fn expectExactFailure(steps: []const Step, expected: application.TransportOutcome) !void {
    var counts = Counts{};
    var workspace: FakeApp.Workspace = undefined;
    workspace.stream.init(response_stream.exact(1, Producer{
        .steps = steps,
        .counts = &counts,
    }));
    var wakes = WakeHarness{};
    try wakes.init();
    var staging: [64]u8 = undefined;
    var state: Transport = undefined;
    const prepared = activePrepared("head", .{ .fixed = 1 }, emptyTrailerPlan());
    _ = try state.init(&workspace, prepared, &staging, wakes.value, .completed);

    var action = try state.sent();
    if (action == .send) action = try state.sent();
    try expectActionOutcome(action, .invalidate, expected);
    const finished = try settle(&state, &wakes, action);
    try expectActionOutcome(finished, .finished, expected);
    try std.testing.expectEqual(@as(u8, 1), counts.aborts);
    try std.testing.expectEqual(@as(u8, 1), counts.joins);
    try wakes.deinit();
}

test "producer exact failures distinguish underrun and overrun" {
    const underrun = [_]Step{.{ .done = &.{} }};
    try expectExactFailure(&underrun, .exact_underrun);
    const overrun = [_]Step{ .{ .bytes = "x" }, .{ .bytes = "y" } };
    try expectExactFailure(&overrun, .exact_overrun);
}

test "producer poll failure aborts joins and reports producer cause" {
    const failed = [_]Step{.fail};
    var counts = Counts{};
    var workspace: FakeApp.Workspace = undefined;
    workspace.stream.init(response_stream.unknown(Producer{
        .steps = &failed,
        .counts = &counts,
    }, &.{}));
    var wakes = WakeHarness{};
    try wakes.init();
    var staging: [64]u8 = undefined;
    var state: Transport = undefined;
    const prepared = activePrepared("head", .chunked, emptyTrailerPlan());
    _ = try state.init(&workspace, prepared, &staging, wakes.value, .completed);

    const invalidation = try state.sent();
    try expectActionOutcome(invalidation, .invalidate, .producer_failed);
    _ = try settle(&state, &wakes, invalidation);
    try std.testing.expectEqual(
        Counts{ .polls = 1, .aborts = 1, .joins = 1 },
        counts,
    );
    try wakes.deinit();
}

test "incoherent stream plans fail before producer polling" {
    for (0..2) |variant| {
        var counts = Counts{};
        const steps = [_]Step{.{ .done = &.{} }};
        var workspace: FakeApp.Workspace = undefined;
        workspace.stream.init(response_stream.unknown(Producer{
            .steps = &steps,
            .counts = &counts,
        }, &.{}));
        var wakes = WakeHarness{};
        try wakes.init();
        var staging: [64]u8 = undefined;
        var state: Transport = undefined;
        var prepared = activePrepared("head", .chunked, emptyTrailerPlan());
        if (variant == 0) {
            prepared.transmission.stream.framing.send_body = false;
        } else {
            prepared.transmission.stream.framing.emit_trailers = true;
        }

        const invalidation = try state.init(
            &workspace,
            prepared,
            &staging,
            wakes.value,
            .completed,
        );
        try expectActionOutcome(invalidation, .invalidate, .framework_canceled);
        _ = try settle(&state, &wakes, invalidation);
        try std.testing.expectEqual(Counts{ .aborts = 1, .joins = 1 }, counts);
        try wakes.deinit();
    }
}

test "completed trailer field count is bounded before alias scanning" {
    const field = response_stream.TrailerField{ .name = "x-one", .value = "value" };
    const fields = [_]response_stream.TrailerField{field} **
        (response_transfer.standard_trailer_limits.fields_max + 1);
    const steps = [_]Step{.{ .done = &fields }};
    var counts = Counts{};
    var workspace: FakeApp.Workspace = undefined;
    workspace.stream.init(response_stream.unknown(Producer{
        .steps = &steps,
        .counts = &counts,
    }, &.{}));
    var wakes = WakeHarness{};
    try wakes.init();
    var staging: [64]u8 = @splat(0xa5);
    var state: Transport = undefined;
    _ = try state.init(
        &workspace,
        activePrepared("head", .chunked, emptyTrailerPlan()),
        &staging,
        wakes.value,
        .completed,
    );
    const invalidation = try state.sent();
    try expectActionOutcome(invalidation, .invalidate, .producer_failed);
    _ = try settle(&state, &wakes, invalidation);
    try std.testing.expectEqual(Counts{ .polls = 1, .joins = 1 }, counts);
    try wakes.deinit();
}

test "security rejects declaration descriptor aliasing full response staging" {
    var staging: [256]u8 align(@alignOf([]const u8)) = @splat(0xa5);
    const descriptor: *([]const u8) = @ptrCast(@alignCast(&staging[128]));
    descriptor.* = "x-one";
    const declarations = @as([*]const []const u8, @ptrCast(descriptor))[0..1];
    try expectDeclarationAlias(&staging, declarations);
}

test "security rejects declaration name aliasing unused response staging tail" {
    var staging: [256]u8 = @splat(0xa5);
    @memcpy(staging[240..245], "x-one");
    const declarations = [_][]const u8{staging[240..245]};
    try expectDeclarationAlias(&staging, &declarations);
}

fn expectDeclarationAlias(staging: []u8, declarations: []const []const u8) !void {
    var counts = Counts{};
    const steps = [_]Step{.{ .done = &.{} }};
    var workspace: FakeApp.Workspace = undefined;
    workspace.stream.init(response_stream.unknown(Producer{
        .steps = &steps,
        .counts = &counts,
    }, declarations));
    var wakes = WakeHarness{};
    try wakes.init();
    var state: Transport = undefined;
    const plan = (try response_transfer.prepareTrailerPlan(
        response_transfer.standard_trailer_limits,
        declarations,
        true,
    )).plan;
    const prepared = activePrepared("head", .chunked, plan);

    const invalidation = try state.init(
        &workspace,
        prepared,
        staging,
        wakes.value,
        .completed,
    );
    try expectActionOutcome(invalidation, .invalidate, .producer_failed);
    _ = try settle(&state, &wakes, invalidation);
    try std.testing.expectEqual(Counts{ .aborts = 1, .joins = 1 }, counts);
    try wakes.deinit();
}

test "security rejects completed trailer name and value aliases without wire mutation" {
    var staging: [256]u8 = @splat(0xa5);
    @memcpy(staging[224..229], "x-one");
    @memcpy(staging[240..245], "value");
    const declarations = [_][]const u8{"x-one"};
    const fields = [_]response_stream.TrailerField{.{
        .name = staging[224..229],
        .value = staging[240..245],
    }};
    try expectRejectedDone(&staging, &declarations, &fields);
}

test "security rejects injected terminal field transactionally" {
    var staging: [256]u8 = @splat(0xa5);
    const declarations = [_][]const u8{"x-one"};
    const fields = [_]response_stream.TrailerField{.{
        .name = "x-one",
        .value = "safe\r\ninjected: yes",
    }};
    try expectRejectedDone(&staging, &declarations, &fields);
}

fn expectRejectedDone(
    staging: []u8,
    declarations: []const []const u8,
    fields: []const response_stream.TrailerField,
) !void {
    var counts = Counts{};
    const steps = [_]Step{.{ .done = fields }};
    var workspace: FakeApp.Workspace = undefined;
    workspace.stream.init(response_stream.unknown(Producer{
        .steps = &steps,
        .counts = &counts,
    }, declarations));
    var wakes = WakeHarness{};
    try wakes.init();
    var state: Transport = undefined;
    const plan = (try response_transfer.prepareTrailerPlan(
        response_transfer.standard_trailer_limits,
        declarations,
        true,
    )).plan;
    const prepared = activePrepared("head", .chunked, plan);
    _ = try state.init(&workspace, prepared, staging, wakes.value, .completed);
    try std.testing.expectEqual(@as(usize, 256), staging.len);
    var before: [256]u8 = undefined;
    @memcpy(&before, staging);

    const invalidation = try state.sent();
    try expectActionOutcome(invalidation, .invalidate, .producer_failed);
    try std.testing.expectEqualSlices(u8, &before, staging);
    _ = try settle(&state, &wakes, invalidation);
    try std.testing.expectEqual(Counts{ .polls = 1, .joins = 1 }, counts);
    try wakes.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
