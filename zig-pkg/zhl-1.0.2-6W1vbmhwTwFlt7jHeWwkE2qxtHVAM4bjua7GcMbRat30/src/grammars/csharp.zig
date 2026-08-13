const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.cs" },
    .{ .kind = .block_comment, .value = "/*", .scope = "comment.block.cs", .escape = "*/" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.cs", .escape = "\\" },
    .{ .kind = .char, .value = "'", .scope = "constant.character.cs", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.cs" },
    .{ .kind = .dotted_prefix_identifier, .value = "[", .scope = "entity.name.function.decorator.cs" },
    .{ .kind = .keywords, .value = "abstract as async await base break case catch checked class const continue default delegate do else enum event explicit extern finally fixed for foreach get global goto if implicit in interface internal is lock namespace new operator out override params partial private protected public readonly record ref return sealed set sizeof stackalloc static struct switch this throw try typeof unchecked unsafe using virtual void volatile when where while yield", .scope = "keyword.control.cs" },
    .{ .kind = .keywords, .value = "bool byte char decimal double dynamic false float int long null object sbyte short string true uint ulong ushort var", .scope = "storage.type.cs" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.cs" },
    .{ .kind = .capitalized_identifier, .value = "", .scope = "entity.name.type.cs" },
    .{ .kind = .operators, .value = "=> ?? ?. :: ++ -- <= >= == != && || << >> += -= *= /= %= &= |= ^= <<= >>= !", .scope = "keyword.operator.cs" },
    .{ .kind = .operators, .value = "+ - * / % = < > & | ^ ~ ? : ; , . { } ( ) [ ]", .scope = "keyword.operator.cs" },
};

pub const name = "C#";

pub const grammar = zhl.native_runtime.Grammar(name, "source.cs", &rules){};
