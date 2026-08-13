const multipart = @import("ploof_compile").multipart;
const runtime = @import("ploof_compile").application_multipart_runtime;

const Base = multipart.DiscardSink;
const CustomSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = Base.State;
    pub const WriteState = Base.WriteState;
    pub const Summary = Base.Summary;
    pub const BeginInput = Base.BeginInput;
    pub const Runtime = Base.Runtime;
    pub const StartupState = Base.StartupState;
    pub const io_requirements = Base.io_requirements;
    pub const request_handles_max = Base.request_handles_max;
    pub const runtime_handles_max = Base.runtime_handles_max;
    pub const Error = Base.Error;
    pub const initial_state = Base.initial_state;
    pub const initial_write_state = Base.initial_write_state;
    pub const initial_startup_state = Base.initial_startup_state;
    pub const runtimeStart = Base.runtimeStart;
    pub const runtimeStop = Base.runtimeStop;
    pub const begin = Base.begin;
    pub const write = Base.write;
    pub const finish = Base.finish;
    pub const commit = Base.commit;
    pub const abort = Base.abort;
};

const Spec = @TypeOf(multipart.decode(.{
    .upload = multipart.file(CustomSink, multipart.required),
}, .{}));

const Handler = struct {
    pub const definition = struct {
        pub const MultipartBodySpec = Spec;
    };
};

const BrokenRuntime = runtime.Runtime(Handler);

export fn forceMultipartRuntimeSinkContract() void {
    _ = @sizeOf(BrokenRuntime);
}
