const std = @import("std");
const ploof = @import("ploof");
const app_state = @import("../app_state.zig");
const cookie = @import("../auth/cookie.zig");
const session = @import("../auth/session.zig");

pub const policy = ploof.Csrf.signedDoubleSubmit(app_state.Context, .{
    .origins = origins,
    .keys = keys,
    .binding = binding,
    .cookie_name = "poof_csrf",
});

pub const FormToken = struct {
    hidden: [192]u8 = undefined,
    hidden_len: u16 = 0,
    set_cookie: [192]u8 = undefined,
    set_cookie_len: u16 = 0,

    pub fn hiddenInput(self: *const FormToken) []const u8 {
        return self.hidden[0..self.hidden_len];
    }

    pub fn cookieHeader(self: *const FormToken) ?[]const u8 {
        if (self.set_cookie_len == 0) return null;
        return self.set_cookie[0..self.set_cookie_len];
    }
};

pub fn prepare(context: *app_state.Context) !FormToken {
    var issued = false;
    var token = policy.currentToken(context) catch token: {
        const io = context.state.io orelse return error.RandomUnavailable;
        var nonce: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &nonce);
        std.Io.random(io, &nonce);
        issued = true;
        break :token try policy.issue(context, nonce);
    };
    defer token.clear();

    var result = FormToken{};
    const hidden = try policy.hiddenInput(context, &token, &result.hidden);
    result.hidden_len = @intCast(hidden.len);
    if (issued) {
        const cookie_header = try policy.cookieHeader(&token, .{
            .secure = app_state.isProduction(context),
            .http_only = true,
            .same_site = .lax,
        }, &result.set_cookie);
        result.set_cookie_len = @intCast(cookie_header.len);
    }
    return result;
}

pub fn attach(response: *app_state.Context.ResponseType, token: *const FormToken) void {
    if (token.cookieHeader()) |header| response.appendHeader("set-cookie", header) catch {};
}

fn origins(state: *const app_state.State) *const app_state.Origins {
    return &state.csrf_origins;
}

fn keys(state: *const app_state.State) *const ploof.Csrf.Keyring {
    return &state.csrf_keys;
}

fn binding(context: *app_state.Context) ?ploof.Csrf.LoginBinding {
    var values: [8][]const u8 = undefined;
    var count: usize = 0;
    var iterator = context.request.headers.all("cookie").iterator();
    while (iterator.next()) |value| {
        if (count == values.len) return null;
        values[count] = value;
        count += 1;
    }
    const name = session.cookieName(app_state.isProduction(context));
    const encoded = (cookie.find(values[0..count], name) catch return null) orelse return null;
    var token = session.Token.parse(encoded) catch return null;
    defer token.clear();
    return ploof.Csrf.LoginBinding.fromRandomLoginValue(token.hash()) catch null;
}
