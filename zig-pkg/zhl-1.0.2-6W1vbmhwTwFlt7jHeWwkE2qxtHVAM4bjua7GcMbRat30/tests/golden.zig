const std = @import("std");
const zhl = @import("zhl");
const grammars = @import("zhl_grammars");

const Highlighter = zhl.Engine(grammars.zig_0_16.grammar, .{
    .max_stack_depth = 1,
    .max_dynamic_capture_bytes = 0,
    .max_regex_vm_stack = 64,
    .max_capture_slots = 1,
});

test "golden Zig fixture has expected token classes" {
    const source = @embedFile("golden/zig_basic.input.zig");
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var state = Highlighter.State.initial();
    var keyword_count: usize = 0;
    var string_count: usize = 0;
    var builtin_count: usize = 0;
    var comment_count: usize = 0;

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        var sink = zhl.sinks.TokenBuffer(128).init();
        const result = try h.highlightLine(line, state, &scratch, &sink);
        state = result.end_state;
        try expectOrdered(line, sink.slice());

        for (sink.slice()) |tok| {
            switch (tok.style_id) {
                .keyword => keyword_count += 1,
                .string => string_count += 1,
                .builtin => builtin_count += 1,
                .comment => comment_count += 1,
                else => {},
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 5), keyword_count);
    try std.testing.expectEqual(@as(usize, 3), string_count);
    try std.testing.expectEqual(@as(usize, 1), builtin_count);
    try std.testing.expectEqual(@as(usize, 1), comment_count);
}

test "golden Zig fixture token dump matches snapshot" {
    const source = @embedFile("golden/zig_basic.input.zig");
    const expected = @embedFile("golden/zig_basic.tokens");
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var state = Highlighter.State.initial();
    var buf: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| : (line_no += 1) {
        var sink = zhl.sinks.TokenBuffer(128).init();
        const result = try h.highlightLine(line, state, &scratch, &sink);
        state = result.end_state;

        try zhl.renderers.renderDebugLine(&writer, line_no, sink.slice());
    }

    try std.testing.expectEqualStrings(expected, buf[0..writer.end]);
}

test "generated native Zig grammar module highlights core scopes" {
    const Generated = zhl.Engine(grammars.zig_0_16_generated.grammar, .{});
    var h = Generated.init(.{});
    var scratch = Generated.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(32).init();

    _ = try h.highlightLine("const x = @import(\"std\"); // done", Generated.State.initial(), &scratch, &sink);

    try std.testing.expectEqual(zhl.StyleId.keyword, sink.tokens[0].style_id);
    try std.testing.expect(hasStyle(sink.slice(), .builtin));
    try std.testing.expectEqual(zhl.StyleId.comment, sink.tokens[sink.count - 1].style_id);
}

test "native grammar pack highlights language fixtures" {
    try expectNativeStyles(grammars.bash.grammar, @embedFile("fixtures/languages/bash-textmate.sh"), &.{ .comment, .field, .builtin, .string });
    try expectNativeStyles(grammars.c.grammar, @embedFile("fixtures/languages/c-textmate.c"), &.{ .keyword, .function, .string, .comment });
    try expectNativeStyles(grammars.javascript.grammar, @embedFile("fixtures/languages/javascript-textmate.js"), &.{ .keyword, .string, .number_integer });
    try expectNativeStyles(grammars.json.grammar, @embedFile("fixtures/languages/json-textmate.json"), &.{ .field, .string, .number_integer, .keyword });
    try expectNativeStyles(grammars.log.grammar, @embedFile("fixtures/languages/log-textmate.log"), &.{ .keyword, .string });
    try expectNativeStyles(grammars.python.grammar, @embedFile("fixtures/languages/python-textmate.py"), &.{ .keyword, .function, .number_integer });
    try expectNativeStyles(grammars.rust.grammar, @embedFile("fixtures/languages/rust-textmate.rs"), &.{ .keyword, .type_name, .function, .comment });
    try expectNativeStyles(grammars.toml.grammar, @embedFile("fixtures/languages/toml-textmate.toml"), &.{ .field, .string, .number_integer, .keyword });
    try expectNativeStyles(grammars.typescript.grammar, @embedFile("fixtures/languages/typescript-textmate.ts"), &.{ .keyword, .type_name, .string });
    try expectNativeStyles(grammars.yaml.grammar, @embedFile("fixtures/languages/yaml-textmate.yaml"), &.{ .field, .keyword, .number_integer });
}

test "golden P0 native fixture token dumps match snapshots" {
    try expectGoldenCrc(grammars.bash.grammar, @embedFile("fixtures/languages/bash-textmate.sh"), 0xe76377da);
    try expectGoldenCrc(grammars.c.grammar, @embedFile("fixtures/languages/c-textmate.c"), 0x987c2593);
    try expectGoldenCrc(grammars.cpp.grammar, @embedFile("fixtures/languages/cpp-textmate.cpp"), 0xdac7103a);
    try expectGoldenCrc(grammars.csharp.grammar, @embedFile("fixtures/languages/csharp-textmate.cs"), 0xcc0d5fdb);
    try expectGoldenCrc(grammars.css.grammar, @embedFile("fixtures/languages/css-textmate.css"), 0xa8d204e0);
    try expectGoldenCrc(grammars.go.grammar, @embedFile("fixtures/languages/go-textmate.go"), 0x6be2f370);
    try expectGoldenCrc(grammars.html.grammar, @embedFile("fixtures/languages/html-textmate.html"), 0x72cbf0d9);
    try expectGoldenCrc(grammars.java.grammar, @embedFile("fixtures/languages/java-textmate.java"), 0xbe8a476c);
    try expectGoldenCrc(grammars.javascript.grammar, @embedFile("fixtures/languages/javascript-textmate.js"), 0x3faea53f);
    try expectGoldenCrc(grammars.jsx.grammar, @embedFile("fixtures/languages/jsx-textmate.jsx"), 0xd38ca52a);
    try expectGoldenCrc(grammars.json.grammar, @embedFile("fixtures/languages/json-textmate.json"), 0xa233f1eb);
    try expectGoldenCrc(grammars.kotlin.grammar, @embedFile("fixtures/languages/kotlin-textmate.kt"), 0xbf6fbffc);
    try expectGoldenCrc(grammars.log.grammar, @embedFile("fixtures/languages/log-textmate.log"), 0xea6a270b);
    try expectGoldenCrc(grammars.markdown.grammar, @embedFile("fixtures/languages/markdown-textmate.md"), 0x02f12a53);
    try expectGoldenCrc(grammars.php.grammar, @embedFile("fixtures/languages/php-textmate.php"), 0xd2ddf64a);
    try expectGoldenCrc(grammars.python.grammar, @embedFile("fixtures/languages/python-textmate.py"), 0xa91314b7);
    try expectGoldenCrc(grammars.ruby.grammar, @embedFile("fixtures/languages/ruby-textmate.rb"), 0x562f9fbb);
    try expectGoldenCrc(grammars.rust.grammar, @embedFile("fixtures/languages/rust-textmate.rs"), 0x27d6de39);
    try expectGoldenCrc(grammars.sql.grammar, @embedFile("fixtures/languages/sql-textmate.sql"), 0x219eac0c);
    try expectGoldenCrc(grammars.swift.grammar, @embedFile("fixtures/languages/swift-textmate.swift"), 0xcd74924e);
    try expectGoldenCrc(grammars.toml.grammar, @embedFile("fixtures/languages/toml-textmate.toml"), 0xd41379b7);
    try expectGoldenCrc(grammars.tsx.grammar, @embedFile("fixtures/languages/tsx-textmate.tsx"), 0x0cc880df);
    try expectGoldenCrc(grammars.typescript.grammar, @embedFile("fixtures/languages/typescript-textmate.ts"), 0x5a3cc475);
    try expectGoldenCrc(grammars.xml.grammar, @embedFile("fixtures/languages/xml-textmate.xml"), 0xa9c4a9b8);
    try expectGoldenCrc(grammars.yaml.grammar, @embedFile("fixtures/languages/yaml-textmate.yaml"), 0x6ae18ff2);
    try expectGoldenCrc(grammars.zig_0_16.grammar, @embedFile("golden/zig_basic.input.zig"), 0x246ec1cb);
}

test "Zig and Rust format markers keep distinct styles" {
    var zig_h = Highlighter.init(.{});
    var zig_scratch = Highlighter.Scratch.init();
    var zig_sink = zhl.sinks.TokenBuffer(32).init();
    const zig_line = "std.debug.print(\"value={d}\\n\", .{42});";

    _ = try zig_h.highlightLine(zig_line, Highlighter.State.initial(), &zig_scratch, &zig_sink);

    try expectTokenTextStyle(zig_line, zig_sink.slice(), "{d}", .format_placeholder);
    try expectTokenTextStyle(zig_line, zig_sink.slice(), "\\n", .escape);
    try expectTokenTextScope(zig_line, zig_sink.slice(), "{d}", .format_placeholder);
    try expectTokenTextScope(zig_line, zig_sink.slice(), "\\n", .escape);

    const Rust = zhl.Engine(grammars.rust.grammar, .{});
    var rust_h = Rust.init(.{});
    var rust_scratch = Rust.Scratch.init();
    var rust_sink = zhl.sinks.TokenBuffer(32).init();
    const rust_line = "println!(\"value={}\", answer);";

    _ = try rust_h.highlightLine(rust_line, Rust.State.initial(), &rust_scratch, &rust_sink);

    try expectTokenTextStyle(rust_line, rust_sink.slice(), "{}", .format_placeholder);
    try expectTokenTextScope(rust_line, rust_sink.slice(), "{}", .format_placeholder);
}

test "TypeScript native grammar separates aliases and primitives" {
    const Native = zhl.Engine(grammars.typescript.grammar, .{});
    var h = Native.init(.{});
    var scratch = Native.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(32).init();
    const line = "type Thing = string";

    _ = try h.highlightLine(line, Native.State.initial(), &scratch, &sink);

    try expectTokenTextStyle(line, sink.slice(), "Thing", .type_name);
    try expectTokenTextStyle(line, sink.slice(), "string", .builtin);
}

test "incremental rehighlight matches full native rehighlight after edit" {
    const lines = [_][]const u8{
        "const std = @import(\"std\");",
        "pub fn main() void {",
        "    const value = 42;",
        "    std.debug.print(\"{d}\\n\", .{value});",
        "}",
    };
    const edited = [_][]const u8{
        "const std = @import(\"std\");",
        "pub fn main() void {",
        "    var value = 100;",
        "    std.debug.print(\"{d}\\n\", .{value});",
        "}",
    };

    const Sink = zhl.sinks.TokenBuffer(128);
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var cache = zhl.document.LineCache(Highlighter.State, edited.len).init(lines.len);
    var cached = [_]Sink{Sink.init()} ** edited.len;

    _ = try cache.rehighlight(&h, &lines, 0, &scratch, &cached);
    _ = try cache.rehighlight(&h, &edited, 2, &scratch, &cached);

    var full_cache = zhl.document.LineCache(Highlighter.State, edited.len).init(edited.len);
    var full = [_]Sink{Sink.init()} ** edited.len;
    scratch = Highlighter.Scratch.init();
    _ = try full_cache.rehighlight(&h, &edited, 0, &scratch, &full);

    for (edited, 0..) |line, i| {
        try expectOrdered(line, cached[i].slice());
        try std.testing.expect(cache.states_out[i].eql(full_cache.states_out[i]));
        try expectSameTokens(cached[i].slice(), full[i].slice());
    }
}

test "tree-sitter overlay refines native Zig tokens" {
    const line = "const answer = 42;";
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var base = zhl.sinks.TokenBuffer(16).init();
    var overlaid = zhl.sinks.TokenBuffer(16).init();

    _ = try h.highlightLine(line, Highlighter.State.initial(), &scratch, &base);
    const captures = [_]zhl.tree_sitter.Capture{
        .{ .start = 6, .end = 12, .style_id = .field, .language_id = 1 },
    };
    _ = try zhl.tree_sitter.applyOverlay(base.slice(), &captures, &overlaid);

    try expectOrdered(line, overlaid.slice());
    var found = false;
    for (overlaid.slice()) |tok| {
        if (tok.start == 6 and tok.end == 12 and tok.style_id == .field and tok.language_id == 1) found = true;
    }
    try std.testing.expect(found);
}

fn hasStyle(tokens: []const zhl.Token, style_id: zhl.StyleId) bool {
    for (tokens) |tok| {
        if (tok.style_id == style_id) return true;
    }
    return false;
}

fn expectNativeStyles(comptime grammar: anytype, source: []const u8, required: []const zhl.StyleId) !void {
    const Native = zhl.Engine(grammar, .{});
    var h = Native.init(.{});
    var scratch = Native.Scratch.init();
    var state = Native.State.initial();
    var seen = [_]bool{false} ** @typeInfo(zhl.StyleId).@"enum".fields.len;

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        var sink = zhl.sinks.TokenBuffer(256).init();
        const result = try h.highlightLine(line, state, &scratch, &sink);
        state = result.end_state;
        try expectOrdered(line, sink.slice());
        for (sink.slice()) |tok| seen[@intFromEnum(tok.style_id)] = true;
    }

    for (required) |style_id| try std.testing.expect(seen[@intFromEnum(style_id)]);
}

fn expectGoldenCrc(comptime grammar: anytype, source: []const u8, expected: u32) !void {
    const Native = zhl.Engine(grammar, .{});
    var h = Native.init(.{});
    var scratch = Native.Scratch.init();
    var state = Native.State.initial();
    var buf: [64 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| : (line_no += 1) {
        var sink = zhl.sinks.TokenBuffer(512).init();
        const result = try h.highlightLine(line, state, &scratch, &sink);
        state = result.end_state;
        try expectOrdered(line, sink.slice());
        try zhl.renderers.renderDebugLine(&writer, line_no, sink.slice());
    }

    try std.testing.expectEqual(expected, std.hash.crc.Crc32.hash(buf[0..writer.end]));
}

fn expectTokenTextStyle(line: []const u8, tokens: []const zhl.Token, text: []const u8, style_id: zhl.StyleId) !void {
    for (tokens) |tok| {
        if (std.mem.eql(u8, line[tok.start..tok.end], text)) {
            try std.testing.expectEqual(style_id, tok.style_id);
            return;
        }
    }
    try std.testing.expect(false);
}

fn expectTokenTextScope(line: []const u8, tokens: []const zhl.Token, text: []const u8, scope_stack_id: zhl.ScopeStackId) !void {
    for (tokens) |tok| {
        if (std.mem.eql(u8, line[tok.start..tok.end], text)) {
            try std.testing.expectEqual(scope_stack_id, tok.scope_stack_id);
            return;
        }
    }
    try std.testing.expect(false);
}

test "deterministic fuzz bytes keep ordered bounded tokens" {
    var prng = std.Random.DefaultPrng.init(0x7a68_6c31);
    const random = prng.random();
    var h = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();

    var buf: [512]u8 = undefined;
    var n: usize = 0;
    while (n < 1000) : (n += 1) {
        const len = random.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*byte| {
            byte.* = random.int(u8);
            if (byte.* == '\n' or byte.* == '\r') byte.* = ' ';
        }

        var sink = zhl.sinks.TokenBuffer(1024).init();
        _ = try h.highlightLine(buf[0..len], Highlighter.State.initial(), &scratch, &sink);
        try expectOrdered(buf[0..len], sink.slice());
    }
}

test "deterministic fuzz native grammar parser and packer stay bounded" {
    var prng = std.Random.DefaultPrng.init(0x7a68_7061);
    const random = prng.random();
    var buf: [512]u8 = undefined;
    var packed_buf: [4096]u8 = undefined;

    var n: usize = 0;
    while (n < 500) : (n += 1) {
        const len = random.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*byte| {
            byte.* = random.intRangeLessThan(u8, 0x20, 0x7f);
            if (byte.* == '\r') byte.* = '\n';
        }

        const spec = zhl.dsl.parse(buf[0..len]) catch |err| switch (err) {
            error.TooManyRules,
            error.TooManyStringBytes,
            error.StringTooLong,
            error.MissingQuote,
            error.InvalidEscape,
            error.InvalidSyntax,
            => continue,
        };
        _ = zhl.binary.packNative(&spec, &packed_buf) catch |err| switch (err) {
            error.BufferTooSmall, error.StringTooLong => continue,
            else => return err,
        };
    }
}

fn expectOrdered(line: []const u8, tokens: []const zhl.Token) !void {
    var end: u32 = 0;
    for (tokens) |tok| {
        try std.testing.expect(tok.start >= end);
        try std.testing.expect(tok.end >= tok.start);
        try std.testing.expect(tok.end <= line.len);
        end = tok.end;
    }
}

fn expectSameTokens(a: []const zhl.Token, b: []const zhl.Token) !void {
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |left, right| try std.testing.expectEqual(left, right);
}
