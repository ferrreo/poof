const std = @import("std");

pub const ParseError = error{
    TooManyRules,
    TooManyStringBytes,
    StringTooLong,
    MissingQuote,
    InvalidEscape,
    InvalidSyntax,
};

pub const max_string_bytes = 8192;
pub const max_pool_bytes = 4 * 1024 * 1024;
pub const max_rules = 16384;

pub const StringRef = struct { start: u32 = 0, len: u16 = 0 };

pub const RuleKind = enum {
    line_comment,
    string,
    char,
    multiline_prefix,
    builtin_prefix,
    prefix_identifier,
    number,
    keywords,
    operators,
    function_call,
    capitalized_identifier,
    identifier_before,
    identifier_after,
    quoted_key_before,
    block_comment,
    regex_line_comment,
    regex_vm_line_comment,
    marker_string,
    regex,
    regex_vm,
    regex_block_comment,
    delimited,
    dynamic_block,
    regex_capture,
    regex_vm_capture,
    regex_vm_after_line_block,
    regex_vm_block,
    dotted_prefix_identifier,
};

pub const NativeRule = struct {
    kind: RuleKind,
    value: StringRef = .{},
    escape: StringRef = .{},
    scope: StringRef = .{},
    nested: bool = false,
};

pub const NativeSpec = struct {
    grammar_scope: StringRef = .{},
    name: StringRef = .{},
    root_scope: StringRef = .{},
    string_pool: [max_pool_bytes]u8 = undefined,
    string_pool_len: usize = 0,
    rules: [max_rules]NativeRule = undefined,
    rule_count: usize = 0,

    pub fn slice(self: *const NativeSpec, ref: StringRef) []const u8 {
        return self.string_pool[ref.start..][0..ref.len];
    }

    pub fn setString(self: *NativeSpec, out: *StringRef, value: []const u8) ParseError!void {
        if (value.len > max_string_bytes) return error.StringTooLong;
        if (self.string_pool_len + value.len > self.string_pool.len) return error.TooManyStringBytes;
        const start = self.string_pool_len;
        @memcpy(self.string_pool[start..][0..value.len], value);
        self.string_pool_len += value.len;
        out.* = .{ .start = @intCast(start), .len = @intCast(value.len) };
    }

    fn appendStringByte(self: *NativeSpec, start: usize, byte: u8) ParseError!void {
        if (self.string_pool_len - start == max_string_bytes) return error.StringTooLong;
        if (self.string_pool_len == self.string_pool.len) return error.TooManyStringBytes;
        self.string_pool[self.string_pool_len] = byte;
        self.string_pool_len += 1;
    }

    pub fn addRule(self: *NativeSpec, rule: NativeRule) ParseError!void {
        if (self.rule_count == self.rules.len) return error.TooManyRules;
        self.rules[self.rule_count] = rule;
        self.rule_count += 1;
    }

    pub fn ruleSlice(self: *const NativeSpec) []const NativeRule {
        return self.rules[0..self.rule_count];
    }
};

pub fn parse(source: []const u8) ParseError!NativeSpec {
    var spec = NativeSpec{};
    try parseInto(source, &spec);
    return spec;
}

pub fn parseInto(source: []const u8, spec: *NativeSpec) ParseError!void {
    spec.* = NativeSpec{};
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;
        if (std.mem.eql(u8, line, "{") or std.mem.eql(u8, line, "}") or std.mem.endsWith(u8, line, "{")) {
            if (std.mem.startsWith(u8, line, "grammar ")) {
                _ = try parseQuoted(spec, line, "grammar ".len, &spec.grammar_scope);
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "name ")) {
            _ = try parseQuoted(spec, line, "name ".len, &spec.name);
        } else if (std.mem.startsWith(u8, line, "scope root = ")) {
            _ = try parseQuoted(spec, line, "scope root = ".len, &spec.root_scope);
        } else if (std.mem.startsWith(u8, line, "line_comment ")) {
            try parseValueScopeRule(line, "line_comment ".len, .line_comment, spec);
        } else if (std.mem.startsWith(u8, line, "regex_line_comment ")) {
            try parseValueScopeRule(line, "regex_line_comment ".len, .regex_line_comment, spec);
        } else if (std.mem.startsWith(u8, line, "regex_vm_line_comment ")) {
            try parseValueScopeRule(line, "regex_vm_line_comment ".len, .regex_vm_line_comment, spec);
        } else if (std.mem.startsWith(u8, line, "block_comment ")) {
            try parsePairedScopeRule(line, "block_comment ".len, .block_comment, spec);
        } else if (std.mem.startsWith(u8, line, "regex_block_comment ")) {
            try parsePairedScopeRule(line, "regex_block_comment ".len, .regex_block_comment, spec);
        } else if (std.mem.startsWith(u8, line, "regex_vm_after_line_block ")) {
            try parsePairedScopeRule(line, "regex_vm_after_line_block ".len, .regex_vm_after_line_block, spec);
        } else if (std.mem.startsWith(u8, line, "dynamic_block ")) {
            try parsePairedScopeRule(line, "dynamic_block ".len, .dynamic_block, spec);
        } else if (std.mem.startsWith(u8, line, "regex_vm_block ")) {
            try parsePairedScopeRule(line, "regex_vm_block ".len, .regex_vm_block, spec);
        } else if (std.mem.startsWith(u8, line, "marker_string ")) {
            try parseDelimitedRule(line, "marker_string ".len, .marker_string, spec);
        } else if (std.mem.startsWith(u8, line, "string ")) {
            try parseDelimitedRule(line, "string ".len, .string, spec);
        } else if (std.mem.startsWith(u8, line, "char ")) {
            try parseDelimitedRule(line, "char ".len, .char, spec);
        } else if (std.mem.startsWith(u8, line, "delimited ")) {
            try parseAsymmetricDelimitedRule(line, "delimited ".len, spec);
        } else if (std.mem.startsWith(u8, line, "multiline_prefix ")) {
            try parseValueScopeRule(line, "multiline_prefix ".len, .multiline_prefix, spec);
        } else if (std.mem.startsWith(u8, line, "builtin_prefix ")) {
            try parseValueScopeRule(line, "builtin_prefix ".len, .builtin_prefix, spec);
        } else if (std.mem.startsWith(u8, line, "prefix_identifier ")) {
            try parseValueScopeRule(line, "prefix_identifier ".len, .prefix_identifier, spec);
        } else if (std.mem.startsWith(u8, line, "dotted_prefix_identifier ")) {
            try parseValueScopeRule(line, "dotted_prefix_identifier ".len, .dotted_prefix_identifier, spec);
        } else if (std.mem.startsWith(u8, line, "number ")) {
            try parseNameOrQuotedScopeRule(line, "number ".len, .number, spec);
        } else if (std.mem.startsWith(u8, line, "keywords ")) {
            try parseNameOrQuotedScopeRule(line, "keywords ".len, .keywords, spec);
        } else if (std.mem.startsWith(u8, line, "operators ")) {
            try parseNameOrQuotedScopeRule(line, "operators ".len, .operators, spec);
        } else if (std.mem.startsWith(u8, line, "function_call ")) {
            try parseScopeOnlyRule(line, "function_call ".len, .function_call, spec);
        } else if (std.mem.startsWith(u8, line, "capitalized_identifier ")) {
            try parseScopeOnlyRule(line, "capitalized_identifier ".len, .capitalized_identifier, spec);
        } else if (std.mem.startsWith(u8, line, "identifier_before ")) {
            try parseValueScopeRule(line, "identifier_before ".len, .identifier_before, spec);
        } else if (std.mem.startsWith(u8, line, "identifier_after ")) {
            try parseValueScopeRule(line, "identifier_after ".len, .identifier_after, spec);
        } else if (std.mem.startsWith(u8, line, "quoted_key_before ")) {
            try parseValueScopeRule(line, "quoted_key_before ".len, .quoted_key_before, spec);
        } else if (std.mem.startsWith(u8, line, "regex ")) {
            try parseValueScopeRule(line, "regex ".len, .regex, spec);
        } else if (std.mem.startsWith(u8, line, "regex_vm ")) {
            try parseValueScopeRule(line, "regex_vm ".len, .regex_vm, spec);
        } else if (std.mem.startsWith(u8, line, "regex_capture ")) {
            try parseCaptureRule(line, "regex_capture ".len, .regex_capture, spec);
        } else if (std.mem.startsWith(u8, line, "regex_vm_capture ")) {
            try parseCaptureRule(line, "regex_vm_capture ".len, .regex_vm_capture, spec);
        } else if (!std.mem.startsWith(u8, line, "context ")) {
            return error.InvalidSyntax;
        }
    }
}

fn parseValueScopeRule(line: []const u8, start: usize, kind: RuleKind, spec: *NativeSpec) ParseError!void {
    var rule = NativeRule{ .kind = kind };
    var pos = try parseQuoted(spec, line, start, &rule.value);
    pos = skipSpaces(line, pos);
    if (!std.mem.startsWith(u8, line[pos..], "scope ")) return error.InvalidSyntax;
    _ = try parseQuoted(spec, line, pos + "scope ".len, &rule.scope);
    try spec.addRule(rule);
}

fn parseDelimitedRule(line: []const u8, start: usize, kind: RuleKind, spec: *NativeSpec) ParseError!void {
    var rule = NativeRule{ .kind = kind };
    var pos = try parseQuoted(spec, line, start, &rule.value);
    pos = skipSpaces(line, pos);
    if (!std.mem.startsWith(u8, line[pos..], "escape ")) return error.InvalidSyntax;
    pos = try parseQuoted(spec, line, pos + "escape ".len, &rule.escape);
    pos = skipSpaces(line, pos);
    if (!std.mem.startsWith(u8, line[pos..], "scope ")) return error.InvalidSyntax;
    _ = try parseQuoted(spec, line, pos + "scope ".len, &rule.scope);
    try spec.addRule(rule);
}

fn parseCaptureRule(line: []const u8, start: usize, kind: RuleKind, spec: *NativeSpec) ParseError!void {
    var rule = NativeRule{ .kind = kind };
    var pos = try parseQuoted(spec, line, start, &rule.value);
    pos = skipSpaces(line, pos);
    if (!std.mem.startsWith(u8, line[pos..], "capture ")) return error.InvalidSyntax;
    pos += "capture ".len;
    const capture_end = scanName(line, pos);
    if (capture_end == pos) return error.InvalidSyntax;
    try spec.setString(&rule.escape, line[pos..capture_end]);
    pos = skipSpaces(line, capture_end);
    if (!std.mem.startsWith(u8, line[pos..], "scope ")) return error.InvalidSyntax;
    _ = try parseQuoted(spec, line, pos + "scope ".len, &rule.scope);
    try spec.addRule(rule);
}

fn parseAsymmetricDelimitedRule(line: []const u8, start: usize, spec: *NativeSpec) ParseError!void {
    var rule = NativeRule{ .kind = .delimited };
    var open = StringRef{};
    var close = StringRef{};
    var pos = try parseQuoted(spec, line, start, &open);
    pos = skipSpaces(line, pos);
    pos = try parseQuoted(spec, line, pos, &close);
    pos = skipSpaces(line, pos);
    if (!std.mem.startsWith(u8, line[pos..], "escape ")) return error.InvalidSyntax;
    pos = try parseQuoted(spec, line, pos + "escape ".len, &rule.escape);
    pos = skipSpaces(line, pos);
    if (!std.mem.startsWith(u8, line[pos..], "scope ")) return error.InvalidSyntax;
    _ = try parseQuoted(spec, line, pos + "scope ".len, &rule.scope);
    try setJoinedPair(spec, &rule.value, spec.slice(open), spec.slice(close));
    try spec.addRule(rule);
}

fn setJoinedPair(spec: *NativeSpec, out: *StringRef, first: []const u8, second: []const u8) ParseError!void {
    if (first.len + 1 + second.len > max_string_bytes) return error.StringTooLong;
    if (spec.string_pool_len + first.len + 1 + second.len > spec.string_pool.len) return error.TooManyStringBytes;
    const start = spec.string_pool_len;
    @memcpy(spec.string_pool[start..][0..first.len], first);
    spec.string_pool[start + first.len] = '\n';
    @memcpy(spec.string_pool[start + first.len + 1 ..][0..second.len], second);
    spec.string_pool_len += first.len + 1 + second.len;
    out.* = .{ .start = @intCast(start), .len = @intCast(first.len + 1 + second.len) };
}

fn parsePairedScopeRule(line: []const u8, start: usize, kind: RuleKind, spec: *NativeSpec) ParseError!void {
    var rule = NativeRule{ .kind = kind };
    var pos = try parseQuoted(spec, line, start, &rule.value);
    pos = skipSpaces(line, pos);
    pos = try parseQuoted(spec, line, pos, &rule.escape);
    pos = skipSpaces(line, pos);
    if (kind == .block_comment and std.mem.startsWith(u8, line[pos..], "nested")) {
        rule.nested = true;
        pos = skipSpaces(line, pos + "nested".len);
    }
    if (!std.mem.startsWith(u8, line[pos..], "scope ")) return error.InvalidSyntax;
    _ = try parseQuoted(spec, line, pos + "scope ".len, &rule.scope);
    try spec.addRule(rule);
}

fn parseNameOrQuotedScopeRule(line: []const u8, start: usize, kind: RuleKind, spec: *NativeSpec) ParseError!void {
    var rule = NativeRule{ .kind = kind };
    var pos = skipSpaces(line, start);
    if (pos < line.len and line[pos] == '"') {
        pos = try parseQuoted(spec, line, pos, &rule.value);
    } else {
        const value_end = scanName(line, pos);
        if (value_end == pos) return error.InvalidSyntax;
        try spec.setString(&rule.value, line[pos..value_end]);
        pos = value_end;
    }
    pos = skipSpaces(line, pos);
    if (!std.mem.startsWith(u8, line[pos..], "scope ")) return error.InvalidSyntax;
    _ = try parseQuoted(spec, line, pos + "scope ".len, &rule.scope);
    try spec.addRule(rule);
}

fn parseScopeOnlyRule(line: []const u8, start: usize, kind: RuleKind, spec: *NativeSpec) ParseError!void {
    var rule = NativeRule{ .kind = kind };
    const pos = skipSpaces(line, start);
    if (!std.mem.startsWith(u8, line[pos..], "scope ")) return error.InvalidSyntax;
    _ = try parseQuoted(spec, line, pos + "scope ".len, &rule.scope);
    try spec.addRule(rule);
}

fn parseQuoted(spec: *NativeSpec, line: []const u8, start: usize, out: *StringRef) ParseError!usize {
    var i = skipSpaces(line, start);
    if (i >= line.len or line[i] != '"') return error.MissingQuote;
    i += 1;
    const pool_start = spec.string_pool_len;
    while (i < line.len) : (i += 1) {
        const byte = line[i];
        if (byte == '"') {
            out.* = .{ .start = @intCast(pool_start), .len = @intCast(spec.string_pool_len - pool_start) };
            return i + 1;
        }
        if (byte == '\\') {
            i += 1;
            if (i >= line.len) return error.InvalidEscape;
            try spec.appendStringByte(pool_start, switch (line[i]) {
                '\\' => '\\',
                '"' => '"',
                '\'' => '\'',
                'n' => '\n',
                't' => '\t',
                else => return error.InvalidEscape,
            });
        } else {
            try spec.appendStringByte(pool_start, byte);
        }
    }
    return error.MissingQuote;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r;");
}

fn skipSpaces(line: []const u8, start: usize) usize {
    var i = start;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i;
}

fn scanName(line: []const u8, start: usize) usize {
    var i = start;
    while (i < line.len) : (i += 1) {
        const byte = line[i];
        if (!((byte >= 'a' and byte <= 'z') or
            (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or
            byte == '_'))
        {
            break;
        }
    }
    return i;
}

test "native DSL parses Zig core rules" {
    const source =
        \\grammar "source.zig" {
        \\    name "Zig 0.16";
        \\    scope root = "source.zig";
        \\    context main {
        \\        line_comment "///" scope "comment.line.documentation.zig";
        \\        regex_vm_line_comment "//[!/](?=[^/])" scope "comment.line.documentation.zig";
        \\        block_comment "/*" "*/" nested scope "comment.block.zig";
        \\        regex_block_comment "/\\*\\*(?!/)" "*/" scope "comment.block.documentation.zig";
        \\        dynamic_block "<<([A-Z]+)" "^\\1$" scope "string.unquoted.heredoc.zig";
        \\        regex_vm_block "(?<!r)\"\"\"" "\"\"\"(?!\")" scope "string.quoted.multi.zig";
        \\        marker_string "r" escape "\"#" scope "string.quoted.double.raw.zig";
        \\        string "\"" escape "\\" scope "string.quoted.double.zig";
        \\        delimited "@\"" "\"" escape "\\" scope "variable.string.zig";
        \\        builtin_prefix "@" scope "support.function.builtin.zig";
        \\        number generic scope "constant.numeric.zig";
        \\        keywords "const var fn" scope "keyword.control.zig";
        \\        operators "=> = ;" scope "keyword.operator.zig";
        \\        function_call scope "entity.name.function.zig";
        \\        identifier_before ":" scope "variable.other.field.zig";
        \\        regex "@[A-Za-z_][A-Za-z0-9_]*" scope "support.function.builtin.zig";
        \\        regex_vm "(?<!\\w)(?:void|int)(?!\\w)" scope "storage.type.zig";
        \\        regex_capture "(const) (name)" capture 2 scope "variable.other.zig";
        \\        regex_vm_after_line_block "^#if 0" "(?=^#endif\\b)" scope "comment.block.zig";
        \\    }
        \\}
    ;

    const spec = try parse(source);
    try std.testing.expectEqualStrings("source.zig", spec.slice(spec.grammar_scope));
    try std.testing.expectEqualStrings("Zig 0.16", spec.slice(spec.name));
    try std.testing.expectEqual(@as(usize, 19), spec.rule_count);
    try std.testing.expectEqual(RuleKind.regex_vm_line_comment, spec.rules[1].kind);
    try std.testing.expectEqualStrings("//[!/](?=[^/])", spec.slice(spec.rules[1].value));
    try std.testing.expectEqual(RuleKind.block_comment, spec.rules[2].kind);
    try std.testing.expectEqualStrings("/*", spec.slice(spec.rules[2].value));
    try std.testing.expectEqualStrings("*/", spec.slice(spec.rules[2].escape));
    try std.testing.expect(spec.rules[2].nested);
    try std.testing.expectEqual(RuleKind.regex_block_comment, spec.rules[3].kind);
    try std.testing.expectEqualStrings("/\\*\\*(?!/)", spec.slice(spec.rules[3].value));
    try std.testing.expectEqualStrings("*/", spec.slice(spec.rules[3].escape));
    try std.testing.expectEqual(RuleKind.dynamic_block, spec.rules[4].kind);
    try std.testing.expectEqualStrings("<<([A-Z]+)", spec.slice(spec.rules[4].value));
    try std.testing.expectEqualStrings("^\\1$", spec.slice(spec.rules[4].escape));
    try std.testing.expectEqual(RuleKind.regex_vm_block, spec.rules[5].kind);
    try std.testing.expectEqualStrings("(?<!r)\"\"\"", spec.slice(spec.rules[5].value));
    try std.testing.expectEqualStrings("\"\"\"(?!\")", spec.slice(spec.rules[5].escape));
    try std.testing.expectEqual(RuleKind.marker_string, spec.rules[6].kind);
    try std.testing.expectEqualStrings("r", spec.slice(spec.rules[6].value));
    try std.testing.expectEqualStrings("\"#", spec.slice(spec.rules[6].escape));
    try std.testing.expectEqual(RuleKind.string, spec.rules[7].kind);
    try std.testing.expectEqualStrings("\"", spec.slice(spec.rules[7].value));
    try std.testing.expectEqualStrings("\\", spec.slice(spec.rules[7].escape));
    try std.testing.expectEqual(RuleKind.delimited, spec.rules[8].kind);
    try std.testing.expectEqualStrings("@\"\n\"", spec.slice(spec.rules[8].value));
    try std.testing.expectEqualStrings("\\", spec.slice(spec.rules[8].escape));
    try std.testing.expectEqual(RuleKind.keywords, spec.rules[11].kind);
    try std.testing.expectEqualStrings("const var fn", spec.slice(spec.rules[11].value));
    try std.testing.expectEqual(RuleKind.function_call, spec.rules[13].kind);
    try std.testing.expectEqual(RuleKind.regex, spec.rules[15].kind);
    try std.testing.expectEqual(RuleKind.regex_vm, spec.rules[16].kind);
    try std.testing.expectEqual(RuleKind.regex_capture, spec.rules[17].kind);
    try std.testing.expectEqualStrings("2", spec.slice(spec.rules[17].escape));
    try std.testing.expectEqual(RuleKind.regex_vm_after_line_block, spec.rules[18].kind);
    try std.testing.expectEqualStrings("^#if 0", spec.slice(spec.rules[18].value));
}

test "native DSL parses dotted prefix identifier rule" {
    const source =
        \\grammar "source.test" {
        \\    name "Test";
        \\    scope root = "source.test";
        \\    context main {
        \\        dotted_prefix_identifier "@" scope "entity.name.function.decorator.test";
        \\    }
        \\}
    ;

    const spec = try parse(source);
    try std.testing.expectEqual(@as(usize, 1), spec.rule_count);
    try std.testing.expectEqual(RuleKind.dotted_prefix_identifier, spec.rules[0].kind);
    try std.testing.expectEqualStrings("@", spec.slice(spec.rules[0].value));
}

test "native DSL accepts generated grammar rule counts" {
    var spec = NativeSpec{};
    var index: usize = 0;
    while (index < 10805) : (index += 1) try spec.addRule(.{
        .kind = .regex,
        .value = .{},
        .scope = .{},
    });
    try std.testing.expectEqual(@as(usize, 10805), spec.rule_count);
}

test "native DSL accepts binary-format string limit" {
    var value = [_]u8{'a'} ** max_string_bytes;
    var quoted: [max_string_bytes + 2]u8 = undefined;
    quoted[0] = '"';
    @memcpy(quoted[1..][0..value.len], &value);
    quoted[quoted.len - 1] = '"';

    var spec = NativeSpec{};
    var out = StringRef{};
    const end = try parseQuoted(&spec, &quoted, 0, &out);

    try std.testing.expectEqual(quoted.len, end);
    try std.testing.expectEqual(@as(usize, max_string_bytes), spec.slice(out).len);
    try std.testing.expectEqualSlices(u8, &value, spec.slice(out));
}
