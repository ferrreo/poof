const std = @import("std");
const textmate = @import("root.zig");

pub fn externalReachable(root: textmate.Summary, scope: []const u8, external: []const textmate.Summary) bool {
    var visited = [_]bool{false} ** 1024;
    return externalReachableOne(root, scope, external, &visited);
}

pub fn unresolvedExternalIncludes(root: textmate.Summary, external: []const textmate.Summary) usize {
    var visited = [_]bool{false} ** 1024;
    return unresolvedExternalIncludesOne(root, root.scope_name, external, &visited);
}

pub fn writeUnresolvedExternalIncludes(writer: anytype, root: textmate.Summary, external: []const textmate.Summary) !void {
    var visited = [_]bool{false} ** 1024;
    var emitted = [_][]const u8{""} ** 256;
    var emitted_len: usize = 0;
    try writeUnresolvedExternalIncludesOne(writer, root, root.scope_name, external, &visited, &emitted, &emitted_len);
}

fn externalReachableOne(summary: textmate.Summary, scope: []const u8, external: []const textmate.Summary, visited: *[1024]bool) bool {
    for (summary.rules) |rule| {
        if (rule.kind != .include) continue;
        const include = externalIncludeScope(externalInclude(rule.include) orelse continue);
        if (std.mem.eql(u8, include, scope)) return true;
        for (external, 0..) |child, index| {
            if (!std.mem.eql(u8, child.scope_name, include)) continue;
            if (index < visited.len and visited[index]) continue;
            if (index < visited.len) visited[index] = true;
            if (externalReachableOne(child, scope, external, visited)) return true;
        }
    }
    return false;
}

fn unresolvedExternalIncludesOne(summary: textmate.Summary, root_scope: []const u8, external: []const textmate.Summary, visited: *[1024]bool) usize {
    var missing: usize = 0;
    for (summary.rules) |rule| {
        if (rule.kind != .include) continue;
        const include = externalInclude(rule.include) orelse continue;
        missing += unresolvedExternalInclude(include, root_scope, external, visited);
    }
    return missing;
}

fn writeUnresolvedExternalIncludesOne(
    writer: anytype,
    summary: textmate.Summary,
    root_scope: []const u8,
    external: []const textmate.Summary,
    visited: *[1024]bool,
    emitted: *[256][]const u8,
    emitted_len: *usize,
) anyerror!void {
    for (summary.rules) |rule| {
        if (rule.kind != .include) continue;
        const include = externalInclude(rule.include) orelse continue;
        try writeUnresolvedExternalInclude(writer, include, root_scope, external, visited, emitted, emitted_len);
    }
}

fn writeUnresolvedExternalInclude(
    writer: anytype,
    scope: []const u8,
    root_scope: []const u8,
    external: []const textmate.Summary,
    visited: *[1024]bool,
    emitted: *[256][]const u8,
    emitted_len: *usize,
) anyerror!void {
    const summary_scope = externalIncludeScope(scope);
    if (std.mem.eql(u8, summary_scope, root_scope)) return;
    for (external, 0..) |summary, index| {
        if (!std.mem.eql(u8, summary.scope_name, summary_scope)) continue;
        if (index < visited.len) {
            if (visited[index]) return;
            visited[index] = true;
        }
        return writeUnresolvedExternalIncludesOne(writer, summary, root_scope, external, visited, emitted, emitted_len);
    }
    for (emitted.*[0..emitted_len.*]) |seen| {
        if (std.mem.eql(u8, seen, summary_scope)) return;
    }
    if (emitted_len.* < emitted.len) {
        emitted.*[emitted_len.*] = summary_scope;
        emitted_len.* += 1;
    }
    try writer.print("missing external {s}\n", .{summary_scope});
}

fn unresolvedExternalInclude(scope: []const u8, root_scope: []const u8, external: []const textmate.Summary, visited: *[1024]bool) usize {
    const summary_scope = externalIncludeScope(scope);
    if (std.mem.eql(u8, summary_scope, root_scope)) return 0;
    for (external, 0..) |summary, index| {
        if (!std.mem.eql(u8, summary.scope_name, summary_scope)) continue;
        if (index < visited.len) {
            if (visited[index]) return 0;
            visited[index] = true;
        }
        return unresolvedExternalIncludesOne(summary, root_scope, external, visited);
    }
    return 1;
}

fn externalIncludeScope(scope: []const u8) []const u8 {
    return scope[0 .. std.mem.indexOfScalar(u8, scope, '#') orelse scope.len];
}

fn externalInclude(include: ?[]const u8) ?[]const u8 {
    const value = include orelse return null;
    if (std.mem.eql(u8, value, "$self") or std.mem.eql(u8, value, "$base") or std.mem.startsWith(u8, value, "#")) return null;
    return value;
}

test "TextMate reachability reports unresolved external scopes once" {
    const root = textmate.Summary{
        .allocator = std.testing.allocator,
        .scope_name = @constCast("source.root"),
        .name = null,
        .rules = @constCast(&[_]textmate.RuleSummary{
            .{ .kind = .include, .include = @constCast("source.child#repo") },
            .{ .kind = .include, .include = @constCast("source.child") },
            .{ .kind = .include, .include = @constCast("$self") },
        }),
    };
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeUnresolvedExternalIncludes(&writer, root, &.{});
    try std.testing.expectEqualStrings("missing external source.child\n", writer.buffered());
}
