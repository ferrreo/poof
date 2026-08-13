const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.c" },
    .{ .kind = .block_comment, .value = "/*", .scope = "comment.block.c", .escape = "*/" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.c", .escape = "\\" },
    .{ .kind = .char, .value = "'", .scope = "constant.character.c", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.c" },
    .{ .kind = .keywords, .value = "break case continue default do else for goto if return switch while", .scope = "keyword.control.c" },
    .{ .kind = .keywords, .value = "auto const enum extern inline register restrict signed sizeof static struct typedef union", .scope = "storage.type.c" },
    .{ .kind = .keywords, .value = "unsigned volatile void char short int long float double bool true false NULL", .scope = "storage.type.c" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.c" },
    .{ .kind = .operators, .value = "-> ++ -- <= >= == != && || << >> += -= *= /= %= &= |= ^= !", .scope = "keyword.operator.c" },
    .{ .kind = .operators, .value = "+ - * / % = < > & | ^ ~ ? : ; , . { } ( ) [ ]", .scope = "keyword.operator.c" },
};

pub const name = "C";

pub const grammar = zhl.native_runtime.Grammar(name, "source.c", &rules){};
