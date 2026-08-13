const std = @import("std");
const Static = @import("../src/static_file.zig");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const syntax = @import("../src/internal/http1/syntax.zig");

test "static path media and range policy fuzz is deterministic and confined" {
    try std.testing.fuzz({}, fuzzPolicy, .{ .corpus = &corpus });
}

pub fn fuzzPolicy(_: void, smith: *std.testing.Smith) !void {
    var storage: [1024]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];
    const parts = splitInput(input);
    const path_first = StaticDir.selectPath(parts.raw, parts.decoded);
    const path_second = StaticDir.selectPath(parts.raw, parts.decoded);
    try expectSameSelection(path_first, path_second);
    switch (path_first) {
        .selected => |selected| try expectConfined(selected, parts.raw, parts.decoded),
        .rejected => {},
    }

    const selected_media = Static.mediaForFilename(parts.decoded);
    _ = try @import("../src/internal/http1/media_type.zig").parse(selected_media.bytes());

    const size = smith.value(u16);
    const now: i64 = 1_784_032_496;
    const validators = try Static.buildValidators(.{
        .device_major = smith.value(u16),
        .device_minor = smith.value(u16),
        .inode = smith.value(u32),
        .size = size,
        .mtime_seconds = 784_111_777,
        .mtime_nanoseconds = smith.valueRangeAtMost(u32, 0, std.time.ns_per_s - 1),
    }, now);
    const method: Static.Method = if (smith.value(bool)) .get else .head;
    const range: ?[]const u8 = if (smith.value(bool)) parts.range else null;
    const if_range: ?[]const u8 = if (smith.value(bool)) parts.if_range else null;
    const first = Static.evaluateRange(method, &validators, range, if_range);
    const second = Static.evaluateRange(method, &validators, range, if_range);
    try std.testing.expect(std.meta.eql(first, second));
    try expectRangeInvariants(first, method, size);

    const conditions = Static.Preconditions{
        .if_match = optionalPart(smith.value(bool), parts.range),
        .if_unmodified_since = optionalPart(smith.value(bool), parts.if_range),
        .if_none_match = optionalPart(smith.value(bool), parts.raw),
        .if_modified_since = optionalPart(smith.value(bool), parts.decoded),
    };
    const precondition_first = Static.evaluatePreconditions(&validators, conditions, 2026);
    const precondition_second = Static.evaluatePreconditions(&validators, conditions, 2026);
    try std.testing.expectEqual(precondition_first, precondition_second);
}

const StaticDir = Static.StaticDir.init("/public", ".", .{
    .limits = .{ .path_bytes_max = 512 },
});

const Parts = struct {
    raw: []const u8,
    decoded: []const u8,
    range: []const u8,
    if_range: []const u8,
};

fn splitInput(input: []const u8) Parts {
    var fields = [_][]const u8{ "", "", "", "" };
    var iterator = std.mem.splitScalar(u8, input, 0);
    for (&fields) |*field| field.* = iterator.next() orelse "";
    return .{
        .raw = fields[0],
        .decoded = fields[1],
        .range = fields[2],
        .if_range = fields[3],
    };
}

fn optionalPart(present: bool, value: []const u8) ?[]const u8 {
    return if (present) value else null;
}

fn expectSameSelection(first: Static.PathSelection, second: Static.PathSelection) !void {
    try std.testing.expectEqual(std.meta.activeTag(first), std.meta.activeTag(second));
    switch (first) {
        .selected => |selected| {
            try std.testing.expectEqualStrings(
                selected.relative_path,
                second.selected.relative_path,
            );
            try std.testing.expectEqual(selected.trailing_slash, second.selected.trailing_slash);
        },
        .rejected => |issue| try std.testing.expectEqual(issue, second.rejected),
    }
}

fn expectConfined(selected: Static.SelectedPath, raw: []const u8, decoded: []const u8) !void {
    const path = selected.relative_path;
    try std.testing.expect(path.len <= 512);
    try std.testing.expect(decodedMatchesRawOracle(raw, decoded));
    try std.testing.expectEqual(
        decoded.len != 0 and decoded[decoded.len - 1] == '/',
        selected.trailing_slash,
    );
    if (path.len == 0) {
        try std.testing.expect(decoded.len <= 1);
        return;
    }
    try std.testing.expect(path.ptr == decoded.ptr + 1);
    var iterator = std.mem.splitScalar(u8, path, '/');
    while (iterator.next()) |component| {
        try std.testing.expect(component.len != 0 and component[0] != '.');
        try std.testing.expect(std.mem.indexOfScalar(u8, component, 0) == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, component, '\\') == null);
    }
}

fn expectRangeInvariants(decision: Static.RangeDecision, method: Static.Method, size: u64) !void {
    switch (decision) {
        .complete => |span| {
            try std.testing.expectEqual(@as(u64, 0), span.offset);
            try std.testing.expectEqual(size, span.length);
            try std.testing.expectEqual(method == .get and size != 0, span.transfer_body);
        },
        .partial => |partial| {
            try std.testing.expectEqual(Static.Method.get, method);
            try std.testing.expect(partial.span.length != 0);
            try std.testing.expect(partial.span.offset < size);
            try std.testing.expect(partial.span.last() < size);
            try std.testing.expectEqual(method == .get, partial.span.transfer_body);
            var output: [Static.content_range_bytes_max]u8 = undefined;
            const written = try partial.content_range.write(&output);
            try std.testing.expect(std.mem.startsWith(u8, written, "bytes "));
        },
        .unsatisfiable => |content_range| {
            var output: [Static.content_range_bytes_max]u8 = undefined;
            const written = try content_range.write(&output);
            var expected: [Static.content_range_bytes_max]u8 = undefined;
            const exact = try std.fmt.bufPrint(&expected, "bytes */{d}", .{size});
            try std.testing.expectEqualStrings(exact, written);
        },
    }
}

fn decodedMatchesRawOracle(raw: []const u8, decoded: []const u8) bool {
    var raw_index: usize = 0;
    var decoded_index: usize = 0;
    while (raw_index < raw.len and decoded_index < decoded.len) {
        const byte = if (raw[raw_index] == '%' and raw.len - raw_index >= 3) blk: {
            const high = hex(raw[raw_index + 1]);
            const low = hex(raw[raw_index + 2]);
            if (high >= 16 or low >= 16) return false;
            raw_index += 3;
            break :blk high << 4 | low;
        } else blk: {
            defer raw_index += 1;
            break :blk raw[raw_index];
        };
        if (decoded[decoded_index] != byte) return false;
        decoded_index += 1;
    }
    return raw_index == raw.len and decoded_index == decoded.len;
}

fn hex(byte: u8) u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => 16,
    };
}

fn smithCase(comptime value: []const u8) [value.len + 4]u8 {
    return fuzz_support.smithInput(value);
}

const corpus = struct {
    const empty = smithCase("");
    const ordinary = smithCase("/css/site.css\x00/css/site.css\x00bytes=0-9\x00");
    const traversal = smithCase("/%2e%2e/secret\x00/../secret\x00bytes=-10\x00");
    const separator = smithCase("/a%2Fb\x00/a/b\x00bytes=0-1,3-4\x00W/\"x\"");
    const nul = smithCase("/a%00b\x00/a\x00b\x00bytes=99-\x00Sun, 06 Nov 1994 08:49:37 GMT");
    const values = [_][]const u8{ &empty, &ordinary, &traversal, &separator, &nul };
}.values;

test "fuzz corpus includes exact traversal and range boundaries" {
    try std.testing.expect(corpus.len >= 5);
    try std.testing.expect(syntax.isFieldValue("bytes=0-9"));
}
