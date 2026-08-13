const std = @import("std");
const sigbench = @import("sigbench");
const application = @import("../src/application.zig");
const request_head = @import("../src/internal/http1/request_head.zig");
const response = @import("../src/response.zig");
const static_file = @import("../src/static_file.zig");

const file_size = 64 * 1024;
const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const fixed_second: i64 = 1_784_030_400;
const raw_path = "/assets/styles/site.css";
const raw_suffix = "/styles/site.css";
const relative_path = "styles/site.css";
const range_value = "bytes=1024-5119";
const range_bytes = "Range" ++ range_value;
const range_fields = [_]request_head.Field{.{
    .name = span(0, "Range".len),
    .raw_value = span("Range".len, range_value.len),
    .value = span("Range".len, range_value.len),
}};

const StaticDir = static_file.StaticDir.init("/assets", ".", .{});
const App = application.Application(.{
    .State = void,
    .routes = .{StaticDir},
});

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof live static benchmark validity check failed");
}

fn benchPathSelection(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            const start = sigbench.nowNs();
            for (0..iterations) |_| {
                const selection = StaticDir.selectPath(raw_suffix, raw_suffix);
                const selected = switch (selection) {
                    .selected => |value| value,
                    .rejected => benchmarkFailure(),
                };
                if (!std.mem.eql(u8, selected.relative_path, relative_path)) {
                    benchmarkFailure();
                }
                std.mem.doNotOptimizeAway(selected.relative_path.ptr);
            }
            return sigbench.nowNs() - start;
        }
    }.run);
}

fn benchPrepareComplete(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runPrepare(iterations, .{}, .ok, file_size);
        }
    }.run);
}

fn benchPrepareRange(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runPrepare(iterations, rangeHeaders(), .partial_content, 4096);
        }
    }.run);
}

fn runPrepare(
    iterations: u64,
    headers: application.RequestHeaders,
    expected_status: response.Status,
    expected_length: u64,
) u64 {
    if (iterations == 0) benchmarkFailure();
    var state: void = {};
    const start = sigbench.nowNs();
    for (0..iterations) |_| {
        var workspace = App.Workspace{};
        var route_workspace = App.RouteSearchWorkspace{};
        var output: [2048]u8 = undefined;
        const first = App.prepareHead(
            &state,
            &workspace,
            &route_workspace,
            input(headers),
            &output,
        ) catch benchmarkFailure();
        const intent = switch (first) {
            .prepared => |prepared| switch (prepared.source) {
                .live_static => |value| value,
                else => benchmarkFailure(),
            },
            .receive_body => benchmarkFailure(),
        };
        const prepared = App.__prepareLiveStatic(
            &workspace,
            intent,
            resolution(),
            &output,
        ) catch benchmarkFailure();
        if (prepared.status != expected_status or prepared.source != .live_static_file) {
            benchmarkFailure();
        }
        const file = prepared.source.live_static_file;
        if (file.length != expected_length or !file.transfer_body) benchmarkFailure();
        std.mem.doNotOptimizeAway(file.head.ptr);
        std.mem.doNotOptimizeAway(file.head.len);
        _ = App.complete(&workspace) catch benchmarkFailure();
    }
    return sigbench.nowNs() - start;
}

fn input(headers: application.RequestHeaders) application.Input {
    return .{
        .method = "GET",
        .path = raw_path,
        .raw_target = raw_path,
        .raw_path = raw_path,
        .date = fixed_date,
        .headers = headers,
    };
}

fn resolution() static_file.RuntimeResolution {
    return .{ .file = .{
        .identity = .{
            .device_major = 8,
            .device_minor = 1,
            .inode = 42,
            .size = file_size,
            .mtime_seconds = fixed_second - 60,
            .mtime_nanoseconds = 123,
        },
        .message_epoch_second = fixed_second,
        .filename = relative_path,
    } };
}

fn rangeHeaders() application.RequestHeaders {
    return .{ .bytes = range_bytes, .fields = &range_fields };
}

fn span(offset: usize, length: usize) request_head.Span {
    return .{ .offset = @intCast(offset), .length = @intCast(length) };
}

pub const group = sigbench.groupWithId("m12-live-static", "M12 live static files", .{
    sigbench.benchWithThroughput(
        "path-selection",
        "validate and select confined live path",
        .{ .bytes = raw_suffix.len },
        benchPathSelection,
    ),
    sigbench.benchWithThroughput(
        "prepare-complete",
        "route and serialize complete live file response",
        .{ .bytes = file_size },
        benchPrepareComplete,
    ),
    sigbench.benchWithThroughput(
        "prepare-range",
        "route and serialize ranged live file response",
        .{ .bytes = 4096 },
        benchPrepareRange,
    ),
});
