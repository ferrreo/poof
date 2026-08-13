const std = @import("std");

const config_module = @import("file_sink_config.zig");
const request_module = @import("../internal/multipart/file_sink_request.zig");
const runtime_module = @import("../internal/multipart/file_sink_runtime.zig");
const upload = @import("upload.zig");

pub fn FileSink(comptime supplied: config_module.FileSinkConfig) type {
    @setEvalBranchQuota(100_000);
    const Config = config_module.Resolved(supplied);
    const Request = request_module.Request(supplied);
    const Lifecycle = runtime_module.Lifecycle(supplied);

    return struct {
        pub const ploof_multipart_sink = true;
        pub const ploof_file_sink = true;
        pub const BeginInput = Request.BeginInput;
        pub const Key = Config.Key;
        pub const State = Request.State;
        pub const WriteState = Request.WriteState;
        pub const Summary = Request.Summary;
        pub const Runtime = Lifecycle.Runtime;
        pub const StartupState = Lifecycle.StartupState;
        pub const StartupFailure = Lifecycle.StartupFailure;
        pub const LifecycleFailureSource = Request.LifecycleFailureSource;
        pub const Report = config_module.FileSinkReport;
        pub const Error = Lifecycle.Error;

        pub const io_requirements = Config.io_requirements;
        pub const request_handles_max = Config.request_handles_max;
        pub const runtime_handles_max = Config.runtime_handles_max;
        pub const initial_state = Request.initial_state;
        pub const initial_write_state = Request.initial_write_state;
        pub const initial_startup_state = Lifecycle.initial_startup_state;
        pub const startup_report = Config.startup_report;

        pub fn runtimeStart(
            state: *StartupState,
            event: upload.PollEvent(upload.RuntimeStartInput),
        ) Error!upload.Poll(Runtime) {
            return Lifecycle.runtimeStart(state, event);
        }

        pub fn runtimeStop(
            runtime: *Runtime,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            return Lifecycle.runtimeStop(runtime, event);
        }

        pub fn abandonRuntimeStart(state: *StartupState) void {
            Lifecycle.abandonRuntimeStart(state);
        }

        pub fn abandonRuntimeStop(runtime: *Runtime) void {
            Lifecycle.abandonRuntimeStop(runtime);
        }

        pub fn begin(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(BeginInput),
        ) Error!upload.Poll(void) {
            return Request.begin(runtime, state, event);
        }

        pub fn write(
            runtime: *Runtime,
            state: *State,
            write_state: *WriteState,
            event: upload.PollEvent(upload.WriteInput),
        ) Error!upload.Poll(void) {
            return Request.write(runtime, state, write_state, event);
        }

        pub fn finish(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(upload.FinishInput),
        ) Error!upload.Poll(Summary) {
            return Request.finish(runtime, state, event);
        }

        pub fn commit(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            return Request.commit(runtime, state, event);
        }

        pub fn abort(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            return Request.abort(runtime, state, event);
        }

        pub fn startupFailure(state: *const StartupState) ?StartupFailure {
            return Lifecycle.startupFailure(state);
        }

        pub fn lifecycleStateFailureSource(state: *const State) LifecycleFailureSource {
            return Request.lifecycleStateFailureSource(state);
        }

        pub fn report(runtime: *const Runtime) Report {
            return Request.report(runtime);
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
