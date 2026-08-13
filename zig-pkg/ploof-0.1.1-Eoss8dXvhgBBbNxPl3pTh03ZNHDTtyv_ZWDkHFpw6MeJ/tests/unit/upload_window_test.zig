const std = @import("std");
const upload = @import("../../src/multipart/upload.zig");
const upload_window = @import("../../src/internal/upload/window.zig");

const file = upload.FileHandle.init(7);

const TestSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = void;
    pub const WriteState = struct { completions: u8 = 0 };
    pub const Summary = u64;
    pub const BeginInput = void;
    pub const StartupState = void;
    pub const Runtime = struct {
        behavior: Behavior = .asynchronous,
        starts: u16 = 0,
        completions: u16 = 0,
        delivered: u32 = 0,
    };
    pub const Behavior = enum {
        synchronous,
        asynchronous,
        reject_start,
        reject_completion,
        invalid_request_start,
        sink_invalid_request_start,
        invalid_request_completion,
        sink_invalid_request_completion,
        continue_after_completion,
    };
    pub const Error = error{ Rejected, InvalidRequest };
    pub const io_requirements = upload.IoRequirements{ .write = true };
    pub const request_handles_max: u8 = 1;
    pub const runtime_handles_max: u8 = 0;
    pub const initial_state: State = {};
    pub const initial_write_state: WriteState = .{};
    pub const initial_startup_state: StartupState = {};

    pub fn runtimeStart(
        _: *StartupState,
        event: upload.PollEvent(upload.RuntimeStartInput),
    ) Error!upload.Poll(Runtime) {
        return switch (event) {
            .start => .{ .done = .{} },
            .completion => error.Rejected,
        };
    }

    pub fn runtimeStop(_: *Runtime, event: upload.PollEvent(void)) Error!upload.Poll(void) {
        return lifecycle(event);
    }

    pub fn begin(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(BeginInput),
    ) Error!upload.Poll(void) {
        return lifecycle(event);
    }

    pub fn write(
        runtime: *Runtime,
        _: *State,
        state: *WriteState,
        event: upload.PollEvent(upload.WriteInput),
    ) Error!upload.Poll(void) {
        return switch (event) {
            .start => |input| startWrite(runtime, input),
            .completion => |completion| completeWrite(runtime, state, completion),
        };
    }

    pub fn finish(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(upload.FinishInput),
    ) Error!upload.Poll(Summary) {
        return switch (event) {
            .start => |input| .{ .done = input.bytes },
            .completion => error.Rejected,
        };
    }

    pub fn commit(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return lifecycle(event);
    }

    pub fn abort(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return lifecycle(event);
    }

    fn startWrite(runtime: *Runtime, input: upload.WriteInput) Error!upload.Poll(void) {
        runtime.starts += 1;
        return switch (runtime.behavior) {
            .synchronous => .{ .done = {} },
            .reject_start => error.Rejected,
            .sink_invalid_request_start => error.InvalidRequest,
            .invalid_request_start => .{ .request = .{ .write = .{
                .file = file,
                .bytes = "",
                .offset = input.offset,
            } } },
            else => .{ .request = .{ .write = .{
                .file = file,
                .bytes = input.bytes,
                .offset = input.offset,
            } } },
        };
    }

    fn completeWrite(
        runtime: *Runtime,
        state: *WriteState,
        completion: upload.IoCompletion,
    ) Error!upload.Poll(void) {
        runtime.completions += 1;
        state.completions += 1;
        if (runtime.behavior == .reject_completion) return error.Rejected;
        if (runtime.behavior == .sink_invalid_request_completion) {
            return error.InvalidRequest;
        }
        if (runtime.behavior == .invalid_request_completion) {
            return .{ .request = .{ .write = .{
                .file = file,
                .bytes = "",
                .offset = 0,
            } } };
        }
        if (completion == .success and completion.success == .write) {
            runtime.delivered = completion.success.write;
        }
        if (runtime.behavior == .continue_after_completion and state.completions == 1) {
            return .{ .request = .{ .write = .{
                .file = file,
                .bytes = "x",
                .offset = 99,
            } } };
        }
        return .{ .done = {} };
    }

    fn lifecycle(event: anytype) Error!upload.Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.Rejected,
        };
    }
};

const SynchronousSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = TestSink.State;
    pub const WriteState = TestSink.WriteState;
    pub const Summary = TestSink.Summary;
    pub const BeginInput = TestSink.BeginInput;
    pub const StartupState = TestSink.StartupState;
    pub const Runtime = TestSink.Runtime;
    pub const Error = TestSink.Error;
    pub const io_requirements = upload.IoRequirements.none;
    pub const request_handles_max = TestSink.request_handles_max;
    pub const runtime_handles_max = TestSink.runtime_handles_max;
    pub const initial_state = TestSink.initial_state;
    pub const initial_write_state = TestSink.initial_write_state;
    pub const initial_startup_state = TestSink.initial_startup_state;
    pub const runtimeStart = TestSink.runtimeStart;
    pub const runtimeStop = TestSink.runtimeStop;
    pub const begin = TestSink.begin;
    pub const write = TestSink.write;
    pub const finish = TestSink.finish;
    pub const commit = TestSink.commit;
    pub const abort = TestSink.abort;
};

test "synchronous window borrows chunks without embedding byte buffers" {
    const Extreme = upload_window.Window(
        SynchronousSink,
        upload.upload_chunk_bytes_hard_max,
        upload.upload_window_hard_max,
    );
    const Slots = @FieldType(Extreme, "slots");
    const Slot = @typeInfo(Slots).array.child;
    comptime {
        std.debug.assert(@typeInfo(@FieldType(Slot, "bytes")).array.len == 0);
        std.debug.assert(@sizeOf(Extreme) < upload.upload_chunk_bytes_hard_max);
    }

    const Window = upload_window.Window(SynchronousSink, 2, 16);
    var window = Window{};
    var runtime = SynchronousSink.Runtime{ .behavior = .synchronous };
    var state = SynchronousSink.initial_state;
    const result = try window.push(&runtime, &state, "abcde", 7);
    try std.testing.expectEqual(@as(usize, 5), result.consumed);
    try std.testing.expect(result.submission == null);
    try std.testing.expectEqual(@as(u16, 3), runtime.starts);
    try std.testing.expect(window.quiescent());
}

test "full window consumes a bounded prefix and reuses the lowest slot" {
    const Window = upload_window.Window(TestSink, 4, 2);
    var window = Window{};
    var runtime = TestSink.Runtime{};
    var state = TestSink.initial_state;

    const first = try window.push(&runtime, &state, "abcdefghij", 20);
    try expectSubmission(first, 4, 0, "abcd", 20);
    const second = try window.push(&runtime, &state, "efghij", 24);
    try expectSubmission(second, 4, 1, "efgh", 24);
    const full = try window.push(&runtime, &state, "ij", 28);
    try std.testing.expectEqual(@as(usize, 0), full.consumed);
    try std.testing.expect(full.submission == null);
    try std.testing.expectEqual(@as(u16, 0b11), window.occupied_mask);
    try std.testing.expectEqual(@as(u4, 0), window.lowestPending().?);

    _ = (try window.complete(&runtime, &state, 1, writeSuccess(4))).done;
    const reused = try window.push(&runtime, &state, "ij", 28);
    try expectSubmission(reused, 2, 1, "ij", 28);
    _ = (try window.complete(&runtime, &state, 1, writeSuccess(2))).done;
    _ = (try window.complete(&runtime, &state, 0, writeSuccess(4))).done;
    try std.testing.expect(window.quiescent());
}

test "synchronous writes release immediately and consume all input" {
    const Window = upload_window.Window(TestSink, 3, 1);
    var window = Window{};
    var runtime = TestSink.Runtime{ .behavior = .synchronous };
    var state = TestSink.initial_state;

    const result = try window.push(&runtime, &state, "abcdefgh", 40);
    try std.testing.expectEqual(@as(usize, 8), result.consumed);
    try std.testing.expect(result.submission == null);
    try std.testing.expectEqual(@as(u16, 3), runtime.starts);
    try std.testing.expectEqual(@as(u16, 0), window.occupied_mask);
    try std.testing.expect(window.quiescent());
}

test "asynchronous request borrows the stable copied slot" {
    const Window = upload_window.Window(TestSink, 4, 1);
    var window = Window{};
    var runtime = TestSink.Runtime{};
    var state = TestSink.initial_state;
    var input = [_]u8{ 'a', 'b', 'c', 'd' };

    const result = try window.push(&runtime, &state, &input, 11);
    input = [_]u8{ 'w', 'x', 'y', 'z' };
    const request = result.submission.?.request.write;
    try std.testing.expectEqualStrings("abcd", request.bytes);
    try std.testing.expect(request.bytes.ptr != input[0..].ptr);
    try std.testing.expectEqualStrings(
        "abcd",
        window.pendingRequest(0).?.write.bytes,
    );
    _ = (try window.complete(&runtime, &state, 0, writeSuccess(4))).done;
}

test "short writes retry from the owned bytes without sink reentry" {
    const Window = upload_window.Window(TestSink, 4, 1);
    var window = Window{};
    var runtime = TestSink.Runtime{};
    var state = TestSink.initial_state;
    _ = try window.push(&runtime, &state, "abcd", 7);

    const retry = try window.complete(&runtime, &state, 0, writeSuccess(2));
    try std.testing.expectEqualStrings("cd", retry.request.write.bytes);
    try std.testing.expectEqual(@as(u64, 9), retry.request.write.offset);
    try std.testing.expectEqual(@as(u16, 0), runtime.completions);
    try std.testing.expectEqual(@as(u16, 1), window.pending_mask);

    _ = (try window.complete(&runtime, &state, 0, writeSuccess(2))).done;
    try std.testing.expectEqual(@as(u16, 1), runtime.completions);
    try std.testing.expectEqual(@as(u32, 4), runtime.delivered);
    try std.testing.expect(window.quiescent());
}

test "slots complete out of order while traversal remains deterministic" {
    const Window = upload_window.Window(TestSink, 2, 3);
    var window = Window{};
    var runtime = TestSink.Runtime{};
    var state = TestSink.initial_state;

    inline for (.{ "ab", "cd", "ef" }, 0..) |bytes, index| {
        const result = try window.push(&runtime, &state, bytes, index * 2);
        try std.testing.expectEqual(@as(u4, @intCast(index)), result.submission.?.slot);
    }
    _ = (try window.complete(&runtime, &state, 2, writeSuccess(2))).done;
    try std.testing.expectEqual(@as(u4, 0), window.lowestPending().?);
    _ = (try window.complete(&runtime, &state, 0, writeSuccess(2))).done;
    try std.testing.expectEqual(@as(u4, 1), window.lowestPending().?);
    _ = (try window.complete(&runtime, &state, 1, writeSuccess(2))).done;
    try std.testing.expect(window.lowestPending() == null);
}

test "sink and completion failures latch and block intake" {
    const Window = upload_window.Window(TestSink, 4, 2);
    var state = TestSink.initial_state;

    var start_window = Window{};
    var start_runtime = TestSink.Runtime{ .behavior = .reject_start };
    try std.testing.expectError(
        error.Rejected,
        start_window.push(&start_runtime, &state, "abcd", 0),
    );
    try expectFailedWindow(&start_window, &start_runtime, &state);

    var completion_window = Window{};
    var completion_runtime = TestSink.Runtime{};
    _ = try completion_window.push(&completion_runtime, &state, "abcd", 0);
    completion_runtime.behavior = .reject_completion;
    try std.testing.expectError(
        error.Rejected,
        completion_window.complete(&completion_runtime, &state, 0, writeSuccess(4)),
    );
    try std.testing.expect(completion_window.quiescent());
    try expectFailedWindow(&completion_window, &completion_runtime, &state);
}

test "invalid generated request poisons while same-named sink error remains recoverable" {
    const Window = upload_window.Window(TestSink, 4, 1);
    var state = TestSink.initial_state;

    var invalid_window = Window{};
    var invalid_runtime = TestSink.Runtime{ .behavior = .invalid_request_start };
    try std.testing.expectError(
        error.InvalidRequest,
        invalid_window.push(&invalid_runtime, &state, "abcd", 0),
    );
    try std.testing.expectEqual(upload_window.Mode.poisoned, invalid_window.mode);
    try std.testing.expect(invalid_window.quiescent());
    try std.testing.expectError(error.Poisoned, invalid_window.reset());

    var sink_window = Window{};
    var sink_runtime = TestSink.Runtime{ .behavior = .sink_invalid_request_start };
    try std.testing.expectError(
        error.InvalidRequest,
        sink_window.push(&sink_runtime, &state, "abcd", 0),
    );
    try std.testing.expectEqual(upload_window.Mode.failed, sink_window.mode);
    try std.testing.expect(sink_window.quiescent());
    try sink_window.reset();
    try std.testing.expectEqual(upload_window.Mode.accepting, sink_window.mode);
}

test "completion request provenance controls whether window can reset" {
    const Window = upload_window.Window(TestSink, 4, 1);
    var state = TestSink.initial_state;

    var invalid_window = Window{};
    var invalid_runtime = TestSink.Runtime{ .behavior = .invalid_request_completion };
    _ = try invalid_window.push(&invalid_runtime, &state, "abcd", 0);
    try std.testing.expectError(
        error.InvalidRequest,
        invalid_window.complete(&invalid_runtime, &state, 0, writeSuccess(4)),
    );
    try std.testing.expectEqual(upload_window.Mode.poisoned, invalid_window.mode);
    try std.testing.expect(invalid_window.quiescent());
    try std.testing.expectError(error.Poisoned, invalid_window.reset());

    var sink_window = Window{};
    var sink_runtime = TestSink.Runtime{ .behavior = .sink_invalid_request_completion };
    _ = try sink_window.push(&sink_runtime, &state, "abcd", 0);
    try std.testing.expectError(
        error.InvalidRequest,
        sink_window.complete(&sink_runtime, &state, 0, writeSuccess(4)),
    );
    try std.testing.expectEqual(upload_window.Mode.failed, sink_window.mode);
    try std.testing.expect(sink_window.quiescent());
    try sink_window.reset();
}

test "failed window still reaps every already-pending slot" {
    const Window = upload_window.Window(TestSink, 4, 2);
    var window = Window{};
    var runtime = TestSink.Runtime{};
    var state = TestSink.initial_state;
    _ = try window.push(&runtime, &state, "abcd", 0);
    _ = try window.push(&runtime, &state, "efgh", 4);

    runtime.behavior = .reject_completion;
    try std.testing.expectError(
        error.Rejected,
        window.complete(&runtime, &state, 0, writeSuccess(4)),
    );
    try std.testing.expectEqual(@as(u16, 0b10), window.pending_mask);
    runtime.behavior = .asynchronous;
    _ = (try window.complete(&runtime, &state, 1, writeSuccess(4))).done;
    try std.testing.expect(window.quiescent());
    try expectFailedWindow(&window, &runtime, &state);
}

test "offset overflow fails before borrowed bytes reach the sink" {
    const Window = upload_window.Window(TestSink, 4, 1);
    var window = Window{};
    var runtime = TestSink.Runtime{ .behavior = .synchronous };
    var state = TestSink.initial_state;

    try std.testing.expectError(
        error.OffsetOverflow,
        window.push(&runtime, &state, "x", std.math.maxInt(u64)),
    );
    try std.testing.expectEqual(@as(u16, 0), runtime.starts);
    try std.testing.expect(window.quiescent());
    try std.testing.expectEqual(upload_window.Mode.poisoned, window.mode);
    try std.testing.expectError(error.Poisoned, window.reset());
}

test "malformed completion quarantines occupied storage" {
    const Window = upload_window.Window(TestSink, 4, 1);
    var window = Window{};
    var runtime = TestSink.Runtime{};
    var state = TestSink.initial_state;
    _ = try window.push(&runtime, &state, "abcd", 0);

    try std.testing.expectError(
        error.CompletionKindMismatch,
        window.complete(&runtime, &state, 0, .{ .success = .{ .sync = {} } }),
    );
    try std.testing.expectEqual(upload_window.Mode.poisoned, window.mode);
    try std.testing.expectEqual(@as(u16, 1), window.occupied_mask);
    try std.testing.expectEqual(@as(u16, 0), window.pending_mask);
    try std.testing.expect(!window.quiescent());
    try std.testing.expect(window.lowestPending() == null);
    try std.testing.expectError(error.Poisoned, window.reset());
}

test "drain and cancel block intake until a quiescent reset" {
    const Window = upload_window.Window(TestSink, 4, 1);
    var window = Window{};
    var runtime = TestSink.Runtime{};
    var state = TestSink.initial_state;
    _ = try window.push(&runtime, &state, "abcd", 0);
    try window.drain();
    try std.testing.expectError(error.Draining, window.push(&runtime, &state, "x", 4));
    _ = (try window.complete(&runtime, &state, 0, writeSuccess(4))).done;
    try window.reset();

    _ = try window.push(&runtime, &state, "wxyz", 4);
    window.cancel();
    try std.testing.expectError(error.Canceled, window.push(&runtime, &state, "x", 8));
    _ = (try window.complete(&runtime, &state, 0, writeSuccess(4))).done;
    try std.testing.expect(window.quiescent());
    try window.reset();
    try std.testing.expectEqual(upload_window.Mode.accepting, window.mode);
}

test "cancel retains sink continuation until it is drained" {
    const Window = upload_window.Window(TestSink, 4, 1);
    var window = Window{};
    var runtime = TestSink.Runtime{ .behavior = .continue_after_completion };
    var state = TestSink.initial_state;
    _ = try window.push(&runtime, &state, "abcd", 0);
    window.cancel();

    const continuation = try window.complete(&runtime, &state, 0, writeSuccess(4));
    try std.testing.expectEqualStrings("x", continuation.request.write.bytes);
    try std.testing.expect(!window.quiescent());
    try std.testing.expectEqualStrings("x", window.pendingRequest(0).?.write.bytes);
    _ = (try window.complete(
        &runtime,
        &state,
        0,
        .{ .failure = .canceled },
    )).done;
    try std.testing.expect(window.quiescent());
    try std.testing.expectEqual(upload_window.Mode.canceled, window.mode);
}

test "normalized canceled completion retains sink continuation" {
    const Window = upload_window.Window(TestSink, 4, 1);
    var window = Window{};
    var runtime = TestSink.Runtime{ .behavior = .continue_after_completion };
    var state = TestSink.initial_state;
    _ = try window.push(&runtime, &state, "abcd", 0);

    const continuation = try window.complete(
        &runtime,
        &state,
        0,
        .{ .failure = .canceled },
    );
    try std.testing.expectEqualStrings("x", continuation.request.write.bytes);
    try std.testing.expect(!window.quiescent());
    _ = (try window.complete(
        &runtime,
        &state,
        0,
        .{ .failure = .canceled },
    )).done;
    try std.testing.expect(window.quiescent());
    try std.testing.expectEqual(upload_window.Mode.canceled, window.mode);
    try std.testing.expectError(error.Canceled, window.push(&runtime, &state, "x", 4));
}

test "requested cancellation drains sink error without hiding spontaneous cancellation" {
    const Window = upload_window.Window(TestSink, 4, 1);
    var state = TestSink.initial_state;

    var requested = Window{};
    var requested_runtime = TestSink.Runtime{ .behavior = .reject_completion };
    _ = try requested.push(&requested_runtime, &state, "abcd", 0);
    _ = (try requested.completeCanceled(&requested_runtime, &state, 0)).done;
    try std.testing.expect(requested.quiescent());
    try std.testing.expectEqual(upload_window.Mode.canceled, requested.mode);

    var spontaneous = Window{};
    var spontaneous_runtime = TestSink.Runtime{ .behavior = .reject_completion };
    _ = try spontaneous.push(&spontaneous_runtime, &state, "abcd", 0);
    try std.testing.expectError(
        error.Rejected,
        spontaneous.complete(
            &spontaneous_runtime,
            &state,
            0,
            .{ .failure = .canceled },
        ),
    );
    try std.testing.expectEqual(upload_window.Mode.failed, spontaneous.mode);
}

test "completion must identify an exact pending slot" {
    const Window = upload_window.Window(TestSink, 4, 2);
    var window = Window{};
    var runtime = TestSink.Runtime{};
    var state = TestSink.initial_state;
    _ = try window.push(&runtime, &state, "abcd", 0);

    try std.testing.expectError(
        error.NoPending,
        window.complete(&runtime, &state, 1, writeSuccess(4)),
    );
    try std.testing.expectEqual(upload_window.Mode.poisoned, window.mode);
    try std.testing.expectEqual(@as(u16, 1), window.pending_mask);
    _ = (try window.complete(&runtime, &state, 0, writeSuccess(4))).done;
    try std.testing.expect(window.quiescent());
    try std.testing.expectError(error.Poisoned, window.reset());
    try std.testing.expectError(error.Poisoned, window.push(&runtime, &state, "x", 4));
}

test "hard-cap configuration has fixed storage and no allocator" {
    const Window = upload_window.Window(
        TestSink,
        upload_window.chunk_bytes_hard_max,
        upload_window.window_hard_max,
    );
    try std.testing.expect(@sizeOf(Window) >= 16 * 1024 * 1024);
}

fn expectSubmission(
    result: anytype,
    consumed: usize,
    slot: u4,
    bytes: []const u8,
    offset: u64,
) !void {
    try std.testing.expectEqual(consumed, result.consumed);
    const submission = result.submission.?;
    try std.testing.expectEqual(slot, submission.slot);
    try std.testing.expectEqualStrings(bytes, submission.request.write.bytes);
    try std.testing.expectEqual(offset, submission.request.write.offset);
}

fn expectFailedWindow(window: anytype, runtime: anytype, state: anytype) !void {
    try std.testing.expectEqual(upload_window.Mode.failed, window.mode);
    try std.testing.expectError(error.Failed, window.push(runtime, state, "x", 0));
}

fn writeSuccess(bytes: u32) upload.IoCompletion {
    return .{ .success = .{ .write = bytes } };
}
