const std = @import("std");
const sigbench = @import("sigbench");
const application_context = @import("../src/application/context.zig");
const asset_http = @import("../src/internal/asset/http.zig");
const asset_response = @import("../src/internal/asset/response.zig");

const identity = [_]u8{'a'} ** 4096;
const gzip = [_]u8{'b'} ** 256;
const identity_etag = "\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"";
const gzip_etag = "\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"";
const Representation = struct {
    bytes: []const u8,
    etag: []const u8,
};
const record = .{
    .media_type = "text/css; charset=utf-8",
    .identity = Representation{ .bytes = &identity, .etag = identity_etag },
    .gzip = @as(?Representation, .{ .bytes = &gzip, .etag = gzip_etag }),
};
const date = "Thu, 01 Jan 1970 00:00:00 GMT";

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof asset benchmark validity check failed");
}

fn benchSelectIdentity(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runSelect(iterations, .{ .gzip = 500, .identity = 1000 }, .identity);
        }
    }.run);
}

fn benchSelectGzip(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runSelect(iterations, .{ .gzip = 1000, .identity = 1000 }, .gzip);
        }
    }.run);
}

fn runSelect(
    iterations: u64,
    preferences: @import("../src/internal/http1/request_accept_encoding.zig").Preferences,
    expected: asset_http.Coding,
) u64 {
    if (iterations == 0) benchmarkFailure();
    const start = sigbench.nowNs();
    for (0..iterations) |_| {
        const selected = asset_http.select(record, .get, preferences).selected;
        if (selected.coding != expected) benchmarkFailure();
        std.mem.doNotOptimizeAway(selected.body.ptr);
        std.mem.doNotOptimizeAway(selected.body.len);
    }
    return sigbench.nowNs() - start;
}

fn benchPrepareGzip(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var output: [1024]u8 = undefined;
            const headers = application_context.RequestHeaders{};
            const start = sigbench.nowNs();
            for (0..iterations) |_| {
                const prepared = asset_response.prepare(
                    .{},
                    &output,
                    record,
                    .{
                        .method = .get,
                        .accept_encoding = .{ .gzip = 1000, .identity = 1000 },
                        .date = date,
                    },
                    headers,
                    null,
                ) catch benchmarkFailure();
                if (prepared.coding != .gzip or prepared.body.ptr != gzip[0..].ptr) {
                    benchmarkFailure();
                }
                std.mem.doNotOptimizeAway(prepared.head.ptr);
                std.mem.doNotOptimizeAway(prepared.head.len);
            }
            return sigbench.nowNs() - start;
        }
    }.run);
}

pub const group = sigbench.groupWithId("m12-embedded-assets", "M12 embedded assets", .{
    sigbench.benchWithThroughput(
        "select-identity",
        "select identity representation",
        .{ .bytes = identity.len },
        benchSelectIdentity,
    ),
    sigbench.benchWithThroughput(
        "select-gzip",
        "select precompressed representation",
        .{ .bytes = gzip.len },
        benchSelectGzip,
    ),
    sigbench.benchWithThroughput(
        "prepare-gzip-head",
        "serialize precompressed asset response head",
        .{ .bytes = gzip.len },
        benchPrepareGzip,
    ),
});
