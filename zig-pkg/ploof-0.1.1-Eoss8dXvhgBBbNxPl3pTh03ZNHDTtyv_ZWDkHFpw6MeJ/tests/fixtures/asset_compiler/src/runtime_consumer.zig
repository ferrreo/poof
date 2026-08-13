const std = @import("std");
const asset = @import("asset_runtime");
const generated = @import("asset_bundle");

const Assets = asset.Bundle(generated);
const References = Assets.References(&.{"https://cdn.example"}, .{});

test "generated module satisfies runtime bundle contract" {
    try std.testing.expectEqual(@as(usize, 2), Assets.asset_count);
    try std.testing.expectEqual(asset.MediaKind.css, Assets.kind("app.css"));

    const local = Assets.local("app.css");
    const local_url = try local.url();
    try std.testing.expectEqualStrings("", local_url.base);
    try std.testing.expectEqualStrings(generated.assets[0].path, local_url.path);
    try std.testing.expectEqualStrings(
        generated.assets[0].identity.bytes,
        try local.identityBytes(),
    );

    var references: References = undefined;
    try std.testing.expect(references.init(.{
        .origin = "https://cdn.example",
        .prefix = "/frontend",
    }) == null);
    const external = try references.get("logo.bin");
    const external_url = try external.url();
    try std.testing.expectEqualStrings("https://cdn.example/frontend", external_url.base);
    try std.testing.expectEqualStrings(generated.assets[1].path, external_url.path);
}
