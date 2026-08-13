const std = @import("std");
const html = @import("../../src/html/source.zig");

test "document fragment and layout kinds enforce distinct structures" {
    try expectValid(
        .document,
        "<!doctype html><html><head><title>Page</title></head><body>ok</body></html>",
    );
    try expectValid(.fragment, "text<section><br><x-card></x-card></section>");
    try expectValid(
        .layout,
        "<!doctype html><html><head><title>Page</title></head>" ++
            "<body><main>{{@body}}</main></body></html>",
    );
    try expectProblem(.document, " <html></html>", .missing_document_doctype);
    try expectProblem(.fragment, "<!doctype html>", .fragment_doctype);
    try expectProblem(.fragment, "<body></body>", .fragment_document_element);
    try expectProblem(
        .document,
        "<!doctype html><html><body></body><head></head></html>",
        .document_structure,
    );
    try expectProblem(
        .document,
        "<!doctype html><html><head></head><body></body></html>x",
        .foster_parenting,
    );
    try expectProblem(
        .layout,
        "<!doctype html><html><head></head><body></body></html>",
        .missing_body_slot,
    );
    try expectProblem(
        .document,
        "<!doctype html><html><head></head><body>{{@body}}</body></html>",
        .unexpected_body_slot,
    );
}

test "head and table insertion modes admit only structure-preserving output" {
    const head_text =
        "<!doctype html><html><head>text</head><body></body></html>";
    try expectProblem(.document, head_text, .foster_parenting);
    const head_value =
        "<!doctype html><html><head>{{ view.text }}</head><body></body></html>";
    try expectProblem(.document, head_value, .directive_context);
    const root_value =
        "<!doctype html>{{ view.text }}<html><head></head><body></body></html>";
    try expectProblem(.document, root_value, .directive_context);
    try expectProblem(
        .fragment,
        "<table>{{> row view.row }}</table>",
        .directive_context,
    );
    const table_layout =
        "<!doctype html><html><head></head><body><table>{{@body}}</table></body></html>";
    try expectProblem(.layout, table_layout, .directive_context);
    try expectValid(
        .fragment,
        "<table>{{#if view.rows}}<tbody><tr><td>x</td></tr></tbody>{{/if}}</table>",
    );
}

test "strict elements require explicit nesting void rules and valid custom names" {
    const valid = [_][]const u8{
        "<DIV><span></SPAN></div>",
        "<img src=\"/logo.svg\"><input disabled>",
        "<hello-world data-value=\"1\"></hello-world>",
        "<caf\xc3\xa9-card></caf\xc3\xa9-card>",
    };
    inline for (valid) |source| try expectValid(.fragment, source);

    const cases = [_]Case{
        .{ .source = "<div>", .code = .unclosed_element },
        .{ .source = "</div>", .code = .unexpected_end_tag },
        .{ .source = "<div><span></div></span>", .code = .mismatched_end_tag },
        .{ .source = "<div/>", .code = .html_self_closing },
        .{ .source = "<br/>", .code = .html_self_closing },
        .{ .source = "<div></br></div>", .code = .void_end_tag },
        .{ .source = "<unknown></unknown>", .code = .unknown_html_element },
        .{ .source = "<No-widget></No-widget>", .code = .unknown_html_element },
        .{ .source = "<annotation-xml></annotation-xml>", .code = .unknown_html_element },
        .{ .source = "<template></template>", .code = .forbidden_html_element },
        .{ .source = "<noscript></noscript>", .code = .forbidden_html_element },
        .{ .source = "<math></math>", .code = .forbidden_html_element },
    };
    inline for (cases) |case| try expectProblem(.fragment, case.source, case.code);
}

test "attributes require separators quotes boolean names and path-aware uniqueness" {
    try expectValid(.fragment, "<input disabled required class=\"x\" title='y'>");
    try expectValid(.fragment, "<input DISABLED=\"disabled\">");
    try expectValid(
        .fragment,
        "<input{{#if view.primary}} disabled{{else}} required{{/if}}>",
    );
    try expectValid(
        .fragment,
        "<input{{#if view.primary}} class=\"a\"{{else}} class=\"b\"{{/if}}>",
    );

    const cases = [_]Case{
        .{ .source = "<div class=x></div>", .code = .unquoted_attribute },
        .{ .source = "<div class></div>", .code = .non_boolean_bare_attribute },
        .{ .source = "<div id=\"a\" ID=\"b\"></div>", .code = .duplicate_attribute },
        .{ .source = "<input disabledrequired>", .code = .non_boolean_bare_attribute },
        .{ .source = "<input disabled{{! gap }}required>", .code = .missing_attribute_separator },
        .{
            .source = "<input disabled{{#if view.x}} disabled{{/if}}>",
            .code = .duplicate_attribute,
        },
        .{
            .source = "<input{{#if view.x}} disabled disabled{{/if}}>",
            .code = .duplicate_attribute,
        },
    };
    inline for (cases) |case| try expectProblem(.fragment, case.source, case.code);
}

test "repair-dependent and foster-parented source is rejected" {
    const cases = [_][]const u8{
        "<p><div></div></p>",
        "<ul><li><li></li></li></ul>",
        "<dl><dt><dd></dd></dt></dl>",
        "<h1><h2></h2></h1>",
        "<a><a></a></a>",
        "<button><button></button></button>",
        "<form><form></form></form>",
        "<table><tr><td>x</td></tr></table>",
        "<table><div></div></table>",
        "<table>x<tbody></tbody></table>",
        "<select><div></div></select>",
        "<select><option><b></b></option></select>",
    };
    inline for (cases) |source| {
        const problem = html.diagnose(spec(.fragment, source), .{}).?;
        try std.testing.expect(
            problem.code == .repair_dependent_structure or problem.code == .foster_parenting,
        );
    }
    try expectValid(
        .fragment,
        "<table><caption>x</caption><tbody><tr><td>x</td></tr></tbody></table>",
    );
    try expectValid(.fragment, "<select><optgroup><option>x</option></optgroup></select>");
    try expectValid(
        .fragment,
        "<ul><li>outer<ul><li>inner</li></ul></li></ul>",
    );
}

test "static SVG uses an exact closed foreign-content allowlist" {
    try expectValid(
        .fragment,
        "<svg viewBox=\"0 0 10 10\" aria-label=\"ok\">" ++
            "<title>Icon</title><g><path d=\"M0 0\"/></g></svg>",
    );
    const cases = [_]Case{
        .{ .source = "<SVG></SVG>", .code = .svg_name_case },
        .{ .source = "<svg><foreignObject/></svg>", .code = .forbidden_svg_element },
        .{ .source = "<svg><script></script></svg>", .code = .forbidden_svg_element },
        .{ .source = "<svg><style></style></svg>", .code = .forbidden_svg_element },
        .{ .source = "<svg><math></math></svg>", .code = .forbidden_svg_element },
        .{ .source = "<svg><use href=\"#x\"/></svg>", .code = .forbidden_svg_element },
        .{ .source = "<svg href=\"/x\"></svg>", .code = .forbidden_svg_attribute },
        .{ .source = "<svg onload=\"x\"></svg>", .code = .forbidden_svg_attribute },
        .{ .source = "<svg style=\"x\"></svg>", .code = .forbidden_svg_attribute },
        .{ .source = "<svg>{{ view.icon }}</svg>", .code = .directive_context },
        .{ .source = "<svg><path d=\"{{ view.d }}\"/></svg>", .code = .directive_context },
        .{ .source = "<svg><path></g></svg>", .code = .mismatched_end_tag },
    };
    inline for (cases) |case| try expectProblem(.fragment, case.source, case.code);
}

const Case = struct {
    source: []const u8,
    code: html.ProblemCode,
};

fn spec(comptime kind: html.SourceKind, comptime source: []const u8) html.SourceSpec {
    return .{
        .kind = kind,
        .graph_name = "structure-tests",
        .file_path = "views/test.html",
        .bytes = source,
    };
}

fn expectValid(comptime kind: html.SourceKind, comptime source: []const u8) !void {
    try std.testing.expectEqual(@as(?html.Problem, null), html.diagnose(spec(kind, source), .{}));
}

fn expectProblem(
    comptime kind: html.SourceKind,
    comptime source: []const u8,
    expected: html.ProblemCode,
) !void {
    const problem = html.diagnose(spec(kind, source), .{}) orelse return error.ExpectedProblem;
    try std.testing.expectEqual(expected, problem.code);
    try std.testing.expect(problem.at.line >= 1);
    try std.testing.expect(problem.at.column >= 1);
    try std.testing.expect(problem.at.byte_offset <= source.len);
}
