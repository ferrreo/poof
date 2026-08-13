const std = @import("std");
const zhl = @import("zhl");
const grammars = @import("zhl_grammars");

pub const line_bytes_max = 8 * 1024;
pub const tokens_per_line_max = 256;

pub const Error = std.Io.Writer.Error;

pub fn renderFence(
    writer: *std.Io.Writer,
    code: []const u8,
    language_name: []const u8,
) Error!void {
    const metadata = grammars.findByName(language_name);
    try writer.writeAll("<pre class=\"code-block\"><code");
    if (metadata) |language| {
        try writer.print(" data-language=\"{s}\">", .{language.canonical});
        return switch (language.id) {
            .bash => renderGrammar(writer, code, grammars.bash.grammar),
            .c => renderGrammar(writer, code, grammars.c.grammar),
            .cpp => renderGrammar(writer, code, grammars.cpp.grammar),
            .csharp => renderGrammar(writer, code, grammars.csharp.grammar),
            .css => renderGrammar(writer, code, grammars.css.grammar),
            .go => renderGrammar(writer, code, grammars.go.grammar),
            .html => renderGrammar(writer, code, grammars.html.grammar),
            .java => renderGrammar(writer, code, grammars.java.grammar),
            .javascript => renderGrammar(writer, code, grammars.javascript.grammar),
            .jsx => renderGrammar(writer, code, grammars.jsx.grammar),
            .json => renderGrammar(writer, code, grammars.json.grammar),
            .kotlin => renderGrammar(writer, code, grammars.kotlin.grammar),
            .log => renderGrammar(writer, code, grammars.log.grammar),
            .markdown => renderGrammar(writer, code, grammars.markdown.grammar),
            .php => renderGrammar(writer, code, grammars.php.grammar),
            .python => renderGrammar(writer, code, grammars.python.grammar),
            .ruby => renderGrammar(writer, code, grammars.ruby.grammar),
            .rust => renderGrammar(writer, code, grammars.rust.grammar),
            .sql => renderGrammar(writer, code, grammars.sql.grammar),
            .swift => renderGrammar(writer, code, grammars.swift.grammar),
            .toml => renderGrammar(writer, code, grammars.toml.grammar),
            .tsx => renderGrammar(writer, code, grammars.tsx.grammar),
            .typescript => renderGrammar(writer, code, grammars.typescript.grammar),
            .xml => renderGrammar(writer, code, grammars.xml.grammar),
            .yaml => renderGrammar(writer, code, grammars.yaml.grammar),
            .zig => renderGrammar(writer, code, grammars.zig_0_16.grammar),
        };
    }
    try writer.writeAll(">");
    try escapeHtml(writer, code);
    try writer.writeAll("</code></pre>");
}

fn renderGrammar(writer: *std.Io.Writer, code: []const u8, comptime grammar: anytype) Error!void {
    const Highlighter = zhl.Engine(grammar, .{
        .max_stack_depth = 32,
        .max_dynamic_capture_bytes = 128,
        .max_regex_vm_stack = 512,
        .max_capture_slots = 64,
        .max_line_bytes = line_bytes_max,
        .max_tokens_per_line = tokens_per_line_max,
    });
    var highlighter = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var state = Highlighter.State.initial();
    var lines = std.mem.splitScalar(u8, code, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try writer.writeByte('\n');
        first = false;
        var sink = zhl.sinks.TokenBuffer(tokens_per_line_max).init();
        const result = highlighter.highlightLine(line, state, &scratch, &sink) catch {
            state = Highlighter.State.initial();
            try escapeHtml(writer, line);
            continue;
        };
        state = result.end_state;
        try zhl.renderers.renderHtmlLine(writer, line, sink.slice());
    }
    try writer.writeAll("</code></pre>");
}

pub fn escapeHtml(writer: *std.Io.Writer, value: []const u8) Error!void {
    for (value) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(byte),
        }
    }
}

test "known Zig fences use zhl spans and escape source" {
    var storage: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try renderFence(&writer, "const value = \"<&\";", "zig");
    const output = storage[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "data-language=\"zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zhl-keyword") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "&lt;&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<&") == null);
}

test "unknown fences are escaped without token markup" {
    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try renderFence(&writer, "<script>alert(1)</script>", "unknown");
    const output = storage[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zhl-") == null);
}
