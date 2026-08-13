const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.tsx" },
    .{ .kind = .block_comment, .value = "/*", .scope = "comment.block.tsx", .escape = "*/" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.tsx", .escape = "\\" },
    .{ .kind = .string, .value = "'", .scope = "string.quoted.single.tsx", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.tsx" },
    .{ .kind = .regex, .value = "</?[A-Za-z][A-Za-z0-9.:-]*", .scope = "entity.name.tag.tsx" },
    .{ .kind = .identifier_before, .value = "=", .scope = "entity.other.attribute-name.tsx" },
    .{ .kind = .keywords, .value = "abstract any as asserts async await boolean break case catch class const constructor continue debugger declare default delete do else enum export extends false finally for from function get if implements import in infer instanceof interface is keyof let module namespace never new null number object of private protected public readonly require return set static string super switch symbol this throw true try type typeof undefined unique unknown var void while with yield", .scope = "keyword.control.tsx" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.tsx" },
    .{ .kind = .capitalized_identifier, .value = "", .scope = "entity.name.type.tsx" },
    .{ .kind = .operators, .value = "=== !== == != <= >= && || ?? ++ -- += -= *= /= %= ** => ... !", .scope = "keyword.operator.tsx" },
    .{ .kind = .operators, .value = "+ - * / % = < > & | ^ ~ ? : ; , . { } ( ) [ ]", .scope = "keyword.operator.tsx" },
};

pub const name = "TSX";

pub const grammar = zhl.native_runtime.Grammar(name, "source.tsx", &rules){};
