const std = @import("std");
const upload = @import("../../multipart/upload.zig");
const upload_finalizer = @import("../upload/finalizer.zig");
const upload_window = @import("../upload/window.zig");

pub const FailureKind = enum(u1) { sink, fatal };

pub fn recoverableWindowFailure(mode: upload_window.Mode) bool {
    return mode == .failed;
}

pub fn Types(comptime Slot: type) type {
    return struct {
        pub const Lane = union(enum) {
            lifecycle,
            write: Slot,
        };

        pub const Submission = struct {
            lane: Lane,
            request: upload.IoRequest,
        };

        pub const FinalizationFlow = enum(u8) {
            progress,
            paused,
            complete,
        };

        pub const FatalClass = enum(u8) {
            moved_after_record,
            phase_mismatch,
            invalid_entry,
            invalid_occurrence,
            variant_mismatch,
            event_mismatch,
            offset_mismatch,
            byte_count_mismatch,
            resume_mismatch,
            outbox_busy,
            submission_missing,
            lane_mismatch,
            completion_before_submission,
            invalid_slot,
            lifecycle_invariant,
            window_invariant,
            layout_invariant,
            finalizer_invariant,
            finalizer_fatal,
        };

        pub const Fatal = struct {
            class: FatalClass,
            entry_index: ?u16 = null,
            lane: ?Lane = null,
            finalizer: ?upload_finalizer.Fatal = null,
        };
    };
}

test "only sink-proven window failures are recoverable" {
    try std.testing.expect(recoverableWindowFailure(.failed));
    try std.testing.expect(!recoverableWindowFailure(.poisoned));
    try std.testing.expect(!recoverableWindowFailure(.canceled));
}
