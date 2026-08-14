const app_state = @import("../app_state.zig");

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
            "default-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' https: http: data:; connect-src 'self'",
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
