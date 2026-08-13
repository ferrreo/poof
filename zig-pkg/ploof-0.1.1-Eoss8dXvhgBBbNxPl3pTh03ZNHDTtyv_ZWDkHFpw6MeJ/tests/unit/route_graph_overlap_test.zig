const std = @import("std");

const route = @import("../../src/route.zig");
const route_graph = @import("../../src/internal/route_graph.zig");
const route_graph_search = @import("../../src/internal/route_graph/search.zig");

pub const Definition = struct {
    method: route.Method,
    path: []const u8,
    route_id: u16,
};

pub fn Fixture(comptime depth: usize) type {
    const count = @as(usize, 1) << @intCast(depth);
    return struct {
        const paths = makePaths(depth);
        pub const definitions = makeDefinitions(&paths);
        pub const Graph = route_graph.Graph(definitions, .{
            .routes_max = @intCast(count),
            .search_visits_max = @intCast(count * 2 - 1),
        });
        pub const literal_path = makeLiteralPath(depth);
        pub const miss_path = literal_path ++ "/miss".*;
    };
}

const Counts = struct {
    options: u64,
    method_not_allowed: u64,
    miss: u64,
};

test "adversarial literal parameter overlap visit counts" {
    inline for (.{ 6, 8, 10, 12 }) |depth| {
        const F = Fixture(depth);
        const counts = try visitCounts(F);
        const one_search = (@as(u64, 1) << @intCast(depth + 1)) - 1;
        try std.testing.expectEqual(one_search, counts.options);
        try std.testing.expectEqual(one_search * 2 - 1, counts.method_not_allowed);
        try std.testing.expectEqual(one_search * 2 - 1, counts.miss);
        try std.testing.expectEqual(one_search, F.Graph.search_visits_bound);
        try std.testing.expectEqual(@as(u8, 3), F.Graph.select_searches_bound);
    }
}

fn visitCounts(comptime F: type) !Counts {
    var workspace: F.Graph.SearchWorkspace = undefined;
    var captures: F.Graph.CaptureBuffer = undefined;
    route_graph_search.TestAccess.beginVisitCount();
    const options = F.Graph.select(.{
        .method = "OPTIONS",
        .path = &F.literal_path,
    }, &workspace, &captures);
    const options_visits = route_graph_search.TestAccess.endVisitCount();
    try std.testing.expect(options == .options);

    route_graph_search.TestAccess.beginVisitCount();
    const rejected = F.Graph.select(.{
        .method = "PUT",
        .path = &F.literal_path,
    }, &workspace, &captures);
    const rejected_visits = route_graph_search.TestAccess.endVisitCount();
    try std.testing.expect(rejected == .method_not_allowed);

    route_graph_search.TestAccess.beginVisitCount();
    const miss = F.Graph.select(.{
        .method = "GET",
        .path = &F.miss_path,
    }, &workspace, &captures);
    const miss_visits = route_graph_search.TestAccess.endVisitCount();
    try std.testing.expect(miss == .not_found);
    return .{
        .options = options_visits,
        .method_not_allowed = rejected_visits,
        .miss = miss_visits,
    };
}

fn makePaths(comptime depth: usize) [@as(usize, 1) << @intCast(depth)][depth * 5]u8 {
    const count = @as(usize, 1) << @intCast(depth);
    @setEvalBranchQuota(@intCast(@as(u64, count) * depth * 8 + 1_000));
    var paths: [count][depth * 5]u8 = undefined;
    for (&paths, 0..) |*path, route_index| {
        for (0..depth) |segment_index| {
            const bit = depth - 1 - segment_index;
            const literal = route_index & (@as(usize, 1) << @intCast(bit)) == 0;
            writeSegment(path[segment_index * 5 ..][0..5], segment_index, literal);
        }
    }
    return paths;
}

fn makeDefinitions(comptime paths: anytype) [paths.len]Definition {
    @setEvalBranchQuota(@intCast(@as(u64, paths.len) * 8 + 1_000));
    var result: [paths.len]Definition = undefined;
    for (&paths.*, 0..) |*path, route_index| {
        result[route_index] = .{
            .method = .get,
            .path = path,
            .route_id = @intCast(route_index),
        };
    }
    return result;
}

fn makeLiteralPath(comptime depth: usize) [depth * 5]u8 {
    var path: [depth * 5]u8 = undefined;
    for (0..depth) |segment_index| {
        writeSegment(path[segment_index * 5 ..][0..5], segment_index, true);
    }
    return path;
}

fn writeSegment(output: *[5]u8, index: usize, literal: bool) void {
    output.* = if (literal) "/l000".* else "/:p00".*;
    output[3] = '0' + @as(u8, @intCast(index / 10));
    output[4] = '0' + @as(u8, @intCast(index % 10));
}
