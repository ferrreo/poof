const std = @import("std");
const sigbench = @import("sigbench");
const html_source = @import("../src/html/source.zig");
const html_template = @import("../src/html/template.zig");

const Item = struct { name: []const u8, count: u16 };
const View = struct {
    title: []const u8,
    show: bool,
    items: []const Item,
};

fn doubled(value: u16) u32 {
    return @as(u32, value) * 2;
}

const Page = html_template.Template(.{
    .View = View,
    .source = html_source.SourceSpec{
        .kind = .fragment,
        .graph_name = "template-benchmark",
        .file_path = "bench/page.html",
        .bytes = "<main><h1>{{view.title}}</h1>" ++
            "{{#if view.show}}<ul>{{#each view.items as item,index}}" ++
            "<li data-index=\"{{index}}\">{{item.name}}:{{doubled item.count}}</li>" ++
            "{{else}}<li>empty</li>{{/each}}</ul>{{else}}hidden{{/if}}</main>",
    },
    .helpers = .{ .doubled = doubled },
});

const items = [_]Item{
    .{ .name = "routing", .count = 3 },
    .{ .name = "HTML <safe>", .count = 5 },
    .{ .name = "JSON & forms", .count = 8 },
    .{ .name = "uploads", .count = 13 },
};

const operation_items = [_]u16{7} ** 256;
const OperationPage = html_template.Template(.{
    .View = struct { items: []const u16 },
    .source = html_source.SourceSpec{
        .kind = .fragment,
        .graph_name = "template-operation-benchmark",
        .file_path = "bench/template-operations.html",
        .bytes = "{{#each view.items as item}}{{item}}{{/each}}",
    },
    .render_operations_max = 1 + operation_items.len * 2,
});

const Writer = struct {
    storage: []u8,
    length: usize = 0,

    pub fn write(writer: *Writer, chunk: []const u8) error{NoSpaceLeft}!void {
        if (chunk.len > writer.storage.len - writer.length) return error.NoSpaceLeft;
        @memcpy(writer.storage[writer.length..][0..chunk.len], chunk);
        writer.length += chunk.len;
    }
};

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof typed template benchmark validity check failed");
}

fn benchPopulated(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runPage(iterations, .{
                .title = "Recent <activity>",
                .show = true,
                .items = &items,
            });
        }
    }.run);
}

fn benchEmpty(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runPage(iterations, .{
                .title = "Empty",
                .show = true,
                .items = &.{},
            });
        }
    }.run);
}

fn benchHidden(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runPage(iterations, .{
                .title = "Hidden",
                .show = false,
                .items = &items,
            });
        }
    }.run);
}

fn benchOperations(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var output: [2048]u8 = undefined;
            var writer = Writer{ .storage = &output };
            OperationPage.render(&writer, .{ .items = &operation_items }, &.{}) catch {
                benchmarkFailure();
            };
            const expected_length = writer.length;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                writer.length = 0;
                OperationPage.render(&writer, .{ .items = &operation_items }, &.{}) catch {
                    benchmarkFailure();
                };
                std.mem.doNotOptimizeAway(&writer);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (writer.length != expected_length or writer.length == 0) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn runPage(iterations: u64, view: View) u64 {
    if (iterations == 0) benchmarkFailure();
    var output: [2048]u8 = undefined;
    var writer = Writer{ .storage = &output };
    Page.render(&writer, view, &.{}) catch benchmarkFailure();
    const expected_length = writer.length;
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        writer.length = 0;
        Page.render(&writer, view, &.{}) catch benchmarkFailure();
        std.mem.doNotOptimizeAway(&writer);
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    if (writer.length != expected_length or writer.length == 0) benchmarkFailure();
    return elapsed_ns;
}

pub const group = sigbench.groupWithId("m11-html-template", "M11 typed HTML templates", .{
    sigbench.benchWithThroughput(
        "populated",
        "typed fields helper nested controls and escaping",
        .{ .elements = items.len },
        benchPopulated,
    ),
    sigbench.benchWithThroughput(
        "empty-each",
        "exact each else path",
        .{ .elements = 1 },
        benchEmpty,
    ),
    sigbench.benchWithThroughput(
        "hidden-branch",
        "outer conditional skip path",
        .{ .elements = 1 },
        benchHidden,
    ),
    sigbench.benchWithThroughput(
        "render-operation-checks",
        "exact-budget each iterations and directives",
        .{ .elements = operation_items.len },
        benchOperations,
    ),
});
