const std = @import("std");

const access_log = @import("../src/access_log.zig");
const application = @import("../src/application.zig");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const metrics = @import("../src/metrics.zig");
const response = @import("../src/response.zig");
const route = @import("../src/route.zig");
const metrics_service = @import("../src/internal/runtime/server/metrics_service.zig");

const EventRing = access_log.Ring(8);
const WorkerMetrics = metrics.Worker(2);
const Snapshots = metrics.Coordinator(1, 2);
const MetricsApp = application.Application(.{
    .State = void,
    .routes = .{route.openMetrics("/metrics")},
});
const MetricsService = metrics_service.Service(MetricsApp);
const ClaimTag = std.meta.Tag(metrics_service.Claim);
const PollTag = std.meta.Tag(metrics_service.Poll);

test "observability pressure Smith preserves bounded queue and complete epochs" {
    try std.testing.fuzz({}, fuzzObservability, .{ .corpus = &corpus });
}

fn fuzzObservability(_: void, smith: *std.testing.Smith) !void {
    var ring = EventRing{};
    var reference = ReferenceQueue{};
    var worker = WorkerMetrics{};
    var active = [_]u16{0} ** 3;
    var coordinator = Snapshots{};
    var active_epoch: ?u64 = null;
    var published = false;
    var published_snapshot: ?metrics.Snapshot(2) = null;
    var output = metrics.Snapshot(2){};

    const actions = smith.valueRangeAtMost(u8, 1, 64);
    for (0..actions) |_| switch (smith.valueRangeAtMost(u8, 0, 7)) {
        0, 1 => try pushEvent(smith, &ring, &reference),
        2 => try popEvent(&ring, &reference),
        3 => admitRequest(smith, &worker, &active),
        4 => completeRequest(smith, &worker, &active),
        5 => beginSnapshot(&coordinator, &active_epoch, &published),
        6 => try publishSnapshot(
            &coordinator,
            &worker,
            active_epoch,
            &published,
            &published_snapshot,
        ),
        7 => try settleSnapshot(
            smith,
            &coordinator,
            &output,
            &active_epoch,
            &published,
            &published_snapshot,
        ),
        else => unreachable,
    };
    while (reference.count != 0) try popEvent(&ring, &reference);
    try std.testing.expectEqual(@as(u16, 0), ring.count());
    try std.testing.expectEqual(reference.dropped, ring.dropped());
    try expectMetricInvariants(&worker, &active);
    try fuzzMetricsService(smith);
}

fn fuzzMetricsService(smith: *std.testing.Smith) !void {
    var fixture = ServiceFixture{};
    try fixture.start();
    var current: ?metrics_service.Ticket = null;
    var stale: ?metrics_service.Ticket = null;
    var lease: ?Lease = null;
    var stopping = false;
    const actions = smith.valueRangeAtMost(u8, 1, 64);
    for (0..actions) |_| {
        reconcileService(&fixture, &current, &stale, &lease) catch unreachable;
        switch (smith.valueRangeAtMost(u8, 0, 7)) {
            0 => try claimService(smith, &fixture, stopping, &current),
            1 => _ = fixture.service.__fuzzStep(),
            2 => try cancelService(&fixture, &current, &stale, &lease),
            3 => try releaseService(&fixture, &current, &stale, &lease),
            4 => try expectStaleOperations(&fixture, stale),
            5 => if (stale) |ticket| fixture.wake().signal(ticket),
            6 => {
                stopping = true;
                fixture.service.requestStop();
            },
            7 => try expectLease(&fixture, current, lease, stopping),
            else => unreachable,
        }
    }
    try stopService(&fixture, &current, &stale, &lease);
}

fn claimService(
    smith: *std.testing.Smith,
    fixture: *ServiceFixture,
    stopping: bool,
    current: *?metrics_service.Ticket,
) !void {
    const deadline: u64 = if (smith.value(bool)) std.math.maxInt(u64) else 1;
    const claim = fixture.service.claim(deadline, fixture.wake());
    if (stopping) return std.testing.expectEqual(ClaimTag.stopping, std.meta.activeTag(claim));
    if (current.* != null) {
        return std.testing.expectEqual(ClaimTag.busy, std.meta.activeTag(claim));
    }
    current.* = switch (claim) {
        .accepted => |ticket| ticket,
        .busy, .stopping => return error.UnexpectedClaim,
    };
}

fn cancelService(
    fixture: *ServiceFixture,
    current: *?metrics_service.Ticket,
    stale: *?metrics_service.Ticket,
    lease: *?Lease,
) !void {
    const ticket = current.* orelse return;
    switch (fixture.service.cancel(ticket)) {
        .pending => {},
        .cancelled => {
            stale.* = ticket;
            current.* = null;
            lease.* = null;
        },
        .stale => return error.CurrentTicketBecameStale,
    }
}

fn releaseService(
    fixture: *ServiceFixture,
    current: *?metrics_service.Ticket,
    stale: *?metrics_service.Ticket,
    lease: *?Lease,
) !void {
    const ticket = current.* orelse return;
    const ready = switch (fixture.service.poll(ticket)) {
        .success, .unavailable => true,
        .pending => false,
        .stale => return error.CurrentTicketBecameStale,
    };
    try std.testing.expectEqual(ready, fixture.service.release(ticket));
    if (!ready) return;
    stale.* = ticket;
    current.* = null;
    lease.* = null;
}

fn reconcileService(
    fixture: *ServiceFixture,
    current: *?metrics_service.Ticket,
    stale: *?metrics_service.Ticket,
    lease: *?Lease,
) !void {
    const ticket = current.* orelse return;
    switch (fixture.service.poll(ticket)) {
        .pending, .unavailable => lease.* = null,
        .success => |body| {
            try std.testing.expect(std.mem.endsWith(u8, body, "# EOF\n"));
            const observed = Lease.capture(body);
            if (lease.*) |held| try std.testing.expectEqualDeep(held, observed);
            lease.* = observed;
        },
        .stale => {
            stale.* = ticket;
            current.* = null;
            lease.* = null;
        },
    }
}

fn expectStaleOperations(fixture: *ServiceFixture, stale: ?metrics_service.Ticket) !void {
    const ticket = stale orelse return;
    try std.testing.expectEqual(
        PollTag.stale,
        std.meta.activeTag(fixture.service.poll(ticket)),
    );
    try std.testing.expectEqual(metrics_service.Cancel.stale, fixture.service.cancel(ticket));
    try std.testing.expect(!fixture.service.release(ticket));
}

fn expectLease(
    fixture: *ServiceFixture,
    current: ?metrics_service.Ticket,
    lease: ?Lease,
    stopping: bool,
) !void {
    const ticket = current orelse return;
    switch (fixture.service.poll(ticket)) {
        .success => |body| try std.testing.expectEqualDeep(lease.?, Lease.capture(body)),
        .unavailable => try std.testing.expect(lease == null),
        .pending => return,
        .stale => return error.CurrentTicketBecameStale,
    }
    const claim = fixture.service.claim(std.math.maxInt(u64), fixture.wake());
    const expected: ClaimTag = if (stopping) .stopping else .busy;
    try std.testing.expectEqual(expected, std.meta.activeTag(claim));
}

fn stopService(
    fixture: *ServiceFixture,
    current: *?metrics_service.Ticket,
    stale: *?metrics_service.Ticket,
    lease: *?Lease,
) !void {
    fixture.service.requestStop();
    if (current.*) |ticket| switch (fixture.service.cancel(ticket)) {
        .pending => {},
        .cancelled, .stale => {
            stale.* = ticket;
            current.* = null;
            lease.* = null;
        },
    };
    _ = fixture.service.__fuzzStep();
    try reconcileService(fixture, current, stale, lease);
    try std.testing.expect(fixture.service.__fuzzStep());
    try std.testing.expect(fixture.service.isTerminal());
}

const Lease = struct {
    address: usize,
    length: usize,
    hash: u64,

    fn capture(body: []const u8) Lease {
        return .{
            .address = @intFromPtr(body.ptr),
            .length = body.len,
            .hash = std.hash.Wyhash.hash(0, body),
        };
    }
};

const ServiceFixture = struct {
    service: MetricsService = .{},
    snapshot_calls: u32 = 0,
    wake_count: u32 = 0,
    last_wake: u64 = 0,
    last_identity: u64 = 0,

    fn start(self: *ServiceFixture) !void {
        try self.service.__fuzzStartWithClock(self, snapshot, self, now);
    }

    fn wake(self: *ServiceFixture) metrics_service.Wake {
        return .{
            .context = self,
            .identity = .{ .stream_generation = self.wake_count + 1 },
            .notify = notified,
        };
    }

    fn snapshot(
        context: *anyopaque,
        _: u64,
        output: *MetricsService.MetricsSnapshot,
    ) !void {
        const self: *ServiceFixture = @ptrCast(@alignCast(context));
        self.snapshot_calls +|= 1;
        output.* = .{ .epoch = self.snapshot_calls };
    }

    fn now(_: *anyopaque) !u64 {
        return 2;
    }

    fn notified(
        context: *anyopaque,
        ticket: metrics_service.Ticket,
        identity: metrics_service.WakeIdentity,
    ) void {
        const self: *ServiceFixture = @ptrCast(@alignCast(context));
        self.wake_count +|= 1;
        self.last_wake = ticket.generation;
        self.last_identity = identity.service_generation;
        std.debug.assert(identity.stream_generation != 0);
    }
};

fn pushEvent(
    smith: *std.testing.Smith,
    ring: *EventRing,
    reference: *ReferenceQueue,
) !void {
    const event = generatedEvent(smith);
    const expected = reference.push(event);
    try std.testing.expectEqual(expected, ring.push(event));
    var output: [access_log.max_record_bytes]u8 = undefined;
    const encoded = try access_log.formatNdjson(event, &output);
    try std.testing.expect(encoded.len != 0 and encoded[encoded.len - 1] == '\n');
    try std.testing.expect(std.mem.indexOf(u8, encoded, "request-canary") == null);
}

fn popEvent(ring: *EventRing, reference: *ReferenceQueue) !void {
    const expected = reference.pop();
    const actual = ring.pop();
    try std.testing.expectEqual(expected == null, actual == null);
    if (expected) |event| try std.testing.expectEqualDeep(event, actual.?);
}

fn admitRequest(
    smith: *std.testing.Smith,
    worker: *WorkerMetrics,
    active: *[3]u16,
) void {
    const route_index = smith.valueRangeAtMost(u8, 0, 2);
    const route_id: ?u16 = if (route_index == 2) null else route_index;
    const method: metrics.MethodClass = @enumFromInt(
        smith.valueRangeAtMost(u8, 0, @typeInfo(metrics.MethodClass).@"enum".fields.len - 1),
    );
    worker.admit(route_id, method);
    active[route_index] += 1;
}

fn completeRequest(
    smith: *std.testing.Smith,
    worker: *WorkerMetrics,
    active: *[3]u16,
) void {
    const route_index = smith.valueRangeAtMost(u8, 0, 2);
    if (active[route_index] == 0) return;
    const route_id: ?u16 = if (route_index == 2) null else route_index;
    const status_value = smith.valueRangeAtMost(u16, 200, 599);
    const status: ?response.Status = if (smith.value(bool))
        @enumFromInt(status_value)
    else
        null;
    const transport: application.TransportOutcome = @enumFromInt(smith.valueRangeAtMost(
        u8,
        0,
        @typeInfo(application.TransportOutcome).@"enum".fields.len - 1,
    ));
    worker.complete(route_id, .{
        .status = status,
        .mapped_error = status != null and smith.value(bool),
        .transport = transport,
        .duration_ns = smith.value(u32),
        .request_wire_bytes = smith.value(u16),
        .request_decoded_bytes = smith.value(u16),
        .response_wire_bytes = smith.value(u16),
    });
    active[route_index] -= 1;
}

fn beginSnapshot(
    coordinator: *Snapshots,
    active_epoch: *?u64,
    published: *bool,
) void {
    const result = coordinator.begin();
    if (active_epoch.* == null) {
        active_epoch.* = result catch unreachable;
        published.* = false;
    } else {
        std.testing.expectError(error.SnapshotActive, result) catch unreachable;
    }
}

fn publishSnapshot(
    coordinator: *Snapshots,
    worker: *const WorkerMetrics,
    active_epoch: ?u64,
    published: *bool,
    published_snapshot: *?metrics.Snapshot(2),
) !void {
    const result = try coordinator.publish(0, worker);
    try std.testing.expectEqual(active_epoch != null and !published.*, result);
    if (result) {
        published.* = true;
        published_snapshot.* = worker.snapshot(active_epoch.?);
    }
}

fn settleSnapshot(
    smith: *std.testing.Smith,
    coordinator: *Snapshots,
    output: *metrics.Snapshot(2),
    active_epoch: *?u64,
    published: *bool,
    published_snapshot: *?metrics.Snapshot(2),
) !void {
    const epoch = active_epoch.* orelse return;
    if (smith.value(bool)) {
        try coordinator.cancel(epoch);
        active_epoch.* = null;
        published.* = false;
        published_snapshot.* = null;
        return;
    }
    const result = coordinator.complete(epoch, output);
    if (!published.*) {
        try std.testing.expectError(error.SnapshotPending, result);
        return;
    }
    try result;
    try std.testing.expectEqual(epoch, output.epoch);
    try std.testing.expectEqualDeep(published_snapshot.*.?, output.*);
    active_epoch.* = null;
    published.* = false;
    published_snapshot.* = null;
}

fn expectMetricInvariants(worker: *const WorkerMetrics, active: *const [3]u16) !void {
    for (worker.routes, 0..) |cell, index| {
        try std.testing.expectEqual(@as(u32, active[index]), cell.active);
        try std.testing.expect(cell.completed <= cell.admitted);
        try std.testing.expectEqual(cell.completed, sum(&cell.statuses));
        try std.testing.expectEqual(cell.completed, sum(&cell.application_outcomes));
        try std.testing.expectEqual(cell.completed, sum(&cell.transport_outcomes));
        try std.testing.expectEqual(cell.completed, sum(&cell.latency));
    }
}

fn generatedEvent(smith: *std.testing.Smith) access_log.AccessEvent {
    const method: metrics.MethodClass = @enumFromInt(
        smith.valueRangeAtMost(
            u8,
            0,
            @typeInfo(metrics.MethodClass).@"enum".fields.len - 1,
        ),
    );
    const route_id: ?u16 = if (smith.value(bool)) smith.value(u8) else null;
    const status: ?response.Status = if (smith.value(bool))
        @enumFromInt(smith.valueRangeAtMost(u16, 200, 599))
    else
        null;
    const transport: application.TransportOutcome = @enumFromInt(smith.valueRangeAtMost(
        u8,
        0,
        @typeInfo(application.TransportOutcome).@"enum".fields.len - 1,
    ));
    return access_log.AccessEvent.init(
        method,
        route_id,
        .{
            .status = status,
            .mapped_error = status != null and smith.value(bool),
            .transport = transport,
        },
        smith.value(u32),
        .{
            .request_wire = smith.value(u16),
            .request_decoded = smith.value(u16),
            .response_wire = smith.value(u16),
        },
    );
}

fn sum(values: []const u64) u64 {
    var total: u64 = 0;
    for (values) |value| total += value;
    return total;
}

const ReferenceQueue = struct {
    events: [8]access_log.AccessEvent = undefined,
    read: usize = 0,
    count: usize = 0,
    dropped: u64 = 0,

    fn push(queue: *ReferenceQueue, event: access_log.AccessEvent) bool {
        if (queue.count == queue.events.len) {
            queue.dropped += 1;
            return false;
        }
        const index = (queue.read + queue.count) % queue.events.len;
        queue.events[index] = event;
        queue.count += 1;
        return true;
    }

    fn pop(queue: *ReferenceQueue) ?access_log.AccessEvent {
        if (queue.count == 0) return null;
        const event = queue.events[queue.read];
        queue.read = (queue.read + 1) % queue.events.len;
        queue.count -= 1;
        return event;
    }
};

const corpus = struct {
    const empty = fuzz_support.smithInput("");
    const pressure = fuzz_support.smithInput("push-pop-snapshot-pressure");
    const cancel = fuzz_support.smithInput("cancel-publish-complete");
    const values = [_][]const u8{ &empty, &pressure, &cancel };
}.values;
