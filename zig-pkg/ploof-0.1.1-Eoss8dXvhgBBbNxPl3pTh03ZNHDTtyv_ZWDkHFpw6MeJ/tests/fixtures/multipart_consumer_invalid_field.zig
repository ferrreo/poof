const ploof = @import("ploof_compile").ploof;

const AppState = struct {};
const Context = ploof.Context(AppState, ploof.response.standard_head_limits);
const Definition = ploof.Endpoint(.{ .body = ploof.Multipart.decode(.{
    .age = ploof.Multipart.field(u16, ploof.Multipart.required),
}, .{}) });

const Consumer = struct {
    pub const State = void;

    pub fn field(_: Consumer, _: *State, _: u8) void {}

    pub fn complete(
        _: Consumer,
        context: *Context,
        _: *State,
        _: Definition.InputType,
        _: Definition.MultipartBodySpec.Summaries,
    ) ploof.Multipart.Decision(Context.ResponseType) {
        return ploof.Multipart.commit(context.empty(.no_content));
    }
};

const BrokenApplication = ploof.Application(.{
    .State = AppState,
    .routes = .{ploof.post("/", Definition.handle(Consumer{}))},
});

export fn forceMultipartConsumerInvalidField() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}
