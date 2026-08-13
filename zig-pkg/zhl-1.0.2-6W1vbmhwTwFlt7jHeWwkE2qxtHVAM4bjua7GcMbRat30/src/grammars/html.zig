const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .block_comment, .value = "<!--", .scope = "comment.block.html", .escape = "-->" },
    .{ .kind = .regex, .value = "<![A-Z]+[^>]*>", .scope = "punctuation.definition.tag.html" },
    .{ .kind = .regex, .value = "</?[A-Za-z][A-Za-z0-9:-]*", .scope = "entity.name.tag.html" },
    .{ .kind = .regex, .value = "[A-Za-z_:][A-Za-z0-9_:.:-]*", .scope = "entity.other.attribute-name.html" },
    .{ .kind = .identifier_before, .value = "=", .scope = "entity.other.attribute-name.html" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.html", .escape = "\\" },
    .{ .kind = .string, .value = "'", .scope = "string.quoted.single.html", .escape = "\\" },
    .{ .kind = .regex, .value = "&[A-Za-z0-9#]+;", .scope = "constant.character.entity.html" },
    .{ .kind = .operators, .value = "< > / = { } ( ) [ ]", .scope = "punctuation.html" },
};

pub const name = "HTML";

pub const grammar = zhl.native_runtime.Grammar(name, "text.html.basic", &rules){};
