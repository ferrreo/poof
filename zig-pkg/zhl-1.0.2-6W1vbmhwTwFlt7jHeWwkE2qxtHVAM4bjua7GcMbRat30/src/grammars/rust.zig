const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "///", .scope = "comment.line.documentation.rust" },
    .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.rust" },
    .{ .kind = .block_comment, .value = "/*", .scope = "comment.block.rust", .escape = "*/", .nested = true },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.rust", .escape = "\\" },
    .{ .kind = .char, .value = "'", .scope = "constant.character.rust", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.rust" },
    .{ .kind = .keywords, .value = "as async await break const continue crate dyn else enum extern false fn for if impl in", .scope = "keyword.control.rust" },
    .{ .kind = .keywords, .value = "let loop match mod move mut pub ref return self Self static struct super trait true type unsafe", .scope = "keyword.control.rust" },
    .{ .kind = .keywords, .value = "use where while i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str", .scope = "entity.name.type.numeric.rust" },
    .{ .kind = .identifier_before, .value = "!", .scope = "entity.name.function.macro.rust" },
    .{ .kind = .capitalized_identifier, .value = "", .scope = "entity.name.type.rust" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.rust" },
    .{ .kind = .operators, .value = ":: -> => .. ..= && || <= >= == != += -= *= /= %= &= |= ^= <<= >>= !", .scope = "keyword.operator.rust" },
    .{ .kind = .operators, .value = "+ - * / % = < > & | ^ ~ ? : ; , . { } ( ) [ ]", .scope = "keyword.operator.rust" },
};

pub const name = "Rust";

pub const grammar = zhl.native_runtime.Grammar(name, "source.rust", &rules){};
