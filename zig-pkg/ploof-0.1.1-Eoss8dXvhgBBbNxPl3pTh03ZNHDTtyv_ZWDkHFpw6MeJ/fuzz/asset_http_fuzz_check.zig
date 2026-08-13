const std = @import("std");
const asset_http = @import("../src/internal/asset/http.zig");
const request_accept_encoding = @import("../src/internal/http1/request_accept_encoding.zig");

const identity_etag = "\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"";
const gzip_etag = "\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"";
const Representation = struct {
    bytes: []const u8,
    etag: []const u8,
};
const record = .{
    .media_type = "text/css; charset=utf-8",
    .identity = Representation{ .bytes = "identity", .etag = identity_etag },
    .gzip = @as(?Representation, .{ .bytes = "gzip", .etag = gzip_etag }),
};

test "embedded asset negotiation and conditional policy fuzz is bounded" {
    try std.testing.fuzz({}, fuzzPolicy, .{ .corpus = &corpus });
}

fn fuzzPolicy(_: void, smith: *std.testing.Smith) !void {
    const preferences = request_accept_encoding.Preferences{
        .gzip = smith.valueRangeAtMost(u16, 0, request_accept_encoding.weight_max),
        .identity = smith.valueRangeAtMost(u16, 0, request_accept_encoding.weight_max),
    };
    const method: asset_http.Method = if (smith.value(bool)) .get else .head;
    const first = asset_http.select(record, method, preferences);
    const second = asset_http.select(record, method, preferences);
    try std.testing.expect(std.meta.eql(first, second));
    try expectSelection(first, method, preferences);

    var storage: [1024]u8 = undefined;
    const values = storage[0..smith.slice(&storage)];
    var first_matcher = asset_http.IfNoneMatch.init(identity_etag);
    var second_matcher = asset_http.IfNoneMatch.init(identity_etag);
    var iterator = std.mem.splitScalar(u8, values, 0);
    var count: u8 = 0;
    while (iterator.next()) |value| : (count += 1) {
        if (count == 64) break;
        first_matcher.add(value);
        second_matcher.add(value);
    }
    try std.testing.expectEqual(first_matcher.notModified(), second_matcher.notModified());
    try std.testing.expectEqualDeep(first_matcher, second_matcher);
    if (first_matcher.notModified()) {
        try std.testing.expect(first_matcher.valid and first_matcher.seen);
    }
}

fn expectSelection(
    decision: asset_http.Decision,
    method: asset_http.Method,
    preferences: request_accept_encoding.Preferences,
) !void {
    switch (decision) {
        .not_acceptable => try std.testing.expect(
            preferences.identity == 0 and preferences.gzip == 0,
        ),
        .selected => |selected| {
            try std.testing.expectEqual(method == .get, selected.transfer_body);
            switch (selected.coding) {
                .identity => {
                    try std.testing.expect(preferences.identity != 0);
                    try std.testing.expectEqualStrings("identity", selected.body);
                    try std.testing.expectEqualStrings(identity_etag, selected.etag);
                },
                .gzip => {
                    try std.testing.expect(preferences.gzip != 0);
                    try std.testing.expect(preferences.gzip >= preferences.identity);
                    try std.testing.expectEqualStrings("gzip", selected.body);
                    try std.testing.expectEqualStrings(gzip_etag, selected.etag);
                },
            }
        },
    }
}

const corpus = .{
    "",
    identity_etag,
    "W/" ++ identity_etag ++ ", \"other\"",
    "\"opaque,comma\", " ++ identity_etag,
    "*",
    "invalid\x00" ++ identity_etag,
};
