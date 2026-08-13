const ploof = @import("ploof_compile").ploof;

const Origins = ploof.Csrf.OriginSet(1, 64);
const AppState = struct {
    origins: Origins = .{},
    keys: ploof.Csrf.Keyring = .{},
};
const Context = ploof.Context(AppState, ploof.response.standard_head_limits);

fn origins(state: *const AppState) *const Origins {
    return &state.origins;
}

fn keys(state: *const AppState) *const ploof.Csrf.Keyring {
    return &state.keys;
}

fn binding(_: *Context) ploof.Csrf.LoginBinding {
    return undefined;
}

const broken = ploof.Csrf.signedDoubleSubmit(Context, .{
    .origins = origins,
    .keys = keys,
    .binding = binding,
});

export fn forceCsrfBindingSignature() void {
    _ = @TypeOf(broken);
}
