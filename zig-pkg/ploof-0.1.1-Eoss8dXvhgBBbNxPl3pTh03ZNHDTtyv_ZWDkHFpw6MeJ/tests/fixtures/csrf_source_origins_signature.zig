const ploof = @import("ploof_compile").ploof;

const Origins = ploof.Csrf.OriginSet(1, 64);
const AppState = struct { origins: Origins = .{} };
const Context = ploof.Context(AppState, ploof.response.standard_head_limits);

fn origins(state: *const AppState) *const Origins {
    return &state.origins;
}

fn sourceOrigins(state: *const AppState) Origins {
    return state.origins;
}

fn load(_: *Context) ?ploof.Csrf.SessionToken {
    return null;
}

fn store(_: *Context, _: ploof.Csrf.SessionToken) void {}
fn clear(_: *Context) void {}

const broken = ploof.Csrf.synchronizer(Context, .{
    .origins = origins,
    .source_origins = sourceOrigins,
    .load = load,
    .store = store,
    .clear = clear,
});

export fn forceCsrfSourceOriginsSignature() void {
    _ = @TypeOf(broken);
}
