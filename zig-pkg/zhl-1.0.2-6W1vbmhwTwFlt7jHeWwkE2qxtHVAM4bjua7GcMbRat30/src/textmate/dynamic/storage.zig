const std = @import("std");
const engine = @import("../../runtime/engine.zig");

pub const max_bytes = 32;

pub const Storage = struct {
    len: u8 = 0,
    bytes: [max_bytes]u8 = [_]u8{0} ** max_bytes,
    guard_len: u8 = 0,
    guard_bytes: [max_bytes]u8 = [_]u8{0} ** max_bytes,
};

pub fn store(pattern: anytype, captures: []const engine.CaptureSlot, line: []const u8) engine.HighlightError!Storage {
    const capture = try firstCapture(pattern, captures);
    if (capture.end <= capture.start) return .{};
    var out = Storage{};
    try appendCapture(&out, .{ .start = @as(usize, @intCast(capture.start)), .end = @as(usize, @intCast(capture.end)) }, line);
    if (pattern.concat_slot != 0) {
        if (pattern.concat_slot >= captures.len) return error.RegexCaptureOverflow;
        if (captures[pattern.concat_slot].end > captures[pattern.concat_slot].start) {
            try appendCapture(&out, .{ .start = @as(usize, @intCast(captures[pattern.concat_slot].start)), .end = @as(usize, @intCast(captures[pattern.concat_slot].end)) }, line);
        }
    }
    if (pattern.guard_slot != 0) {
        if (pattern.guard_slot >= captures.len) return error.RegexCaptureOverflow;
        if (captures[pattern.guard_slot].end > captures[pattern.guard_slot].start) {
            try appendGuardCapture(&out, .{ .start = @as(usize, @intCast(captures[pattern.guard_slot].start)), .end = @as(usize, @intCast(captures[pattern.guard_slot].end)) }, line);
        }
    }
    return out;
}

pub fn storeVm(pattern: anytype, captures: anytype, line: []const u8) engine.HighlightError!?Storage {
    if (pattern.slot >= captures.len or !captures[pattern.slot].set) return null;
    var out = Storage{};
    try appendCapture(&out, captures[pattern.slot], line);
    if (pattern.concat_slot != 0 and pattern.concat_slot >= captures.len) return error.RegexCaptureOverflow;
    if (pattern.concat_slot != 0 and captures[pattern.concat_slot].set) try appendCapture(&out, captures[pattern.concat_slot], line);
    if (pattern.guard_slot != 0 and pattern.guard_slot >= captures.len) return error.RegexCaptureOverflow;
    if (pattern.guard_slot != 0 and captures[pattern.guard_slot].set) try appendGuardCapture(&out, captures[pattern.guard_slot], line);
    return out;
}

pub fn matchRepeated(storage: Storage, repeat: u8, line: []const u8, start: usize) ?usize {
    const marker = storage.bytes[0..storage.len];
    const total = marker.len * @as(usize, repeat);
    if (start + total > line.len) return null;
    var cursor = start;
    var n: usize = 0;
    while (n < repeat) : (n += 1) {
        if (!std.mem.eql(u8, marker, line[cursor..][0..marker.len])) return null;
        cursor += marker.len;
    }
    return cursor;
}

pub fn serialize(storage: Storage, out: []u8) engine.HighlightError![]const u8 {
    const len: usize = storage.len;
    const guard_len: usize = storage.guard_len;
    const total = 2 + len + guard_len;
    if (total > out.len) return error.DynamicCaptureOverflow;
    out[0] = storage.len;
    @memcpy(out[1..][0..len], storage.bytes[0..len]);
    out[1 + len] = storage.guard_len;
    @memcpy(out[2 + len ..][0..guard_len], storage.guard_bytes[0..guard_len]);
    return out[0..total];
}

pub fn deserialize(bytes: []const u8) ?Storage {
    if (bytes.len < 2) return null;
    const len: usize = bytes[0];
    if (len > max_bytes or 1 + len >= bytes.len) return null;
    const guard_len: usize = bytes[1 + len];
    if (guard_len > max_bytes or 2 + len + guard_len != bytes.len) return null;
    var storage = Storage{ .len = @intCast(len), .guard_len = @intCast(guard_len) };
    @memcpy(storage.bytes[0..len], bytes[1..][0..len]);
    @memcpy(storage.guard_bytes[0..guard_len], bytes[2 + len ..][0..guard_len]);
    return storage;
}

fn firstCapture(pattern: anytype, captures: []const engine.CaptureSlot) engine.HighlightError!engine.CaptureSlot {
    if (pattern.slot >= captures.len or (pattern.alt_slot != 0 and pattern.alt_slot >= captures.len)) return error.RegexCaptureOverflow;
    return if (captures[pattern.slot].end > captures[pattern.slot].start or pattern.alt_slot == 0) captures[pattern.slot] else captures[pattern.alt_slot];
}

fn appendCapture(out: *Storage, capture: anytype, line: []const u8) engine.HighlightError!void {
    const bytes = line[capture.start..capture.end];
    if (@as(usize, out.len) + bytes.len > max_bytes) return error.DynamicCaptureOverflow;
    @memcpy(out.bytes[out.len..][0..bytes.len], bytes);
    out.len += @intCast(bytes.len);
}

fn appendGuardCapture(out: *Storage, capture: anytype, line: []const u8) engine.HighlightError!void {
    const bytes = line[capture.start..capture.end];
    if (bytes.len > max_bytes) return error.DynamicCaptureOverflow;
    @memcpy(out.guard_bytes[0..bytes.len], bytes);
    out.guard_len = @intCast(bytes.len);
}
