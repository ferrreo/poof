const std = @import("std");
const capability = @import("../internal/html/value_capability.zig");
const html_source = @import("source.zig");
const inline_text = @import("../inline_text.zig");
const json = @import("../json.zig");

pub const trusted_html_bytes_hard_max: u32 = 1024 * 1024;

pub const Error = error{
    BoundExceeded,
    InvalidUtf8,
    UnknownEnumTag,
};

pub const EscapeContext = enum(u2) {
    html_data,
    rcdata,
    attribute_double_quoted,
    attribute_single_quoted,
};

pub const AttributeQuote = enum(u1) {
    double,
    single,
};

pub const BrowserJsonOptions = struct {
    encoded_bytes_max: usize = json.standard_encoded_bytes_max,
    max_depth: u16 = 64,

    fn validate(comptime options: BrowserJsonOptions) BrowserJsonOptions {
        _ = json.Options.validate(.{
            .encoded_bytes_max = options.encoded_bytes_max,
            .max_depth = options.max_depth,
        });
        return options;
    }
};

pub fn writeText(writer: anytype, input: []const u8) !void {
    return writeEscaped(writer, .html_data, input);
}

pub fn writeRcData(writer: anytype, input: []const u8) !void {
    return writeEscaped(writer, .rcdata, input);
}

pub fn writeAttribute(
    writer: anytype,
    comptime quote: AttributeQuote,
    input: []const u8,
) !void {
    const context: EscapeContext = switch (quote) {
        .double => .attribute_double_quoted,
        .single => .attribute_single_quoted,
    };
    return writeEscaped(writer, context, input);
}

pub fn writeValue(
    writer: anytype,
    comptime context: EscapeContext,
    value: anytype,
) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => return writer.write(if (value) "true" else "false"),
        .int => return writeInteger(writer, value),
        .comptime_int => {
            const Fitting = std.math.IntFittingRange(value, value);
            return writeInteger(writer, @as(Fitting, value));
        },
        .@"enum" => return writeEnum(writer, context, value),
        .array => |info| {
            if (info.child != u8) unsupportedTextType(T);
            return writeEscaped(writer, context, value[0..]);
        },
        .pointer => |info| {
            if (info.size != .slice or info.child != u8) unsupportedTextType(T);
            return writeEscaped(writer, context, value);
        },
        .@"struct" => {
            if (comptime isInlineText(T)) {
                return writeInlineText(writer, context, value);
            } else if (comptime @hasDecl(T, "formatText")) {
                return writeFormatted(writer, context, value);
            } else {
                unsupportedTextType(T);
            }
        },
        else => unsupportedTextType(T),
    }
}

pub fn TrustedHtml(comptime bytes_max: u32) type {
    if (bytes_max == 0) {
        @compileError("PLOOF-E3901 TrustedHtml byte limit must be nonzero");
    }
    if (bytes_max > trusted_html_bytes_hard_max) {
        @compileError("PLOOF-E3902 TrustedHtml byte limit exceeds 1 MiB");
    }
    return struct {
        _borrowed: []const u8,

        pub const ploof_trusted_html = true;
        pub const bytes_maximum = bytes_max;
        const Self = @This();

        pub fn literal(comptime input: []const u8) Self {
            if (input.len > bytes_max) {
                @compileError("PLOOF-E3903 TrustedHtml literal exceeds its byte limit");
            }
            validateHtmlLiteral(input);
            return .{ ._borrowed = input };
        }

        /// Borrows application-sanitized markup. Misuse can cause XSS.
        /// Caller owns sanitizer policy, balance, lifetime, and insertion-context safety.
        pub fn unsafeAssumeSanitized(input: []const u8) Error!Self {
            if (input.len > bytes_max) return error.BoundExceeded;
            return .{ ._borrowed = input };
        }

        fn validatedBytes(value: Self) Error![]const u8 {
            if (value._borrowed.len > bytes_max) return error.BoundExceeded;
            if (!std.unicode.utf8ValidateSlice(value._borrowed)) return error.InvalidUtf8;
            return value._borrowed;
        }
    };
}

pub fn writeTrustedHtml(writer: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    comptime validateTrustedHtmlType(T);
    const bytes = try value.validatedBytes();
    return writer.write(bytes);
}

pub fn writeBrowserJson(
    comptime options_requested: BrowserJsonOptions,
    writer: anytype,
    comptime static_name: []const u8,
    value: anytype,
    scratch: []u8,
) !void {
    const options = comptime options_requested.validate();
    comptime validateStaticName(static_name);
    defer std.crypto.secureZero(u8, scratch);
    const encoded = try json.encodeWith(.{
        .encoded_bytes_max = options.encoded_bytes_max,
        .max_depth = options.max_depth,
        .html_safe = true,
    }, value, scratch);
    const opening = "<script type=\"application/json\" id=\"" ++ static_name ++ "\">";
    try writer.write(opening);
    try writer.write(encoded);
    return writer.write("</script>");
}

pub fn writeStaticSvg(writer: anytype, comptime source: []const u8) !void {
    comptime validateStaticSvg(source);
    return writer.write(source);
}

fn writeEscaped(
    writer: anytype,
    comptime context: EscapeContext,
    input: []const u8,
) !void {
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    var start: usize = 0;
    while (firstEscapable(context, input, start)) |index| {
        if (index != start) try writer.write(input[start..index]);
        try writer.write(replacement(context, input[index]));
        start = index + 1;
    }
    if (start != input.len) try writer.write(input[start..]);
}

fn firstEscapable(
    comptime context: EscapeContext,
    input: []const u8,
    start: usize,
) ?usize {
    const lanes = 32;
    const Bytes = @Vector(lanes, u8);
    var index = start;
    while (index + lanes <= input.len) : (index += lanes) {
        const bytes: Bytes = input[index..][0..lanes].*;
        var matches = (bytes == @as(Bytes, @splat('&'))) |
            (bytes == @as(Bytes, @splat('<'))) |
            (bytes == @as(Bytes, @splat('>')));
        if (context == .attribute_double_quoted) {
            matches |= bytes == @as(Bytes, @splat('"'));
        }
        if (context == .attribute_single_quoted) {
            matches |= bytes == @as(Bytes, @splat('\''));
        }
        if (@reduce(.Or, matches)) return index + std.simd.firstTrue(matches).?;
    }
    while (index < input.len) : (index += 1) {
        if (needsEscape(context, input[index])) return index;
    }
    return null;
}

fn needsEscape(comptime context: EscapeContext, byte: u8) bool {
    return byte == '&' or byte == '<' or byte == '>' or
        (context == .attribute_double_quoted and byte == '"') or
        (context == .attribute_single_quoted and byte == '\'');
}

fn replacement(comptime context: EscapeContext, byte: u8) []const u8 {
    return switch (byte) {
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => if (context == .attribute_double_quoted) "&quot;" else unreachable,
        '\'' => if (context == .attribute_single_quoted) "&#39;" else unreachable,
        else => unreachable,
    };
}

fn writeInteger(writer: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    const bits = @typeInfo(T).int.bits;
    const bytes_max = @as(usize, bits) * 302 / 1000 + 2;
    var storage: [bytes_max]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&storage);
    fixed.print("{d}", .{value}) catch unreachable;
    return writer.write(fixed.buffered());
}

fn writeEnum(writer: anytype, comptime context: EscapeContext, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T).@"enum";
    if (!info.is_exhaustive) {
        inline for (info.fields) |field| {
            if (value == @field(T, field.name)) {
                return writeEscaped(writer, context, field.name);
            }
        }
        return error.UnknownEnumTag;
    }
    return writeEscaped(writer, context, @tagName(value));
}

fn writeInlineText(writer: anytype, comptime context: EscapeContext, value: anytype) !void {
    const bytes = value.bytes() catch |problem| switch (problem) {
        error.InvalidUtf8 => return error.InvalidUtf8,
        error.TooLong => return error.BoundExceeded,
    };
    return writeEscaped(writer, context, bytes);
}

fn writeFormatted(writer: anytype, comptime context: EscapeContext, value: anytype) !void {
    const T = @TypeOf(value);
    const Return = comptime validateFormatText(T);
    switch (@typeInfo(Return)) {
        .error_union => {
            const formatted = try value.formatText();
            return writeInlineText(writer, context, formatted);
        },
        else => {
            const formatted = value.formatText();
            return writeInlineText(writer, context, formatted);
        },
    }
}

fn validateFormatText(comptime T: type) type {
    if (capability.carries(T)) {
        @compileError("PLOOF-E3914 formatText self carries a mutable or framework capability");
    }
    const function = @TypeOf(@field(T, "formatText"));
    const info = switch (@typeInfo(function)) {
        .@"fn" => |function_info| function_info,
        else => @compileError("PLOOF-E3904 formatText must be a function"),
    };
    if (info.is_var_args or capability.hasComptimeParameter(function) or
        info.params.len != 1 or info.params[0].type == null or info.params[0].type.? != T)
    {
        @compileError("PLOOF-E3905 formatText requires one concrete self value");
    }
    const Return = info.return_type orelse {
        @compileError("PLOOF-E3906 formatText requires an explicit return type");
    };
    const Payload = switch (@typeInfo(Return)) {
        .error_union => |error_union| block: {
            if (@typeInfo(error_union.error_set).error_set == null) {
                @compileError("PLOOF-E3907 formatText requires a finite error set");
            }
            break :block error_union.payload;
        },
        else => Return,
    };
    if (!isInlineText(Payload)) {
        @compileError("PLOOF-E3908 formatText must return InlineText(N)");
    }
    return Return;
}

fn isInlineText(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "ploof_inline_text") or
        !@hasDecl(T, "bytes_maximum")) return false;
    const marker = @field(T, "ploof_inline_text");
    if (@TypeOf(marker) != bool) return false;
    if (!marker) return false;
    const maximum = @field(T, "bytes_maximum");
    switch (@typeInfo(@TypeOf(maximum))) {
        .int, .comptime_int => {},
        else => return false,
    }
    return maximum > 0 and maximum <= inline_text.bytes_hard_max and
        T == inline_text.InlineText(@intCast(maximum));
}

fn validateTrustedHtmlType(comptime T: type) void {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "ploof_trusted_html") or
        !@hasDecl(T, "bytes_maximum"))
    {
        @compileError("PLOOF-E3909 raw HTML requires TrustedHtml(N)");
    }
    const marker = @field(T, "ploof_trusted_html");
    if (@TypeOf(marker) != bool) {
        @compileError("PLOOF-E3909 raw HTML requires TrustedHtml(N)");
    }
    if (!marker) {
        @compileError("PLOOF-E3909 raw HTML requires TrustedHtml(N)");
    }
    const maximum = @field(T, "bytes_maximum");
    switch (@typeInfo(@TypeOf(maximum))) {
        .int, .comptime_int => {},
        else => @compileError("PLOOF-E3909 raw HTML requires TrustedHtml(N)"),
    }
    if (maximum <= 0 or maximum > trusted_html_bytes_hard_max or
        T != TrustedHtml(@intCast(maximum)))
    {
        @compileError("PLOOF-E3909 raw HTML requires TrustedHtml(N)");
    }
}

fn validateHtmlLiteral(comptime input: []const u8) void {
    const limit: u32 = @intCast(@max(input.len, 1));
    const Compiled = html_source.compile(.{
        .kind = .fragment,
        .graph_name = "TrustedHtml.literal",
        .file_path = "<comptime>",
        .bytes = input,
    }, .{
        .source_bytes_max = limit,
        .graph_source_bytes_max = limit,
    });
    if (Compiled.directives.len != 0) {
        @compileError("PLOOF-E3910 TrustedHtml literal cannot contain directives");
    }
}

fn validateStaticName(comptime name: []const u8) void {
    if (name.len == 0 or !asciiLetter(name[0])) {
        @compileError("PLOOF-E3911 browser JSON name must start with an ASCII letter");
    }
    for (name[1..]) |byte| {
        if (!asciiLetter(byte) and !std.ascii.isDigit(byte) and byte != '-' and byte != '_') {
            @compileError("PLOOF-E3912 browser JSON name contains an invalid byte");
        }
    }
}

fn validateStaticSvg(comptime source: []const u8) void {
    const trimmed = std.mem.trim(u8, source, " \t\n\r\x0c");
    if (!hasSvgEnvelope(trimmed)) {
        @compileError("PLOOF-E3913 static SVG must be an svg element");
    }
    const Compiled = html_source.compile(.{
        .kind = .fragment,
        .graph_name = "StaticSvg",
        .file_path = "<comptime>",
        .bytes = source,
    }, .{});
    if (Compiled.directives.len != 0) {
        @compileError("PLOOF-E3914 static SVG cannot contain directives");
    }
}

fn hasSvgEnvelope(source: []const u8) bool {
    if (!std.mem.startsWith(u8, source, "<svg")) return false;
    if (source.len < 5 or
        (source[4] != '>' and source[4] != '/' and !htmlSpace(source[4]))) return false;
    return std.mem.endsWith(u8, source, "</svg>") or
        (std.mem.endsWith(u8, source, "/>") and
            std.mem.findScalar(u8, source, '>') == source.len - 1);
}

fn asciiLetter(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
}

fn htmlSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == '\x0c';
}

fn unsupportedTextType(comptime T: type) noreturn {
    @compileError("PLOOF-E3915 unsupported template text type '" ++ @typeName(T) ++ "'");
}

comptime {
    std.debug.assert(trusted_html_bytes_hard_max > inline_text.bytes_hard_max);
}
