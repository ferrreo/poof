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
    pub const State = void;

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
        _: *Context,
        _: *State,
        _: Definition.InputType,
        _: Definition.MultipartBodySpec.Summaries,
    ) u8 {
        return 0;
    }
};

const BrokenApplication = ploof.Application(.{
    .State = AppState,
    .routes = .{ploof.post("/", Definition.handle(Consumer{}))},
});

export fn forceMultipartConsumerInvalidComplete() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}
