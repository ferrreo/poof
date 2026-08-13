const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.js" },
    .{ .kind = .block_comment, .value = "/*", .scope = "comment.block.js", .escape = "*/" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.js", .escape = "\\" },
    .{ .kind = .string, .value = "'", .scope = "string.quoted.single.js", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.js" },
    .{ .kind = .keywords, .value = "async await break case catch class const continue debugger default delete do else export extends", .scope = "keyword.control.js" },
    .{ .kind = .keywords, .value = "finally for from function get if import in instanceof let new of return set static super switch", .scope = "keyword.control.js" },
    .{ .kind = .keywords, .value = "this throw try typeof var void while with yield true false null undefined", .scope = "constant.language.js" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.js" },
    .{ .kind = .capitalized_identifier, .value = "", .scope = "entity.name.type.js" },
    .{ .kind = .operators, .value = "=== !== == != <= >= && || ?? ++ -- += -= *= /= %= ** => ... !", .scope = "keyword.operator.js" },
    .{ .kind = .operators, .value = "+ - * / % = < > & | ^ ~ ? : ; , . { } ( ) [ ]", .scope = "keyword.operator.js" },
};

pub const name = "JavaScript";

pub const grammar = zhl.native_runtime.Grammar(name, "source.js", &rules){};
