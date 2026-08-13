const upload = @import("../../multipart/upload.zig");
const transaction_types = @import("upload_transaction_types.zig");

pub const Error = error{
    CompletionBeforeSubmission,
    InvalidSlot,
    LaneMismatch,
    OutboxBusy,
    SubmissionMissing,
};

pub fn Tracker(comptime Slot: type, comptime window: usize) type {
    const Public = transaction_types.Types(Slot);

    return struct {
        const Self = @This();

        lifecycle_pending: bool = false,
        lifecycle_request: upload.IoRequest = undefined,
        writes_pending: u16 = 0,
        write_requests: [window]upload.IoRequest = undefined,
        lifecycle_submitted: bool = false,
        writes_submitted: u16 = 0,

        pub fn peek(self: *const Self) ?Public.Submission {
            if (self.lifecycle_pending) return .{
                .lane = .lifecycle,
                .request = self.lifecycle_request,
            };
            if (self.writes_pending == 0) return null;
            const slot: Slot = @intCast(@ctz(self.writes_pending));
            return .{
                .lane = .{ .write = slot },
                .request = self.write_requests[slot],
            };
        }

        pub fn put(
            self: *Self,
            lane: Public.Lane,
            request: upload.IoRequest,
        ) Error!void {
            if (self.pending(lane) or self.submitted(lane)) return error.OutboxBusy;
            switch (lane) {
                .lifecycle => {
                    self.lifecycle_request = request;
                    self.lifecycle_pending = true;
                },
                .write => |slot| {
                    if (!validSlot(slot)) return error.InvalidSlot;
                    self.write_requests[slot] = request;
                    self.writes_pending |= bitFor(slot);
                },
            }
        }

        pub fn mark(self: *Self, lane: Public.Lane) Error!void {
            if (!self.pending(lane)) {
                return if (self.hasUnsubmitted())
                    error.LaneMismatch
                else
                    error.SubmissionMissing;
            }
            if (self.submitted(lane)) return error.LaneMismatch;
            switch (lane) {
                .lifecycle => {
                    self.lifecycle_pending = false;
                    self.lifecycle_submitted = true;
                },
                .write => |slot| {
                    if (!validSlot(slot)) return error.InvalidSlot;
                    self.writes_pending &= ~bitFor(slot);
                    self.writes_submitted |= bitFor(slot);
                },
            }
        }

        pub fn takeCompletion(self: *Self, lane: Public.Lane) Error!void {
            if (self.pending(lane)) return error.CompletionBeforeSubmission;
            if (!self.submitted(lane)) return error.LaneMismatch;
            switch (lane) {
                .lifecycle => self.lifecycle_submitted = false,
                .write => |slot| self.writes_submitted &= ~bitFor(slot),
            }
        }

        pub fn takeUnsubmitted(self: *Self) ?Public.Submission {
            const submission = self.peek() orelse return null;
            switch (submission.lane) {
                .lifecycle => self.lifecycle_pending = false,
                .write => |slot| self.writes_pending &= ~bitFor(slot),
            }
            return submission;
        }

        pub fn hasUnsubmitted(self: *const Self) bool {
            return self.lifecycle_pending or self.writes_pending != 0;
        }

        pub fn hasSubmitted(self: *const Self) bool {
            return self.lifecycle_submitted or self.writes_submitted != 0;
        }

        fn pending(self: *const Self, lane: Public.Lane) bool {
            return switch (lane) {
                .lifecycle => self.lifecycle_pending,
                .write => |slot| validSlot(slot) and
                    self.writes_pending & bitFor(slot) != 0,
            };
        }

        fn submitted(self: *const Self, lane: Public.Lane) bool {
            return switch (lane) {
                .lifecycle => self.lifecycle_submitted,
                .write => |slot| validSlot(slot) and
                    self.writes_submitted & bitFor(slot) != 0,
            };
        }

        fn validSlot(slot: Slot) bool {
            return @as(usize, slot) < window;
        }

        fn bitFor(slot: Slot) u16 {
            return @as(u16, 1) << slot;
        }
    };
}
