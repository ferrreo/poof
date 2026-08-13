const std = @import("std");
const regex_escape = @import("../regex/escape.zig");
const sublime = @import("import.zig");
const textmate_dynamic = @import("../textmate/dynamic/root.zig");

pub const Pair = struct {
    pop_index: usize,
    scope: []const u8,
    prefix: []const u8,
    delimiter: u8,
    marker: u8,
};

pub fn popConsumed(rules: []const sublime.Rule, index: usize, prefix_buf: []u8) bool {
    const rule = rules[index];
    if (rule.action != .pop) return false;
    for (rules, 0..) |open_rule, open_index| {
        if (open_rule.action != .push and open_rule.action != .set) continue;
        const found = pair(rules, open_index, prefix_buf) orelse continue;
        if (found.pop_index == index) return true;
    }
    return false;
}

pub fn pair(rules: []const sublime.Rule, index: usize, prefix_buf: []u8) ?Pair {
    const open_rule = rules[index];
    if (open_rule.action != .push and open_rule.action != .set) return null;
    if (open_rule.target.len == 0 or open_rule.match.len == 0) return null;
    for (rules, 0..) |pop_rule, pop_index| {
        if (pop_rule.action != .pop or !std.mem.eql(u8, pop_rule.context, open_rule.target)) continue;
        const scope = preferredScope(open_rule, pop_rule) orelse continue;
        if (!contains(scope, "string")) continue;
        const dynamic = textmate_dynamic.parse(pop_rule.match) orelse continue;
        if (dynamic.prefix_len != 1) continue;
        const open = markerOpen(open_rule.match, dynamic.slot, dynamic.prefix[0], prefix_buf) orelse continue;
        return .{ .pop_index = pop_index, .scope = scope, .prefix = open.prefix, .delimiter = dynamic.prefix[0], .marker = open.marker };
    }
    return null;
}

const MarkerOpen = struct { prefix: []const u8, marker: u8 };

fn markerOpen(pattern: []const u8, slot: u8, delimiter: u8, prefix_buf: []u8) ?MarkerOpen {
    var capture: u8 = 0;
    var prefix_len: usize = 0;
    var marker: ?u8 = null;
    var suffix_len: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '(' => {
                if (!isCapturingGroup(pattern, i)) return null;
                capture += 1;
                if (capture == slot) {
                    const parsed = markerGroup(pattern, i) orelse return null;
                    marker = parsed.marker;
                    i = parsed.end;
                }
            },
            ')' => {},
            else => {
                const byte = regexByte(pattern, &i) orelse return null;
                if (marker == null) {
                    if (prefix_len == prefix_buf.len) return null;
                    prefix_buf[prefix_len] = byte;
                    prefix_len += 1;
                } else {
                    if (byte != delimiter) return null;
                    suffix_len += 1;
                }
            },
        }
    }
    return if (marker) |byte| if (suffix_len == 1) .{ .prefix = prefix_buf[0..prefix_len], .marker = byte } else null else null;
}

fn markerGroup(pattern: []const u8, start: usize) ?struct { marker: u8, end: usize } {
    var i = start + 1;
    const marker = regexByte(pattern, &i) orelse return null;
    return if (i + 2 < pattern.len and pattern[i + 1] == '*' and pattern[i + 2] == ')') .{ .marker = marker, .end = i + 2 } else null;
}

fn regexByte(pattern: []const u8, index: *usize) ?u8 {
    var byte = pattern[index.*];
    if (byte == '\\') {
        index.* += 1;
        if (index.* >= pattern.len) return null;
        byte = regex_escape.byte(pattern[index.*]);
    } else if (std.mem.indexOfScalar(u8, ".^$*+?[]{}|()", byte) != null) return null;
    return byte;
}

fn isCapturingGroup(pattern: []const u8, start: usize) bool {
    if (start >= 2 and pattern[start - 2] == '(' and pattern[start - 1] == '?') return false;
    if (start + 1 >= pattern.len or pattern[start + 1] != '?') return true;
    if (start + 2 >= pattern.len) return false;
    if (pattern[start + 2] == '\'') return true;
    if (pattern[start + 2] != '<') return false;
    return start + 3 >= pattern.len or (pattern[start + 3] != '=' and pattern[start + 3] != '!');
}

fn preferredScope(open_rule: sublime.Rule, pop_rule: sublime.Rule) ?[]const u8 {
    if (contains(pop_rule.context_scope, "string")) return pop_rule.context_scope;
    if (contains(open_rule.scope, "string")) return open_rule.scope;
    if (contains(open_rule.capture_scope, "string")) return open_rule.capture_scope;
    if (contains(pop_rule.scope, "string")) return pop_rule.scope;
    if (contains(pop_rule.capture_scope, "string")) return pop_rule.capture_scope;
    return null;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "Sublime marker pair lowers captured marker delimiters" {
    const rules = [_]sublime.Rule{
        .{ .context = @constCast("main"), .match = @constCast("(r)(#*)\""), .target = @constCast("raw"), .action = .push },
        .{ .context = @constCast("raw"), .context_scope = @constCast("string.quoted.raw.test"), .match = @constCast("\"\\2"), .scope = @constCast("punctuation.definition.string.end.test"), .action = .pop },
    };
    var buf: [64]u8 = undefined;
    const found = pair(&rules, 0, &buf).?;
    try std.testing.expectEqual(@as(usize, 1), found.pop_index);
    try std.testing.expectEqualStrings("r", found.prefix);
    try std.testing.expectEqual(@as(u8, '"'), found.delimiter);
    try std.testing.expectEqual(@as(u8, '#'), found.marker);
    try std.testing.expect(popConsumed(&rules, 1, &buf));
}
