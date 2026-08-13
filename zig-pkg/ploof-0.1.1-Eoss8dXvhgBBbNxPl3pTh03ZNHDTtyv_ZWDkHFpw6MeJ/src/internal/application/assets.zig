const std = @import("std");
const application_routes = @import("routes.zig");

pub fn count(comptime config: anytype) usize {
    const Assets = configuredBundle(config) orelse return 0;
    return Assets.asset_count;
}

pub fn bundle(comptime config: anytype) ?type {
    return configuredBundle(config);
}

pub fn definitions(
    comptime config: anytype,
    comptime application: anytype,
) [application.len + count(config)]application_routes.Definition {
    const asset_count = comptime count(config);
    var result: [application.len + asset_count]application_routes.Definition = undefined;
    for (application, 0..) |definition, route_index| result[route_index] = definition;
    const Assets = configuredBundle(config) orelse return result;
    inline for (Assets.generated.assets, application.len..) |record, route_id| {
        result[route_id] = .{
            .method = .get,
            .path = record.path,
            .route_id = @intCast(route_id),
        };
    }
    return result;
}

pub fn appendRepeated(
    comptime config: anytype,
    comptime values: anytype,
    comptime repeated: anytype,
) [values.len + count(config)]arrayChild(@TypeOf(values)) {
    const Value = arrayChild(@TypeOf(values));
    var result: [values.len + count(config)]Value = undefined;
    for (values, 0..) |value, value_index| result[value_index] = value;
    for (values.len..result.len) |value_index| result[value_index] = repeated;
    return result;
}

fn arrayChild(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .array => |array| array.child,
        else => @compileError("PLOOF-E5122 invalid embedded asset route-plan extension"),
    };
}

pub fn index(route_id: u16, application_count: usize, asset_count: usize) ?usize {
    if (route_id < application_count) return null;
    const candidate = @as(usize, route_id) - application_count;
    return if (candidate < asset_count) candidate else null;
}

fn configuredBundle(comptime config: anytype) ?type {
    const Config = @TypeOf(config);
    if (!@hasField(Config, "assets")) return null;
    if (@TypeOf(config.assets) != type) {
        @compileError("PLOOF-E5120 Application assets must be an Asset.Bundle type");
    }
    const Assets = config.assets;
    if (!@hasDecl(Assets, "ploof_asset_bundle") or Assets.ploof_asset_bundle != true or
        !@hasDecl(Assets, "asset_count") or !@hasDecl(Assets, "generated"))
    {
        @compileError("PLOOF-E5120 Application assets must be an Asset.Bundle type");
    }
    if (Assets.asset_count == 0 or Assets.asset_count > std.math.maxInt(u16)) {
        @compileError("PLOOF-E5121 Application embedded asset count is invalid");
    }
    return Assets;
}

test "asset definitions append public GET routes with stable ids" {
    const Fake = struct {
        pub const ploof_asset_bundle = true;
        pub const asset_count = 2;
        pub const generated = struct {
            pub const assets = .{
                .{ .path = "/assets/a/app.css" },
                .{ .path = "/assets/b/app.js" },
            };
        };
    };
    const routes = [_]application_routes.Definition{.{
        .method = .post,
        .path = "/submit",
        .route_id = 0,
    }};
    const result = definitions(.{ .assets = Fake }, routes);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("/assets/a/app.css", result[1].path);
    try std.testing.expectEqual(@as(u16, 2), result[2].route_id);
    try std.testing.expectEqual(@as(?usize, 0), index(1, 1, 2));
    try std.testing.expectEqual(@as(?usize, null), index(0, 1, 2));
    const plans = appendRepeated(.{ .assets = Fake }, [_]u8{7}, 0);
    try std.testing.expectEqualSlices(u8, &.{ 7, 0, 0 }, &plans);
}
