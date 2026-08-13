const zhl = @import("zhl");
const rules = [_]zhl.native_runtime.Rule{
    .{ .kind = .line_comment, .value = "--", .scope = "comment.line.double-dash.sql" },
    .{ .kind = .line_comment, .value = "#", .scope = "comment.line.number-sign.sql" },
    .{ .kind = .block_comment, .value = "/*", .scope = "comment.block.sql", .escape = "*/", .nested = true },
    .{ .kind = .string, .value = "\"", .scope = "string.quoted.double.sql", .escape = "\\" },
    .{ .kind = .string, .value = "`", .scope = "string.quoted.other.backtick.sql", .escape = "\\" },
    .{ .kind = .string, .value = "'", .scope = "string.quoted.single.sql", .escape = "'" },
    .{ .kind = .number, .value = "generic", .scope = "constant.numeric.sql" },
    .{ .kind = .keywords, .value = "select SELECT insert INSERT update UPDATE delete DELETE create CREATE alter ALTER drop DROP truncate TRUNCATE from FROM where WHERE and AND or OR not NOT null NULL is IS in IN between BETWEEN like LIKE limit LIMIT offset OFFSET order ORDER by BY group GROUP having HAVING distinct DISTINCT as AS join JOIN inner INNER left LEFT right RIGHT outer OUTER full FULL cross CROSS union UNION on ON set SET into INTO values VALUES case CASE when WHEN then THEN else ELSE end END exists EXISTS table TABLE index INDEX view VIEW database DATABASE schema SCHEMA column COLUMN constraint CONSTRAINT primary PRIMARY key KEY foreign FOREIGN references REFERENCES unique UNIQUE check CHECK default DEFAULT", .scope = "keyword.control.sql" },
    .{ .kind = .keywords, .value = "int integer bigint smallint tinyint real float double decimal numeric char varchar text blob date time timestamp datetime boolean bool", .scope = "storage.type.sql" },
    .{ .kind = .regex, .value = "[A-Za-z_][A-Za-z0-9_]*", .scope = "variable.other.sql" },
};

pub const name = "SQL";

pub const grammar = zhl.native_runtime.Grammar(name, "source.sql", &rules){};
