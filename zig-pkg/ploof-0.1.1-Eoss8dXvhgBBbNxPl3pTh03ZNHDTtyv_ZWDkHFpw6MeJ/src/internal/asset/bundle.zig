const std = @import("std");

pub const format_version: u16 = 1;
pub const assets_hard_max: u16 = 4096;
pub const logical_name_bytes_max: u8 = 128;
pub const route_prefix_bytes_max: u8 = 128;
pub const gzip_bytes_min: usize = 1024;
pub const gzip_bytes_max: usize = 4 * 1024 * 1024;

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

const MediaPolicy = struct {
    media_type: []const u8,
    compressible: bool,
};

pub fn mediaType(kind: MediaKind) []const u8 {
    return mediaPolicy(kind).media_type;
}

pub fn gzipEligible(kind: MediaKind, identity_bytes: usize) bool {
    return mediaPolicy(kind).compressible and
        identity_bytes >= gzip_bytes_min and identity_bytes <= gzip_bytes_max;
}

pub fn Plan(comptime Generated: type) type {
    @setEvalBranchQuota(std.math.maxInt(u32));
    validateShape(Generated);
    const prefix = routePrefix(Generated);
    const count = assetCount(Generated);
    validateValues(Generated, prefix, count);

    return struct {
        pub const Module = Generated;
        pub const route_prefix = prefix;
        pub const asset_count = count;

        pub fn kindAt(comptime index: usize) MediaKind {
            if (index >= asset_count) {
                @compileError("PLOOF-E5112 embedded asset index is out of range");
            }
            return generatedKind(Module.assets[index].media_kind);
        }

        pub fn indexOf(comptime logical_name: []const u8) usize {
            return comptime for (Module.assets, 0..) |asset, index| {
                if (std.mem.eql(u8, logical_name, asset.logical_name)) break index;
            } else @compileError(
                "PLOOF-E5112 unknown embedded asset '" ++ logical_name ++ "'",
            );
        }

        pub fn kindOf(comptime logical_name: []const u8) MediaKind {
            return kindAt(indexOf(logical_name));
        }
    };
}

fn validateShape(comptime Generated: type) void {
    if (@typeInfo(Generated) != .@"struct") failShape();
    const declarations = [_][]const u8{
        "format_version",
        "route_prefix",
        "MediaKind",
        "Representation",
        "Asset",
        "assets",
    };
    inline for (declarations) |name| if (!@hasDecl(Generated, name)) failShape();
    if (@TypeOf(Generated.format_version) != u16) failShape();
    if (Generated.format_version != format_version) {
        @compileError("PLOOF-E5101 unsupported embedded asset module format version");
    }
    validateMediaKindShape(Generated.MediaKind);
    validateRepresentationShape(Generated.Representation);
    validateAssetShape(Generated);

    const assets_info = @typeInfo(@TypeOf(Generated.assets));
    if (assets_info != .array or assets_info.array.child != Generated.Asset) failShape();
}

fn validateMediaKindShape(comptime GeneratedKind: type) void {
    const info = @typeInfo(GeneratedKind);
    if (info != .@"enum" or info.@"enum".tag_type != u8 or
        !info.@"enum".is_exhaustive)
    {
        @compileError("PLOOF-E5104 invalid embedded asset media-kind table");
    }
    const expected = std.meta.fields(MediaKind);
    const actual = info.@"enum".fields;
    if (actual.len != expected.len) {
        @compileError("PLOOF-E5104 invalid embedded asset media-kind table");
    }
    inline for (expected, actual) |wanted, found| {
        if (wanted.value != found.value or !std.mem.eql(u8, wanted.name, found.name)) {
            @compileError("PLOOF-E5104 invalid embedded asset media-kind table");
        }
    }
}

fn validateRepresentationShape(comptime Representation: type) void {
    const info = @typeInfo(Representation);
    if (info != .@"struct" or info.@"struct".fields.len != 3 or
        !exactField(Representation, "bytes", []const u8) or
        !exactField(Representation, "digest", [32]u8) or
        !exactField(Representation, "etag", []const u8))
    {
        failShape();
    }
}

fn validateAssetShape(comptime Generated: type) void {
    const Asset = Generated.Asset;
    const info = @typeInfo(Asset);
    if (info != .@"struct" or info.@"struct".fields.len != 6 or
        !exactField(Asset, "logical_name", []const u8) or
        !exactField(Asset, "path", []const u8) or
        !exactField(Asset, "media_kind", Generated.MediaKind) or
        !exactField(Asset, "media_type", []const u8) or
        !exactField(Asset, "identity", Generated.Representation) or
        !exactField(Asset, "gzip", ?Generated.Representation))
    {
        failShape();
    }
}

fn exactField(comptime T: type, comptime name: []const u8, comptime Field: type) bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.type == Field;
    }
    return false;
}

fn routePrefix(comptime Generated: type) []const u8 {
    const T = @TypeOf(Generated.route_prefix);
    return switch (@typeInfo(T)) {
        .array => |array| if (array.child == u8) Generated.route_prefix[0..] else failPrefixType(),
        .pointer => |pointer| switch (pointer.size) {
            .slice => if (pointer.child == u8 and pointer.is_const)
                Generated.route_prefix
            else
                failPrefixType(),
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| if (array.child == u8)
                    Generated.route_prefix[0..]
                else
                    failPrefixType(),
                else => failPrefixType(),
            },
            else => failPrefixType(),
        },
        else => failPrefixType(),
    };
}

fn failPrefixType() noreturn {
    @compileError("PLOOF-E5100 invalid generated embedded asset module shape");
}

fn assetCount(comptime Generated: type) usize {
    const count = Generated.assets.len;
    if (count == 0 or count > assets_hard_max) {
        @compileError("PLOOF-E5102 embedded asset count must be 1 to 4096");
    }
    return count;
}

fn validateValues(
    comptime Generated: type,
    comptime prefix: []const u8,
    comptime count: usize,
) void {
    if (!validRoutePrefix(prefix)) {
        @compileError("PLOOF-E5103 invalid generated embedded asset route prefix");
    }
    inline for (Generated.assets, 0..) |asset, index| {
        validateAssetValue(Generated, asset, prefix);
        if (index > 0 and std.mem.order(
            u8,
            Generated.assets[index - 1].logical_name,
            asset.logical_name,
        ) != .lt) {
            @compileError("PLOOF-E5106 embedded assets must have unique sorted logical names");
        }
    }
    validateDigestPrefixes(Generated, count);
}

fn validateAssetValue(
    comptime Generated: type,
    comptime asset: Generated.Asset,
    comptime prefix: []const u8,
) void {
    if (!validLogicalName(asset.logical_name)) {
        @compileError("PLOOF-E5106 invalid embedded asset logical name");
    }
    if (!validDigest(asset.identity.bytes, asset.identity.digest)) {
        @compileError("PLOOF-E5109 invalid embedded asset identity metadata");
    }
    if (asset.gzip) |gzip| {
        if (!validDigest(gzip.bytes, gzip.digest)) {
            @compileError("PLOOF-E5110 invalid embedded asset gzip metadata");
        }
    }
    const kind = generatedKind(asset.media_kind);
    if (!std.mem.eql(u8, asset.media_type, mediaType(kind))) {
        @compileError("PLOOF-E5108 invalid embedded asset media metadata");
    }
    if (!validAssetPath(asset.path, prefix, asset.identity.digest, asset.logical_name)) {
        @compileError("PLOOF-E5107 invalid content-addressed embedded asset path");
    }
    if (!validEtag(asset.identity.etag, asset.identity.digest)) {
        @compileError("PLOOF-E5109 invalid embedded asset identity metadata");
    }
    const eligible = gzipEligible(kind, asset.identity.bytes.len);
    if (eligible != (asset.gzip != null)) {
        @compileError("PLOOF-E5110 invalid embedded asset gzip policy");
    }
    if (asset.gzip) |gzip| {
        if (!validEtag(gzip.etag, gzip.digest) or
            !validGzipHeader(gzip.bytes))
        {
            @compileError("PLOOF-E5110 invalid embedded asset gzip metadata");
        }
    }
}

fn validateDigestPrefixes(comptime Generated: type, comptime count: usize) void {
    var indices: [count]u16 = undefined;
    for (&indices, 0..) |*index, value| index.* = @intCast(value);
    std.mem.sortUnstable(u16, &indices, Generated, digestLessThan);
    for (indices[1..], 1..) |right_index, offset| {
        const left = Generated.assets[indices[offset - 1]].identity.digest;
        const right = Generated.assets[right_index].identity.digest;
        if (digestPrefixCollision(left, right)) {
            @compileError("PLOOF-E5111 embedded asset SHA-256 prefix collision");
        }
    }
}

fn digestLessThan(comptime Generated: type, left_index: u16, right_index: u16) bool {
    const left = Generated.assets[left_index].identity.digest;
    const right = Generated.assets[right_index].identity.digest;
    const prefix_order = std.mem.order(u8, left[0..16], right[0..16]);
    if (prefix_order != .eq) return prefix_order == .lt;
    return std.mem.order(u8, &left, &right) == .lt;
}

fn digestPrefixCollision(left: [32]u8, right: [32]u8) bool {
    return std.mem.eql(u8, left[0..16], right[0..16]) and
        !std.mem.eql(u8, &left, &right);
}

fn generatedKind(comptime value: anytype) MediaKind {
    return @enumFromInt(@intFromEnum(value));
}

fn validRoutePrefix(prefix: []const u8) bool {
    if (prefix.len == 0 or prefix.len > route_prefix_bytes_max) return false;
    if (prefix[0] != '/' or prefix[prefix.len - 1] != '/') return false;
    if (prefix.len == 1) return true;
    var segment_bytes: u8 = 0;
    for (prefix[1..]) |byte| {
        if (byte == '/') {
            if (segment_bytes == 0) return false;
            segment_bytes = 0;
        } else if (isPathByte(byte)) {
            segment_bytes += 1;
        } else return false;
    }
    return segment_bytes == 0;
}

fn validLogicalName(name: []const u8) bool {
    if (name.len == 0 or name.len > logical_name_bytes_max) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |byte| {
        if (!(isPathByte(byte) or byte == '.')) return false;
    }
    return true;
}

fn isPathByte(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= '0' and byte <= '9') or byte == '-' or byte == '_';
}

fn validAssetPath(
    path: []const u8,
    prefix: []const u8,
    digest: [32]u8,
    name: []const u8,
) bool {
    const expected_length = prefix.len + 32 + 1 + name.len;
    if (path.len != expected_length or !std.mem.startsWith(u8, path, prefix)) return false;
    const hex = path[prefix.len .. prefix.len + 32];
    for (digest[0..16], 0..) |byte, index| {
        if (hex[index * 2] != lower_hex[byte >> 4] or
            hex[index * 2 + 1] != lower_hex[byte & 0x0f]) return false;
    }
    if (path[prefix.len + 32] != '/') return false;
    return std.mem.eql(u8, path[prefix.len + 33 ..], name);
}

fn validEtag(etag: []const u8, digest: [32]u8) bool {
    if (etag.len != 66 or etag[0] != '"' or etag[65] != '"') return false;
    for (digest, 0..) |byte, index| {
        if (etag[1 + index * 2] != lower_hex[byte >> 4] or
            etag[2 + index * 2] != lower_hex[byte & 0x0f]) return false;
    }
    return true;
}

fn validDigest(bytes: []const u8, digest: [32]u8) bool {
    var computed: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &computed, .{});
    return std.mem.eql(u8, &computed, &digest);
}

fn validGzipHeader(bytes: []const u8) bool {
    return bytes.len >= 18 and std.mem.eql(u8, bytes[0..3], &.{ 0x1f, 0x8b, 0x08 }) and
        std.mem.allEqual(u8, bytes[4..8], 0) and bytes[9] == 255;
}

fn mediaPolicy(kind: MediaKind) MediaPolicy {
    return switch (kind) {
        .css => .{ .media_type = "text/css; charset=utf-8", .compressible = true },
        .javascript => .{
            .media_type = "text/javascript; charset=utf-8",
            .compressible = true,
        },
        .json => .{ .media_type = "application/json; charset=utf-8", .compressible = true },
        .svg => .{ .media_type = "image/svg+xml", .compressible = true },
        .text => .{ .media_type = "text/plain; charset=utf-8", .compressible = true },
        .html => .{ .media_type = "text/html; charset=utf-8", .compressible = true },
        .xml => .{ .media_type = "application/xml", .compressible = true },
        .png => .{ .media_type = "image/png", .compressible = false },
        .jpeg => .{ .media_type = "image/jpeg", .compressible = false },
        .gif => .{ .media_type = "image/gif", .compressible = false },
        .webp => .{ .media_type = "image/webp", .compressible = false },
        .avif => .{ .media_type = "image/avif", .compressible = false },
        .ico => .{ .media_type = "image/x-icon", .compressible = false },
        .woff => .{ .media_type = "font/woff", .compressible = false },
        .woff2 => .{ .media_type = "font/woff2", .compressible = false },
        .ttf => .{ .media_type = "font/ttf", .compressible = false },
        .otf => .{ .media_type = "font/otf", .compressible = false },
        .wasm => .{ .media_type = "application/wasm", .compressible = false },
        .binary => .{ .media_type = "application/octet-stream", .compressible = false },
    };
}

fn failShape() noreturn {
    @compileError("PLOOF-E5100 invalid generated embedded asset module shape");
}

const lower_hex = "0123456789abcdef";

comptime {
    std.debug.assert(assets_hard_max <= std.math.maxInt(u16));
    std.debug.assert(gzip_bytes_min <= gzip_bytes_max);
}

test "digest prefix collision requires equal prefixes and different full hashes" {
    const left = [_]u8{0x11} ** 32;
    var collision = left;
    collision[31] = 0x22;
    var distinct = left;
    distinct[0] = 0x22;
    try std.testing.expect(digestPrefixCollision(left, collision));
    try std.testing.expect(!digestPrefixCollision(left, left));
    try std.testing.expect(!digestPrefixCollision(left, distinct));
}
