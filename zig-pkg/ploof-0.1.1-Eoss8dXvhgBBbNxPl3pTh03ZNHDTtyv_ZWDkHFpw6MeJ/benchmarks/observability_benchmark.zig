const std = @import("std");
const sigbench = @import("sigbench");

const access_log = @import("../src/access_log.zig");
const metrics = @import("../src/metrics.zig");
const open_metrics = @import("../src/open_metrics.zig");
const route = @import("../src/route.zig");

const route_count: u16 = 2;
const WorkerMetrics = metrics.Worker(route_count);
const Snapshot = metrics.Snapshot(route_count);
const Snapshots = metrics.Coordinator(4, route_count);
const EventRing = access_log.Ring(256);

const MetricApp = struct {
    const Definition = struct {
        method: route.Method,
        path: []const u8,
    };

    pub const route_definitions = [_]Definition{
        .{ .method = .get, .path = "/health" },
        .{ .method = .post, .path = "/users/:id" },
    };
};

const OpenMetrics = open_metrics.Formatter(MetricApp);

const event = access_log.AccessEvent.init(
    .post,
    1,
    .{ .status = .created, .mapped_error = false, .transport = .completed },
    28_000,
    .{ .request_wire = 384, .request_decoded = 256, .response_wire = 512 },
);

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof observability benchmark validity check failed");
}

fn benchRequestMetrics(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            var worker = WorkerMetrics{};
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                worker.admit(1, .post);
                worker.complete(1, .{
                    .status = .created,
                    .mapped_error = false,
                    .transport = .completed,
                    .duration_ns = 28_000,
                    .request_wire_bytes = 384,
                    .request_decoded_bytes = 256,
                    .response_wire_bytes = 512,
                });
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (worker.routes[1].completed != iterations) benchmarkFailure();
            std.mem.doNotOptimizeAway(&worker);
            return elapsed_ns;
        }
    }.run);
}

fn benchAccessRing(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            var ring = EventRing{};
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                if (!ring.push(event)) benchmarkFailure();
                const selected = ring.pop() orelse benchmarkFailure();
                std.mem.doNotOptimizeAway(&selected);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (ring.count() != 0 or ring.dropped() != 0) benchmarkFailure();
            std.mem.doNotOptimizeAway(&ring);
            return elapsed_ns;
        }
    }.run);
}

fn benchAccessFormat(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            var output: [access_log.max_record_bytes]u8 = undefined;
            var length: usize = 0;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                const record = access_log.formatNdjson(event, &output) catch benchmarkFailure();
                length = record.len;
                std.mem.doNotOptimizeAway(record);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (length == 0) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn benchmarkWorkers() [4]WorkerMetrics {
    var workers = [4]WorkerMetrics{ .{}, .{}, .{}, .{} };
    for (&workers, 0..) |*worker, index| {
        const route_id: u16 = @intCast(index % @as(usize, route_count));
        worker.admit(route_id, .get);
        worker.complete(route_id, .{
            .status = .ok,
            .mapped_error = false,
            .transport = .completed,
            .duration_ns = 1_000,
        });
    }
    return workers;
}

fn benchSnapshot(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            var coordinator = Snapshots{};
            var workers = benchmarkWorkers();
            var output = Snapshot{};
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                const epoch = coordinator.begin() catch benchmarkFailure();
                for (&workers, 0..) |*worker, index| {
                    if (!(coordinator.publish(@intCast(index), worker) catch
                        benchmarkFailure())) benchmarkFailure();
                }
                coordinator.complete(epoch, &output) catch benchmarkFailure();
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (output.routes[0].completed != 2) benchmarkFailure();
            std.mem.doNotOptimizeAway(&coordinator);
            std.mem.doNotOptimizeAway(&output);
            return elapsed_ns;
        }
    }.run);
}

fn benchOpenMetrics(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            var snapshot = Snapshot{ .epoch = 1 };
            snapshot.routes[1].admit(.post);
            snapshot.routes[1].complete(.{
                .status = .created,
                .mapped_error = false,
                .transport = .completed,
                .duration_ns = 28_000,
            });
            var output: [OpenMetrics.bytes_max]u8 = undefined;
            var length: usize = 0;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                const body = OpenMetrics.format(&snapshot, &output) catch benchmarkFailure();
                length = body.len;
                std.mem.doNotOptimizeAway(body);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (length == 0) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

pub const group = sigbench.groupWithId("m13-observability", "M13 observability", .{
    sigbench.benchWithThroughput(
        "request-metrics",
        "one admitted and completed request",
        .{ .elements = 1 },
        benchRequestMetrics,
    ),
    sigbench.benchWithThroughput(
        "access-ring",
        "one access-event enqueue and dequeue",
        .{ .elements = 1 },
        benchAccessRing,
    ),
    sigbench.benchWithThroughput(
        "access-ndjson",
        "one fixed-schema access record",
        .{ .elements = 1 },
        benchAccessFormat,
    ),
    sigbench.benchWithThroughput(
        "four-worker-snapshot",
        "one complete four-worker metrics snapshot",
        .{ .elements = 4 },
        benchSnapshot,
    ),
    sigbench.benchWithThroughput(
        "openmetrics-two-routes",
        "one complete two-route OpenMetrics exposition",
        .{ .elements = 3 },
        benchOpenMetrics,
    ),
});
