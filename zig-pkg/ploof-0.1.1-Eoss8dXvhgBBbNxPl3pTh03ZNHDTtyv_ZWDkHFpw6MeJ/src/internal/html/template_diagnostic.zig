const std = @import("std");
const html_source = @import("../../html/source.zig");

pub const Code = enum(u8) {
    invalid_config = 1,
    invalid_view,
    invalid_helpers,
    invalid_partials,
    unknown_field,
    non_struct_path,
    if_not_bool,
    with_not_optional,
    each_not_collection,
    unknown_helper,
    invalid_helper,
    helper_argument_mismatch,
    helper_anyerror,
    invalid_output_type,
    unknown_partial,
    invalid_partial,
    partial_view_mismatch,
    partial_cycle,
    partial_depth,
    invalid_writer,
    invalid_render_kind,
    invalid_layout_body,
    graph_source_limit,
    invalid_attribute_quote,
    duplicate_browser_json,
    repeated_browser_json,
    graph_node_limit,
    graph_edge_limit,
    browser_json_limit,
    reserved_application_error,
    invalid_assets,
    invalid_inline_asset,
};

pub fn number(code: Code) u16 {
    return 4000 + @as(u16, @intFromEnum(code));
}

pub fn fail(
    comptime code: Code,
    comptime Source: type,
    comptime offset: usize,
    comptime detail: []const u8,
) noreturn {
    const at = position(Source.source, offset);
    @compileError(std.fmt.comptimePrint(
        "PLOOF-E{d} HTML template {s}; graph '{s}', file '{s}', " ++
            "line {d}, column {d}; {s}",
        .{
            number(code),
            @tagName(code),
            Source.graph_name,
            Source.file_path,
            at.line,
            at.column,
            detail,
        },
    ));
}

pub fn failSpec(
    comptime code: Code,
    comptime spec: html_source.SourceSpec,
    comptime offset: usize,
    comptime detail: []const u8,
) noreturn {
    const at = position(spec.bytes, offset);
    @compileError(std.fmt.comptimePrint(
        "PLOOF-E{d} HTML template {s}; graph '{s}', file '{s}', " ++
            "line {d}, column {d}; {s}",
        .{
            number(code),
            @tagName(code),
            spec.graph_name,
            spec.file_path,
            at.line,
            at.column,
            detail,
        },
    ));
}

pub fn failConfig(comptime code: Code, comptime detail: []const u8) noreturn {
    @compileError(std.fmt.comptimePrint(
        "PLOOF-E{d} HTML template {s}; graph '<config>', file '<config>', " ++
            "line 1, column 1; {s}",
        .{ number(code), @tagName(code), detail },
    ));
}

const LineColumn = struct { line: usize = 1, column: usize = 1 };

fn position(source: []const u8, requested: usize) LineColumn {
    var result = LineColumn{};
    var index: usize = 0;
    const end = @min(source.len, requested);
    while (index < end) : (index += 1) {
        if (source[index] == '\r') {
            if (index + 1 < end and source[index + 1] == '\n') index += 1;
            result.line += 1;
            result.column = 1;
        } else if (source[index] == '\n') {
            result.line += 1;
            result.column = 1;
        } else if (source[index] & 0xc0 != 0x80) {
            result.column += 1;
        }
    }
    return result;
}
