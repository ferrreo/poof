const std = @import("std");
const app_state = @import("../app_state.zig");
const page = @import("page.zig");

const content_security_policy = std.fmt.comptimePrint(
    "default-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'; script-src 'self'; style-src 'self' 'sha256-{s}'; font-src 'self'; img-src 'self' https: http: data:; connect-src 'self'",
    .{page.view_transition_style_hash},
);

pub const SecurityHeaders = struct {
    pub const State = void;

    pub fn init(_: SecurityHeaders) State {}

    pub fn response(
        _: SecurityHeaders,
        _: *app_state.Context,
        _: *State,
        value: anytype,
    ) void {
        value.setHeaderStatic(
            "content-security-policy",
            content_security_policy,
        ) catch {};
        value.setHeaderStatic("x-content-type-options", "nosniff") catch {};
        value.setHeaderStatic("referrer-policy", "strict-origin-when-cross-origin") catch {};
        value.setHeaderStatic(
            "permissions-policy",
            "camera=(), microphone=(), geolocation=(), payment=()",
        ) catch {};
        value.setHeaderStatic("x-frame-options", "DENY") catch {};
    }
};
