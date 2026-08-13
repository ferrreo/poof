const std = @import("std");

pub fn Configuration(
    comptime App: type,
    comptime response_bytes_per_request: u32,
) type {
    const enabled = if (@hasDecl(App, "response_gzip_enabled"))
        App.response_gzip_enabled
    else
        false;
    if (enabled and
        response_bytes_per_request < App.response_gzip_framework_bytes_required)
    {
        @compileError(
            "PLOOF-E3085 response staging cannot hold response gzip framework fallback",
        );
    }
    return struct {
        pub const Workspace = if (@hasDecl(App, "ResponseGzipWorkspace"))
            App.ResponseGzipWorkspace
        else
            struct {};
    };
}

test "response gzip worker workspace compiles out when disabled" {
    const Disabled = struct {};
    const DisabledConfig = Configuration(Disabled, 1);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(DisabledConfig.Workspace));

    const Enabled = struct {
        pub const response_gzip_enabled = true;
        pub const response_gzip_framework_bytes_required = 8;
        pub const ResponseGzipWorkspace = [32]u8;
    };
    const EnabledConfig = Configuration(Enabled, 8);
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(EnabledConfig.Workspace));
}
