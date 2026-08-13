const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.php" },
    .{ .kind = .line_comment, .value = "#", .scope = "comment.line.number-sign.php" },
    .{ .kind = .block_comment, .value = "/*", .scope = "comment.block.php", .escape = "*/" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.php", .escape = "\\" },
    .{ .kind = .string, .value = "'", .scope = "string.quoted.single.php", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.php" },
    .{ .kind = .regex, .value = "\\$[A-Za-z_][A-Za-z0-9_]*", .scope = "variable.other.php" },
    .{ .kind = .keywords, .value = "__halt_compiler abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum eval exit extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield from", .scope = "keyword.control.php" },
    .{ .kind = .keywords, .value = "bool boolean false float int integer mixed never null object parent self string true void", .scope = "storage.type.php" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.php" },
    .{ .kind = .capitalized_identifier, .value = "", .scope = "entity.name.type.php" },
    .{ .kind = .operators, .value = "-> ?-> :: ++ -- <= >= == != === !== && || += -= *= /= %= .= ?? => ...", .scope = "keyword.operator.php" },
    .{ .kind = .operators, .value = "+ - * / % = < > & | ^ ~ ! ? : ; , . { } ( ) [ ]", .scope = "keyword.operator.php" },
};

pub const name = "PHP";

pub const grammar = zhl.native_runtime.Grammar(name, "source.php", &rules){};
