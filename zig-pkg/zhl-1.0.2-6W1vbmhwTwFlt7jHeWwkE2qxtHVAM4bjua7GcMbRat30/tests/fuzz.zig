const std = @import("std");
const zhl = @import("zhl");
const grammars = @import("zhl_grammars");

test "fuzz native Zig highlighter on ASCII lines" {
    const Highlighter = zhl.Engine(grammars.zig_0_16.grammar, .{
        .max_line_bytes = 256,
        .max_tokens_per_line = 512,
    });
    var highlighter = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var state = Highlighter.State.initial();
    var seed: u32 = 0x12345678;

    var case_index: usize = 0;
    while (case_index < 256) : (case_index += 1) {
        var line: [256]u8 = undefined;
        const len = next(&seed) % line.len;
        for (line[0..len]) |*byte| byte.* = randomSourceByte(&seed);
        var sink = zhl.sinks.TokenBuffer(512).init();
        const result = try highlighter.highlightLine(line[0..len], state, &scratch, &sink);
        state = result.end_state;
    }
}

test "fuzz native DSL parser on generated grammars" {
    var case_index: usize = 0;
    while (case_index < 64) : (case_index += 1) {
        var buf: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try writer.print(
            \\grammar "source.fuzz{d}" {{
            \\  name "Fuzz{d}";
            \\  scope root = "source.fuzz{d}";
            \\  context main {{
            \\    line_comment "//{d}" scope "comment.line.fuzz";
            \\    keywords "const var fn" scope "keyword.control.fuzz";
            \\  }}
            \\}}
        , .{ case_index, case_index, case_index, case_index });
        const parsed = try zhl.dsl.parse(buf[0..writer.end]);
        try std.testing.expectEqual(@as(u16, 2), parsed.rule_count);
    }
}

fn next(seed: *u32) usize {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return seed.*;
}

fn randomSourceByte(seed: *u32) u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_{}[]()\"' \t+-*/%=;,.@\\";
    return alphabet[next(seed) % alphabet.len];
}
