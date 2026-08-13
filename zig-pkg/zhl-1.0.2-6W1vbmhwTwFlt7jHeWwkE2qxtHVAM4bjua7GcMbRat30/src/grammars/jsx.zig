const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.jsx" },
    .{ .kind = .block_comment, .value = "/*", .scope = "comment.block.jsx", .escape = "*/" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.jsx", .escape = "\\" },
    .{ .kind = .string, .value = "'", .scope = "string.quoted.single.jsx", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.jsx" },
    .{ .kind = .regex, .value = "</?[A-Za-z][A-Za-z0-9.:-]*", .scope = "entity.name.tag.jsx" },
    .{ .kind = .identifier_before, .value = "=", .scope = "entity.other.attribute-name.jsx" },
    .{ .kind = .keywords, .value = "async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield true false null undefined", .scope = "keyword.control.jsx" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.jsx" },
    .{ .kind = .capitalized_identifier, .value = "", .scope = "entity.name.type.jsx" },
    .{ .kind = .operators, .value = "=== !== == != <= >= && || ?? ++ -- += -= *= /= %= ** => ... !", .scope = "keyword.operator.jsx" },
    .{ .kind = .operators, .value = "+ - * / % = < > & | ^ ~ ? : ; , . { } ( ) [ ]", .scope = "keyword.operator.jsx" },
};

pub const name = "JSX";

pub const grammar = zhl.native_runtime.Grammar(name, "source.jsx", &rules){};
