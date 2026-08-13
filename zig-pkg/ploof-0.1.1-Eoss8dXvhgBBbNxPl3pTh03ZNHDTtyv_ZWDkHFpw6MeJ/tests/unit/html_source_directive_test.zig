const std = @import("std");
const html = @import("../../src/html/source.zig");

test "fixed directive language emits complete typed metadata" {
    const source =
        "{{- view.title -}}" ++
        "{{#if view.visible}}yes{{else}}no{{/if}}" ++
        "{{#with view.user as user}}{{ user.name }}{{else}}none{{/with}}" ++
        "{{#each view.items as item, index}}{{ item.name }}{{ index }}{{else}}empty{{/each}}" ++
        "{{> card view.card }}{{ formatDate view.date view.zone }}" ++
        "{{@jsonData page-state view.state}}{{! removed }}";
    const Compiled = html.compile(spec(.fragment, source), .{});
    try std.testing.expectEqual(@as(usize, 17), Compiled.directives.len);
    try std.testing.expect(Compiled.directives[0].trim_before);
    try std.testing.expect(Compiled.directives[0].trim_after);
    try std.testing.expectEqual(html.DirectiveKind.interpolation, Compiled.directives[0].kind);
    try std.testing.expectEqual(html.DirectiveKind.if_open, Compiled.directives[1].kind);
    try std.testing.expectEqual(html.DirectiveKind.else_branch, Compiled.directives[2].kind);
    try std.testing.expectEqual(html.DirectiveKind.block_close, Compiled.directives[3].kind);
    try std.testing.expectEqual(html.DirectiveKind.with_open, Compiled.directives[4].kind);
    try std.testing.expectEqualStrings(
        "user",
        Compiled.directives[4].name.bytes(Compiled.source),
    );
    try std.testing.expectEqual(html.DirectiveKind.each_open, Compiled.directives[8].kind);
    try std.testing.expectEqualStrings(
        "index",
        Compiled.directives[8].auxiliary.bytes(Compiled.source),
    );
    try std.testing.expectEqual(html.DirectiveKind.partial, Compiled.directives[13].kind);
    try std.testing.expectEqual(html.DirectiveKind.helper, Compiled.directives[14].kind);
    try std.testing.expectEqual(@as(u32, 2), Compiled.directives[14].argument_count);
    try std.testing.expectEqual(html.DirectiveKind.json_data, Compiled.directives[15].kind);
    try std.testing.expectEqual(html.DirectiveKind.comment, Compiled.directives[16].kind);
}

test "control blocks preserve parser context on every branch" {
    const valid = [_][]const u8{
        "{{#if view.x}}<b>x</b>{{else}}<i>y</i>{{/if}}",
        "{{#with view.x as x}}<span>{{ x.name }}</span>{{else}}none{{/with}}",
        "{{#each view.x as x}}<span>{{ x.name }}</span>{{else}}none{{/each}}",
        "<div title=\"{{#if view.x}}a{{else}}b{{/if}}\"></div>",
        "<input{{#if view.x}} disabled{{else}} required{{/if}}>",
    };
    inline for (valid) |source| try expectValid(source);

    const cases = [_]Case{
        .{
            .source = "{{#if view.x}}<b>{{else}}</b>{{/if}}",
            .code = .control_context,
        },
        .{
            .source = "<div title=\"{{#if view.x}}x\">{{/if}}</div>",
            .code = .control_context,
        },
        .{
            .source = "<input{{#each view.x as x}} disabled{{/each}}>",
            .code = .each_between_attributes,
        },
        .{
            .source = "<a href=\"{{#if view.x}}{{ view.a }}{{/if}}\"></a>",
            .code = .directive_context,
        },
    };
    inline for (cases) |case| try expectProblem(case.source, case.code);
}

test "lexical locals exist only in successful with and each branches" {
    try expectValid("{{#with view.user as user}}{{ user.name }}{{/with}}");
    try expectValid("{{#each view.items as item,index}}{{ item.name }}{{ index }}{{/each}}");
    try expectProblem("{{ missing.value }}", .unknown_local);
    try expectProblem("{{#with view.user as view}}{{/with}}", .reserved_local);
    try expectProblem(
        "{{#with view.user as user}}{{else}}{{ user.name }}{{/with}}",
        .unknown_local,
    );
    try expectProblem(
        "{{#each view.items as item, index}}{{else}}{{ index }}{{/each}}",
        .unknown_local,
    );
}

test "comments and verbatim have exact trim and nesting behavior" {
    const source =
        "{{#verbatim}}<div>{{ client.value }}</div>{{/verbatim}}" ++
        "<script>{{#verbatim}}const x = '{{ client }}';{{/verbatim}}</script>";
    const Compiled = html.compile(spec(.fragment, source), .{});
    try std.testing.expectEqual(@as(usize, 4), Compiled.directives.len);
    try std.testing.expectEqual(html.DirectiveKind.verbatim_open, Compiled.directives[0].kind);
    try std.testing.expectEqual(html.DirectiveKind.verbatim_close, Compiled.directives[1].kind);
    try std.testing.expectEqual(html.ParserContext.script_text, Compiled.directives[2].context);
    try expectValid("<input disabled {{! gap }} required>");
    try expectValid("<input disabled {{-! gap }} required>");
    try expectProblem("<input disabled {{-! gap -}} required>", .missing_attribute_separator);
    try expectProblem(
        "{{#verbatim}}a{{#verbatim}}b{{/verbatim}}{{/verbatim}}",
        .nested_verbatim,
    );
    try expectProblem("{{#verbatim}}x", .unclosed_verbatim);
    try expectProblem("<svg>{{#verbatim}}x{{/verbatim}}</svg>", .directive_context);
}

test "inline asset directives are confined to matching raw-text elements" {
    const source = "<style>{{@inlineCss critical}}</style>" ++
        "<script>{{@inlineJavaScript bootstrap}}</script>";
    const Compiled = html.compile(spec(.fragment, source), .{});
    try std.testing.expectEqual(@as(usize, 2), Compiled.directives.len);
    try std.testing.expectEqual(html.DirectiveKind.inline_css, Compiled.directives[0].kind);
    try std.testing.expectEqual(html.ParserContext.style_text, Compiled.directives[0].context);
    try std.testing.expectEqual(
        html.DirectiveKind.inline_javascript,
        Compiled.directives[1].kind,
    );
    try std.testing.expectEqual(html.ParserContext.script_text, Compiled.directives[1].context);

    inline for (.{
        "{{@inlineCss critical}}",
        "<script>{{@inlineCss critical}}</script>",
        "<style>{{@inlineJavaScript bootstrap}}</style>",
        "<iframe>{{@inlineJavaScript bootstrap}}</iframe>",
    }) |invalid| try expectProblem(invalid, .directive_context);
}

test "directive grammar rejects mismatches unsupported expressions and bad arity" {
    const cases = [_]Case{
        .{ .source = "{{}}", .code = .malformed_directive },
        .{ .source = "{{ view.x", .code = .malformed_directive },
        .{ .source = "{{{ view.x }}}", .code = .unsupported_directive },
        .{ .source = "{{ view.x | escape }}", .code = .malformed_directive },
        .{ .source = "{{#if view.x}}{{/with}}", .code = .block_mismatch },
        .{ .source = "{{#if view.x}}{{else}}{{else}}{{/if}}", .code = .duplicate_else },
        .{ .source = "{{/if}}", .code = .block_mismatch },
        .{ .source = "{{#unknown view.x}}{{/unknown}}", .code = .unsupported_directive },
        .{ .source = "{{@unknown view.x}}", .code = .unsupported_directive },
        .{ .source = "{{ if view.x }}", .code = .unsupported_directive },
        .{ .source = "{{#each view.x as item,}}x{{/each}}", .code = .malformed_directive },
    };
    inline for (cases) |case| try expectProblem(case.source, case.code);
}

test "browser data names are unique non-repeating and body slots unconditional" {
    try expectValid("{{@jsonData state view.state}}");
    try expectProblem("{{@jsonData 1state view.state}}", .invalid_json_data_name);
    try expectProblem(
        "{{@jsonData state view.a}}{{@jsonData state view.b}}",
        .duplicate_json_data,
    );
    try expectProblem(
        "{{#each view.items as item}}{{@jsonData state item}}{{/each}}",
        .repeated_json_data,
    );
    const conditional_layout =
        "<!doctype html><html><head></head><body>" ++
        "{{#if view.show}}{{@body}}{{/if}}</body></html>";
    const problem = html.diagnose(spec(.layout, conditional_layout), .{}).?;
    try std.testing.expectEqual(html.ProblemCode.invalid_body_slot, problem.code);
    const duplicate_layout =
        "<!doctype html><html><head></head><body>{{@body}}{{@body}}</body></html>";
    const duplicate = html.diagnose(spec(.layout, duplicate_layout), .{}).?;
    try std.testing.expectEqual(html.ProblemCode.invalid_body_slot, duplicate.code);
}

const Case = struct {
    source: []const u8,
    code: html.ProblemCode,
};

fn spec(comptime kind: html.SourceKind, comptime source: []const u8) html.SourceSpec {
    return .{
        .kind = kind,
        .graph_name = "directive-tests",
        .file_path = "views/directives.html",
        .bytes = source,
    };
}

fn expectValid(comptime source: []const u8) !void {
    try std.testing.expectEqual(
        @as(?html.Problem, null),
        html.diagnose(spec(.fragment, source), .{}),
    );
}

fn expectProblem(comptime source: []const u8, expected: html.ProblemCode) !void {
    const problem = html.diagnose(spec(.fragment, source), .{}) orelse {
        return error.ExpectedProblem;
    };
    try std.testing.expectEqual(expected, problem.code);
}
