const std = @import("std");
const engine = @import("../runtime/engine.zig");
const style = @import("../theme/style.zig");
const token = @import("../runtime/token.zig");

pub const LanguageId = token.LanguageId;
pub const no_language = token.no_language;

pub const Capture = struct {
    start: u32,
    end: u32,
    style_id: style.StyleId,
    language_id: LanguageId = no_language,
};

pub fn styleFromCaptureName(capture_name: []const u8) style.StyleId {
    const name = if (capture_name.len != 0 and capture_name[0] == '@') capture_name[1..] else capture_name;
    if (contains(name, "comment")) return .comment;
    if (contains(name, "escape")) return .escape;
    if (contains(name, "placeholder") or contains(name, "format")) return .format_placeholder;
    if (contains(name, "string")) return .string;
    if (contains(name, "character") or contains(name, "char")) return .char;
    if (contains(name, "float")) return .number_float;
    if (contains(name, "number") or contains(name, "numeric") or contains(name, "integer")) return .number_integer;
    if (contains(name, "operator")) return .operator;
    if (contains(name, "keyword") or contains(name, "storage")) return .keyword;
    if (contains(name, "builtin")) return .builtin;
    if (contains(name, "function") or contains(name, "method")) return .function;
    if (contains(name, "type") or contains(name, "constructor") or contains(name, "class") or contains(name, "struct") or contains(name, "enum")) return .type_name;
    if (contains(name, "parameter")) return .parameter;
    if (contains(name, "property") or contains(name, "field") or contains(name, "member")) return .field;
    if (contains(name, "label")) return .label;
    if (contains(name, "punctuation")) return .punctuation;
    if (contains(name, "error") or contains(name, "invalid")) return .invalid;
    return .plain;
}

pub fn applyOverlay(
    base_tokens: []const token.Token,
    captures: []const Capture,
    sink: anytype,
) engine.HighlightError!usize {
    return applyOverlayLine(inferLineLen(base_tokens, captures), base_tokens, captures, sink);
}

pub fn applyAdapterLine(
    line: []const u8,
    base_tokens: []const token.Token,
    adapter: anytype,
    scratch: anytype,
    sink: anytype,
) engine.HighlightError!usize {
    if (line.len > std.math.maxInt(u32)) return error.LineTooLong;
    const captures = try adapter.captures(line, scratch);
    return applyOverlayLine(@intCast(line.len), base_tokens, captures, sink);
}

pub fn applyOverlayLine(
    line_len: u32,
    base_tokens: []const token.Token,
    captures: []const Capture,
    sink: anytype,
) engine.HighlightError!usize {
    try validateCaptures(captures);
    if (captures.len != 0 and captures[captures.len - 1].end > line_len) return error.MalformedGrammar;
    var emitted: usize = 0;
    var capture_i: usize = 0;
    var cursor: u32 = 0;

    for (base_tokens) |base| {
        if (base.end < base.start or base.start < cursor or base.end > line_len) return error.MalformedGrammar;
        emitted += try overlaySegment(cursor, base.start, .plain, no_language, captures, &capture_i, sink);
        emitted += try overlaySegment(base.start, base.end, base.style_id, base.language_id, captures, &capture_i, sink);
        cursor = base.end;
    }
    emitted += try overlaySegment(cursor, line_len, .plain, no_language, captures, &capture_i, sink);
    return emitted;
}

fn inferLineLen(base_tokens: []const token.Token, captures: []const Capture) u32 {
    var line_len: u32 = 0;
    for (base_tokens) |tok| line_len = @max(line_len, tok.end);
    for (captures) |cap| line_len = @max(line_len, cap.end);
    return line_len;
}

fn overlaySegment(
    seg_start: u32,
    seg_end: u32,
    style_id: style.StyleId,
    language_id: LanguageId,
    captures: []const Capture,
    capture_i: *usize,
    sink: anytype,
) engine.HighlightError!usize {
    var emitted: usize = 0;
    var pos = seg_start;
    while (capture_i.* < captures.len and captures[capture_i.*].end <= seg_start) : (capture_i.* += 1) {}
    while (capture_i.* < captures.len and captures[capture_i.*].start < seg_end) {
        const cap = captures[capture_i.*];
        if (cap.start > pos) {
            try emit(sink, pos, @min(cap.start, seg_end), style_id, language_id);
            emitted += 1;
        }
        const start = @max(pos, cap.start);
        const end = @min(seg_end, cap.end);
        if (end > start) {
            try emit(sink, start, end, cap.style_id, cap.language_id);
            emitted += 1;
        }
        pos = end;
        if (cap.end <= pos) capture_i.* += 1 else break;
    }
    if (pos < seg_end) {
        try emit(sink, pos, seg_end, style_id, language_id);
        emitted += 1;
    }
    return emitted;
}

fn validateCaptures(captures: []const Capture) engine.HighlightError!void {
    var last_end: u32 = 0;
    for (captures) |cap| {
        if (cap.end < cap.start or cap.start < last_end) return error.MalformedGrammar;
        last_end = cap.end;
    }
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn emit(sink: anytype, start: u32, end: u32, style_id: style.StyleId, language_id: LanguageId) engine.HighlightError!void {
    if (end <= start) return;
    try sink.emit(.{ .start = start, .end = end, .style_id = style_id, .language_id = language_id });
}

test "tree-sitter maps common capture names to styles" {
    try std.testing.expectEqual(style.StyleId.comment, styleFromCaptureName("@comment"));
    try std.testing.expectEqual(style.StyleId.escape, styleFromCaptureName("@string.escape"));
    try std.testing.expectEqual(style.StyleId.format_placeholder, styleFromCaptureName("@format.placeholder"));
    try std.testing.expectEqual(style.StyleId.number_float, styleFromCaptureName("@number.float"));
    try std.testing.expectEqual(style.StyleId.operator, styleFromCaptureName("@keyword.operator"));
    try std.testing.expectEqual(style.StyleId.keyword, styleFromCaptureName("@keyword"));
    try std.testing.expectEqual(style.StyleId.builtin, styleFromCaptureName("@function.builtin"));
    try std.testing.expectEqual(style.StyleId.function, styleFromCaptureName("@method"));
    try std.testing.expectEqual(style.StyleId.type_name, styleFromCaptureName("@constructor"));
    try std.testing.expectEqual(style.StyleId.parameter, styleFromCaptureName("@variable.parameter"));
    try std.testing.expectEqual(style.StyleId.field, styleFromCaptureName("@property"));
    try std.testing.expectEqual(style.StyleId.punctuation, styleFromCaptureName("@punctuation.bracket"));
    try std.testing.expectEqual(style.StyleId.invalid, styleFromCaptureName("@error"));
    try std.testing.expectEqual(style.StyleId.plain, styleFromCaptureName("@variable"));
}

test "tree-sitter overlay splits lexical tokens without allocation" {
    var sink = @import("../runtime/sinks.zig").TokenBuffer(8).init();
    const base = [_]token.Token{
        .{ .start = 0, .end = 10, .style_id = .plain },
    };
    const captures = [_]Capture{
        .{ .start = 2, .end = 6, .style_id = .function, .language_id = 1 },
    };

    const count = try applyOverlay(&base, &captures, &sink);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(style.StyleId.plain, sink.tokens[0].style_id);
    try std.testing.expectEqual(style.StyleId.function, sink.tokens[1].style_id);
    try std.testing.expectEqual(@as(LanguageId, 1), sink.tokens[1].language_id);
    try std.testing.expectEqual(style.StyleId.plain, sink.tokens[2].style_id);
}

test "tree-sitter overlay emits captures in plain gaps" {
    var sink = @import("../runtime/sinks.zig").TokenBuffer(8).init();
    const base = [_]token.Token{
        .{ .start = 0, .end = 2, .style_id = .keyword },
        .{ .start = 8, .end = 10, .style_id = .comment },
    };
    const captures = [_]Capture{
        .{ .start = 4, .end = 6, .style_id = .function, .language_id = 2 },
    };

    const count = try applyOverlayLine(10, &base, &captures, &sink);
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqual(style.StyleId.keyword, sink.tokens[0].style_id);
    try std.testing.expectEqual(style.StyleId.plain, sink.tokens[1].style_id);
    try std.testing.expectEqual(style.StyleId.function, sink.tokens[2].style_id);
    try std.testing.expectEqual(@as(LanguageId, 2), sink.tokens[2].language_id);
    try std.testing.expectEqual(style.StyleId.comment, sink.tokens[4].style_id);
}

test "tree-sitter overlay preserves captures across native token boundaries" {
    var sink = @import("../runtime/sinks.zig").TokenBuffer(8).init();
    const base = [_]token.Token{
        .{ .start = 0, .end = 5, .style_id = .keyword },
        .{ .start = 5, .end = 10, .style_id = .plain },
    };
    const captures = [_]Capture{
        .{ .start = 3, .end = 8, .style_id = .function, .language_id = 4 },
    };

    const count = try applyOverlayLine(10, &base, &captures, &sink);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(usize, 3), sink.count);
    try std.testing.expectEqual(style.StyleId.keyword, sink.tokens[0].style_id);
    try std.testing.expectEqual(style.StyleId.function, sink.tokens[1].style_id);
    try std.testing.expectEqual(@as(u32, 3), sink.tokens[1].start);
    try std.testing.expectEqual(@as(u32, 8), sink.tokens[1].end);
    try std.testing.expectEqual(@as(LanguageId, 4), sink.tokens[1].language_id);
    try std.testing.expectEqual(style.StyleId.plain, sink.tokens[2].style_id);
}

test "tree-sitter adapter feeds overlay captures" {
    const MockAdapter = struct {
        fn captures(_: @This(), line: []const u8, scratch: *[1]Capture) engine.HighlightError![]const Capture {
            const start = std.mem.indexOf(u8, line, "main") orelse return scratch[0..0];
            scratch[0] = .{ .start = @intCast(start), .end = @intCast(start + 4), .style_id = .function, .language_id = 3 };
            return scratch[0..1];
        }
    };
    var scratch: [1]Capture = undefined;
    var sink = @import("../runtime/sinks.zig").TokenBuffer(8).init();
    const base = [_]token.Token{
        .{ .start = 0, .end = 2, .style_id = .keyword },
    };

    const count = try applyAdapterLine("fn main() void", &base, MockAdapter{}, &scratch, &sink);

    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(style.StyleId.keyword, sink.tokens[0].style_id);
    try std.testing.expectEqual(style.StyleId.function, sink.tokens[2].style_id);
    try std.testing.expectEqual(@as(LanguageId, 3), sink.tokens[2].language_id);
}

test "tree-sitter overlay rejects overlapping captures" {
    var sink = @import("../runtime/sinks.zig").NullSink{};
    const base = [_]token.Token{.{ .start = 0, .end = 10, .style_id = .plain }};
    const captures = [_]Capture{
        .{ .start = 2, .end = 7, .style_id = .function },
        .{ .start = 6, .end = 9, .style_id = .type_name },
    };

    try std.testing.expectError(error.MalformedGrammar, applyOverlay(&base, &captures, &sink));
}

test "tree-sitter overlay rejects unordered base tokens" {
    var sink = @import("../runtime/sinks.zig").NullSink{};
    const base = [_]token.Token{
        .{ .start = 4, .end = 8, .style_id = .plain },
        .{ .start = 2, .end = 3, .style_id = .keyword },
    };

    try std.testing.expectError(error.MalformedGrammar, applyOverlayLine(8, &base, &.{}, &sink));
}

test "tree-sitter overlay rejects base tokens past line length" {
    var sink = @import("../runtime/sinks.zig").NullSink{};
    const base = [_]token.Token{.{ .start = 0, .end = 11, .style_id = .plain }};

    try std.testing.expectError(error.MalformedGrammar, applyOverlayLine(10, &base, &.{}, &sink));
}

test "tree-sitter overlay rejects captures past line length" {
    var sink = @import("../runtime/sinks.zig").NullSink{};
    const captures = [_]Capture{.{ .start = 9, .end = 11, .style_id = .function }};

    try std.testing.expectError(error.MalformedGrammar, applyOverlayLine(10, &.{}, &captures, &sink));
}
