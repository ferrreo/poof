const std = @import("std");
const builtin = @import("builtin");

const config_module = @import("load_driver_config.zig");
const engine = @import("load_driver_engine.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const bytes_max: usize = 16 * 1024;

const Buffer = struct {
    bytes: []u8,
    used: usize = 0,

    fn raw(self: *Buffer, value: []const u8) !void {
        if (value.len > self.bytes.len - self.used) return error.ReportTooLarge;
        @memcpy(self.bytes[self.used..][0..value.len], value);
        self.used += value.len;
    }

    fn format(self: *Buffer, comptime template: []const u8, args: anytype) !void {
        const rendered = std.fmt.bufPrint(self.bytes[self.used..], template, args) catch {
            return error.ReportTooLarge;
        };
        self.used += rendered.len;
    }

    fn string(self: *Buffer, value: []const u8) !void {
        try self.raw("\"");
        for (value) |byte| switch (byte) {
            '"' => try self.raw("\\\""),
            '\\' => try self.raw("\\\\"),
            '\n' => try self.raw("\\n"),
            '\r' => try self.raw("\\r"),
            '\t' => try self.raw("\\t"),
            else => if (byte < 0x20)
                try self.format("\\u00{x:0>2}", .{byte})
            else
                try self.raw(&.{byte}),
        };
        try self.raw("\"");
    }

    fn hex(self: *Buffer, value: []const u8) !void {
        try self.raw("\"");
        for (value) |byte| try self.format("{x:0>2}", .{byte});
        try self.raw("\"");
    }
};

pub fn render(
    output: []u8,
    config: config_module.Config,
    result: engine.Result,
) ![]const u8 {
    var buffer = Buffer{ .bytes = output };
    try renderIdentity(&buffer, config);
    try renderConfig(&buffer, config, result);
    try renderResults(&buffer, config, result);
    try renderHistogram(&buffer, result);
    try renderPercentiles(&buffer, result);
    try buffer.raw("}\n");
    return output[0..buffer.used];
}

fn renderIdentity(buffer: *Buffer, config: config_module.Config) !void {
    try buffer.raw("{\"schema_version\":1,\"driver\":\"ploof-load-driver\",");
    try buffer.raw("\"driver_version\":1,\"optimization_mode\":");
    try buffer.string(@tagName(builtin.mode));
    try buffer.raw(",\"scheduling_mode\":");
    try buffer.string(schedulingName(config.scheduling));
    try buffer.raw(",\"connections\":");
    try buffer.string(@tagName(config.connections));
    try buffer.format(",\"calibration\":{},\"calibration_kind\":", .{config.calibration});
    if (config.calibration) {
        try buffer.string("scheduler-request-loop-lower-bound");
    } else {
        try buffer.raw("null");
    }
    try buffer.raw(",");
}

fn renderConfig(
    buffer: *Buffer,
    config: config_module.Config,
    result: engine.Result,
) !void {
    try buffer.raw("\"config\":{\"address\":");
    try buffer.format(
        "\"{d}.{d}.{d}.{d}\",\"host\":",
        .{ config.address[0], config.address[1], config.address[2], config.address[3] },
    );
    try buffer.string(config.host);
    try buffer.format(",\"port\":{d},\"path\":", .{config.port});
    try buffer.string(config.path);
    try buffer.raw(",\"method\":");
    try buffer.string(config.method);
    try buffer.format(
        ",\"requests\":{d},\"concurrency\":{d},\"offered_rate_rps\":{d}," ++
            "\"timeout_ms\":{d},\"request_bytes\":{d},\"expected_status\":{d}," ++
            "\"expected_body_bytes\":{d},\"content_type\":",
        .{
            config.requests,
            config.concurrency,
            config.rate,
            config.timeout_ms,
            result.request_bytes_per_attempt,
            config.expected_status,
            expectedBodyLength(config),
        },
    );
    try buffer.string(config.content_type);
    try renderHeaders(buffer, config);
    try renderRequestBody(buffer, config, result);
    try renderExpectedBody(buffer, config);
    try buffer.raw("},");
}

fn renderHeaders(buffer: *Buffer, config: config_module.Config) !void {
    try buffer.raw(",\"headers\":[");
    for (config.headerSlice(), 0..) |header, index| {
        if (index != 0) try buffer.raw(",");
        try buffer.raw("{\"name\":");
        try buffer.string(header.name);
        try buffer.raw(",\"value\":");
        try buffer.string(header.value);
        try buffer.raw("}");
    }
    try buffer.raw("]");
}

fn renderRequestBody(
    buffer: *Buffer,
    config: config_module.Config,
    result: engine.Result,
) !void {
    try buffer.raw(",\"request_body\":{\"mode\":");
    try buffer.string(requestBodyMode(config));
    try buffer.format(",\"bytes\":{d},\"sha256\":", .{result.request_body_bytes});
    try buffer.hex(&result.request_body_sha256);
    try buffer.raw(",\"generated_byte\":");
    if (config.request_body_bytes != null) {
        try buffer.format("{d}", .{config.request_body_byte});
    } else {
        try buffer.raw("null");
    }
    try buffer.raw("}");
}

fn renderExpectedBody(buffer: *Buffer, config: config_module.Config) !void {
    var digest: [Sha256.digest_length]u8 = undefined;
    const mode: []const u8 = switch (config.expectedBody()) {
        .bytes => |bytes| value: {
            Sha256.hash(bytes, &digest, .{});
            break :value "inline";
        },
        .sha256 => |hashed| value: {
            digest = hashed.digest;
            break :value "sha256";
        },
    };
    try buffer.raw(",\"expected_body\":{\"mode\":");
    try buffer.string(mode);
    try buffer.format(",\"bytes\":{d},\"sha256\":", .{expectedBodyLength(config)});
    try buffer.hex(&digest);
    try buffer.raw("}");
}

fn renderResults(
    buffer: *Buffer,
    config: config_module.Config,
    result: engine.Result,
) !void {
    const capacity = result.requestsPerSecond();
    const ratio_milli = if (config.calibration and config.rate != 0)
        scaledRatio(capacity, 1000, config.rate)
    else
        0;
    try buffer.format(
        "\"results\":{{\"duration_ns\":{d},\"scheduled_requests\":{d}," ++
            "\"successful_requests\":{d},\"requests_per_second\":{d}," ++
            "\"bytes_per_second\":{d},\"request_wire_bytes\":{d}," ++
            "\"response_wire_bytes\":{d},\"transport_failures\":{d}," ++
            "\"connect_failures\":{d},\"send_failures\":{d}," ++
            "\"receive_failures\":{d},\"timeout_failures\":{d},",
        .{
            result.durationNs(),
            result.scheduled_requests,
            result.successful_requests,
            capacity,
            result.bytesPerSecond(),
            result.request_wire_bytes,
            result.response_wire_bytes,
            result.transport_failures,
            result.connect_failures,
            result.send_failures,
            result.receive_failures,
            result.timeout_failures,
        },
    );
    const calibration_capacity = if (config.calibration) capacity else 0;
    try renderApplicationResults(buffer, result, calibration_capacity, ratio_milli);
}

fn renderApplicationResults(
    buffer: *Buffer,
    result: engine.Result,
    calibration_capacity: u64,
    ratio_milli: u64,
) !void {
    try buffer.format(
        "\"application_failures\":{d},\"status_failures\":{d}," ++
            "\"identity_failures\":{d},\"parser_failures\":{d}," ++
            "\"late_starts\":{d},\"missed_starts\":{d}," ++
            "\"max_start_lateness_ns\":{d},\"calibration_capacity_rps\":{d}," ++
            "\"calibration_ratio_milli\":{d},\"calibration_checksum\":{d}}},",
        .{
            result.application_failures,
            result.status_failures,
            result.identity_failures,
            result.parser_failures,
            result.late_starts,
            result.missed_starts,
            result.max_start_lateness_ns,
            calibration_capacity,
            ratio_milli,
            result.calibration_checksum,
        },
    );
}

fn renderHistogram(buffer: *Buffer, result: engine.Result) !void {
    try buffer.raw(
        "\"latency_histogram\":{\"unit\":\"ns\",\"scheme\":" ++
            "\"log2-upper-bound\",\"samples\":",
    );
    try buffer.format("{d},\"buckets\":[", .{result.histogram.samples});
    for (result.histogram.buckets, 0..) |count, index| {
        if (index != 0) try buffer.raw(",");
        try buffer.format("{d}", .{count});
    }
    try buffer.raw("]},");
}

fn renderPercentiles(buffer: *Buffer, result: engine.Result) !void {
    try buffer.format(
        "\"percentiles_ns\":{{\"p50\":{d},\"p95\":{d},\"p99\":{d}," ++
            "\"p99_9\":{d}}}",
        .{
            result.histogram.percentile(50, 100),
            result.histogram.percentile(95, 100),
            result.histogram.percentile(99, 100),
            result.histogram.percentile(999, 1000),
        },
    );
}

fn expectedBodyLength(config: config_module.Config) u64 {
    return switch (config.expectedBody()) {
        .bytes => |bytes| bytes.len,
        .sha256 => |hashed| hashed.bytes,
    };
}

fn schedulingName(value: config_module.Scheduling) []const u8 {
    return switch (value) {
        .closed_loop => "closed-loop",
        .constant_rate => "constant-rate",
    };
}

fn requestBodyMode(config: config_module.Config) []const u8 {
    if (config.request_body_file != null) return "file";
    if (config.request_body_bytes != null) return "generated";
    return "inline";
}

fn scaledRatio(value: u64, scale: u64, denominator: u64) u64 {
    const ratio = @as(u128, value) * scale / denominator;
    return @intCast(@min(ratio, std.math.maxInt(u64)));
}

test "report is valid strict JSON with identity and percentiles" {
    var histogram = engine.Histogram{};
    histogram.record(100);
    var bytes: [bytes_max]u8 = undefined;
    const document = try render(&bytes, .{ .host = "app\\\"test" }, .{
        .histogram = histogram,
        .scheduled_requests = 1,
        .successful_requests = 1,
        .request_bytes_per_attempt = 100,
        .started_ns = 10,
        .finished_ns = 110,
    });
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        document,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "ploof-load-driver",
        parsed.value.object.get("driver").?.string,
    );
    const percentiles = parsed.value.object.get("percentiles_ns").?.object;
    try std.testing.expectEqual(@as(i64, 127), percentiles.get("p50").?.integer);
}

test "maximum escaped configuration fits fixed report storage" {
    const escaped = "\\" ** config_module.header_value_bytes_max;
    var config = config_module.Config{
        .path = "\\" ** config_module.path_bytes_max,
        .host = "\\" ** config_module.host_bytes_max,
        .content_type = "\\" ** 255,
    };
    for (0..config_module.headers_max) |index| {
        config.headers[index] = .{ .name = "X-Bounded", .value = escaped };
    }
    config.header_count = config_module.headers_max;
    var bytes: [bytes_max]u8 = undefined;
    const document = try render(&bytes, config, .{
        .request_body_sha256 = @splat(0),
        .started_ns = 1,
        .finished_ns = 2,
    });
    try std.testing.expect(document.len < bytes.len);
}
