const multipart = @import("ploof_compile").multipart;
const runtime = @import("ploof_compile").application_multipart_upload_runtime;

const Spec = @TypeOf(multipart.decode(.{
    .upload = multipart.file(multipart.DiscardSink, multipart.required),
}, .{}));

const Consumer = struct {
    pub const State = void;

    pub fn fileStart(
        _: Consumer,
        _: anytype,
        _: *State,
        _: Spec.FileStart,
    ) Spec.FileAdmission(void) {
        return .{ .accept = .{ .upload = {} } };
    }
};

const Handler = struct {
    pub const definition = struct {
        pub const MultipartBodySpec = Spec;
    };
    pub const MultipartConsumer = Consumer;
    pub const MultipartState = Consumer.State;
    pub const handler_fn = Consumer{};
};

const BrokenRuntime = runtime.Runtime(Handler);

export fn forceMultipartUploadRuntimeGenericFileStart() void {
    _ = @sizeOf(BrokenRuntime);
}
