const std = @import("std");
const route = @import("../../../src/route.zig");

pub const Definition = struct {
    method: route.Method,
    path: []const u8,
    route_id: u16,
};

pub fn definitions(comptime count: usize) [count]Definition {
    if (count == 0 or count > 4096) @compileError("route scale count is outside 1...4096");
    const Fixture = struct {
        const paths = makePaths(count);
        const value = makeDefinitions(&paths);
    };
    return Fixture.value;
}

const path_prefix = "/shared/deep/prefix/route-";
const path_length = path_prefix.len + 4;

fn makePaths(comptime count: usize) [count][path_length]u8 {
    @setEvalBranchQuota(@intCast(@as(u64, count) * 64 + 1_000));
    var result: [count][path_length]u8 = undefined;
    for (&result, 0..) |*path, index| {
        @memcpy(path[0..path_prefix.len], path_prefix);
        var value = index;
        var digit = path.len;
        while (digit > path_prefix.len) {
            digit -= 1;
            path[digit] = '0' + @as(u8, @intCast(value % 10));
            value /= 10;
        }
        std.debug.assert(value == 0);
    }
    return result;
}

fn makeDefinitions(comptime paths: anytype) [paths.len]Definition {
    @setEvalBranchQuota(@intCast(@as(u64, paths.len) * 8 + 1_000));
    var result: [paths.len]Definition = undefined;
    for (&paths.*, 0..) |*path, index| {
        result[index] = .{
            .method = .get,
            .path = path,
            .route_id = @intCast(index),
        };
    }
    return result;
}

pub fn run(comptime Graph: type, comptime count: usize) !void {
    var workspace: Graph.SearchWorkspace = undefined;
    var captures: Graph.CaptureBuffer = undefined;
    const last_path = std.fmt.comptimePrint(
        "/shared/deep/prefix/route-{d:0>4}",
        .{count - 1},
    );
    const selected = Graph.select(.{ .method = "GET", .path = last_path }, &workspace, &captures);
    try expectSelected(selected, count - 1);

    const miss = Graph.select(.{
        .method = "GET",
        .path = "/shared/deep/prefix/not-present",
    }, &workspace, &captures);
    try std.testing.expect(miss == .not_found);

    const rejected = Graph.select(.{ .method = "PUT", .path = last_path }, &workspace, &captures);
    try expectAllow(rejected, false);
    const options = Graph.select(
        .{ .method = "OPTIONS", .path = last_path },
        &workspace,
        &captures,
    );
    try expectAllow(options, true);

    try std.testing.expectEqual(count + 4, Graph.index_node_count);
    try std.testing.expectEqual(count + 3, Graph.index_literal_count);
}

fn expectSelected(selection: anytype, route_id: usize) !void {
    const selected = switch (selection) {
        .selected => |value| value,
        else => return error.ExpectedSelected,
    };
    try std.testing.expectEqual(@as(u16, @intCast(route_id)), selected.route_id);
    try std.testing.expectEqual(@as(usize, 0), selected.captures.len);
}

fn expectAllow(selection: anytype, options: bool) !void {
    const allow = if (options) switch (selection) {
        .options => |value| value,
        else => return error.ExpectedOptions,
    } else switch (selection) {
        .method_not_allowed => |value| value,
        else => return error.ExpectedMethodNotAllowed,
    };
    var output: [32]u8 = undefined;
    try std.testing.expectEqualStrings("GET, HEAD, OPTIONS", try allow.write(&output));
}
