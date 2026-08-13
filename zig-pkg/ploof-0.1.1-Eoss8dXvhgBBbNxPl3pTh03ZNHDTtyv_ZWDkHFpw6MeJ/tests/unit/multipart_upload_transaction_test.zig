const std = @import("std");
const multipart = @import("../../src/multipart.zig");
const upload = @import("../../src/multipart/upload.zig");
const events = @import("../../src/internal/multipart/events.zig");
const parser = @import("../../src/internal/multipart/parser.zig");
const upload_finalizer = @import("../../src/internal/upload/finalizer.zig");
const transaction = @import("../../src/internal/multipart/upload_transaction.zig");

pub const Operation = enum(u8) { begin, write, finish, commit, abort };

pub const TraceEntry = struct {
    operation: Operation,
    sink: u8,
    serial: u16,
};

pub const Harness = struct {
    trace: [128]TraceEntry = undefined,
    trace_len: usize = 0,
    next_serial: u16 = 1,

    fn append(self: *Harness, operation: Operation, sink: u8, serial: u16) void {
        self.trace[self.trace_len] = .{
            .operation = operation,
            .sink = sink,
            .serial = serial,
        };
        self.trace_len += 1;
    }
};

pub const Behavior = struct {
    begin_async: bool = false,
    finish_async: bool = false,
    commit_async: bool = false,
    abort_async: bool = false,
    write_async: bool = false,
    write_continue: bool = false,
    invalid_write_request: bool = false,
    reject: ?Operation = null,
    reject_serial: u16 = 0,
    collision: ?Operation = null,
};

fn TestSink(comptime sink_id: u8) type {
    return struct {
        const Self = @This();

        pub const ploof_multipart_sink = true;
        pub const State = struct {
            serial: u16 = 0,
            bytes: u64 = 0,
        };
        pub const WriteState = struct { completions: u8 = 0 };
        pub const Summary = struct { bytes: u64, sink: u8 };
        pub const BeginInput = u32;
        pub const Runtime = struct {
            harness: *Harness,
            behavior: Behavior = .{},
        };
        pub const StartupState = void;
        pub const Error = error{ Rejected, TransactionFatal };
        pub const io_requirements = upload.IoRequirements{
            .write = true,
            .sync = true,
        };
        pub const request_handles_max: u8 = 1;
        pub const runtime_handles_max: u8 = 0;
        pub const initial_state: State = .{};
        pub const initial_write_state: WriteState = .{};
        pub const initial_startup_state: StartupState = {};

        pub fn runtimeStart(
            _: *StartupState,
            event: upload.PollEvent(upload.RuntimeStartInput),
        ) Error!upload.Poll(Runtime) {
            _ = event;
            return error.Rejected;
        }

        pub fn runtimeStop(
            _: *Runtime,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            return synchronous(event);
        }

        pub fn begin(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(BeginInput),
        ) Error!upload.Poll(void) {
            return switch (event) {
                .start => |input| start: {
                    _ = input;
                    if (runtime.behavior.collision == .begin) {
                        return error.TransactionFatal;
                    }
                    if (runtime.behavior.reject == .begin) return error.Rejected;
                    state.serial = runtime.harness.next_serial;
                    runtime.harness.next_serial += 1;
                    runtime.harness.append(.begin, sink_id, state.serial);
                    break :start requestOrDone(runtime.behavior.begin_async);
                },
                .completion => |completion| completeVoid(completion),
            };
        }

        pub fn write(
            runtime: *Runtime,
            state: *State,
            write_state: *WriteState,
            event: upload.PollEvent(upload.WriteInput),
        ) Error!upload.Poll(void) {
            return switch (event) {
                .start => |input| start: {
                    if (runtime.behavior.collision == .write) {
                        return error.TransactionFatal;
                    }
                    if (rejects(runtime, .write, state.serial)) return error.Rejected;
                    state.bytes += input.bytes.len;
                    runtime.harness.append(.write, sink_id, state.serial);
                    if (runtime.behavior.invalid_write_request) {
                        break :start .{ .request = .{ .write = .{
                            .file = upload.FileHandle.init(sink_id),
                            .bytes = "",
                            .offset = input.offset,
                        } } };
                    }
                    if (!runtime.behavior.write_async) break :start .{ .done = {} };
                    break :start .{ .request = .{ .write = .{
                        .file = upload.FileHandle.init(sink_id),
                        .bytes = input.bytes,
                        .offset = input.offset,
                    } } };
                },
                .completion => |completion| complete: {
                    if (rejects(runtime, .write, state.serial)) return error.Rejected;
                    if (runtime.behavior.write_continue and write_state.completions == 0) {
                        write_state.completions += 1;
                        break :complete .{ .request = .{ .sync = .{
                            .file = upload.FileHandle.init(sink_id),
                        } } };
                    }
                    if (completion == .failure and completion.failure == .canceled) {
                        break :complete .{ .done = {} };
                    }
                    _ = try expectSuccess(completion);
                    break :complete .{ .done = {} };
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
                    if (runtime.behavior.collision == .finish) {
                        return error.TransactionFatal;
                    }
                    if (rejects(runtime, .finish, state.serial)) return error.Rejected;
                    if (input.bytes != state.bytes) return error.Rejected;
                    runtime.harness.append(.finish, sink_id, state.serial);
                    if (runtime.behavior.finish_async) {
                        break :start .{ .request = syncRequest() };
                    }
                    break :start .{ .done = summary(state) };
                },
                .completion => |completion| complete: {
                    _ = try expectSuccess(completion);
                    break :complete .{ .done = summary(state) };
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
                    if (rejects(runtime, operation, state.serial)) return error.Rejected;
                    runtime.harness.append(operation, sink_id, state.serial);
                    const asynchronous = if (operation == .commit)
                        runtime.behavior.commit_async
                    else
                        runtime.behavior.abort_async;
                    break :start requestOrDone(asynchronous);
                },
                .completion => |completion| completeVoid(completion),
            };
        }

        fn summary(state: *const State) Summary {
            return .{ .bytes = state.bytes, .sink = sink_id };
        }

        fn rejects(runtime: *const Runtime, operation: Operation, serial: u16) bool {
            return runtime.behavior.reject == operation and
                (runtime.behavior.reject_serial == 0 or
                    runtime.behavior.reject_serial == serial);
        }

        fn synchronous(event: upload.PollEvent(void)) Error!upload.Poll(void) {
            return switch (event) {
                .start => .{ .done = {} },
                .completion => |completion| completeVoid(completion),
            };
        }

        fn requestOrDone(asynchronous: bool) upload.Poll(void) {
            return if (asynchronous)
                .{ .request = syncRequest() }
            else
                .{ .done = {} };
        }

        fn syncRequest() upload.IoRequest {
            return .{ .sync = .{ .file = upload.FileHandle.init(sink_id) } };
        }

        fn completeVoid(completion: upload.IoCompletion) Error!upload.Poll(void) {
            _ = try expectSuccess(completion);
            return .{ .done = {} };
        }

        fn expectSuccess(completion: upload.IoCompletion) Error!upload.IoSuccess {
            return switch (completion) {
                .success => |success| success,
                .failure => error.Rejected,
            };
        }
    };
}

pub const Alpha = TestSink(1);
pub const Beta = TestSink(2);
pub const Synchronous = struct {
    pub const ploof_multipart_sink = true;
    pub const State = multipart.DiscardSink.State;
    pub const WriteState = multipart.DiscardSink.WriteState;
    pub const Summary = multipart.DiscardSink.Summary;
    pub const BeginInput = multipart.DiscardSink.BeginInput;
    pub const Runtime = multipart.DiscardSink.Runtime;
    pub const StartupState = multipart.DiscardSink.StartupState;
    pub const io_requirements = multipart.DiscardSink.io_requirements;
    pub const request_handles_max = multipart.DiscardSink.request_handles_max;
    pub const runtime_handles_max = multipart.DiscardSink.runtime_handles_max;
    pub const Error = multipart.DiscardSink.Error;
    pub const initial_state = multipart.DiscardSink.initial_state;
    pub const initial_write_state = multipart.DiscardSink.initial_write_state;
    pub const initial_startup_state = multipart.DiscardSink.initial_startup_state;
    pub const runtimeStart = multipart.DiscardSink.runtimeStart;
    pub const runtimeStop = multipart.DiscardSink.runtimeStop;
    pub const begin = multipart.DiscardSink.begin;
    pub const write = multipart.DiscardSink.write;
    pub const finish = multipart.DiscardSink.finish;
    pub const commit = multipart.DiscardSink.commit;
    pub const abort = multipart.DiscardSink.abort;
};
pub const spec = multipart.decode(.{
    .alpha = multipart.file(Alpha, multipart.oneTo(2)),
    .gap = multipart.field(u8, multipart.optional),
    .beta = multipart.file(Beta, multipart.oneTo(2)),
    .discard = multipart.file(multipart.DiscardSink, multipart.optional),
}, .{
    .limits = .{ .parts_max = 6, .files_max = 5 },
    .upload = .{ .window = 2, .chunk_bytes = 4 },
});
pub const Spec = @TypeOf(spec);

pub const Registry = struct {
    alpha: Alpha.Runtime,
    beta: Beta.Runtime,
    discard: multipart.DiscardSink.Runtime = {},

    pub fn init(harness: *Harness) Registry {
        return .{
            .alpha = .{ .harness = harness },
            .beta = .{ .harness = harness },
        };
    }

    pub fn get(self: *@This(), comptime Sink: type) *Sink.Runtime {
        if (Sink == Alpha) return &self.alpha;
        if (Sink == Beta) return &self.beta;
        if (Sink == multipart.DiscardSink) return &self.discard;
        unreachable;
    }
};

pub const Transaction = transaction.Transaction(Spec, Registry);

pub const SizeRegistry = struct {
    synchronous: Synchronous.Runtime = {},
    discard: multipart.DiscardSink.Runtime = {},

    pub fn get(self: *@This(), comptime Sink: type) *Sink.Runtime {
        if (Sink == Synchronous) return &self.synchronous;
        if (Sink == multipart.DiscardSink) return &self.discard;
        unreachable;
    }
};

pub const synchronous_extreme = multipart.decode(.{
    .synchronous = multipart.file(Synchronous, multipart.required),
}, .{ .upload = .{
    .window = upload.upload_window_hard_max,
    .chunk_bytes = upload.upload_chunk_bytes_hard_max,
} });
pub const SynchronousExtremeSpec = @TypeOf(synchronous_extreme);
pub const SynchronousExtreme = transaction.Transaction(SynchronousExtremeSpec, SizeRegistry);

pub const discard_extreme = multipart.decode(.{
    .discard = multipart.file(
        multipart.DiscardSink,
        multipart.oneTo(std.math.maxInt(u16)),
    ),
}, .{
    .limits = .{
        .parts_max = std.math.maxInt(u16),
        .files_max = std.math.maxInt(u16),
    },
    .upload = .{
        .window = upload.upload_window_hard_max,
        .chunk_bytes = upload.upload_chunk_bytes_hard_max,
    },
});
pub const DiscardExtremeSpec = @TypeOf(discard_extreme);
pub const DiscardExtreme = transaction.Transaction(DiscardExtremeSpec, SizeRegistry);

pub const capacity_extreme = multipart.decode(.{
    .synchronous = multipart.file(Synchronous, multipart.required),
    .discard = multipart.file(
        multipart.DiscardSink,
        multipart.zeroTo(std.math.maxInt(u16) - 1),
    ),
}, .{
    .limits = .{
        .parts_max = std.math.maxInt(u16),
        .files_max = std.math.maxInt(u16),
    },
    .upload = .{
        .window = upload.upload_window_hard_max,
        .chunk_bytes = upload.upload_chunk_bytes_hard_max,
    },
});
pub const CapacityExtremeSpec = @TypeOf(capacity_extreme);
pub const CapacityExtreme = transaction.Transaction(CapacityExtremeSpec, SizeRegistry);

pub const async_extreme = multipart.decode(.{
    .alpha = multipart.file(Alpha, multipart.required),
}, .{ .upload = .{
    .window = upload.upload_window_hard_max,
    .chunk_bytes = upload.upload_chunk_bytes_hard_max,
} });
pub const AsyncExtreme = transaction.Transaction(@TypeOf(async_extreme), Registry);

fn embeddedWindowBytes(comptime TransactionType: type) usize {
    const Window = @FieldType(TransactionType, "window");
    const slots = @typeInfo(@FieldType(Window, "slots")).array;
    const bytes = @typeInfo(@FieldType(slots.child, "bytes")).array;
    return slots.len * bytes.len;
}

fn recordCapacity(comptime TransactionType: type) usize {
    return @typeInfo(@FieldType(TransactionType, "records")).array.len;
}

fn finalizerCapacity(comptime TransactionType: type) usize {
    const Finalizer = @FieldType(TransactionType, "finalizer");
    return @typeInfo(@FieldType(Finalizer, "states")).array.len;
}

test "synchronous and discard extremes erase upload buffers and discard records" {
    comptime {
        std.debug.assert(embeddedWindowBytes(SynchronousExtreme) == 0);
        std.debug.assert(embeddedWindowBytes(DiscardExtreme) == 0);
        std.debug.assert(embeddedWindowBytes(CapacityExtreme) == 0);
        std.debug.assert(embeddedWindowBytes(AsyncExtreme) ==
            upload.upload_window_hard_max * upload.upload_chunk_bytes_hard_max);
        std.debug.assert(@sizeOf(SynchronousExtreme) < upload.upload_chunk_bytes_hard_max);
        std.debug.assert(@sizeOf(DiscardExtreme) < upload.upload_chunk_bytes_hard_max);
        std.debug.assert(@sizeOf(CapacityExtreme) < upload.upload_chunk_bytes_hard_max);
        std.debug.assert(recordCapacity(SynchronousExtreme) == 1);
        std.debug.assert(recordCapacity(DiscardExtreme) == 0);
        std.debug.assert(recordCapacity(CapacityExtreme) == 1);
        std.debug.assert(finalizerCapacity(SynchronousExtreme) == 1);
        std.debug.assert(finalizerCapacity(DiscardExtreme) == 0);
        std.debug.assert(finalizerCapacity(CapacityExtreme) == 1);
    }

    var registry = SizeRegistry{};
    var tx = SynchronousExtreme.init(&registry);
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileStartProgress(
        startEvent(0, 1),
        SynchronousExtremeSpec.BeginInput{ .synchronous = {} },
    ));
    const progress = try tx.fileChunkProgress(chunkEvent(0, 1, 0, "direct"));
    try std.testing.expectEqual(@as(usize, 6), progress.consumed);
    try std.testing.expectEqual(parser.CallbackFlow.ready, progress.flow);
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileEndProgress(
        endEvent(0, 1, 6),
    ));
    try std.testing.expectEqual(
        @as(usize, 1),
        (try tx.summaries()).synchronous.slice().len,
    );
}

test "transaction stores one authoritative finalization report" {
    comptime {
        const Finalizer = @FieldType(Transaction, "finalizer");
        const Duplicated = struct {
            transaction: Transaction,
            final_report: ?Transaction.Report,
        };
        std.debug.assert(!@hasField(Transaction, "final_report"));
        std.debug.assert(@FieldType(Finalizer, "report") == Transaction.Report);
        std.debug.assert(@sizeOf(Duplicated) >=
            @sizeOf(Transaction) + @sizeOf(?Transaction.Report));
    }

    var registry = SizeRegistry{};
    var tx = DiscardExtreme.init(&registry);
    try std.testing.expect((try tx.report()) == null);
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileStartProgress(
        startEvent(0, 1),
        DiscardExtremeSpec.BeginInput{ .discard = {} },
    ));
    const progress = try tx.fileChunkProgress(chunkEvent(0, 1, 0, "discard"));
    try std.testing.expectEqual(@as(usize, 7), progress.consumed);
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileEndProgress(
        endEvent(0, 1, 7),
    ));
    try std.testing.expect((try tx.report()) == null);
    try tx.markCommitReady();
    try std.testing.expectEqual(DiscardExtreme.FinalizationFlow.complete, try tx.startCommit());
    const report = (try tx.report()).?;
    try std.testing.expectEqual(upload_finalizer.Outcome.committed, report.outcome);
    try std.testing.expectEqual(@as(u32, 0), report.commit_attempted_count);
    try std.testing.expectEqualDeep(report, (try tx.report()).?);
}

test "transaction instantiates and stores heterogeneous summary" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    var tx = Transaction.init(&registry);

    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileStartProgress(
        startEvent(0, 1),
        .{ .alpha = 7 },
    ));
    try std.testing.expectEqualDeep(
        parser.ChunkProgress{ .consumed = 3, .flow = .ready },
        try tx.fileChunkProgress(chunkEvent(0, 1, 0, "abc")),
    );
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileEndProgress(
        endEvent(0, 1, 3),
    ));
    const summaries = try tx.summaries();
    try std.testing.expectEqual(@as(usize, 1), summaries.alpha.slice().len);
    try std.testing.expectEqual(@as(u64, 3), summaries.alpha.slice()[0].bytes);
    try std.testing.expectEqual(@as(u8, 1), summaries.alpha.slice()[0].sink);
}

pub fn startEvent(entry_index: u16, occurrence: u16) events.FileStart {
    return .{
        .entry_index = entry_index,
        .occurrence = occurrence,
        .metadata = undefined,
    };
}

pub fn synchronousFile(
    tx: *Transaction,
    entry_index: u16,
    occurrence: u16,
    begin_input: Spec.BeginInput,
    bytes: []const u8,
) !void {
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileStartProgress(
        startEvent(entry_index, occurrence),
        begin_input,
    ));
    try synchronousBodyAndEnd(tx, entry_index, occurrence, bytes);
}

pub fn expectSinkCollision(operation: Operation) !void {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    registry.alpha.behavior.collision = operation;
    var tx = Transaction.init(&registry);
    var sink_error: ?Transaction.Error = null;

    switch (operation) {
        .begin => if (tx.fileStartProgress(startEvent(0, 1), .{ .alpha = 1 })) |_| {
            return error.ExpectedSinkFailure;
        } else |problem| {
            sink_error = problem;
        },
        .write => {
            _ = try tx.fileStartProgress(startEvent(0, 1), .{ .alpha = 1 });
            if (tx.fileChunkProgress(chunkEvent(0, 1, 0, "x"))) |_| {
                return error.ExpectedSinkFailure;
            } else |problem| {
                sink_error = problem;
            }
        },
        .finish => {
            _ = try tx.fileStartProgress(startEvent(0, 1), .{ .alpha = 1 });
            _ = try tx.fileChunkProgress(chunkEvent(0, 1, 0, "x"));
            if (tx.fileEndProgress(endEvent(0, 1, 1))) |_| {
                return error.ExpectedSinkFailure;
            } else |problem| {
                sink_error = problem;
            }
        },
        .commit, .abort => unreachable,
    }

    try std.testing.expect(sink_error.? == error.TransactionFatal);
    try std.testing.expectEqual(
        Transaction.FailureKind.sink,
        tx.failureKind(sink_error.?),
    );
    try std.testing.expect(tx.fatal() == null);
    try std.testing.expectEqual(
        Transaction.FinalizationFlow.complete,
        try tx.startAbort(null),
    );
    const report = (try tx.report()).?;
    try std.testing.expectEqual(upload_finalizer.Outcome.failed, report.outcome);
    try std.testing.expect(report.primary.?.class == .sink);
    try std.testing.expectEqual(@as(?usize, 0), report.primary.?.entry_index);
}

pub fn synchronousBodyAndEnd(
    tx: *Transaction,
    entry_index: u16,
    occurrence: u16,
    bytes: []const u8,
) !void {
    const progress = try tx.fileChunkProgress(chunkEvent(
        entry_index,
        occurrence,
        0,
        bytes,
    ));
    try std.testing.expectEqual(bytes.len, progress.consumed);
    try std.testing.expectEqual(parser.CallbackFlow.ready, progress.flow);
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileEndProgress(
        endEvent(entry_index, occurrence, bytes.len),
    ));
}

pub fn submitPending(tx: *Transaction) !Transaction.Submission {
    const pending = (try tx.peekSubmission()) orelse return error.MissingSubmission;
    try tx.markSubmitted(pending.lane);
    return pending;
}

pub fn expectLifecycle(lane: Transaction.Lane) !void {
    try std.testing.expect(lane == .lifecycle);
}

pub fn expectWrite(
    submission: Transaction.Submission,
    slot: u4,
    bytes: []const u8,
    offset: u64,
) !void {
    switch (submission.lane) {
        .write => |actual| try std.testing.expectEqual(slot, actual),
        .lifecycle => return error.ExpectedWriteLane,
    }
    try std.testing.expect(submission.request == .write);
    try std.testing.expectEqualStrings(bytes, submission.request.write.bytes);
    try std.testing.expectEqual(offset, submission.request.write.offset);
}

pub fn expectSyncWriteLane(submission: Transaction.Submission, slot: u4) !void {
    switch (submission.lane) {
        .write => |actual| try std.testing.expectEqual(slot, actual),
        .lifecycle => return error.ExpectedWriteLane,
    }
    try std.testing.expect(submission.request == .sync);
}

pub fn expectFatal(
    tx: *Transaction,
    class: Transaction.FatalClass,
    entry_index: ?u16,
) !void {
    const value = tx.fatal() orelse return error.MissingFatal;
    try std.testing.expectEqual(class, value.class);
    try std.testing.expectEqual(entry_index, value.entry_index);
}

pub fn traceCount(harness: *const Harness, operation: Operation) usize {
    var count: usize = 0;
    for (harness.trace[0..harness.trace_len]) |entry| {
        count += @intFromBool(entry.operation == operation);
    }
    return count;
}

pub fn filterTrace(
    harness: *const Harness,
    operation: Operation,
    output: []TraceEntry,
) []const TraceEntry {
    var length: usize = 0;
    for (harness.trace[0..harness.trace_len]) |entry| {
        if (entry.operation != operation) continue;
        output[length] = entry;
        length += 1;
    }
    return output[0..length];
}

pub fn chunkEvent(
    entry_index: u16,
    occurrence: u16,
    offset: u64,
    bytes: []const u8,
) events.FileChunk {
    return .{
        .entry_index = entry_index,
        .occurrence = occurrence,
        .offset = offset,
        .bytes = bytes,
    };
}

pub fn endEvent(entry_index: u16, occurrence: u16, bytes: u64) events.FileEnd {
    return .{
        .entry_index = entry_index,
        .occurrence = occurrence,
        .bytes = bytes,
    };
}

pub fn writeSuccess(bytes: u32) upload.IoCompletion {
    return .{ .success = .{ .write = bytes } };
}

pub fn syncSuccess() upload.IoCompletion {
    return .{ .success = .{ .sync = {} } };
}

pub fn upstreamFailure() upload_finalizer.UpstreamFailure {
    return .body;
}
