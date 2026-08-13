const std = @import("std");

pub fn targets(selector: []const u8, root_scope: []const u8) bool {
    var groups = std.mem.splitScalar(u8, selector, ',');
    while (groups.next()) |group| {
        if (groupTargets(group, root_scope)) return true;
    }
    return false;
}

fn groupTargets(group: []const u8, root_scope: []const u8) bool {
    var trimmed = std.mem.trim(u8, group, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[1] == ':' and (trimmed[0] == 'L' or trimmed[0] == 'R')) trimmed = trimmed[2..];
    var has_positive = false;
    var matched = false;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    while (it.next()) |part| {
        const negative = part[0] == '-';
        const scope = if (negative) part[1..] else part;
        if (scope.len == 0) continue;
        if (negative and scopeMatches(scope, root_scope)) return false;
        if (!negative) {
            has_positive = true;
            matched = matched or scopeMatches(scope, root_scope);
        }
    }
    return has_positive and matched;
}

fn scopeMatches(selector_scope: []const u8, root_scope: []const u8) bool {
    return std.mem.eql(u8, selector_scope, root_scope) or
        std.mem.startsWith(u8, root_scope, selector_scope) or
        std.mem.startsWith(u8, selector_scope, root_scope);
}

test "TextMate injection selectors target root scopes" {
    try std.testing.expect(targets("L:source.zig", "source.zig"));
    try std.testing.expect(targets("text.html source.zig", "source.zig"));
    try std.testing.expect(targets("source", "source.zig"));
    try std.testing.expect(targets("source.other, R:source.zig", "source.zig"));
    try std.testing.expect(!targets("source.other", "source.zig"));
    try std.testing.expect(!targets("source.zig -source.zig", "source.zig"));
}
