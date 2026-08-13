const std = @import("std");
const media_type = @import("../http1/media_type.zig");
const syntax = @import("../http1/syntax.zig");

pub const table_version: u16 = 1;

const Entry = struct {
    extension: []const u8,
    value: media_type.MediaType,
};

const table = makeTable();

fn makeTable() [33]Entry {
    @setEvalBranchQuota(20_000);
    return .{
        entry("avif", "image/avif"),
        entry("bin", "application/octet-stream"),
        entry("css", "text/css; charset=utf-8"),
        entry("csv", "text/csv; charset=utf-8"),
        entry("gif", "image/gif"),
        entry("gz", "application/gzip"),
        entry("htm", "text/html; charset=utf-8"),
        entry("html", "text/html; charset=utf-8"),
        entry("ico", "image/x-icon"),
        entry("jpeg", "image/jpeg"),
        entry("jpg", "image/jpeg"),
        entry("js", "text/javascript; charset=utf-8"),
        entry("json", "application/json; charset=utf-8"),
        entry("map", "application/json; charset=utf-8"),
        entry("mjs", "text/javascript; charset=utf-8"),
        entry("mp3", "audio/mpeg"),
        entry("mp4", "video/mp4"),
        entry("ogg", "audio/ogg"),
        entry("otf", "font/otf"),
        entry("pdf", "application/pdf"),
        entry("png", "image/png"),
        entry("svg", "image/svg+xml"),
        entry("tar", "application/x-tar"),
        entry("ttf", "font/ttf"),
        entry("txt", "text/plain; charset=utf-8"),
        entry("wasm", "application/wasm"),
        entry("wav", "audio/wav"),
        entry("webm", "video/webm"),
        entry("webp", "image/webp"),
        entry("woff", "font/woff"),
        entry("woff2", "font/woff2"),
        entry("xml", "application/xml"),
        entry("zip", "application/zip"),
    };
}

pub fn forFilename(filename: []const u8) media_type.MediaType {
    const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return media_type.octet_stream;
    if (dot + 1 == filename.len) return media_type.octet_stream;
    const extension = filename[dot + 1 ..];
    // Finite scalar table is smaller than a speculative lookup structure.
    for (table) |candidate| {
        if (syntax.eqlIgnoreCase(extension, candidate.extension)) return candidate.value;
    }
    return media_type.octet_stream;
}

fn entry(comptime extension: []const u8, comptime value: []const u8) Entry {
    return .{ .extension = extension, .value = media_type.parseComptime(value) };
}

test "versioned media table is case-insensitive with an exact fallback" {
    try std.testing.expectEqual(@as(u16, 1), table_version);
    try std.testing.expectEqualStrings("text/css; charset=utf-8", forFilename("app.CSS").bytes());
    try std.testing.expectEqualStrings("application/wasm", forFilename("core.wasm").bytes());
    try std.testing.expectEqualStrings(
        "application/octet-stream",
        forFilename("unknown.x").bytes(),
    );
    try std.testing.expectEqualStrings("application/octet-stream", forFilename("README").bytes());
}
