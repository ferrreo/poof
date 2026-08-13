const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .quoted_key_before, .value = ":", .scope = "meta.mapping.key.json" },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.json", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.json" },
    .{ .kind = .keywords, .value = "true false null", .scope = "constant.language.json" },
    .{ .kind = .operators, .value = "{ } [ ] : ,", .scope = "punctuation.separator.json" },
};

pub const name = "JSON";

pub const grammar = zhl.native_runtime.Grammar(name, "source.json", &rules){};
