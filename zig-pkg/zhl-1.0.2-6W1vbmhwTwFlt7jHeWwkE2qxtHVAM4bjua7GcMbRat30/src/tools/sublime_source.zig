const std = @import("std");

const max_input_bytes = 64 * 1024 * 1024;

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8, source: []const u8) ![]u8 {
    return loadDepth(io, allocator, path, source, 0);
}

fn loadDepth(io: std.Io, allocator: std.mem.Allocator, path: []const u8, source: []const u8, depth: u8) ![]u8 {
    if (depth == 8) return error.SublimeExtendsDepth;
    var parent_names: [8][]const u8 = undefined;
    const parent_names_len = extendsList(source, &parent_names);
    if (parent_names_len == 0) return allocator.dupe(u8, source);

    var parents: [8][]u8 = undefined;
    var parents_len: usize = 0;
    defer for (parents[0..parents_len]) |parent| allocator.free(parent);

    var total = source.len;
    for (parent_names[0..parent_names_len]) |parent_name| {
        const parent_path = try resolveSiblingPath(allocator, path, parent_name);
        defer allocator.free(parent_path);
        const parent_source = try std.Io.Dir.cwd().readFileAlloc(io, parent_path, allocator, .limited(max_input_bytes));
        defer allocator.free(parent_source);
        const parent = try loadDepth(io, allocator, parent_path, parent_source, depth + 1);
        parents[parents_len] = parent;
        parents_len += 1;
        total += parent.len + 1;
    }

    const out = try allocator.alloc(u8, total);
    var cursor: usize = 0;
    for (parents[0..parents_len]) |parent| {
        @memcpy(out[cursor..][0..parent.len], parent);
        cursor += parent.len;
        out[cursor] = '\n';
        cursor += 1;
    }
    @memcpy(out[cursor..][0..source.len], source);
    return out;
}

fn extendsList(source: []const u8, out: *[8][]const u8) usize {
    var count: usize = 0;
    var in_extends_list = false;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "extends:")) {
            const value = stripYamlScalar(line["extends:".len..]);
            if (value.len != 0) {
                out[0] = value;
                return 1;
            }
            in_extends_list = true;
            continue;
        }
        if (!in_extends_list) continue;
        if (!std.mem.startsWith(u8, line, "- ") or count == out.len) break;
        out[count] = stripYamlScalar(line[2..]);
        count += 1;
    }
    return count;
}

fn stripYamlScalar(raw: []const u8) []const u8 {
    var value = std.mem.trim(u8, raw, " \t");
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
        (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        value = value[1 .. value.len - 1];
    }
    return value;
}

fn resolveSiblingPath(allocator: std.mem.Allocator, path: []const u8, parent_name: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(parent_name);
    return std.fs.path.join(allocator, &.{ dir, base });
}

test "extends parser handles scalar and list forms" {
    var parents: [8][]const u8 = undefined;

    try std.testing.expectEqual(@as(usize, 1), extendsList(
        \\extends: Packages/JavaScript/JavaScript.sublime-syntax
        \\contexts:
    , &parents));
    try std.testing.expectEqualStrings("Packages/JavaScript/JavaScript.sublime-syntax", parents[0]);

    try std.testing.expectEqual(@as(usize, 2), extendsList(
        \\extends:
        \\  - JSX.sublime-syntax
        \\  - TypeScript.sublime-syntax
        \\file_extensions:
    , &parents));
    try std.testing.expectEqualStrings("JSX.sublime-syntax", parents[0]);
    try std.testing.expectEqualStrings("TypeScript.sublime-syntax", parents[1]);
}
