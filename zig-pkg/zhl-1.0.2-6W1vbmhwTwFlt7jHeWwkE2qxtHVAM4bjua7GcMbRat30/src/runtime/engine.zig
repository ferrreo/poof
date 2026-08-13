const std = @import("std");
const token = @import("token.zig");
const regex_scratch = @import("../regex/scratch.zig");

pub const EngineOptions = struct {
    max_stack_depth: u16 = 64,
    max_dynamic_capture_bytes: u16 = 256,
    max_regex_vm_stack: u16 = 1024,
    max_capture_slots: u16 = 128,
    max_line_bytes: u32 = 1 << 20,
    max_tokens_per_line: u32 = 16_384,
    offset_type: type = u32,
    emit_scopes: bool = false,
    emit_style_ids: bool = true,
};

pub const HighlightError = error{
    StackOverflow,
    DynamicCaptureOverflow,
    RegexVmStackOverflow,
    RegexCaptureOverflow,
    RegexStepLimitExceeded,
    TokenOverflow,
    LineTooLong,
    MalformedGrammar,
};

pub const CaptureSlot = packed struct {
    start: u32 = 0,
    end: u32 = 0,
};

pub const Frame = packed struct {
    context_id: u16 = 0,
    scope_stack_id: u16 = 0,
    end_matcher_id: u16 = 0,
    while_matcher_id: u16 = 0,
    dynamic_capture_offset: u16 = 0,
    dynamic_capture_len: u16 = 0,
};

pub fn State(comptime max_depth: u16, comptime max_capture_bytes: u16) type {
    return struct {
        const Self = @This();

        depth: u16 = 0,
        frames: [max_depth]Frame = [_]Frame{.{}} ** max_depth,
        dynamic_captures: [max_capture_bytes]u8 = [_]u8{0} ** max_capture_bytes,
        dynamic_capture_len: u16 = 0,
        fingerprint: u64 = 0,

        pub fn initial() Self {
            return .{};
        }

        pub fn eql(a: Self, b: Self) bool {
            if (a.fingerprint != b.fingerprint) return false;
            if (a.depth != b.depth) return false;
            if (a.dynamic_capture_len != b.dynamic_capture_len) return false;

            var i: usize = 0;
            while (i < a.depth) : (i += 1) {
                if (a.frames[i] != b.frames[i]) return false;
            }

            if (max_capture_bytes > 0) {
                i = 0;
                while (i < a.dynamic_capture_len) : (i += 1) {
                    if (a.dynamic_captures[i] != b.dynamic_captures[i]) return false;
                }
            }
            return true;
        }
    };
}

pub fn Scratch(
    comptime max_dynamic_capture_bytes: u16,
    comptime max_regex_vm_stack: u16,
    comptime max_capture_slots: u16,
    comptime max_stack_depth: u16,
) type {
    return struct {
        dynamic_captures: [max_dynamic_capture_bytes]u8 = [_]u8{0} ** max_dynamic_capture_bytes,
        regex_vm_stack: [max_regex_vm_stack]regex_scratch.VmFrame = undefined,
        capture_slots: [max_capture_slots]CaptureSlot = [_]CaptureSlot{.{}} ** max_capture_slots,
        temporary_scope_stack: [max_stack_depth]u16 = [_]u16{0} ** max_stack_depth,

        pub fn init() @This() {
            return .{};
        }
    };
}

pub fn LineResult(comptime StateType: type) type {
    return struct {
        end_state: StateType,
        token_count: usize,
    };
}

pub fn Engine(comptime grammar: anytype, comptime options: EngineOptions) type {
    const StateType = State(options.max_stack_depth, options.max_dynamic_capture_bytes);
    const ScratchType = Scratch(
        options.max_dynamic_capture_bytes,
        options.max_regex_vm_stack,
        options.max_capture_slots,
        options.max_stack_depth,
    );
    const LineResultType = LineResult(StateType);

    return struct {
        const Self = @This();
        pub const State = StateType;
        pub const Scratch = ScratchType;
        pub const LineResult = LineResultType;
        pub const grammar_name = grammar.name;

        pub fn init(_: struct {}) Self {
            return .{};
        }

        pub fn highlightLine(
            self: *Self,
            line: []const u8,
            state: StateType,
            scratch: *ScratchType,
            sink: anytype,
        ) HighlightError!LineResultType {
            _ = self;
            if (line.len > options.max_line_bytes) return error.LineTooLong;
            const result = try @TypeOf(grammar).highlightLine(options, line, state, scratch, sink);
            if (result.token_count > options.max_tokens_per_line) return error.TokenOverflow;
            return result;
        }
    };
}

test "state equality checks fingerprint and data" {
    const S = State(4, 8);
    var a = S.initial();
    var b = S.initial();
    try std.testing.expect(a.eql(b));
    a.fingerprint = 1;
    try std.testing.expect(!a.eql(b));
    b.fingerprint = 1;
    a.depth = 1;
    try std.testing.expect(!a.eql(b));
}

test "engine enforces max tokens per line" {
    const fake = struct {
        pub const grammar = @This(){};
        pub const name = "fake";

        pub fn highlightLine(
            comptime _: EngineOptions,
            _: []const u8,
            state: anytype,
            _: anytype,
            _: anytype,
        ) HighlightError!LineResult(@TypeOf(state)) {
            return .{ .end_state = state, .token_count = 2 };
        }
    };

    const Highlighter = Engine(fake.grammar, .{ .max_tokens_per_line = 1 });
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = struct {
        pub fn emit(_: *@This(), _: token.Token) HighlightError!void {}
    }{};

    try std.testing.expectError(
        error.TokenOverflow,
        h.highlightLine("", Highlighter.State.initial(), &scratch, &sink),
    );
}

test "engine enforces max line bytes" {
    const fake = struct {
        pub const grammar = @This(){};
        pub const name = "fake";

        pub fn highlightLine(
            comptime _: EngineOptions,
            _: []const u8,
            state: anytype,
            _: anytype,
            _: anytype,
        ) HighlightError!LineResult(@TypeOf(state)) {
            return .{ .end_state = state, .token_count = 0 };
        }
    };

    const Highlighter = Engine(fake.grammar, .{ .max_line_bytes = 2 });
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = struct {
        pub fn emit(_: *@This(), _: token.Token) HighlightError!void {}
    }{};

    try std.testing.expectError(
        error.LineTooLong,
        h.highlightLine("long", Highlighter.State.initial(), &scratch, &sink),
    );
}

test "engine surfaces grammar errors" {
    const fake = struct {
        pub const grammar = @This(){};
        pub const name = "fake";

        pub fn highlightLine(
            comptime _: EngineOptions,
            _: []const u8,
            state: anytype,
            _: anytype,
            _: anytype,
        ) HighlightError!LineResult(@TypeOf(state)) {
            return error.MalformedGrammar;
        }
    };

    const Highlighter = Engine(fake.grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = @import("sinks.zig").TokenBuffer(4).init();

    try std.testing.expectError(
        error.MalformedGrammar,
        h.highlightLine("bad", Highlighter.State.initial(), &scratch, &sink),
    );
}
