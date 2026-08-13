const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.go" },
    .{ .kind = .block_comment, .value = "/*", .scope = "comment.block.go", .escape = "*/" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.go", .escape = "\\" },
    .{ .kind = .block_comment, .value = "`", .scope = "string.quoted.raw.go", .escape = "`" },
    .{ .kind = .char, .value = "'", .scope = "constant.character.go", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.go" },
    .{ .kind = .keywords, .value = "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var", .scope = "keyword.control.go" },
    .{ .kind = .keywords, .value = "bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr", .scope = "storage.type.go" },
    .{ .kind = .keywords, .value = "true false iota nil", .scope = "constant.language.go" },
    .{ .kind = .keywords, .value = "append cap close complex copy delete imag len make new panic print println real recover", .scope = "support.function.builtin.go" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.go" },
    .{ .kind = .capitalized_identifier, .value = "", .scope = "entity.name.type.go" },
    .{ .kind = .regex, .value = "[A-Za-z_][A-Za-z0-9_]*", .scope = "variable.other.go" },
    .{ .kind = .operators, .value = ":= << >> <= >= == != += -= *= /= %= &= |= ^= &^ &^= && || <- ++ -- ! ~ & | ^ * / % + - < > = : ; , . ( ) [ ] { }", .scope = "keyword.operator.go" },
};

pub const name = "Go";

pub const grammar = zhl.native_runtime.Grammar(name, "source.go", &rules){};
