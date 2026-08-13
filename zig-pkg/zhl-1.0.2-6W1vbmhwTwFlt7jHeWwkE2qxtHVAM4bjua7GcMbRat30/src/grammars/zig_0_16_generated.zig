const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "///", .scope = "comment.line.documentation.zig" },
    .{ .kind = .line_comment, .value = "//!", .scope = "comment.line.documentation.container.zig" },
    .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.zig" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.zig", .escape = "\\" },
    .{ .kind = .char, .value = "'", .scope = "constant.character.zig", .escape = "\\" },
    .{ .kind = .multiline_prefix, .value = "\\\\", .scope = "string.quoted.multiline.zig" },
    .{ .kind = .builtin_prefix, .value = "@", .scope = "support.function.builtin.zig" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.zig" },
    .{ .kind = .keywords, .value = "addrspace align allowzero and anyframe anytype asm break callconv catch comptime const", .scope = "keyword.control.zig" },
    .{ .kind = .keywords, .value = "continue defer else enum errdefer error export extern fn for if inline noalias opaque or", .scope = "keyword.control.zig" },
    .{ .kind = .keywords, .value = "orelse packed pub return struct switch test threadlocal try union var volatile while", .scope = "keyword.control.zig" },
    .{ .kind = .keywords, .value = "bool void noreturn type anyerror anyopaque undefined null true false", .scope = "constant.language.zig" },
    .{ .kind = .operators, .value = "<<|= >>= <<= *%= +%= -%= .* ... ** ++ +% -% *% -> << >> <= >=", .scope = "keyword.operator.zig" },
    .{ .kind = .operators, .value = "== != => || + - * / % = < > ! & | ^ ~ ? . : ; , { } ( ) [ ]", .scope = "keyword.operator.zig" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.zig" },
};

pub const name = "Zig 0.16";

pub const grammar = zhl.native_runtime.Grammar(name, "source.zig", &rules){};
