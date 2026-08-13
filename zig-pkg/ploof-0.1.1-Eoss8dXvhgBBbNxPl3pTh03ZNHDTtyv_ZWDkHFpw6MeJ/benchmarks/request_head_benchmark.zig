const std = @import("std");
const sigbench = @import("sigbench");
const request_head = @import("../src/internal/http1/request_head.zig");
const limits = @import("../src/internal/http1/limits.zig");

const standard_limits = limits.standard_request_head_limits;
const Decoder = request_head.Decoder(standard_limits);
const wire =
    "GET /api/v1/projects/alpha/events/42?limit=20 HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Accept: application/json\r\n" ++
    "User-Agent: ploof-bench\r\n" ++
    "\r\n";
const long_wire =
    "GET /long HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "X-Long: " ++ ([_]u8{'a'} ** 4096) ++ "\r\n" ++
    "\r\n";
const overlong_wire = [_]u8{'a'} ** (standard_limits.request_line_bytes_max + 4096);

pub const contiguous = sigbench.benchWithThroughput(
    "request-head",
    "request head",
    .{ .bytes = wire.len },
    benchContiguous,
);
pub const fragmented = sigbench.benchWithThroughput(
    "request-head-fragmented",
    "request head in 16-byte fragments",
    .{ .bytes = wire.len },
    benchFragmented,
);
pub const long_field = sigbench.benchWithThroughput(
    "request-head-long-field",
    "request head with 4 KiB field value",
    .{ .bytes = long_wire.len },
    benchLongField,
);
pub const overlong_line = sigbench.benchWithThroughput(
    "request-head-overlong-line",
    "bounded rejection of overlong request line",
    .{ .bytes = standard_limits.request_line_bytes_max },
    benchOverlongLine,
);

fn benchContiguous(b: *sigbench.Bencher) void {
    b.iter(struct {
        fn run() void {
            var input = wire;
            std.mem.doNotOptimizeAway(&input);
            var decoder = Decoder.init();
            const result = decoder.feed(input);
            switch (result.state) {
                .ready => |head| {
                    if (result.consumed != input.len) benchmarkFailure();
                    if (head.fields_count != 3) benchmarkFailure();
                    std.mem.doNotOptimizeAway(result.consumed);
                    std.mem.doNotOptimizeAway(head.fields_count);
                },
                else => benchmarkFailure(),
            }
        }
    }.run);
}

fn benchFragmented(b: *sigbench.Bencher) void {
    b.iter(struct {
        fn run() void {
            var input = wire;
            std.mem.doNotOptimizeAway(&input);
            var decoder = Decoder.init();
            var offset: usize = 0;
            var ready = false;
            while (offset < input.len) {
                const end = @min(offset + 16, input.len);
                const result = decoder.feed(input[offset..end]);
                if (result.consumed != end - offset) benchmarkFailure();
                offset = end;
                switch (result.state) {
                    .need_more => {},
                    .ready => |head| {
                        if (head.fields_count != 3) benchmarkFailure();
                        ready = true;
                    },
                    .rejected => benchmarkFailure(),
                }
            }
            if (!ready) benchmarkFailure();
            std.mem.doNotOptimizeAway(decoder.bytes());
        }
    }.run);
}

fn benchLongField(b: *sigbench.Bencher) void {
    b.iter(struct {
        fn run() void {
            var input = long_wire;
            std.mem.doNotOptimizeAway(&input);
            var decoder = Decoder.init();
            const result = decoder.feed(input);
            switch (result.state) {
                .ready => |head| {
                    if (result.consumed != input.len) benchmarkFailure();
                    if (head.fields_count != 2) benchmarkFailure();
                    std.mem.doNotOptimizeAway(decoder.bytes());
                },
                else => benchmarkFailure(),
            }
        }
    }.run);
}

fn benchOverlongLine(b: *sigbench.Bencher) void {
    b.iter(struct {
        fn run() void {
            var input: []const u8 = &overlong_wire;
            std.mem.doNotOptimizeAway(&input);
            var decoder = Decoder.init();
            const result = decoder.feed(input);
            switch (result.state) {
                .rejected => |rejection| {
                    const expected = standard_limits.request_line_bytes_max;
                    if (result.consumed != expected) benchmarkFailure();
                    if (decoder.bytes().len != expected) benchmarkFailure();
                    if (rejection.status != .uri_too_long) benchmarkFailure();
                    std.mem.doNotOptimizeAway(decoder.bytes());
                },
                else => benchmarkFailure(),
            }
        }
    }.run);
}

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof request-head benchmark validity check failed");
}
