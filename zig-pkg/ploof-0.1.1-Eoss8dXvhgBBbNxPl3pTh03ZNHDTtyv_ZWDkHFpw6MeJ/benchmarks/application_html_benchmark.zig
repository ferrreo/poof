const std = @import("std");
const sigbench = @import("sigbench");

const application = @import("../src/application.zig");
const application_chunk_output = @import("../src/internal/application/chunk_output.zig");
const config = @import("../src/internal/runtime/config.zig");
const gzip_encoder = @import("../src/internal/runtime/gzip/encoder.zig");
const worker_response_chunks = @import("../src/internal/runtime/worker/response_chunks.zig");
const html_render = @import("../src/html/render.zig");
const html_response = @import("../src/html/response.zig");
const html_source = @import("../src/html/source.zig");
const html_template = @import("../src/html/template.zig");
const response = @import("../src/response.zig");
const route = @import("../src/route.zig");

const kib: usize = 1024;
const mib: usize = 1024 * kib;
const chunk_bytes = config.response_chunk_bytes;
const pool_chunks = config.Limits.validate(.{}).response_chunk_count;
const Pool = worker_response_chunks.Pool(chunk_bytes);
const State = struct {};
const Context = application.Context(State, response.standard_head_limits);

const static_source = "<main>" ++
    ("<p>Ploof finite HTML writes one bounded shared chunk chain.</p>" ** 128) ++
    "</main>";
const StaticPage = template("static-heavy", static_source, 16 * kib, struct {});

const escape_pattern = "<&>\"'";
const escape_repetitions = 4096;
const escape_input = escape_pattern ** escape_repetitions;
const escape_piece = "&lt;&amp;&gt;\"'";
const escape_bytes = "<main>".len + escape_piece.len * escape_repetitions +
    "</main>".len;
const EscapePage = template(
    "escape-heavy",
    "<main>{{view.value}}</main>",
    64 * kib,
    struct { value: []const u8 },
);

const LoopItem = struct { label: []const u8 };
const loop_label = "row<&>";
const loop_items = [_]LoopItem{.{ .label = loop_label }} ** 2048;
const loop_piece = "<li>row&lt;&amp;&gt;</li>";
const loop_bytes = loop_piece.len * loop_items.len;
const LoopPage = html_template.Template(.{
    .View = struct { items: []const LoopItem },
    .encoded_bytes_max = 64 * kib,
    .source = source(
        "loop-partial",
        "{{#each view.items as item}}{{> row item}}{{/each}}",
    ),
    .partials = .{ .row = .{
        .View = LoopItem,
        .source = source("loop-row", "<li>{{view.label}}</li>"),
    } },
});

const browser_pattern = "</script><&";
const browser_repetitions = 8192;
const browser_input = browser_pattern ** browser_repetitions;
const browser_piece = "\\u003c/script\\u003e\\u003c\\u0026";
const browser_open = "<script type=\"application/json\" id=\"benchmark-state\">";
const browser_bytes = browser_open.len + "{\"value\":\"".len +
    browser_piece.len * browser_repetitions + "\"}".len + "</script>".len;
const BrowserPage = html_template.Template(.{
    .View = struct { state: struct { value: []const u8 } },
    .encoded_bytes_max = 512 * kib,
    .source = source(
        "browser-json",
        "{{@jsonData benchmark-state view.state}}",
    ),
    .browser_json = html_render.BrowserJsonOptions{ .encoded_bytes_max = 384 * kib },
});

const BoundaryHtml = html_render.TrustedHtml(mib);
const boundary_markup = "b" ** mib;
const boundary_value = BoundaryHtml.unsafeAssumeSanitized(boundary_markup) catch unreachable;
const BoundaryPage = template(
    "one-mib-boundary",
    "{{view.markup}}",
    mib,
    struct { markup: BoundaryHtml },
);

fn staticHandler(context: *Context) html_response.TemplateResponse(StaticPage) {
    return context.html(.ok, StaticPage, .{});
}

fn escapeHandler(context: *Context) html_response.TemplateResponse(EscapePage) {
    return context.html(.ok, EscapePage, .{ .value = escape_input });
}

fn loopHandler(context: *Context) html_response.TemplateResponse(LoopPage) {
    return context.html(.ok, LoopPage, .{ .items = &loop_items });
}

fn browserHandler(context: *Context) html_response.TemplateResponse(BrowserPage) {
    return context.html(.ok, BrowserPage, .{ .state = .{ .value = browser_input } });
}

fn boundaryHandler(context: *Context) html_response.TemplateResponse(BoundaryPage) {
    return context.html(.ok, BoundaryPage, .{ .markup = boundary_value });
}

const App = application.Application(.{
    .State = State,
    .response_gzip = application.ResponseGzip{ .minimum_bytes = 0 },
    .routes = .{
        route.get("/static", staticHandler),
        route.get("/escape", escapeHandler),
        route.get("/loop", loopHandler),
        route.get("/browser-json", browserHandler),
        route.get("/boundary", boundaryHandler),
    },
});

const Coding = enum { identity, gzip };
const Definition = struct {
    id: []const u8,
    description: []const u8,
    path: []const u8,
    identity_bytes: u32,
    coding: Coding,
};

fn definition(
    comptime id: []const u8,
    comptime description: []const u8,
    comptime path: []const u8,
    comptime identity_bytes: usize,
    comptime coding: Coding,
) Definition {
    return .{
        .id = id,
        .description = description,
        .path = path,
        .identity_bytes = identity_bytes,
        .coding = coding,
    };
}

const definitions = .{
    definition(
        "static-heavy-identity",
        "static-heavy finite route",
        "/static",
        static_source.len,
        .identity,
    ),
    definition(
        "static-heavy-gzip",
        "static-heavy finite route",
        "/static",
        static_source.len,
        .gzip,
    ),
    definition(
        "escape-heavy-identity",
        "escape-heavy finite route",
        "/escape",
        escape_bytes,
        .identity,
    ),
    definition(
        "escape-heavy-gzip",
        "escape-heavy finite route",
        "/escape",
        escape_bytes,
        .gzip,
    ),
    definition(
        "loop-partial-identity",
        "loop and typed partial finite route",
        "/loop",
        loop_bytes,
        .identity,
    ),
    definition(
        "loop-partial-gzip",
        "loop and typed partial finite route",
        "/loop",
        loop_bytes,
        .gzip,
    ),
    definition(
        "browser-json-identity",
        "HTML-safe browser JSON finite route",
        "/browser-json",
        browser_bytes,
        .identity,
    ),
    definition(
        "browser-json-gzip",
        "HTML-safe browser JSON finite route",
        "/browser-json",
        browser_bytes,
        .gzip,
    ),
    definition(
        "boundary-1mib-identity",
        "exact standard 1 MiB finite route",
        "/boundary",
        mib,
        .identity,
    ),
    definition(
        "boundary-1mib-gzip",
        "exact standard 1 MiB finite route",
        "/boundary",
        mib,
        .gzip,
    ),
};

const Inspection = struct {
    identity_bytes: u32,
    wire_body_bytes: u32,
    output_chunks: u16,
    pool_high_water: u16,
    coding_outcome: application.CodingOutcome,
    fingerprint: u64,
};

const Harness = struct {
    indices: [pool_chunks]u16 = undefined,
    nodes: [pool_chunks]worker_response_chunks.Node = undefined,
    chunk_storage: [@as(usize, pool_chunks) * chunk_bytes]u8 = undefined,
    pool: Pool = undefined,
    state: State = .{},
    workspace: App.Workspace = .{},
    route_workspace: App.RouteSearchWorkspace = undefined,
    scratch: [App.html_json_scratch_bytes_max]u8 = undefined,
    gzip: App.ResponseGzipWorkspace = undefined,

    fn init(self: *Harness) void {
        self.pool = Pool.init(&self.indices, &self.nodes, &self.chunk_storage) catch {
            benchmarkFailure();
        };
    }

    fn execute(self: *Harness, comptime spec: Definition) Inspection {
        if (self.pool.available() != pool_chunks) benchmarkFailure();
        const request = input(spec);
        var plan = App.plan(request, &self.route_workspace);
        const chunks = plan.finite_output.chunks;
        var concrete = self.pool.writer(chunks.encoded_bytes_max);
        defer concrete.abort();
        var writer = application_chunk_output.bind(&concrete);
        const result = App.__prepareHeadPlannedWithChunks(
            &self.state,
            &self.workspace,
            &.{},
            &self.workspace.response_head_bytes,
            &plan,
            .{},
            &writer,
            &self.scratch,
            &self.gzip,
        ) catch benchmarkFailure();
        const prepared = switch (result) {
            .prepared => |value| value,
            .receive_body => benchmarkFailure(),
        };
        const finite = switch (prepared.source) {
            .finite_chain => |value| value,
            .contiguous_wire,
            .borrowed_static,
            .live_static,
            .live_static_file,
            => benchmarkFailure(),
        };
        validatePrepared(spec, prepared, finite.body);
        const fingerprint = responseFingerprint(prepared, finite.body);
        const inspection = Inspection{
            .identity_bytes = spec.identity_bytes,
            .wire_body_bytes = finite.body.bytes,
            .output_chunks = finite.body.chunks,
            .pool_high_water = self.pool.high_water,
            .coding_outcome = prepared.coding_outcome,
            .fingerprint = fingerprint,
        };
        App.__scrubPreparedHead(&self.workspace, finite.head);
        self.pool.release(finite.body);
        _ = App.complete(&self.workspace) catch benchmarkFailure();
        if (self.pool.available() != pool_chunks) benchmarkFailure();
        return inspection;
    }
};

fn input(comptime spec: Definition) application.Input {
    return .{
        .method = "GET",
        .path = spec.path,
        .raw_target = spec.path,
        .raw_path = spec.path,
        .date = "Thu, 16 Jul 2026 12:00:00 GMT",
        .accept_encoding = switch (spec.coding) {
            .identity => .{ .gzip = 0, .identity = 1000 },
            .gzip => .{ .gzip = 1000, .identity = 1000 },
        },
    };
}

fn validatePrepared(
    comptime spec: Definition,
    prepared: application.Prepared,
    chain: worker_response_chunks.Chain,
) void {
    if (prepared.status != .ok or prepared.close_connection or chain.isEmpty()) {
        benchmarkFailure();
    }
    const expected: application.CodingOutcome = switch (spec.coding) {
        .identity => .identity_negotiated,
        .gzip => .gzip,
    };
    if (prepared.coding_outcome != expected) benchmarkFailure();
    if (spec.coding == .identity and chain.bytes != spec.identity_bytes) {
        benchmarkFailure();
    }
}

fn responseFingerprint(prepared: application.Prepared, chain: anytype) u64 {
    var value: u64 = @intFromEnum(prepared.status);
    value = value *% 0x9e37_79b9_7f4a_7c15 +% chain.bytes;
    value = value *% 0x9e37_79b9_7f4a_7c15 +% chain.chunks;
    value = value *% 0x9e37_79b9_7f4a_7c15 +% prepared.bytes.len;
    return value *% 0x9e37_79b9_7f4a_7c15 +% @intFromEnum(prepared.coding_outcome);
}

fn Runner(comptime spec: Definition) type {
    return struct {
        fn bench(bencher: *sigbench.Bencher) void {
            bencher.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var harness: Harness = .{};
            harness.init();
            const expected = harness.execute(spec);
            var fingerprint: u64 = 0;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                const actual = harness.execute(spec);
                if (!std.meta.eql(actual, expected)) benchmarkFailure();
                fingerprint +%= actual.fingerprint;
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            std.mem.doNotOptimizeAway(&fingerprint);
            return elapsed_ns;
        }
    };
}

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof Application HTML benchmark validity check failed");
}

fn template(
    comptime name: []const u8,
    comptime bytes: []const u8,
    comptime encoded_bytes_max: u32,
    comptime View: type,
) type {
    return html_template.Template(.{
        .View = View,
        .encoded_bytes_max = encoded_bytes_max,
        .source = source(name, bytes),
    });
}

fn source(comptime name: []const u8, comptime bytes: []const u8) html_source.SourceSpec {
    return .{
        .kind = .fragment,
        .graph_name = name,
        .file_path = "bench/" ++ name ++ ".html",
        .bytes = bytes,
    };
}

pub const group = sigbench.groupWithId("m11-html-application", "M11 finite HTML routes", .{
    benchDefinition(0),
    benchDefinition(1),
    benchDefinition(2),
    benchDefinition(3),
    benchDefinition(4),
    benchDefinition(5),
    benchDefinition(6),
    benchDefinition(7),
    benchDefinition(8),
    benchDefinition(9),
});

fn benchDefinition(comptime index: usize) sigbench.BenchmarkCase {
    const spec = definitions[index];
    return sigbench.benchWithThroughput(
        spec.id,
        spec.description,
        .{ .bytes = spec.identity_bytes },
        Runner(spec).bench,
    );
}

pub const Metric = struct {
    id: []const u8,
    coding: []const u8,
    identity_bytes: u32,
    wire_body_bytes: u32,
    copied_bytes: u64,
    source_chunks: u16,
    output_chunks: u16,
    reserved_destination_chunks: u16,
    pool_high_water: u16,
    peak_live_chunk_bytes: u32,
    gzip_peak_memory_bytes: u32,
};

pub fn writeMetricsReport(init: std.process.Init, default_output_root: []const u8) !void {
    const output_root = try selectedOutputRoot(init, default_output_root) orelse return;
    var metrics: [definitions.len]Metric = undefined;
    inline for (definitions, 0..) |spec, index| metrics[index] = inspectMetric(spec);
    try writeMetrics(init, output_root, &metrics);
}

fn inspectMetric(comptime spec: Definition) Metric {
    var harness: Harness = .{};
    harness.init();
    const result = harness.execute(spec);
    const source_chunks = chunksRequired(spec.identity_bytes);
    const reserved = if (spec.coding == .gzip)
        chunksRequired(gzip_encoder.bound(spec.identity_bytes) catch benchmarkFailure())
    else
        0;
    const workspace_bytes = if (spec.coding == .gzip)
        @sizeOf(App.ResponseGzipWorkspace)
    else
        0;
    return .{
        .id = spec.id,
        .coding = @tagName(spec.coding),
        .identity_bytes = spec.identity_bytes,
        .wire_body_bytes = result.wire_body_bytes,
        .copied_bytes = spec.identity_bytes + if (spec.coding == .gzip)
            result.wire_body_bytes
        else
            0,
        .source_chunks = source_chunks,
        .output_chunks = result.output_chunks,
        .reserved_destination_chunks = reserved,
        .pool_high_water = result.pool_high_water,
        .peak_live_chunk_bytes = @as(u32, result.pool_high_water) * chunk_bytes,
        .gzip_peak_memory_bytes = if (spec.coding == .gzip)
            @as(u32, result.pool_high_water) * chunk_bytes +
                @as(u32, @intCast(workspace_bytes))
        else
            0,
    };
}

fn chunksRequired(bytes: anytype) u16 {
    return @intCast((@as(u64, bytes) + chunk_bytes - 1) / chunk_bytes);
}

fn selectedOutputRoot(
    init: std.process.Init,
    default_output_root: []const u8,
) !?[]const u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    var output_root = default_output_root;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sigbench-exact")) return null;
        if (std.mem.eql(u8, arg, "--output-dir")) {
            output_root = args.next() orelse return error.MissingArgument;
        }
    }
    return output_root;
}

fn writeMetrics(init: std.process.Init, output_root: []const u8, metrics: []const Metric) !void {
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try std.fmt.bufPrint(
        &directory_storage,
        "{s}/m11-html-application",
        .{output_root},
    );
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    var json_storage: [16 * kib]u8 = undefined;
    var json = std.Io.Writer.fixed(&json_storage);
    try json.writeAll("{\n  \"format\":1,\n  \"entries\":[\n");
    for (metrics, 0..) |metric, index| {
        if (index != 0) try json.writeAll(",\n");
        try writeMetric(&json, metric);
    }
    try json.writeAll("\n  ]\n}\n");
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "{s}/metrics.json", .{directory});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = json.buffered() });
}

fn writeMetric(writer: *std.Io.Writer, metric: Metric) !void {
    try writer.print(
        "    {{\"id\":\"{s}\",\"coding\":\"{s}\"," ++
            "\"identity_bytes\":{},\"wire_body_bytes\":{},\"copied_bytes\":{}," ++
            "\"source_chunks\":{},\"output_chunks\":{}," ++
            "\"reserved_destination_chunks\":{},\"pool_high_water\":{}," ++
            "\"peak_live_chunk_bytes\":{},\"gzip_peak_memory_bytes\":{}," ++
            "\"rejections\":0,\"operations\":1,\"framework_allocations\":0}}",
        .{
            metric.id,
            metric.coding,
            metric.identity_bytes,
            metric.wire_body_bytes,
            metric.copied_bytes,
            metric.source_chunks,
            metric.output_chunks,
            metric.reserved_destination_chunks,
            metric.pool_high_water,
            metric.peak_live_chunk_bytes,
            metric.gzip_peak_memory_bytes,
        },
    );
}
