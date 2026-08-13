const std = @import("std");
const multipart = @import("../../src/multipart.zig");
const upload = @import("../../src/multipart/upload.zig");
const adapter = @import("../../src/internal/multipart/upload_adapter.zig");
const upload_layout = @import("../../src/internal/multipart/upload_layout.zig");
const sink_driver = @import("../../src/internal/upload/sink_driver.zig");

const Flavor = enum { alpha, beta };

fn TestSink(comptime flavor: Flavor) type {
    return struct {
        const Self = @This();

        pub const ploof_multipart_sink = true;
        pub const State = struct {
            total: usize = if (flavor == .alpha) 11 else 23,
            padding: [if (flavor == .alpha) 31 else 3]u8 = @splat(0),
        };
        pub const WriteState = struct { path: [9]u8 = @splat(0) };
        pub const Summary = if (flavor == .alpha)
            struct { bytes: usize, alpha: bool }
        else
            struct { bytes: usize };
        pub const BeginInput = if (flavor == .alpha) usize else bool;
        pub const Runtime = struct {
            begins: u8 = 0,
            writes: u8 = 0,
            commits: u8 = 0,
            aborts: u8 = 0,
        };
        pub const StartupState = void;
        pub const Error = if (flavor == .alpha)
            error{ AlphaRejected, VariantMismatch }
        else
            error{BetaRejected};
        pub const io_requirements: upload.IoRequirements = if (flavor == .alpha)
            .{ .unlink = true }
        else
            .{ .sync = true };
        pub const request_handles_max: u8 = if (flavor == .alpha) 2 else 1;
        pub const runtime_handles_max: u8 = 0;
        pub const initial_state: State = .{};
        pub const initial_write_state: WriteState = .{};
        pub const initial_startup_state: StartupState = {};

        pub fn runtimeStart(
            _: *StartupState,
            event: upload.PollEvent(upload.RuntimeStartInput),
        ) Error!upload.Poll(Runtime) {
            return switch (event) {
                .start => .{ .done = .{} },
                .completion => rejection(),
            };
        }

        pub fn runtimeStop(
            _: *Runtime,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            return lifecycle(event);
        }

        pub fn begin(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(BeginInput),
        ) Error!upload.Poll(void) {
            const input = switch (event) {
                .start => |value| value,
                .completion => return rejection(),
            };
            if (comptime flavor == .alpha) {
                if (input == 0) return rejection();
                if (input == std.math.maxInt(usize)) return error.VariantMismatch;
                state.total = input;
            } else {
                if (!input) return rejection();
                state.total = 1;
            }
            runtime.begins += 1;
            return .{ .done = {} };
        }

        pub fn write(
            runtime: *Runtime,
            state: *State,
            write_state: *WriteState,
            event: upload.PollEvent(upload.WriteInput),
        ) Error!upload.Poll(void) {
            if (comptime flavor == .alpha) return alphaWrite(
                runtime,
                state,
                write_state,
                event,
            );
            return betaWrite(runtime, state, event);
        }

        fn betaWrite(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(upload.WriteInput),
        ) Error!upload.Poll(void) {
            return switch (event) {
                .start => |input| request: {
                    state.total += input.bytes.len;
                    runtime.writes += 1;
                    break :request .{ .request = .{
                        .sync = .{ .file = upload.FileHandle.init(4) },
                    } };
                },
                .completion => |completion| done: {
                    if (completion != .success or completion.success != .sync) {
                        return rejection();
                    }
                    break :done .{ .done = {} };
                },
            };
        }

        fn alphaWrite(
            runtime: *Runtime,
            state: *State,
            write_state: *WriteState,
            event: upload.PollEvent(upload.WriteInput),
        ) Error!upload.Poll(void) {
            return switch (event) {
                .start => |input| request: {
                    state.total += input.bytes.len;
                    runtime.writes += 1;
                    @memcpy(write_state.path[0..4], "temp");
                    break :request .{ .request = .{
                        .unlink = .{
                            .directory = upload.FileHandle.init(3),
                            .path = write_state.path[0..4 :0],
                        },
                    } };
                },
                .completion => |completion| done: {
                    if (write_state.path[0] != 't' or completion != .success or
                        completion.success != .unlink)
                    {
                        return rejection();
                    }
                    break :done .{ .done = {} };
                },
            };
        }

        pub fn finish(
            _: *Runtime,
            state: *State,
            event: upload.PollEvent(upload.FinishInput),
        ) Error!upload.Poll(Summary) {
            if (event != .start) return rejection();
            if (comptime flavor == .alpha) {
                return .{ .done = .{ .bytes = state.total, .alpha = true } };
            }
            return .{ .done = .{ .bytes = state.total } };
        }

        pub fn commit(
            runtime: *Runtime,
            _: *State,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            const result = try lifecycle(event);
            runtime.commits += 1;
            return result;
        }

        pub fn abort(
            runtime: *Runtime,
            _: *State,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            const result = try lifecycle(event);
            runtime.aborts += 1;
            return result;
        }

        fn lifecycle(event: upload.PollEvent(void)) Error!upload.Poll(void) {
            return switch (event) {
                .start => .{ .done = {} },
                .completion => rejection(),
            };
        }

        fn rejection() Error {
            return if (flavor == .alpha) error.AlphaRejected else error.BetaRejected;
        }
    };
}

const Alpha = TestSink(.alpha);
const Beta = TestSink(.beta);
const spec = multipart.decode(.{
    .alpha_first = multipart.file(Alpha, multipart.oneTo(2)),
    .beta = multipart.file(Beta, multipart.oneTo(3)),
    .alpha_last = multipart.file(Alpha, multipart.optional),
    .discard = multipart.file(multipart.DiscardSink, multipart.optional),
}, .{ .limits = .{ .parts_max = 7, .files_max = 7 } });
const Spec = @TypeOf(spec);
const Storage = upload_layout.Layout(Spec);

const Registry = struct {
    alpha: Alpha.Runtime = .{},
    beta: Beta.Runtime = .{},
    discard: multipart.DiscardSink.Runtime = {},

    pub fn get(self: *@This(), comptime Sink: type) *Sink.Runtime {
        if (Sink == Alpha) return &self.alpha;
        if (Sink == Beta) return &self.beta;
        if (Sink == multipart.DiscardSink) return &self.discard;
        unreachable;
    }
};

const Mux = adapter.SinkMux(Spec, Registry);

const LaunderPhase = enum {
    none,
    begin,
    write_start,
    write_active,
    finish,
    commit,
    abort,
};

const LaunderRuntime = struct {
    phase: LaunderPhase = .none,
    emits: bool,
};
const LaunderError = error{Rejected};

const UndeclaredWriteSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const Runtime = LaunderRuntime;
    pub const StartupState = void;
    pub const Error = LaunderError;
    pub const io_requirements = upload.IoRequirements.none;
    pub const request_handles_max: u8 = 0;
    pub const runtime_handles_max: u8 = 0;
    pub const initial_state: State = {};
    pub const initial_write_state: WriteState = {};
    pub const initial_startup_state: StartupState = {};
    pub const runtimeStart = launderRuntimeStart;
    pub const runtimeStop = launderRuntimeStop;
    pub const begin = launderBegin;
    pub const write = launderWrite;
    pub const finish = launderFinish;
    pub const commit = launderCommit;
    pub const abort = launderAbort;
};

const DeclaredWriteSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const Runtime = LaunderRuntime;
    pub const StartupState = void;
    pub const Error = LaunderError;
    pub const io_requirements = upload.IoRequirements{ .write = true };
    pub const request_handles_max: u8 = 0;
    pub const runtime_handles_max: u8 = 0;
    pub const initial_state: State = {};
    pub const initial_write_state: WriteState = {};
    pub const initial_startup_state: StartupState = {};
    pub const runtimeStart = launderRuntimeStart;
    pub const runtimeStop = launderRuntimeStop;
    pub const begin = launderBegin;
    pub const write = launderWrite;
    pub const finish = launderFinish;
    pub const commit = launderCommit;
    pub const abort = launderAbort;
};

fn launderRuntimeStart(
    _: *void,
    event: upload.PollEvent(upload.RuntimeStartInput),
) LaunderError!upload.Poll(LaunderRuntime) {
    return switch (event) {
        .start => .{ .done = .{ .emits = false } },
        .completion => error.Rejected,
    };
}

fn launderRuntimeStop(
    _: *LaunderRuntime,
    event: upload.PollEvent(void),
) LaunderError!upload.Poll(void) {
    return switch (event) {
        .start => .{ .done = {} },
        .completion => error.Rejected,
    };
}

fn launderBegin(
    runtime: *LaunderRuntime,
    _: *void,
    _: upload.PollEvent(void),
) LaunderError!upload.Poll(void) {
    return if (runtime.emits and runtime.phase == .begin)
        launderWriteRequest()
    else
        .{ .done = {} };
}

fn launderWrite(
    runtime: *LaunderRuntime,
    _: *void,
    _: *void,
    event: upload.PollEvent(upload.WriteInput),
) LaunderError!upload.Poll(void) {
    const emits = switch (event) {
        .start => runtime.phase == .write_start,
        .completion => runtime.phase == .write_active,
    };
    return if (runtime.emits and emits) launderWriteRequest() else .{ .done = {} };
}

fn launderFinish(
    runtime: *LaunderRuntime,
    _: *void,
    _: upload.PollEvent(upload.FinishInput),
) LaunderError!upload.Poll(void) {
    return if (runtime.emits and runtime.phase == .finish)
        launderWriteRequest()
    else
        .{ .done = {} };
}

fn launderCommit(
    runtime: *LaunderRuntime,
    _: *void,
    _: upload.PollEvent(void),
) LaunderError!upload.Poll(void) {
    return if (runtime.emits and runtime.phase == .commit)
        launderWriteRequest()
    else
        .{ .done = {} };
}

fn launderAbort(
    runtime: *LaunderRuntime,
    _: *void,
    _: upload.PollEvent(void),
) LaunderError!upload.Poll(void) {
    return if (runtime.emits and runtime.phase == .abort)
        launderWriteRequest()
    else
        .{ .done = {} };
}

fn launderWriteRequest() upload.Poll(void) {
    return .{ .request = .{ .write = .{
        .file = upload.FileHandle.init(9),
        .bytes = "x",
        .offset = 0,
    } } };
}

const launder_spec = multipart.decode(.{
    .undeclared = multipart.file(UndeclaredWriteSink, multipart.required),
    .declared = multipart.file(DeclaredWriteSink, multipart.required),
}, .{});
const LaunderSpec = @TypeOf(launder_spec);
const LaunderStorage = upload_layout.Layout(LaunderSpec);
const LaunderRegistry = struct {
    undeclared: LaunderRuntime = .{ .emits = true },
    declared: LaunderRuntime = .{ .emits = false },

    pub fn get(self: *@This(), comptime Sink: type) *Sink.Runtime {
        if (Sink == UndeclaredWriteSink) return &self.undeclared;
        if (Sink == DeclaredWriteSink) return &self.declared;
        unreachable;
    }
};
const LaunderMux = adapter.SinkMux(LaunderSpec, LaunderRegistry);

test "upload layout keeps exact per-field storage and fitting lengths" {
    const ExactStates = struct {
        alpha_first: [2]Alpha.State,
        beta: [3]Beta.State,
        alpha_last: [1]Alpha.State,
        discard: [1]multipart.DiscardSink.State,
    };
    const ExactSummaries = struct {
        alpha_first: [2]Alpha.Summary,
        beta: [3]Beta.Summary,
        alpha_last: [1]Alpha.Summary,
        discard: [1]multipart.DiscardSink.Summary,
    };
    const LargestStateArray = [Storage.total_maximum]union(enum) {
        alpha: Alpha.State,
        beta: Beta.State,
    };
    const LargestSummaryArray = [Storage.total_maximum]union(enum) {
        alpha: Alpha.Summary,
        beta: Beta.Summary,
    };

    try std.testing.expect(@FieldType(Storage.StateStorage, "alpha_first") ==
        [2]Alpha.State);
    try std.testing.expect(@FieldType(Storage.SummaryStorage, "beta") ==
        [3]Beta.Summary);
    try std.testing.expect(@FieldType(Storage.SummaryLengths, "alpha_first") ==
        std.math.IntFittingRange(0, 2));
    try std.testing.expectEqual(@sizeOf(ExactStates), @sizeOf(Storage.StateStorage));
    try std.testing.expectEqual(@sizeOf(ExactSummaries), @sizeOf(Storage.SummaryStorage));
    try std.testing.expect(@sizeOf(Storage.StateStorage) < @sizeOf(LargestStateArray));
    try std.testing.expect(@sizeOf(Storage.SummaryStorage) < @sizeOf(LargestSummaryArray));
    try std.testing.expect(@FieldType(Mux.State, "alpha_last") == *Alpha.State);
    try std.testing.expect(@FieldType(Mux.WritePayload, "beta") == Beta.WriteState);
    try std.testing.expect(@FieldType(Mux.Summary, "alpha_first") == Alpha.Summary);
    try std.testing.expectEqual(@as(u32, 7), Storage.total_maximum);
    try std.testing.expectEqual(@as(u32, 6), Storage.non_discard_total_maximum);
    try std.testing.expectEqual(@as(u32, 9), Storage.request_handles_maximum);
    try std.testing.expectEqual(
        upload.IoRequirements{ .unlink = true, .sync = true },
        Mux.io_requirements,
    );
    try std.testing.expect(Mux.isDiscard(.discard));
    try std.testing.expect(!Mux.isDiscard(.alpha_first));

    var storage = Storage.init();
    const alpha = try storage.beginState(.alpha_first, 2);
    const beta = try storage.beginState(.beta, 3);
    try std.testing.expectEqual(@as(usize, 11), alpha.alpha_first.total);
    try std.testing.expectEqual(@as(usize, 23), beta.beta.total);
    try std.testing.expectError(
        error.InvalidOccurrence,
        storage.beginState(.alpha_first, 0),
    );
    try std.testing.expectError(
        error.InvalidOccurrence,
        storage.beginState(.alpha_first, 3),
    );
    try storage.storeSummary(.beta, 1, .{ .beta = .{ .bytes = 17 } });
    try std.testing.expectEqual(@as(usize, 17), storage.summaryViews().beta.slice()[0].bytes);
    try std.testing.expectError(
        error.OccurrenceOutOfOrder,
        storage.storeSummary(.beta, 3, .{ .beta = .{ .bytes = 19 } }),
    );
    try std.testing.expectError(
        error.VariantMismatch,
        storage.storeSummary(.beta, 2, .{ .alpha_first = .{ .bytes = 19, .alpha = true } }),
    );
}

test "sink mux dispatches repeated heterogeneous fields without erasure" {
    comptime upload.validateRequestSink(Mux);
    var storage = Storage.init();
    var registry = Registry{};
    var runtime = Mux.Runtime{ .registry = &registry };

    var first = try storage.beginState(.alpha_first, 2);
    try expectDone(try Mux.begin(&runtime, &first, .{
        .start = .{ .alpha_first = 5 },
    }));
    var first_write = Mux.initial_write_state;
    const request = try Mux.write(&runtime, &first, &first_write, .{
        .start = .{ .bytes = "abc", .offset = 0 },
    });
    try std.testing.expect(request == .request and request.request == .unlink);
    try std.testing.expect(request.request.unlink.path.ptr ==
        first_write.payload.alpha_first.path[0..4].ptr);
    clobberStack();
    try std.testing.expectEqualStrings("temp", request.request.unlink.path);
    try expectDone(try Mux.write(&runtime, &first, &first_write, .{
        .completion = .{ .success = .{ .unlink = {} } },
    }));
    const first_summary = try Mux.finish(&runtime, &first, .{
        .start = .{ .bytes = 3 },
    });
    try std.testing.expectEqual(@as(usize, 8), first_summary.done.alpha_first.bytes);

    var second = try storage.beginState(.beta, 3);
    try std.testing.expectError(error.VariantMismatch, Mux.begin(&runtime, &second, .{
        .start = .{ .alpha_last = 4 },
    }));
    try std.testing.expectEqual(adapter.FailureSource.invalid_request, Mux.lifecycleFailureSource(
        &runtime,
    ));
    try expectDone(try Mux.begin(&runtime, &second, .{ .start = .{ .beta = true } }));
    var second_write = Mux.initial_write_state;
    const second_request = try Mux.write(&runtime, &second, &second_write, .{
        .start = .{ .bytes = "xy", .offset = 0 },
    });
    try std.testing.expect(second_request == .request and second_request.request == .sync);
    try expectDone(try Mux.write(&runtime, &second, &second_write, .{
        .completion = .{ .success = .{ .sync = {} } },
    }));
    const second_summary = try Mux.finish(&runtime, &second, .{
        .start = .{ .bytes = 2 },
    });
    try std.testing.expectEqual(@as(usize, 3), second_summary.done.beta.bytes);

    var last = try storage.beginState(.alpha_last, 1);
    try expectDone(try Mux.begin(&runtime, &last, .{
        .start = .{ .alpha_last = 9 },
    }));
    try expectDone(try Mux.commit(&runtime, &first, .{ .start = {} }));
    try expectDone(try Mux.abort(&runtime, &second, .{ .start = {} }));
    try std.testing.expectEqual(@as(u8, 2), registry.alpha.begins);
    try std.testing.expectEqual(@as(u8, 1), registry.beta.begins);
    try std.testing.expectEqual(@as(u8, 1), registry.alpha.commits);
    try std.testing.expectEqual(@as(u8, 1), registry.beta.aborts);
}

test "sink mux carries finite sink errors and rejects missing write state" {
    acceptsMuxError(error.AlphaRejected);
    acceptsMuxError(error.BetaRejected);
    acceptsMuxError(error.MissingWriteState);
    try std.testing.expect(@typeInfo(Mux.Error).error_set != null);

    var storage = Storage.init();
    var registry = Registry{};
    var runtime = Mux.Runtime{ .registry = &registry };
    var state = try storage.beginState(.alpha_first, 1);
    var write_state = Mux.initial_write_state;
    try std.testing.expectError(error.MissingWriteState, Mux.write(
        &runtime,
        &state,
        &write_state,
        .{ .completion = .{ .success = .{ .sync = {} } } },
    ));
    try std.testing.expectEqual(adapter.FailureSource.invalid_request, Mux.writeFailureSource(
        &write_state,
    ));
    try std.testing.expectError(error.AlphaRejected, Mux.begin(
        &runtime,
        &state,
        .{ .start = .{ .alpha_first = 0 } },
    ));

    var beta = try storage.beginState(.beta, 1);
    var wrong = Mux.initial_write_state;
    wrong.payload = .{ .alpha_first = .{} };
    wrong.initialized = true;
    try std.testing.expectError(error.VariantMismatch, Mux.write(
        &runtime,
        &beta,
        &wrong,
        .{ .completion = .{ .success = .{ .sync = {} } } },
    ));
    try std.testing.expectEqual(adapter.FailureSource.invalid_request, Mux.writeFailureSource(
        &wrong,
    ));
}

test "sink drivers distinguish mux invariants from colliding sink errors" {
    var storage = Storage.init();
    var registry = Registry{};
    var runtime = Mux.Runtime{ .registry = &registry };
    var beta = try storage.beginState(.beta, 1);

    var invalid_lifecycle = sink_driver.Lifecycle(Mux){};
    try std.testing.expectError(error.VariantMismatch, invalid_lifecycle.startBegin(
        &runtime,
        &beta,
        .{ .alpha_first = 1 },
    ));
    try std.testing.expectEqual(
        sink_driver.FailureSource.invalid_request,
        invalid_lifecycle.lastFailureSource(),
    );

    var alpha = try storage.beginState(.alpha_first, 1);
    var sink_lifecycle = sink_driver.Lifecycle(Mux){};
    try std.testing.expectError(error.VariantMismatch, sink_lifecycle.startBegin(
        &runtime,
        &alpha,
        .{ .alpha_first = std.math.maxInt(usize) },
    ));
    try std.testing.expectEqual(
        sink_driver.FailureSource.sink,
        sink_lifecycle.lastFailureSource(),
    );

    var write = sink_driver.Write(Mux){};
    const request = try write.start(&runtime, &alpha, .{ .bytes = "z", .offset = 0 });
    try std.testing.expect(request == .request and request.request == .unlink);
    try std.testing.expectError(error.VariantMismatch, write.resumeWrite(
        &runtime,
        &beta,
        .{ .success = .{ .unlink = {} } },
    ));
    try std.testing.expectEqual(
        sink_driver.FailureSource.invalid_request,
        write.lastFailureSource(),
    );
}

test "selected sink cannot borrow another sink I/O requirement" {
    comptime upload.validateRequestSink(LaunderMux);
    try std.testing.expectEqual(
        upload.IoRequirements{ .write = true },
        LaunderMux.io_requirements,
    );

    var storage = LaunderStorage.init();
    var registry = LaunderRegistry{};
    var runtime = LaunderMux.Runtime{ .registry = &registry };
    var state = try storage.beginState(.undeclared, 1);

    try expectLaunderedDriverRequests(&registry, &runtime, &state);
    try expectLaunderedCompletionRequests(&registry, &runtime, &state);
}

fn expectLaunderedDriverRequests(
    registry: *LaunderRegistry,
    runtime: *LaunderMux.Runtime,
    state: *LaunderMux.State,
) !void {
    registry.undeclared.phase = .begin;
    var lifecycle_driver = sink_driver.Lifecycle(LaunderMux){};
    try std.testing.expectError(error.InvalidRequest, lifecycle_driver.startBegin(
        runtime,
        state,
        .{ .undeclared = {} },
    ));
    try std.testing.expectEqual(
        sink_driver.FailureSource.invalid_request,
        lifecycle_driver.lastFailureSource(),
    );
    try std.testing.expectEqual(
        sink_driver.FailureSource.invalid_request,
        lifecycle_driver.latchedFailureSource(),
    );
    try std.testing.expectError(error.Failed, lifecycle_driver.startBegin(
        runtime,
        state,
        .{ .undeclared = {} },
    ));

    registry.undeclared.phase = .write_start;
    var write_driver = sink_driver.Write(LaunderMux){};
    try std.testing.expectError(error.InvalidRequest, write_driver.start(
        runtime,
        state,
        .{ .bytes = "x", .offset = 0 },
    ));
    try std.testing.expectEqual(
        sink_driver.FailureSource.invalid_request,
        write_driver.lastFailureSource(),
    );
    try std.testing.expectError(error.Failed, write_driver.start(
        runtime,
        state,
        .{ .bytes = "x", .offset = 0 },
    ));
}

fn expectLaunderedCompletionRequests(
    registry: *LaunderRegistry,
    runtime: *LaunderMux.Runtime,
    state: *LaunderMux.State,
) !void {
    registry.undeclared.phase = .none;
    var write_state = LaunderMux.initial_write_state;
    try expectDone(try LaunderMux.write(
        runtime,
        state,
        &write_state,
        .{ .start = .{ .bytes = "x", .offset = 0 } },
    ));
    registry.undeclared.phase = .write_active;
    try std.testing.expectError(error.InvalidRequest, LaunderMux.write(
        runtime,
        state,
        &write_state,
        .{ .completion = .{ .success = .{ .write = 1 } } },
    ));
    try std.testing.expectEqual(
        adapter.FailureSource.invalid_request,
        LaunderMux.writeFailureSource(&write_state),
    );

    registry.undeclared.phase = .finish;
    try std.testing.expectError(error.InvalidRequest, LaunderMux.finish(
        runtime,
        state,
        .{ .start = .{ .bytes = 1 } },
    ));
    try std.testing.expectEqual(
        adapter.FailureSource.invalid_request,
        LaunderMux.lifecycleFailureSource(runtime),
    );

    registry.undeclared.phase = .commit;
    try std.testing.expectError(error.InvalidRequest, LaunderMux.commit(
        runtime,
        state,
        .{ .start = {} },
    ));
    registry.undeclared.phase = .abort;
    try std.testing.expectError(error.InvalidRequest, LaunderMux.abort(
        runtime,
        state,
        .{ .start = {} },
    ));
    try std.testing.expectEqual(
        adapter.FailureSource.invalid_request,
        LaunderMux.lifecycleFailureSource(runtime),
    );
}

fn expectDone(result: upload.Poll(void)) !void {
    try std.testing.expect(result == .done);
}

fn acceptsMuxError(_: Mux.Error) void {}

fn clobberStack() void {
    var bytes: [2048]u8 = @splat(0xa5);
    std.mem.doNotOptimizeAway(&bytes);
}
