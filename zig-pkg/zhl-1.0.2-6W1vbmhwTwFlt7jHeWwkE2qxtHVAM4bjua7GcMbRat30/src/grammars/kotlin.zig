const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.kotlin" },
    .{ .kind = .block_comment, .value = "/*", .scope = "comment.block.kotlin", .escape = "*/", .nested = true },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.kotlin", .escape = "\\" },
    .{ .kind = .delimited, .value = "\"\"\"\n\"\"\"", .scope = "string.quoted.triple.kotlin", .escape = "\\" },
    .{ .kind = .char, .value = "'", .scope = "constant.character.kotlin", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.kotlin" },
    .{ .kind = .dotted_prefix_identifier, .value = "@", .scope = "entity.name.function.decorator.kotlin" },
    .{ .kind = .regex, .value = "\\$[A-Za-z_][A-Za-z0-9_]*", .scope = "variable.other.kotlin" },
    .{ .kind = .identifier_before, .value = ":", .scope = "variable.parameter.kotlin" },
    .{ .kind = .keywords, .value = "as break by catch class companion constructor continue data do dynamic else enum expect external false field file finally for fun get if import in init inline inner interface internal is lateinit noinline null object open operator out override package private protected public reified return sealed set super suspend tailrec this throw true try typealias val var vararg when where while", .scope = "keyword.control.kotlin" },
    .{ .kind = .keywords, .value = "Any Boolean Byte Char Double Float Int Long Nothing Short String Unit UInt ULong UShort", .scope = "storage.type.kotlin" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.kotlin" },
    .{ .kind = .capitalized_identifier, .value = "", .scope = "entity.name.type.kotlin" },
    .{ .kind = .operators, .value = "?. ?: !! -> => .. :: ++ -- <= >= == != === !== && || += -= *= /= %= !", .scope = "keyword.operator.kotlin" },
    .{ .kind = .operators, .value = "+ - * / % = < > & | ^ ~ ? : ; , . { } ( ) [ ]", .scope = "keyword.operator.kotlin" },
};

pub const name = "Kotlin";

pub const grammar = zhl.native_runtime.Grammar(name, "source.kotlin", &rules){};
