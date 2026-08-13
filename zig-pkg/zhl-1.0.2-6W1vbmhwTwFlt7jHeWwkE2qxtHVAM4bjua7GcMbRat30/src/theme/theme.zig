const std = @import("std");
const style = @import("style.zig");

pub const Rgb = packed struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const TextStyle = struct {
    foreground: ?Rgb = null,
    background: ?Rgb = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};

pub const ThemeRule = struct {
    scope: []const u8,
    style: TextStyle,
};

pub const CompiledTheme = struct {
    styles: [style_count]TextStyle = [_]TextStyle{.{}} ** style_count,
    set: [style_count]bool = [_]bool{false} ** style_count,

    pub fn styleFor(self: *const CompiledTheme, id: style.StyleId) TextStyle {
        return self.styles[@intFromEnum(id)];
    }

    pub fn setCount(self: *const CompiledTheme) usize {
        var count: usize = 0;
        for (self.set) |is_set| {
            if (is_set) count += 1;
        }
        return count;
    }
};

const style_count = @typeInfo(style.StyleId).@"enum".fields.len;

pub fn compile(rules: []const ThemeRule) CompiledTheme {
    var out = CompiledTheme{};
    for (rules) |rule| {
        applyScope(&out, rule.scope, rule.style);
    }
    return out;
}

pub fn styleIdForScope(scope: []const u8) ?style.StyleId {
    inline for (@typeInfo(style.StyleId).@"enum".fields) |field| {
        const id: style.StyleId = @enumFromInt(field.value);
        if (scopeMatches(scope, id.scope())) return id;
    }
    return null;
}

pub fn compileJson(allocator: std.mem.Allocator, source: []const u8) !CompiledTheme {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.MalformedTheme,
    };
    const token_colors = switch (root.get("tokenColors") orelse return CompiledTheme{}) {
        .array => |array| array.items,
        else => return error.MalformedTheme,
    };

    var out = CompiledTheme{};
    for (token_colors) |entry_value| {
        const entry = switch (entry_value) {
            .object => |object| object,
            else => continue,
        };
        const settings = switch (entry.get("settings") orelse continue) {
            .object => |object| object,
            else => return error.MalformedTheme,
        };
        const text_style = try parseSettings(settings);
        if (entry.get("scope")) |scope_value| try applyScopeValue(&out, scope_value, text_style);
    }
    return out;
}

fn applyScopeValue(out: *CompiledTheme, value: std.json.Value, text_style: TextStyle) !void {
    switch (value) {
        .string => |scope_list| applyScopeList(out, scope_list, text_style),
        .array => |array| for (array.items) |item| switch (item) {
            .string => |scope_list| applyScopeList(out, scope_list, text_style),
            else => return error.MalformedTheme,
        },
        else => return error.MalformedTheme,
    }
}

pub fn applyScopeList(out: *CompiledTheme, scope_list: []const u8, text_style: TextStyle) void {
    var it = std.mem.splitScalar(u8, scope_list, ',');
    while (it.next()) |raw_scope| {
        const scope = selectorScope(raw_scope);
        if (scope.len != 0) applyScope(out, scope, text_style);
    }
}

fn selectorScope(raw_scope: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_scope, " \t\r\n");
    if (std.mem.lastIndexOfScalar(u8, trimmed, ' ')) |index| {
        return std.mem.trim(u8, trimmed[index + 1 ..], " \t\r\n");
    }
    return trimmed;
}

fn parseSettings(settings: std.json.ObjectMap) !TextStyle {
    const foreground = if (settings.get("foreground")) |value| valueString(value) orelse return error.MalformedTheme else null;
    const background = if (settings.get("background")) |value| valueString(value) orelse return error.MalformedTheme else null;
    const font_style = if (settings.get("fontStyle")) |value| valueString(value) orelse return error.MalformedTheme else null;
    return textStyleFromStrings(foreground, background, font_style);
}

pub fn textStyleFromStrings(foreground: ?[]const u8, background: ?[]const u8, font_style: ?[]const u8) !TextStyle {
    var out = TextStyle{};
    if (foreground) |value| out.foreground = try parseRgb(value);
    if (background) |value| out.background = try parseRgb(value);
    if (font_style) |value| applyFontStyle(&out, value);
    return out;
}

fn applyFontStyle(out: *TextStyle, font_style: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, font_style, ' ');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "bold")) out.bold = true;
        if (std.mem.eql(u8, part, "italic")) out.italic = true;
        if (std.mem.eql(u8, part, "underline")) out.underline = true;
    }
}

fn applyScope(out: *CompiledTheme, scope: []const u8, text_style: TextStyle) void {
    inline for (@typeInfo(style.StyleId).@"enum".fields) |field| {
        const id: style.StyleId = @enumFromInt(field.value);
        if (scopeMatches(scope, id.scope())) {
            const index = @intFromEnum(id);
            out.styles[index] = text_style;
            out.set[index] = true;
        }
    }
}

fn scopeMatches(rule_scope: []const u8, token_scope: []const u8) bool {
    return std.mem.eql(u8, rule_scope, token_scope) or std.mem.startsWith(u8, token_scope, rule_scope);
}

pub fn rgb(comptime hex: []const u8) Rgb {
    if (hex.len != 7 or hex[0] != '#') @compileError("expected #rrggbb");
    return .{
        .r = parseHexByte(hex[1], hex[2]),
        .g = parseHexByte(hex[3], hex[4]),
        .b = parseHexByte(hex[5], hex[6]),
    };
}

pub fn parseRgb(hex: []const u8) !Rgb {
    if (hex.len != 7 or hex[0] != '#') return error.MalformedTheme;
    return .{
        .r = try parseHexByteRuntime(hex[1], hex[2]),
        .g = try parseHexByteRuntime(hex[3], hex[4]),
        .b = try parseHexByteRuntime(hex[5], hex[6]),
    };
}

fn parseHexByte(comptime hi: u8, comptime lo: u8) u8 {
    return (hexNibble(hi) << 4) | hexNibble(lo);
}

fn parseHexByteRuntime(hi: u8, lo: u8) !u8 {
    return (try hexNibbleRuntime(hi) << 4) | try hexNibbleRuntime(lo);
}

fn hexNibble(comptime byte: u8) u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => @compileError("invalid hex digit"),
    };
}

fn hexNibbleRuntime(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.MalformedTheme,
    };
}

fn valueString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

test "theme compiler resolves scopes to style ids" {
    const compiled = compile(&.{
        .{ .scope = "keyword.control", .style = .{ .foreground = rgb("#ff00aa"), .bold = true } },
        .{ .scope = "string.quoted.double.zig", .style = .{ .foreground = rgb("#00ff00") } },
    });

    try std.testing.expect(compiled.set[@intFromEnum(style.StyleId.keyword)]);
    try std.testing.expect(compiled.set[@intFromEnum(style.StyleId.string)]);
    try std.testing.expect(compiled.styleFor(.keyword).bold);
}

test "VS Code theme JSON resolves token colors" {
    const source =
        \\{
        \\  "tokenColors": [
        \\    {"scope": "keyword.control", "settings": {"foreground": "#ff00aa", "fontStyle": "bold italic"}},
        \\    {"scope": ["string.quoted.double.zig", "comment.line"], "settings": {"foreground": "#00ff00", "fontStyle": "underline"}},
        \\    {"scope": "source.zig keyword.operator.zig", "settings": {"foreground": "#112233"}}
        \\  ]
        \\}
    ;

    const compiled = try compileJson(std.testing.allocator, source);
    try std.testing.expectEqual(@as(usize, 6), compiled.setCount());
    try std.testing.expect(compiled.styleFor(.keyword).bold);
    try std.testing.expect(compiled.styleFor(.keyword).italic);
    try std.testing.expect(compiled.styleFor(.string).underline);
    try std.testing.expect(compiled.styleFor(.comment).underline);
    try std.testing.expectEqual(Rgb{ .r = 0x11, .g = 0x22, .b = 0x33 }, compiled.styleFor(.operator).foreground.?);
}

test "theme JSON rejects malformed colors" {
    try std.testing.expectError(error.MalformedTheme, compileJson(std.testing.allocator,
        \\{"tokenColors":[{"scope":"keyword.control","settings":{"foreground":"red"}}]}
    ));
}
