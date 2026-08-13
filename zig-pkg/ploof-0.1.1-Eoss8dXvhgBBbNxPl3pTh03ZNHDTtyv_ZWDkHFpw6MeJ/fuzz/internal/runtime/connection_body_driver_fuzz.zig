const std = @import("std");
const fuzz_support = @import("../../../src/internal/http1/testing/smith.zig");
const reactor = @import("../../../src/internal/runtime/reactor.zig");
const driver_test = @import("../../../tests/unit/internal/runtime/connection_body_driver_test.zig");

const Harness = driver_test.Harness;
const test_limits = driver_test.test_limits;

fn fuzzFixedBodyDriver(_: void, smith: *std.testing.Smith) !void {
    var actions: [64]u8 = undefined;
    const action_count = smith.slice(&actions);
    var harness: Harness = undefined;
    try harness.init();
    const connection_index = try harness.addConnection(90);

    for (actions[0..action_count]) |action| {
        harness.now_ns += @as(u64, action) + 1;
        if (!try fuzzDriverStep(&harness, connection_index, action)) break;
    }

    if (harness.storage.connections[connection_index].phase != .free) {
        _ = try harness.driver.stop(connection_index);
        try harness.drainClosing(connection_index);
    }
    try expectFuzzDriverQuiescent(&harness);
}

fn fuzzDriverStep(harness: *Harness, connection_index: u16, action: u8) !bool {
    if (action == 0xff) {
        _ = try harness.driver.stop(connection_index);
        return false;
    }
    if (action >> 4 == 5) {
        _ = try harness.driver.resumeReceive(connection_index);
        return true;
    }
    const submission = fuzzSubmission(harness, action) orelse return false;
    try fuzzDriverCompletion(harness, connection_index, submission, action & 0x0f);
    return harness.storage.connections[connection_index].phase != .free;
}

fn fuzzSubmission(harness: *const Harness, action: u8) ?reactor.Submission {
    const preferred: ?reactor.OperationKind = switch (action >> 4) {
        0 => .receive,
        1 => .send,
        2 => .timeout,
        3 => .cancel,
        4 => .close,
        else => null,
    };
    if (preferred) |kind| {
        var index: u16 = 0;
        while (index < harness.io.activeCount()) : (index += 1) {
            const submission = harness.io.activeSubmission(index).?;
            if (std.meta.activeTag(submission.operation) == kind) return submission;
        }
    }
    const active_count = harness.io.activeCount();
    if (active_count == 0) return null;
    return harness.io.activeSubmission(@as(u16, action) % active_count);
}

fn fuzzDriverCompletion(
    harness: *Harness,
    connection_index: u16,
    submission: reactor.Submission,
    variant: u8,
) !void {
    switch (submission.operation) {
        .receive => |receive| try fuzzBodyReceive(
            harness,
            connection_index,
            submission.token,
            receive.multishot,
            variant,
        ),
        .send => |send| try fuzzBodySend(harness, submission.token, send.bytes.len, variant),
        .timeout => |timeout| try fuzzBodyTimeout(harness, submission.token, timeout, variant),
        .cancel => |cancel| try fuzzBodyCancel(harness, submission.token, cancel, variant),
        .close => _ = try harness.complete(
            submission.token,
            .{ .success = .{ .close = {} } },
            false,
        ),
        .accept,
        .wake,
        .file_open,
        .file_write,
        .file_close,
        .file_link,
        .file_unlink,
        .file_rename_no_replace,
        .file_sync,
        .upload_cancel,
        .file_read,
        .file_stat,
        .file_cancel,
        => return error.FuzzUnexpectedOperation,
    }
}

fn fuzzBodyReceive(
    harness: *Harness,
    connection_index: u16,
    token: reactor.OperationToken,
    multishot: bool,
    variant: u8,
) !void {
    switch (variant) {
        6 => _ = try harness.endOfStream(connection_index),
        7 => _ = try harness.complete(
            token,
            .{ .failure = .buffer_exhausted },
            false,
        ),
        else => {
            const bytes = fuzzReceiveBytes(variant);
            _ = try harness.receive(
                connection_index,
                bytes,
                fuzzReceiveMore(multishot, variant),
            );
        },
    }
}

fn fuzzReceiveBytes(variant: u8) []const u8 {
    return switch (variant) {
        0 => driver_test.echo_head,
        1 => driver_test.expect_echo_head,
        2 => driver_test.echo_head ++ "ab",
        3 => driver_test.expect_echo_head ++ "abcdef",
        4 => "cdef",
        5 => "abcdef" ++ driver_test.ping_request,
        8 => driver_test.echo_head,
        9 => driver_test.expect_echo_head,
        10 => "a",
        11 => "bc",
        12 => "def",
        13 => driver_test.ping_request,
        14, 15 => "X",
        6, 7 => unreachable,
        else => unreachable,
    };
}

fn fuzzReceiveMore(multishot: bool, variant: u8) bool {
    if (!multishot and variant == 14) return true;
    return multishot and switch (variant) {
        0, 1, 3, 10, 11, 14 => true,
        else => false,
    };
}

fn fuzzBodySend(
    harness: *Harness,
    token: reactor.OperationToken,
    length: usize,
    variant: u8,
) !void {
    if (variant & 0x03 == 3) {
        _ = try harness.complete(token, .{ .failure = .broken_pipe }, false);
        return;
    }
    const count = switch (variant & 0x03) {
        0 => 1,
        1 => @max(1, length / 2),
        2 => length,
        else => unreachable,
    };
    _ = try harness.complete(
        token,
        .{ .success = .{ .send = @intCast(count) } },
        false,
    );
}

fn fuzzBodyTimeout(
    harness: *Harness,
    token: reactor.OperationToken,
    timeout: reactor.Timeout,
    variant: u8,
) !void {
    if (variant & 0x03 == 3) {
        _ = try harness.complete(token, .{ .failure = .canceled }, false);
        return;
    }
    harness.now_ns = @max(harness.now_ns, timeout.deadline_ns);
    _ = try harness.complete(token, .{ .success = .{ .timeout = {} } }, false);
}

fn fuzzBodyCancel(
    harness: *Harness,
    token: reactor.OperationToken,
    cancel: reactor.Cancel,
    variant: u8,
) !void {
    const canceled = variant & 1 == 0 and harness.io.operation(cancel.target) != null;
    _ = try harness.complete(token, .{ .success = .{ .cancel = if (canceled)
        .canceled
    else
        .not_found } }, false);
    if (!canceled or harness.io.operation(cancel.target) == null) return;
    _ = try harness.complete(cancel.target, .{ .failure = .canceled }, false);
}

fn expectFuzzDriverQuiescent(harness: *const Harness) !void {
    try std.testing.expectEqual(@as(u16, 0), harness.io.activeCount());
    try std.testing.expectEqual(@as(u16, 0), harness.io.pendingCompletionCount());
    try std.testing.expectEqual(@as(u16, 0), harness.io.borrowedCount());
    try std.testing.expectEqual(
        test_limits.connection_slots,
        harness.storage.connection_pool.available(),
    );
    try std.testing.expectEqual(
        test_limits.request_slots,
        harness.storage.request_pool.available(),
    );
    try std.testing.expectEqual(
        test_limits.body_workspace_slots,
        harness.storage.bodyWorkspaceAvailable(),
    );
    try std.testing.expectEqual(
        harness.state.after_calls,
        harness.state.completed + harness.state.aborted,
    );
}

test "fixed body driver bounded state transitions fuzz" {
    try std.testing.fuzz({}, fuzzFixedBodyDriver, .{
        .corpus = &fixed_body_driver_fuzz_corpus,
    });
}

const fixed_body_driver_fuzz_corpus = struct {
    const fragmented = fuzz_support.smithInput("\x02\x04\x12\xff");
    const expect_partial = fuzz_support.smithInput("\x09\x10\x05\x12\x12\xff");
    const premature_eof = fuzz_support.smithInput("\x08\x06\x12\xff");
    const inactivity_timeout = fuzz_support.smithInput("\x08\x20\x12\xff");
    const send_failure = fuzz_support.smithInput("\x03\x13\xff");
    const paused_receive = fuzz_support.smithInput("\x08\x07\x50\x04\x12\xff");
    const stop_mid_body = fuzz_support.smithInput("\x02\xff");
    const delayed_control = fuzz_support.smithInput("\x01\x12\x00\x13");
    const partial_continue_stop = fuzz_support.smithInput("\x01\x10\xff");
    const partial_continue_timeout = fuzz_support.smithInput("\x01\x10\x20");
    const failed_continue = fuzz_support.smithInput("\x01\x13");
    const delayed_control_stop = fuzz_support.smithInput("\x01\x12\x00\xff");
    const delayed_control_timeout = fuzz_support.smithInput("\x01\x12\x00\x20");
    const illegal_one_shot_more = fuzz_support.smithInput("\x0e\xff");
    const generated_deadline = fuzz_support.smithInput(
        "\x70\x80\x66\x50\x35\x0d\x1e\x05\x2b\x84\xc7\x21\x00\xf6\x5b\xc3" ++
            "\x7c\xec\xde\x7a\x4a\xd8\xfc\xfd\xf0\x58\x3b\x63\x5f\x34\xab\x58" ++
            "\xa1\x4d\x45\x56\x94\x08\xd8\xf7\x9f\xa5\xf9\x51\x35\x80\x1e\x06" ++
            "\x2e\x3e\x9d\x5e\xcc\x89\xc3\x9c\x0d\x82\xd9\xfc\xc9\x5a\x06",
    );
    const generated_retarget = fuzz_support.smithInput(
        "\xa2\xeb\xb2\x8e\x80\x86\xf3\xdc\x15\x80\x98\x27\x28\x41",
    );

    const values = [_][]const u8{
        &fragmented,
        &expect_partial,
        &premature_eof,
        &inactivity_timeout,
        &send_failure,
        &paused_receive,
        &stop_mid_body,
        &delayed_control,
        &partial_continue_stop,
        &partial_continue_timeout,
        &failed_continue,
        &delayed_control_stop,
        &delayed_control_timeout,
        &illegal_one_shot_more,
        &generated_deadline,
        &generated_retarget,
    };
}.values;
