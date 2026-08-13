const std = @import("std");
const style = @import("../theme/style.zig");
const textmate = @import("root.zig");
const textmate_captures = @import("captures.zig");
const textmate_include = @import("include.zig");
const textmate_injection = @import("injection.zig");
const theme = @import("../theme/root.zig").theme;

const Entry = struct {
    key: []u8,
    value: Node,
};

const Node = union(enum) {
    string: []u8,
    bool: bool,
    array: []Node,
    dict: []Entry,

    fn deinit(self: Node, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |value| allocator.free(value),
            .bool => {},
            .array => |items| {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            },
            .dict => |entries| {
                for (entries) |entry| {
                    allocator.free(entry.key);
                    entry.value.deinit(allocator);
                }
                allocator.free(entries);
            },
        }
    }
};

pub fn summarize(allocator: std.mem.Allocator, xml: []const u8) !textmate.Summary {
    var parser = Parser{ .allocator = allocator, .source = xml };
    const root = try parser.parseRoot();
    defer root.deinit(allocator);
    const dict = switch (root) {
        .dict => |entries| entries,
        else => return error.MalformedGrammar,
    };
    const scope_name = dictString(dict, "scopeName") orelse return error.MissingScopeName;
    var rules = std.ArrayList(textmate.RuleSummary).empty;
    var include_stack = textmate_include.Stack{};
    defer include_stack.deinit(allocator);
    errdefer {
        freeRules(allocator, rules.items);
        rules.deinit(allocator);
    }
    try collectPatterns(allocator, &rules, dictGet(dict, "patterns") orelse return error.MalformedGrammar, dictGet(dict, "repository"), null, &include_stack, 0);
    const injections = if (dictGet(dict, "injections")) |value|
        try collectInjections(allocator, &rules, value, dictGet(dict, "repository"), scope_name, &include_stack)
    else
        InjectionCounts{};
    return .{
        .allocator = allocator,
        .scope_name = try allocator.dupe(u8, scope_name),
        .name = try dupeOpt(allocator, dictString(dict, "name")),
        .first_line_match = try dupeOpt(allocator, dictString(dict, "firstLineMatch")),
        .injections_total = injections.total,
        .injections_applied = injections.applied,
        .rules = try rules.toOwnedSlice(allocator),
    };
}

pub fn compileTheme(allocator: std.mem.Allocator, xml: []const u8) !theme.CompiledTheme {
    var parser = Parser{ .allocator = allocator, .source = xml };
    const root = try parser.parseRoot();
    defer root.deinit(allocator);
    const dict = switch (root) {
        .dict => |entries| entries,
        else => return error.MalformedTheme,
    };
    const settings = switch (dictGet(dict, "settings") orelse return theme.CompiledTheme{}) {
        .array => |items| items,
        else => return error.MalformedTheme,
    };
    var out = theme.CompiledTheme{};
    for (settings) |entry_node| {
        const entry = switch (entry_node) {
            .dict => |entries| entries,
            else => continue,
        };
        const scope = dictString(entry, "scope") orelse continue;
        const values = switch (dictGet(entry, "settings") orelse continue) {
            .dict => |entries| entries,
            else => return error.MalformedTheme,
        };
        const text_style = try theme.textStyleFromStrings(
            dictString(values, "foreground"),
            dictString(values, "background"),
            dictString(values, "fontStyle"),
        );
        theme.applyScopeList(&out, scope, text_style);
    }
    return out;
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    index: usize = 0,

    fn parseRoot(self: *Parser) anyerror!Node {
        self.skipTrivia();
        if (try self.consumeStart("plist")) {
            const root = try self.parseNode();
            try self.expectEnd("plist");
            return root;
        }
        return self.parseNode();
    }

    fn parseNode(self: *Parser) anyerror!Node {
        self.skipTrivia();
        if (try self.consumeStart("dict")) return .{ .dict = try self.parseDict() };
        if (try self.consumeStart("array")) return .{ .array = try self.parseArray() };
        if (try self.consumeStart("string")) return .{ .string = try self.readText("string") };
        if (self.consumeEmpty("true")) return .{ .bool = true };
        if (self.consumeEmpty("false")) return .{ .bool = false };
        return error.MalformedGrammar;
    }

    fn parseDict(self: *Parser) anyerror![]Entry {
        var entries = std.ArrayList(Entry).empty;
        errdefer {
            for (entries.items) |entry| {
                self.allocator.free(entry.key);
                entry.value.deinit(self.allocator);
            }
            entries.deinit(self.allocator);
        }
        while (true) {
            self.skipTrivia();
            if (self.consumeEnd("dict")) break;
            try self.expectStart("key");
            const key = try self.readText("key");
            const value = try self.parseNode();
            try entries.append(self.allocator, .{ .key = key, .value = value });
        }
        return entries.toOwnedSlice(self.allocator);
    }

    fn parseArray(self: *Parser) anyerror![]Node {
        var items = std.ArrayList(Node).empty;
        errdefer {
            for (items.items) |item| item.deinit(self.allocator);
            items.deinit(self.allocator);
        }
        while (true) {
            self.skipTrivia();
            if (self.consumeEnd("array")) break;
            try items.append(self.allocator, try self.parseNode());
        }
        return items.toOwnedSlice(self.allocator);
    }

    fn readText(self: *Parser, comptime tag: []const u8) ![]u8 {
        const close = "</" ++ tag ++ ">";
        const end = std.mem.indexOf(u8, self.source[self.index..], close) orelse return error.MalformedGrammar;
        const raw = self.source[self.index .. self.index + end];
        self.index += end + close.len;
        return decodeEntities(self.allocator, raw);
    }

    fn skipTrivia(self: *Parser) void {
        while (true) {
            while (self.index < self.source.len and std.ascii.isWhitespace(self.source[self.index])) self.index += 1;
            if (std.mem.startsWith(u8, self.source[self.index..], "<?")) {
                self.index += (std.mem.indexOf(u8, self.source[self.index..], "?>") orelse return) + 2;
            } else if (std.mem.startsWith(u8, self.source[self.index..], "<!--")) {
                self.index += (std.mem.indexOf(u8, self.source[self.index..], "-->") orelse return) + 3;
            } else if (std.mem.startsWith(u8, self.source[self.index..], "<!")) {
                self.index += (std.mem.indexOfScalar(u8, self.source[self.index..], '>') orelse return) + 1;
            } else return;
        }
    }

    fn expectStart(self: *Parser, comptime tag: []const u8) !void {
        if (!try self.consumeStart(tag)) return error.MalformedGrammar;
    }

    fn consumeStart(self: *Parser, comptime tag: []const u8) !bool {
        if (!std.mem.startsWith(u8, self.source[self.index..], "<" ++ tag)) return false;
        const after = self.index + 1 + tag.len;
        if (after >= self.source.len or (self.source[after] != '>' and !std.ascii.isWhitespace(self.source[after]))) return false;
        const close = std.mem.indexOfScalar(u8, self.source[after..], '>') orelse return error.MalformedGrammar;
        self.index = after + close + 1;
        return true;
    }

    fn expectEnd(self: *Parser, comptime tag: []const u8) !void {
        self.skipTrivia();
        if (!self.consumeEnd(tag)) return error.MalformedGrammar;
    }

    fn consumeEnd(self: *Parser, comptime tag: []const u8) bool {
        const end = "</" ++ tag ++ ">";
        if (!std.mem.startsWith(u8, self.source[self.index..], end)) return false;
        self.index += end.len;
        return true;
    }

    fn consumeEmpty(self: *Parser, comptime tag: []const u8) bool {
        const empty = "<" ++ tag ++ "/>";
        if (!std.mem.startsWith(u8, self.source[self.index..], empty)) return false;
        self.index += empty.len;
        return true;
    }
};

const max_include_depth = textmate_include.max_depth;

fn collectPatterns(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(textmate.RuleSummary),
    patterns_node: Node,
    repository_node: ?Node,
    parent: ?u32,
    include_stack: *textmate_include.Stack,
    depth: usize,
) anyerror!void {
    if (depth > max_include_depth) return error.StackOverflow;
    const patterns = switch (patterns_node) {
        .array => |items| items,
        else => return error.MalformedGrammar,
    };
    for (patterns) |pattern| try collectPattern(allocator, out, pattern, repository_node, parent, include_stack, depth);
}

fn collectPattern(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(textmate.RuleSummary),
    pattern_node: Node,
    repository_node: ?Node,
    parent: ?u32,
    include_stack: *textmate_include.Stack,
    depth: usize,
) anyerror!void {
    const object = switch (pattern_node) {
        .dict => |entries| entries,
        else => return,
    };
    if (dictString(object, "match")) |pattern| {
        const captures_node = dictGet(object, "captures");
        const captures = try compileCaptures(allocator, captures_node);
        errdefer if (captures.len != 0) allocator.free(captures);
        const capture_scope = try dupeOpt(allocator, firstCaptureScope(captures_node));
        errdefer if (capture_scope) |scope| allocator.free(scope);
        try out.append(allocator, .{
            .kind = .match,
            .parent = parent,
            .name = try dupeOpt(allocator, dictString(object, "name")),
            .capture_scope = capture_scope,
            .pattern = try allocator.dupe(u8, pattern),
            .captures = captures,
        });
    } else if (dictString(object, "begin")) |begin| {
        const parent_index: u32 = @intCast(out.items.len);
        try out.append(allocator, .{
            .kind = if (dictGet(object, "while") != null) .while_rule else .begin_end,
            .parent = parent,
            .name = try dupeOpt(allocator, dictString(object, "name")),
            .content_name = try dupeOpt(allocator, dictString(object, "contentName")),
            .pattern = try allocator.dupe(u8, begin),
            .end = try dupeOpt(allocator, dictString(object, "end") orelse dictString(object, "while")),
            .apply_end_pattern_last = dictBool(object, "applyEndPatternLast") orelse false,
            .captures = try compileCaptures(allocator, dictGet(object, "beginCaptures") orelse dictGet(object, "captures")),
            .end_captures = try compileCaptures(allocator, dictGet(object, "endCaptures") orelse dictGet(object, "whileCaptures")),
        });
        if (dictGet(object, "patterns")) |nested| try collectPatterns(allocator, out, nested, repository_node, parent_index, include_stack, depth + 1);
        return;
    } else if (dictString(object, "include")) |include| {
        if (std.mem.startsWith(u8, include, "#")) {
            const name = include[1..];
            if (repositoryLookup(repository_node, name)) |included| {
                if (include_stack.contains(name) or include_stack.seenBefore(name, parent)) return;
                try include_stack.markSeen(allocator, name, parent);
                try include_stack.push(name);
                defer include_stack.pop();
                try collectPattern(allocator, out, included, repository_node, parent, include_stack, depth + 1);
                return;
            }
        }
        try out.append(allocator, .{ .kind = .include, .parent = parent, .include = try allocator.dupe(u8, include) });
    }
    if (dictGet(object, "patterns")) |nested| try collectPatterns(allocator, out, nested, repository_node, parent, include_stack, depth + 1);
}

fn collectInjections(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(textmate.RuleSummary),
    injections_node: Node,
    repository_node: ?Node,
    root_scope: []const u8,
    include_stack: *textmate_include.Stack,
) !InjectionCounts {
    const injections = switch (injections_node) {
        .dict => |entries| entries,
        else => return .{},
    };
    var counts = InjectionCounts{};
    for (injections) |entry| {
        counts.total += 1;
        if (!textmate_injection.targets(entry.key, root_scope)) continue;
        counts.applied += 1;
        switch (entry.value) {
            .dict => |object| if (dictGet(object, "patterns")) |patterns|
                try collectPatterns(allocator, out, patterns, repository_node, null, include_stack, 0)
            else
                try collectPattern(allocator, out, entry.value, repository_node, null, include_stack, 0),
            else => try collectPattern(allocator, out, entry.value, repository_node, null, include_stack, 0),
        }
    }
    return counts;
}

const InjectionCounts = struct {
    total: u32 = 0,
    applied: u32 = 0,
};

fn compileCaptures(allocator: std.mem.Allocator, captures_node: ?Node) ![]textmate_captures.CaptureEntry {
    const captures = captures_node orelse return &.{};
    const entries = switch (captures) {
        .dict => |items| items,
        else => return error.MalformedGrammar,
    };
    var out = std.ArrayList(textmate_captures.CaptureEntry).empty;
    errdefer out.deinit(allocator);
    for (entries) |entry| {
        const slot = try std.fmt.parseInt(u16, entry.key, 10);
        const capture = switch (entry.value) {
            .dict => |object| object,
            else => continue,
        };
        if (dictString(capture, "name")) |name| try out.append(allocator, .{ .slot = slot, .style_id = style.styleFromScope(name) });
    }
    return out.toOwnedSlice(allocator);
}

fn firstCaptureScope(captures_node: ?Node) ?[]const u8 {
    const entries = switch (captures_node orelse return null) {
        .dict => |items| items,
        else => return null,
    };
    var best_slot: ?u16 = null;
    var best_scope: ?[]const u8 = null;
    for (entries) |entry| {
        const slot = std.fmt.parseInt(u16, entry.key, 10) catch continue;
        const capture = switch (entry.value) {
            .dict => |object| object,
            else => continue,
        };
        const scope = dictString(capture, "name") orelse continue;
        if (best_slot == null or slot < best_slot.?) {
            best_slot = slot;
            best_scope = scope;
        }
    }
    return best_scope;
}

fn repositoryLookup(repository_node: ?Node, name: []const u8) ?Node {
    const repository = switch (repository_node orelse return null) {
        .dict => |entries| entries,
        else => return null,
    };
    return dictGet(repository, name);
}

fn dictGet(dict: []const Entry, key: []const u8) ?Node {
    for (dict) |entry| if (std.mem.eql(u8, entry.key, key)) return entry.value;
    return null;
}

fn dictString(dict: []const Entry, key: []const u8) ?[]const u8 {
    return switch (dictGet(dict, key) orelse return null) {
        .string => |value| value,
        else => null,
    };
}

fn dictBool(dict: []const Entry, key: []const u8) ?bool {
    return switch (dictGet(dict, key) orelse return null) {
        .bool => |value| value,
        else => null,
    };
}

fn dupeOpt(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |v| try allocator.dupe(u8, v) else null;
}

fn freeRules(allocator: std.mem.Allocator, rules: []textmate.RuleSummary) void {
    for (rules) |rule| {
        if (rule.name) |value| allocator.free(value);
        if (rule.capture_scope) |value| allocator.free(value);
        if (rule.content_name) |value| allocator.free(value);
        if (rule.pattern) |value| allocator.free(value);
        if (rule.end) |value| allocator.free(value);
        if (rule.include) |value| allocator.free(value);
        if (rule.captures.len != 0) allocator.free(rule.captures);
        if (rule.end_captures.len != 0) allocator.free(rule.end_captures);
    }
}

fn decodeEntities(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            try out.append(allocator, raw[i]);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, raw[i..], "&lt;")) {
            try out.append(allocator, '<');
            i += 4;
        } else if (std.mem.startsWith(u8, raw[i..], "&gt;")) {
            try out.append(allocator, '>');
            i += 4;
        } else if (std.mem.startsWith(u8, raw[i..], "&amp;")) {
            try out.append(allocator, '&');
            i += 5;
        } else if (std.mem.startsWith(u8, raw[i..], "&quot;")) {
            try out.append(allocator, '"');
            i += 6;
        } else if (std.mem.startsWith(u8, raw[i..], "&apos;")) {
            try out.append(allocator, '\'');
            i += 6;
        } else return error.MalformedGrammar;
    }
    return out.toOwnedSlice(allocator);
}

test ".tmTheme plist compiles token colors" {
    const compiled = try compileTheme(std.testing.allocator,
        \\<plist><dict>
        \\<key>settings</key><array>
        \\<dict>
        \\  <key>scope</key><string>keyword.control, string.quoted.double.zig</string>
        \\  <key>settings</key><dict>
        \\    <key>foreground</key><string>#ff00aa</string>
        \\    <key>fontStyle</key><string>bold underline</string>
        \\  </dict>
        \\</dict>
        \\<dict>
        \\  <key>scope</key><string>source.zig keyword.operator.zig</string>
        \\  <key>settings</key><dict><key>foreground</key><string>#112233</string></dict>
        \\</dict>
        \\</array>
        \\</dict></plist>
    );

    try std.testing.expectEqual(@as(usize, 3), compiled.setCount());
    try std.testing.expect(compiled.styleFor(.keyword).bold);
    try std.testing.expect(compiled.styleFor(.string).underline);
    try std.testing.expectEqual(theme.Rgb{ .r = 0x11, .g = 0x22, .b = 0x33 }, compiled.styleFor(.operator).foreground.?);
}
