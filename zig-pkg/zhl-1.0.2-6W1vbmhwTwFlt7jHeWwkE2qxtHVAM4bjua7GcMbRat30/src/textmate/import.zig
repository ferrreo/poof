const std = @import("std");
const textmate_captures = @import("captures.zig");
const textmate_include = @import("include.zig");
const textmate_injection = @import("injection.zig");
const textmate_plist = @import("plist.zig");
const types = @import("types.zig");

const RuleKind = types.RuleKind;
const RuleSummary = types.RuleSummary;
const Summary = types.Summary;

pub fn summarizeJson(allocator: std.mem.Allocator, source: []const u8) !Summary {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();

    const root_value = switch (parsed.value) {
        .array => |array| firstGrammarObject(array.items) orelse return error.MalformedGrammar,
        else => parsed.value,
    };
    const root = switch (root_value) {
        .object => |object| object,
        else => return error.MalformedGrammar,
    };
    const scope_name = objectString(root, "scopeName") orelse return error.MalformedGrammar;
    const name = objectString(root, "name");
    const patterns = root.get("patterns") orelse return error.MalformedGrammar;
    const repository = root.get("repository");

    var rules = std.ArrayList(RuleSummary).empty;
    var include_stack = textmate_include.Stack{};
    var repository_state = RepositoryState{};
    defer include_stack.deinit(allocator);
    defer repository_state.deinit(allocator);
    errdefer {
        types.freeRuleSummaries(allocator, rules.items);
        rules.deinit(allocator);
    }
    try collectValuePatterns(allocator, &rules, patterns, repository, null, &include_stack, &repository_state, 0);
    const injections = if (root.get("injections")) |value|
        try collectInjections(allocator, &rules, value, repository, scope_name, &include_stack, &repository_state)
    else
        InjectionCounts{};

    return .{
        .allocator = allocator,
        .scope_name = try allocator.dupe(u8, scope_name),
        .name = try dupeOpt(allocator, name),
        .first_line_match = try dupeOpt(allocator, objectString(root, "firstLineMatch")),
        .injections_total = injections.total,
        .injections_applied = injections.applied,
        .rules = try rules.toOwnedSlice(allocator),
    };
}

pub fn summarizePlist(allocator: std.mem.Allocator, xml: []const u8) !Summary {
    return textmate_plist.summarize(allocator, xml);
}

const RepositoryState = struct {
    items: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        name: []const u8,
        rule_index: u32,
    };

    fn deinit(self: *RepositoryState, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    fn find(self: *const RepositoryState, name: []const u8) ?u32 {
        for (self.items.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.rule_index;
        }
        return null;
    }

    fn put(self: *RepositoryState, allocator: std.mem.Allocator, name: []const u8, rule_index: u32) !void {
        try self.items.append(allocator, .{ .name = name, .rule_index = rule_index });
    }
};

fn ensureRepositoryGroup(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(RuleSummary),
    name: []const u8,
    included: std.json.Value,
    repository_value: ?std.json.Value,
    include_stack: *textmate_include.Stack,
    repository_state: *RepositoryState,
    depth: usize,
) anyerror!u32 {
    if (repository_state.find(name)) |existing| return existing;
    const group_index: u32 = @intCast(out.items.len);
    try out.append(allocator, .{ .kind = .repository, .include = try allocator.dupe(u8, name) });
    try repository_state.put(allocator, name, group_index);
    if (include_stack.contains(name)) return group_index;
    try include_stack.push(name);
    defer include_stack.pop();
    try collectValuePattern(allocator, out, included, repository_value, group_index, include_stack, repository_state, depth);
    return group_index;
}

fn collectValuePatterns(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(RuleSummary),
    patterns_value: std.json.Value,
    repository_value: ?std.json.Value,
    parent: ?u32,
    include_stack: *textmate_include.Stack,
    repository_state: *RepositoryState,
    depth: usize,
) anyerror!void {
    if (depth > textmate_include.max_depth) return error.StackOverflow;
    const patterns = switch (patterns_value) {
        .array => |array| array.items,
        else => return error.MalformedGrammar,
    };
    for (patterns) |pattern| {
        try collectValuePattern(allocator, out, pattern, repository_value, parent, include_stack, repository_state, depth);
    }
}

fn collectValuePattern(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(RuleSummary),
    pattern_value: std.json.Value,
    repository_value: ?std.json.Value,
    parent: ?u32,
    include_stack: *textmate_include.Stack,
    repository_state: *RepositoryState,
    depth: usize,
) anyerror!void {
    const object = switch (pattern_value) {
        .object => |object| object,
        else => return,
    };

    if (object.get("match")) |match_value| {
        const pattern = valueString(match_value) orelse return error.MalformedGrammar;
        const name = objectString(object, "name");
        const captures_value = object.get("captures");
        const captures = try compileCaptureEntries(allocator, captures_value);
        errdefer freeCaptures(allocator, captures);
        const capture_scope = try dupeOpt(allocator, firstCaptureScope(captures_value));
        errdefer if (capture_scope) |scope| allocator.free(scope);
        if (findMatchRule(out.items, parent, name, capture_scope, pattern, captures) != null) {
            freeCaptures(allocator, captures);
            if (capture_scope) |scope| allocator.free(scope);
            return;
        }
        try out.append(allocator, .{
            .kind = .match,
            .parent = parent,
            .name = try dupeOpt(allocator, name),
            .capture_scope = capture_scope,
            .pattern = try allocator.dupe(u8, pattern),
            .captures = captures,
        });
        return;
    } else if (object.get("begin")) |begin_value| {
        const begin = valueString(begin_value) orelse return error.MalformedGrammar;
        const end = objectString(object, "end") orelse objectString(object, "while");
        const kind: RuleKind = if (object.get("while") != null) .while_rule else .begin_end;
        const name = objectString(object, "name");
        const content_name = objectString(object, "contentName");
        const apply_end_pattern_last = objectBool(object, "applyEndPatternLast") orelse false;
        const captures = try compileCaptureEntries(allocator, object.get("beginCaptures") orelse object.get("captures"));
        const end_captures = try compileCaptureEntries(allocator, object.get("endCaptures") orelse object.get("whileCaptures"));
        var captures_in_rule = false;
        errdefer if (!captures_in_rule) {
            freeCaptures(allocator, captures);
            freeCaptures(allocator, end_captures);
        };
        var reused = false;
        const parent_summary_index = if (findBeginRule(out.items, parent, kind, name, content_name, begin, end, apply_end_pattern_last, captures, end_captures)) |existing| blk: {
            reused = true;
            break :blk existing;
        } else blk: {
            const index: u32 = @intCast(out.items.len);
            var rule = RuleSummary{
                .kind = kind,
                .parent = parent,
                .name = try dupeOpt(allocator, name),
                .content_name = try dupeOpt(allocator, content_name),
                .pattern = try allocator.dupe(u8, begin),
                .end = try dupeOpt(allocator, end),
                .apply_end_pattern_last = apply_end_pattern_last,
                .captures = captures,
                .end_captures = end_captures,
            };
            captures_in_rule = true;
            var transferred = false;
            errdefer if (!transferred) freeRuleSummary(allocator, &rule);
            try out.append(allocator, rule);
            transferred = true;
            break :blk index;
        };
        if (reused) {
            freeCaptures(allocator, captures);
            freeCaptures(allocator, end_captures);
            captures_in_rule = true;
        }
        if (object.get("patterns")) |nested| {
            try collectValuePatterns(allocator, out, nested, repository_value, parent_summary_index, include_stack, repository_state, depth + 1);
        }
        return;
    } else if (object.get("include")) |include_value| {
        const include = valueString(include_value) orelse return error.MalformedGrammar;
        if (std.mem.startsWith(u8, include, "#")) {
            if (repository_value) |repository| {
                if (repositoryLookup(repository, include[1..])) |included| {
                    const name = include[1..];
                    _ = try ensureRepositoryGroup(allocator, out, name, included, repository_value, include_stack, repository_state, depth + 1);
                    try out.append(allocator, .{ .kind = .include, .parent = parent, .include = try allocator.dupe(u8, include) });
                    return;
                }
            }
        }
        try out.append(allocator, .{ .kind = .include, .parent = parent, .include = try allocator.dupe(u8, include) });
    }

    if (object.get("patterns")) |nested| {
        try collectValuePatterns(allocator, out, nested, repository_value, parent, include_stack, repository_state, depth + 1);
    }
}

fn findMatchRule(rules: []const RuleSummary, parent: ?u32, name: ?[]const u8, capture_scope: ?[]const u8, pattern: []const u8, captures: []const textmate_captures.CaptureEntry) ?u32 {
    for (rules, 0..) |rule, index| {
        if (rule.kind != .match or rule.parent != parent) continue;
        if (!optEql(rule.name, name) or !optEql(rule.capture_scope, capture_scope) or !optEql(rule.pattern, pattern)) continue;
        if (!capturesEql(rule.captures, captures)) continue;
        return @intCast(index);
    }
    return null;
}

fn findBeginRule(
    rules: []const RuleSummary,
    parent: ?u32,
    kind: RuleKind,
    name: ?[]const u8,
    content_name: ?[]const u8,
    pattern: []const u8,
    end: ?[]const u8,
    apply_end_pattern_last: bool,
    captures: []const textmate_captures.CaptureEntry,
    end_captures: []const textmate_captures.CaptureEntry,
) ?u32 {
    for (rules, 0..) |rule, index| {
        if (rule.kind != kind or rule.parent != parent) continue;
        if (!optEql(rule.name, name) or !optEql(rule.content_name, content_name)) continue;
        if (!optEql(rule.pattern, pattern) or !optEql(rule.end, end)) continue;
        if (rule.apply_end_pattern_last != apply_end_pattern_last) continue;
        if (!capturesEql(rule.captures, captures) or !capturesEql(rule.end_captures, end_captures)) continue;
        return @intCast(index);
    }
    return null;
}

fn repositoryLookup(repository_value: std.json.Value, name: []const u8) ?std.json.Value {
    const repository = switch (repository_value) {
        .object => |object| object,
        else => return null,
    };
    return repository.get(name);
}

fn firstGrammarObject(items: []std.json.Value) ?std.json.Value {
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const item = items[i];
        const object = switch (item) {
            .object => |object| object,
            else => continue,
        };
        if (object.get("scopeName") != null and object.get("patterns") != null) return item;
    }
    return null;
}

fn compileCaptureEntries(allocator: std.mem.Allocator, value: ?std.json.Value) ![]textmate_captures.CaptureEntry {
    const captures = value orelse return &.{};
    const plan = try textmate_captures.compile(allocator, captures);
    return plan.entries;
}

fn firstCaptureScope(value: ?std.json.Value) ?[]const u8 {
    switch (value orelse return null) {
        .object => |object| {
            var best_slot: ?u16 = null;
            var best_scope: ?[]const u8 = null;
            var it = object.iterator();
            while (it.next()) |entry| {
                const slot = std.fmt.parseInt(u16, entry.key_ptr.*, 10) catch continue;
                const scope = captureScope(entry.value_ptr.*) orelse continue;
                if (best_slot == null or slot < best_slot.?) {
                    best_slot = slot;
                    best_scope = scope;
                }
            }
            return best_scope;
        },
        .array => |array| for (array.items) |item| {
            if (captureScope(item)) |scope| return scope;
        },
        else => return null,
    }
    return null;
}

fn captureScope(value: std.json.Value) ?[]const u8 {
    const capture = switch (value) {
        .object => |capture| capture,
        else => return null,
    };
    return objectString(capture, "name");
}

fn freeCaptures(allocator: std.mem.Allocator, captures: []textmate_captures.CaptureEntry) void {
    if (captures.len != 0) allocator.free(captures);
}

fn freeRuleSummary(allocator: std.mem.Allocator, rule: *RuleSummary) void {
    if (rule.name) |value| allocator.free(value);
    if (rule.capture_scope) |value| allocator.free(value);
    if (rule.content_name) |value| allocator.free(value);
    if (rule.pattern) |value| allocator.free(value);
    if (rule.end) |value| allocator.free(value);
    if (rule.include) |value| allocator.free(value);
    freeCaptures(allocator, rule.captures);
    freeCaptures(allocator, rule.end_captures);
}

const InjectionCounts = struct {
    total: u32 = 0,
    applied: u32 = 0,
};

fn collectInjections(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(RuleSummary),
    injections_value: std.json.Value,
    repository_value: ?std.json.Value,
    root_scope: []const u8,
    include_stack: *textmate_include.Stack,
    repository_state: *RepositoryState,
) !InjectionCounts {
    const injections = switch (injections_value) {
        .object => |object| object,
        else => return .{},
    };
    var counts = InjectionCounts{};
    var it = injections.iterator();
    while (it.next()) |entry| {
        counts.total += 1;
        if (!textmate_injection.targets(entry.key_ptr.*, root_scope)) continue;
        counts.applied += 1;
        const value = entry.value_ptr.*;
        switch (value) {
            .object => |object| if (object.get("patterns")) |patterns|
                try collectValuePatterns(allocator, out, patterns, repository_value, null, include_stack, repository_state, 0)
            else
                try collectValuePattern(allocator, out, value, repository_value, null, include_stack, repository_state, 0),
            else => try collectValuePattern(allocator, out, value, repository_value, null, include_stack, repository_state, 0),
        }
    }
    return counts;
}

fn dupeOpt(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |v| try allocator.dupe(u8, v) else null;
}

fn objectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return valueString(object.get(key) orelse return null);
}

fn objectBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    return switch (object.get(key) orelse return null) {
        .bool => |v| v,
        else => null,
    };
}

fn valueString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn capturesEql(a: []const textmate_captures.CaptureEntry, b: []const textmate_captures.CaptureEntry) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.slot != right.slot or left.style_id != right.style_id) return false;
    }
    return true;
}
