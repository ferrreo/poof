const std = @import("std");

const io_uring_backend_upload = @import("backend_upload.zig");
const io_uring_errors = @import("errors.zig");

pub const Error = error{ InvalidState, SubmissionFailed };

pub const Outcome = union(enum) {
    retry_without_progress,
    retry_partial: u32,
    complete: u32,
};

pub fn submit(
    ring: anytype,
    queued_count: *u32,
    active_count: *u32,
    submission_retry_pending: *bool,
) Error!Outcome {
    const expected = queued_count.*;
    const submitted = ring.submit() catch |err| {
        if (!io_uring_errors.retryableFlushError(err)) {
            return error.SubmissionFailed;
        }
        if (ring.sq_ready() != expected) return error.InvalidState;
        submission_retry_pending.* = true;
        return .retry_without_progress;
    };
    if (submitted > expected) return error.InvalidState;
    active_count.* = std.math.add(u32, active_count.*, submitted) catch {
        return error.InvalidState;
    };
    queued_count.* -= submitted;
    submission_retry_pending.* = queued_count.* != 0;
    if (submission_retry_pending.*) return .{ .retry_partial = submitted };
    return .{ .complete = submitted };
}

pub fn releaseStableStorage(
    outcome: Outcome,
    queued_timeouts: *u16,
    upload_metadata: anytype,
) void {
    switch (outcome) {
        .complete => {
            queued_timeouts.* = 0;
            upload_metadata.reset();
        },
        .retry_without_progress, .retry_partial => {},
    }
}

const SubmitStep = union(enum) {
    submitted: u32,
    signal_interrupt,
    system_resources,
};

const FakeRing = struct {
    steps: []const SubmitStep,
    sq_ready_count: u32,
    step_index: usize = 0,

    fn submit(self: *FakeRing) !u32 {
        const step = self.steps[self.step_index];
        self.step_index += 1;
        return switch (step) {
            .submitted => |count| count,
            .signal_interrupt => error.SignalInterrupt,
            .system_resources => error.SystemResources,
        };
    }

    fn sq_ready(self: *const FakeRing) u32 {
        return self.sq_ready_count;
    }
};

const UploadMetadata = io_uring_backend_upload.Metadata(true, 2);

const StableStorage = struct {
    timeout_storage: [2]std.os.linux.kernel_timespec = .{
        .{ .sec = 7, .nsec = 11 },
        .{ .sec = 13, .nsec = 17 },
    },
    queued_timeouts: u16 = 1,
    upload_metadata: UploadMetadata = initialUploadMetadata(),
};

const StorageSnapshot = struct {
    timeout_storage: [2]std.os.linux.kernel_timespec,
    open_how: io_uring_backend_upload.OpenHow,
    link_path: io_uring_backend_upload.AnonymousLinkPath,
    timeout_address: usize,
    open_address: usize,
    link_address: usize,
};

fn initialUploadMetadata() UploadMetadata {
    var metadata = UploadMetadata{};
    metadata.open_hows[0] = .{ .flags = 19, .mode = 23, .resolve = 29 };
    metadata.link_paths[0] = [_]u8{31} ** metadata.link_paths[0].len;
    metadata.open_count = 1;
    metadata.link_count = 1;
    return metadata;
}

test "partial submission retains stable storage until final retry succeeds" {
    const steps = [_]SubmitStep{ .{ .submitted = 1 }, .{ .submitted = 2 } };
    var ring = FakeRing{ .steps = &steps, .sq_ready_count = 0 };
    var queued: u32 = 3;
    var active: u32 = 0;
    var retry_pending = false;
    var storage = StableStorage{};
    const before = snapshot(&storage);

    const partial = try submit(&ring, &queued, &active, &retry_pending);
    releaseStableStorage(partial, &storage.queued_timeouts, &storage.upload_metadata);
    try std.testing.expectEqual(Outcome{ .retry_partial = 1 }, partial);
    try expectRetained(&storage, before);
    try std.testing.expectEqual(@as(u32, 2), queued);
    try std.testing.expectEqual(@as(u32, 1), active);
    try std.testing.expect(retry_pending);

    // The submitted operation can retire before the remaining SQEs are retried.
    active -= 1;
    const complete = try submit(&ring, &queued, &active, &retry_pending);
    releaseStableStorage(complete, &storage.queued_timeouts, &storage.upload_metadata);
    try std.testing.expectEqual(Outcome{ .complete = 2 }, complete);
    try std.testing.expectEqual(@as(u32, 0), queued);
    try std.testing.expectEqual(@as(u32, 2), active);
    try std.testing.expect(!retry_pending);
    try std.testing.expectEqual(@as(u16, 0), storage.queued_timeouts);
    try std.testing.expectEqual(@as(u16, 0), storage.upload_metadata.open_count);
    try std.testing.expectEqual(@as(u16, 0), storage.upload_metadata.link_count);
}

test "signal interruption retains stable storage for exact retry" {
    const steps = [_]SubmitStep{ .signal_interrupt, .{ .submitted = 2 } };
    var ring = FakeRing{ .steps = &steps, .sq_ready_count = 2 };
    var queued: u32 = 2;
    var active: u32 = 0;
    var retry_pending = false;
    var storage = StableStorage{};
    const before = snapshot(&storage);

    const interrupted = try submit(&ring, &queued, &active, &retry_pending);
    releaseStableStorage(interrupted, &storage.queued_timeouts, &storage.upload_metadata);
    try std.testing.expectEqual(Outcome.retry_without_progress, interrupted);
    try expectRetained(&storage, before);
    try std.testing.expectEqual(@as(u32, 2), queued);
    try std.testing.expectEqual(@as(u32, 0), active);
    try std.testing.expect(retry_pending);

    const complete = try submit(&ring, &queued, &active, &retry_pending);
    releaseStableStorage(complete, &storage.queued_timeouts, &storage.upload_metadata);
    try std.testing.expectEqual(Outcome{ .complete = 2 }, complete);
    try std.testing.expectEqual(@as(u16, 0), storage.queued_timeouts);
    try std.testing.expectEqual(@as(u16, 0), storage.upload_metadata.open_count);
    try std.testing.expectEqual(@as(u16, 0), storage.upload_metadata.link_count);
}

test "nonretryable submission error leaves all batch state unchanged" {
    const steps = [_]SubmitStep{.system_resources};
    var ring = FakeRing{ .steps = &steps, .sq_ready_count = 2 };
    var queued: u32 = 2;
    var active: u32 = 0;
    var retry_pending = false;
    const storage = StableStorage{};

    try std.testing.expectError(
        error.SubmissionFailed,
        submit(&ring, &queued, &active, &retry_pending),
    );
    try std.testing.expectEqual(@as(u32, 2), queued);
    try std.testing.expectEqual(@as(u32, 0), active);
    try std.testing.expect(!retry_pending);
    try std.testing.expectEqual(@as(u16, 1), storage.queued_timeouts);
    try std.testing.expectEqual(@as(u16, 1), storage.upload_metadata.open_count);
    try std.testing.expectEqual(@as(u16, 1), storage.upload_metadata.link_count);
}

test "observed interruption progress and oversubmit fail without state mutation" {
    const Case = struct { step: SubmitStep, sq_ready: u32 };
    const cases = [_]Case{
        .{ .step = .signal_interrupt, .sq_ready = 1 },
        .{ .step = .{ .submitted = 3 }, .sq_ready = 0 },
    };
    for (cases) |case| {
        const steps = [_]SubmitStep{case.step};
        var ring = FakeRing{ .steps = &steps, .sq_ready_count = case.sq_ready };
        var queued: u32 = 2;
        var active: u32 = 1;
        var retry_pending = false;

        try std.testing.expectError(
            error.InvalidState,
            submit(&ring, &queued, &active, &retry_pending),
        );
        try std.testing.expectEqual(@as(u32, 2), queued);
        try std.testing.expectEqual(@as(u32, 1), active);
        try std.testing.expect(!retry_pending);
    }
}

fn snapshot(storage: *const StableStorage) StorageSnapshot {
    return .{
        .timeout_storage = storage.timeout_storage,
        .open_how = storage.upload_metadata.open_hows[0],
        .link_path = storage.upload_metadata.link_paths[0],
        .timeout_address = @intFromPtr(&storage.timeout_storage[0]),
        .open_address = @intFromPtr(&storage.upload_metadata.open_hows[0]),
        .link_address = @intFromPtr(&storage.upload_metadata.link_paths[0]),
    };
}

fn expectRetained(storage: *const StableStorage, before: StorageSnapshot) !void {
    try std.testing.expectEqualDeep(before.timeout_storage, storage.timeout_storage);
    try std.testing.expectEqual(before.open_how, storage.upload_metadata.open_hows[0]);
    try std.testing.expectEqual(before.link_path, storage.upload_metadata.link_paths[0]);
    try std.testing.expectEqual(before.timeout_address, @intFromPtr(&storage.timeout_storage[0]));
    try std.testing.expectEqual(
        before.open_address,
        @intFromPtr(&storage.upload_metadata.open_hows[0]),
    );
    try std.testing.expectEqual(
        before.link_address,
        @intFromPtr(&storage.upload_metadata.link_paths[0]),
    );
    try std.testing.expectEqual(@as(u16, 1), storage.queued_timeouts);
    try std.testing.expectEqual(@as(u16, 1), storage.upload_metadata.open_count);
    try std.testing.expectEqual(@as(u16, 1), storage.upload_metadata.link_count);
}
