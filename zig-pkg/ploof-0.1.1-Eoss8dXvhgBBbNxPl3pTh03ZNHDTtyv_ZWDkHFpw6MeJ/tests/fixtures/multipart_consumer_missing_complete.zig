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
};
const broken = Definition.handle(Consumer{});

export fn forceMultipartConsumerMissingComplete() void {
    _ = @sizeOf(@TypeOf(broken));
}
