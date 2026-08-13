const ploof = @import("ploof_compile").ploof;

fn handler() void {}

const routes_1 = ploof.route.get("/", handler);
const routes_2 = ploof.route.group("", .{}, .{ routes_1, routes_1 });
const routes_4 = ploof.route.group("", .{}, .{ routes_2, routes_2 });
const routes_8 = ploof.route.group("", .{}, .{ routes_4, routes_4 });
const routes_16 = ploof.route.group("", .{}, .{ routes_8, routes_8 });
const routes_32 = ploof.route.group("", .{}, .{ routes_16, routes_16 });
const routes_64 = ploof.route.group("", .{}, .{ routes_32, routes_32 });
const routes_128 = ploof.route.group("", .{}, .{ routes_64, routes_64 });
const routes_256 = ploof.route.group("", .{}, .{ routes_128, routes_128 });
const routes_512 = ploof.route.group("", .{}, .{ routes_256, routes_256 });
const routes_1024 = ploof.route.group("", .{}, .{ routes_512, routes_512 });
const routes_2048 = ploof.route.group("", .{}, .{ routes_1024, routes_1024 });
const routes_4096 = ploof.route.group("", .{}, .{ routes_2048, routes_2048 });
const routes_8192 = ploof.route.group("", .{}, .{ routes_4096, routes_4096 });
const routes_16384 = ploof.route.group("", .{}, .{ routes_8192, routes_8192 });
const routes_32768 = ploof.route.group("", .{}, .{ routes_16384, routes_16384 });
const routes_65536 = ploof.route.group("", .{}, .{ routes_32768, routes_32768 });

fn brokenApplication() type {
    @setEvalBranchQuota(1_000_000);
    return ploof.Application(.{
        .State = struct {},
        .routes = .{routes_65536},
    });
}

const BrokenApplication = brokenApplication();

export fn forceRouteCount() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}
