const std = @import("std");
const builtin = @import("builtin");
const route = @import("../../route.zig");
const route_graph_index = @import("index.zig");

const TestCounters = if (builtin.is_test) struct {
    var count_visits = std.atomic.Value(bool).init(false);
    var visits = std.atomic.Value(u64).init(0);
    var searches = std.atomic.Value(u64).init(0);
} else struct {};

pub const PathView = struct {
    bytes: []const u8,
    append_slash: bool = false,

    pub fn len(view: PathView) usize {
        return view.bytes.len + @intFromBool(view.append_slash);
    }

    pub fn at(view: PathView, index: usize) u8 {
        if (index < view.bytes.len) return view.bytes[index];
        std.debug.assert(view.append_slash);
        std.debug.assert(index == view.bytes.len);
        return '/';
    }
};

pub const Result = struct {
    found: ?u16 = null,
    allow_mask: u8 = 0,
};

const Stage = enum(u8) {
    literal,
    parameter,
    catch_all,
    done,
};

const Frame = struct {
    node: u32,
    segment_index: u16,
    stage: Stage = .literal,
};

pub fn Workspace(comptime Index: type) type {
    return struct {
        frames: [Index.maximum_depth]Frame = undefined,
        segment_ends: [Index.maximum_depth]u32 = undefined,
    };
}

pub fn search(
    comptime Index: type,
    target: ?route.Method,
    path: PathView,
    workspace: *Workspace(Index),
) Result {
    var result = Result{};
    if (path.len() == 0 or path.len() > std.math.maxInt(u32) or path.at(0) != '/') {
        return result;
    }
    countSearchForTest();
    tokenize(Index, path, &workspace.segment_ends);
    const frames = &workspace.frames;
    frames[0] = makeFrame(0, 0);
    var depth: usize = 1;
    while (depth != 0) {
        const frame = &frames[depth - 1];
        if (frame.stage == .done) {
            depth -= 1;
            continue;
        }
        const edge = frame.stage;
        frame.stage = @enumFromInt(@intFromEnum(edge) + 1);
        const segment_start = segmentStart(&workspace.segment_ends, frame.segment_index);
        const segment_end = workspace.segment_ends[frame.segment_index];
        const child = childFor(Index, path, frame.*, segment_start, segment_end, edge);
        if (child == route_graph_index.none_node) continue;
        countVisitForTest();
        if (edge == .catch_all or segment_end == @as(u32, @intCast(path.len()))) {
            if (terminal(Index, child, target, &result.allow_mask)) |index| {
                result.found = index;
                return result;
            }
            continue;
        }
        if (!Index.nodes[child].hasChildren()) continue;
        std.debug.assert(depth < frames.len);
        frames[depth] = makeFrame(
            child,
            frame.segment_index + 1,
        );
        depth += 1;
    }
    if (result.allow_mask != 0) result.allow_mask |= 1 << 6;
    return result;
}

pub const TestAccess = if (builtin.is_test) struct {
    pub fn beginVisitCount() void {
        TestCounters.visits.store(1, .release);
        TestCounters.searches.store(0, .release);
        TestCounters.count_visits.store(true, .release);
    }

    pub fn endVisitCount() u64 {
        TestCounters.count_visits.store(false, .release);
        return TestCounters.visits.load(.acquire);
    }

    pub fn searchCount() u64 {
        return TestCounters.searches.load(.acquire);
    }
} else struct {};

fn countVisitForTest() void {
    if (comptime !builtin.is_test) return;
    if (TestCounters.count_visits.load(.acquire)) {
        _ = TestCounters.visits.fetchAdd(1, .monotonic);
    }
}

fn countSearchForTest() void {
    if (comptime !builtin.is_test) return;
    if (TestCounters.count_visits.load(.acquire)) {
        _ = TestCounters.searches.fetchAdd(1, .monotonic);
    }
}

fn terminal(
    comptime Index: type,
    node_index: u32,
    target: ?route.Method,
    allow_mask: *u8,
) ?u16 {
    const node = Index.nodes[node_index];
    inline for (std.enums.values(route.Method)) |method| {
        if (node.routes[@intFromEnum(method)] != route_graph_index.none_route) {
            addMethod(allow_mask, method);
        }
    }
    const method = target orelse return null;
    const route_index = node.routes[@intFromEnum(method)];
    return if (route_index == route_graph_index.none_route) null else route_index;
}

fn makeFrame(node: u32, segment_index: u16) Frame {
    return .{
        .node = node,
        .segment_index = segment_index,
    };
}

fn childFor(
    comptime Index: type,
    path: PathView,
    frame: Frame,
    segment_start: u32,
    segment_end: u32,
    edge: Stage,
) u32 {
    const node = Index.nodes[frame.node];
    return switch (edge) {
        .literal => route_graph_index.literalChild(
            Index,
            path,
            frame.node,
            @intCast(segment_start),
            @intCast(segment_end),
        ),
        .parameter => if (segment_start == segment_end)
            route_graph_index.none_node
        else
            node.parameter,
        .catch_all => node.catch_all,
        .done => unreachable,
    };
}

fn addMethod(mask: *u8, method: route.Method) void {
    mask.* |= @as(u8, 1) << @intCast(@intFromEnum(method));
    if (method == .get) mask.* |= @as(u8, 1) << @intCast(@intFromEnum(route.Method.head));
}

fn nextSlash(path: PathView, start: usize) usize {
    var index = start;
    while (index < path.len() and path.at(index) != '/') : (index += 1) {}
    return index;
}

fn tokenize(comptime Index: type, path: PathView, ends: *[Index.maximum_depth]u32) void {
    var start: usize = 1;
    for (ends) |*end| {
        end.* = @intCast(nextSlash(path, start));
        if (end.* == @as(u32, @intCast(path.len()))) return;
        start = @as(usize, end.*) + 1;
    }
}

fn segmentStart(ends: anytype, segment_index: u16) u32 {
    return if (segment_index == 0) 1 else ends[segment_index - 1] + 1;
}
