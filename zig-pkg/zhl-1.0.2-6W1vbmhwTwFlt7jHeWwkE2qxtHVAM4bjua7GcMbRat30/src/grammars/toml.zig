const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "#", .scope = "comment.line.number-sign.toml" },
    .{ .kind = .identifier_before, .value = "]", .scope = "entity.name.section.toml" },
    .{ .kind = .quoted_key_before, .value = "=", .scope = "meta.mapping.key.toml" },
    .{ .kind = .identifier_before, .value = "=", .scope = "meta.mapping.key.toml" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.toml", .escape = "\\" },
    .{ .kind = .string, .value = "'", .scope = "string.quoted.single.toml", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.toml" },
    .{ .kind = .keywords, .value = "true false inf nan", .scope = "constant.language.toml" },
    .{ .kind = .operators, .value = "[ ] = . ,", .scope = "punctuation.separator.toml" },
};

pub const name = "TOML";

pub const grammar = zhl.native_runtime.Grammar(name, "source.toml", &rules){};
