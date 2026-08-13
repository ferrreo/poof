const ploof = @import("ploof_compile").ploof;

const AppState = struct {};
const Context = ploof.Context(AppState, ploof.response.standard_head_limits);
const Definition = ploof.Endpoint(.{ .body = ploof.Multipart.decode(.{
    .upload = ploof.Multipart.file(
        ploof.Multipart.DiscardSink,
        ploof.Multipart.required,
    ),
}, .{}) });

const Consumer = struct {
    pub const State = u8;

    pub fn init(_: Consumer) State {
        return 0;
    }

    pub fn fileStart(
        _: Consumer,
        _: *Context,
        _: *State,
        _: Definition.MultipartBodySpec.FileStart,
    ) Definition.MultipartBodySpec.FileAdmission(Context.ResponseType) {
        return .{ .accept = .{ .upload = {} } };
    }

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

export fn forceMultipartConsumerInvalidInit() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}
