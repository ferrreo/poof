const upload_finalizer = @import("../upload/finalizer.zig");
const transaction_lanes = @import("upload_transaction_lanes.zig");

pub inline fn readyForCommit(self: anytype) bool {
    return self.phase == .collecting and self.active == null and
        self.blocked_wait == null and self.lanes.peek() == null and
        !self.lanes.hasSubmitted() and
        self.lifecycle.quiescent() and self.window.quiescent();
}

pub inline fn laneFailure(
    self: anytype,
    problem: transaction_lanes.Error,
    lane: anytype,
) error{TransactionFatal} {
    const Fatal = @typeInfo(@TypeOf(self.fatal_state)).optional.child;
    const FatalClass = @FieldType(Fatal, "class");
    const class: FatalClass = switch (problem) {
        error.CompletionBeforeSubmission => .completion_before_submission,
        error.InvalidSlot => .invalid_slot,
        error.LaneMismatch => .lane_mismatch,
        error.OutboxBusy => .outbox_busy,
        error.SubmissionMissing => .submission_missing,
    };
    return fail(self, class, activeEntry(self), lane);
}

pub inline fn guard(self: anytype) error{TransactionFatal}!void {
    if (self.anchor) |anchor| {
        if (anchor != self) {
            return fail(self, .moved_after_record, null, null);
        }
    }
    if (self.fatal_state != null) return error.TransactionFatal;
}

pub inline fn fail(
    self: anytype,
    class: anytype,
    entry_index: ?u16,
    lane: anytype,
) error{TransactionFatal} {
    latch(self, class, entry_index, lane, null);
    return error.TransactionFatal;
}

pub inline fn latch(
    self: anytype,
    class: anytype,
    entry_index: ?u16,
    lane: anytype,
    finalizer_fatal: ?upload_finalizer.Fatal,
) void {
    if (self.fatal_state == null) {
        self.fatal_state = .{
            .class = class,
            .entry_index = entry_index,
            .lane = lane,
            .finalizer = finalizer_fatal,
        };
    }
    self.phase = .fatal;
}

pub inline fn activeEntry(self: anytype) ?u16 {
    return if (self.active) |active| active.entry_index else null;
}
