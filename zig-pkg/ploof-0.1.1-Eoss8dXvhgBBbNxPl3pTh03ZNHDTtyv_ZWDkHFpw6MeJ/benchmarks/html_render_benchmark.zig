const std = @import("std");
const sigbench = @import("sigbench");
const render = @import("../src/html/render.zig");

const clean_input = "Ploof serves predictable HTML without allocating. " ** 8;
const escaped_input = "name=<&>\"' path=/users/42 " ** 8;
const trusted_input = "<article><h2>Ready</h2><p>Static sanitized markup.</p></article>";

const BufferWriter = struct {
    storage: []u8,
    length: usize = 0,

    pub fn write(writer: *BufferWriter, input: []const u8) error{NoSpaceLeft}!void {
        if (input.len > writer.storage.len - writer.length) return error.NoSpaceLeft;
        @memcpy(writer.storage[writer.length..][0..input.len], input);
        writer.length += input.len;
    }

    fn reset(writer: *BufferWriter) void {
        writer.length = 0;
    }
};

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof HTML render benchmark validity check failed");
}

fn benchCleanText(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var output: [clean_input.len]u8 = undefined;
            var writer = BufferWriter{ .storage = &output };
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                writer.reset();
                render.writeText(&writer, clean_input) catch benchmarkFailure();
                std.mem.doNotOptimizeAway(&writer);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (writer.length != clean_input.len) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn benchEscapedAttribute(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var output: [6 * escaped_input.len]u8 = undefined;
            var writer = BufferWriter{ .storage = &output };
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                writer.reset();
                render.writeAttribute(&writer, .double, escaped_input) catch benchmarkFailure();
                std.mem.doNotOptimizeAway(&writer);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (writer.length <= escaped_input.len) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn benchWideInteger(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var output: [64]u8 = undefined;
            var writer = BufferWriter{ .storage = &output };
            const value = std.math.minInt(i128);
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                writer.reset();
                render.writeValue(&writer, .html_data, value) catch benchmarkFailure();
                std.mem.doNotOptimizeAway(&writer);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (writer.length != 40) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn benchTrustedHtml(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            const Html = render.TrustedHtml(256);
            const trusted = Html.unsafeAssumeSanitized(trusted_input) catch benchmarkFailure();
            var output: [trusted_input.len]u8 = undefined;
            var writer = BufferWriter{ .storage = &output };
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                writer.reset();
                render.writeTrustedHtml(&writer, trusted) catch benchmarkFailure();
                std.mem.doNotOptimizeAway(&writer);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (writer.length != trusted_input.len) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn benchBrowserJson(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            const value = .{ .title = "</script>", .count = @as(u32, 42) };
            var scratch: [256]u8 = undefined;
            var output: [512]u8 = undefined;
            var writer = BufferWriter{ .storage = &output };
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                writer.reset();
                render.writeBrowserJson(
                    .{ .encoded_bytes_max = scratch.len },
                    &writer,
                    "bench-state",
                    value,
                    &scratch,
                ) catch benchmarkFailure();
                std.mem.doNotOptimizeAway(&writer);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (writer.length == 0) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

pub const group = sigbench.groupWithId("m11-html-render", "M11 HTML rendering", .{
    sigbench.benchWithThroughput(
        "clean-text",
        "UTF-8 validation and SIMD no-escape scan",
        .{ .bytes = clean_input.len },
        benchCleanText,
    ),
    sigbench.benchWithThroughput(
        "escaped-double-attribute",
        "quoted attribute escaping with SIMD clean-span scan",
        .{ .bytes = escaped_input.len },
        benchEscapedAttribute,
    ),
    sigbench.benchWithThroughput(
        "i128-min",
        "exact bounded decimal scalar formatting",
        .{ .elements = 1 },
        benchWideInteger,
    ),
    sigbench.benchWithThroughput(
        "trusted-html",
        "bounded trusted HTML UTF-8 validation and write",
        .{ .bytes = trusted_input.len },
        benchTrustedHtml,
    ),
    sigbench.benchWithThroughput(
        "browser-json",
        "typed HTML-safe browser JSON data block",
        .{ .elements = 1 },
        benchBrowserJson,
    ),
});
