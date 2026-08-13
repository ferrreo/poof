const std = @import("std");
const html = @import("../../src/html/source.zig");

test "plain interpolation is confined to inert classified contexts" {
    const source =
        "{{ view.body }}" ++
        "<title>{{ view.title }}</title>" ++
        "<textarea>{{ view.text }}</textarea>" ++
        "<div class=\"prefix {{ view.class }}\" title='{{ view.tip }}'></div>";
    const Compiled = html.compile(spec(source), .{});
    const expected = [_]html.ParserContext{
        .html_data,
        .title_text,
        .textarea_text,
        .attribute_inert,
        .attribute_inert,
    };
    try std.testing.expectEqual(expected.len, Compiled.directives.len);
    inline for (expected, 0..) |context, index| {
        try std.testing.expectEqual(context, Compiled.directives[index].context);
    }
}

test "URL positions carry nominal navigation asset and active-resource contexts" {
    const cases = [_]struct {
        source: []const u8,
        context: html.ParserContext,
    }{
        .{ .source = "<a href=\"{{ view.url }}\"></a>", .context = .attribute_navigation_url },
        .{
            .source = "<form action=\"{{ view.url }}\"></form>",
            .context = .attribute_navigation_url,
        },
        .{ .source = "<img src=\"{{ view.asset }}\">", .context = .attribute_image_url },
        .{
            .source = "<video poster=\"{{ view.asset }}\"></video>",
            .context = .attribute_image_url,
        },
        .{
            .source = "<table background=\"{{ view.asset }}\"></table>",
            .context = .attribute_image_url,
        },
        .{
            .source = "<script src=\"{{ view.script }}\"></script>",
            .context = .attribute_script_url,
        },
        .{
            .source = "<iframe src=\"{{ view.frame }}\"></iframe>",
            .context = .attribute_document_url,
        },
        .{
            .source = "<link rel=\"stylesheet\" href=\"{{ view.css }}\">",
            .context = .attribute_style_url,
        },
        .{
            .source = "<link rel=\"icon\" href=\"{{ view.icon }}\">",
            .context = .attribute_image_url,
        },
        .{
            .source = "<link rel=\"preload\" as=\"font\" href=\"{{ view.font }}\">",
            .context = .attribute_font_url,
        },
        .{
            .source = "<link rel=\"canonical\" href=\"{{ view.url }}\">",
            .context = .attribute_navigation_url,
        },
        .{
            .source = "<link rel=\"prefetch\" href=\"{{ view.asset }}\">",
            .context = .attribute_asset_url,
        },
        .{
            .source = "<link rel=\"manifest\" href=\"{{ view.resource }}\">",
            .context = .attribute_json_url,
        },
        .{
            .source = "<img lowsrc=\"{{ view.asset }}\">",
            .context = .attribute_image_url,
        },
        .{
            .source = "<img longdesc=\"{{ view.url }}\">",
            .context = .attribute_navigation_url,
        },
    };
    inline for (cases) |case| {
        const Compiled = html.compile(spec(case.source), .{});
        try std.testing.expectEqual(@as(usize, 1), Compiled.directives.len);
        try std.testing.expectEqual(case.context, Compiled.directives[0].context);
    }
}

test "dynamic URLs occupy one entire quoted value with static discriminators" {
    const cases = [_]Case{
        .{ .source = "<a href=\"/users/{{ view.id }}\"></a>", .code = .mixed_url_value },
        .{ .source = "<a href=\"{{ view.a }}{{ view.b }}\"></a>", .code = .mixed_url_value },
        .{ .source = "<a href=\"{{! note }}{{ view.a }}\"></a>", .code = .mixed_url_value },
        .{ .source = "<img srcset=\"{{ view.images }}\">", .code = .directive_context },
        .{ .source = "<a ping=\"{{ view.ping }}\"></a>", .code = .directive_context },
        .{ .source = "<link href=\"{{ view.css }}\">", .code = .ambiguous_url_context },
        .{
            .source = "<link rel=\"{{ view.rel }}\" href=\"{{ view.css }}\">",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<link rel=\"preload\" href=\"{{ view.asset }}\">",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<meta http-equiv=\"refresh\" content=\"{{ view.target }}\">",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<meta http-equiv=\"{{ view.kind }}\" content=\"safe\">",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<link href=\"{{view.url}}\"{{#if view.x}} " ++
                "rel=\"canonical\"{{else}} rel=\"stylesheet\"{{/if}}>",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<link href=\"{{view.url}}\"{{#if view.x}} " ++
                "rel=\"stylesheet\"{{else}} rel=\"canonical\"{{/if}}>",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<link rel=\"preload\" href=\"{{view.url}}\"{{#if view.x}} " ++
                "as=\"font\"{{else}} as=\"script\"{{/if}}>",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<link href=\"/theme.css\"{{#if view.x}} " ++
                "rel=\"canonical\"{{else}} rel=\"stylesheet\"{{/if}}>",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<link href=\"/theme.css\"{{#if view.x}} " ++
                "rel=\"stylesheet\"{{else}} rel=\"canonical\"{{/if}}>",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<link rel=\"preload\" href=\"/bundle.js\"{{#if view.x}} " ++
                "as=\"font\"{{else}} as=\"script\"{{/if}}>",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<link rel=\"preload\" href=\"/bundle.js\"{{#if view.x}} " ++
                "as=\"script\"{{else}} as=\"font\"{{/if}}>",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<meta{{#if view.x}} http-equiv=\"x\"{{else}} " ++
                "http-equiv=\"refresh\"{{/if}} content=\"{{view.target}}\">",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<meta http-equiv=\"refresh\"{{#if view.x}} content=\"safe\"" ++
                "{{else}} content=\"{{view.target}}\"{{/if}}>",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<link rel=\"style&#115;heet\" href=\"{{view.url}}\">",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<link rel=\"style&#x73;heet\" href=\"{{view.url}}\">",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<link rel=\"icon style&#x000073;heet\" href=\"{{view.url}}\">",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<link rel=\"preload\" as=\"scr&#105;pt\" href=\"{{view.url}}\">",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<meta http-equiv=\"refre&#115;h\" content=\"{{view.target}}\">",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<base href=\"{{view.base}}\">",
            .code = .directive_context,
        },
        .{
            .source = "<div itemid=\"{{view.id}}\"></div>",
            .code = .directive_context,
        },
        .{
            .source = "<div itemtype=\"{{view.types}}\"></div>",
            .code = .directive_context,
        },
        .{
            .source = "<div itemprop=\"{{view.properties}}\"></div>",
            .code = .directive_context,
        },
        .{
            .source = "<iframe sandbox=\"{{view.policy}}\"></iframe>",
            .code = .directive_context,
        },
        .{
            .source = "<meta http-equiv=\"content-security-policy\" " ++
                "content=\"{{view.policy}}\">",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<meta name=\"referrer\" content=\"{{view.policy}}\">",
            .code = .ambiguous_url_context,
        },
        .{
            .source = "<img attributionsrc=\"{{view.destinations}}\">",
            .code = .directive_context,
        },
        .{
            .source = "<script language=\"{{view.language}}\">safe()</script>",
            .code = .directive_context,
        },
        .{
            .source = "<button is=\"{{view.builtin}}\"></button>",
            .code = .directive_context,
        },
        .{
            .source = "<a href=\"/safe\" rel=\"{{view.rel}}\">safe</a>",
            .code = .directive_context,
        },
        .{
            .source = "<base target=\"{{view.target}}\">",
            .code = .directive_context,
        },
        .{
            .source = "<link rel=\"future-resource\" href=\"{{view.url}}\">",
            .code = .ambiguous_url_context,
        },
    };
    inline for (cases) |case| try expectProblem(case.source, case.code);
    try expectValid("<a href=\"/users/42\"></a>");
    try expectValid("<script src=\"https://cdn.example/app.js\"></script>");
    try expectValid("<meta http-equiv=\"refresh\" content=\"0;url=/signed-out\">");
    const Mixed = html.compile(
        spec("<link rel=\"stylesheet icon\" href=\"{{ view.asset }}\">"),
        .{},
    );
    try std.testing.expectEqual(
        html.ParserContext.attribute_style_url,
        Mixed.directives[0].context,
    );
}

test "executable and parser-sensitive positions reject ordinary directives" {
    const cases = [_]Case{
        .{ .source = "<script>const x = '{{ view.x }}';</script>", .code = .directive_context },
        .{ .source = "<style>.x{color:{{ view.color }}}</style>", .code = .directive_context },
        .{ .source = "<div onclick=\"{{ view.handler }}\"></div>", .code = .directive_context },
        .{ .source = "<div style=\"{{ view.css }}\"></div>", .code = .directive_context },
        .{ .source = "<iframe srcdoc=\"{{ view.html }}\"></iframe>", .code = .directive_context },
        .{ .source = "<div {{ view.attribute }}></div>", .code = .directive_context },
        .{ .source = "<div title={{ view.title }}></div>", .code = .unquoted_attribute },
        .{ .source = "<!-- {{ view.comment }} -->", .code = .directive_context },
        .{ .source = "<{{ view.tag }}></x-tag>", .code = .malformed_declaration },
    };
    inline for (cases) |case| try expectProblem(case.source, case.code);
    try expectValid("<script>const x = 1 < 2;</script><style>.x{color:red}</style>");
    try expectValid("<iframe>static fallback</iframe>");
}

test "raw text RCDATA comments and declarations resist boundary confusion" {
    try expectValid("<title>&lt; {{ view.title }}</title>");
    try expectValid("<textarea><b>literal</b> {{ view.text }}</textarea>");
    try expectProblem("<!-- a--b -->", .malformed_comment);
    try expectProblem("<!-- unclosed", .malformed_comment);
    const document_case = html.diagnose(.{
        .kind = .document,
        .graph_name = "context-tests",
        .file_path = "views/document.html",
        .bytes = "<!DOCTYPE html><html><head></head><body></body></html>",
    }, .{}).?;
    try std.testing.expectEqual(html.ProblemCode.missing_document_doctype, document_case.code);
    try expectProblem("<script>x</ScRiPt>tail</script>", .unexpected_end_tag);
}

const Case = struct {
    source: []const u8,
    code: html.ProblemCode,
};

fn spec(comptime source: []const u8) html.SourceSpec {
    return .{
        .kind = .fragment,
        .graph_name = "context-tests",
        .file_path = "views/context.html",
        .bytes = source,
    };
}

fn expectValid(comptime source: []const u8) !void {
    try std.testing.expectEqual(@as(?html.Problem, null), html.diagnose(spec(source), .{}));
}

fn expectProblem(comptime source: []const u8, expected: html.ProblemCode) !void {
    const problem = html.diagnose(spec(source), .{}) orelse return error.ExpectedProblem;
    try std.testing.expectEqual(expected, problem.code);
}
