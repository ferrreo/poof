const std = @import("std");
const linux = std.os.linux;
const sigbench = @import("sigbench");

const multipart = @import("../src/multipart.zig");
const harness_module = @import("../tests/unit/internal/runtime/upload_io_uring_test_harness.zig");

pub const chunk_bytes: usize = 16 * 1024;
pub const window: usize = 4;
pub const payload_bytes: usize = chunk_bytes * window;

const payload = [_]u8{0x5a} ** payload_bytes;
const entropy = [_]u8{0xa5} ** 32;
const storage_key = "upload.bin";

const anonymous_buffered = multipart.FileSinkConfig{
    .root = "zig-out/ploof-m9-filesink-ab",
    .durability = .buffered,
};
const anonymous_durable = multipart.FileSinkConfig{
    .root = "zig-out/ploof-m9-filesink-ad",
    .durability = .crash_durable,
};
const named_buffered = multipart.FileSinkConfig{
    .root = "zig-out/ploof-m9-filesink-nb",
    .durability = .buffered,
    .staging = .{ .named_staging = ".stage" },
};
const named_durable = multipart.FileSinkConfig{
    .root = "zig-out/ploof-m9-filesink-nd",
    .durability = .crash_durable,
    .staging = .{ .named_staging = ".stage" },
};

fn FileBench(comptime supplied: multipart.FileSinkConfig, comptime group_id: u16) type {
    const Sink = multipart.FileSink(supplied);
    const Harness = harness_module.Harness(Sink, group_id);

    return struct {
        const Self = @This();
        const State = struct {
            harness: Harness = undefined,
            runtime_driver: Harness.RuntimeDriver = .{},
            lifecycle: Harness.LifecycleDriver = .{},
            writer: Harness.WriteDriver = .{},
            sink_state: Sink.State = Sink.initial_state,
            runtime: *Sink.Runtime = undefined,
            summary_bytes: u64 = 0,
        };

        var state: State = .{};
        var active = false;

        fn bench(bencher: *sigbench.Bencher) void {
            beginBenchmark();
            defer endBenchmark();
            bencher.iterBatchWithTeardown(
                *State,
                setupIteration,
                run,
                teardownIteration,
                .per_iteration,
            );
        }

        fn beginBenchmark() void {
            if (active) benchmarkFailure();
            ensureDirectories(supplied);
            state = .{};
            state.harness.init() catch |problem| benchmarkError("harness init", problem);
            state.harness.runtimeStart(&state.runtime_driver, .{
                .worker_index = 0,
                .entropy = &entropy,
            }) catch |problem| benchmarkError("runtime start", problem);
            state.runtime = state.runtime_driver.runtimePointer() orelse benchmarkFailure();
            active = true;
        }

        fn setupIteration() *State {
            if (!active) benchmarkFailure();
            state.lifecycle = .{};
            state.writer = .{};
            state.sink_state = Sink.initial_state;
            state.summary_bytes = 0;
            return &state;
        }

        fn run(pointer: **State) void {
            const current = pointer.*;
            const key = Sink.Key.init(storage_key) catch benchmarkFailure();
            current.harness.begin(
                &current.lifecycle,
                current.runtime,
                &current.sink_state,
                key,
            ) catch |problem| benchmarkError("begin", problem);
            for (0..window) |index| {
                const start = index * chunk_bytes;
                current.harness.write(
                    &current.writer,
                    current.runtime,
                    &current.sink_state,
                    .{ .bytes = payload[start..][0..chunk_bytes], .offset = start },
                ) catch |problem| benchmarkError("write", problem);
            }
            const summary = current.harness.finish(
                &current.lifecycle,
                current.runtime,
                &current.sink_state,
                .{ .bytes = payload.len },
            ) catch |problem| benchmarkError("finish", problem);
            current.harness.commit(
                &current.lifecycle,
                current.runtime,
                &current.sink_state,
            ) catch |problem| benchmarkError("commit", problem);
            if (summary.bytes != payload.len or
                !std.mem.eql(u8, summary.storage_key, storage_key))
            {
                benchmarkFailure();
            }
            current.summary_bytes = summary.bytes;
            std.mem.doNotOptimizeAway(&current.summary_bytes);
        }

        fn teardownIteration(pointer: **State) void {
            const current = pointer.*;
            if (!active or current.summary_bytes != payload.len) benchmarkFailure();
            current.harness.abort(
                &current.lifecycle,
                current.runtime,
                &current.sink_state,
            ) catch |problem| benchmarkError("compensating abort", problem);
            current.summary_bytes = 0;
        }

        fn endBenchmark() void {
            if (!active) benchmarkFailure();
            state.harness.runtimeStop(&state.runtime_driver) catch |problem| {
                benchmarkError("runtime stop", problem);
            };
            state.harness.deinit() catch |problem| benchmarkError("harness deinit", problem);
            active = false;
        }
    };
}

const AnonymousBuffered = FileBench(anonymous_buffered, 101);
const AnonymousDurable = FileBench(anonymous_durable, 102);
const NamedBuffered = FileBench(named_buffered, 103);
const NamedDurable = FileBench(named_durable, 104);

pub const group = sigbench.groupWithId(
    "m9-filesink-io-uring",
    "M9 FileSink real io_uring 64 KiB upload",
    .{
        sigbench.benchWithThroughput(
            "anonymous-buffered",
            "anonymous staging, buffered publication",
            .{ .bytes = payload_bytes },
            AnonymousBuffered.bench,
        ),
        sigbench.benchWithThroughput(
            "anonymous-crash-durable",
            "anonymous staging, crash-durable publication",
            .{ .bytes = payload_bytes },
            AnonymousDurable.bench,
        ),
        sigbench.benchWithThroughput(
            "named-buffered",
            "named staging, buffered publication",
            .{ .bytes = payload_bytes },
            NamedBuffered.bench,
        ),
        sigbench.benchWithThroughput(
            "named-crash-durable",
            "named staging, crash-durable publication",
            .{ .bytes = payload_bytes },
            NamedDurable.bench,
        ),
    },
);

fn ensureDirectories(comptime supplied: multipart.FileSinkConfig) void {
    makeDirectory(supplied.root);
    switch (supplied.staging) {
        .anonymous_required => {},
        .named_staging => |name| {
            const path = supplied.root ++ "/" ++ name;
            makeDirectory(path);
        },
    }
}

fn makeDirectory(comptime path: []const u8) void {
    const sentinel = path ++ "\x00";
    const result = linux.mkdir(sentinel, 0o700);
    const problem = linux.errno(result);
    if (problem != .SUCCESS and problem != .EXIST) benchmarkFailure();
}

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof FileSink benchmark validity check failed");
}

fn benchmarkError(comptime stage: []const u8, problem: anyerror) noreturn {
    std.debug.print("Ploof FileSink benchmark {s} failed: {s}\n", .{ stage, @errorName(problem) });
    benchmarkFailure();
}

test "FileSink benchmark keeps standard upload dimensions" {
    try std.testing.expectEqual(@as(usize, 16 * 1024), chunk_bytes);
    try std.testing.expectEqual(@as(usize, 4), window);
    try std.testing.expectEqual(@as(usize, 64 * 1024), payload.len);
    try std.testing.expectEqual(@as(usize, 4), group.cases.len);
}
