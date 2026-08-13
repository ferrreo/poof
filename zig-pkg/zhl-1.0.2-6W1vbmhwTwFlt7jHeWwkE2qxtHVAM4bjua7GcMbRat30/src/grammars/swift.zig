const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "//", .scope = "comment.line.double-slash.swift" },
    .{ .kind = .block_comment, .value = "/*", .scope = "comment.block.swift", .escape = "*/", .nested = true },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.swift", .escape = "\\" },
    .{ .kind = .marker_string, .value = "#", .scope = "string.quoted.double.swift", .escape = "\"#" },
    .{ .kind = .char, .value = "'", .scope = "constant.character.swift", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.swift" },
    .{ .kind = .dotted_prefix_identifier, .value = "@", .scope = "entity.name.function.decorator.swift" },
    .{ .kind = .regex, .value = "#[A-Za-z_][A-Za-z0-9_]*", .scope = "keyword.other.directive.swift" },
    .{ .kind = .keywords, .value = "associatedtype borrowing break case catch class consuming continue default defer deinit do else enum extension fallthrough for func guard if import in init inout internal is isolated let mutating nil nonisolated open operator private protocol public rethrows return self Self static struct subscript super switch throw throws try typealias var where while", .scope = "keyword.control.swift" },
    .{ .kind = .keywords, .value = "Any Bool Character Double Error Float Int Never Optional String UInt Void false true", .scope = "storage.type.swift" },
    .{ .kind = .function_call, .value = "", .scope = "entity.name.function.swift" },
    .{ .kind = .capitalized_identifier, .value = "", .scope = "entity.name.type.swift" },
    .{ .kind = .operators, .value = "-> => ... ..< ...? ?? ?. ++ -- <= >= == != === !== && || += -= *= /= %= &= |= ^= !", .scope = "keyword.operator.swift" },
    .{ .kind = .operators, .value = "+ - * / % = < > & | ^ ~ ? : ; , . { } ( ) [ ]", .scope = "keyword.operator.swift" },
};

pub const name = "Swift";

pub const grammar = zhl.native_runtime.Grammar(name, "source.swift", &rules){};
