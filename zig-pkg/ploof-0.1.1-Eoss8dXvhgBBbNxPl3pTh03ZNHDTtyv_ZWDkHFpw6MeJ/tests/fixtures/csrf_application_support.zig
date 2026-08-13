const ploof = @import("ploof_compile").ploof;

pub const Origins = ploof.Csrf.OriginSet(1, 64);
pub const State = struct {
    origins: Origins = .{},
    session: ?ploof.Csrf.SessionToken = null,
    keys: ploof.Csrf.Keyring = .{},
    binding: ?ploof.Csrf.LoginBinding = null,
};
pub const Context = ploof.Context(State, ploof.response.standard_head_limits);
pub const Response = Context.ResponseType;

pub fn originsProvider(state: *const State) *const Origins {
    return &state.origins;
}

pub fn load(context: *Context) ?ploof.Csrf.SessionToken {
    return context.state.session;
}

pub fn store(context: *Context, token: ploof.Csrf.SessionToken) void {
    context.state.session = token;
}

pub fn clear(context: *Context) void {
    context.state.session = null;
}

pub const policy = ploof.Csrf.synchronizer(Context, .{
    .origins = originsProvider,
    .load = load,
    .store = store,
    .clear = clear,
});

pub fn keysProvider(state: *const State) *const ploof.Csrf.Keyring {
    return &state.keys;
}

pub fn bindingProvider(context: *Context) ?ploof.Csrf.LoginBinding {
    return context.state.binding;
}

pub fn bodyless(context: *Context) Response {
    return context.empty(.no_content);
}
