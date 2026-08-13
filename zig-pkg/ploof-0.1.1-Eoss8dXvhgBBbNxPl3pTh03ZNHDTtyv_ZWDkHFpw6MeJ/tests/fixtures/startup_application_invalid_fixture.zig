const startup = @import("ploof_compile").startup;

export fn forceStartupApplicationDiagnostic() void {
    _ = startup.check(struct {}, .{});
}
