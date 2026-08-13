const std = @import("std");
const html = @import("../../src/html/source.zig");

const fragment = html.SourceSpec{
    .kind = .fragment,
    .graph_name = "test-graph",
    .file_path = "views/card.html",
    .bytes = "<article class=\"card\"><h2>{{ view.title }}</h2></article>",
};

test "compiled fragment exposes exact immutable directive metadata" {
    const Compiled = html.compile(fragment, .{});
    try std.testing.expectEqual(html.SourceKind.fragment, Compiled.kind);
    try std.testing.expectEqual(@as(usize, 1), Compiled.directives.len);
    try std.testing.expectEqual(html.DirectiveKind.interpolation, Compiled.directives[0].kind);
    try std.testing.expectEqual(html.ParserContext.html_data, Compiled.directives[0].context);
    try std.testing.expectEqualStrings(
        "view.title",
        Compiled.directives[0].expression.bytes(Compiled.source),
    );
    try std.testing.expectEqual(@as(u32, 2), Compiled.element_count);
    try std.testing.expectEqual(@as(u32, 2), Compiled.maximum_element_depth);
}

test "diagnose returns source line and scalar column" {
    const problem = html.diagnose(.{
        .kind = .fragment,
        .graph_name = "test-graph",
        .file_path = "views/bad.html",
        .bytes = "caf\xc3\xa9\n<div id=\"a\" ID=\"b\"></div>",
    }, .{}).?;
    try std.testing.expectEqual(html.ProblemCode.duplicate_attribute, problem.code);
    try std.testing.expectEqual(@as(u32, 2), problem.at.line);
    try std.testing.expectEqual(@as(u32, 13), problem.at.column);
    try std.testing.expectEqual(@as(u32, 2), problem.related_at.?.line);
}
