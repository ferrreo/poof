const std = @import("std");

const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const multipart = @import("../src/multipart.zig");
const upload = @import("../src/multipart/upload.zig");
const events = @import("../src/internal/multipart/events.zig");
const parser = @import("../src/internal/multipart/parser.zig");
const transaction = @import("../src/internal/multipart/upload_transaction.zig");

const fuzz_sink = @import("internal/multipart_upload_transaction_fuzz_sink.zig");
const operation_count_max = fuzz_sink.operation_count_max;
const state_steps_max = 256;
const Operation = fuzz_sink.Operation;
const TraceEntry = fuzz_sink.TraceEntry;
const Harness = fuzz_sink.Harness;
const Behavior = fuzz_sink.Behavior;
const TestSink = fuzz_sink.TestSink;

const Alpha = TestSink(1);
const Beta = TestSink(2);
const spec = multipart.decode(.{
    .alpha = multipart.file(Alpha, multipart.oneTo(2)),
    .beta = multipart.file(Beta, multipart.oneTo(2)),
}, .{
    .limits = .{ .parts_max = 4, .files_max = 4 },
    .upload = .{ .window = 2, .chunk_bytes = 4 },
});
const Spec = @TypeOf(spec);

const Registry = struct {
    alpha: Alpha.Runtime,
    beta: Beta.Runtime,

    fn init(harness: *Harness, behavior: Behavior) Registry {
        return .{
            .alpha = .{ .harness = harness, .behavior = behavior },
            .beta = .{ .harness = harness, .behavior = behavior },
        };
    }

    pub fn get(self: *Registry, comptime Sink: type) *Sink.Runtime {
        if (Sink == Alpha) return &self.alpha;
        if (Sink == Beta) return &self.beta;
        unreachable;
    }
};

const Transaction = transaction.Transaction(Spec, Registry);

const Scenario = enum(u8) {
    commit,
    abort,
    upstream_abort,
    fail_begin,
    fail_write,
    fail_finish,
    fail_commit,
    fail_abort,
    bad_occurrence,
    bad_offset,
    duplicate_cqe,
    early_commit,
};

const Case = struct {
    scenario: Scenario,
    file_count: u8,
    target: u8,
    short_writes: bool,
    behavior: Behavior,

    fn decode(control: u64) Case {
        const scenario_count = @typeInfo(Scenario).@"enum".fields.len;
        const scenario: Scenario = @enumFromInt(@as(u8, @truncate(control)) % scenario_count);
        var result = Case{
            .scenario = scenario,
            .file_count = 2 + @as(u8, @truncate((control >> 8) & 0x3)) % 3,
            .target = @truncate((control >> 10) & 0x3),
            .short_writes = control & (@as(u64, 1) << 17) != 0,
            .behavior = .{
                .begin_async = control & (@as(u64, 1) << 12) != 0,
                .write_async = control & (@as(u64, 1) << 13) != 0,
                .finish_async = control & (@as(u64, 1) << 14) != 0,
                .commit_async = control & (@as(u64, 1) << 15) != 0,
                .abort_async = control & (@as(u64, 1) << 16) != 0,
            },
        };
        if (result.short_writes or scenario == .fail_write) result.behavior.write_async = true;
        switch (scenario) {
            .fail_begin, .duplicate_cqe => result.behavior.begin_async = true,
            .fail_finish => result.behavior.finish_async = true,
            .fail_commit => result.behavior.commit_async = true,
            .fail_abort => result.behavior.abort_async = true,
            else => {},
        }
        result.target %= result.file_count;
        return result;
    }
};

const File = struct {
    tag: Spec.File,
    entry: u16,
    occurrence: u16,
    sink: u8,
};

const files = [_]File{
    .{ .tag = .alpha, .entry = 0, .occurrence = 1, .sink = 1 },
    .{ .tag = .beta, .entry = 1, .occurrence = 1, .sink = 2 },
    .{ .tag = .alpha, .entry = 0, .occurrence = 2, .sink = 1 },
    .{ .tag = .beta, .entry = 1, .occurrence = 2, .sink = 2 },
};

const PendingWrite = struct { instance: u16, offset: u64, length: u32 };
const PendingLifecycle = struct { instance: u16, file: Spec.File };

const Snapshot = struct {
    terminal: enum { report, fatal },
    report: ?Transaction.Report = null,
    fatal_class: ?Transaction.FatalClass = null,
    fatal_entry: ?u16 = null,
    trace: [operation_count_max]TraceEntry,
    trace_len: u8,
    cqe_digest: u64,
    cqe_count: u16,
    steps: u16,
    alpha_bytes: [2]u64 = @splat(0),
    alpha_count: u8 = 0,
    beta_bytes: [2]u64 = @splat(0),
    beta_count: u8 = 0,
};

const Runner = struct {
    tx: *Transaction,
    harness: *Harness,
    case: Case,
    actions: []const u8,
    action_index: usize = 0,
    writes: [2]?PendingWrite = @splat(null),
    lifecycle: ?PendingLifecycle = null,
    lengths: [4]u8 = @splat(0),
    payloads: [4][12]u8 = undefined,
    begun: u8 = 0,
    finished: u8 = 0,
    short_done: bool = false,
    failure_sent: bool = false,
    cqe_digest: u64 = 0,
    cqe_count: u16 = 0,
    steps: u16 = 0,

    fn prepare(self: *Runner, control: u64) void {
        for (0..self.case.file_count) |file_index| {
            var length: u8 = 1 + self.next() % 12;
            if (self.case.short_writes and length == 1) length = 2;
            self.lengths[file_index] = length;
            for (0..length) |byte_index| {
                const shift: u6 = @intCast(((file_index + byte_index) % 8) * 8);
                self.payloads[file_index][byte_index] = @truncate(
                    (control >> shift) ^ (file_index * 31 + byte_index),
                );
            }
        }
    }

    fn next(self: *Runner) u8 {
        if (self.actions.len == 0) return 0;
        const value = self.actions[self.action_index % self.actions.len];
        self.action_index += 1;
        return value;
    }

    fn tick(self: *Runner) !void {
        if (self.steps == state_steps_max) return error.UploadFuzzStateStuck;
        self.steps += 1;
    }

    fn payload(self: *Runner, index: usize) []const u8 {
        return self.payloads[index][0..self.lengths[index]];
    }

    fn startFile(self: *Runner, index: usize) !bool {
        try self.tick();
        const file = files[index];
        const flow = switch (file.tag) {
            .alpha => try self.tx.fileStartProgress(startEvent(file, file.occurrence), .{
                .alpha = @intCast(index),
            }),
            .beta => try self.tx.fileStartProgress(startEvent(file, file.occurrence), .{
                .beta = @intCast(index),
            }),
        };
        self.begun += 1;
        if (flow == .ready) return true;
        try self.acceptPending(null);
        const fail = self.case.scenario == .fail_begin and index == self.case.target;
        const failed = try self.completeLifecycle(fail, true);
        if (failed) return false;
        try std.testing.expectEqual(
            parser.CallbackFlow.ready,
            try self.tx.multipartResume(.file_start),
        );
        return true;
    }

    fn writeAndFinish(self: *Runner, index: usize) !bool {
        const body = self.payload(index);
        var offset: usize = 0;
        while (offset < body.len) {
            try self.tick();
            const progress = try self.tx.fileChunkProgress(chunkEvent(
                files[index],
                offset,
                body[offset..],
            ));
            try std.testing.expect(progress.consumed > 0);
            offset += progress.consumed;
            if (progress.flow == .ready) continue;
            if (try self.tx.peekSubmission() != null) try self.acceptPending(body);
            var flow = try self.tx.multipartResume(.file_chunk);
            while (flow == .paused) {
                if (try self.completeScheduledWrite(body, index, false)) return false;
                if (try self.tx.peekSubmission() != null) try self.acceptPending(body);
                flow = try self.tx.multipartResume(.file_chunk);
            }
        }

        try self.tick();
        var flow = try self.tx.fileEndProgress(endEvent(files[index], body.len));
        while (flow == .paused) {
            if (try self.tx.peekSubmission() != null) try self.acceptPending(body);
            if (self.lifecycle != null) {
                const fail = self.case.scenario == .fail_finish and index == self.case.target;
                if (try self.completeLifecycle(fail, true)) return false;
            } else if (self.hasWrites()) {
                if (try self.completeScheduledWrite(body, index, false)) return false;
            } else return error.UploadFuzzStateStuck;
            flow = try self.tx.multipartResume(.file_end);
        }
        self.finished += 1;
        try self.expectSummary(index, body.len);
        return true;
    }

    fn acceptPending(self: *Runner, body: ?[]const u8) !void {
        try self.tick();
        const pending = (try self.tx.peekSubmission()) orelse return error.MissingSubmission;
        if (pending.instance_index >= self.begun or pending.instance_index >= files.len) {
            return error.InvalidFuzzInstance;
        }
        switch (pending.lane) {
            .lifecycle => {
                try std.testing.expect(self.lifecycle == null);
                switch (pending.request) {
                    .sync => |request| try std.testing.expectEqual(
                        files[pending.instance_index].sink,
                        @as(u8, @intCast(request.file.index())),
                    ),
                    else => return error.UnexpectedLifecycleRequest,
                }
                self.lifecycle = .{ .instance = pending.instance_index, .file = pending.file };
            },
            .write => |slot| {
                if (@as(usize, slot) >= self.writes.len) return error.InvalidFuzzLane;
                try std.testing.expect(self.writes[slot] == null);
                const active_body = body orelse return error.MissingActiveBody;
                const request = switch (pending.request) {
                    .write => |request| request,
                    else => return error.UnexpectedWriteRequest,
                };
                const offset = std.math.cast(usize, request.offset) orelse {
                    return error.InvalidFuzzOffset;
                };
                if (offset > active_body.len or request.bytes.len > active_body.len - offset) {
                    return error.InvalidFuzzBounds;
                }
                try std.testing.expectEqualSlices(
                    u8,
                    active_body[offset .. offset + request.bytes.len],
                    request.bytes,
                );
                self.writes[slot] = .{
                    .instance = pending.instance_index,
                    .offset = request.offset,
                    .length = @intCast(request.bytes.len),
                };
            },
        }
        try self.tx.markSubmitted(pending.lane);
    }

    fn completeLifecycle(
        self: *Runner,
        fail: bool,
        propagate_sink_failure: bool,
    ) !bool {
        try self.tick();
        const pending = self.lifecycle orelse return error.MissingLifecycleSubmission;
        self.lifecycle = null;
        const completion: upload.IoCompletion = if (fail)
            .{ .failure = .io_failure }
        else
            syncSuccess();
        self.noteCqe(2, pending.instance, if (fail) 0 else 1);
        self.tx.complete(.lifecycle, completion) catch |problem| {
            if (fail and propagate_sink_failure and problem == error.Rejected) return true;
            return problem;
        };
        if (fail and propagate_sink_failure) return error.ExpectedSinkFailure;
        return false;
    }

    fn completeScheduledWrite(
        self: *Runner,
        body: []const u8,
        file_index: usize,
        cancel: bool,
    ) !bool {
        const slot = self.selectWriteSlot() orelse return error.MissingWriteSubmission;
        try self.tick();
        const pending = self.writes[slot].?;
        self.writes[slot] = null;
        const fail = !cancel and !self.failure_sent and
            self.case.scenario == .fail_write and file_index == self.case.target;
        const completion: upload.IoCompletion = if (cancel)
            .{ .failure = .canceled }
        else if (fail)
            .{ .failure = .io_failure }
        else success: {
            var length = pending.length;
            if (self.case.short_writes and !self.short_done and length > 1) {
                length = 1 + self.next() % (length - 1);
                self.short_done = true;
            }
            break :success .{ .success = .{ .write = length } };
        };
        const result = switch (completion) {
            .success => |success| success.write,
            .failure => 0,
        };
        self.noteCqe(@intCast(slot), pending.instance, result);
        self.tx.complete(.{ .write = @intCast(slot) }, completion) catch |problem| {
            if (fail and problem == error.Rejected) {
                self.failure_sent = true;
                return true;
            }
            return problem;
        };
        if (fail) return error.ExpectedSinkFailure;
        if (!cancel and try self.tx.peekSubmission() != null) try self.acceptPending(body);
        return false;
    }

    fn selectWriteSlot(self: *Runner) ?usize {
        const first = if (self.writes[0] != null) @as(?usize, 0) else null;
        const second = if (self.writes[1] != null) @as(?usize, 1) else null;
        if (first != null and second != null) return if (self.next() & 1 == 0) 0 else 1;
        return first orelse second;
    }

    fn hasWrites(self: *const Runner) bool {
        return self.writes[0] != null or self.writes[1] != null;
    }

    fn noteCqe(self: *Runner, lane: u8, instance: u16, result: u32) void {
        self.cqe_digest = self.cqe_digest *% 0x9e3779b185ebca87 ^
            @as(u64, lane) ^ (@as(u64, instance) << 8) ^ (@as(u64, result) << 24);
        self.cqe_count += 1;
    }

    fn finalize(self: *Runner, collection_failed: bool) !Transaction.Report {
        var operation: Operation = undefined;
        var flow: Transaction.FinalizationFlow = undefined;
        if (collection_failed) {
            operation = .abort;
            flow = try self.tx.startAbort(null);
        } else switch (self.case.scenario) {
            .commit, .fail_commit => {
                operation = .commit;
                try self.tx.markCommitReady();
                flow = try self.tx.startCommit();
            },
            .abort, .fail_abort => {
                operation = .abort;
                flow = try self.tx.startAbort(null);
            },
            .upstream_abort => {
                operation = .abort;
                flow = try self.tx.startAbort(.body);
            },
            else => return error.InvalidFinalizationScenario,
        }

        while (flow != .complete) {
            try self.tick();
            if (flow == .progress) {
                flow = try self.tx.finalizationFlow();
                continue;
            }
            if (try self.tx.peekSubmission() != null) try self.acceptPending(null);
            if (self.hasWrites()) {
                _ = try self.completeScheduledWrite(&.{}, 0, true);
            } else if (self.lifecycle) |pending| {
                const fail = !self.failure_sent and pending.instance == self.case.target and
                    ((operation == .commit and self.case.scenario == .fail_commit) or
                        (operation == .abort and self.case.scenario == .fail_abort));
                _ = try self.completeLifecycle(fail, false);
                if (fail) {
                    self.failure_sent = true;
                    if (operation == .commit) operation = .abort;
                }
            } else return error.UploadFuzzStateStuck;
            flow = try self.tx.finalizationFlow();
        }
        const report = (try self.tx.report()) orelse return error.MissingFinalReport;
        return report.*;
    }

    fn expectSummary(self: *Runner, index: usize, length: usize) !void {
        const summaries = try self.tx.summaries();
        const occurrence = files[index].occurrence - 1;
        switch (files[index].tag) {
            .alpha => {
                try std.testing.expect(summaries.alpha.slice().len > occurrence);
                try std.testing.expectEqual(
                    @as(u64, @intCast(length)),
                    summaries.alpha.slice()[occurrence].bytes,
                );
            },
            .beta => {
                try std.testing.expect(summaries.beta.slice().len > occurrence);
                try std.testing.expectEqual(
                    @as(u64, @intCast(length)),
                    summaries.beta.slice()[occurrence].bytes,
                );
            },
        }
    }
};

fn fuzzTransaction(_: void, smith: *std.testing.Smith) !void {
    const control = smith.value(u64);
    var action_storage: [64]u8 = undefined;
    const actions = action_storage[0..smith.slice(&action_storage)];
    const first = try runCase(control, actions);
    const second = try runCase(control, actions);
    try std.testing.expectEqualDeep(first, second);
}

fn runCase(control: u64, actions: []const u8) !Snapshot {
    const case = Case.decode(control);
    var harness = Harness{};
    var registry = Registry.init(&harness, case.behavior);
    var tx = Transaction.init(&registry);
    var runner = Runner{
        .tx = &tx,
        .harness = &harness,
        .case = case,
        .actions = actions,
    };
    runner.prepare(control);

    switch (case.scenario) {
        .bad_occurrence, .bad_offset, .duplicate_cqe, .early_commit => {
            return runAdversarial(&runner);
        },
        else => {},
    }

    var collection_failed = false;
    for (0..case.file_count) |index| {
        if (!try runner.startFile(index) or !try runner.writeAndFinish(index)) {
            collection_failed = true;
            break;
        }
    }
    const report = try runner.finalize(collection_failed);
    try expectReport(&runner, report, collection_failed);
    try expectTrace(&runner, report);
    try expectQuiescent(&runner);
    return snapshot(&runner, report, null);
}

fn runAdversarial(runner: *Runner) !Snapshot {
    switch (runner.case.scenario) {
        .bad_occurrence => {
            try runner.tick();
            try std.testing.expectError(error.TransactionFatal, runner.tx.fileStartProgress(
                startEvent(files[0], 0),
                .{ .alpha = 0 },
            ));
            try expectFatalClass(runner.tx, .invalid_occurrence);
        },
        .bad_offset => {
            try std.testing.expect(try runner.startFile(0));
            try runner.tick();
            try std.testing.expectError(error.TransactionFatal, runner.tx.fileChunkProgress(
                chunkEvent(files[0], 1, runner.payload(0)),
            ));
            try expectFatalClass(runner.tx, .offset_mismatch);
        },
        .duplicate_cqe => {
            try runner.tick();
            try std.testing.expectEqual(
                parser.CallbackFlow.paused,
                try runner.tx.fileStartProgress(startEvent(files[0], 1), .{ .alpha = 0 }),
            );
            runner.begun = 1;
            try runner.acceptPending(null);
            _ = try runner.completeLifecycle(false, true);
            try std.testing.expectError(
                error.TransactionFatal,
                runner.tx.complete(.lifecycle, syncSuccess()),
            );
            try expectFatalClass(runner.tx, .lane_mismatch);
        },
        .early_commit => {
            try runner.tick();
            try std.testing.expectError(error.TransactionFatal, runner.tx.startCommit());
            try expectFatalClass(runner.tx, .phase_mismatch);
        },
        else => unreachable,
    }
    const fatal = runner.tx.fatal().?;
    try std.testing.expectError(error.TransactionFatal, runner.tx.peekSubmission());
    try std.testing.expect(runner.tx.lifecycle.quiescent());
    try std.testing.expect(runner.tx.window.quiescent());
    try std.testing.expect(!runner.tx.lanes.hasSubmitted());
    try std.testing.expect(!runner.tx.lanes.hasUnsubmitted());
    return snapshot(runner, null, fatal);
}

fn expectReport(
    runner: *Runner,
    report: Transaction.Report,
    collection_failed: bool,
) !void {
    var expected = Transaction.Report{};
    if (collection_failed) {
        expected.outcome = .failed;
        expected.primary = .{ .class = .sink, .entry_index = runner.case.target };
        expected.abort_attempted_count = runner.begun;
        expected.abort_completed_count = runner.begun;
    } else switch (runner.case.scenario) {
        .commit => {
            expected.outcome = .committed;
            expected.commit_attempted_count = runner.begun;
            expected.commit_completed_count = runner.begun;
        },
        .abort => {
            expected.abort_attempted_count = runner.begun;
            expected.abort_completed_count = runner.begun;
        },
        .upstream_abort => {
            expected.outcome = .failed;
            expected.primary = .{
                .class = .{ .upstream = .body },
                .entry_index = null,
            };
            expected.abort_attempted_count = runner.begun;
            expected.abort_completed_count = runner.begun;
        },
        .fail_commit => {
            expected.outcome = .failed;
            expected.primary = .{ .class = .sink, .entry_index = runner.case.target };
            expected.commit_attempted_count = runner.case.target + 1;
            expected.commit_completed_count = runner.case.target;
            expected.abort_attempted_count = runner.begun;
            expected.abort_completed_count = runner.begun;
        },
        .fail_abort => {
            expected.outcome = .failed;
            expected.abort_attempted_count = runner.begun;
            expected.abort_completed_count = runner.begun - 1;
            expected.cleanup_failure_count = 1;
            expected.cleanup_failure_mask[0] = @as(u64, 1) << @intCast(runner.case.target);
            expected.cleanup_failure_classes[runner.case.target] = .sink;
        },
        else => return error.InvalidReportScenario,
    }
    try std.testing.expectEqualDeep(expected, report);
    if (runner.case.short_writes and runner.case.scenario != .fail_begin and
        runner.case.scenario != .fail_write)
    {
        try std.testing.expect(runner.short_done);
    }
    try std.testing.expectEqualDeep(report, (try runner.tx.report()).?.*);
    try std.testing.expectEqual(@as(usize, runner.begun), runner.tx.record_count);
}

fn expectTrace(runner: *Runner, report: Transaction.Report) !void {
    var begin_count: u32 = 0;
    var commit_count: u32 = 0;
    var abort_count: u32 = 0;
    for (runner.harness.trace[0..runner.harness.trace_len]) |entry| {
        if (entry.serial == 0 or entry.serial > runner.begun) return error.InvalidTraceSerial;
        try std.testing.expectEqual(files[entry.serial - 1].sink, entry.sink);
        switch (entry.operation) {
            .begin => {
                begin_count += 1;
                try std.testing.expectEqual(begin_count, entry.serial);
            },
            .commit => {
                commit_count += 1;
                try std.testing.expectEqual(commit_count, entry.serial);
            },
            .abort => {
                abort_count += 1;
                try std.testing.expectEqual(
                    @as(u32, runner.begun) - abort_count + 1,
                    entry.serial,
                );
            },
            .write, .finish => {},
        }
    }
    try std.testing.expectEqual(@as(u32, runner.begun), begin_count);
    try std.testing.expectEqual(report.commit_attempted_count, commit_count);
    try std.testing.expectEqual(report.abort_attempted_count, abort_count);
}

fn expectQuiescent(runner: *Runner) !void {
    try std.testing.expect((try runner.tx.peekSubmission()) == null);
    try std.testing.expect(!runner.tx.lanes.hasSubmitted());
    try std.testing.expect(!runner.tx.lanes.hasUnsubmitted());
    try std.testing.expect(runner.tx.lifecycle.quiescent());
    try std.testing.expect(runner.tx.window.quiescent());
    try std.testing.expect(!runner.hasWrites());
    try std.testing.expect(runner.lifecycle == null);
}

fn snapshot(
    runner: *Runner,
    report: ?Transaction.Report,
    fatal: ?Transaction.Fatal,
) !Snapshot {
    var result = Snapshot{
        .terminal = if (fatal == null) .report else .fatal,
        .report = report,
        .fatal_class = if (fatal) |value| value.class else null,
        .fatal_entry = if (fatal) |value| value.entry_index else null,
        .trace = runner.harness.trace,
        .trace_len = @intCast(runner.harness.trace_len),
        .cqe_digest = runner.cqe_digest,
        .cqe_count = runner.cqe_count,
        .steps = runner.steps,
    };
    if (fatal == null) {
        const summaries = try runner.tx.summaries();
        if (summaries.alpha.slice().len > result.alpha_bytes.len or
            summaries.beta.slice().len > result.beta_bytes.len)
        {
            return error.InvalidFuzzSummaryCount;
        }
        result.alpha_count = @intCast(summaries.alpha.slice().len);
        result.beta_count = @intCast(summaries.beta.slice().len);
        for (summaries.alpha.slice(), 0..) |summary, index| {
            result.alpha_bytes[index] = summary.bytes;
        }
        for (summaries.beta.slice(), 0..) |summary, index| {
            result.beta_bytes[index] = summary.bytes;
        }
    }
    return result;
}

fn expectFatalClass(tx: *Transaction, class: Transaction.FatalClass) !void {
    try std.testing.expectEqual(class, (tx.fatal() orelse return error.MissingFatal).class);
}

fn startEvent(file: File, occurrence: u16) events.FileStart {
    return .{ .entry_index = file.entry, .occurrence = occurrence, .metadata = undefined };
}

fn chunkEvent(file: File, offset: u64, bytes: []const u8) events.FileChunk {
    return .{
        .entry_index = file.entry,
        .occurrence = file.occurrence,
        .offset = offset,
        .bytes = bytes,
    };
}

fn endEvent(file: File, bytes: u64) events.FileEnd {
    return .{ .entry_index = file.entry, .occurrence = file.occurrence, .bytes = bytes };
}

fn syncSuccess() upload.IoCompletion {
    return .{ .success = .{ .sync = {} } };
}

test "multipart upload transaction structured schedules are deterministic and bounded" {
    try std.testing.fuzz({}, fuzzTransaction, .{ .corpus = &fuzz_corpus });
}

fn fuzzCase(comptime control: u64, comptime actions: []const u8) [12 + actions.len]u8 {
    const encoded_actions = fuzz_support.smithInput(actions);
    var input: [12 + actions.len]u8 = undefined;
    std.mem.writeInt(u64, input[0..8], control, .little);
    @memcpy(input[8..], &encoded_actions);
    return input;
}

fn seedControl(comptime scenario: Scenario, comptime flags: u64) u64 {
    return @intFromEnum(scenario) | flags;
}

const fuzz_corpus = struct {
    const async_all = (@as(u64, 0x1f) << 12) | (@as(u64, 2) << 8);
    const commit = fuzzCase(seedControl(.commit, async_all | (@as(u64, 1) << 17)), &.{
        11, 11, 11, 11, 1, 0, 1,
    });
    const abort = fuzzCase(seedControl(.abort, async_all), &.{ 7, 9, 5, 11, 0, 1 });
    const upstream = fuzzCase(seedControl(.upstream_abort, 0), &.{ 1, 2, 3, 4 });
    const begin_failure = fuzzCase(seedControl(.fail_begin, @as(u64, 1) << 10), &.{ 8, 8 });
    const write_failure = fuzzCase(seedControl(.fail_write, @as(u64, 2) << 10), &.{ 11, 11, 11 });
    const finish_failure = fuzzCase(seedControl(.fail_finish, 0), &.{ 3, 4, 5 });
    const commit_failure = fuzzCase(seedControl(.fail_commit, async_all), &.{ 11, 8, 9, 10 });
    const abort_failure = fuzzCase(seedControl(.fail_abort, async_all), &.{ 11, 8, 9, 10 });
    const bad_occurrence = fuzzCase(seedControl(.bad_occurrence, 0), &.{});
    const bad_offset = fuzzCase(seedControl(.bad_offset, 0), &.{1});
    const duplicate = fuzzCase(seedControl(.duplicate_cqe, 0), &.{1});
    const early_commit = fuzzCase(seedControl(.early_commit, 0), &.{});

    const values = [_][]const u8{
        &commit,
        &abort,
        &upstream,
        &begin_failure,
        &write_failure,
        &finish_failure,
        &commit_failure,
        &abort_failure,
        &bad_occurrence,
        &bad_offset,
        &duplicate,
        &early_commit,
    };
}.values;
