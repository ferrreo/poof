const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .regex, .value = "^#{1,6}\\s+.*$", .scope = "entity.name.section.markdown" },
    .{ .kind = .regex, .value = "^>.*$", .scope = "comment.block.markdown" },
    .{ .kind = .regex, .value = "^\\s*[-+*]\\s+", .scope = "punctuation.definition.list.markdown" },
    .{ .kind = .regex, .value = "^\\s*[0-9]+\\.\\s+", .scope = "punctuation.definition.list.markdown" },
    .{ .kind = .regex, .value = "`[^`]+`", .scope = "string.quoted.inline.markdown" },
    .{ .kind = .regex, .value = "^```.*$", .scope = "string.quoted.block.markdown" },
    .{ .kind = .regex, .value = "^~~~.*$", .scope = "string.quoted.block.markdown" },
    .{ .kind = .regex, .value = "\\*\\*[^*]+\\*\\*", .scope = "string.quoted.bold.markdown" },
    .{ .kind = .regex, .value = "\\*[^*]+\\*", .scope = "string.quoted.italic.markdown" },
    .{ .kind = .regex, .value = "\\[[^\\]]+\\]\\([^\\)]+\\)", .scope = "entity.name.section.link.markdown" },
};

pub const name = "Markdown";

pub const grammar = zhl.native_runtime.Grammar(name, "text.html.markdown", &rules){};
