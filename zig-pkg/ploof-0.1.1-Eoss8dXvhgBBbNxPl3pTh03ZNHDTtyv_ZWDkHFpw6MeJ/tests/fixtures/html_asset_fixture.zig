const ploof = @import("ploof_compile").ploof;

pub fn Bundle(comptime kind: ploof.Asset.MediaKind, comptime bytes: []const u8) type {
    return ploof.Asset.Bundle(Generated(kind, bytes));
}

fn Generated(comptime kind: ploof.Asset.MediaKind, comptime bytes: []const u8) type {
    const digest_value = sha256(bytes);
    const path_value = assetPath(digest_value);
    const etag_value = assetEtag(digest_value);
    return struct {
        pub const format_version: u16 = ploof.Asset.format_version;
        pub const route_prefix = "/assets/";
        pub const MediaKind = ploof.Asset.MediaKind;
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
        pub const path = path_value;
        pub const etag = etag_value;
        pub const assets = [_]Asset{.{
            .logical_name = "asset.bin",
            .path = &path,
            .media_kind = kind,
            .media_type = ploof.Asset.mediaType(kind),
            .identity = .{
                .bytes = bytes,
                .digest = digest_value,
                .etag = &etag,
            },
            .gzip = null,
        }};
    };
}

fn assetPath(comptime digest: [32]u8) [
    "/assets/".len + 32 + "/asset.bin".len
]u8 {
    var result: ["/assets/".len + 32 + "/asset.bin".len]u8 = undefined;
    @memcpy(result[0.."/assets/".len], "/assets/");
    for (digest[0..16], 0..) |byte, index| {
        result["/assets/".len + index * 2] = lower_hex[byte >> 4];
        result["/assets/".len + index * 2 + 1] = lower_hex[byte & 0x0f];
    }
    @memcpy(result["/assets/".len + 32 ..], "/asset.bin");
    return result;
}

fn assetEtag(comptime digest: [32]u8) [66]u8 {
    var result: [66]u8 = undefined;
    result[0] = '"';
    for (digest, 0..) |byte, index| {
        result[1 + index * 2] = lower_hex[byte >> 4];
        result[2 + index * 2] = lower_hex[byte & 0x0f];
    }
    result[65] = '"';
    return result;
}

fn sha256(comptime bytes: []const u8) [32]u8 {
    @setEvalBranchQuota(100_000);
    var digest: [32]u8 = undefined;
    @import("std").crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

const lower_hex = "0123456789abcdef";
