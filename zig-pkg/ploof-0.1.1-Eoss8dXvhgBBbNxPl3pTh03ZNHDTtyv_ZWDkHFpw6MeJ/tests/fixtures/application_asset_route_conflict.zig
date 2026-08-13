const ploof = @import("ploof_compile").ploof;
const asset_fixture = @import("html_asset_fixture.zig");

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Assets = asset_fixture.Bundle(.binary, "body");

fn handler(context: *Context) Context.ResponseType {
    return context.empty(.ok);
}

const BrokenApplication = ploof.Application(.{
    .State = State,
    .assets = Assets,
    .routes = .{ploof.route.get(Assets.generated.assets[0].path, handler)},
});

export fn forceAssetRouteConflict() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}
