const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.java" },
    .{ .kind = .block_comment, .value = "/*", .scope = "comment.block.java", .escape = "*/" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.java", .escape = "\\" },
    .{ .kind = .char, .value = "'", .scope = "constant.character.java", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.java" },
    .{ .kind = .dotted_prefix_identifier, .value = "@", .scope = "entity.name.function.decorator.java" },
    .{ .kind = .keywords, .value = "abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized this throw throws transient try volatile while yield record sealed permits", .scope = "keyword.control.java" },
    .{ .kind = .keywords, .value = "boolean byte char double false float int long null short true var void", .scope = "storage.type.java" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.java" },
    .{ .kind = .capitalized_identifier, .value = "", .scope = "entity.name.type.java" },
    .{ .kind = .operators, .value = "-> :: ++ -- <= >= == != && || << >> >>> += -= *= /= %= &= |= ^= <<= >>= >>>= !", .scope = "keyword.operator.java" },
    .{ .kind = .operators, .value = "+ - * / % = < > & | ^ ~ ? : ; , . { } ( ) [ ]", .scope = "keyword.operator.java" },
};

pub const name = "Java";

pub const grammar = zhl.native_runtime.Grammar(name, "source.java", &rules){};
