const std = @import("std");
const zhl = @import("zhl");

pub const grammar = ZigGrammar{};
pub const name = ZigGrammar.name;

pub const ZigGrammar = struct {
    pub const name = "Zig 0.16";
    pub const scope_root = "source.zig";

    const interesting = blk: {
        var mask = zhl.ByteMask256.empty();
        for ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_0123456789/@\"'\\.{}()[];,:+-*%=!<>&|^~?") |byte| {
            mask.set(byte);
        }
        mask.set(' ');
        mask.set('\t');
        break :blk mask;
    };

    pub fn highlightLine(
        comptime options: zhl.EngineOptions,
        line: []const u8,
        state: anytype,
        scratch: anytype,
        sink: anytype,
    ) zhl.HighlightError!zhl.LineResult(@TypeOf(state)) {
        _ = options;
        _ = scratch;

        var out_state = state;
        out_state.fingerprint = 0;

        var i: usize = 0;
        var emitted: usize = 0;
        while (i < line.len) {
            const next = zhl.scan.findNextInteresting(interesting, line, i);
            if (next > i) {
                try emit(sink, i, next, .plain, &emitted);
                i = next;
            }
            if (i >= line.len) break;

            const byte = line[i];
            if (isControl(byte)) {
                try emit(sink, i, i + 1, .invalid, &emitted);
                i += 1;
                continue;
            }

            if (std.mem.startsWith(u8, line[i..], "//!")) {
                try emit(sink, i, line.len, .container_doc_comment, &emitted);
                break;
            }
            if (std.mem.startsWith(u8, line[i..], "///") and (i + 3 == line.len or line[i + 3] != '/')) {
                try emit(sink, i, line.len, .doc_comment, &emitted);
                break;
            }
            if (std.mem.startsWith(u8, line[i..], "//")) {
                try emit(sink, i, line.len, .comment, &emitted);
                break;
            }

            if (std.mem.startsWith(u8, line[i..], "\\\\")) {
                try emit(sink, i, line.len, .multiline_string, &emitted);
                break;
            }

            switch (byte) {
                ' ', '\t' => {
                    const end = zhl.scan.scanAsciiWhitespace(line, i);
                    try emit(sink, i, end, .plain, &emitted);
                    i = end;
                },
                '"' => {
                    const end = scanQuoted(line, i, '"');
                    try emitQuotedString(line, i, end, sink, &emitted);
                    i = end;
                },
                '\'' => {
                    const end = scanQuoted(line, i, '\'');
                    try emit(sink, i, end, .char, &emitted);
                    i = end;
                },
                '@' => {
                    const end = scanBuiltin(line, i);
                    try emit(sink, i, end, .builtin, &emitted);
                    i = end;
                },
                '0'...'9' => {
                    const n = scanNumber(line, i);
                    try emit(sink, i, n.end, if (n.is_float) .number_float else .number_integer, &emitted);
                    i = n.end;
                },
                '.' => {
                    if (i + 1 < line.len and zhl.scan.isIdentStart(line[i + 1])) {
                        try emit(sink, i, i + 1, .operator, &emitted);
                        const end = zhl.scan.scanAsciiIdentifier(line, i + 1);
                        const style_id: zhl.StyleId = if (isCallAfter(line, end)) .function else .field;
                        try emit(sink, i + 1, end, style_id, &emitted);
                        i = end;
                    } else {
                        const end = scanOperator(line, i);
                        try emit(sink, i, end, .operator, &emitted);
                        i = end;
                    }
                },
                '{', '}', '(', ')', '[', ']', ';', ',', ':' => {
                    try emit(sink, i, i + 1, .punctuation, &emitted);
                    i += 1;
                },
                else => {
                    if (zhl.scan.isIdentStart(byte)) {
                        const end = zhl.scan.scanAsciiIdentifier(line, i);
                        const word = line[i..end];
                        if (std.mem.eql(u8, word, "fn")) {
                            try emit(sink, i, end, .keyword, &emitted);
                            i = try emitFunctionNameAfterFn(line, end, sink, &emitted);
                        } else if (isKeyword(word)) {
                            try emit(sink, i, end, .keyword, &emitted);
                            i = end;
                        } else if (isPrimitiveValue(word)) {
                            try emit(sink, i, end, .keyword, &emitted);
                            i = end;
                        } else if (isPrimitiveType(word) or isIntegerTypeName(word)) {
                            try emit(sink, i, end, .type_name, &emitted);
                            i = end;
                        } else if (isLabel(line, end)) {
                            try emit(sink, i, end, .label, &emitted);
                            i = end;
                        } else {
                            try emit(sink, i, end, .plain, &emitted);
                            i = end;
                        }
                    } else if (isOperatorStart(byte)) {
                        const end = scanOperator(line, i);
                        try emit(sink, i, end, .operator, &emitted);
                        i = end;
                    } else {
                        try emit(sink, i, i + 1, .plain, &emitted);
                        i += 1;
                    }
                },
            }
        }

        return .{ .end_state = out_state, .token_count = emitted };
    }
};

fn emit(sink: anytype, start: usize, end: usize, style_id: zhl.StyleId, emitted: *usize) zhl.HighlightError!void {
    if (end <= start) return;
    try sink.emit(.{
        .start = @intCast(start),
        .end = @intCast(end),
        .style_id = style_id,
        .scope_stack_id = scopeForStyle(style_id),
    });
    emitted.* += 1;
}

fn scopeForStyle(style_id: zhl.StyleId) zhl.ScopeStackId {
    return switch (style_id) {
        .plain => .source_zig,
        .comment => .comment,
        .doc_comment => .doc_comment,
        .container_doc_comment => .container_doc_comment,
        .string => .string,
        .multiline_string => .multiline_string,
        .char => .char,
        .escape => .escape,
        .format_placeholder => .format_placeholder,
        .number_integer, .number_float => .number,
        .keyword => .keyword,
        .operator => .operator,
        .builtin => .builtin,
        .function => .function,
        .type_name => .type_name,
        .parameter => .field,
        .field => .field,
        .label => .label,
        .punctuation => .punctuation,
        .invalid => .invalid,
    };
}

fn scanQuoted(line: []const u8, start: usize, comptime quote: u8) usize {
    var i = start + 1;
    while (i < line.len) {
        const hit = zhl.scan.indexOfAnyByte(&.{ quote, '\\' }, line, i);
        if (hit >= line.len) return line.len;
        if (line[hit] == quote) return hit + 1;
        i = @min(hit + 2, line.len);
    }
    return line.len;
}

fn emitQuotedString(line: []const u8, start: usize, end: usize, sink: anytype, emitted: *usize) zhl.HighlightError!void {
    const content_end = if (end > start and line[end - 1] == '"') end - 1 else end;
    var segment = start;
    var i = start + 1;
    while (i < content_end) {
        if (line[i] == '\\' and i + 1 < content_end) {
            try emit(sink, segment, i, .string, emitted);
            try emit(sink, i, i + 2, .escape, emitted);
            i += 2;
            segment = i;
        } else if (bracePlaceholderEnd(line, i, content_end)) |format_end| {
            try emit(sink, segment, i, .string, emitted);
            try emit(sink, i, format_end, .format_placeholder, emitted);
            i = format_end;
            segment = i;
        } else {
            i += 1;
        }
    }
    try emit(sink, segment, end, .string, emitted);
}

fn bracePlaceholderEnd(line: []const u8, start: usize, limit: usize) ?usize {
    if (line[start] != '{' or start + 1 >= limit or line[start + 1] == '{') return null;
    var i = start + 1;
    while (i < limit and line[i] != '}') : (i += 1) {}
    return if (i < limit) i + 1 else null;
}

fn scanBuiltin(line: []const u8, start: usize) usize {
    if (start + 1 >= line.len) return start + 1;
    if (line[start + 1] == '"') return scanQuoted(line, start + 1, '"');
    const ident_end = zhl.scan.scanAsciiIdentifier(line, start + 1);
    if (ident_end == start + 1) return start + 1;
    return ident_end;
}

const NumberScan = struct {
    end: usize,
    is_float: bool,
};

fn scanNumber(line: []const u8, start: usize) NumberScan {
    var i = start;
    var is_float = false;

    if (i + 1 < line.len and line[i] == '0' and zhl.scan.isAnyOf(line[i + 1], "xXbBoO")) {
        const base = line[i + 1];
        i += 2;
        while (i < line.len and numberDigitForBase(line[i], base)) : (i += 1) {}
        if (i < line.len and line[i] == '.' and i + 1 < line.len and numberDigitForBase(line[i + 1], base)) {
            is_float = true;
            i += 1;
            while (i < line.len and numberDigitForBase(line[i], base)) : (i += 1) {}
        }
        if (i < line.len and zhl.scan.isAnyOf(line[i], "pPeE")) {
            is_float = true;
            i += 1;
            if (i < line.len and zhl.scan.isAnyOf(line[i], "+-")) i += 1;
            while (i < line.len and isDecimalOrUnderscore(line[i])) : (i += 1) {}
        }
        return .{ .end = i, .is_float = is_float };
    }

    while (i < line.len and isDecimalOrUnderscore(line[i])) : (i += 1) {}
    if (i < line.len and line[i] == '.' and i + 1 < line.len and zhl.scan.isDigit(line[i + 1])) {
        is_float = true;
        i += 1;
        while (i < line.len and isDecimalOrUnderscore(line[i])) : (i += 1) {}
    }
    if (i < line.len and zhl.scan.isAnyOf(line[i], "eE")) {
        is_float = true;
        i += 1;
        if (i < line.len and zhl.scan.isAnyOf(line[i], "+-")) i += 1;
        while (i < line.len and isDecimalOrUnderscore(line[i])) : (i += 1) {}
    }
    return .{ .end = i, .is_float = is_float };
}

fn numberDigitForBase(byte: u8, base_marker: u8) bool {
    return switch (base_marker) {
        'x', 'X' => zhl.scan.isHexDigit(byte) or byte == '_',
        'b', 'B' => byte == '0' or byte == '1' or byte == '_',
        'o', 'O' => (byte >= '0' and byte <= '7') or byte == '_',
        else => isDecimalOrUnderscore(byte),
    };
}

fn isDecimalOrUnderscore(byte: u8) bool {
    return zhl.scan.isDigit(byte) or byte == '_';
}

fn isOperatorStart(byte: u8) bool {
    return zhl.scan.isAnyOf(byte, "+-*%=!<>&|^~?/");
}

const operators = [_][]const u8{
    "<<|=", ">>=", "<<=", "*%=", "+%=", "-%=", ".*", "...", "**",  "++", "+%",     "-%", "*%", "->",
    "<<",   ">>",  "<=",  ">=",  "==",  "!=",  "=>", "||",  "and", "or", "orelse", "+",  "-",  "*",
    "/",    "%",   "=",   "<",   ">",   "!",   "&",  "|",   "^",   "~",  "?",      ".",  ":",
};

fn scanOperator(line: []const u8, start: usize) usize {
    for (operators) |op| {
        if (std.mem.startsWith(u8, line[start..], op)) return start + op.len;
    }
    return start + 1;
}

fn isKeyword(word: []const u8) bool {
    inline for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

const keywords = [_][]const u8{
    "addrspace",
    "align",
    "allowzero",
    "and",
    "anyframe",
    "anytype",
    "asm",
    "break",
    "callconv",
    "catch",
    "comptime",
    "const",
    "continue",
    "defer",
    "else",
    "enum",
    "errdefer",
    "error",
    "export",
    "extern",
    "fn",
    "for",
    "if",
    "inline",
    "linksection",
    "noalias",
    "noinline",
    "nosuspend",
    "opaque",
    "or",
    "orelse",
    "packed",
    "pub",
    "resume",
    "return",
    "struct",
    "suspend",
    "switch",
    "test",
    "threadlocal",
    "try",
    "union",
    "unreachable",
    "var",
    "volatile",
    "while",
};

fn isPrimitiveType(word: []const u8) bool {
    inline for (primitive_types) |ty| {
        if (std.mem.eql(u8, word, ty)) return true;
    }
    return false;
}

const primitive_types = [_][]const u8{
    "anyopaque",
    "bool",
    "void",
    "noreturn",
    "type",
    "anyerror",
    "comptime_int",
    "comptime_float",
    "isize",
    "usize",
    "c_char",
    "c_short",
    "c_ushort",
    "c_int",
    "c_uint",
    "c_long",
    "c_ulong",
    "c_longlong",
    "c_ulonglong",
    "c_longdouble",
    "f16",
    "f32",
    "f64",
    "f80",
    "f128",
};

fn isPrimitiveValue(word: []const u8) bool {
    inline for (primitive_values) |value| {
        if (std.mem.eql(u8, word, value)) return true;
    }
    return false;
}

const primitive_values = [_][]const u8{
    "true",
    "false",
    "null",
    "undefined",
};

fn isIntegerTypeName(word: []const u8) bool {
    if (word.len < 2) return false;
    if (word[0] != 'u' and word[0] != 'i') return false;
    for (word[1..]) |byte| {
        if (!zhl.scan.isDigit(byte)) return false;
    }
    return true;
}

fn isLabel(line: []const u8, ident_end: usize) bool {
    return ident_end < line.len and line[ident_end] == ':' and
        (ident_end + 1 == line.len or line[ident_end + 1] != ':');
}

fn isCallAfter(line: []const u8, ident_end: usize) bool {
    const pos = skipSpace(line, ident_end);
    return pos < line.len and line[pos] == '(';
}

fn emitFunctionNameAfterFn(line: []const u8, start: usize, sink: anytype, emitted: *usize) zhl.HighlightError!usize {
    const ws_end = skipSpace(line, start);
    if (ws_end > start) try emit(sink, start, ws_end, .plain, emitted);
    if (ws_end >= line.len or !zhl.scan.isIdentStart(line[ws_end])) return ws_end;
    const end = zhl.scan.scanAsciiIdentifier(line, ws_end);
    try emit(sink, ws_end, end, .function, emitted);
    return end;
}

fn skipSpace(line: []const u8, start: usize) usize {
    var i = start;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i;
}

fn isControl(byte: u8) bool {
    return byte < 0x20 and byte != '\t';
}

test "keywords match Zig 0.16 reference sample" {
    try std.testing.expect(isKeyword("addrspace"));
    try std.testing.expect(isKeyword("nosuspend"));
    try std.testing.expect(isKeyword("threadlocal"));
    try std.testing.expect(!isKeyword("void"));
}

test "primitive type and value names match Zig 0.16 docs" {
    try std.testing.expect(isPrimitiveType("anyopaque"));
    try std.testing.expect(isPrimitiveType("comptime_int"));
    try std.testing.expect(isPrimitiveValue("undefined"));
    try std.testing.expect(isPrimitiveValue("null"));
}

test "numbers classify integers and floats" {
    try std.testing.expectEqual(NumberScan{ .end = 5, .is_float = false }, scanNumber("0x1f_u", 0));
    try std.testing.expectEqual(NumberScan{ .end = 7, .is_float = true }, scanNumber("12.34e2", 0));
    try std.testing.expectEqual(NumberScan{ .end = 7, .is_float = true }, scanNumber("0x1.fp3", 0));
}

test "native Zig grammar highlights common line" {
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(32).init();
    const state = Highlighter.State.initial();

    const result = try h.highlightLine("pub fn main() void { @import(\"std\"); // hi }", state, &scratch, &sink);

    try std.testing.expect(result.end_state.eql(state));
    try std.testing.expect(sink.count >= 10);
    try std.testing.expectEqual(zhl.StyleId.keyword, sink.tokens[0].style_id);
    try std.testing.expect(hasStyle(sink.slice(), .function));
    try std.testing.expect(hasStyle(sink.slice(), .builtin));
    try std.testing.expectEqual(zhl.StyleId.comment, sink.tokens[sink.count - 1].style_id);
}

test "fields and member calls get cheap contextual styles" {
    const Highlighter = zhl.Engine(grammar, .{});
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(64).init();

    _ = try h.highlightLine("Thing = struct { field: u32 = obj.value; std.debug.print() }", Highlighter.State.initial(), &scratch, &sink);

    var saw_field = false;
    var saw_function = false;
    for (sink.slice()) |tok| {
        if (tok.style_id == .field) saw_field = true;
        if (tok.style_id == .function and std.mem.eql(u8, "Thing = struct { field: u32 = obj.value; std.debug.print() }"[tok.start..tok.end], "print")) saw_function = true;
    }
    try std.testing.expect(saw_field);
    try std.testing.expect(saw_function);
}

fn hasStyle(tokens: []const zhl.Token, style_id: zhl.StyleId) bool {
    for (tokens) |tok| {
        if (tok.style_id == style_id) return true;
    }
    return false;
}
