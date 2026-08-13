const route_graph = @import("../src/internal/route_graph.zig");
const route = @import("../src/route.zig");
const behavior = @import("../tests/unit/internal/route_graph_test.zig");
const scale = @import("../tests/unit/internal/route_graph_scale_test.zig");

const Graph1 = route_graph.Graph(scale.definitions(1), .{ .routes_max = 1 });
const Graph512 = route_graph.Graph(scale.definitions(512), .{});
const Graph4096 = route_graph.Graph(scale.definitions(4096), .{
    .routes_max = route.routes_hard_max,
});

test {
    _ = behavior;
    _ = route_graph;
}

test "route graph scale 1 common-prefix route" {
    try scale.run(Graph1, 1);
}

test "route graph scale 512 common-prefix routes" {
    try scale.run(Graph512, 512);
}

test "route graph scale 4096 common-prefix routes" {
    try scale.run(Graph4096, 4096);
}
