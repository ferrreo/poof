const ploof = @import("ploof_compile").ploof;

const Origins = ploof.Csrf.OriginSet(1, 64);
const AppState = struct { origins: Origins = .{} };
const Context = ploof.Context(AppState, ploof.response.standard_head_limits);

fn origins(state: *const AppState) *const Origins {
    return &state.origins;
}

fn load(_: *Context) ploof.Csrf.SessionToken {
    return undefined;
}

fn store(_: *Context, _: ploof.Csrf.SessionToken) void {}
fn clear(_: *Context) void {}

const broken = ploof.Csrf.synchronizer(Context, .{
    .origins = origins,
    .load = load,
    .store = store,
    .clear = clear,
});

export fn forceCsrfLoadSignature() void {
    _ = @TypeOf(broken);
}
