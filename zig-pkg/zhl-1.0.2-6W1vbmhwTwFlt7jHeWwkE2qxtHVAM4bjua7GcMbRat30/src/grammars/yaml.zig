const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "#", .scope = "comment.line.number-sign.yaml" },
    .{ .kind = .quoted_key_before, .value = ":", .scope = "meta.mapping.key.yaml" },
    .{ .kind = .identifier_before, .value = ":", .scope = "meta.mapping.key.yaml" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.yaml", .escape = "\\" },
    .{ .kind = .string, .value = "'", .scope = "string.quoted.single.yaml", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.yaml" },
    .{ .kind = .keywords, .value = "true false null yes no on off", .scope = "constant.language.yaml" },
    .{ .kind = .identifier_after, .value = ":", .scope = "string.unquoted.plain.yaml" },
    .{ .kind = .identifier_after, .value = "-", .scope = "string.unquoted.plain.yaml" },
    .{ .kind = .operators, .value = "--- ... : - [ ] { } , | >", .scope = "punctuation.separator.yaml" },
};

pub const name = "YAML";

pub const grammar = zhl.native_runtime.Grammar(name, "source.yaml", &rules){};
