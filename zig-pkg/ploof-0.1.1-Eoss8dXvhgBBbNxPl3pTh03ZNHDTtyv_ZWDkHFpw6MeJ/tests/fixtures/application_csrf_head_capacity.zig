const ploof = @import("ploof_compile").ploof;
const support = @import("csrf_application_support.zig");

const route_limits = ploof.response.HeadLimits{
    .head_bytes_max = 512,
    .field_line_bytes_max = 38,
    .fields_max = 16,
};

const BrokenApplication = ploof.Application(.{
    .State = support.State,
    .routes = .{ploof.route.configured(
        .get,
        "/",
        support.bodyless,
        .{support.policy},
        route_limits,
    )},
});

export fn forceCsrfHeadCapacity() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}
