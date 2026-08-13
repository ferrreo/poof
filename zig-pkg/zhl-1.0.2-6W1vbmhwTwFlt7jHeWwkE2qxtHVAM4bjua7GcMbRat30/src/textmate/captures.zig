const std = @import("std");
const engine = @import("../runtime/engine.zig");
const style = @import("../theme/style.zig");
const token = @import("../runtime/token.zig");

pub const CaptureEntry = struct {
    slot: u16,
    style_id: style.StyleId,
};

pub const CapturePlan = struct {
    allocator: std.mem.Allocator,
    entries: []CaptureEntry,

    pub fn deinit(self: *CapturePlan) void {
        self.allocator.free(self.entries);
    }
};

pub fn compile(allocator: std.mem.Allocator, value: std.json.Value) !CapturePlan {
    var entries = std.ArrayList(CaptureEntry).empty;
    errdefer entries.deinit(allocator);
    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                const slot = std.fmt.parseInt(u16, entry.key_ptr.*, 10) catch continue;
                try appendCapture(allocator, &entries, slot, entry.value_ptr.*);
            }
        },
        .array => |array| for (array.items, 0..) |item, slot| {
            if (slot > std.math.maxInt(u16)) break;
            try appendCapture(allocator, &entries, @intCast(slot), item);
        },
        else => return error.MalformedGrammar,
    }
    return .{ .allocator = allocator, .entries = try entries.toOwnedSlice(allocator) };
}

fn appendCapture(allocator: std.mem.Allocator, entries: *std.ArrayList(CaptureEntry), slot: u16, value: std.json.Value) !void {
    const capture = switch (value) {
        .object => |capture_object| capture_object,
        else => return,
    };
    const style_id = captureStyle(capture) orelse return;
    try entries.append(allocator, .{ .slot = slot, .style_id = style_id });
}

fn captureStyle(capture: std.json.ObjectMap) ?style.StyleId {
    if (capture.get("name")) |name_value| {
        if (name_value == .string) return style.styleFromScope(name_value.string);
    }
    return nestedStyle(capture.get("patterns") orelse return null, 0);
}

fn nestedStyle(value: std.json.Value, depth: u8) ?style.StyleId {
    if (depth > 8) return null;
    var best: style.StyleId = .plain;
    switch (value) {
        .object => |object| {
            if (object.get("name")) |name_value| {
                if (name_value == .string) {
                    const style_id = style.styleFromScope(name_value.string);
                    best = betterStyle(best, style_id);
                }
            }
            if (object.get("captures")) |captures_value| {
                const captures = switch (captures_value) {
                    .object => |captures| captures,
                    else => return if (best == .plain) null else best,
                };
                var it = captures.iterator();
                while (it.next()) |entry| {
                    if (nestedStyle(entry.value_ptr.*, depth + 1)) |style_id| best = betterStyle(best, style_id);
                }
            }
            if (object.get("patterns")) |patterns_value| {
                if (nestedStyle(patterns_value, depth + 1)) |style_id| best = betterStyle(best, style_id);
            }
        },
        .array => |array| for (array.items) |item| {
            if (nestedStyle(item, depth + 1)) |style_id| best = betterStyle(best, style_id);
        },
        else => {},
    }
    return if (best == .plain) null else best;
}

fn betterStyle(a: style.StyleId, b: style.StyleId) style.StyleId {
    return if (stylePriority(b) > stylePriority(a)) b else a;
}

fn stylePriority(id: style.StyleId) u8 {
    return switch (id) {
        .plain => 0,
        .punctuation => 1,
        .operator => 2,
        .keyword => 3,
        .string, .multiline_string => 4,
        .builtin, .function, .type_name, .parameter, .field, .label => 5,
        .char, .escape, .format_placeholder => 6,
        .number_integer, .number_float => 7,
        .comment, .doc_comment, .container_doc_comment => 8,
        .invalid => 1,
    };
}

pub fn emit(
    plan: CapturePlan,
    slots: []const engine.CaptureSlot,
    sink: anytype,
) engine.HighlightError!usize {
    return emitEntries(plan.entries, slots, sink);
}

pub fn emitEntries(
    entries: []const CaptureEntry,
    slots: []const engine.CaptureSlot,
    sink: anytype,
) engine.HighlightError!usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (entry.slot >= slots.len) return error.RegexCaptureOverflow;
        const slot = slots[entry.slot];
        if (slot.end <= slot.start) continue;
        try sink.emit(token.Token{
            .start = slot.start,
            .end = slot.end,
            .style_id = entry.style_id,
            .scope_stack_id = style.scopeStackForStyle(entry.style_id),
        });
        count += 1;
    }
    return count;
}

test "TextMate capture plans compile numeric captures" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "0": {"name": "string.quoted.test"},
        \\  "1": {"name": "constant.character.escape.test"}
        \\}
    , .{});
    defer parsed.deinit();
    var plan = try compile(std.testing.allocator, parsed.value);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 2), plan.entries.len);
    try std.testing.expectEqual(style.StyleId.string, plan.entries[0].style_id);
    try std.testing.expectEqual(style.StyleId.escape, plan.entries[1].style_id);
}

test "TextMate capture plans use nested pattern style" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "2": {"patterns": [
        \\    {"match": "[^.\\s]+", "name": "entity.name.section.toml"}
        \\  ]}
        \\}
    , .{});
    defer parsed.deinit();
    var plan = try compile(std.testing.allocator, parsed.value);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 1), plan.entries.len);
    try std.testing.expectEqual(@as(u16, 2), plan.entries[0].slot);
    try std.testing.expectEqual(style.StyleId.field, plan.entries[0].style_id);
}

test "TextMate nested capture style prefers numeric over unit keyword" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "0": {"patterns": [
        \\    {"match": "0x", "name": "keyword.other.unit.hexadecimal.c"},
        \\    {"match": "\\d+", "name": "constant.numeric.decimal.c"}
        \\  ]}
        \\}
    , .{});
    defer parsed.deinit();
    var plan = try compile(std.testing.allocator, parsed.value);
    defer plan.deinit();

    try std.testing.expectEqual(style.StyleId.number_integer, plan.entries[0].style_id);
}

test "TextMate capture plans ignore non-numeric keys" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "name": "ignored",
        \\  "1": {"name": "keyword.control.test"}
        \\}
    , .{});
    defer parsed.deinit();
    var plan = try compile(std.testing.allocator, parsed.value);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 1), plan.entries.len);
    try std.testing.expectEqual(@as(u16, 1), plan.entries[0].slot);
    try std.testing.expectEqual(style.StyleId.keyword, plan.entries[0].style_id);
}

test "TextMate capture plans accept array captures" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\[
        \\  {"name": "variable.parameter.test"},
        \\  {"name": "punctuation.definition.string.begin.test"}
        \\]
    , .{});
    defer parsed.deinit();
    var plan = try compile(std.testing.allocator, parsed.value);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 2), plan.entries.len);
    try std.testing.expectEqual(@as(u16, 0), plan.entries[0].slot);
    try std.testing.expectEqual(style.StyleId.parameter, plan.entries[0].style_id);
    try std.testing.expectEqual(@as(u16, 1), plan.entries[1].slot);
    try std.testing.expectEqual(style.StyleId.punctuation, plan.entries[1].style_id);
}

test "TextMate capture emission uses caller-owned slots" {
    var sink = @import("../runtime/sinks.zig").TokenBuffer(4).init();
    var plan = CapturePlan{
        .allocator = std.testing.allocator,
        .entries = try std.testing.allocator.dupe(CaptureEntry, &.{
            .{ .slot = 1, .style_id = .char },
        }),
    };
    defer plan.deinit();
    const slots = [_]engine.CaptureSlot{
        .{ .start = 0, .end = 0 },
        .{ .start = 3, .end = 5 },
    };

    try std.testing.expectEqual(@as(usize, 1), try emit(plan, &slots, &sink));
    try std.testing.expectEqual(style.StyleId.char, sink.tokens[0].style_id);
    try std.testing.expectEqual(style.ScopeStackId.char, sink.tokens[0].scope_stack_id);
    try std.testing.expectEqual(@as(u32, 3), sink.tokens[0].start);
    try std.testing.expectEqual(@as(u32, 5), sink.tokens[0].end);
}
