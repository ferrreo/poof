const std = @import("std");

pub const Error = error{InvalidRoutePlan};

const SegmentKind = enum(u8) {
    literal,
    parameter,
    catch_all,
};

pub fn materialize(
    comptime routes: anytype,
    comptime Selection: type,
    planned: anytype,
    path: []const u8,
    output: anytype,
) Error!Selection {
    return switch (planned) {
        .selected => |matched| materializeMatch(
            routes,
            Selection,
            matched,
            path,
            output,
        ),
        .redirect => |value| redirect: {
            if (value.route_id) |route_id| {
                if (route_id >= routes.len) return error.InvalidRoutePlan;
            }
            break :redirect .{ .redirect = value };
        },
        .options => |value| .{ .options = value },
        .method_not_allowed => |value| .{ .method_not_allowed = value },
        .not_implemented => .not_implemented,
        .not_found => .not_found,
    };
}

fn materializeMatch(
    comptime routes: anytype,
    comptime Selection: type,
    matched: anytype,
    path: []const u8,
    output: anytype,
) Error!Selection {
    const route_index: usize = matched.route_index;
    if (route_index >= routes.len) return error.InvalidRoutePlan;
    const metadata = routes[route_index];
    if (matched.route_id != metadata.route_id or
        matched.declared_method != metadata.method or
        matched.capture_count != metadata.capture_count or
        matched.head_uses_get and metadata.method != .get)
    {
        return error.InvalidRoutePlan;
    }
    const capture_count: usize = matched.capture_count;
    if (capture_count > output.len) return error.InvalidRoutePlan;
    const captures = output[0..capture_count];
    try replay(metadata.pattern, path, captures);
    return .{ .selected = .{
        .route_id = matched.route_id,
        .declared_method = matched.declared_method,
        .head_uses_get = matched.head_uses_get,
        .captures = captures,
    } };
}

fn replay(pattern: []const u8, path: []const u8, captures: anytype) Error!void {
    if (path.len == 0 or path[0] != '/' or path.len > std.math.maxInt(u32)) {
        return error.InvalidRoutePlan;
    }
    var pattern_start: usize = 1;
    var path_start: usize = 1;
    var captured: usize = 0;
    while (true) {
        if (pattern_start > pattern.len or path_start > path.len) {
            return error.InvalidRoutePlan;
        }
        const pattern_end = nextSlash(pattern, pattern_start);
        const path_end = nextSlash(path, path_start);
        const segment = pattern[pattern_start..pattern_end];
        const kind = segmentKind(segment);
        switch (kind) {
            .literal => if (!std.mem.eql(u8, segment, path[path_start..path_end])) {
                return error.InvalidRoutePlan;
            },
            .parameter => {
                if (path_start == path_end) return error.InvalidRoutePlan;
                try putCapture(captures, &captured, segment, path_start, path_end, false);
            },
            .catch_all => {
                try putCapture(captures, &captured, segment, path_start - 1, path.len, true);
                if (pattern_end != pattern.len or captured != captures.len) {
                    return error.InvalidRoutePlan;
                }
                return;
            },
        }
        if (pattern_end == pattern.len) {
            if (path_end != path.len or captured != captures.len) {
                return error.InvalidRoutePlan;
            }
            return;
        }
        if (path_end == path.len) return error.InvalidRoutePlan;
        pattern_start = pattern_end + 1;
        path_start = path_end + 1;
    }
}

fn putCapture(
    captures: anytype,
    captured: *usize,
    segment: []const u8,
    start: usize,
    end: usize,
    catch_all: bool,
) Error!void {
    if (captured.* >= captures.len or segment.len < 2) return error.InvalidRoutePlan;
    captures[captured.*] = .{
        .name = segment[1..],
        .start = @intCast(start),
        .end = @intCast(end),
        .kind = if (catch_all) .catch_all else .parameter,
    };
    captured.* += 1;
}

fn segmentKind(segment: []const u8) SegmentKind {
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
