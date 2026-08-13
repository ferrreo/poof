const std = @import("std");
const builtin = @import("builtin");

var pause_requested = std.atomic.Value(bool).init(false);
var paused = std.atomic.Value(bool).init(false);

pub fn pause() void {
    if (comptime !builtin.is_test) return;
    if (!pause_requested.load(.acquire)) return;
    paused.store(true, .release);
    while (pause_requested.load(.acquire)) std.Thread.yield() catch {};
    paused.store(false, .release);
}

pub const TestAccess = if (builtin.is_test) struct {
    pub fn pauseClaim(enabled: bool) void {
        pause_requested.store(enabled, .release);
    }

    pub fn claimPaused() bool {
        return paused.load(.acquire);
    }
} else struct {};
