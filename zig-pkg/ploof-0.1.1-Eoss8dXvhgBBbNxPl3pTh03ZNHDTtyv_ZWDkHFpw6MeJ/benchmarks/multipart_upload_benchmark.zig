const std = @import("std");
const sigbench = @import("sigbench");
const multipart = @import("../src/multipart.zig");
const file_sink_benchmark = @import("multipart_file_sink_benchmark.zig");
const upload = @import("../src/multipart/upload.zig");
const events = @import("../src/internal/multipart/events.zig");
const parser = @import("../src/internal/multipart/parser.zig");
const transaction = @import("../src/internal/multipart/upload_transaction.zig");
const upload_finalizer = @import("../src/internal/upload/finalizer.zig");

const chunk_bytes = 4 * 1024;
const window = 4;
const payload = [_]u8{0xa5} ** (chunk_bytes * window);

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof upload benchmark validity check failed");
}

const BenchSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = struct { bytes: u64 = 0 };
    pub const WriteState = void;
    pub const Summary = u64;
    pub const BeginInput = void;
    pub const Runtime = struct {
        begins: u32 = 0,
        writes: u32 = 0,
        finishes: u32 = 0,
        commits: u32 = 0,
        aborts: u32 = 0,
    };
    pub const StartupState = void;
    pub const Error = error{ InvalidBytes, IoFailure, UnexpectedCompletion };
    pub const io_requirements = upload.IoRequirements{ .write = true };
    pub const request_handles_max: u8 = 1;
    pub const runtime_handles_max: u8 = 0;
    pub const initial_state = State{};
    pub const initial_write_state: WriteState = {};
    pub const initial_startup_state: StartupState = {};

    pub fn runtimeStart(
        _: *StartupState,
        event: upload.PollEvent(upload.RuntimeStartInput),
    ) Error!upload.Poll(Runtime) {
        return switch (event) {
            .start => .{ .done = .{} },
            .completion => error.UnexpectedCompletion,
        };
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
            .start => {
                runtime.begins += 1;
                state.* = .{};
                return .{ .done = {} };
            },
            .completion => error.UnexpectedCompletion,
        };
    }

    pub fn write(
        runtime: *Runtime,
        state: *State,
        _: *WriteState,
        event: upload.PollEvent(upload.WriteInput),
    ) Error!upload.Poll(void) {
        return switch (event) {
            .start => |input| {
                runtime.writes += 1;
                state.bytes += input.bytes.len;
                return .{ .request = .{ .write = .{
                    .file = upload.FileHandle.init(1),
                    .bytes = input.bytes,
                    .offset = input.offset,
                } } };
            },
            .completion => |completion| completeWrite(completion),
        };
    }

    pub fn finish(
        runtime: *Runtime,
        state: *State,
        event: upload.PollEvent(upload.FinishInput),
    ) Error!upload.Poll(Summary) {
        return switch (event) {
            .start => |input| {
                if (input.bytes != state.bytes) return error.InvalidBytes;
                runtime.finishes += 1;
                return .{ .done = state.bytes };
            },
            .completion => error.UnexpectedCompletion,
        };
    }

    pub fn commit(
        runtime: *Runtime,
        _: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        if (event == .completion) return error.UnexpectedCompletion;
        runtime.commits += 1;
        return .{ .done = {} };
    }

    pub fn abort(
        runtime: *Runtime,
        _: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        if (event == .completion) return error.UnexpectedCompletion;
        runtime.aborts += 1;
        return .{ .done = {} };
    }

    fn synchronous(event: upload.PollEvent(void)) Error!upload.Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.UnexpectedCompletion,
        };
    }

    fn completeWrite(completion: upload.IoCompletion) Error!upload.Poll(void) {
        return switch (completion) {
            .success => |success| switch (success) {
                .write => .{ .done = {} },
                else => error.UnexpectedCompletion,
            },
            .failure => error.IoFailure,
        };
    }
};

const spec = multipart.decode(.{
    .file = multipart.file(BenchSink, multipart.oneTo(4)),
}, .{
    .limits = .{ .parts_max = 4, .files_max = 4 },
    .upload = .{ .window = window, .chunk_bytes = chunk_bytes },
});
const Spec = @TypeOf(spec);

const Registry = struct {
    runtime: BenchSink.Runtime = .{},

    pub fn get(self: *@This(), comptime Sink: type) *Sink.Runtime {
        if (comptime Sink == BenchSink) return &self.runtime;
        @compileError("unexpected upload benchmark sink");
    }
};

const Transaction = transaction.Transaction(Spec, Registry);

fn benchPipelinedWrites(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runIterations(iterations, .writes);
        }
    }.run);
}

fn benchCommitFour(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runIterations(iterations, .commit);
        }
    }.run);
}

fn benchAbortFour(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runIterations(iterations, .abort);
        }
    }.run);
}

const Case = enum { writes, commit, abort };

fn runIterations(iterations: u64, comptime case: Case) u64 {
    if (iterations == 0) benchmarkFailure();
    var fingerprint: u64 = 0;
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        fingerprint +%= switch (case) {
            .writes => runPipelinedWrites(),
            .commit => runFinalization(true),
            .abort => runFinalization(false),
        };
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    const expected: u64 = switch (case) {
        .writes => payload.len + window + 1,
        .commit => 12,
        .abort => 12,
    };
    if (fingerprint != expected *% iterations) benchmarkFailure();
    std.mem.doNotOptimizeAway(&fingerprint);
    return elapsed_ns;
}

fn runPipelinedWrites() u64 {
    var registry = Registry{};
    var tx = Transaction.init(&registry);
    expectFlow(tx.fileStartProgress(startEvent(1), .{ .file = {} }), .ready);
    var submissions: [window]Transaction.Submission = undefined;
    var offset: usize = 0;
    for (&submissions, 0..) |*submission, index| {
        const progress = tx.fileChunkProgress(chunkEvent(offset, payload[offset..])) catch {
            benchmarkFailure();
        };
        if (progress.consumed != chunk_bytes or progress.flow != .paused) benchmarkFailure();
        offset += progress.consumed;
        submission.* = tx.peekSubmission() catch benchmarkFailure() orelse benchmarkFailure();
        tx.markSubmitted(submission.lane) catch benchmarkFailure();
        if (index + 1 < window) expectFlow(tx.multipartResume(.file_chunk), .ready);
    }
    if (offset != payload.len) benchmarkFailure();
    var resumed = false;
    var reverse = submissions.len;
    while (reverse > 0) {
        reverse -= 1;
        const pending = submissions[reverse];
        const written: u32 = @intCast(pending.request.write.bytes.len);
        tx.complete(pending.lane, .{ .success = .{ .write = written } }) catch {
            benchmarkFailure();
        };
        if (!resumed) {
            expectFlow(tx.multipartResume(.file_chunk), .ready);
            resumed = true;
        }
    }
    expectFlow(tx.fileEndProgress(endEvent(1, payload.len)), .ready);
    tx.markCommitReady() catch benchmarkFailure();
    expectFinalFlow(tx.startCommit(), .complete);
    const report = tx.report() catch benchmarkFailure() orelse benchmarkFailure();
    if (report.outcome != .committed or registry.runtime.writes != window or
        registry.runtime.commits != 1)
    {
        benchmarkFailure();
    }
    std.mem.doNotOptimizeAway(&tx);
    return payload.len + registry.runtime.writes + registry.runtime.commits;
}

fn runFinalization(comptime commit: bool) u64 {
    var registry = Registry{};
    var tx = Transaction.init(&registry);
    for (1..5) |occurrence| {
        expectFlow(tx.fileStartProgress(
            startEvent(@intCast(occurrence)),
            .{ .file = {} },
        ), .ready);
        expectFlow(tx.fileEndProgress(endEvent(@intCast(occurrence), 0)), .ready);
    }
    if (commit) {
        tx.markCommitReady() catch benchmarkFailure();
        expectFinalFlow(tx.startCommit(), .complete);
    } else {
        expectFinalFlow(tx.startAbort(null), .complete);
    }
    const report = tx.report() catch benchmarkFailure() orelse benchmarkFailure();
    const expected: upload_finalizer.Outcome = if (commit) .committed else .aborted;
    if (report.outcome != expected or registry.runtime.begins != 4 or
        registry.runtime.finishes != 4)
    {
        benchmarkFailure();
    }
    const finalized = if (commit) registry.runtime.commits else registry.runtime.aborts;
    if (finalized != 4) benchmarkFailure();
    std.mem.doNotOptimizeAway(&tx);
    return registry.runtime.begins + registry.runtime.finishes + finalized;
}

fn expectFlow(result: anytype, expected: parser.CallbackFlow) void {
    const actual = result catch benchmarkFailure();
    if (actual != expected) benchmarkFailure();
}

fn expectFinalFlow(result: anytype, expected: Transaction.FinalizationFlow) void {
    const actual = result catch benchmarkFailure();
    if (actual != expected) benchmarkFailure();
}

fn startEvent(occurrence: u16) events.FileStart {
    return .{ .entry_index = 0, .occurrence = occurrence, .metadata = undefined };
}

fn chunkEvent(offset: usize, bytes: []const u8) events.FileChunk {
    return .{
        .entry_index = 0,
        .occurrence = 1,
        .offset = @intCast(offset),
        .bytes = bytes,
    };
}

fn endEvent(occurrence: u16, bytes: u64) events.FileEnd {
    return .{ .entry_index = 0, .occurrence = occurrence, .bytes = bytes };
}

pub const group = sigbench.groupWithId(
    "m9-upload-transaction",
    "M9 bounded upload window and finalization",
    .{
        sigbench.benchWithThroughput(
            "window-4x4k-out-of-order",
            "four retained writes completed in reverse CQE order",
            .{ .bytes = payload.len },
            benchPipelinedWrites,
        ),
        sigbench.benchWithThroughput(
            "commit-four",
            "sequential commit for four staged files",
            .{ .elements = 4 },
            benchCommitFour,
        ),
        sigbench.benchWithThroughput(
            "abort-four",
            "reverse abort for four staged files",
            .{ .elements = 4 },
            benchAbortFour,
        ),
    },
);

test "upload benchmark cases retain validity checks" {
    try std.testing.expectEqual(@as(u64, payload.len + window + 1), runPipelinedWrites());
    try std.testing.expectEqual(@as(u64, 12), runFinalization(true));
    try std.testing.expectEqual(@as(u64, 12), runFinalization(false));
}

pub fn writeMetricsReport(
    init: std.process.Init,
    default_output_root: []const u8,
) !void {
    const output_root = try selectedOutputRoot(init, default_output_root) orelse return;
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try std.fmt.bufPrint(
        &directory_storage,
        "{s}/m9-upload",
        .{output_root},
    );
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    var data_storage: [512]u8 = undefined;
    const data = try std.fmt.bufPrint(
        &data_storage,
        "{{\n  \"format\":1,\n  \"transaction_bytes\":{},\n" ++
            "  \"finalization_report_bytes\":{},\n" ++
            "  \"retained_window_bytes\":{},\n" ++
            "  \"window_slots\":{},\n  \"chunk_bytes\":{},\n" ++
            "  \"filesink_payload_bytes\":{},\n" ++
            "  \"filesink_window_slots\":{},\n" ++
            "  \"filesink_chunk_bytes\":{},\n" ++
            "  \"filesink_mode_cases\":4\n}}\n",
        .{
            @sizeOf(Transaction),
            @sizeOf(Transaction.Report),
            payload.len,
            window,
            chunk_bytes,
            file_sink_benchmark.payload_bytes,
            file_sink_benchmark.window,
            file_sink_benchmark.chunk_bytes,
        },
    );
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "{s}/metrics.json", .{directory});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = data });
}

fn selectedOutputRoot(
    init: std.process.Init,
    default_output_root: []const u8,
) !?[]const u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    var output_root = default_output_root;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sigbench-exact")) return null;
        if (std.mem.eql(u8, arg, "--output-dir")) {
            output_root = args.next() orelse return error.MissingArgument;
        }
    }
    return output_root;
}
