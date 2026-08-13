const ploof = @import("ploof_compile").ploof;

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
        _: anytype,
        _: *State,
        _: Definition.MultipartBodySpec.FileStart,
    ) Definition.MultipartBodySpec.FileAdmission(void) {
        return .{ .accept = .{ .upload = {} } };
    }

    pub fn complete(
        _: Consumer,
        _: anytype,
        _: *State,
        _: Definition.InputType,
        _: Definition.MultipartBodySpec.Summaries,
    ) ploof.Multipart.Decision(void) {
        return ploof.Multipart.commit({});
    }
};

const broken = Definition.handle(Consumer{});

export fn forceMultipartConsumerGenericFileStart() void {
    _ = @sizeOf(@TypeOf(broken));
}
