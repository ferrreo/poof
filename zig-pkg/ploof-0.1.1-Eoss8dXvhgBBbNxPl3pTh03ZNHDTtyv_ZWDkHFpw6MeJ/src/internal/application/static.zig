const std = @import("std");

pub fn count(comptime descriptors: anytype) usize {
    var total: usize = 0;
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => {},
        .static_dir, .static_file => total += 1,
        .group => total += count(descriptor.children),
    };
    return total;
}

pub fn rootCount(comptime descriptors: anytype) usize {
    var scratch: [count(descriptors)][]const u8 = undefined;
    var used: usize = 0;
    collectRoots(descriptors, &scratch, &used);
    return used;
}

pub fn roots(comptime descriptors: anytype) [rootCount(descriptors)][]const u8 {
    var scratch: [count(descriptors)][]const u8 = undefined;
    var used: usize = 0;
    collectRoots(descriptors, &scratch, &used);
    var result: [rootCount(descriptors)][]const u8 = undefined;
    for (0..result.len) |index| result[index] = scratch[index];
    return result;
}

pub fn routeRootIndex(comptime descriptors: anytype, route_id: u16) ?u16 {
    const configured_roots = comptime roots(descriptors);
    return findRouteRoot(descriptors, route_id, 0, configured_roots);
}

pub fn maximumPathBytes(comptime descriptors: anytype) u16 {
    var maximum: u16 = 0;
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => {},
        .static_dir, .static_file => maximum = @max(
            maximum,
            descriptor.limits_profile.path_bytes_max,
        ),
        .group => maximum = @max(maximum, maximumPathBytes(descriptor.children)),
    };
    return maximum;
}

fn collectRoots(comptime descriptors: anytype, result: anytype, used: *usize) void {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => {},
        .static_dir, .static_file => {
            if (!contains(result, used.*, descriptor.root_path)) {
                result[used.*] = descriptor.root_path;
                used.* += 1;
            }
        },
        .group => collectRoots(descriptor.children, result, used),
    };
}

fn contains(paths: anytype, used: usize, candidate: []const u8) bool {
    for (paths[0..used]) |path| {
        if (std.mem.eql(u8, path, candidate)) return true;
    }
    return false;
}

fn findRouteRoot(
    comptime descriptors: anytype,
    route_id: u16,
    comptime first_route_id: usize,
    comptime configured_roots: anytype,
) ?u16 {
    comptime var current = first_route_id;
    inline for (descriptors) |descriptor| {
        const first = comptime current;
        const route_count = comptime leafCount(descriptor);
        comptime current += route_count;
        switch (descriptor.kind) {
            .route => {},
            .static_dir, .static_file => if (route_id == first) {
                inline for (configured_roots, 0..) |root, index| {
                    if (std.mem.eql(u8, root, descriptor.root_path)) return @intCast(index);
                }
                unreachable;
            },
            .group => if (route_id >= first and route_id < first + route_count) {
                return findRouteRoot(
                    descriptor.children,
                    route_id,
                    first,
                    configured_roots,
                );
            },
        }
    }
    return null;
}

fn leafCount(comptime descriptor: anytype) usize {
    return switch (descriptor.kind) {
        .route, .static_dir, .static_file => 1,
        .group => blk: {
            var total: usize = 0;
            inline for (descriptor.children) |child| total += leafCount(child);
            break :blk total;
        },
    };
}

test "static catalog deduplicates roots and retains route ids" {
    const route = @import("../../route.zig");
    const Static = @import("../../static_file.zig");
    const descriptors = comptime .{
        route.get("/health", struct {
            fn handle(_: anytype) void {}
        }.handle),
        Static.StaticDir.init("/public", "/srv/www", .{}),
        route.group("/v1", .{}, .{
            Static.StaticFile.init("/robots.txt", "/srv/www", "robots.txt", .{}),
            Static.StaticFile.init("/feed", "/srv/feed", "feed.xml", .{}),
        }),
    };
    try std.testing.expectEqual(@as(usize, 3), count(descriptors));
    try std.testing.expectEqual(@as(usize, 2), rootCount(descriptors));
    try std.testing.expectEqualStrings("/srv/www", roots(descriptors)[0]);
    try std.testing.expectEqual(@as(?u16, 0), routeRootIndex(descriptors, 1));
    try std.testing.expectEqual(@as(?u16, 0), routeRootIndex(descriptors, 2));
    try std.testing.expectEqual(@as(?u16, 1), routeRootIndex(descriptors, 3));
    try std.testing.expectEqual(@as(?u16, null), routeRootIndex(descriptors, 0));
}
