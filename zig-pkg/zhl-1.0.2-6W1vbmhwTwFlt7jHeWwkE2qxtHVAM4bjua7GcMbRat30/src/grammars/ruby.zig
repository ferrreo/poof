const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "#", .scope = "comment.line.number-sign.ruby" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.ruby" },
    .{ .kind = .keywords, .value = "BEGIN END alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield", .scope = "keyword.control.ruby" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.ruby", .escape = "\\" },
    .{ .kind = .string, .value = "'", .scope = "string.quoted.single.ruby", .escape = "\\" },
    .{ .kind = .regex, .value = ":[A-Za-z_][A-Za-z0-9_]*[!?=]?", .scope = "constant.other.symbol.ruby" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.ruby" },
    .{ .kind = .capitalized_identifier, .value = "", .scope = "entity.name.type.ruby" },
    .{ .kind = .regex, .value = "[@$]?[A-Za-z_][A-Za-z0-9_]*[!?=]?", .scope = "variable.other.ruby" },
    .{ .kind = .operators, .value = "**= <<= >>= &&= ||= += -= *= /= %= &= |= ^= == === != =~ !~ <= >= <=> && || .. ... => :: [] []= !", .scope = "keyword.operator.ruby" },
    .{ .kind = .operators, .value = "+ - * / % = < > & | ^ ~ ? : ; , . { } ( ) [ ]", .scope = "keyword.operator.ruby" },
};

pub const name = "Ruby";

pub const grammar = zhl.native_runtime.Grammar(name, "source.ruby", &rules){};
