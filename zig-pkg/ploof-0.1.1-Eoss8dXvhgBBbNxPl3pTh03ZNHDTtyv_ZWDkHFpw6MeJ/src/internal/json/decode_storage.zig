const std = @import("std");

pub const ArenaError = error{
    PlanMismatch,
    WorkspaceTooSmall,
};

pub const PlanKind = enum(u8) {
    array,
    object,
};

pub const Plan = struct {
    count: u32 = 0,
    kind: PlanKind,
};

pub const Arena = struct {
    bytes: []u8,
    used: usize = 0,
    peak: usize = 0,

    pub fn init(bytes: []u8) Arena {
        return .{ .bytes = bytes };
    }

    pub fn allocate(self: *Arena, comptime T: type, count: usize) ArenaError![]T {
        if (@sizeOf(T) == 0) {
            const pointer: [*]T = @ptrFromInt(@alignOf(T));
            return pointer[0..count];
        }
        const byte_count = std.math.mul(usize, @sizeOf(T), count) catch {
            return error.WorkspaceTooSmall;
        };
        const base = @intFromPtr(self.bytes.ptr);
        const current = std.math.add(usize, base, self.used) catch {
            return error.WorkspaceTooSmall;
        };
        const aligned = std.mem.alignForward(usize, current, @alignOf(T));
        const start = aligned - base;
        if (start > self.bytes.len or byte_count > self.bytes.len - start) {
            return error.WorkspaceTooSmall;
        }
        const pointer: [*]T = @ptrCast(@alignCast(self.bytes.ptr + start));
        self.used = start + byte_count;
        self.peak = @max(self.peak, self.used);
        return pointer[0..count];
    }

    pub fn remaining(self: *Arena) []u8 {
        if (self.used > self.bytes.len) return self.bytes[self.bytes.len..];
        return self.bytes[self.used..];
    }

    pub fn observe(self: *Arena, byte_count: usize) error{WorkspaceTooSmall}!void {
        const end = std.math.add(usize, self.used, byte_count) catch {
            return error.WorkspaceTooSmall;
        };
        if (end > self.bytes.len) return error.WorkspaceTooSmall;
        self.peak = @max(self.peak, end);
    }

    pub fn retain(self: *Arena, bytes: []const u8) ArenaError![]const u8 {
        try self.observe(bytes.len);
        if (bytes.len != 0 and bytes.ptr != self.bytes.ptr + self.used) {
            return error.PlanMismatch;
        }
        self.used += bytes.len;
        return self.bytes[self.used - bytes.len .. self.used];
    }
};

pub const Cursor = struct {
    plans: []const Plan,
    index: usize = 0,

    pub fn take(self: *Cursor, kind: PlanKind) error{PlanMismatch}!usize {
        if (self.index >= self.plans.len) return error.PlanMismatch;
        const plan = self.plans[self.index];
        if (plan.kind != kind) return error.PlanMismatch;
        self.index += 1;
        return plan.count;
    }

    pub fn finish(self: Cursor) error{PlanMismatch}!void {
        if (self.index != self.plans.len) return error.PlanMismatch;
    }
};

test {
    std.testing.refAllDecls(@This());
}
