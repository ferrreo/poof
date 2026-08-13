const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .block_comment, .value = "<!--", .scope = "comment.block.xml", .escape = "-->" },
    .{ .kind = .block_comment, .value = "<![CDATA[", .scope = "string.unquoted.cdata.xml", .escape = "]]>" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.xml", .escape = "\\" },
    .{ .kind = .string, .value = "'", .scope = "string.quoted.single.xml", .escape = "\\" },
    .{ .kind = .regex, .value = "&[#A-Za-z0-9:]+;", .scope = "constant.character.entity.xml" },
    .{ .kind = .regex, .value = "<[?][A-Za-z_][A-Za-z0-9_.-]*", .scope = "punctuation.definition.tag.xml" },
    .{ .kind = .regex, .value = "</[A-Za-z_][A-Za-z0-9_.:-]*", .scope = "entity.name.tag.xml" },
    .{ .kind = .regex, .value = "<[A-Za-z_][A-Za-z0-9_.:-]*", .scope = "entity.name.tag.xml" },
    .{ .kind = .regex, .value = "[A-Za-z_:][A-Za-z0-9_.:-]*", .scope = "entity.other.attribute-name.xml" },
    .{ .kind = .identifier_before, .value = "=", .scope = "entity.other.attribute-name.xml" },
    .{ .kind = .operators, .value = "< > / ? = ! [ ] & ;", .scope = "punctuation.definition.tag.xml" },
};

pub const name = "XML";

pub const grammar = zhl.native_runtime.Grammar(name, "text.xml", &rules){};
