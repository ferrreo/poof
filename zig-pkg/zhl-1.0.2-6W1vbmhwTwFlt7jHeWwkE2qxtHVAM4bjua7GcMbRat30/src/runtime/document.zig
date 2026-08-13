pub const DirtyRange = struct {
    first: usize,
    past_end: usize,
};

pub fn LineCache(comptime StateType: type, comptime max_lines: usize) type {
    return struct {
        const Self = @This();

        states_out: [max_lines]StateType = [_]StateType{StateType.initial()} ** max_lines,
        line_count: usize = 0,

        pub fn init(line_count: usize) Self {
            _ = line_count;
            return .{};
        }

        pub fn rehighlight(
            self: *Self,
            highlighter: anytype,
            lines: []const []const u8,
            first_line: usize,
            scratch: anytype,
            token_buffers: anytype,
        ) !DirtyRange {
            if (lines.len > max_lines or first_line > lines.len or token_buffers.len < lines.len) return error.TooManyLines;
            var state = if (first_line == 0) StateType.initial() else self.states_out[first_line - 1];
            const old_line_count = self.line_count;
            var line_i = first_line;
            var past_end = first_line;

            while (line_i < lines.len) : (line_i += 1) {
                const old_out = self.states_out[line_i];
                token_buffers[line_i].reset();
                const result = try highlighter.highlightLine(lines[line_i], state, scratch, &token_buffers[line_i]);
                self.states_out[line_i] = result.end_state;
                state = result.end_state;
                past_end = line_i + 1;

                if (line_i > first_line and line_i < old_line_count and result.end_state.eql(old_out)) break;
            }

            self.line_count = lines.len;
            return .{ .first = first_line, .past_end = past_end };
        }
    };
}

test "LineCache rehighlight stops when state converges" {
    const engine = @import("engine.zig");

    const fake = struct {
        pub const grammar = @This(){};
        pub const name = "fake";

        pub fn highlightLine(
            comptime _: engine.EngineOptions,
            line: []const u8,
            state: anytype,
            _: anytype,
            sink: anytype,
        ) engine.HighlightError!engine.LineResult(@TypeOf(state)) {
            _ = sink;
            var next = state;
            next.fingerprint = line.len;
            return .{ .end_state = next, .token_count = 0 };
        }
    };

    const Highlighter = engine.Engine(fake.grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    const Sink = @import("sinks.zig").TokenBuffer(4);
    var sinks = [_]Sink{ Sink.init(), Sink.init(), Sink.init() };
    var cache = LineCache(Highlighter.State, 3).init(3);
    const lines = [_][]const u8{ "a", "bb", "ccc" };

    const first = try cache.rehighlight(&h, &lines, 0, &scratch, &sinks);
    try @import("std").testing.expectEqual(DirtyRange{ .first = 0, .past_end = 3 }, first);
    const second = try cache.rehighlight(&h, &lines, 0, &scratch, &sinks);
    try @import("std").testing.expect(second.past_end < 3);
}

test "LineCache rejects over-capacity inputs before indexing" {
    const engine = @import("engine.zig");
    const std = @import("std");

    const fake = struct {
        pub const grammar = @This(){};
        pub const name = "fake";

        pub fn highlightLine(
            comptime _: engine.EngineOptions,
            _: []const u8,
            state: anytype,
            _: anytype,
            _: anytype,
        ) engine.HighlightError!engine.LineResult(@TypeOf(state)) {
            return .{ .end_state = state, .token_count = 0 };
        }
    };

    const Highlighter = engine.Engine(fake.grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    const Sink = @import("sinks.zig").TokenBuffer(4);
    var sinks = [_]Sink{Sink.init()};
    var cache = LineCache(Highlighter.State, 1).init(1);
    const lines = [_][]const u8{ "a", "b" };

    try std.testing.expectError(error.TooManyLines, cache.rehighlight(&h, &lines, 0, &scratch, &sinks));
    try std.testing.expectError(error.TooManyLines, cache.rehighlight(&h, lines[0..1], 2, &scratch, &sinks));
}
