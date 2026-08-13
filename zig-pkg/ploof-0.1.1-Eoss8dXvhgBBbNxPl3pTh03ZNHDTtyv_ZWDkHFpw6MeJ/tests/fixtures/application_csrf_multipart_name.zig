const ploof = @import("ploof_compile").ploof;
const support = @import("csrf_application_support.zig");

const custom_policy = ploof.Csrf.synchronizer(support.Context, .{
    .origins = struct {
        fn call(state: *const support.State) *const support.Origins {
            return &state.origins;
        }
    }.call,
    .load = struct {
        fn call(context: *support.Context) ?ploof.Csrf.SessionToken {
            return context.state.session;
        }
    }.call,
    .store = struct {
        fn call(context: *support.Context, token: ploof.Csrf.SessionToken) void {
            context.state.session = token;
        }
    }.call,
    .clear = struct {
        fn call(context: *support.Context) void {
            context.state.session = null;
        }
    }.call,
    .form_name = "token",
});

const Definition = ploof.Endpoint(.{ .body = ploof.Multipart.decode(.{
    ._csrf = ploof.Csrf.multipartField(),
}, .{}) });

const Consumer = struct {
    pub const State = void;

    pub fn complete(
        _: Consumer,
        context: *support.Context,
        _: *State,
        _: Definition.InputType,
        _: Definition.MultipartBodySpec.Summaries,
    ) ploof.Multipart.Decision(support.Response) {
        return ploof.Multipart.commit(context.empty(.no_content));
    }
};

const BrokenApplication = ploof.Application(.{
    .State = support.State,
    .middleware = .{custom_policy},
    .routes = .{ploof.route.post("/", Definition.handle(Consumer{}))},
});

export fn forceCsrfMultipartName() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}
