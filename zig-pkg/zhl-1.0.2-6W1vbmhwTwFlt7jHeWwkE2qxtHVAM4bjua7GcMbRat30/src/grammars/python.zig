const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "#", .scope = "comment.line.number-sign.python" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.python", .escape = "\\" },
    .{ .kind = .string, .value = "'", .scope = "string.quoted.single.python", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.python" },
    .{ .kind = .keywords, .value = "and as assert async await break class continue def del elif else except False finally", .scope = "keyword.control.python" },
    .{ .kind = .keywords, .value = "for from global if import in is lambda None nonlocal not or pass raise return True", .scope = "keyword.control.python" },
    .{ .kind = .keywords, .value = "try while with yield match case self cls", .scope = "keyword.control.python" },
    .{ .kind = .dotted_prefix_identifier, .value = "@", .scope = "entity.name.function.decorator.python" },
    .{ .kind = .identifier_before, .value = ")", .scope = "variable.parameter.python" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.python" },
    .{ .kind = .capitalized_identifier, .value = "", .scope = "entity.name.type.python" },
    .{ .kind = .operators, .value = "//= **= == != <= >= += -= *= /= %= &= |= ^= <<= >>= -> := //", .scope = "keyword.operator.python" },
    .{ .kind = .operators, .value = "+ - * / % = < > & | ^ ~ ? : ; , . { } ( ) [ ]", .scope = "keyword.operator.python" },
};

pub const name = "Python";

pub const grammar = zhl.native_runtime.Grammar(name, "source.python", &rules){};
