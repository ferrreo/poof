const std = @import("std");
const asset = @import("../../src/asset.zig");

pub const Generated = struct {
    pub const format_version: u16 = 1;

    pub const MediaKind = enum(u8) {
        css,
        javascript,
        json,
        svg,
        text,
        html,
        xml,
        png,
        jpeg,
        gif,
        webp,
        avif,
        ico,
        woff,
        woff2,
        ttf,
        otf,
        wasm,
        binary,
    };

    pub const Representation = struct {
        bytes: []const u8,
        digest: [32]u8,
        etag: []const u8,
    };

    pub const Asset = struct {
        logical_name: []const u8,
        path: []const u8,
        media_kind: MediaKind,
        media_type: []const u8,
        identity: Representation,
        gzip: ?Representation,
    };

    pub const route_prefix = "/assets/";
    pub const assets = [_]Asset{
        .{
            .logical_name = "app.css",
            .path = &first_path,
            .media_kind = .css,
            .media_type = "text/css; charset=utf-8",
            .identity = .{
                .bytes = first_bytes,
                .digest = first_digest,
                .etag = &first_etag,
            },
            .gzip = null,
        },
        .{
            .logical_name = "logo.bin",
            .path = &second_path,
            .media_kind = .binary,
            .media_type = "application/octet-stream",
            .identity = .{
                .bytes = second_bytes,
                .digest = second_digest,
                .etag = &second_etag,
            },
            .gzip = null,
        },
    };
};

const first_bytes = "body{}";
const second_bytes = "PLOOF-ASSET-V1\n";
const first_digest = sha256(first_bytes);
const second_digest = sha256(second_bytes);
const first_path = assetPath("app.css", first_digest);
const second_path = assetPath("logo.bin", second_digest);
const first_etag = assetEtag(first_digest);
const second_etag = assetEtag(second_digest);

pub const Assets = asset.Bundle(Generated);
const References = Assets.References(
    &.{ "https://cdn.example", "https://static.example:8443" },
    .{},
);

test "bundle exposes media-typed sealed local references" {
    try std.testing.expectEqual(@as(usize, 2), Assets.asset_count);
    try std.testing.expectEqual(asset.MediaKind.css, Assets.kind("app.css"));
    try std.testing.expectEqualStrings("/assets/", Assets.route_prefix);
    try std.testing.expectEqualStrings(
        "text/javascript; charset=utf-8",
        asset.mediaType(.javascript),
    );

    const css = Assets.local("app.css");
    try std.testing.expect(asset.isAssetRef(@TypeOf(css)));
    try std.testing.expectEqual(asset.MediaKind.css, asset.referenceKind(@TypeOf(css)).?);
    const url = try css.url();
    try std.testing.expectEqualStrings("", url.base);
    try std.testing.expectEqualStrings(Generated.assets[0].path, url.path);
    try std.testing.expectEqual(url.path.len, url.encodedLength());
    try std.testing.expectEqualStrings("body{}", try css.identityBytes());
    try std.testing.expectEqualSlices(u8, &first_digest, &(try css.identityDigest()));
}

test "reference table selects local paths without allocation" {
    var references: References = undefined;
    try std.testing.expect(references.init(null) == null);
    try std.testing.expect((try references.origin()) == null);

    const css = try references.get("app.css");
    const parts = try css.url();
    try std.testing.expectEqualStrings("", parts.base);
    try std.testing.expectEqualStrings(Generated.assets[0].path, parts.path);

    var moved = references;
    const moved_logo = try moved.get("logo.bin");
    try std.testing.expectEqualStrings(Generated.assets[1].path, try moved_logo.canonicalPath());
}

test "startup origin uses allowlisted HTTPS and fixed prefix" {
    var references: References = undefined;
    try std.testing.expect(references.init(.{
        .origin = "https://CDN.EXAMPLE:443",
        .prefix = "/release_7/frontend",
    }) == null);

    const origin = (try references.origin()).?;
    try std.testing.expectEqualStrings(
        "https://cdn.example/release_7/frontend",
        try origin.base(),
    );
    const css = try references.get("app.css");
    const parts = try css.url();
    try std.testing.expectEqualStrings(
        "https://cdn.example/release_7/frontend",
        parts.base,
    );
    try std.testing.expectEqualStrings(Generated.assets[0].path, parts.path);
    try std.testing.expectEqual(parts.base.len + parts.path.len, parts.encodedLength());
}

test "startup origin failures leave table unavailable" {
    var references: References = undefined;
    const insecure = references.init(.{ .origin = "http://cdn.example" }).?;
    try std.testing.expectEqual(
        error.UnsupportedScheme,
        insecure.issue.invalid_origin,
    );
    try std.testing.expectError(error.NotInitialized, references.get("app.css"));

    const untrusted = references.init(.{ .origin = "https://attacker.example" }).?;
    try std.testing.expect(untrusted.issue == .origin_not_allowed);

    const bad_prefix = references.init(.{
        .origin = "https://cdn.example",
        .prefix = "/Release/latest",
    }).?;
    try std.testing.expect(bad_prefix.issue == .invalid_prefix);

    var long_prefix: [129]u8 = @splat('a');
    long_prefix[0] = '/';
    const too_long = references.init(.{
        .origin = "https://cdn.example",
        .prefix = &long_prefix,
    }).?;
    try std.testing.expect(too_long.issue == .prefix_too_long);
}

test "origin content seal detects mutation and clear invalidates references" {
    var references: References = undefined;
    try std.testing.expect(references.init(.{ .origin = "https://cdn.example" }) == null);
    const css = try references.get("app.css");
    const origin = (try references.origin()).?;

    references.origin_storage[0] ^= 1;
    try std.testing.expectError(error.CorruptState, origin.base());
    try std.testing.expectError(error.CorruptState, css.url());

    references.clear();
    try std.testing.expectError(error.NotInitialized, references.get("app.css"));
    try std.testing.expectError(error.CorruptState, css.canonicalPath());
}

test "reference setup does not touch an allocator" {
    var allocator_storage: [1]u8 = undefined;
    const fixed = std.heap.FixedBufferAllocator.init(&allocator_storage);
    const before = fixed.end_index;

    var references: References = undefined;
    try std.testing.expect(references.init(.{
        .origin = "https://static.example:8443",
        .prefix = "/v1",
    }) == null);
    _ = try (try references.get("logo.bin")).url();
    try std.testing.expectEqual(before, fixed.end_index);
}

fn sha256(comptime bytes: []const u8) [32]u8 {
    @setEvalBranchQuota(100_000);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn assetPath(comptime name: []const u8, comptime digest: [32]u8) [
    "/assets/".len + 32 + 1 + name.len
]u8 {
    var result: ["/assets/".len + 32 + 1 + name.len]u8 = undefined;
    @memcpy(result[0.."/assets/".len], "/assets/");
    writeDigestHex(result["/assets/".len..][0..32], digest[0..16]);
    result["/assets/".len + 32] = '/';
    @memcpy(result["/assets/".len + 33 ..], name);
    return result;
}

fn assetEtag(comptime digest: [32]u8) [66]u8 {
    var result: [66]u8 = undefined;
    result[0] = '"';
    writeDigestHex(result[1..65], &digest);
    result[65] = '"';
    return result;
}

fn writeDigestHex(output: []u8, digest: []const u8) void {
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        output[index * 2] = hex[byte >> 4];
        output[index * 2 + 1] = hex[byte & 0x0f];
    }
}
