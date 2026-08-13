const std = @import("std");

pub const Error = error{
    DuplicateCookie,
    InvalidCookieName,
    InvalidCookieValue,
    NoSpaceLeft,
};

pub fn find(headers: []const []const u8, name: []const u8) Error!?[]const u8 {
    if (!validName(name)) return error.InvalidCookieName;
    var selected: ?[]const u8 = null;
    for (headers) |header| {
        var pairs = std.mem.splitScalar(u8, header, ';');
        while (pairs.next()) |raw_pair| {
            const pair = std.mem.trim(u8, raw_pair, " \t");
            if (pair.len == 0) continue;
            const separator = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const candidate_name = std.mem.trim(u8, pair[0..separator], " \t");
            if (!std.mem.eql(u8, candidate_name, name)) continue;
            const value = std.mem.trim(u8, pair[separator + 1 ..], " \t");
            if (!validValue(value)) return error.InvalidCookieValue;
            if (selected != null) return error.DuplicateCookie;
            selected = value;
        }
    }
    return selected;
}

pub const Options = struct {
    secure: bool = true,
    http_only: bool = true,
    same_site: enum { strict, lax, none } = .lax,
    max_age_seconds: ?u32 = null,
};

pub fn write(
    output: []u8,
    name: []const u8,
    value: []const u8,
    options: Options,
) Error![]const u8 {
    if (!validName(name)) return error.InvalidCookieName;
    if (!validValue(value)) return error.InvalidCookieValue;
    if (std.mem.startsWith(u8, name, "__Host-") and !options.secure) {
        return error.InvalidCookieValue;
    }
    if (options.same_site == .none and !options.secure) return error.InvalidCookieValue;

    var writer = std.Io.Writer.fixed(output);
    writer.print("{s}={s}; Path=/", .{ name, value }) catch return error.NoSpaceLeft;
    if (options.max_age_seconds) |seconds| {
        writer.print("; Max-Age={d}", .{seconds}) catch return error.NoSpaceLeft;
    }
    if (options.secure) writer.writeAll("; Secure") catch return error.NoSpaceLeft;
    if (options.http_only) writer.writeAll("; HttpOnly") catch return error.NoSpaceLeft;
    writer.writeAll("; SameSite=") catch return error.NoSpaceLeft;
    writer.writeAll(switch (options.same_site) {
        .strict => "Strict",
        .lax => "Lax",
        .none => "None",
    }) catch return error.NoSpaceLeft;
    return output[0..writer.end];
}

fn validName(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '!' and byte != '#' and byte != '$' and byte != '%' and
            byte != '&' and byte != '\'' and byte != '*' and byte != '+' and
            byte != '-' and byte != '.' and byte != '^' and byte != '_' and
            byte != '`' and byte != '|' and byte != '~')
        {
            return false;
        }
    }
    return true;
}

fn validValue(value: []const u8) bool {
    for (value) |byte| {
        if (byte < 0x21 or byte > 0x7e or byte == '"' or byte == ',' or
            byte == ';' or byte == '\\')
        {
            return false;
        }
    }
    return true;
}

test "cookie lookup rejects duplicate names across headers" {
    const headers = [_][]const u8{
        "theme=dark; __Host-poof-session=first",
        "__Host-poof-session=second",
    };
    try std.testing.expectError(
        error.DuplicateCookie,
        find(&headers, "__Host-poof-session"),
    );
}

test "cookie writer applies secure host policy" {
    var storage: [256]u8 = undefined;
    const header = try write(
        &storage,
        "__Host-poof-session",
        "abc_123",
        .{ .max_age_seconds = 3600 },
    );
    try std.testing.expectEqualStrings(
        "__Host-poof-session=abc_123; Path=/; Max-Age=3600; Secure; HttpOnly; SameSite=Lax",
        header,
    );
    try std.testing.expectError(
        error.InvalidCookieValue,
        write(&storage, "__Host-poof-session", "abc", .{ .secure = false }),
    );
}
