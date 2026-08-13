const std = @import("std");

const application = @import("application.zig");
const metrics = @import("metrics.zig");
const response = @import("response.zig");
const route_module = @import("route.zig");

pub const content_type = response.staticMediaType(
    "application/openmetrics-text; version=1.0.0; charset=utf-8",
);
pub const unavailable_body = "metrics unavailable\n";
pub const handler = route_module.open_metrics_handler;

pub const route = route_module.openMetrics;
pub const configured = route_module.openMetricsConfigured;

pub const Error = error{
    IncompleteSnapshot,
    NoSpaceLeft,
};

const header =
    "# TYPE ploof_http_requests_admitted_total counter\n" ++
    "# TYPE ploof_http_requests_active gauge\n" ++
    "# TYPE ploof_http_requests_active_high_water gauge\n" ++
    "# TYPE ploof_http_requests_completed_total counter\n" ++
    "# TYPE ploof_http_request_wire_bytes_total counter\n" ++
    "# TYPE ploof_http_request_decoded_bytes_total counter\n" ++
    "# TYPE ploof_http_response_wire_bytes_total counter\n" ++
    "# TYPE ploof_http_requests_by_method_total counter\n" ++
    "# TYPE ploof_http_requests_by_status_class_total counter\n" ++
    "# TYPE ploof_http_requests_by_application_outcome_total counter\n" ++
    "# TYPE ploof_http_requests_by_transport_outcome_total counter\n" ++
    "# TYPE ploof_http_request_duration_seconds histogram\n" ++
    "# TYPE ploof_runtime_counter_total counter\n" ++
    "# TYPE ploof_runtime_gauge gauge\n" ++
    "# TYPE ploof_runtime_gauge_high_water gauge\n";

const RouteLabel = struct {
    method: []const u8,
    path: []const u8,
    matched: bool,
};

const Dimension = struct {
    name: []const u8,
    value: []const u8,
};

const Cursor = struct {
    output: []u8,
    used: usize = 0,

    fn append(cursor: *Cursor, input: []const u8) Error!void {
        if (input.len > cursor.output.len - cursor.used) return error.NoSpaceLeft;
        @memcpy(cursor.output[cursor.used..][0..input.len], input);
        cursor.used += input.len;
    }

    fn print(cursor: *Cursor, comptime format: []const u8, args: anytype) Error!void {
        const written = std.fmt.bufPrint(cursor.output[cursor.used..], format, args) catch {
            return error.NoSpaceLeft;
        };
        cursor.used += written.len;
    }

    fn bytes(cursor: *const Cursor) []const u8 {
        return cursor.output[0..cursor.used];
    }
};

pub fn Formatter(comptime App: type) type {
    if (!@hasDecl(App, "route_definitions")) {
        @compileError("PLOOF-E6300 OpenMetrics formatter requires a Ploof Application type");
    }
    if (App.route_definitions.len > std.math.maxInt(u16)) {
        @compileError("PLOOF-E6301 OpenMetrics route count exceeds u16");
    }
    const route_count: u16 = @intCast(App.route_definitions.len);
    const Snapshot = metrics.Snapshot(route_count);
    const series_count = metrics.Worker(route_count).profile().series_count;
    const output_max = checkedOutputMax(App, series_count);

    return struct {
        pub const bytes_max = output_max;
        pub const MetricsSnapshot = Snapshot;

        pub fn format(snapshot: *const Snapshot, output: []u8) Error![]const u8 {
            if (snapshot.epoch == 0) return error.IncompleteSnapshot;
            var cursor = Cursor{ .output = output };
            try cursor.append(header);
            for (App.route_definitions, 0..) |definition, route_index| {
                try writeRoute(
                    &cursor,
                    .{
                        .method = definition.method.wire(),
                        .path = definition.path,
                        .matched = true,
                    },
                    snapshot.routes[route_index],
                );
            }
            try writeRoute(
                &cursor,
                .{ .method = "", .path = "", .matched = false },
                snapshot.routes[route_count],
            );
            try writeRuntime(&cursor, snapshot.runtime);
            try cursor.append("# EOF\n");
            std.debug.assert(cursor.used <= bytes_max);
            return cursor.bytes();
        }
    };
}

fn writeRoute(cursor: *Cursor, label: RouteLabel, cell: metrics.RouteCell) Error!void {
    try writeRouteValue(cursor, "ploof_http_requests_admitted_total", label, null, cell.admitted);
    try writeRouteValue(cursor, "ploof_http_requests_active", label, null, cell.active);
    try writeRouteValue(
        cursor,
        "ploof_http_requests_active_high_water",
        label,
        null,
        cell.active_high_water,
    );
    try writeRouteValue(cursor, "ploof_http_requests_completed_total", label, null, cell.completed);
    try writeRouteBytes(cursor, label, cell);
    inline for (std.enums.values(metrics.MethodClass)) |class| try writeRouteValue(
        cursor,
        "ploof_http_requests_by_method_total",
        label,
        .{ .name = "method", .value = @tagName(class) },
        cell.methods[@intFromEnum(class)],
    );
    inline for (std.enums.values(metrics.StatusClass)) |class| try writeRouteValue(
        cursor,
        "ploof_http_requests_by_status_class_total",
        label,
        .{ .name = "status_class", .value = @tagName(class) },
        cell.statuses[@intFromEnum(class)],
    );
    try writeRouteOutcomes(cursor, label, cell);
    try writeLatency(cursor, label, cell);
}

fn writeRouteBytes(cursor: *Cursor, label: RouteLabel, cell: metrics.RouteCell) Error!void {
    try writeRouteValue(
        cursor,
        "ploof_http_request_wire_bytes_total",
        label,
        null,
        cell.request_wire_bytes,
    );
    try writeRouteValue(
        cursor,
        "ploof_http_request_decoded_bytes_total",
        label,
        null,
        cell.request_decoded_bytes,
    );
    try writeRouteValue(
        cursor,
        "ploof_http_response_wire_bytes_total",
        label,
        null,
        cell.response_wire_bytes,
    );
}

fn writeRouteOutcomes(cursor: *Cursor, label: RouteLabel, cell: metrics.RouteCell) Error!void {
    inline for (std.enums.values(metrics.ApplicationOutcome)) |outcome| try writeRouteValue(
        cursor,
        "ploof_http_requests_by_application_outcome_total",
        label,
        .{ .name = "outcome", .value = @tagName(outcome) },
        cell.application_outcomes[@intFromEnum(outcome)],
    );
    inline for (std.enums.values(application.TransportOutcome)) |outcome| try writeRouteValue(
        cursor,
        "ploof_http_requests_by_transport_outcome_total",
        label,
        .{ .name = "outcome", .value = @tagName(outcome) },
        cell.transport_outcomes[@intFromEnum(outcome)],
    );
}

fn writeLatency(cursor: *Cursor, label: RouteLabel, cell: metrics.RouteCell) Error!void {
    var cumulative: u64 = 0;
    for (cell.latency, 0..) |count, bucket| {
        cumulative +|= count;
        try beginRouteValue(cursor, "ploof_http_request_duration_seconds_bucket", label);
        try cursor.append(",le=\"");
        if (metrics.latencyBucketUpperNs(bucket)) |upper_ns| {
            try writeSeconds(cursor, upper_ns);
        } else {
            try cursor.append("+Inf");
        }
        try cursor.print("\"}} {d}\n", .{cumulative});
    }
    try beginRouteValue(cursor, "ploof_http_request_duration_seconds_sum", label);
    try cursor.append("} ");
    try writeSeconds(cursor, cell.latency_ns_total);
    try cursor.append("\n");
    try writeRouteValue(
        cursor,
        "ploof_http_request_duration_seconds_count",
        label,
        null,
        cell.completed,
    );
}

fn writeRouteValue(
    cursor: *Cursor,
    name: []const u8,
    label: RouteLabel,
    dimension: ?Dimension,
    value: anytype,
) Error!void {
    try beginRouteValue(cursor, name, label);
    if (dimension) |selected| {
        try cursor.append(",");
        try cursor.append(selected.name);
        try cursor.append("=\"");
        try writeLabel(cursor, selected.value);
        try cursor.append("\"");
    }
    try cursor.print("}} {d}\n", .{value});
}

fn beginRouteValue(cursor: *Cursor, name: []const u8, label: RouteLabel) Error!void {
    try cursor.append(name);
    try cursor.append("{route=\"");
    if (label.matched) {
        try writeLabel(cursor, label.method);
        try cursor.append(" ");
        try writeLabel(cursor, label.path);
    } else {
        try cursor.append("unmatched");
    }
    try cursor.append("\"");
}

fn writeRuntime(cursor: *Cursor, runtime: metrics.RuntimeCells) Error!void {
    inline for (std.enums.values(metrics.RuntimeCounter)) |counter| {
        try cursor.print(
            "ploof_runtime_counter_total{{class=\"{s}\"}} {d}\n",
            .{ @tagName(counter), runtime.counters[@intFromEnum(counter)] },
        );
    }
    inline for (std.enums.values(metrics.RuntimeGauge)) |gauge| {
        const value = runtime.gauges[@intFromEnum(gauge)];
        try cursor.print(
            "ploof_runtime_gauge{{class=\"{s}\"}} {d}\n",
            .{ @tagName(gauge), value.current },
        );
        try cursor.print(
            "ploof_runtime_gauge_high_water{{class=\"{s}\"}} {d}\n",
            .{ @tagName(gauge), value.high_water },
        );
    }
}

fn writeLabel(cursor: *Cursor, value: []const u8) Error!void {
    for (value) |byte| switch (byte) {
        '\\' => try cursor.append("\\\\"),
        '"' => try cursor.append("\\\""),
        '\n' => try cursor.append("\\n"),
        else => try cursor.append(&.{byte}),
    };
}

fn writeSeconds(cursor: *Cursor, nanoseconds: u64) Error!void {
    const whole = nanoseconds / std.time.ns_per_s;
    const fraction = nanoseconds % std.time.ns_per_s;
    try cursor.print("{d}.{d:0>9}", .{ whole, fraction });
}

fn checkedOutputMax(comptime App: type, series_count: u32) usize {
    const series_bytes = std.math.mul(u64, series_count, 256) catch {
        @compileError("PLOOF-E6302 OpenMetrics output bound overflows u64");
    };
    const route_label_bytes = comptime routeLabelBytes(App);
    const repeated_labels = std.math.mul(
        u64,
        route_label_bytes,
        metrics.route_series_per_slot,
    ) catch @compileError("PLOOF-E6302 OpenMetrics output bound overflows u64");
    const with_labels = std.math.add(u64, series_bytes, repeated_labels) catch {
        @compileError("PLOOF-E6302 OpenMetrics output bound overflows u64");
    };
    const total = std.math.add(u64, with_labels, 4096) catch {
        @compileError("PLOOF-E6302 OpenMetrics output bound overflows u64");
    };
    if (total > std.math.maxInt(usize)) {
        @compileError("PLOOF-E6303 OpenMetrics output bound exceeds usize");
    }
    return @intCast(total);
}

fn routeLabelBytes(comptime App: type) u64 {
    var total: u64 = "unmatched".len;
    for (App.route_definitions) |definition| {
        total += escapedLabelBytes(definition.method.wire());
        total += 1;
        total += escapedLabelBytes(definition.path);
    }
    return total;
}

fn escapedLabelBytes(value: []const u8) u64 {
    return std.math.mul(u64, value.len, 2) catch {
        @compileError("PLOOF-E6302 OpenMetrics output bound overflows u64");
    };
}

const TestContext = application.Context(void, response.standard_head_limits);

fn testHandler(context: *TestContext) TestContext.ResponseType {
    return context.empty(.no_content);
}

const TestApp = application.Application(.{
    .State = void,
    .routes = .{
        route_module.get("/things/:id", testHandler),
        route_module.post("/things", testHandler),
    },
});

test "formatter emits complete static route and unmatched inventories" {
    const Format = Formatter(TestApp);
    var snapshot = metrics.Snapshot(2){ .epoch = 7 };
    snapshot.routes[0].admitted = 3;
    snapshot.routes[0].completed = 2;
    snapshot.routes[0].latency[0] = 1;
    snapshot.routes[0].latency[1] = 1;
    snapshot.routes[0].latency_ns_total = 2500;
    snapshot.runtime.counters[@intFromEnum(metrics.RuntimeCounter.progress_timeouts)] = 4;
    var output: [Format.bytes_max]u8 = undefined;
    const rendered = try Format.format(&snapshot, &output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "ploof_http_requests_admitted_total{route=\"GET /things/:id\"} 3\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "ploof_http_requests_admitted_total{route=\"unmatched\"} 0\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "ploof_runtime_counter_total{class=\"progress_timeouts\"} 4\n",
    ) != null);
    try std.testing.expect(std.mem.endsWith(u8, rendered, "# EOF\n"));
    try std.testing.expect(rendered.len <= Format.bytes_max);
}

test "formatter rejects partial epochs and insufficient output transactionally" {
    const Format = Formatter(TestApp);
    var snapshot = metrics.Snapshot(2){};
    var output: [Format.bytes_max]u8 = undefined;
    try std.testing.expectError(error.IncompleteSnapshot, Format.format(&snapshot, &output));
    snapshot.epoch = 1;
    try std.testing.expectError(error.NoSpaceLeft, Format.format(&snapshot, output[0..32]));
}

test "OpenMetrics label escaping never emits raw quote slash or newline" {
    var output: [64]u8 = undefined;
    var cursor = Cursor{ .output = &output };
    try writeLabel(&cursor, "a\\b\"c\nd");
    try std.testing.expectEqualStrings("a\\\\b\\\"c\\nd", cursor.bytes());
}

test "latency bounds use finite microsecond powers and one infinity bucket" {
    try std.testing.expectEqual(@as(?u64, 1000), metrics.latencyBucketUpperNs(0));
    try std.testing.expectEqual(@as(?u64, 2000), metrics.latencyBucketUpperNs(1));
    try std.testing.expectEqual(
        @as(?u64, null),
        metrics.latencyBucketUpperNs(metrics.latency_bucket_count - 1),
    );
    try std.testing.expectEqual(@as(usize, 0), metrics.latencyBucket(1000));
    try std.testing.expectEqual(@as(usize, 1), metrics.latencyBucket(1001));
}

test "advertised output bound includes long escaped static route labels" {
    const LongApp = struct {
        const Definition = struct { method: route_module.Method, path: []const u8 };
        const long_path = "/" ++ ([_]u8{'x'} ** 8192) ++ "\\\"\n";
        pub const route_definitions = [_]Definition{
            .{ .method = .get, .path = long_path },
        };
    };
    const Format = Formatter(LongApp);
    const snapshot = metrics.Snapshot(1){ .epoch = 1 };
    var output: [Format.bytes_max]u8 = undefined;
    const rendered = try Format.format(&snapshot, &output);
    try std.testing.expect(rendered.len <= output.len);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\\\\\\\"\\n") != null);
}
