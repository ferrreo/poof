const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.log", .escape = "\\" },
    .{ .kind = .string, .value = "'", .scope = "string.quoted.single.log", .escape = "\\" },
    .{ .kind = .number, .value = "generic", .scope = "constant.language.log" },
    .{ .kind = .keywords, .value = "TRACE Trace trace DEBUG Debug debug", .scope = "comment.log" },
    .{ .kind = .keywords, .value = "HINT INFO INFORMATION Info NOTICE Started", .scope = "keyword.log" },
    .{ .kind = .keywords, .value = "WARNING WARN Warning Warn", .scope = "keyword.log" },
    .{ .kind = .keywords, .value = "ALERT CRITICAL EMERGENCY ERROR FAILURE FAIL Fatal FATAL Error Failed", .scope = "string.log" },
    .{ .kind = .keywords, .value = "true false null", .scope = "constant.language.log" },
};

pub const name = "Log";

pub const grammar = zhl.native_runtime.Grammar(name, "text.log", &rules){};
