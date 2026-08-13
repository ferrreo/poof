const source = @import("worker_live_static_test.zig");
const std = source.std;
const application = source.application;
const response = source.response;
const static_file = source.static_file;
const config = source.config;
const connection_driver = source.connection_driver;
const deterministic_reactor = source.deterministic_reactor;
const reactor = source.reactor;
const worker_runtime = source.worker_runtime;
const worker_storage = source.worker_storage;
const fixed_date = source.fixed_date;
const State = source.State;
const Context = source.Context;
const Observe = source.Observe;
const App = source.App;
const limits = source.limits;
const Storage = source.Storage;
const TestReactor = source.TestReactor;
const Driver = source.Driver;
const Worker = source.Worker;
const TinyTestReactor = source.TinyTestReactor;
const TinyWorker = source.TinyWorker;
const MultiRootApp = source.MultiRootApp;
const MultiRootStorage = source.MultiRootStorage;
const MultiRootDriver = source.MultiRootDriver;
const LiveHarness = source.LiveHarness;
const isDrainOperation = source.isDrainOperation;
const CancelSendStage = source.CancelSendStage;
const PendingSend = source.PendingSend;
const long_content = source.long_content;
const reachPendingSend = source.reachPendingSend;
const expectRootOperation = source.expectRootOperation;
const findRootSubmission = source.findRootSubmission;
const settleDriverRootTarget = source.settleDriverRootTarget;
const settleWorkerRootTarget = source.settleWorkerRootTarget;
const completeAllStaticCloses = source.completeAllStaticCloses;
const fillDirectoryStat = source.fillDirectoryStat;
const ScheduleStage = source.ScheduleStage;
const RootSchedule = source.RootSchedule;
const fuzzLiveStaticControllerSchedule = source.fuzzLiveStaticControllerSchedule;
const fuzzRootSchedule = source.fuzzRootSchedule;
const settleLatePositiveRootTimeout = source.settleLatePositiveRootTimeout;
const expectFuzzRootIdle = source.expectFuzzRootIdle;
const settleFuzzRootTarget = source.settleFuzzRootTarget;
const completeRootControl = source.completeRootControl;
const fuzzRequestSchedule = source.fuzzRequestSchedule;
const reachScheduleStage = source.reachScheduleStage;
const RandomDrain = source.RandomDrain;
const expectScheduleClean = source.expectScheduleClean;
const expectDescriptorLedgerClosed = source.expectDescriptorLedgerClosed;
const expectZeroed = source.expectZeroed;

test "live static conditional fields precede range on the transfer path" {
    const content = "0123456789abcdef";
    var not_modified: LiveHarness = undefined;
    try not_modified.init(content);
    const not_modified_connection = try not_modified.request(
        "GET /assets/value.txt HTTP/1.1\r\n" ++
            "Host: example.test\r\nIf-None-Match: *\r\nRange: bytes=2-5\r\n\r\n",
    );
    try not_modified.runResponse(not_modified_connection);
    try std.testing.expect(std.mem.startsWith(
        u8,
        not_modified.written(),
        "HTTP/1.1 304 Not Modified\r\n",
    ));
    try std.testing.expectEqual(@as(u16, 0), not_modified.read_count);

    var precondition: LiveHarness = undefined;
    try precondition.init(content);
    const precondition_connection = try precondition.request(
        "GET /assets/value.txt HTTP/1.1\r\n" ++
            "Host: example.test\r\nIf-Match: \"mismatch\"\r\n" ++
            "Range: bytes=2-5\r\n\r\n",
    );
    try precondition.runResponse(precondition_connection);
    try std.testing.expect(std.mem.startsWith(
        u8,
        precondition.written(),
        "HTTP/1.1 412 Precondition Failed\r\n",
    ));
    try std.testing.expectEqual(@as(u16, 0), precondition.read_count);

    var if_range: LiveHarness = undefined;
    try if_range.init(content);
    const if_range_connection = try if_range.request(
        "GET /assets/value.txt HTTP/1.1\r\n" ++
            "Host: example.test\r\nRange: bytes=2-5\r\n" ++
            "If-Range: \"mismatch\"\r\n\r\n",
    );
    try if_range.runResponse(if_range_connection);
    try std.testing.expect(std.mem.startsWith(u8, if_range.written(), "HTTP/1.1 200 OK\r\n"));
    try std.testing.expectEqualStrings(content, try if_range.body());
}

test "request STATX rejects stale regular mode when required mask is absent" {
    var harness: LiveHarness = undefined;
    try harness.init("must not be served");
    const connection = try harness.request(
        "GET /assets/value.txt HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    try harness.completeStatic(harness.findStatic(.file_open).?);
    const stat = harness.findStatic(.file_stat).?;
    stat.operation.file_stat.output.* = std.mem.zeroes(std.os.linux.Statx);
    stat.operation.file_stat.output.mode = 0o100644;
    stat.operation.file_stat.output.size = harness.content.len;
    stat.operation.file_stat.output.mask = .{ .SIZE = true, .MTIME = true, .INO = true };
    try harness.completeStaticResult(stat, .{ .success = .{ .file_stat = {} } });
    try harness.runResponse(connection);
    try std.testing.expect(std.mem.startsWith(
        u8,
        harness.written(),
        "HTTP/1.1 500 Internal Server Error\r\n",
    ));
    try std.testing.expectEqual(@as(u16, 0), harness.read_count);
    try std.testing.expectEqual(@as(u16, 0), harness.driver.liveStaticRequests());
}

test "live static same-size mutation withholds terminal chunk and closes" {
    const content = "same-size content mutation";
    var harness: LiveHarness = undefined;
    try harness.init(content);
    harness.mutate_on_verify = true;
    const connection = try harness.request(
        "GET /assets/value.txt HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    try harness.runReleased(connection);

    try std.testing.expectEqual(@as(u8, 2), harness.regular_stat_count);
    try std.testing.expectEqual(@as(u16, 1), harness.read_count);
    try std.testing.expectEqual(@as(usize, 0), (try harness.body()).len);
    try std.testing.expectEqual(@as(u16, 0), harness.driver.liveStaticRequests());
}

test "live static cancellation retains every borrowed send until target completion" {
    for (std.meta.tags(CancelSendStage)) |stage| {
        for ([_]bool{ false, true }) |send_success| {
            for ([_]bool{ false, true }) |close_first| {
                const content: []const u8 = if (stage == .body_nonterminal)
                    &long_content
                else
                    "terminal body";
                var harness: LiveHarness = undefined;
                try harness.init(content);
                const pending = try reachPendingSend(&harness, stage);
                const borrowed = pending.submission.operation.send.bytes;
                var snapshot: [4096]u8 = undefined;
                try std.testing.expect(borrowed.len <= snapshot.len);
                @memcpy(snapshot[0..borrowed.len], borrowed);

                _ = try harness.driver.stop(pending.connection);
                const close = harness.findStatic(.file_close).?;
                if (close_first) {
                    try harness.completeStatic(close);
                    try std.testing.expectEqual(
                        @as(u16, 1),
                        harness.driver.liveStaticRequests(),
                    );
                    try std.testing.expectEqualSlices(u8, snapshot[0..borrowed.len], borrowed);
                }
                try harness.completeSendResult(pending.submission, send_success);
                if (!close_first) try harness.completeStatic(close);
                try harness.runReleased(pending.connection);

                const target_wins = send_success and
                    (stage == .head_complete or stage == .body_terminal);
                try std.testing.expectEqual(
                    @as(u16, @intFromBool(target_wins)),
                    harness.state.completed,
                );
                try std.testing.expectEqual(
                    @as(u16, @intFromBool(!target_wins)),
                    harness.state.aborted,
                );
                try std.testing.expectEqual(@as(u16, 0), harness.driver.liveStaticRequests());
            }
        }
    }
}

test "repeated close retires terminal send target and cancel in either order" {
    inline for (.{ CancelSendStage.head_complete, CancelSendStage.body_terminal }) |stage| {
        inline for (.{ false, true }) |send_success| {
            inline for (.{ false, true }) |cancel_first| {
                var harness: LiveHarness = undefined;
                try harness.init("terminal body");
                const pending = try reachPendingSend(&harness, stage);

                _ = try harness.driver.stop(pending.connection);
                const target = harness.findStatic(.file_close).?;
                _ = try harness.driver.stop(pending.connection);
                const cancel = harness.findStatic(.file_cancel).?;
                try harness.completeSendResult(pending.submission, send_success);

                if (cancel_first) {
                    try harness.completeStaticResult(
                        cancel,
                        .{ .success = .{ .file_cancel = .canceled } },
                    );
                    try harness.completeStaticResult(target, .{ .failure = .canceled });
                } else {
                    try harness.completeStatic(target);
                    try harness.completeStaticResult(
                        cancel,
                        .{ .success = .{ .file_cancel = .not_found } },
                    );
                }
                if (harness.findStatic(.file_close)) |close| {
                    try harness.completeStatic(close);
                }
                try harness.runReleased(pending.connection);

                try std.testing.expectEqual(
                    @as(u16, @intFromBool(send_success)),
                    harness.state.completed,
                );
                try std.testing.expectEqual(
                    @as(u16, @intFromBool(!send_success)),
                    harness.state.aborted,
                );
                try std.testing.expectEqual(@as(u16, 0), harness.driver.liveStaticRequests());
            }
        }
    }
}

test "live static cancellation retires target and cancel in either order" {
    inline for (.{ false, true }) |cancel_first| {
        var harness: LiveHarness = undefined;
        try harness.init("body");
        const connection = try harness.request(
            "GET /assets/value.txt HTTP/1.1\r\nHost: example.test\r\n\r\n",
        );
        const target = harness.findStatic(.file_open).?;
        try std.testing.expectEqual(
            connection_driver.Disposition.retained,
            try harness.driver.stop(connection),
        );
        const cancel = harness.findStatic(.file_cancel).?;
        if (cancel_first) {
            try harness.completeStaticResult(
                cancel,
                .{ .success = .{ .file_cancel = .canceled } },
            );
        }
        try harness.completeStaticResult(target, .{ .failure = .canceled });
        if (!cancel_first) {
            try harness.completeStaticResult(
                cancel,
                .{ .success = .{ .file_cancel = .canceled } },
            );
        }
        try harness.runReleased(connection);
        try std.testing.expectEqual(@as(u16, 0), harness.driver.liveStaticRequests());
    }
}

test "live static in-flight cancel closes acquired descriptor before reuse" {
    var harness: LiveHarness = undefined;
    try harness.init("body");
    const connection = try harness.request(
        "GET /assets/value.txt HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    try harness.completeStatic(harness.findStatic(.file_open).?);
    const target = harness.findStatic(.file_stat).?;
    _ = try harness.driver.stop(connection);
    const cancel = harness.findStatic(.file_cancel).?;
    try harness.completeStatic(target);
    try harness.completeStaticResult(
        cancel,
        .{ .success = .{ .file_cancel = .not_found } },
    );
    const close = harness.findStatic(.file_close).?;
    try std.testing.expectEqual(@as(i32, 50), close.operation.file_close.file.value);
    try harness.completeStatic(close);
    try harness.runReleased(connection);
    try std.testing.expectEqual(@as(u16, 0), harness.driver.liveStaticRequests());
}

test "live static drain waits for requests then closes root ownership" {
    var harness: LiveHarness = undefined;
    try harness.init("body");
    const connection = try harness.request(
        "GET /assets/value.txt HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    try std.testing.expectError(error.StateInvariant, harness.driver.beginLiveStaticStop());
    try harness.runResponse(connection);
    try std.testing.expectEqual(.pending, try harness.driver.beginLiveStaticStop());
    const close = harness.findRoot(.file_close).?;
    try std.testing.expectEqual(@as(i32, 41), close.operation.file_close.file.value);
    try harness.io.complete(close.token, .{ .success = .{ .file_close = {} } }, false);
    try std.testing.expectEqual(
        .stopped,
        try harness.driver.handleLiveStatic(
            harness.io.nextCompletion().?,
            1_784_030_400,
            4,
        ),
    );
    try std.testing.expect(harness.driver.liveStaticStopped());
}

test {
    std.testing.refAllDecls(@This());
}
