const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.cpp" },
    .{ .kind = .block_comment, .value = "/*", .scope = "comment.block.cpp", .escape = "*/" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.cpp", .escape = "\\" },
    .{ .kind = .char, .value = "'", .scope = "constant.character.cpp", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.cpp" },
    .{ .kind = .regex, .value = "#\\s*[A-Za-z_][A-Za-z0-9_]*", .scope = "keyword.control.directive.cpp" },
    .{ .kind = .keywords, .value = "alignas alignof asm break case catch class co_await co_return co_yield concept consteval constexpr constinit continue default delete do else enum explicit export extern for friend goto if import module namespace new noexcept operator private protected public requires return sizeof static_assert struct switch template throw try typedef typename union using virtual while", .scope = "keyword.control.cpp" },
    .{ .kind = .keywords, .value = "auto bool char char8_t char16_t char32_t const double float inline int long mutable nullptr short signed static unsigned void volatile wchar_t true false", .scope = "storage.type.cpp" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.cpp" },
    .{ .kind = .capitalized_identifier, .value = "", .scope = "entity.name.type.cpp" },
    .{ .kind = .identifier_before, .value = ".", .scope = "variable.other.field.cpp" },
    .{ .kind = .identifier_after, .value = ".", .scope = "variable.other.field.cpp" },
    .{ .kind = .operators, .value = ":: -> .* ->* ++ -- <= >= == != && || << >> += -= *= /= %= &= |= ^= <<= >>= <=> ...", .scope = "keyword.operator.cpp" },
    .{ .kind = .operators, .value = "+ - * / % = < > & | ^ ~ ! ? : ; , . { } ( ) [ ]", .scope = "keyword.operator.cpp" },
};

pub const name = "C++";

pub const grammar = zhl.native_runtime.Grammar(name, "source.cpp", &rules){};
