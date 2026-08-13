const std = @import("std");
const sigbench = @import("sigbench");
const route = @import("../src/route.zig");
const url = @import("../src/url.zig");
const url_for = @import("../src/url_for.zig");

fn handler() void {}

const literal_route = route.get("/health", handler);
const path_route = route.get("/accounts/:account_id/items/:item_id", handler);
const query_route = route.get("/search/:scope", handler);

const Query = struct {
    term: []const u8,
    page: u16,
    tags: [2][]const u8,
};

const benchmark_query = Query{
    .term = "zig http server",
    .page = 7,
    .tags = .{ "fast", "safe & typed" },
};

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof urlFor benchmark validity check failed");
}

fn benchLiteral(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var output: [64]u8 = undefined;
            var result: url.Url = undefined;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                result = url_for.urlFor(literal_route, .{}, .{}, &output) catch {
                    benchmarkFailure();
                };
                std.mem.doNotOptimizeAway(&result);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (!std.mem.eql(u8, result.bytes(), "/health")) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn benchTypedPath(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var output: [128]u8 = undefined;
            var result: url.Url = undefined;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |iteration| {
                result = url_for.urlFor(path_route, .{
                    .account_id = iteration,
                    .item_id = "caf\xc3\xa9 item",
                }, .{}, &output) catch benchmarkFailure();
                std.mem.doNotOptimizeAway(&result);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (result.bytes().len == 0) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn benchTypedQuery(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var output: [256]u8 = undefined;
            var result: url.Url = undefined;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                result = url_for.urlFor(
                    query_route,
                    .{ .scope = "all" },
                    benchmark_query,
                    &output,
                ) catch benchmarkFailure();
                std.mem.doNotOptimizeAway(&result);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (result.bytes().len == 0) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

pub const group = sigbench.groupWithId("m11-url-for", "M11 typed URL construction", .{
    sigbench.benchWithThroughput(
        "literal-route",
        "literal route URL construction and validation",
        .{ .elements = 1 },
        benchLiteral,
    ),
    sigbench.benchWithThroughput(
        "typed-path",
        "typed path formatting and percent encoding",
        .{ .elements = 2 },
        benchTypedPath,
    ),
    sigbench.benchWithThroughput(
        "typed-query",
        "ordered typed query formatting and percent encoding",
        .{ .elements = 5 },
        benchTypedQuery,
    ),
});
