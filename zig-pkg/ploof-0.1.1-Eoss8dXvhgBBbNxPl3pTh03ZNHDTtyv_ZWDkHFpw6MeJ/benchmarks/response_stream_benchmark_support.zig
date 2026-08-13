const std = @import("std");

pub const Metric = struct {
    id: []const u8,
    scope: []const u8,
    framing: []const u8,
    payload_bytes: usize,
    request_bytes: usize,
    wire_bytes: usize,
    producer_polls: usize,
    send_actions: usize,
    send_completions: usize,
    eventfd_notifications: usize,
    eventfd_drains: usize,
    request_slots: usize = 0,
    ready_slots: usize = 0,
    callback_dispatches: usize = 0,
    runtime_completions: usize = 0,
};

pub fn writeMetrics(
    init: std.process.Init,
    output_root: []const u8,
    metrics: []const Metric,
) !void {
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try std.fmt.bufPrint(
        &directory_storage,
        "{s}/response-stream",
        .{output_root},
    );
    try std.Io.Dir.cwd().createDirPath(init.io, directory);

    var json_storage: [16 * 1024]u8 = undefined;
    var json = std.Io.Writer.fixed(&json_storage);
    try json.writeAll("{\n  \"format\": 1,\n  \"entries\": [\n");
    for (metrics, 0..) |metric, index| {
        if (index != 0) try json.writeAll(",\n");
        try writeMetric(&json, metric);
    }
    try json.writeAll("\n  ]\n}\n");

    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "{s}/metrics.json", .{directory});
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = path,
        .data = json.buffered(),
    });
}

fn writeMetric(writer: *std.Io.Writer, metric: Metric) !void {
    try writer.print(
        "    {{\"id\":\"{s}\",\"scope\":\"{s}\",\"framing\":\"{s}\"," ++
            "\"payload_bytes\":{},\"request_bytes\":{},\"wire_bytes\":{}," ++
            "\"producer_polls\":{},\"send_actions\":{}," ++
            "\"send_completions\":{},\"eventfd_notifications\":{}," ++
            "\"eventfd_drains\":{},\"request_slots\":{}," ++
            "\"ready_slots\":{},\"callback_dispatches\":{}," ++
            "\"runtime_completions\":{}}}",
        .{
            metric.id,
            metric.scope,
            metric.framing,
            metric.payload_bytes,
            metric.request_bytes,
            metric.wire_bytes,
            metric.producer_polls,
            metric.send_actions,
            metric.send_completions,
            metric.eventfd_notifications,
            metric.eventfd_drains,
            metric.request_slots,
            metric.ready_slots,
            metric.callback_dispatches,
            metric.runtime_completions,
        },
    );
}
