const std = @import("std");

pub const none_node = std.math.maxInt(u32);
pub const none_route = std.math.maxInt(u16);

const method_count = 6;

const EdgeKind = enum(u8) {
    literal,
    parameter,
    catch_all,
};

pub const Node = struct {
    segment: []const u8,
    literal_start: u32,
    literal_count: u16,
    parameter: u32,
    catch_all: u32,
    routes: [method_count]u16,

    pub fn hasChildren(node: Node) bool {
        return node.literal_count != 0 or
            node.parameter != none_node or node.catch_all != none_node;
    }
};

const BuildNode = struct {
    parent: u32 = none_node,
    kind: EdgeKind = .literal,
    segment: []const u8 = "",
    routes: [method_count]u16 = [_]u16{none_route} ** method_count,
};

pub fn Index(comptime routes: anytype, comptime nodes_max: u32) type {
    @setEvalBranchQuota(indexEvaluationQuota(routes));
    const node_count = comptime uniqueNodeCount(routes);
    if (node_count > nodes_max) {
        @compileError(std.fmt.comptimePrint(
            "PLOOF-E3122 route graph index nodes exceed configured limit: " ++
                "computed={d} configured={d}",
            .{ node_count, nodes_max },
        ));
    }
    const raw = comptime build(routes, node_count);
    const finished = comptime finish(raw.nodes);
    const depth = comptime maximumDepth(routes);
    const bounds = comptime searchBounds(finished.nodes, finished.literals);

    return struct {
        pub const nodes = finished.nodes;
        pub const literals = finished.literals;
        pub const maximum_depth = depth;
        pub const static_bytes = nodes.len * @sizeOf(Node) + literals.len * @sizeOf(u32);
        pub const search_visits_bound = bounds.visits;
        pub const search_compare_bytes_bound = bounds.compare_bytes;
    };
}

pub fn literalChild(
    comptime index: type,
    path: anytype,
    parent: u32,
    start: usize,
    end: usize,
) u32 {
    const node = index.nodes[parent];
    var low: usize = node.literal_start;
    var high = low + node.literal_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const child = index.literals[middle];
        switch (compareSegment(index.nodes[child].segment, path, start, end)) {
            .lt => low = middle + 1,
            .eq => return child,
            .gt => high = middle,
        }
    }
    return none_node;
}

fn compareSegment(literal: []const u8, path: anytype, start: usize, end: usize) std.math.Order {
    const path_length = end - start;
    const compared = @min(literal.len, path_length);
    for (literal[0..compared], start..) |byte, index| {
        if (byte < path.at(index)) return .lt;
        if (byte > path.at(index)) return .gt;
    }
    return std.math.order(literal.len, path_length);
}

fn BuildStorage(comptime node_count: usize) type {
    return struct {
        nodes: [node_count]BuildNode,
    };
}

fn build(
    comptime routes: anytype,
    comptime node_count_expected: usize,
) BuildStorage(node_count_expected) {
    @setEvalBranchQuota(branchQuota(totalSegments(routes), 32));
    const Storage = BuildStorage(node_count_expected);
    var result = Storage{ .nodes = undefined };
    result.nodes[0] = .{};
    var lineage: [maximumDepth(routes)]u32 = undefined;
    var node_count: usize = 1;
    for (routes, 0..) |metadata, route_index| {
        const shared = if (route_index == 0)
            0
        else
            sharedDepth(routes[route_index - 1].pattern, metadata.pattern);
        const parent = if (shared == 0) 0 else lineage[shared - 1];
        insertRoute(
            &result,
            &lineage,
            &node_count,
            metadata,
            @intCast(route_index),
            parent,
            shared,
        );
    }
    std.debug.assert(node_count == result.nodes.len);
    return result;
}

fn insertRoute(
    state: anytype,
    lineage: anytype,
    node_count: *usize,
    metadata: anytype,
    route_index: u16,
    initial_parent: u32,
    shared: u16,
) void {
    @setEvalBranchQuota(branchQuota(metadata.segment_count, 16));
    var parent = initial_parent;
    var depth = shared;
    var start = segmentStart(metadata.pattern, shared);
    while (depth < metadata.segment_count) : (depth += 1) {
        const end = nextSlash(metadata.pattern, start);
        const raw_segment = metadata.pattern[start..end];
        const kind = edgeKind(raw_segment);
        const segment = if (kind == .literal) raw_segment else "";
        const inserted: u32 = @intCast(node_count.*);
        node_count.* += 1;
        state.nodes[inserted] = .{ .parent = parent, .kind = kind, .segment = segment };
        lineage[depth] = inserted;
        parent = inserted;
        start = end + 1;
    }
    const method_index: usize = @intFromEnum(metadata.method);
    std.debug.assert(state.nodes[parent].routes[method_index] == none_route);
    state.nodes[parent].routes[method_index] = route_index;
}

fn uniqueNodeCount(comptime routes: anytype) usize {
    @setEvalBranchQuota(branchQuota(totalSegments(routes), 64));
    var count: usize = 1;
    for (routes, 0..) |metadata, index| {
        const shared = if (index == 0)
            0
        else
            sharedDepth(routes[index - 1].pattern, metadata.pattern);
        count += metadata.segment_count - shared;
    }
    return count;
}

fn sharedDepth(left: []const u8, right: []const u8) u16 {
    var left_start: usize = 1;
    var right_start: usize = 1;
    var depth: u16 = 0;
    while (true) {
        const left_end = nextSlash(left, left_start);
        const right_end = nextSlash(right, right_start);
        const left_segment = left[left_start..left_end];
        const right_segment = right[right_start..right_end];
        if (edgeKind(left_segment) != edgeKind(right_segment)) return depth;
        if (edgeKind(left_segment) == .literal and
            !std.mem.eql(u8, left_segment, right_segment)) return depth;
        depth += 1;
        if (left_end == left.len or right_end == right.len) return depth;
        left_start = left_end + 1;
        right_start = right_end + 1;
    }
}

fn segmentStart(pattern: []const u8, depth: u16) usize {
    var start: usize = 1;
    for (0..depth) |_| start = nextSlash(pattern, start) + 1;
    return start;
}

fn RuntimeStorage(comptime nodes: anytype) type {
    return struct {
        nodes: [nodes.len]Node,
        literals: [literalCount(nodes)]u32,
    };
}

fn finish(comptime build_nodes: anytype) RuntimeStorage(build_nodes) {
    @setEvalBranchQuota(branchQuota(build_nodes.len, 128));
    const Storage = RuntimeStorage(build_nodes);
    var result: Storage = undefined;
    var literal_counts = [_]u16{0} ** build_nodes.len;
    for (build_nodes[1..]) |node| {
        if (node.kind == .literal) literal_counts[node.parent] += 1;
    }
    var literal_start: u32 = 0;
    for (build_nodes, 0..) |node, node_index| {
        result.nodes[node_index] = .{
            .segment = node.segment,
            .literal_start = literal_start,
            .literal_count = literal_counts[node_index],
            .parameter = none_node,
            .catch_all = none_node,
            .routes = node.routes,
        };
        literal_start += literal_counts[node_index];
    }
    std.debug.assert(literal_start == result.literals.len);
    fillChildren(build_nodes, &result);
    sortLiterals(&result);
    return result;
}

fn fillChildren(comptime build_nodes: anytype, result: anytype) void {
    @setEvalBranchQuota(branchQuota(build_nodes.len, 32));
    var cursors = [_]u16{0} ** build_nodes.len;
    for (build_nodes[1..], 1..) |node, child| {
        const parent = &result.nodes[node.parent];
        switch (node.kind) {
            .literal => {
                const destination = parent.literal_start + cursors[node.parent];
                result.literals[destination] = @intCast(child);
                cursors[node.parent] += 1;
            },
            .parameter => {
                std.debug.assert(parent.parameter == none_node);
                parent.parameter = @intCast(child);
            },
            .catch_all => {
                std.debug.assert(parent.catch_all == none_node);
                parent.catch_all = @intCast(child);
            },
        }
    }
}

fn sortLiterals(result: anytype) void {
    @setEvalBranchQuota(branchQuota(result.nodes.len, 128));
    for (result.nodes) |node| {
        const start: usize = node.literal_start;
        const end = start + node.literal_count;
        sortLiteralRange(result, start, end);
    }
}

fn sortLiteralRange(result: anytype, start: usize, end: usize) void {
    const count = end - start;
    var root = count / 2;
    while (root != 0) {
        root -= 1;
        siftDown(result, start, root, count);
    }
    var remaining = count;
    while (remaining > 1) {
        std.mem.swap(u32, &result.literals[start], &result.literals[start + remaining - 1]);
        remaining -= 1;
        siftDown(result, start, 0, remaining);
    }
}

fn siftDown(result: anytype, start: usize, initial_root: usize, count: usize) void {
    var root = initial_root;
    while (root * 2 + 1 < count) {
        var child = root * 2 + 1;
        if (child + 1 < count and literalLess(result, start + child, start + child + 1)) {
            child += 1;
        }
        if (!literalLess(result, start + root, start + child)) return;
        std.mem.swap(u32, &result.literals[start + root], &result.literals[start + child]);
        root = child;
    }
}

fn literalLess(result: anytype, left_slot: usize, right_slot: usize) bool {
    const left = result.nodes[result.literals[left_slot]].segment;
    const right = result.nodes[result.literals[right_slot]].segment;
    return std.mem.order(u8, left, right) == .lt;
}

fn literalCount(comptime nodes: anytype) usize {
    @setEvalBranchQuota(branchQuota(nodes.len, 4));
    var count: usize = 0;
    for (nodes[1..]) |node| count += @intFromBool(node.kind == .literal);
    return count;
}

const SearchBounds = struct {
    visits: u32,
    compare_bytes: u64,
};

fn searchBounds(comptime nodes: anytype, comptime literals: anytype) SearchBounds {
    @setEvalBranchQuota(branchQuota(nodes.len, 64));
    var visits: [nodes.len]u32 = undefined;
    var compare_bytes: [nodes.len]u64 = undefined;
    var remaining = nodes.len;
    while (remaining != 0) {
        remaining -= 1;
        const node = nodes[remaining];
        var literal_visits: u32 = 0;
        var literal_compare_bytes: u64 = 0;
        const start: usize = node.literal_start;
        const end = start + node.literal_count;
        for (literals[start..end]) |child| {
            literal_visits = @max(literal_visits, visits[child]);
            literal_compare_bytes = @max(literal_compare_bytes, compare_bytes[child]);
        }
        const parameter_visits = childVisits(node.parameter, &visits);
        const catch_all_visits = childVisits(node.catch_all, &visits);
        visits[remaining] = 1 + literal_visits + parameter_visits + catch_all_visits;
        compare_bytes[remaining] = literalLookupBytes(nodes, literals, node) +
            literal_compare_bytes + childCompareBytes(node.parameter, &compare_bytes);
    }
    return .{ .visits = visits[0], .compare_bytes = compare_bytes[0] };
}

fn childVisits(child: u32, visits: []const u32) u32 {
    return if (child == none_node) 0 else visits[child];
}

fn childCompareBytes(child: u32, compare_bytes: []const u64) u64 {
    return if (child == none_node) 0 else compare_bytes[child];
}

fn literalLookupBytes(comptime nodes: anytype, literals: anytype, node: Node) u64 {
    var maximum_length: usize = 0;
    const start: usize = node.literal_start;
    const end = start + node.literal_count;
    for (literals[start..end]) |child| {
        maximum_length = @max(maximum_length, nodes[child].segment.len);
    }
    var candidates = node.literal_count;
    var comparisons: u8 = 0;
    while (candidates != 0) : (candidates >>= 1) comparisons += 1;
    return @as(u64, comparisons) * maximum_length;
}

fn totalSegments(comptime routes: anytype) usize {
    @setEvalBranchQuota(branchQuota(routes.len, 4));
    var count: usize = 0;
    for (routes) |metadata| count += metadata.segment_count;
    return count;
}

fn maximumDepth(comptime routes: anytype) u16 {
    @setEvalBranchQuota(branchQuota(routes.len, 4));
    var depth: u16 = 1;
    for (routes) |metadata| depth = @max(depth, metadata.segment_count);
    return depth;
}

fn edgeKind(segment: []const u8) EdgeKind {
    if (segment.len == 0) return .literal;
    return switch (segment[0]) {
        ':' => .parameter,
        '*' => .catch_all,
        else => .literal,
    };
}

fn nextSlash(bytes: []const u8, start: usize) usize {
    return std.mem.indexOfScalarPos(u8, bytes, start, '/') orelse bytes.len;
}

fn indexEvaluationQuota(comptime routes: anytype) u32 {
    const work: u64 = @as(u64, totalSegments(routes)) * 128 + routes.len * 512 + 100_000;
    return @intCast(@min(work, std.math.maxInt(u32)));
}

fn branchQuota(comptime items: usize, comptime branches_per_item: usize) u32 {
    const work: u64 = @as(u64, items) * branches_per_item + 1_000;
    return @intCast(@min(work, std.math.maxInt(u32)));
}
