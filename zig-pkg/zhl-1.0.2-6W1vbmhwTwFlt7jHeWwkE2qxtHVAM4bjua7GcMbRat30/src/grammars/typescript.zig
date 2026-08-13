const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.ts" },
    .{ .kind = .block_comment, .value = "/*", .scope = "comment.block.ts", .escape = "*/" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.ts", .escape = "\\" },
    .{ .kind = .string, .value = "'", .scope = "string.quoted.single.ts", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.ts" },
    .{ .kind = .keywords, .value = "any bigint boolean never number object string symbol unknown void", .scope = "support.type.primitive.ts" },
    .{ .kind = .keywords, .value = "abstract as async await break case catch class const constructor continue debugger", .scope = "keyword.control.ts" },
    .{ .kind = .keywords, .value = "declare default delete do else enum export extends false finally for from function get if", .scope = "keyword.control.ts" },
    .{ .kind = .keywords, .value = "implements import in infer instanceof interface keyof let module namespace new null", .scope = "keyword.control.ts" },
    .{ .kind = .keywords, .value = "of package private protected public readonly require return set static super switch", .scope = "keyword.control.ts" },
    .{ .kind = .keywords, .value = "this throw true try type typeof undefined unique var while with yield", .scope = "keyword.control.ts" },
    .{ .kind = .capitalized_identifier, .value = "", .scope = "entity.name.type.ts" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.ts" },
    .{ .kind = .operators, .value = "=== !== == != <= >= && || ?? ++ -- += -= *= /= %= ** => ... !", .scope = "keyword.operator.ts" },
    .{ .kind = .operators, .value = "+ - * / % = < > & | ^ ~ ? : ; , . { } ( ) [ ]", .scope = "keyword.operator.ts" },
};

pub const name = "TypeScript";

pub const grammar = zhl.native_runtime.Grammar(name, "source.ts", &rules){};
