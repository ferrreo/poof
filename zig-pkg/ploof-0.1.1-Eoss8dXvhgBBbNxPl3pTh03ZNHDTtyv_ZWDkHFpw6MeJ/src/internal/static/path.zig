const std = @import("std");
const syntax = @import("../http1/syntax.zig");

pub const Issue = enum(u8) {
    bytes_limit,
    shape_mismatch,
    invalid_raw_byte,
    invalid_escape,
    encoded_separator,
    nul,
    backslash,
    empty_component,
    dot_component,
    hidden_component,
};

pub const Selected = struct {
    relative_path: []const u8,
    trailing_slash: bool,
};

pub const Selection = union(enum) {
    selected: Selected,
    rejected: Issue,
};

/// Both suffixes are empty or begin with the mount-separating slash.
pub fn select(raw_suffix: []const u8, decoded_suffix: []const u8, bytes_max: u16) Selection {
    if (!validSuffixShape(raw_suffix) or !validSuffixShape(decoded_suffix)) {
        return .{ .rejected = .shape_mismatch };
    }
    if (relativeBytes(raw_suffix) > bytes_max or relativeBytes(decoded_suffix) > bytes_max) {
        return .{ .rejected = .bytes_limit };
    }
    if (rawIssue(raw_suffix)) |problem| return .{ .rejected = problem };
    if (!decodedMatchesRaw(raw_suffix, decoded_suffix)) {
        return .{ .rejected = .shape_mismatch };
    }
    if (decodedIssue(decoded_suffix)) |problem| return .{ .rejected = problem };
    const trailing_slash = hasTrailingSlash(decoded_suffix);
    const relative_path = if (decoded_suffix.len <= 1)
        decoded_suffix[0..0]
    else
        decoded_suffix[1 .. decoded_suffix.len - @intFromBool(trailing_slash)];
    return .{ .selected = .{
        .relative_path = relative_path,
        .trailing_slash = trailing_slash,
    } };
}

pub fn configuredRelativeIssue(path: []const u8, bytes_max: u16) ?Issue {
    if (path.len == 0) return .empty_component;
    if (path.len > bytes_max) return .bytes_limit;
    if (path[0] == '/') return .shape_mismatch;
    return decodedComponentsIssue(path);
}

pub fn configuredIndexIssue(path: []const u8, bytes_max: u16) ?Issue {
    const problem = configuredRelativeIssue(path, bytes_max);
    if (problem != null) return problem;
    if (std.mem.indexOfScalar(u8, path, '/') != null) return .shape_mismatch;
    return null;
}

fn validSuffixShape(path: []const u8) bool {
    return path.len == 0 or path[0] == '/';
}

fn relativeBytes(path: []const u8) usize {
    if (path.len <= 1) return 0;
    return path.len - 1 - @intFromBool(hasTrailingSlash(path));
}

fn hasTrailingSlash(path: []const u8) bool {
    return path.len != 0 and path[path.len - 1] == '/';
}

fn rawIssue(path: []const u8) ?Issue {
    var index: usize = 0;
    while (index < path.len) {
        const byte = path[index];
        if (byte == '%') {
            if (path.len - index < 3) return .invalid_escape;
            const high = hexValue(path[index + 1]);
            const low = hexValue(path[index + 2]);
            if (high >= 16 or low >= 16) return .invalid_escape;
            const decoded = high << 4 | low;
            if (decoded == '/' or decoded == '\\') return .encoded_separator;
            index += 3;
            continue;
        }
        if (byte == 0) return .nul;
        if (byte == '\\') return .backslash;
        if (byte != '/' and !syntax.isUriPchar(byte)) return .invalid_raw_byte;
        index += 1;
    }
    if (path.len <= 1) return null;
    return componentIssue(path[1 .. path.len - @intFromBool(hasTrailingSlash(path))]);
}

fn decodedIssue(path: []const u8) ?Issue {
    if (path.len <= 1) return null;
    return decodedComponentsIssue(path[1 .. path.len - @intFromBool(hasTrailingSlash(path))]);
}

fn decodedComponentsIssue(path: []const u8) ?Issue {
    for (path) |byte| {
        if (byte == 0) return .nul;
        if (byte == '\\') return .backslash;
    }
    return componentIssue(path);
}

fn componentIssue(path: []const u8) ?Issue {
    var start: usize = 0;
    while (start <= path.len) {
        const end = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
        const component = path[start..end];
        if (component.len == 0) return .empty_component;
        if (component[0] == '.') {
            if (component.len == 1 or std.mem.eql(u8, component, "..")) {
                return .dot_component;
            }
            return .hidden_component;
        }
        if (end == path.len) break;
        start = end + 1;
    }
    return null;
}

fn decodedMatchesRaw(raw: []const u8, decoded: []const u8) bool {
    var raw_index: usize = 0;
    var decoded_index: usize = 0;
    while (raw_index < raw.len) {
        if (decoded_index == decoded.len) return false;
        const byte = if (raw[raw_index] == '%') blk: {
            const value = hexValue(raw[raw_index + 1]) << 4 | hexValue(raw[raw_index + 2]);
            raw_index += 3;
            break :blk value;
        } else blk: {
            const value = raw[raw_index];
            raw_index += 1;
            break :blk value;
        };
        if (decoded[decoded_index] != byte) return false;
        decoded_index += 1;
    }
    return decoded_index == decoded.len;
}

fn hexValue(byte: u8) u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => 16,
    };
}

test "raw and decoded suffixes produce only confined relative paths" {
    const selected = select("/css/site.css", "/css/site.css", 64);
    try std.testing.expectEqualStrings("css/site.css", selected.selected.relative_path);
    try std.testing.expect(!selected.selected.trailing_slash);
    try std.testing.expectEqualStrings("", select("", "", 64).selected.relative_path);
    try std.testing.expect(!select("", "", 64).selected.trailing_slash);
    try std.testing.expectEqualStrings("", select("/", "/", 64).selected.relative_path);
    try std.testing.expect(select("/", "/", 64).selected.trailing_slash);
    try std.testing.expectEqualStrings(
        "caf\xc3\xa9.txt",
        select("/caf%C3%A9.txt", "/caf\xc3\xa9.txt", 64).selected.relative_path,
    );
}

test "terminal slash preserves canonical nested directory shape" {
    const bare = select("/docs/api", "/docs/api", 64).selected;
    try std.testing.expectEqualStrings("docs/api", bare.relative_path);
    try std.testing.expect(!bare.trailing_slash);

    const canonical = select("/docs/api/", "/docs/api/", 64).selected;
    try std.testing.expectEqualStrings("docs/api", canonical.relative_path);
    try std.testing.expect(canonical.trailing_slash);
    try std.testing.expectEqual(
        Issue.empty_component,
        select("/docs//api/", "/docs//api/", 64).rejected,
    );
}

test "path security corpus rejects alternate traversal spellings" {
    const cases = [_]struct { raw: []const u8, decoded: []const u8, issue: Issue }{
        .{ .raw = "/../key", .decoded = "/../key", .issue = .dot_component },
        .{ .raw = "/%2e%2e/key", .decoded = "/../key", .issue = .dot_component },
        .{ .raw = "/.git/config", .decoded = "/.git/config", .issue = .hidden_component },
        .{ .raw = "/a//b", .decoded = "/a//b", .issue = .empty_component },
        .{ .raw = "/a%2fb", .decoded = "/a/b", .issue = .encoded_separator },
        .{ .raw = "/a%5Cb", .decoded = "/a\\b", .issue = .encoded_separator },
        .{ .raw = "/a\\b", .decoded = "/a\\b", .issue = .backslash },
        .{ .raw = "/a%00b", .decoded = "/a\x00b", .issue = .nul },
        .{ .raw = "/bad%", .decoded = "/bad%", .issue = .invalid_escape },
        .{ .raw = "/safe", .decoded = "/other", .issue = .shape_mismatch },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.issue, select(case.raw, case.decoded, 64).rejected);
    }
}

test "configured relative paths and indexes obey the same component policy" {
    try std.testing.expectEqual(@as(?Issue, null), configuredRelativeIssue("a/b.txt", 64));
    try std.testing.expectEqual(@as(?Issue, null), configuredIndexIssue("home.html", 64));
    try std.testing.expectEqual(Issue.hidden_component, configuredRelativeIssue(".env", 64));
    try std.testing.expectEqual(Issue.shape_mismatch, configuredIndexIssue("a/index.html", 64));
}
