const std = @import("std");

pub const max_depth = 256;

pub const Stack = struct {
    names: [max_depth][]const u8 = undefined,
    seen: std.ArrayList(Seen) = .empty,
    len: usize = 0,

    pub fn deinit(self: *Stack, allocator: std.mem.Allocator) void {
        self.seen.deinit(allocator);
    }

    pub fn contains(self: *const Stack, name: []const u8) bool {
        for (self.names[0..self.len]) |entry| if (std.mem.eql(u8, entry, name)) return true;
        return false;
    }

    pub fn push(self: *Stack, name: []const u8) !void {
        if (self.len == self.names.len) return error.IncludeDepthOverflow;
        self.names[self.len] = name;
        self.len += 1;
    }

    pub fn pop(self: *Stack) void {
        self.len -= 1;
    }

    pub fn seenBefore(self: *const Stack, name: []const u8, parent: ?u32) bool {
        for (self.seen.items) |entry| {
            if (entry.parent == parent and std.mem.eql(u8, entry.name, name)) return true;
        }
        return false;
    }

    pub fn markSeen(self: *Stack, allocator: std.mem.Allocator, name: []const u8, parent: ?u32) !void {
        try self.seen.append(allocator, .{ .name = name, .parent = parent });
    }
};

const Seen = struct {
    name: []const u8,
    parent: ?u32,
};
