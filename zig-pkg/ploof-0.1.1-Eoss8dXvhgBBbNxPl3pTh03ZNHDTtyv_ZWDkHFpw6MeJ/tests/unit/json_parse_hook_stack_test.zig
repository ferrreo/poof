const builtin = @import("builtin");
const std = @import("std");
const body = @import("../../src/body.zig");
const decode = @import("../../src/internal/json/decode.zig");
const json = @import("../../src/json.zig");
const validate = @import("../../src/internal/json/validate.zig");

const hash_key = [_]u8{
    0x8e, 0x31, 0x77, 0x04, 0x52, 0xae, 0xd9, 0x63,
    0xc4, 0x1b, 0xf0, 0x29, 0x95, 0x46, 0xba, 0x0d,
};

threadlocal var chain_remaining: u16 = 0;

const Chain = struct {
    pub fn jsonParse(parser: anytype) json.ParseError!@This() {
        if (chain_remaining == 0) return error.InvalidValue;
        if (chain_remaining == 1) {
            chain_remaining = 0;
            _ = try parser.parse(?u8);
            return .{};
        }
        chain_remaining -= 1;
        return parser.parse(@This());
    }
};

const CursorChain = struct {
    count: u16,

    pub fn jsonParse(parser: anytype) json.ParseError!@This() {
        const value = try parser.cursor();
        if (value.kind() == .null) return .{ .count = 1 };
        const array = try value.array();
        if (array.len() != 1) return error.InvalidValue;
        const child = try array.at(0).?.parse(@This());
        return .{ .count = std.math.add(u16, child.count, 1) catch return error.Overflow };
    }
};

fn NestedArray(comptime depth: u16) type {
    if (depth == 0) return bool;
    return [1]NestedArray(depth - 1);
}

fn ConversionHook(comptime T: type) type {
    return struct {
        value: T,

        pub fn jsonParse(parser: anytype) json.ParseError!@This() {
            return .{ .value = try parser.parse(T) };
        }
    };
}

const Swallowing = struct {
    pub fn jsonParse(parser: anytype) json.ParseError!@This() {
        _ = parser.parse(@This()) catch {};
        return .{};
    }
};

const Outcome = struct {
    cursor_document: []const u8,
    conversion_at_document: []const u8,
    conversion_over_document: []const u8,
    at_workspace: []align(validate.scratch_alignment) u8,
    over_workspace: []align(validate.scratch_alignment) u8,
    at_error: ?decode.Error = null,
    at_complete: bool = false,
    over_error: ?decode.Error = null,
    over_returned: bool = false,
    cursor_error: ?decode.Error = null,
    cursor_count: u16 = 0,
    conversion_at_error: ?decode.Error = null,
    conversion_at_returned: bool = false,
    conversion_over_error: ?decode.Error = null,
    conversion_over_returned: bool = false,
    swallowed_error: ?decode.Error = null,
    swallowed_returned: bool = false,

    fn run(self: *Outcome) void {
        self.decodeAtLimit();
        self.decodeOverLimit();
        self.decodeCursorAtLimit();
        self.decodeConversionAtLimit();
        self.decodeConversionOverLimit();
        self.decodeSwallowed();
    }

    fn decodeAtLimit(self: *Outcome) void {
        chain_remaining = json.hook_depth_hard_max;
        const chunks = [_]body.Chunk{body.Chunk.init("null")};
        const input = body.Bytes.init(&chunks) catch {
            self.at_error = error.CountOverflow;
            return;
        };
        const result = decode.decode(Chain, input, self.at_workspace, options()) catch |problem| {
            self.at_error = problem;
            return;
        };
        _ = result;
        self.at_complete = chain_remaining == 0;
    }

    fn decodeOverLimit(self: *Outcome) void {
        chain_remaining = json.hook_depth_hard_max + 1;
        const chunks = [_]body.Chunk{body.Chunk.init("null")};
        const input = body.Bytes.init(&chunks) catch {
            self.over_error = error.CountOverflow;
            return;
        };
        _ = decode.decode(Chain, input, self.over_workspace, options()) catch |problem| {
            self.over_error = problem;
            return;
        };
        self.over_returned = true;
    }

    fn decodeCursorAtLimit(self: *Outcome) void {
        const chunks = [_]body.Chunk{body.Chunk.init(self.cursor_document)};
        const input = body.Bytes.init(&chunks) catch {
            self.cursor_error = error.CountOverflow;
            return;
        };
        const result = decode.decode(
            CursorChain,
            input,
            self.at_workspace,
            options(),
        ) catch |problem| {
            self.cursor_error = problem;
            return;
        };
        self.cursor_count = result.value.count;
    }

    fn decodeConversionAtLimit(self: *Outcome) void {
        const T = NestedArray(json.hook_depth_hard_max - 1);
        const chunks = [_]body.Chunk{body.Chunk.init(self.conversion_at_document)};
        const input = body.Bytes.init(&chunks) catch {
            self.conversion_at_error = error.CountOverflow;
            return;
        };
        _ = decode.decode(
            ConversionHook(T),
            input,
            self.at_workspace,
            options(),
        ) catch |problem| {
            self.conversion_at_error = problem;
            return;
        };
        self.conversion_at_returned = true;
    }

    fn decodeConversionOverLimit(self: *Outcome) void {
        const T = NestedArray(json.hook_depth_hard_max);
        const chunks = [_]body.Chunk{body.Chunk.init(self.conversion_over_document)};
        const input = body.Bytes.init(&chunks) catch {
            self.conversion_over_error = error.CountOverflow;
            return;
        };
        _ = decode.decode(
            ConversionHook(T),
            input,
            self.over_workspace,
            options(),
        ) catch |problem| {
            self.conversion_over_error = problem;
            return;
        };
        self.conversion_over_returned = true;
    }

    fn decodeSwallowed(self: *Outcome) void {
        const chunks = [_]body.Chunk{body.Chunk.init("null")};
        const input = body.Bytes.init(&chunks) catch {
            self.swallowed_error = error.CountOverflow;
            return;
        };
        _ = decode.decode(Swallowing, input, self.over_workspace, options()) catch |problem| {
            self.swallowed_error = problem;
            return;
        };
        self.swallowed_returned = true;
    }

    fn options() decode.Options {
        return .{ .hash_key = hash_key, .depth_max = json.depth_hard_max };
    }
};

test "jsonParse hook recursion is bounded on the minimum worker stack" {
    const depth: usize = json.hook_depth_hard_max;
    var cursor_document: [depth * 2 + 4]u8 = undefined;
    @memset(cursor_document[0..depth], '[');
    @memcpy(cursor_document[depth .. depth + 4], "null");
    @memset(cursor_document[depth + 4 ..], ']');
    var conversion_document: [depth * 2 + 4]u8 = undefined;
    @memset(conversion_document[0..depth], '[');
    @memcpy(conversion_document[depth .. depth + 4], "true");
    @memset(conversion_document[depth + 4 ..], ']');
    var at_workspace: [64 * 1024]u8 align(validate.scratch_alignment) = undefined;
    var over_workspace: [64 * 1024]u8 align(validate.scratch_alignment) = undefined;
    var outcome = Outcome{
        .cursor_document = cursor_document[1 .. cursor_document.len - 1],
        .conversion_at_document = conversion_document[1 .. conversion_document.len - 1],
        .conversion_over_document = &conversion_document,
        .at_workspace = &at_workspace,
        .over_workspace = &over_workspace,
    };
    const stack_size = if (builtin.sanitize_thread)
        std.Thread.SpawnConfig.default_stack_size
    else
        64 * 1024;
    const thread = try std.Thread.spawn(.{ .stack_size = stack_size }, Outcome.run, .{&outcome});
    thread.join();
    try std.testing.expect(outcome.at_error == null);
    try std.testing.expect(outcome.at_complete);
    try std.testing.expect(!outcome.over_returned);
    try std.testing.expectEqual(error.DepthLimitExceeded, outcome.over_error.?);
    try std.testing.expect(outcome.cursor_error == null);
    try std.testing.expectEqual(json.hook_depth_hard_max, outcome.cursor_count);
    try std.testing.expectEqual(@as(?decode.Error, null), outcome.conversion_at_error);
    try std.testing.expect(outcome.conversion_at_returned);
    try std.testing.expect(!outcome.conversion_over_returned);
    try std.testing.expectEqual(error.DepthLimitExceeded, outcome.conversion_over_error.?);
    try std.testing.expect(!outcome.swallowed_returned);
    try std.testing.expectEqual(error.MalformedCustomJson, outcome.swallowed_error.?);
}
