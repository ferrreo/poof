const upload = @import("../../src/multipart/upload.zig");

pub const operation_count_max = 64;

pub const Operation = enum(u8) { begin, write, finish, commit, abort };

pub const TraceEntry = struct {
    operation: Operation = .begin,
    sink: u8 = 0,
    serial: u16 = 0,
};

pub const Harness = struct {
    trace: [operation_count_max]TraceEntry = @splat(.{}),
    trace_len: usize = 0,
    next_serial: u16 = 1,

    fn append(self: *Harness, operation: Operation, sink: u8, serial: u16) void {
        if (self.trace_len == self.trace.len) @panic("bounded upload fuzz trace overflow");
        self.trace[self.trace_len] = .{
            .operation = operation,
            .sink = sink,
            .serial = serial,
        };
        self.trace_len += 1;
    }
};

pub const Behavior = struct {
    begin_async: bool,
    write_async: bool,
    finish_async: bool,
    commit_async: bool,
    abort_async: bool,
};

pub fn TestSink(comptime sink_id: u8) type {
    return struct {
        pub const ploof_multipart_sink = true;
        pub const State = struct { serial: u16 = 0, bytes: u64 = 0 };
        pub const WriteState = void;
        pub const Summary = struct { bytes: u64, sink: u8 };
        pub const BeginInput = u32;
        pub const Runtime = struct { harness: *Harness, behavior: Behavior };
        pub const StartupState = void;
        pub const Error = error{Rejected};
        pub const io_requirements = upload.IoRequirements{ .write = true, .sync = true };
        pub const request_handles_max: u8 = 1;
        pub const runtime_handles_max: u8 = 0;
        pub const initial_state: State = .{};
        pub const initial_write_state: WriteState = {};
        pub const initial_startup_state: StartupState = {};

        pub fn runtimeStart(
            _: *StartupState,
            _: upload.PollEvent(upload.RuntimeStartInput),
        ) Error!upload.Poll(Runtime) {
            return error.Rejected;
        }

        pub fn runtimeStop(
            _: *Runtime,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            return completeVoid(event);
        }

        pub fn begin(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(BeginInput),
        ) Error!upload.Poll(void) {
            return switch (event) {
                .start => |input| start: {
                    _ = input;
                    state.serial = runtime.harness.next_serial;
                    runtime.harness.next_serial += 1;
                    runtime.harness.append(.begin, sink_id, state.serial);
                    break :start requestOrDone(runtime.behavior.begin_async);
                },
                .completion => |completion| completionVoid(completion),
            };
        }

        pub fn write(
            runtime: *Runtime,
            state: *State,
            _: *WriteState,
            event: upload.PollEvent(upload.WriteInput),
        ) Error!upload.Poll(void) {
            return switch (event) {
                .start => |input| start: {
                    state.bytes += input.bytes.len;
                    runtime.harness.append(.write, sink_id, state.serial);
                    if (!runtime.behavior.write_async) break :start .{ .done = {} };
                    break :start .{ .request = .{ .write = .{
                        .file = upload.FileHandle.init(sink_id),
                        .bytes = input.bytes,
                        .offset = input.offset,
                    } } };
                },
                .completion => |completion| completion: {
                    if (completion == .failure and completion.failure == .canceled) {
                        break :completion .{ .done = {} };
                    }
                    _ = try expectSuccess(completion);
                    break :completion .{ .done = {} };
                },
            };
        }

        pub fn finish(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(upload.FinishInput),
        ) Error!upload.Poll(Summary) {
            return switch (event) {
                .start => |input| start: {
                    if (input.bytes != state.bytes) return error.Rejected;
                    runtime.harness.append(.finish, sink_id, state.serial);
                    if (runtime.behavior.finish_async) {
                        break :start .{ .request = syncRequest() };
                    }
                    break :start .{ .done = summary(state) };
                },
                .completion => |completion| completion: {
                    _ = try expectSuccess(completion);
                    break :completion .{ .done = summary(state) };
                },
            };
        }

        pub fn commit(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            return lifecycle(runtime, state, event, .commit);
        }

        pub fn abort(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            return lifecycle(runtime, state, event, .abort);
        }

        fn lifecycle(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(void),
            operation: Operation,
        ) Error!upload.Poll(void) {
            return switch (event) {
                .start => start: {
                    runtime.harness.append(operation, sink_id, state.serial);
                    const asynchronous = if (operation == .commit)
                        runtime.behavior.commit_async
                    else
                        runtime.behavior.abort_async;
                    break :start requestOrDone(asynchronous);
                },
                .completion => |completion| completionVoid(completion),
            };
        }

        fn completeVoid(event: upload.PollEvent(void)) Error!upload.Poll(void) {
            return switch (event) {
                .start => .{ .done = {} },
                .completion => |completion| completionVoid(completion),
            };
        }

        fn completionVoid(completion: upload.IoCompletion) Error!upload.Poll(void) {
            _ = try expectSuccess(completion);
            return .{ .done = {} };
        }

        fn expectSuccess(completion: upload.IoCompletion) Error!upload.IoSuccess {
            return switch (completion) {
                .success => |success| success,
                .failure => error.Rejected,
            };
        }

        fn requestOrDone(asynchronous: bool) upload.Poll(void) {
            return if (asynchronous) .{ .request = syncRequest() } else .{ .done = {} };
        }

        fn syncRequest() upload.IoRequest {
            return .{ .sync = .{ .file = upload.FileHandle.init(sink_id) } };
        }

        fn summary(state: *const State) Summary {
            return .{ .bytes = state.bytes, .sink = sink_id };
        }
    };
}
