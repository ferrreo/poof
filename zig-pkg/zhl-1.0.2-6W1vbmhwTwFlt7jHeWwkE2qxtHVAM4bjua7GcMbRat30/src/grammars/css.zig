const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .block_comment, .value = "/*", .scope = "comment.block.css", .escape = "*/" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.css", .escape = "\\" },
    .{ .kind = .string, .value = "'", .scope = "string.quoted.single.css", .escape = "\\" },
    .{ .kind = .regex, .value = "@[a-zA-Z][a-zA-Z0-9-]*", .scope = "keyword.control.at-rule.css" },
    .{ .kind = .regex, .value = "!important", .scope = "keyword.other.important.css" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.css" },
    .{ .kind = .identifier_before, .value = ":", .scope = "support.type.property-name.css" },
    .{ .kind = .function_call, .value = "", .scope = "support.function.css" },
    .{ .kind = .keywords, .value = "inherit initial unset revert none auto block inline flex grid", .scope = "keyword.other.css" },
    .{ .kind = .operators, .value = "{ } ( ) [ ] : ; , > + ~ = * /", .scope = "punctuation.css" },
    .{ .kind = .operators, .value = ". # ", .scope = "punctuation.css" },
    .{ .kind = .regex, .value = "[a-zA-Z_][a-zA-Z0-9_-]*", .scope = "entity.name.tag.css" },
};

pub const name = "CSS";

pub const grammar = zhl.native_runtime.Grammar(name, "source.css", &rules){};
