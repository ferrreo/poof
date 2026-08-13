const std = @import("std");
const parser = @import("../../src/internal/multipart/parser.zig");
const upload_finalizer = @import("../../src/internal/upload/finalizer.zig");
const base = @import("multipart_upload_transaction_test.zig");

const Harness = base.Harness;
const Registry = base.Registry;
const Spec = base.Spec;
const TraceEntry = base.TraceEntry;
const Transaction = base.Transaction;
const chunkEvent = base.chunkEvent;
const endEvent = base.endEvent;
const expectFatal = base.expectFatal;
const expectLifecycle = base.expectLifecycle;
const expectSinkCollision = base.expectSinkCollision;
const expectSyncWriteLane = base.expectSyncWriteLane;
const expectWrite = base.expectWrite;
const filterTrace = base.filterTrace;
const startEvent = base.startEvent;
const submitPending = base.submitPending;
const syncSuccess = base.syncSuccess;
const synchronousBodyAndEnd = base.synchronousBodyAndEnd;
const synchronousFile = base.synchronousFile;
const traceCount = base.traceCount;
const upstreamFailure = base.upstreamFailure;
const writeSuccess = base.writeSuccess;

test "heterogeneous repeats and discard preserve fitting summary order" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    var tx = Transaction.init(&registry);

    try synchronousFile(&tx, 0, 1, .{ .alpha = 10 }, "a");
    try synchronousFile(&tx, 2, 1, .{ .beta = 20 }, "bc");
    try synchronousFile(&tx, 3, 1, .{ .discard = {} }, "ignored");
    try synchronousFile(&tx, 0, 2, .{ .alpha = 30 }, "def");

    const summaries = try tx.summaries();
    try std.testing.expectEqual(@as(usize, 2), summaries.alpha.slice().len);
    try std.testing.expectEqual(@as(u64, 1), summaries.alpha.slice()[0].bytes);
    try std.testing.expectEqual(@as(u64, 3), summaries.alpha.slice()[1].bytes);
    try std.testing.expectEqual(@as(usize, 1), summaries.beta.slice().len);
    try std.testing.expectEqual(@as(u64, 2), summaries.beta.slice()[0].bytes);
    try std.testing.expectEqual(@as(usize, 1), summaries.discard.slice().len);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(@TypeOf(
        summaries.discard.slice()[0],
    )));
}

test "raw schema entry validation distinguishes gap variant and occurrence" {
    var harness = Harness{};
    var registry = Registry.init(&harness);

    var gap = Transaction.init(&registry);
    try std.testing.expectError(error.TransactionFatal, gap.fileStartProgress(
        startEvent(1, 1),
        .{ .beta = 1 },
    ));
    try expectFatal(&gap, .invalid_entry, 1);

    var variant = Transaction.init(&registry);
    try std.testing.expectError(error.TransactionFatal, variant.fileStartProgress(
        startEvent(0, 1),
        .{ .beta = 1 },
    ));
    try expectFatal(&variant, .variant_mismatch, 0);

    var occurrence = Transaction.init(&registry);
    try std.testing.expectError(error.TransactionFatal, occurrence.fileStartProgress(
        startEvent(0, 0),
        .{ .alpha = 1 },
    ));
    try expectFatal(&occurrence, .invalid_occurrence, 0);
    try std.testing.expectEqual(@as(usize, 0), harness.trace_len);
}

test "transaction may move before first record but never after one" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    const initial = Transaction.init(&registry);
    var before_record = initial;

    try std.testing.expectEqual(parser.CallbackFlow.ready, try before_record.fileStartProgress(
        startEvent(0, 1),
        .{ .alpha = 1 },
    ));
    var after_record = before_record;
    try std.testing.expectError(error.TransactionFatal, after_record.fileChunkProgress(
        chunkEvent(0, 1, 0, "x"),
    ));
    try expectFatal(&after_record, .moved_after_record, null);
}

test "async begin retains outbox until submission and resumes exact wait" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    registry.alpha.behavior.begin_async = true;
    var tx = Transaction.init(&registry);

    try std.testing.expectEqual(parser.CallbackFlow.paused, try tx.fileStartProgress(
        startEvent(0, 1),
        .{ .alpha = 4 },
    ));
    const first = (try tx.peekSubmission()).?;
    const second = (try tx.peekSubmission()).?;
    try expectLifecycle(first.lane);
    try std.testing.expectEqual(Spec.File.alpha, first.file);
    try std.testing.expectEqual(@as(u16, 0), first.instance_index);
    try std.testing.expectEqual(first.request.sync.file, second.request.sync.file);
    try std.testing.expectEqual(
        parser.CallbackFlow.paused,
        try tx.multipartResume(.file_start),
    );
    try tx.markSubmitted(first.lane);
    try tx.complete(first.lane, syncSuccess());
    try std.testing.expectEqual(
        parser.CallbackFlow.ready,
        try tx.multipartResume(.file_start),
    );
    try synchronousBodyAndEnd(&tx, 0, 1, "data");
}

test "async finish publishes summary only after completion and resume" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    registry.beta.behavior.finish_async = true;
    var tx = Transaction.init(&registry);

    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileStartProgress(
        startEvent(2, 1),
        .{ .beta = 9 },
    ));
    const chunk = try tx.fileChunkProgress(chunkEvent(2, 1, 0, "xyz"));
    try std.testing.expectEqual(@as(usize, 3), chunk.consumed);
    try std.testing.expectEqual(parser.CallbackFlow.paused, try tx.fileEndProgress(
        endEvent(2, 1, 3),
    ));
    try std.testing.expectEqual(@as(usize, 0), (try tx.summaries()).beta.slice().len);
    const pending = try submitPending(&tx);
    try expectLifecycle(pending.lane);
    try tx.complete(pending.lane, syncSuccess());
    try std.testing.expectEqual(
        parser.CallbackFlow.ready,
        try tx.multipartResume(.file_end),
    );
    try std.testing.expectEqual(@as(usize, 1), (try tx.summaries()).beta.slice().len);
}

test "bounded chunk intake retains stable bytes across source mutation" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    registry.alpha.behavior.write_async = true;
    var tx = Transaction.init(&registry);
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileStartProgress(
        startEvent(0, 1),
        .{ .alpha = 1 },
    ));
    var source = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f' };
    const progress = try tx.fileChunkProgress(chunkEvent(0, 1, 0, &source));
    try std.testing.expectEqual(@as(usize, 4), progress.consumed);
    try std.testing.expectEqual(parser.CallbackFlow.paused, progress.flow);
    @memcpy(source[0..4], "WXYZ");
    const pending = (try tx.peekSubmission()).?;
    try expectWrite(pending, 0, "abcd", 0);
}

test "invalid generated write request is a poisoned window invariant" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    registry.alpha.behavior.invalid_write_request = true;
    var tx = Transaction.init(&registry);
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileStartProgress(
        startEvent(0, 1),
        .{ .alpha = 1 },
    ));

    try std.testing.expectError(error.TransactionFatal, tx.fileChunkProgress(
        chunkEvent(0, 1, 0, "x"),
    ));
    try expectFatal(&tx, .window_invariant, 0);
}

test "sink TransactionFatal name collision keeps explicit provenance" {
    try expectSinkCollision(.begin);
    try expectSinkCollision(.write);
    try expectSinkCollision(.finish);

    var harness = Harness{};
    var registry = Registry.init(&harness);
    var framework = Transaction.init(&registry);
    var framework_error: ?Transaction.Error = null;
    if (framework.fileStartProgress(startEvent(0, 0), .{ .alpha = 1 })) |_| {
        return error.ExpectedFrameworkFailure;
    } else |problem| {
        framework_error = problem;
    }
    try std.testing.expect(framework_error.? == error.TransactionFatal);
    try std.testing.expectEqual(
        Transaction.FailureKind.fatal,
        framework.failureKind(framework_error.?),
    );
    try expectFatal(&framework, .invalid_occurrence, 0);
}

test "short write retries exact suffix on same lane" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    registry.alpha.behavior.write_async = true;
    var tx = Transaction.init(&registry);
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileStartProgress(
        startEvent(0, 1),
        .{ .alpha = 1 },
    ));
    _ = try tx.fileChunkProgress(chunkEvent(0, 1, 0, "abcd"));
    const first = try submitPending(&tx);
    try expectWrite(first, 0, "abcd", 0);
    try tx.complete(first.lane, writeSuccess(2));
    const retry = (try tx.peekSubmission()).?;
    try expectWrite(retry, 0, "cd", 2);
    try tx.markSubmitted(retry.lane);
    try tx.complete(retry.lane, writeSuccess(2));
    try std.testing.expectEqual(
        parser.CallbackFlow.ready,
        try tx.multipartResume(.file_chunk),
    );
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileEndProgress(
        endEvent(0, 1, 4),
    ));
}

test "write slots complete out of order and file end waits for drain" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    registry.alpha.behavior.write_async = true;
    var tx = Transaction.init(&registry);
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileStartProgress(
        startEvent(0, 1),
        .{ .alpha = 1 },
    ));

    const first_progress = try tx.fileChunkProgress(chunkEvent(0, 1, 0, "abcdefgh"));
    try std.testing.expectEqual(@as(usize, 4), first_progress.consumed);
    const first = try submitPending(&tx);
    try expectWrite(first, 0, "abcd", 0);
    try std.testing.expectEqual(
        parser.CallbackFlow.ready,
        try tx.multipartResume(.file_chunk),
    );
    const second_progress = try tx.fileChunkProgress(chunkEvent(0, 1, 4, "efgh"));
    try std.testing.expectEqual(@as(usize, 4), second_progress.consumed);
    const second = try submitPending(&tx);
    try expectWrite(second, 1, "efgh", 4);

    try tx.complete(second.lane, writeSuccess(4));
    try std.testing.expectEqual(
        parser.CallbackFlow.ready,
        try tx.multipartResume(.file_chunk),
    );
    try std.testing.expectEqual(parser.CallbackFlow.paused, try tx.fileEndProgress(
        endEvent(0, 1, 8),
    ));
    try tx.complete(first.lane, writeSuccess(4));
    try std.testing.expectEqual(
        parser.CallbackFlow.ready,
        try tx.multipartResume(.file_end),
    );
}

test "lane-local continuations do not block another submitted CQE" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    registry.alpha.behavior.write_async = true;
    registry.alpha.behavior.write_continue = true;
    var tx = Transaction.init(&registry);
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileStartProgress(
        startEvent(0, 1),
        .{ .alpha = 1 },
    ));

    _ = try tx.fileChunkProgress(chunkEvent(0, 1, 0, "abcdefgh"));
    const first = try submitPending(&tx);
    try std.testing.expectEqual(
        parser.CallbackFlow.ready,
        try tx.multipartResume(.file_chunk),
    );
    _ = try tx.fileChunkProgress(chunkEvent(0, 1, 4, "efgh"));
    const second = try submitPending(&tx);

    try tx.complete(first.lane, writeSuccess(4));
    const first_retry = (try tx.peekSubmission()).?;
    try expectSyncWriteLane(first_retry, 0);
    try tx.complete(second.lane, writeSuccess(4));
    const still_first = (try tx.peekSubmission()).?;
    try expectSyncWriteLane(still_first, 0);

    try tx.markSubmitted(still_first.lane);
    try tx.complete(still_first.lane, syncSuccess());
    const second_retry = (try tx.peekSubmission()).?;
    try expectSyncWriteLane(second_retry, 1);
    try tx.markSubmitted(second_retry.lane);
    try tx.complete(second_retry.lane, syncSuccess());
    try std.testing.expectEqual(
        parser.CallbackFlow.ready,
        try tx.multipartResume(.file_chunk),
    );
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileEndProgress(
        endEvent(0, 1, 8),
    ));
}

test "outbox rejects early completion wrong lane and duplicate completion" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    registry.alpha.behavior.begin_async = true;

    var early = Transaction.init(&registry);
    _ = try early.fileStartProgress(startEvent(0, 1), .{ .alpha = 1 });
    try std.testing.expectError(
        error.TransactionFatal,
        early.complete(.lifecycle, syncSuccess()),
    );
    try expectFatal(&early, .completion_before_submission, 0);

    var wrong_mark = Transaction.init(&registry);
    _ = try wrong_mark.fileStartProgress(startEvent(0, 1), .{ .alpha = 1 });
    try std.testing.expectError(
        error.TransactionFatal,
        wrong_mark.markSubmitted(.{ .write = 0 }),
    );
    try expectFatal(&wrong_mark, .lane_mismatch, 0);

    var duplicate = Transaction.init(&registry);
    _ = try duplicate.fileStartProgress(startEvent(0, 1), .{ .alpha = 1 });
    const pending = try submitPending(&duplicate);
    try duplicate.complete(pending.lane, syncSuccess());
    try std.testing.expectError(
        error.TransactionFatal,
        duplicate.complete(pending.lane, syncSuccess()),
    );
    try expectFatal(&duplicate, .lane_mismatch, 0);
}

test "submitted abort drains CQE before reverse finalization" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    registry.alpha.behavior.write_async = true;
    var tx = Transaction.init(&registry);
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileStartProgress(
        startEvent(0, 1),
        .{ .alpha = 1 },
    ));
    _ = try tx.fileChunkProgress(chunkEvent(0, 1, 0, "abcd"));
    const write = try submitPending(&tx);

    try std.testing.expectEqual(
        Transaction.FinalizationFlow.paused,
        try tx.startAbort(null),
    );
    try std.testing.expectEqual(@as(usize, 0), traceCount(&harness, .abort));
    try std.testing.expectEqual(
        Transaction.FinalizationFlow.paused,
        try tx.finalizationFlow(),
    );
    try tx.completeCanceled(write.lane);
    try std.testing.expectEqual(
        Transaction.FinalizationFlow.complete,
        try tx.finalizationFlow(),
    );
    try std.testing.expectEqual(@as(usize, 1), traceCount(&harness, .abort));
    const report = (try tx.report()).?;
    try std.testing.expectEqual(upload_finalizer.Outcome.aborted, report.outcome);
}

test "unsubmitted abort abandons the exact pending sink request" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    registry.alpha.behavior.write_async = true;
    registry.alpha.behavior.write_continue = true;
    var tx = Transaction.init(&registry);
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileStartProgress(
        startEvent(0, 1),
        .{ .alpha = 1 },
    ));
    _ = try tx.fileChunkProgress(chunkEvent(0, 1, 0, "abcd"));

    try std.testing.expectEqual(
        Transaction.FinalizationFlow.complete,
        try tx.startAbort(null),
    );
    try std.testing.expect((try tx.peekSubmission()) == null);
    try std.testing.expectEqual(
        Transaction.FinalizationFlow.complete,
        try tx.finalizationFlow(),
    );
    try std.testing.expect((try tx.peekSubmission()) == null);
    try std.testing.expectEqual(
        upload_finalizer.Outcome.aborted,
        (try tx.report()).?.outcome,
    );
}

test "commit follows file-start chronology across heterogeneous repeats" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    var tx = Transaction.init(&registry);
    try synchronousFile(&tx, 0, 1, .{ .alpha = 1 }, "a");
    try synchronousFile(&tx, 2, 1, .{ .beta = 1 }, "b");
    try synchronousFile(&tx, 0, 2, .{ .alpha = 1 }, "c");

    try tx.markCommitReady();
    try std.testing.expectEqual(
        Transaction.FinalizationFlow.complete,
        try tx.startCommit(),
    );
    var commits: [8]TraceEntry = undefined;
    const actual = filterTrace(&harness, .commit, &commits);
    try std.testing.expectEqualSlices(TraceEntry, &.{
        .{ .operation = .commit, .sink = 1, .serial = 1 },
        .{ .operation = .commit, .sink = 2, .serial = 2 },
        .{ .operation = .commit, .sink = 1, .serial = 3 },
    }, actual);
    const report = (try tx.report()).?;
    try std.testing.expectEqual(upload_finalizer.Outcome.committed, report.outcome);
    try std.testing.expectEqual(@as(usize, 3), report.commit_attempted_count);
    try std.testing.expectEqual(@as(usize, 3), report.commit_completed_count);
}

test "commit requires explicit readiness gate" {
    var premature_harness = Harness{};
    var premature_registry = Registry.init(&premature_harness);
    var premature = Transaction.init(&premature_registry);
    try synchronousFile(&premature, 0, 1, .{ .alpha = 1 }, "x");
    try std.testing.expectError(error.TransactionFatal, premature.startCommit());
    try expectFatal(&premature, .phase_mismatch, null);

    var gated_harness = Harness{};
    var gated_registry = Registry.init(&gated_harness);
    var gated = Transaction.init(&gated_registry);
    try synchronousFile(&gated, 0, 1, .{ .alpha = 1 }, "x");
    try gated.markCommitReady();
    try std.testing.expectEqual(
        Transaction.FinalizationFlow.complete,
        try gated.startCommit(),
    );
    try std.testing.expectEqual(
        upload_finalizer.Outcome.committed,
        (try gated.report()).?.outcome,
    );
}

test "commit readiness lock rejects later abort decision" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    var tx = Transaction.init(&registry);
    try synchronousFile(&tx, 0, 1, .{ .alpha = 1 }, "x");
    try tx.markCommitReady();

    try std.testing.expectError(
        error.TransactionFatal,
        tx.startAbort(.peer_disconnect),
    );
    try expectFatal(&tx, .phase_mismatch, null);
    try std.testing.expectEqual(@as(usize, 0), traceCount(&harness, .abort));
}

test "discard-only summaries anchor transaction storage" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    var tx = Transaction.init(&registry);
    try synchronousFile(&tx, 3, 1, .{ .discard = {} }, "ignored");
    try std.testing.expectEqual(@as(usize, 1), (try tx.summaries()).discard.slice().len);

    var moved = tx;
    try std.testing.expectError(error.TransactionFatal, moved.startAbort(null));
    try expectFatal(&moved, .moved_after_record, null);
}

test "maximum event offset remains a framework fatal" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    var tx = Transaction.init(&registry);
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileStartProgress(
        startEvent(0, 1),
        .{ .alpha = 1 },
    ));
    try std.testing.expectError(error.TransactionFatal, tx.fileChunkProgress(
        chunkEvent(0, 1, std.math.maxInt(u64), "x"),
    ));
    try expectFatal(&tx, .offset_mismatch, 0);
}

test "commit failure stops forward pass and compensates every record in reverse" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    registry.beta.behavior.reject = .commit;
    registry.beta.behavior.reject_serial = 2;
    var tx = Transaction.init(&registry);
    try synchronousFile(&tx, 0, 1, .{ .alpha = 1 }, "a");
    try synchronousFile(&tx, 2, 1, .{ .beta = 1 }, "b");
    try synchronousFile(&tx, 0, 2, .{ .alpha = 1 }, "c");

    try tx.markCommitReady();
    try std.testing.expectEqual(
        Transaction.FinalizationFlow.complete,
        try tx.startCommit(),
    );
    var commits: [8]TraceEntry = undefined;
    try std.testing.expectEqualSlices(TraceEntry, &.{
        .{ .operation = .commit, .sink = 1, .serial = 1 },
    }, filterTrace(&harness, .commit, &commits));
    var aborts: [8]TraceEntry = undefined;
    try std.testing.expectEqualSlices(TraceEntry, &.{
        .{ .operation = .abort, .sink = 1, .serial = 3 },
        .{ .operation = .abort, .sink = 2, .serial = 2 },
        .{ .operation = .abort, .sink = 1, .serial = 1 },
    }, filterTrace(&harness, .abort, &aborts));
    const report = (try tx.report()).?;
    try std.testing.expectEqual(upload_finalizer.Outcome.failed, report.outcome);
    try std.testing.expectEqual(@as(usize, 2), report.commit_attempted_count);
    try std.testing.expectEqual(@as(usize, 1), report.commit_completed_count);
    try std.testing.expectEqual(@as(usize, 3), report.abort_completed_count);
    try std.testing.expectEqual(@as(?usize, 1), report.primary.?.entry_index);
}

test "cleanup failure is masked and reverse cleanup continues" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    registry.beta.behavior.reject = .abort;
    registry.beta.behavior.reject_serial = 2;
    var tx = Transaction.init(&registry);
    try synchronousFile(&tx, 0, 1, .{ .alpha = 1 }, "a");
    try synchronousFile(&tx, 2, 1, .{ .beta = 1 }, "b");
    try synchronousFile(&tx, 0, 2, .{ .alpha = 1 }, "c");

    try std.testing.expectEqual(
        Transaction.FinalizationFlow.complete,
        try tx.startAbort(null),
    );
    var aborts: [8]TraceEntry = undefined;
    try std.testing.expectEqualSlices(TraceEntry, &.{
        .{ .operation = .abort, .sink = 1, .serial = 3 },
        .{ .operation = .abort, .sink = 1, .serial = 1 },
    }, filterTrace(&harness, .abort, &aborts));
    const report = (try tx.report()).?;
    try std.testing.expectEqual(upload_finalizer.Outcome.failed, report.outcome);
    try std.testing.expectEqual(@as(usize, 3), report.abort_attempted_count);
    try std.testing.expectEqual(@as(usize, 2), report.abort_completed_count);
    try std.testing.expectEqual(@as(usize, 1), report.cleanup_failure_count);
    try std.testing.expect(report.cleanupFailed(1));
    try std.testing.expect(!report.responseAllowed());
}

test "clean abort permits response while upstream abort does not" {
    var clean_harness = Harness{};
    var clean_registry = Registry.init(&clean_harness);
    var clean = Transaction.init(&clean_registry);
    try synchronousFile(&clean, 0, 1, .{ .alpha = 1 }, "x");
    try std.testing.expectEqual(
        Transaction.FinalizationFlow.complete,
        try clean.startAbort(null),
    );
    const clean_report = (try clean.report()).?;
    try std.testing.expectEqual(upload_finalizer.Outcome.aborted, clean_report.outcome);
    try std.testing.expect(clean_report.responseAllowed());
    try std.testing.expect(clean_report.primary == null);

    var failed_harness = Harness{};
    var failed_registry = Registry.init(&failed_harness);
    var failed = Transaction.init(&failed_registry);
    try synchronousFile(&failed, 0, 1, .{ .alpha = 1 }, "x");
    try std.testing.expectEqual(
        Transaction.FinalizationFlow.complete,
        try failed.startAbort(upstreamFailure()),
    );
    const failed_report = (try failed.report()).?;
    try std.testing.expectEqual(upload_finalizer.Outcome.failed, failed_report.outcome);
    try std.testing.expect(!failed_report.responseAllowed());
    try std.testing.expect(failed_report.primary.?.class == .upstream);
    try std.testing.expectEqual(
        upstreamFailure(),
        failed_report.primary.?.class.upstream,
    );
}

test "finish sink failure stores no summary and remains primary" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    registry.beta.behavior.reject = .finish;
    var tx = Transaction.init(&registry);
    try std.testing.expectEqual(parser.CallbackFlow.ready, try tx.fileStartProgress(
        startEvent(2, 1),
        .{ .beta = 1 },
    ));
    _ = try tx.fileChunkProgress(chunkEvent(2, 1, 0, "x"));
    try std.testing.expectError(
        error.Rejected,
        tx.fileEndProgress(endEvent(2, 1, 1)),
    );
    try std.testing.expectEqual(@as(usize, 0), (try tx.summaries()).beta.slice().len);
    try std.testing.expectEqual(
        Transaction.FinalizationFlow.complete,
        try tx.startAbort(null),
    );
    const report = (try tx.report()).?;
    try std.testing.expectEqual(upload_finalizer.Outcome.failed, report.outcome);
    try std.testing.expectEqual(@as(?usize, 0), report.primary.?.entry_index);
}

test "finalization gates report and late completion is fatal" {
    var harness = Harness{};
    var registry = Registry.init(&harness);
    registry.alpha.behavior.commit_async = true;
    var tx = Transaction.init(&registry);
    try synchronousFile(&tx, 0, 1, .{ .alpha = 1 }, "x");

    try tx.markCommitReady();
    try std.testing.expectEqual(
        Transaction.FinalizationFlow.paused,
        try tx.startCommit(),
    );
    try std.testing.expect((try tx.report()) == null);
    try std.testing.expectEqual(
        Transaction.FinalizationFlow.paused,
        try tx.finalizationFlow(),
    );
    const pending = try submitPending(&tx);
    try tx.complete(pending.lane, syncSuccess());
    try std.testing.expectEqual(
        Transaction.FinalizationFlow.complete,
        try tx.finalizationFlow(),
    );
    try std.testing.expectEqual(
        upload_finalizer.Outcome.committed,
        (try tx.report()).?.outcome,
    );
    try std.testing.expectError(
        error.TransactionFatal,
        tx.complete(pending.lane, syncSuccess()),
    );
    try expectFatal(&tx, .lane_mismatch, null);
}
