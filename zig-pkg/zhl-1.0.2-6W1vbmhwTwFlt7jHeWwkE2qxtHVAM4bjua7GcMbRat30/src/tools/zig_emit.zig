const std = @import("std");
const zhl = @import("zhl");

pub fn nativeModule(writer: *std.Io.Writer, spec: *const zhl.dsl.NativeSpec) !void {
    try writer.writeAll(
        \\const zhl = @import("zhl");
        \\
    );
    try writer.writeAll("const rules = [_]zhl.native_runtime.Rule{\n");
    for (spec.ruleSlice()) |rule| {
        try writer.print("    .{{ .kind = .{s}, .value = ", .{@tagName(rule.kind)});
        try zigString(writer, spec.slice(rule.value));
        try writer.writeAll(", .scope = ");
        try zigString(writer, spec.slice(rule.scope));
        if (rule.escape.len != 0) {
            try writer.writeAll(", .escape = ");
            try zigString(writer, spec.slice(rule.escape));
        }
        if (rule.nested) try writer.writeAll(", .nested = true");
        try writer.writeAll(" },\n");
    }
    try writer.writeAll("};\n\npub const name = ");
    try zigString(writer, spec.slice(spec.name));
    try writer.writeAll(";\n\npub const grammar = zhl.native_runtime.Grammar(name, ");
    try zigString(writer, spec.slice(spec.root_scope));
    try writer.writeAll(", &rules){};\n");
}

pub fn themeModule(writer: *std.Io.Writer, compiled: zhl.theme.CompiledTheme) !void {
    try writer.writeAll(
        \\const zhl = @import("zhl");
        \\
        \\pub const theme = zhl.theme.CompiledTheme{
        \\    .styles = .{
        \\
    );
    inline for (@typeInfo(zhl.StyleId).@"enum".fields) |field| {
        const id: zhl.StyleId = @enumFromInt(field.value);
        try writer.writeAll("        ");
        try textStyle(writer, compiled.styleFor(id));
        try writer.writeAll(",\n");
    }
    try writer.writeAll(
        \\    },
        \\    .set = .{
        \\
    );
    inline for (@typeInfo(zhl.StyleId).@"enum".fields) |field| {
        try writer.print("        {},\n", .{compiled.set[field.value]});
    }
    try writer.writeAll(
        \\    },
        \\};
        \\
    );
}

fn textStyle(writer: *std.Io.Writer, style: zhl.theme.TextStyle) !void {
    try writer.writeAll(".{ ");
    if (style.foreground) |value| {
        try writer.print(".foreground = .{{ .r = {d}, .g = {d}, .b = {d} }}, ", .{ value.r, value.g, value.b });
    }
    if (style.background) |value| {
        try writer.print(".background = .{{ .r = {d}, .g = {d}, .b = {d} }}, ", .{ value.r, value.g, value.b });
    }
    if (style.bold) try writer.writeAll(".bold = true, ");
    if (style.italic) try writer.writeAll(".italic = true, ");
    if (style.underline) try writer.writeAll(".underline = true, ");
    try writer.writeAll("}");
}

fn zigString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11...12, 14...31, 127 => try writeHexEscape(writer, byte),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn writeHexEscape(writer: *std.Io.Writer, byte: u8) !void {
    const hex = "0123456789abcdef";
    try writer.writeAll("\\x");
    try writer.writeByte(hex[byte >> 4]);
    try writer.writeByte(hex[byte & 0xf]);
}

test "native compiler emits static Zig grammar module" {
    const spec = try zhl.dsl.parse(
        \\grammar "source.test" {
        \\  name "Test";
        \\  scope root = "source.test";
        \\  context main {
        \\    line_comment "//" scope "comment.line.test";
        \\    regex_vm "\x01abc" scope "keyword.control.test";
        \\  }
        \\}
    );
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try nativeModule(&writer, &spec);
    const generated = buf[0..writer.end];

    try std.testing.expect(std.mem.indexOf(u8, generated, "zhl.native_runtime.Rule") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".kind = .line_comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "\\x01abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const name") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const grammar") != null);
}

test "theme compiler emits static Zig theme module" {
    const compiled = zhl.theme.compile(&.{
        .{ .scope = "keyword.control", .style = .{ .foreground = zhl.theme.rgb("#ff00aa"), .bold = true } },
    });
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try themeModule(&writer, compiled);
    const generated = buf[0..writer.end];

    try std.testing.expect(std.mem.indexOf(u8, generated, "zhl.theme.CompiledTheme") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".foreground") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".bold = true") != null);
}
