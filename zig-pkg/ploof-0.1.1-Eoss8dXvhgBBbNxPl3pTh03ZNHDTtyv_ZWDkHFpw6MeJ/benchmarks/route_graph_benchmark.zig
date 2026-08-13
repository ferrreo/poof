const std = @import("std");
const sigbench = @import("sigbench");
const route = @import("../src/route.zig");
const route_graph = @import("../src/internal/route_graph.zig");
const overlap = @import("../tests/unit/route_graph_overlap_test.zig");
const scale = @import("../tests/unit/internal/route_graph_scale_test.zig");

const Graph1 = route_graph.Graph(scale.definitions(1), .{ .routes_max = 1 });
const Graph512 = route_graph.Graph(scale.definitions(512), .{});
const Graph4096 = route_graph.Graph(scale.definitions(4096), .{
    .routes_max = route.routes_hard_max,
});
const Overlap6 = overlap.Fixture(6);
const Overlap8 = overlap.Fixture(8);
const Overlap10 = overlap.Fixture(10);
const Overlap12 = overlap.Fixture(12);

const miss_path = "/shared/deep/prefix/not-present";
const last_path_1 = Graph1.routes[Graph1.routes.len - 1].pattern;
const last_path_512 = Graph512.routes[Graph512.routes.len - 1].pattern;
const last_path_4096 = Graph4096.routes[Graph4096.routes.len - 1].pattern;

const Expected = enum(u8) {
    selected,
    method_not_allowed,
    options,
    not_found,
};

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof route graph benchmark validity check failed");
}

fn Runner(
    comptime Graph: type,
    comptime method: []const u8,
    comptime path: []const u8,
    comptime expected: Expected,
) type {
    return struct {
        fn bench(bencher: *sigbench.Bencher) void {
            bencher.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var workspace: Graph.SearchWorkspace = undefined;
            var captures: Graph.CaptureBuffer = undefined;
            var fingerprint: u64 = 0;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                const selection = Graph.select(
                    .{ .method = method, .path = path },
                    &workspace,
                    &captures,
                );
                fingerprint +%= selectionCode(selection, expected, Graph.routes.len - 1);
                std.mem.doNotOptimizeAway(&selection);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (fingerprint != expectedCode(expected) *% iterations) benchmarkFailure();
            std.mem.doNotOptimizeAway(&fingerprint);
            return elapsed_ns;
        }
    };
}

fn selectionCode(
    selection: route_graph.Selection,
    comptime expected: Expected,
    comptime expected_route_id: usize,
) u64 {
    return switch (expected) {
        .selected => switch (selection) {
            .selected => |value| if (value.route_id == expected_route_id and
                value.captures.len == 0)
                expectedCode(expected)
            else
                benchmarkFailure(),
            else => benchmarkFailure(),
        },
        .method_not_allowed => switch (selection) {
            .method_not_allowed => |allow| validateAllow(allow, expected),
            else => benchmarkFailure(),
        },
        .options => switch (selection) {
            .options => |allow| validateAllow(allow, expected),
            else => benchmarkFailure(),
        },
        .not_found => if (selection == .not_found)
            expectedCode(expected)
        else
            benchmarkFailure(),
    };
}

fn validateAllow(allow: route_graph.Allow, comptime expected: Expected) u64 {
    if (!allow.contains(.get) or !allow.contains(.head) or !allow.containsOptions()) {
        benchmarkFailure();
    }
    if (allow.contains(.post) or allow.contains(.put) or allow.contains(.patch) or
        allow.contains(.delete)) benchmarkFailure();
    return expectedCode(expected);
}

fn expectedCode(expected: Expected) u64 {
    return @intFromEnum(expected) + 1;
}

pub const group = sigbench.groupWithId("m14-route-index", "M14 route index scaling", .{
    sigbench.benchWithThroughput(
        "common-prefix-miss-1",
        "common-prefix miss, 1 route",
        .{ .elements = 1 },
        Runner(Graph1, "GET", miss_path, .not_found).bench,
    ),
    sigbench.benchWithThroughput(
        "common-prefix-miss-512",
        "common-prefix miss, 512 routes",
        .{ .elements = 1 },
        Runner(Graph512, "GET", miss_path, .not_found).bench,
    ),
    sigbench.benchWithThroughput(
        "common-prefix-miss-4096",
        "common-prefix miss, 4096 routes",
        .{ .elements = 1 },
        Runner(Graph4096, "GET", miss_path, .not_found).bench,
    ),
    sigbench.benchWithThroughput(
        "selected-1",
        "last literal route hit, 1 route",
        .{ .elements = 1 },
        Runner(Graph1, "GET", last_path_1, .selected).bench,
    ),
    sigbench.benchWithThroughput(
        "selected-512",
        "last literal route hit, 512 routes",
        .{ .elements = 1 },
        Runner(Graph512, "GET", last_path_512, .selected).bench,
    ),
    sigbench.benchWithThroughput(
        "selected-4096",
        "last literal route hit, 4096 routes",
        .{ .elements = 1 },
        Runner(Graph4096, "GET", last_path_4096, .selected).bench,
    ),
    sigbench.benchWithThroughput(
        "method-not-allowed-1",
        "405 allow synthesis, 1 route",
        .{ .elements = 1 },
        Runner(Graph1, "PUT", last_path_1, .method_not_allowed).bench,
    ),
    sigbench.benchWithThroughput(
        "method-not-allowed-512",
        "405 allow synthesis, 512 routes",
        .{ .elements = 1 },
        Runner(Graph512, "PUT", last_path_512, .method_not_allowed).bench,
    ),
    sigbench.benchWithThroughput(
        "method-not-allowed-4096",
        "405 allow synthesis, 4096 routes",
        .{ .elements = 1 },
        Runner(Graph4096, "PUT", last_path_4096, .method_not_allowed).bench,
    ),
    sigbench.benchWithThroughput(
        "options-1",
        "OPTIONS allow synthesis, 1 route",
        .{ .elements = 1 },
        Runner(Graph1, "OPTIONS", last_path_1, .options).bench,
    ),
    sigbench.benchWithThroughput(
        "options-512",
        "OPTIONS allow synthesis, 512 routes",
        .{ .elements = 1 },
        Runner(Graph512, "OPTIONS", last_path_512, .options).bench,
    ),
    sigbench.benchWithThroughput(
        "options-4096",
        "OPTIONS allow synthesis, 4096 routes",
        .{ .elements = 1 },
        Runner(Graph4096, "OPTIONS", last_path_4096, .options).bench,
    ),
});

fn overlapCase(
    comptime id: []const u8,
    comptime name: []const u8,
    comptime F: type,
    comptime method: []const u8,
    comptime path: []const u8,
    comptime expected: Expected,
) sigbench.BenchmarkCase {
    return sigbench.benchWithThroughput(
        id,
        name,
        .{ .elements = 1 },
        Runner(F.Graph, method, path, expected).bench,
    );
}

pub const overlap_group = sigbench.groupWithId(
    "m14-route-overlap",
    "M14 adversarial route overlap",
    .{
        overlapCase(
            "options-6",
            "OPTIONS 64 routes",
            Overlap6,
            "OPTIONS",
            &Overlap6.literal_path,
            .options,
        ),
        overlapCase(
            "405-6",
            "405 64 routes",
            Overlap6,
            "PUT",
            &Overlap6.literal_path,
            .method_not_allowed,
        ),
        overlapCase("miss-6", "miss 64 routes", Overlap6, "GET", &Overlap6.miss_path, .not_found),
        overlapCase(
            "options-8",
            "OPTIONS 256 routes",
            Overlap8,
            "OPTIONS",
            &Overlap8.literal_path,
            .options,
        ),
        overlapCase(
            "405-8",
            "405 256 routes",
            Overlap8,
            "PUT",
            &Overlap8.literal_path,
            .method_not_allowed,
        ),
        overlapCase("miss-8", "miss 256 routes", Overlap8, "GET", &Overlap8.miss_path, .not_found),
        overlapCase(
            "options-10",
            "OPTIONS 1024 routes",
            Overlap10,
            "OPTIONS",
            &Overlap10.literal_path,
            .options,
        ),
        overlapCase(
            "405-10",
            "405 1024 routes",
            Overlap10,
            "PUT",
            &Overlap10.literal_path,
            .method_not_allowed,
        ),
        overlapCase(
            "miss-10",
            "miss 1024 routes",
            Overlap10,
            "GET",
            &Overlap10.miss_path,
            .not_found,
        ),
        overlapCase(
            "options-12",
            "OPTIONS 4096 routes",
            Overlap12,
            "OPTIONS",
            &Overlap12.literal_path,
            .options,
        ),
        overlapCase(
            "405-12",
            "405 4096 routes",
            Overlap12,
            "PUT",
            &Overlap12.literal_path,
            .method_not_allowed,
        ),
        overlapCase(
            "miss-12",
            "miss 4096 routes",
            Overlap12,
            "GET",
            &Overlap12.miss_path,
            .not_found,
        ),
    },
);
