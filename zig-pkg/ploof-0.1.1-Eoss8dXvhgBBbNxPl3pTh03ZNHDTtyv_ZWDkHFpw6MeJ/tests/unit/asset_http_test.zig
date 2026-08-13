const std = @import("std");
const asset_http = @import("../../src/internal/asset/http.zig");

const Representation = struct {
    bytes: []const u8,
    digest: [32]u8,
    etag: []const u8,
};

const Record = struct {
    media_type: []const u8,
    identity: Representation,
    gzip: ?Representation,
};

const identity_etag = "\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"";
const gzip_etag = "\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"";
const record = Record{
    .media_type = "text/css; charset=utf-8",
    .identity = .{ .bytes = "identity", .digest = [_]u8{0xaa} ** 32, .etag = identity_etag },
    .gzip = .{ .bytes = "gzip", .digest = [_]u8{0xbb} ** 32, .etag = gzip_etag },
};

test "precompressed representation negotiation matches response policy" {
    try expectSelected(.get, .{}, .identity, "identity", true);
    try expectSelected(
        .get,
        .{ .gzip = 1000, .identity = 1000 },
        .gzip,
        "gzip",
        true,
    );
    try expectSelected(
        .get,
        .{ .gzip = 500, .identity = 900 },
        .identity,
        "identity",
        true,
    );
    try std.testing.expect(asset_http.select(
        record,
        .get,
        .{ .gzip = 0, .identity = 0 },
    ) == .not_acceptable);
}

test "HEAD selects identical metadata without a body transfer" {
    const get = asset_http.select(
        record,
        .get,
        .{ .gzip = 1000, .identity = 0 },
    ).selected;
    const head = asset_http.select(
        record,
        .head,
        .{ .gzip = 1000, .identity = 0 },
    ).selected;
    try std.testing.expectEqualStrings(get.etag, head.etag);
    try std.testing.expectEqual(get.contentLength(), head.contentLength());
    try std.testing.expect(get.transfer_body);
    try std.testing.expect(!head.transfer_body);
}

test "asset without gzip rejects forbidden identity" {
    var identity_only = record;
    identity_only.gzip = null;
    try std.testing.expect(asset_http.select(
        identity_only,
        .get,
        .{ .gzip = 1000, .identity = 0 },
    ) == .not_acceptable);
}

test "If-None-Match uses weak comparison and strict aggregate syntax" {
    try expectNotModified(&.{identity_etag}, true);
    try expectNotModified(&.{"W/" ++ identity_etag}, true);
    try expectNotModified(&.{"\"other\", " ++ identity_etag}, true);
    try expectNotModified(&.{"\"opaque,comma\", " ++ identity_etag}, true);
    try expectNotModified(&.{"W/\"opaque,comma\""}, false);
    try expectNotModified(&.{"*"}, true);
    try expectNotModified(&.{ "invalid", identity_etag }, false);
    try expectNotModified(&.{ "*", identity_etag }, false);
    try expectNotModified(&.{"\"other\""}, false);
    try expectNotModified(&.{""}, false);
}

test "asset policy fields are immutable and sniff resistant" {
    try std.testing.expectEqualStrings(
        "public, max-age=31536000, immutable",
        asset_http.cache_control,
    );
    try std.testing.expectEqualStrings("Accept-Encoding", asset_http.vary);
    try std.testing.expectEqualStrings("nosniff", asset_http.nosniff);
}

fn expectSelected(
    method: asset_http.Method,
    preferences: @import("../../src/internal/http1/request_accept_encoding.zig").Preferences,
    coding: asset_http.Coding,
    bytes: []const u8,
    transfer_body: bool,
) !void {
    const selected = asset_http.select(record, method, preferences).selected;
    try std.testing.expectEqual(coding, selected.coding);
    try std.testing.expectEqualStrings(bytes, selected.body);
    try std.testing.expectEqual(transfer_body, selected.transfer_body);
}

fn expectNotModified(values: []const []const u8, expected: bool) !void {
    var matcher = asset_http.IfNoneMatch.init(identity_etag);
    for (values) |value| matcher.add(value);
    try std.testing.expectEqual(expected, matcher.notModified());
}
