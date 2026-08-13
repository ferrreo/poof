const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "#", .scope = "comment.line.number-sign.shell" },
    .{ .kind = .identifier_before, .value = "=", .scope = "variable.other.assignment.shell" },
    .{ .kind = .prefix_identifier, .value = "$", .scope = "variable.other.normal.shell" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.shell", .escape = "\\" },
    .{ .kind = .string, .value = "'", .scope = "string.quoted.single.shell", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.shell" },
    .{ .kind = .keywords, .value = "if then else elif fi for in do done while until case esac function select return continue break", .scope = "keyword.control.shell" },
    .{ .kind = .keywords, .value = "export declare typeset local readonly printf echo cd test true false", .scope = "support.function.builtin.shell" },
    .{ .kind = .operators, .value = "&& || ;; << >> <= >= == != += -= *= /= %= = !", .scope = "keyword.operator.shell" },
    .{ .kind = .operators, .value = "+ - * / % < > & | ^ ~ ? : ; , . { } ( ) [ ]", .scope = "keyword.operator.shell" },
};

pub const name = "Bash";

pub const grammar = zhl.native_runtime.Grammar(name, "source.shell", &rules){};
