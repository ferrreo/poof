const std = @import("std");
const fuzz_support = @import("../../src/internal/http1/testing/smith.zig");
const route = @import("../../src/route.zig");
const route_graph_search = @import("../../src/internal/route_graph/search.zig");

const Context = struct {};

pub fn run(comptime Graph: type, comptime ReversedGraph: type) !void {
    const Adapter = struct {
        fn testOne(_: Context, smith: *std.testing.Smith) anyerror!void {
            var input_storage: [256]u8 = undefined;
            const input = input_storage[0..smith.slice(&input_storage)];
            var workspace: Graph.SearchWorkspace = undefined;
            var captures: Graph.CaptureBuffer = undefined;
            var method_storage: [8]u8 = undefined;
            const split = std.mem.indexOfScalar(u8, input, 0) orelse input.len;
            const method_len = @min(split, method_storage.len);
            @memcpy(method_storage[0..method_len], input[0..method_len]);
            const path_start = @min(split + @intFromBool(split < input.len), input.len);
            const method = method_storage[0..method_len];
            const path = input[path_start..];
            const terminal_literal = smith.value(bool);
            route_graph_search.TestAccess.beginVisitCount();
            const first = Graph.select(.{
                .method = method,
                .path = path,
                .terminal_slash_is_literal = terminal_literal,
            }, &workspace, &captures);
            const first_visits = route_graph_search.TestAccess.endVisitCount();
            const first_searches = route_graph_search.TestAccess.searchCount();
            try std.testing.expect(first_visits <= Graph.select_visits_bound);
            try std.testing.expect(first_searches <= Graph.select_searches_bound);
            try checkSelection(first, path, Graph.maximum_captures);
            try compareReference(Graph, first, method, path, terminal_literal);

            var second_workspace: ReversedGraph.SearchWorkspace = undefined;
            var second_captures: ReversedGraph.CaptureBuffer = undefined;
            route_graph_search.TestAccess.beginVisitCount();
            const second = ReversedGraph.select(.{
                .method = method,
                .path = path,
                .terminal_slash_is_literal = terminal_literal,
            }, &second_workspace, &second_captures);
            const second_visits = route_graph_search.TestAccess.endVisitCount();
            const second_searches = route_graph_search.TestAccess.searchCount();
            try std.testing.expect(second_visits <= ReversedGraph.select_visits_bound);
            try std.testing.expect(second_searches <= ReversedGraph.select_searches_bound);
            try expectEquivalent(first, second, path);
        }
    };

    try std.testing.fuzz(Context{}, Adapter.testOne, .{ .corpus = &fuzz_corpus });
}

const fuzz_corpus = struct {
    const literal = fuzz_support.smithInputThenU64("GET\x00/users/new", 1);
    const parameter = fuzz_support.smithInput("GET\x00/users/value");
    const catch_all = fuzz_support.smithInput("GET\x00/users/a/b");
    const head = fuzz_support.smithInput("HEAD\x00/explicit");
    const options = fuzz_support.smithInput("OPTIONS\x00/users/x");
    const unknown = fuzz_support.smithInput("TRACE\x00/users/x");
    const exact = fuzz_support.smithInput("GET\x00/Case/./x//");
    const delete = fuzz_support.smithInput("DELETE\x00/only-delete");
    const empty_catch_all = fuzz_support.smithInput("GET\x00/assets/");
    const redirect = fuzz_support.smithInput("GET\x00/slash");
    const options_redirect = fuzz_support.smithInput("OPTIONS\x00/slash");

    const values = [_][]const u8{
        &literal,
        &parameter,
        &catch_all,
        &head,
        &options,
        &unknown,
        &exact,
        &delete,
        &empty_catch_all,
        &redirect,
        &options_redirect,
    };
}.values;

const ReferenceTag = enum(u8) {
    selected,
    redirect,
    options,
    method_not_allowed,
    not_implemented,
    not_found,
};

const Reference = struct {
    tag: ReferenceTag,
    route_id: u16 = 0,
    head_uses_get: bool = false,
    allow_mask: u8 = 0,
    redirect_status: u16 = 0,
    slash_add: bool = false,
    redirect_route_id: ?u16 = null,
};

const ParsedMethod = enum(u8) {
    get,
    head,
    post,
    put,
    patch,
    delete,
    options,
    unknown,

    fn declared(parsed: ParsedMethod) ?route.Method {
        return switch (parsed) {
            .get => .get,
            .head => .head,
            .post => .post,
            .put => .put,
            .patch => .patch,
            .delete => .delete,
            .options, .unknown => null,
        };
    }
};

const ReferenceFound = struct {
    route_id: u16,
    head_uses_get: bool,
};

const ReferenceAlternate = struct {
    path: []const u8,
    add: bool,
};

const ReferenceCapture = struct {
    name: []const u8,
    value: []const u8,
    catch_all: bool,
};

fn referenceSelection(
    comptime Graph: type,
    method_bytes: []const u8,
    path: []const u8,
    terminal_literal: bool,
) Reference {
    const parsed = referenceMethod(method_bytes);
    if (parsed == .unknown) return .{ .tag = .not_implemented };
    if (parsed == .options and std.mem.eql(u8, path, "*")) {
        return .{ .tag = .options, .allow_mask = referenceServerAllow(Graph) };
    }
    var alternate_storage: [257]u8 = undefined;
    if (parsed.declared()) |method| {
        if (referenceRequested(Graph, method, path)) |found| return referenceFound(found);
        if (referenceAlternate(path, terminal_literal, &alternate_storage)) |other| {
            if (referenceRequested(Graph, method, other.path)) |found| {
                return referenceRedirect(method == .get, other.add, found.route_id);
            }
        }
        const allow = referenceAllow(Graph, path);
        if (allow != 0) return .{ .tag = .method_not_allowed, .allow_mask = allow };
        return .{ .tag = .not_found };
    }
    const allow = referenceAllow(Graph, path);
    if (allow != 0) return .{ .tag = .options, .allow_mask = allow };
    if (referenceAlternate(path, terminal_literal, &alternate_storage)) |other| {
        if (referenceAllow(Graph, other.path) != 0) {
            return referenceRedirect(false, other.add, null);
        }
    }
    return .{ .tag = .not_found };
}

fn referenceMethod(bytes: []const u8) ParsedMethod {
    if (std.mem.eql(u8, bytes, "GET")) return .get;
    if (std.mem.eql(u8, bytes, "HEAD")) return .head;
    if (std.mem.eql(u8, bytes, "POST")) return .post;
    if (std.mem.eql(u8, bytes, "PUT")) return .put;
    if (std.mem.eql(u8, bytes, "PATCH")) return .patch;
    if (std.mem.eql(u8, bytes, "DELETE")) return .delete;
    if (std.mem.eql(u8, bytes, "OPTIONS")) return .options;
    return .unknown;
}

fn referenceRequested(
    comptime Graph: type,
    method: route.Method,
    path: []const u8,
) ?ReferenceFound {
    if (method == .head) {
        if (referenceFind(Graph, .head, path)) |route_id| {
            return .{ .route_id = route_id, .head_uses_get = false };
        }
        if (referenceFind(Graph, .get, path)) |route_id| {
            return .{ .route_id = route_id, .head_uses_get = true };
        }
        return null;
    }
    const route_id = referenceFind(Graph, method, path) orelse return null;
    return .{ .route_id = route_id, .head_uses_get = false };
}

fn referenceFind(comptime Graph: type, method: route.Method, path: []const u8) ?u16 {
    var best: ?@TypeOf(Graph.routes[0]) = null;
    for (Graph.routes) |metadata| {
        if (metadata.method != method or !referenceMatches(metadata.pattern, path)) continue;
        if (best == null or referencePrecedes(metadata.pattern, best.?.pattern)) best = metadata;
    }
    return if (best) |metadata| metadata.route_id else null;
}

fn referenceMatches(pattern: []const u8, path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    var patterns = std.mem.splitScalar(u8, pattern[1..], '/');
    var paths = std.mem.splitScalar(u8, path[1..], '/');
    while (patterns.next()) |pattern_segment| {
        const path_segment = paths.next() orelse return false;
        if (pattern_segment.len != 0 and pattern_segment[0] == '*') return true;
        if (pattern_segment.len != 0 and pattern_segment[0] == ':') {
            if (path_segment.len == 0) return false;
        } else if (!std.mem.eql(u8, pattern_segment, path_segment)) return false;
    }
    return paths.next() == null;
}

fn referencePrecedes(left: []const u8, right: []const u8) bool {
    var left_segments = std.mem.splitScalar(u8, left[1..], '/');
    var right_segments = std.mem.splitScalar(u8, right[1..], '/');
    while (left_segments.next()) |left_segment| {
        const right_segment = right_segments.next() orelse return false;
        const left_rank = referenceSegmentRank(left_segment);
        const right_rank = referenceSegmentRank(right_segment);
        if (left_rank != right_rank) return left_rank < right_rank;
        if (left_rank == 0) {
            const order = std.mem.order(u8, left_segment, right_segment);
            if (order != .eq) return order == .lt;
        }
    }
    return right_segments.next() != null;
}

fn referenceSegmentRank(segment: []const u8) u8 {
    if (segment.len == 0) return 0;
    return switch (segment[0]) {
        ':' => 1,
        '*' => 2,
        else => 0,
    };
}

fn referenceAllow(comptime Graph: type, path: []const u8) u8 {
    var mask: u8 = 0;
    inline for (std.enums.values(route.Method), 0..) |method, index| {
        if (referenceFind(Graph, method, path) != null) {
            mask |= @as(u8, 1) << @intCast(index);
            if (method == .get) mask |= 1 << 1;
        }
    }
    if (mask != 0) mask |= 1 << 6;
    return mask;
}

fn referenceServerAllow(comptime Graph: type) u8 {
    var mask: u8 = 0;
    for (Graph.routes) |metadata| {
        mask |= @as(u8, 1) << @as(u3, @intCast(@intFromEnum(metadata.method)));
        if (metadata.method == .get) mask |= 1 << 1;
    }
    if (mask != 0) mask |= 1 << 6;
    return mask;
}

fn referenceAlternate(path: []const u8, literal: bool, output: []u8) ?ReferenceAlternate {
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return null;
    if (path[path.len - 1] == '/') {
        if (!literal) return null;
        return .{ .path = path[0 .. path.len - 1], .add = false };
    }
    if (output.len < path.len + 1) return null;
    @memcpy(output[0..path.len], path);
    output[path.len] = '/';
    return .{ .path = output[0 .. path.len + 1], .add = true };
}

fn referenceFound(found: ReferenceFound) Reference {
    return .{
        .tag = .selected,
        .route_id = found.route_id,
        .head_uses_get = found.head_uses_get,
    };
}

fn referenceRedirect(permanent: bool, add: bool, route_id: ?u16) Reference {
    return .{
        .tag = .redirect,
        .redirect_status = if (permanent) 301 else 307,
        .slash_add = add,
        .redirect_route_id = route_id,
    };
}

fn referenceCaptures(
    comptime Graph: type,
    route_id: u16,
    path: []const u8,
    output: []ReferenceCapture,
) usize {
    const pattern = for (Graph.routes) |metadata| {
        if (metadata.route_id == route_id) break metadata.pattern;
    } else unreachable;
    var patterns = std.mem.splitScalar(u8, pattern[1..], '/');
    var paths = std.mem.splitScalar(u8, path[1..], '/');
    var count: usize = 0;
    while (patterns.next()) |pattern_segment| {
        const path_segment = paths.next() orelse unreachable;
        if (pattern_segment.len == 0) continue;
        if (pattern_segment[0] == ':') {
            output[count] = .{
                .name = pattern_segment[1..],
                .value = path_segment,
                .catch_all = false,
            };
            count += 1;
        } else if (pattern_segment[0] == '*') {
            const offset = @intFromPtr(path_segment.ptr) - @intFromPtr(path.ptr);
            output[count] = .{
                .name = pattern_segment[1..],
                .value = path[offset - 1 ..],
                .catch_all = true,
            };
            return count + 1;
        }
    }
    return count;
}

fn compareReference(
    comptime Graph: type,
    selection: anytype,
    method: []const u8,
    path: []const u8,
    terminal_literal: bool,
) !void {
    const expected = referenceSelection(Graph, method, path, terminal_literal);
    switch (selection) {
        .selected => |match| {
            try std.testing.expectEqual(ReferenceTag.selected, expected.tag);
            try std.testing.expectEqual(expected.route_id, match.route_id);
            try std.testing.expectEqual(expected.head_uses_get, match.head_uses_get);
            var captures: [Graph.maximum_captures]ReferenceCapture = undefined;
            const count = referenceCaptures(Graph, expected.route_id, path, &captures);
            try std.testing.expectEqual(count, match.captures.len);
            for (captures[0..count], match.captures) |reference, actual| {
                try std.testing.expectEqualStrings(reference.name, actual.name);
                try std.testing.expectEqualStrings(reference.value, actual.value(path));
                try std.testing.expectEqual(reference.catch_all, actual.kind == .catch_all);
            }
        },
        .redirect => |redirect| {
            try std.testing.expectEqual(ReferenceTag.redirect, expected.tag);
            try std.testing.expectEqual(expected.redirect_route_id, redirect.route_id);
            try std.testing.expectEqual(expected.redirect_status, @intFromEnum(redirect.status));
            try std.testing.expectEqual(expected.slash_add, redirect.slash_change == .add);
        },
        .options => |allow| try compareReferenceAllow(expected, .options, allow.mask),
        .method_not_allowed => |allow| {
            try compareReferenceAllow(expected, .method_not_allowed, allow.mask);
        },
        .not_implemented => try std.testing.expectEqual(.not_implemented, expected.tag),
        .not_found => try std.testing.expectEqual(.not_found, expected.tag),
    }
}

fn compareReferenceAllow(expected: Reference, tag: ReferenceTag, mask: u8) !void {
    try std.testing.expectEqual(tag, expected.tag);
    try std.testing.expectEqual(expected.allow_mask, mask);
}

fn checkSelection(selection: anytype, path: []const u8, maximum_captures: u16) !void {
    switch (selection) {
        .selected => |match| {
            try std.testing.expect(match.captures.len <= maximum_captures);
            for (match.captures) |capture| {
                try std.testing.expect(capture.start <= capture.end);
                try std.testing.expect(capture.end <= path.len);
                try std.testing.expect(capture.name.len != 0);
                _ = capture.value(path);
            }
        },
        .redirect => |redirect| {
            try std.testing.expect(path.len > 1);
            try std.testing.expect(switch (@intFromEnum(redirect.status)) {
                301, 307 => true,
                else => false,
            });
        },
        .options, .method_not_allowed => |allow| try checkAllow(allow),
        .not_implemented, .not_found => {},
    }
}

fn checkAllow(allow: anytype) !void {
    var output: [64]u8 = undefined;
    const wire = try allow.write(&output);
    try std.testing.expectEqual(allow.wireLength(), wire.len);
    try std.testing.expect(allow.containsOptions());
    if (allow.contains(.get)) try std.testing.expect(allow.contains(.head));
}

fn expectEquivalent(first: anytype, second: @TypeOf(first), path: []const u8) !void {
    try std.testing.expectEqual(std.meta.activeTag(first), std.meta.activeTag(second));
    switch (first) {
        .selected => |left| {
            const right = second.selected;
            try std.testing.expectEqual(left.route_id, right.route_id);
            try std.testing.expectEqual(left.head_uses_get, right.head_uses_get);
            try std.testing.expectEqual(left.captures.len, right.captures.len);
            for (left.captures, right.captures) |a, b| {
                try std.testing.expectEqualStrings(a.name, b.name);
                try std.testing.expectEqualStrings(a.value(path), b.value(path));
            }
        },
        .redirect => |left| try std.testing.expectEqual(left, second.redirect),
        .options => |left| try std.testing.expectEqual(left.mask, second.options.mask),
        .method_not_allowed => |left| {
            try std.testing.expectEqual(left.mask, second.method_not_allowed.mask);
        },
        .not_implemented, .not_found => {},
    }
}
