const std = @import("std");
const html = @import("../../src/html/source.zig");

test "standard source profile matches every ADR 0119 bound" {
    const profile = html.TemplateSourceProfile{};
    try std.testing.expectEqual(@as(u32, 256 * 1024), profile.source_bytes_max);
    try std.testing.expectEqual(@as(u32, 2 * 1024 * 1024), profile.graph_source_bytes_max);
    try std.testing.expectEqual(@as(u32, 128), profile.html_element_depth_max);
    try std.testing.expectEqual(@as(u32, 32), profile.template_control_depth_max);
    try std.testing.expectEqual(@as(u32, 32), profile.partial_call_depth_max);
    try std.testing.expectEqual(@as(u32, 16_384), profile.directives_max);
    try std.testing.expectEqual(@as(u32, 16), profile.field_path_components_max);
    try std.testing.expectEqual(@as(u32, 8), profile.helper_arguments_max);
}

test "source and graph byte limits accept exact boundaries and report overflow" {
    const exact = html.TemplateSourceProfile{
        .source_bytes_max = 8,
        .graph_source_bytes_max = 8,
    };
    try expectValid("12345678", exact);
    const source_problem = problem("123456789", .{
        .source_bytes_max = 8,
        .graph_source_bytes_max = 16,
    });
    try std.testing.expectEqual(html.ProblemCode.source_too_long, source_problem.code);
    try std.testing.expectEqual(@as(u32, 9), source_problem.actual);
    try std.testing.expectEqual(@as(u32, 8), source_problem.limit);
    try std.testing.expectEqual(@as(u32, 9), source_problem.at.column);

    const graph_problem = problem("123456789", .{
        .source_bytes_max = 16,
        .graph_source_bytes_max = 8,
    });
    try std.testing.expectEqual(html.ProblemCode.graph_source_too_long, graph_problem.code);
    try std.testing.expectEqual(@as(u32, 9), graph_problem.actual);
    try std.testing.expectEqual(@as(u32, 8), graph_problem.limit);
}

test "standard per-source byte boundary is exact" {
    const exact = "x" ** (256 * 1024);
    try expectValid(exact, .{});
    const excess = exact ++ "x";
    const result = problem(excess, .{});
    try std.testing.expectEqual(html.ProblemCode.source_too_long, result.code);
    try std.testing.expectEqual(@as(u32, 256 * 1024 + 1), result.actual);
    try std.testing.expectEqual(@as(u32, 256 * 1024), result.limit);
}

test "element control and directive limits fail on first excess item" {
    try expectValid("<div><span></span></div>", .{ .html_element_depth_max = 2 });
    const element = problem("<div><span></span></div>", .{ .html_element_depth_max = 1 });
    try std.testing.expectEqual(html.ProblemCode.html_depth_limit, element.code);
    try std.testing.expectEqual(@as(u32, 2), element.actual);
    try std.testing.expectEqual(@as(u32, 1), element.limit);

    const nested = "{{#if view.a}}{{#if view.b}}x{{/if}}{{/if}}";
    try expectValid(nested, .{ .template_control_depth_max = 2 });
    const control = problem(nested, .{ .template_control_depth_max = 1 });
    try std.testing.expectEqual(html.ProblemCode.control_depth_limit, control.code);
    try std.testing.expectEqual(@as(u32, 2), control.actual);
    try std.testing.expectEqual(@as(u32, 1), control.limit);

    try expectValid("{{ view.a }}{{ view.b }}", .{ .directives_max = 2 });
    const directive = problem("{{ view.a }}{{ view.b }}", .{ .directives_max = 1 });
    try std.testing.expectEqual(html.ProblemCode.directive_limit, directive.code);
    try std.testing.expectEqual(@as(u32, 2), directive.actual);
    try std.testing.expectEqual(@as(u32, 1), directive.limit);
}

test "standard depth directive field and helper boundaries are exact" {
    const elements = "<div>" ** 128 ++ "</div>" ** 128;
    try expectValid(elements, .{});
    const element_problem = problem(elements, .{ .html_element_depth_max = 127 });
    try std.testing.expectEqual(html.ProblemCode.html_depth_limit, element_problem.code);

    const controls = "{{#if view.x}}" ** 32 ++ "{{/if}}" ** 32;
    try expectValid(controls, .{});
    const control_problem = problem(controls, .{ .template_control_depth_max = 31 });
    try std.testing.expectEqual(html.ProblemCode.control_depth_limit, control_problem.code);

    const directive_source = "{{!}}" ** 16_384;
    try expectValid(directive_source, .{});
    const directive_problem = problem(directive_source ++ "{{!}}", .{});
    try std.testing.expectEqual(html.ProblemCode.directive_limit, directive_problem.code);

    const field = "{{ view" ++ ".a" ** 15 ++ " }}";
    try expectValid(field, .{});
    const field_problem = problem("{{ view" ++ ".a" ** 16 ++ " }}", .{});
    try std.testing.expectEqual(html.ProblemCode.field_path_limit, field_problem.code);

    const helper = "{{ helper" ++ " view.a" ** 8 ++ " }}";
    try expectValid(helper, .{});
    const helper_problem = problem("{{ helper" ++ " view.a" ** 9 ++ " }}", .{});
    try std.testing.expectEqual(html.ProblemCode.helper_argument_limit, helper_problem.code);
}

test "field and helper bounds count exact grammar components" {
    try expectValid("{{ view.value }}", .{ .field_path_components_max = 2 });
    const field = problem("{{ view.value }}", .{ .field_path_components_max = 1 });
    try std.testing.expectEqual(html.ProblemCode.field_path_limit, field.code);
    try std.testing.expectEqual(@as(u32, 2), field.actual);
    try std.testing.expectEqual(@as(u32, 1), field.limit);

    try expectValid("{{ helper view.a }}", .{ .helper_arguments_max = 1 });
    const helper = problem(
        "{{ helper view.a view.b }}",
        .{ .helper_arguments_max = 1 },
    );
    try std.testing.expectEqual(html.ProblemCode.helper_argument_limit, helper.code);
    try std.testing.expectEqual(@as(u32, 2), helper.actual);
    try std.testing.expectEqual(@as(u32, 1), helper.limit);
}

test "every configurable profile limit is finite and nonzero" {
    const profiles = [_]html.TemplateSourceProfile{
        .{ .source_bytes_max = 0 },
        .{ .graph_source_bytes_max = 0 },
        .{ .html_element_depth_max = 0 },
        .{ .template_control_depth_max = 0 },
        .{ .partial_call_depth_max = 0 },
        .{ .directives_max = 0 },
        .{ .field_path_components_max = 0 },
        .{ .helper_arguments_max = 0 },
    };
    inline for (profiles) |profile| {
        const result = problem("x", profile);
        try std.testing.expectEqual(html.ProblemCode.profile_limit_zero, result.code);
        try std.testing.expectEqual(@as(u32, 1), result.at.line);
        try std.testing.expectEqual(@as(u32, 1), result.at.column);
    }
}

test "encoding failures identify deterministic first offending byte positions" {
    const invalid = problem("ok\nx\xff", .{});
    try std.testing.expectEqual(html.ProblemCode.invalid_utf8, invalid.code);
    try std.testing.expectEqual(@as(u32, 4), invalid.at.byte_offset);
    try std.testing.expectEqual(@as(u32, 2), invalid.at.line);
    try std.testing.expectEqual(@as(u32, 2), invalid.at.column);

    const truncated = problem("x\xe2\x82", .{});
    try std.testing.expectEqual(html.ProblemCode.invalid_utf8, truncated.code);
    try std.testing.expectEqual(@as(u32, 1), truncated.at.byte_offset);

    const bom = problem("\xef\xbb\xbf<div></div>", .{});
    try std.testing.expectEqual(html.ProblemCode.byte_order_mark, bom.code);
    try std.testing.expectEqual(@as(u32, 0), bom.at.byte_offset);

    const nul = problem("ok\n\x00", .{});
    try std.testing.expectEqual(html.ProblemCode.nul_byte, nul.code);
    try std.testing.expectEqual(@as(u32, 3), nul.at.byte_offset);
    try std.testing.expectEqual(@as(u32, 2), nul.at.line);
}

test "diagnostic columns count Unicode scalars and CRLF as one line break" {
    const duplicate = problem("caf\xc3\xa9\r\n<div id=\"a\" ID=\"b\"></div>", .{});
    try std.testing.expectEqual(html.ProblemCode.duplicate_attribute, duplicate.code);
    try std.testing.expectEqual(@as(u32, 2), duplicate.at.line);
    try std.testing.expectEqual(@as(u32, 13), duplicate.at.column);
    try std.testing.expectEqual(@as(u32, 2), duplicate.related_at.?.line);
    try std.testing.expect(html.diagnosticCode(.duplicate_attribute) >= 3800);
    try std.testing.expect(
        html.diagnosticCode(.duplicate_attribute) != html.diagnosticCode(.unquoted_attribute),
    );
}

fn spec(comptime source: []const u8) html.SourceSpec {
    return .{
        .kind = .fragment,
        .graph_name = "limit-tests",
        .file_path = "views/limits.html",
        .bytes = source,
    };
}

fn expectValid(
    comptime source: []const u8,
    comptime profile: html.TemplateSourceProfile,
) !void {
    try std.testing.expectEqual(
        @as(?html.Problem, null),
        html.diagnose(spec(source), profile),
    );
}

fn problem(
    comptime source: []const u8,
    comptime profile: html.TemplateSourceProfile,
) html.Problem {
    return html.diagnose(spec(source), profile).?;
}
