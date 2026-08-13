const std = @import("std");
const hook = @import("parse_hook.zig");
const storage = @import("decode_storage.zig");
const types = @import("types.zig");

pub fn minimumParseMemory(comptime T: type) usize {
    const plan_bytes = multiply(minimumPlans(T, .{}), @sizeOf(storage.Plan));
    const root_offset = alignForward(plan_bytes, @alignOf(T));
    return add(root_offset, @sizeOf(T));
}

pub fn parseMemoryAlignment(comptime T: type) usize {
    return maximumAlignment(T, .{});
}

fn minimumPlans(comptime T: type, comptime seen: anytype) usize {
    inline for (seen) |Seen| if (T == Seen) return 0;
    if (T == types.Value or T == types.Number or hook.has(T)) return 0;
    const next = seen ++ .{T};
    return switch (@typeInfo(T)) {
        .optional => 0,
        .array => |info| if (info.child == u8)
            0
        else
            multiply(info.len, minimumPlans(info.child, next)),
        .vector => |info| multiply(info.len, minimumPlans(info.child, next)),
        .pointer => |info| switch (info.size) {
            .one => minimumPlans(info.child, next),
            .slice => @intFromBool(info.child != u8),
            .many, .c => 0,
        },
        .@"struct" => |info| minimumStructPlans(info, next),
        .@"union" => |info| minimumUnionPlans(info, next),
        else => 0,
    };
}

fn minimumStructPlans(
    comptime info: std.builtin.Type.Struct,
    comptime seen: anytype,
) usize {
    var total: usize = 0;
    inline for (info.fields) |field| {
        if (!info.is_tuple and field.default_value_ptr != null) continue;
        total = add(total, minimumPlans(field.type, seen));
    }
    return total;
}

fn minimumUnionPlans(
    comptime info: std.builtin.Type.Union,
    comptime seen: anytype,
) usize {
    if (info.fields.len == 0) return 0;
    var result = std.math.maxInt(usize);
    inline for (info.fields) |field| {
        result = @min(result, minimumPlans(field.type, seen));
    }
    return result;
}

fn maximumAlignment(comptime T: type, comptime seen: anytype) usize {
    inline for (seen) |Seen| if (T == Seen) return @alignOf(T);
    if (hook.has(T)) return @alignOf(T);
    const next = seen ++ .{T};
    var result = @alignOf(T);
    switch (@typeInfo(T)) {
        .optional => |info| result = @max(result, maximumAlignment(info.child, next)),
        .array => |info| result = @max(result, maximumAlignment(info.child, next)),
        .vector => |info| result = @max(result, maximumAlignment(info.child, next)),
        .pointer => |info| result = @max(result, maximumAlignment(info.child, next)),
        .@"struct" => |info| inline for (info.fields) |field| {
            result = @max(result, maximumAlignment(field.type, next));
        },
        .@"union" => |info| inline for (info.fields) |field| {
            result = @max(result, maximumAlignment(field.type, next));
        },
        else => {},
    }
    return result;
}

fn add(a: usize, b: usize) usize {
    return std.math.add(usize, a, b) catch std.math.maxInt(usize);
}

fn multiply(a: usize, b: usize) usize {
    return std.math.mul(usize, a, b) catch std.math.maxInt(usize);
}

fn alignForward(offset: usize, alignment: usize) usize {
    if (offset > std.math.maxInt(usize) - (alignment - 1)) {
        return std.math.maxInt(usize);
    }
    return std.mem.alignForward(usize, offset, alignment);
}

test "minimum parse memory includes plans and aligned root" {
    const Slice = []const u64;
    const plan_bytes = @sizeOf(storage.Plan);
    const slice_minimum = std.mem.alignForward(usize, plan_bytes, @alignOf(Slice)) +
        @sizeOf(Slice);
    try std.testing.expectEqual(slice_minimum, minimumParseMemory(Slice));

    const OverAligned = struct {
        items: []const u64,
        marker: u8 align(64),
    };
    const aligned_minimum = std.mem.alignForward(
        usize,
        plan_bytes,
        @alignOf(OverAligned),
    ) + @sizeOf(OverAligned);
    try std.testing.expectEqual(aligned_minimum, minimumParseMemory(OverAligned));

    const Backed = *struct { marker: u8 align(64) };
    try std.testing.expectEqual(@sizeOf(Backed), minimumParseMemory(Backed));
}

test {
    std.testing.refAllDecls(@This());
}
