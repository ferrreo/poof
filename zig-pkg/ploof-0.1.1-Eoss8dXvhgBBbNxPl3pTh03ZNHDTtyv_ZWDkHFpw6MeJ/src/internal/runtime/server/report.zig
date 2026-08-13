const std = @import("std");

const lifecycle = @import("../../../lifecycle.zig");

pub fn add(
    target: *lifecycle.ShutdownIncomplete,
    source: lifecycle.ShutdownIncomplete,
) void {
    inline for (std.meta.fields(lifecycle.Remaining)) |field| {
        @field(target.remaining, field.name) = count(
            field.type,
            @field(target.remaining, field.name),
            @field(source.remaining, field.name),
        );
    }
    target.dropped_access_events = count(
        u64,
        target.dropped_access_events,
        source.dropped_access_events,
    );
}

pub fn count(comptime T: type, a: T, b: T) T {
    return std.math.add(T, a, b) catch std.math.maxInt(T);
}

test "shutdown aggregation keeps every bounded class exact" {
    var target = lifecycle.ShutdownIncomplete{
        .remaining = .{ .workers = 1, .network_operations = 2 },
        .dropped_access_events = 3,
    };
    add(&target, .{
        .remaining = .{ .workers = 4, .network_operations = 5 },
        .dropped_access_events = 6,
    });
    try std.testing.expectEqual(@as(u16, 5), target.remaining.workers);
    try std.testing.expectEqual(@as(u32, 7), target.remaining.network_operations);
    try std.testing.expectEqual(@as(u64, 9), target.dropped_access_events);
}

test "shutdown aggregation saturates valid maxima without panicking" {
    var target = lifecycle.ShutdownIncomplete{
        .remaining = .{ .workers = std.math.maxInt(u16), .requests = std.math.maxInt(u32) },
        .dropped_access_events = std.math.maxInt(u64),
    };
    add(&target, .{
        .remaining = .{ .workers = 1, .requests = 1 },
        .dropped_access_events = 1,
    });
    try std.testing.expectEqual(std.math.maxInt(u16), target.remaining.workers);
    try std.testing.expectEqual(std.math.maxInt(u32), target.remaining.requests);
    try std.testing.expectEqual(std.math.maxInt(u64), target.dropped_access_events);
}
