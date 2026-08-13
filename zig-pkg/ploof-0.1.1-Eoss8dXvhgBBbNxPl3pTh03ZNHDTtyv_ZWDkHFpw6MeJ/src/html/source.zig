const std = @import("std");
const parser = @import("../internal/html/source_parser.zig");
const types = @import("../internal/html/source_types.zig");

pub const SourceKind = types.SourceKind;
pub const TemplateSourceProfile = types.TemplateSourceProfile;
pub const SourceSpec = types.SourceSpec;
pub const Position = types.Position;
pub const SourceRange = types.SourceRange;
pub const Region = types.Region;
pub const ParserContext = types.ParserContext;
pub const DirectiveKind = types.DirectiveKind;
pub const Directive = types.Directive;
pub const ProblemCode = types.ProblemCode;
pub const Problem = types.Problem;

pub fn diagnose(
    comptime spec: SourceSpec,
    comptime profile: TemplateSourceProfile,
) ?Problem {
    @setEvalBranchQuota(100_000_000);
    return parser.analyze(spec, profile).problem;
}

pub fn compile(
    comptime spec: SourceSpec,
    comptime profile: TemplateSourceProfile,
) type {
    @setEvalBranchQuota(100_000_000);
    const analysis = parser.analyze(spec, profile);
    if (analysis.problem) |problem| @compileError(diagnostic(spec, problem));
    const exact_directives = analysis.directives[0..analysis.directive_count].*;
    return struct {
        pub const ploof_compiled_html_source = true;
        pub const kind = spec.kind;
        pub const graph_name = spec.graph_name;
        pub const file_path = spec.file_path;
        pub const source = spec.bytes;
        pub const source_profile = profile;
        pub const directives = exact_directives;
        pub const element_count = analysis.element_count;
        pub const maximum_element_depth = analysis.maximum_element_depth;
        pub const maximum_control_depth = analysis.maximum_control_depth;
    };
}

pub fn diagnosticCode(code: ProblemCode) u16 {
    return 3800 + @as(u16, @intFromEnum(code));
}

fn diagnostic(comptime spec: SourceSpec, comptime problem: Problem) []const u8 {
    const related = if (problem.related_at) |position|
        std.fmt.comptimePrint(
            "; related line {d}, column {d}",
            .{ position.line, position.column },
        )
    else
        "";
    const limits = if (problem.limit != 0)
        std.fmt.comptimePrint(
            "; actual {d}, configured limit {d}",
            .{ problem.actual, problem.limit },
        )
    else
        "";
    return std.fmt.comptimePrint(
        "PLOOF-E{d} HTML source {s}; graph '{s}', file '{s}', " ++
            "line {d}, column {d}{s}{s}",
        .{
            diagnosticCode(problem.code),
            @tagName(problem.code),
            spec.graph_name,
            spec.file_path,
            problem.at.line,
            problem.at.column,
            related,
            limits,
        },
    );
}
