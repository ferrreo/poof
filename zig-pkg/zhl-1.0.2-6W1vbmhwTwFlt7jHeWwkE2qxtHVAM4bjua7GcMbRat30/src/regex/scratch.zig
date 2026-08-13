const std = @import("std");

pub const VmFrame = struct {
    atom_i: usize,
    pos: usize,
};

pub fn VmScratch(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        frames: [capacity]VmFrame = undefined,
        len: usize = 0,
        steps: usize = 0,
        step_limit: usize = std.math.maxInt(usize),

        pub fn init() Self {
            return .{};
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
            self.steps = 0;
        }

        pub fn tick(self: *Self) error{RegexStepLimitExceeded}!void {
            self.steps += 1;
            if (self.steps > self.step_limit) return error.RegexStepLimitExceeded;
        }

        pub fn push(self: *Self, frame: VmFrame) error{RegexVmStackOverflow}!void {
            if (self.len == capacity) return error.RegexVmStackOverflow;
            self.frames[self.len] = frame;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?VmFrame {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.frames[self.len];
        }
    };
}

pub fn VmScratchView(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        frames: *[capacity]VmFrame,
        len: usize = 0,
        steps: usize = 0,
        step_limit: usize = std.math.maxInt(usize),

        pub fn init(frames: *[capacity]VmFrame) Self {
            return .{ .frames = frames };
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
            self.steps = 0;
        }

        pub fn tick(self: *Self) error{RegexStepLimitExceeded}!void {
            self.steps += 1;
            if (self.steps > self.step_limit) return error.RegexStepLimitExceeded;
        }

        pub fn push(self: *Self, frame: VmFrame) error{RegexVmStackOverflow}!void {
            if (self.len == capacity) return error.RegexVmStackOverflow;
            self.frames[self.len] = frame;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?VmFrame {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.frames[self.len];
        }
    };
}
