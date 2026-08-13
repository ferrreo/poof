const std = @import("std");
const bundle = @import("asset_bundle");

const css_digest = "650226eb61682d789d217e3007e180cae380cf605a336dc4f5d33bb3171b1d38";
const binary_digest = "f543d842926a8800f88f37d3334e7a93c570fe2155f8ab303f597c1449b4c7c1";

test "generated module exposes immutable sorted asset records" {
    try std.testing.expectEqual(@as(u16, 1), bundle.format_version);
    try std.testing.expectEqualStrings("/assets/", bundle.route_prefix);
    try std.testing.expectEqual(@as(usize, 2), bundle.assets.len);
    try expectIdentity(&bundle.assets[0], "app.css", 1723, css_digest);
    try expectIdentity(&bundle.assets[1], "logo.bin", 15, binary_digest);
    try std.testing.expectEqual(bundle.MediaKind.css, bundle.assets[0].media_kind);
    try std.testing.expectEqual(bundle.MediaKind.binary, bundle.assets[1].media_kind);
    try std.testing.expectEqualStrings(
        "text/css; charset=utf-8",
        bundle.assets[0].media_type,
    );
    try std.testing.expectEqualStrings(
        "application/octet-stream",
        bundle.assets[1].media_type,
    );
}

test "compressible asset has deterministic full-wire gzip representation" {
    const gzip = bundle.assets[0].gzip orelse return error.MissingGzip;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(gzip.bytes, &digest, .{});
    try std.testing.expectEqualSlices(u8, &digest, &gzip.digest);
    try expectEtag(gzip.etag, digest);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, gzip.bytes[4..8]);
    try std.testing.expectEqual(@as(u8, 255), gzip.bytes[9]);

    var input_reader = std.Io.Reader.fixed(gzip.bytes);
    var decoder = std.compress.flate.Decompress.init(&input_reader, .gzip, &.{});
    var output: [1723]u8 = undefined;
    var output_writer = std.Io.Writer.fixed(&output);
    const written = try decoder.reader.streamRemaining(&output_writer);
    try std.testing.expectEqualStrings(bundle.assets[0].identity.bytes, output[0..written]);
    try std.testing.expectEqualStrings("PLOOF-ASSET-V1\n", bundle.assets[1].identity.bytes);
    try std.testing.expect(bundle.assets[1].gzip == null);
}

fn expectIdentity(
    asset: *const bundle.Asset,
    name: []const u8,
    source_length: usize,
    expected_digest: []const u8,
) !void {
    try std.testing.expectEqualStrings(name, asset.logical_name);
    try std.testing.expectEqual(source_length, asset.identity.bytes.len);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(asset.identity.bytes, &digest, .{});
    try std.testing.expectEqualSlices(u8, &digest, &asset.identity.digest);
    var digest_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&digest_hex, "{x}", .{digest});
    try std.testing.expectEqualStrings(expected_digest, &digest_hex);
    try expectEtag(asset.identity.etag, digest);

    var expected_path: [bundle.route_prefix.len + 32 + 1 + 128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &expected_path,
        "{s}{x}/{s}",
        .{ bundle.route_prefix, digest[0..16], name },
    );
    try std.testing.expectEqualStrings(path, asset.path);
}

fn expectEtag(etag: []const u8, digest: [32]u8) !void {
    var expected: [66]u8 = undefined;
    const value = try std.fmt.bufPrint(&expected, "\"{x}\"", .{digest});
    try std.testing.expectEqualStrings(value, etag);
}
