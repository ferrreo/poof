const std = @import("std");

pub const StyleId = enum(u16) {
    plain = 0,
    comment,
    doc_comment,
    container_doc_comment,
    string,
    multiline_string,
    char,
    escape,
    format_placeholder,
    number_integer,
    number_float,
    keyword,
    operator,
    builtin,
    function,
    type_name,
    parameter,
    field,
    label,
    punctuation,
    invalid,

    pub fn ansi(self: StyleId) []const u8 {
        return switch (self) {
            .plain => "\x1b[0m",
            .comment, .doc_comment, .container_doc_comment => "\x1b[90m",
            .string, .multiline_string, .char => "\x1b[32m",
            .escape => "\x1b[33m",
            .format_placeholder => "\x1b[31m",
            .number_integer, .number_float => "\x1b[36m",
            .keyword => "\x1b[35m",
            .operator, .punctuation => "\x1b[37m",
            .builtin => "\x1b[33m",
            .function => "\x1b[34m",
            .type_name => "\x1b[94m",
            .parameter => "\x1b[36m",
            .field => "\x1b[96m",
            .label => "\x1b[95m",
            .invalid => "\x1b[41m",
        };
    }

    pub fn cssClass(self: StyleId) []const u8 {
        return switch (self) {
            .plain => "zhl-plain",
            .comment => "zhl-comment",
            .doc_comment => "zhl-doc-comment",
            .container_doc_comment => "zhl-container-doc-comment",
            .string => "zhl-string",
            .multiline_string => "zhl-multiline-string",
            .char => "zhl-char",
            .escape => "zhl-escape",
            .format_placeholder => "zhl-format-placeholder",
            .number_integer => "zhl-number-integer",
            .number_float => "zhl-number-float",
            .keyword => "zhl-keyword",
            .operator => "zhl-operator",
            .builtin => "zhl-builtin",
            .function => "zhl-function",
            .type_name => "zhl-type-name",
            .parameter => "zhl-parameter",
            .field => "zhl-field",
            .label => "zhl-label",
            .punctuation => "zhl-punctuation",
            .invalid => "zhl-invalid",
        };
    }

    pub fn scope(self: StyleId) []const u8 {
        return switch (self) {
            .plain => "source.zig",
            .comment => "comment.line.double-slash.zig",
            .doc_comment => "comment.line.documentation.zig",
            .container_doc_comment => "comment.line.documentation.container.zig",
            .string => "string.quoted.double.zig",
            .multiline_string => "string.quoted.multiline.zig",
            .char => "constant.character.zig",
            .escape => "constant.character.escape.zig",
            .format_placeholder => "constant.other.placeholder.zig",
            .number_integer => "constant.numeric.integer.zig",
            .number_float => "constant.numeric.float.zig",
            .keyword => "keyword.control.zig",
            .operator => "keyword.operator.zig",
            .builtin => "support.function.builtin.zig",
            .function => "entity.name.function.zig",
            .type_name => "entity.name.type.zig",
            .parameter => "variable.parameter.zig",
            .field => "variable.other.field.zig",
            .label => "entity.name.label.zig",
            .punctuation => "punctuation.separator.zig",
            .invalid => "invalid.illegal.zig",
        };
    }
};

pub const ScopeStackId = enum(u16) {
    none = 0,
    source_zig,
    comment,
    doc_comment,
    container_doc_comment,
    string,
    multiline_string,
    char,
    escape,
    format_placeholder,
    number,
    keyword,
    operator,
    builtin,
    function,
    type_name,
    parameter,
    field,
    label,
    punctuation,
    invalid,
};

pub fn scopeStackForStyle(style_id: StyleId) ScopeStackId {
    return switch (style_id) {
        .plain => .source_zig,
        .comment => .comment,
        .doc_comment => .doc_comment,
        .container_doc_comment => .container_doc_comment,
        .string => .string,
        .multiline_string => .multiline_string,
        .char => .char,
        .escape => .escape,
        .format_placeholder => .format_placeholder,
        .number_integer, .number_float => .number,
        .keyword => .keyword,
        .operator => .operator,
        .builtin => .builtin,
        .function => .function,
        .type_name => .type_name,
        .parameter => .parameter,
        .field => .field,
        .label => .label,
        .punctuation => .punctuation,
        .invalid => .invalid,
    };
}

pub fn styleFromScope(scope: []const u8) StyleId {
    if (std.mem.indexOf(u8, scope, "meta.mapping.key") != null) return .field;
    var rest = scope;
    var chosen: StyleId = .plain;
    while (std.mem.lastIndexOfScalar(u8, rest, ' ')) |space| {
        const part = rest[space + 1 ..];
        const resolved = styleFromSingleScope(part);
        if (resolved != .plain) return resolved;
        rest = rest[0..space];
    }
    chosen = styleFromSingleScope(rest);
    if (chosen != .plain) return chosen;
    return .plain;
}

fn styleFromSingleScope(scope: []const u8) StyleId {
    if (std.mem.startsWith(u8, scope, "comment.line.documentation.container")) return .container_doc_comment;
    if (std.mem.startsWith(u8, scope, "comment.line.documentation")) return .doc_comment;
    if (std.mem.startsWith(u8, scope, "comment.block.documentation")) return .doc_comment;
    if (std.mem.startsWith(u8, scope, "comment.")) return .comment;
    if (std.mem.startsWith(u8, scope, "punctuation.definition.comment")) return .comment;
    if (std.mem.startsWith(u8, scope, "punctuation.definition.interpolation")) return .format_placeholder;
    if (std.mem.startsWith(u8, scope, "string.quoted.multiline")) return .multiline_string;
    if (std.mem.startsWith(u8, scope, "string.")) return .string;
    if (std.mem.startsWith(u8, scope, "constant.character.escape")) return .escape;
    if (std.mem.startsWith(u8, scope, "constant.other.placeholder")) return .format_placeholder;
    if (std.mem.startsWith(u8, scope, "constant.other.format")) return .format_placeholder;
    if (std.mem.startsWith(u8, scope, "constant.numeric.float")) return .number_float;
    if (std.mem.startsWith(u8, scope, "constant.numeric")) return .number_integer;
    if (std.mem.startsWith(u8, scope, "constant.character")) return .char;
    if (std.mem.startsWith(u8, scope, "constant.other")) return .char;
    if (std.mem.startsWith(u8, scope, "constant.language")) return .keyword;
    if (std.mem.startsWith(u8, scope, "keyword.operator")) return .operator;
    if (std.mem.startsWith(u8, scope, "keyword.")) return .keyword;
    if (std.mem.startsWith(u8, scope, "storage.")) return .keyword;
    if (std.mem.startsWith(u8, scope, "meta.export")) return .keyword;
    if (std.mem.startsWith(u8, scope, "meta.function")) return .function;
    if (std.mem.startsWith(u8, scope, "meta.type")) return .type_name;
    if (std.mem.startsWith(u8, scope, "support.function")) return .builtin;
    if (std.mem.startsWith(u8, scope, "support.type.primitive")) return .builtin;
    if (std.mem.indexOf(u8, scope, ".built-in") != null) return .builtin;
    if (std.mem.startsWith(u8, scope, "support.type")) return .type_name;
    if (std.mem.startsWith(u8, scope, "support.class")) return .type_name;
    if (std.mem.startsWith(u8, scope, "entity.name.function")) return .function;
    if (std.mem.startsWith(u8, scope, "entity.name.command")) return .function;
    if (std.mem.startsWith(u8, scope, "entity.name.type.numeric")) return .builtin;
    if (std.mem.startsWith(u8, scope, "entity.name.type")) return .type_name;
    if (std.mem.startsWith(u8, scope, "entity.name.class")) return .type_name;
    if (std.mem.startsWith(u8, scope, "entity.name.struct")) return .type_name;
    if (std.mem.startsWith(u8, scope, "entity.name.enum")) return .type_name;
    if (std.mem.startsWith(u8, scope, "entity.name.section")) return .field;
    if (std.mem.startsWith(u8, scope, "entity.name.tag")) return .field;
    if (std.mem.startsWith(u8, scope, "variable.language")) return .keyword;
    if (std.mem.startsWith(u8, scope, "variable.string")) return .string;
    if (std.mem.startsWith(u8, scope, "variable.parameter")) return .parameter;
    if (std.mem.startsWith(u8, scope, "variable.other.field")) return .field;
    if (std.mem.startsWith(u8, scope, "variable.other")) return .field;
    if (std.mem.startsWith(u8, scope, "entity.name.label")) return .label;
    if (std.mem.startsWith(u8, scope, "punctuation.")) return .punctuation;
    if (std.mem.startsWith(u8, scope, "invalid.")) return .invalid;
    return .plain;
}

test "style resolver maps common TextMate scopes" {
    try std.testing.expectEqual(StyleId.doc_comment, styleFromScope("comment.line.documentation.zig"));
    try std.testing.expectEqual(StyleId.doc_comment, styleFromScope("comment.block.documentation.json"));
    try std.testing.expectEqual(StyleId.operator, styleFromScope("keyword.operator.zig"));
    try std.testing.expectEqual(StyleId.function, styleFromScope("entity.name.function.zig"));
    try std.testing.expectEqual(StyleId.punctuation, styleFromScope("punctuation.separator.zig"));
    try std.testing.expectEqual(StyleId.comment, styleFromScope("punctuation.definition.comment.c"));
    try std.testing.expectEqual(StyleId.escape, styleFromScope("constant.character.escape.c"));
    try std.testing.expectEqual(StyleId.format_placeholder, styleFromScope("constant.other.placeholder.c"));
    try std.testing.expectEqual(StyleId.format_placeholder, styleFromScope("punctuation.definition.interpolation.rust"));
    try std.testing.expectEqual(StyleId.parameter, styleFromScope("variable.parameter.rust"));
    try std.testing.expectEqual(StyleId.string, styleFromScope("variable.string.zig"));
    try std.testing.expectEqual(StyleId.field, styleFromScope("meta.mapping.key.yaml string.unquoted.plain.out.yaml"));
    try std.testing.expectEqual(StyleId.punctuation, styleFromScope("meta.function-call.c punctuation.section.arguments.begin.c"));
    try std.testing.expectEqual(StyleId.function, styleFromScope("meta.function-call.c entity.name.function.c"));
    try std.testing.expectEqual(StyleId.field, styleFromScope("entity.name.section.toml"));
    try std.testing.expectEqual(StyleId.builtin, styleFromScope("support.type.primitive.ts"));
    try std.testing.expectEqual(StyleId.builtin, styleFromScope("entity.name.type.numeric.rust"));
    try std.testing.expectEqual(StyleId.type_name, styleFromScope("entity.name.type.alias.ts"));
}
