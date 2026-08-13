const std = @import("std");

const Action = enum { match, include, push, set, embed, pop };

const Variable = struct {
    name: []u8,
    value: []u8,
};

pub const Rule = struct {
    context: []u8 = &.{},
    match: []u8 = &.{},
    scope: []u8 = &.{},
    capture_scope: []u8 = &.{},
    context_scope: []u8 = &.{},
    target: []u8 = &.{},
    escape: []u8 = &.{},
    action: Action = .match,
};

pub const Summary = struct {
    allocator: std.mem.Allocator,
    name: []u8 = &.{},
    scope: []u8 = &.{},
    rules: []Rule = &.{},

    pub fn deinit(self: *Summary) void {
        self.allocator.free(self.name);
        self.allocator.free(self.scope);
        for (self.rules) |rule| {
            freeOpt(self.allocator, rule.context);
            freeOpt(self.allocator, rule.match);
            freeOpt(self.allocator, rule.scope);
            freeOpt(self.allocator, rule.capture_scope);
            freeOpt(self.allocator, rule.context_scope);
            freeOpt(self.allocator, rule.target);
            freeOpt(self.allocator, rule.escape);
        }
        self.allocator.free(self.rules);
    }
};

pub fn summarizeYaml(allocator: std.mem.Allocator, source: []const u8) !Summary {
    var name: []const u8 = "";
    var scope: []const u8 = "";
    var current_context: []const u8 = "main";
    var current_meta_scope: []const u8 = "";
    var inline_context: []const u8 = "";
    var inline_meta_scope: []const u8 = "";
    var inline_indent: usize = 0;
    var inline_context_buf: [64]u8 = undefined;
    var in_variables = false;
    var in_captures = false;
    var variables = std.ArrayList(Variable).empty;
    var rules = std.ArrayList(Rule).empty;
    errdefer {
        deinitVariables(allocator, variables.items);
        variables.deinit(allocator);
        deinitRules(allocator, rules.items);
        rules.deinit(allocator);
    }

    try collectVariables(allocator, source, &variables);

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        const indent = lineIndent(raw_line);
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or std.mem.eql(u8, line, "---") or line[0] == '%') continue;
        const list_line = nestedListLine(line);

        if (indent == 0 and std.mem.eql(u8, line, "variables:")) {
            in_variables = true;
            continue;
        }
        if (indent == 0 and std.mem.eql(u8, line, "contexts:")) {
            in_variables = false;
            continue;
        }
        if (std.mem.eql(u8, line, "captures:")) {
            in_captures = true;
            continue;
        }
        if (in_variables and indent == 0) in_variables = false;
        if (in_captures) {
            if (parseCaptureScope(line)) |scope_value| {
                if (lastRule(&rules)) |rule| {
                    if (rule.capture_scope.len == 0) try replaceOpt(allocator, &rule.capture_scope, scope_value);
                }
                continue;
            }
        }
        if (in_variables and parseVariable(line) != null) continue;
        if (inline_context.len != 0 and indent <= inline_indent) {
            inline_context = "";
            inline_meta_scope = "";
        }
        if (inline_context.len != 0) {
            if (parseMetaScope(list_line)) |scope_value| {
                inline_meta_scope = scope_value;
                continue;
            }
            if (std.mem.startsWith(u8, list_line, "- match:")) {
                in_captures = false;
                var rule = Rule{};
                var transferred = false;
                errdefer if (!transferred) deinitRule(allocator, rule);
                rule.context = try allocator.dupe(u8, inline_context);
                rule.match = try expandVariables(allocator, stripScalar(list_line["- match:".len..]), variables.items);
                rule.context_scope = try allocator.dupe(u8, inline_meta_scope);
                try rules.append(allocator, rule);
                transferred = true;
                continue;
            }
            if (std.mem.startsWith(u8, list_line, "- include:")) {
                in_captures = false;
                try rules.append(allocator, .{
                    .context = try allocator.dupe(u8, inline_context),
                    .context_scope = try allocator.dupe(u8, inline_meta_scope),
                    .target = try allocator.dupe(u8, stripTarget(list_line["- include:".len..])),
                    .action = .include,
                });
                continue;
            }
        }
        if (indent <= 4) {
            if (parseMetaScope(list_line)) |scope_value| {
                current_meta_scope = scope_value;
                continue;
            }
        }
        if (indent <= 2 and std.mem.endsWith(u8, line, ":") and !std.mem.startsWith(u8, line, "-")) {
            current_context = line[0 .. line.len - 1];
            current_meta_scope = "";
        } else if (indent == 0 and std.mem.startsWith(u8, line, "name:")) {
            name = stripScalar(line["name:".len..]);
        } else if (indent == 0 and std.mem.startsWith(u8, line, "scope:")) {
            scope = stripScalar(line["scope:".len..]);
        } else if (std.mem.startsWith(u8, line, "scope:")) {
            const value = stripScalar(line["scope:".len..]);
            if (lastRule(&rules)) |rule| try replaceOpt(allocator, &rule.scope, value);
        } else if (std.mem.startsWith(u8, list_line, "- match:")) {
            in_captures = false;
            var rule = Rule{};
            var transferred = false;
            errdefer if (!transferred) deinitRule(allocator, rule);
            rule.context = try allocator.dupe(u8, current_context);
            rule.match = try expandVariables(allocator, stripScalar(list_line["- match:".len..]), variables.items);
            rule.context_scope = try allocator.dupe(u8, current_meta_scope);
            try rules.append(allocator, rule);
            transferred = true;
        } else if (std.mem.startsWith(u8, list_line, "- include:")) {
            in_captures = false;
            try rules.append(allocator, .{
                .context = try allocator.dupe(u8, current_context),
                .context_scope = try allocator.dupe(u8, current_meta_scope),
                .target = try allocator.dupe(u8, stripTarget(list_line["- include:".len..])),
                .action = .include,
            });
        } else if (std.mem.startsWith(u8, line, "push:")) {
            if (lastRule(&rules)) |rule| {
                const target = stripTarget(line["push:".len..]);
                if (target.len == 0) {
                    inline_context = try inlineContextName(&inline_context_buf, rules.items.len);
                    inline_meta_scope = "";
                    inline_indent = indent;
                    try replaceOpt(allocator, &rule.target, inline_context);
                } else {
                    try replaceOpt(allocator, &rule.target, target);
                }
                rule.action = .push;
            }
        } else if (std.mem.startsWith(u8, line, "set:")) {
            if (lastRule(&rules)) |rule| {
                const target = stripTarget(line["set:".len..]);
                if (target.len == 0) {
                    inline_context = try inlineContextName(&inline_context_buf, rules.items.len);
                    inline_meta_scope = "";
                    inline_indent = indent;
                    try replaceOpt(allocator, &rule.target, inline_context);
                } else {
                    try replaceOpt(allocator, &rule.target, target);
                }
                rule.action = .set;
            }
        } else if (std.mem.startsWith(u8, line, "embed:")) {
            if (lastRule(&rules)) |rule| {
                try replaceOpt(allocator, &rule.target, stripTarget(line["embed:".len..]));
                rule.action = .embed;
            }
        } else if (std.mem.startsWith(u8, line, "escape:")) {
            if (lastRule(&rules)) |rule| {
                freeOpt(allocator, rule.escape);
                rule.escape = try expandVariables(allocator, stripScalar(line["escape:".len..]), variables.items);
            }
        } else if (std.mem.startsWith(u8, line, "pop:")) {
            if (lastRule(&rules)) |rule| {
                if (isPop(line["pop:".len..])) rule.action = .pop;
            }
        }
    }

    const out_name = try allocator.dupe(u8, name);
    errdefer allocator.free(out_name);
    const out_scope = try allocator.dupe(u8, scope);
    errdefer allocator.free(out_scope);
    const out_rules = try rules.toOwnedSlice(allocator);
    deinitVariables(allocator, variables.items);
    variables.deinit(allocator);

    return .{
        .allocator = allocator,
        .name = out_name,
        .scope = out_scope,
        .rules = out_rules,
    };
}

fn stripScalar(raw: []const u8) []const u8 {
    var value = std.mem.trim(u8, raw, " \t");
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
        (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        return value[1 .. value.len - 1];
    }
    for (value, 0..) |byte, index| {
        if (byte == '#' and index != 0 and std.ascii.isWhitespace(value[index - 1])) return std.mem.trim(u8, value[0..index], " \t");
    }
    return value;
}

fn lineIndent(raw: []const u8) usize {
    var count: usize = 0;
    while (count < raw.len and (raw[count] == ' ' or raw[count] == '\t')) : (count += 1) {}
    return count;
}

fn nestedListLine(line: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, line, "- - ")) line[2..] else line;
}

fn parseMetaScope(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "- meta_scope:")) return stripScalar(line["- meta_scope:".len..]);
    if (std.mem.startsWith(u8, line, "meta_scope:")) return stripScalar(line["meta_scope:".len..]);
    return null;
}

fn inlineContextName(buf: []u8, id: usize) ![]const u8 {
    return try std.fmt.bufPrint(buf, "__inline_{d}", .{id});
}

fn stripTarget(raw: []const u8) []const u8 {
    const value = stripScalar(raw);
    if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') {
        const inner = value[1 .. value.len - 1];
        if (std.mem.lastIndexOfScalar(u8, inner, ',')) |comma| {
            return std.mem.trim(u8, inner[comma + 1 ..], " \t");
        }
        return std.mem.trim(u8, inner, " \t");
    }
    return value;
}

fn parseVariable(line: []const u8) ?struct { name: []const u8, value: []const u8 } {
    if (std.mem.startsWith(u8, line, "-") or std.mem.indexOfScalar(u8, line, ':') == null) return null;
    const colon = std.mem.indexOfScalar(u8, line, ':').?;
    return .{ .name = std.mem.trim(u8, line[0..colon], " \t"), .value = stripScalar(line[colon + 1 ..]) };
}

fn collectVariables(allocator: std.mem.Allocator, source: []const u8, variables: *std.ArrayList(Variable)) !void {
    var in_variables = false;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '%') continue;
        if (lineIndent(raw_line) == 0 and std.mem.eql(u8, line, "variables:")) {
            in_variables = true;
            continue;
        }
        if (lineIndent(raw_line) == 0 and std.mem.eql(u8, line, "contexts:")) {
            in_variables = false;
            continue;
        }
        if (in_variables and lineIndent(raw_line) == 0) in_variables = false;
        if (in_variables) if (parseVariable(line)) |variable| {
            var owned = Variable{ .name = try allocator.dupe(u8, variable.name), .value = &.{} };
            var transferred = false;
            errdefer if (!transferred) {
                allocator.free(owned.name);
                if (owned.value.len != 0) allocator.free(owned.value);
            };
            owned.value = try allocator.dupe(u8, variable.value);
            try variables.append(allocator, owned);
            transferred = true;
        };
    }
}

fn parseCaptureScope(line: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const slot = std.mem.trim(u8, line[0..colon], " \t");
    for (slot) |byte| if (!std.ascii.isDigit(byte)) return null;
    return stripScalar(line[colon + 1 ..]);
}

fn expandVariables(allocator: std.mem.Allocator, value: []const u8, variables: []const Variable) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendExpanded(allocator, &out, value, variables, 0);
    return out.toOwnedSlice(allocator);
}

fn appendExpanded(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8, variables: []const Variable, depth: u8) !void {
    if (depth == 8) {
        try out.appendSlice(allocator, value);
        return;
    }
    var i: usize = 0;
    while (i < value.len) {
        if (std.mem.startsWith(u8, value[i..], "{{")) {
            if (std.mem.indexOf(u8, value[i + 2 ..], "}}")) |close_rel| {
                const key = std.mem.trim(u8, value[i + 2 .. i + 2 + close_rel], " \t");
                if (findVariable(variables, key)) |replacement| {
                    try appendExpanded(allocator, out, replacement, variables, depth + 1);
                    i += close_rel + 4;
                    continue;
                }
            }
        }
        try out.append(allocator, value[i]);
        i += 1;
    }
}

fn findVariable(variables: []const Variable, name: []const u8) ?[]const u8 {
    var i = variables.len;
    while (i > 0) {
        i -= 1;
        const variable = variables[i];
        if (std.mem.eql(u8, variable.name, name)) return variable.value;
    }
    return null;
}

fn isPop(raw: []const u8) bool {
    const value = stripScalar(raw);
    if (std.mem.eql(u8, value, "true")) return true;
    return (std.fmt.parseInt(u16, value, 10) catch 0) > 0;
}

fn lastRule(rules: *std.ArrayList(Rule)) ?*Rule {
    if (rules.items.len == 0) return null;
    return &rules.items[rules.items.len - 1];
}

fn freeOpt(allocator: std.mem.Allocator, value: []u8) void {
    if (value.len != 0) allocator.free(value);
}

fn replaceOpt(allocator: std.mem.Allocator, field: *[]u8, value: []const u8) !void {
    freeOpt(allocator, field.*);
    field.* = try allocator.dupe(u8, value);
}

fn deinitRules(allocator: std.mem.Allocator, rules: []Rule) void {
    for (rules) |rule| {
        deinitRule(allocator, rule);
    }
}

fn deinitRule(allocator: std.mem.Allocator, rule: Rule) void {
    freeOpt(allocator, rule.context);
    freeOpt(allocator, rule.match);
    freeOpt(allocator, rule.scope);
    freeOpt(allocator, rule.capture_scope);
    freeOpt(allocator, rule.context_scope);
    freeOpt(allocator, rule.target);
    freeOpt(allocator, rule.escape);
}

fn deinitVariables(allocator: std.mem.Allocator, variables: []Variable) void {
    for (variables) |variable| {
        allocator.free(variable.name);
        allocator.free(variable.value);
    }
}

test "Sublime YAML summary extracts match scopes" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: \b(if|else)\b
        \\      scope: keyword.control.test
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqualStrings("Test", summary.name);
    try std.testing.expectEqualStrings("source.test", summary.scope);
    try std.testing.expectEqual(@as(usize, 1), summary.rules.len);
    try std.testing.expectEqualStrings("\\b(if|else)\\b", summary.rules[0].match);
}

test "Sublime summary preserves includes" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - include: keywords
        \\  keywords:
        \\    - match: \b(if|else)\b
        \\      scope: keyword.control.test
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqual(@as(usize, 2), summary.rules.len);
    try std.testing.expectEqual(Action.include, summary.rules[0].action);
    try std.testing.expectEqualStrings("keywords", summary.rules[0].target);
    try std.testing.expectEqualStrings("\\b(if|else)\\b", summary.rules[1].match);
}

test "Sublime variables expand in match patterns" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\variables:
        \\  ident: '[A-Za-z_][A-Za-z0-9_]*'
        \\contexts:
        \\  main:
        \\    - match: '@{{ident}}'
        \\      scope: support.function.builtin.test
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqualStrings("@[A-Za-z_][A-Za-z0-9_]*", summary.rules[0].match);
    try std.testing.expectEqualStrings("support.function.builtin.test", summary.rules[0].scope);
}

test "Sublime unquoted scalars strip inline comments" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: ^\3$ # HEREDOC delimiter
        \\      scope: string.test
        \\    - match: 'literal # hash'
        \\      scope: keyword.test
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqualStrings("^\\3$", summary.rules[0].match);
    try std.testing.expectEqualStrings("literal # hash", summary.rules[1].match);
}

test "Sublime variables expand before declaration and recursively" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: '{{bol}}{{word}}'
        \\      scope: keyword.control.test
        \\variables:
        \\  bol: ^
        \\  ident: '[A-Za-z_]+'
        \\  word: '{{ident}}\b'
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqualStrings("^[A-Za-z_]+\\b", summary.rules[0].match);
}

test "Sublime concatenated parent keeps child root scope" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Parent
        \\scope: source.parent
        \\contexts:
        \\  main:
        \\    - match: parent
        \\      scope: keyword.parent
        \\%YAML 1.2
        \\---
        \\name: Child
        \\scope: source.child
        \\contexts:
        \\  main:
        \\    - match: child
        \\      scope: keyword.child
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqualStrings("Child", summary.name);
    try std.testing.expectEqualStrings("source.child", summary.scope);
    try std.testing.expectEqualStrings("keyword.parent", summary.rules[0].scope);
}

test "Sublime summary preserves numeric capture scope" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: ([A-Z]+)
        \\      captures:
        \\        1: entity.name.type.test
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqualStrings("entity.name.type.test", summary.rules[0].capture_scope);
}

test "Sublime summary preserves prototype context" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  prototype:
        \\    - match: '//'
        \\      scope: comment.line.test
        \\  main:
        \\    - match: \b(if|else)\b
        \\      scope: keyword.control.test
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqualStrings("prototype", summary.rules[0].context);
    try std.testing.expectEqualStrings("main", summary.rules[1].context);
}

test "Sublime summary preserves named context meta scope" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  body:
        \\    - meta_scope: comment.block.test
        \\    - match: \*/
        \\      scope: punctuation.definition.comment.end.test
        \\      pop: true
        \\  main:
        \\    - match: /\*
        \\      scope: punctuation.definition.comment.begin.test
        \\      push: body
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqualStrings("comment.block.test", summary.rules[0].context_scope);
    try std.testing.expectEqualStrings("", summary.rules[1].context_scope);
}

test "Sublime summary preserves inline push meta scope" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: /\*
        \\      scope: punctuation.definition.comment.begin.test
        \\      push:
        \\        - meta_scope: comment.block.test
        \\        - match: \*/
        \\          scope: punctuation.definition.comment.end.test
        \\          pop: true
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqual(Action.push, summary.rules[0].action);
    try std.testing.expect(summary.rules[0].target.len != 0);
    try std.testing.expectEqualStrings(summary.rules[0].target, summary.rules[1].context);
    try std.testing.expectEqualStrings("comment.block.test", summary.rules[1].context_scope);
    try std.testing.expectEqual(Action.pop, summary.rules[1].action);
}

test "Sublime summary preserves nested inline context lists" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: (?=[A-Za-z_])
        \\      set:
        \\        - - meta_scope: meta.binding.test
        \\          - include: immediately-pop
        \\        - literal-variable
        \\  immediately-pop:
        \\    - match: (?=\S)
        \\      pop: true
        \\  literal-variable:
        \\    - match: \b[a-z]+\b
        \\      scope: variable.other.test
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqual(Action.set, summary.rules[0].action);
    try std.testing.expect(summary.rules[0].target.len != 0);
    try std.testing.expectEqual(Action.include, summary.rules[1].action);
    try std.testing.expectEqualStrings(summary.rules[0].target, summary.rules[1].context);
    try std.testing.expectEqualStrings("meta.binding.test", summary.rules[1].context_scope);
    try std.testing.expectEqualStrings("immediately-pop", summary.rules[1].target);
}

test "Sublime summary preserves push and pop context" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: '"'
        \\      scope: string.quoted.test
        \\      push: string
        \\  string:
        \\    - match: '"'
        \\      scope: string.quoted.test
        \\      pop: true
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqual(Action.push, summary.rules[0].action);
    try std.testing.expectEqualStrings("string", summary.rules[0].target);
    try std.testing.expectEqual(Action.pop, summary.rules[1].action);
}

test "Sublime summary treats variables context as normal context" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  variables:
        \\    - match: '"'
        \\      push:
        \\        - meta_scope: string.test
        \\        - match: '"'
        \\          pop: true
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqualStrings("variables", summary.rules[0].context);
    try std.testing.expectEqual(Action.push, summary.rules[0].action);
    try std.testing.expectEqual(Action.pop, summary.rules[1].action);
}

test "Sublime summary accepts numeric pop" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  body:
        \\    - match: end
        \\      pop: 1
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqual(Action.pop, summary.rules[0].action);
}

test "Sublime summary preserves set context" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: \{
        \\      scope: punctuation.section.block.begin.test
        \\      set: [block]
        \\  block:
        \\    - match: \}
        \\      scope: punctuation.section.block.end.test
        \\      pop: true
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqual(Action.set, summary.rules[0].action);
    try std.testing.expectEqualStrings("block", summary.rules[0].target);
    try std.testing.expectEqual(Action.pop, summary.rules[1].action);
}

test "Sublime summary uses final bracketed target context" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - match: start
        \\      push: [prefix, body]
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqualStrings("body", summary.rules[0].target);
}

test "Sublime summary preserves embed escape" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: text.html.test
        \\contexts:
        \\  main:
        \\    - match: <script>
        \\      scope: string.quoted.test
        \\      embed: js
        \\      escape: </script>
        \\  js:
        \\    - match: \b(if|else)\b
        \\      scope: keyword.control.test
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqual(Action.embed, summary.rules[0].action);
    try std.testing.expectEqualStrings("js", summary.rules[0].target);
    try std.testing.expectEqualStrings("</script>", summary.rules[0].escape);
    try std.testing.expectEqualStrings("js", summary.rules[1].context);
}

test "Sublime summary frees overwritten rule fields" {
    const yaml =
        \\%YAML 1.2
        \\---
        \\name: Test
        \\scope: source.test
        \\contexts:
        \\  main:
        \\    - include: old-target
        \\      push: new-target
        \\      scope: keyword.old
        \\      scope: keyword.new
        \\      escape: old
        \\      escape: new
    ;

    var summary = try summarizeYaml(std.testing.allocator, yaml);
    defer summary.deinit();

    try std.testing.expectEqual(Action.push, summary.rules[0].action);
    try std.testing.expectEqualStrings("new-target", summary.rules[0].target);
    try std.testing.expectEqualStrings("keyword.new", summary.rules[0].scope);
    try std.testing.expectEqualStrings("new", summary.rules[0].escape);
}
