const std = @import("std");
const syntax = @import("syntax.zig");

pub const owned_names = [_][]const u8{
    "content-length",
    "transfer-encoding",
    "trailer",
    "connection",
    "keep-alive",
    "proxy-connection",
    "te",
    "upgrade",
    "date",
    "via",
    "alt-svc",
    "server",
};

pub const singleton_names = [_][]const u8{
    "content-type",
    "content-encoding",
    "location",
    "etag",
    "last-modified",
};

pub const forbidden_trailer_names = [_][]const u8{
    "content-length",
    "transfer-encoding",
    "trailer",
    "connection",
    "keep-alive",
    "proxy-connection",
    "te",
    "upgrade",
    "date",
    "server",
    "via",
    "alt-svc",
    "content-type",
    "content-encoding",
    "content-range",
    "set-cookie",
    "www-authenticate",
    "proxy-authenticate",
    "authentication-info",
    "location",
    "retry-after",
    "vary",
    "cache-control",
    "expires",
};

pub fn isOwnedName(name: []const u8) bool {
    return nameInTable(name, &owned_names);
}

pub fn isSingletonName(name: []const u8) bool {
    return nameInTable(name, &singleton_names);
}

pub fn isForbiddenTrailerName(name: []const u8) bool {
    return nameInTable(name, &forbidden_trailer_names);
}

fn nameInTable(name: []const u8, table: []const []const u8) bool {
    for (table) |known| {
        if (syntax.eqlIgnoreCase(name, known)) return true;
    }
    return false;
}

test "response field policy tables are unique and case insensitive" {
    inline for (.{ owned_names, singleton_names, forbidden_trailer_names }) |table| {
        for (table, 0..) |name, index| {
            try std.testing.expect(nameInTable(name, &table));
            for (table[0..index]) |prior| {
                try std.testing.expect(!syntax.eqlIgnoreCase(name, prior));
            }
        }
    }
    try std.testing.expect(isOwnedName("CONTENT-LENGTH"));
    try std.testing.expect(isSingletonName("ETAG"));
    try std.testing.expect(isForbiddenTrailerName("DATE"));
}
