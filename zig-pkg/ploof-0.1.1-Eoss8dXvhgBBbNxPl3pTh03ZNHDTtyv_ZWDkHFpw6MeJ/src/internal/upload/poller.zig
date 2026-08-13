const std = @import("std");
const io = @import("../../upload_io.zig");

pub const SubmitError = error{ Poisoned, RequestAlreadyPending, InvalidRequest };
pub const ResumeError = error{
    Poisoned,
    CompletionWithoutRequest,
    CompletionKindMismatch,
    CompletionOverflow,
    InvalidSuccess,
};

pub const CompletionStep = union(enum) {
    retry: io.IoRequest,
    deliver: io.IoCompletion,
};

pub const Poller = struct {
    pending_request: ?io.IoRequest = null,
    write_completed: u32 = 0,
    poisoned: bool = false,

    pub fn submit(self: *Poller, request: io.IoRequest) SubmitError!void {
        if (self.poisoned) return error.Poisoned;
        if (self.pending_request != null) return error.RequestAlreadyPending;
        if (request.validate() != null) return error.InvalidRequest;
        self.pending_request = request;
    }

    pub fn complete(self: *Poller, completion: io.IoCompletion) ResumeError!CompletionStep {
        if (self.poisoned) return error.Poisoned;
        const request = self.pending_request orelse
            return self.poison(error.CompletionWithoutRequest);
        switch (completion) {
            .success => |success| {
                if (std.meta.activeTag(success) != std.meta.activeTag(request)) {
                    return self.poison(error.CompletionKindMismatch);
                }
                if (success.validate() != null) return self.poison(error.InvalidSuccess);
                if (completionOverflow(request, success)) {
                    return self.poison(error.CompletionOverflow);
                }
                if (self.retryShortWrite(request, success)) |retry| {
                    return .{ .retry = retry };
                }
            },
            .failure => {},
        }
        const deliver = deliveredCompletion(self.write_completed, completion);
        self.pending_request = null;
        self.write_completed = 0;
        return .{ .deliver = deliver };
    }

    pub fn pendingRequest(self: *const Poller) ?io.IoRequest {
        return self.pending_request;
    }

    pub fn pendingKind(self: *const Poller) ?io.IoKind {
        const request = self.pending_request orelse return null;
        return std.meta.activeTag(request);
    }

    pub fn isPoisoned(self: *const Poller) bool {
        return self.poisoned;
    }

    pub fn ownershipProven(self: *const Poller) bool {
        return !self.poisoned;
    }

    pub fn abandonPending(self: *Poller) bool {
        if (self.poisoned or self.pending_request == null) return false;
        self.pending_request = null;
        self.write_completed = 0;
        return true;
    }

    pub fn invalidateOwnership(self: *Poller) void {
        self.pending_request = null;
        self.write_completed = 0;
        self.poisoned = true;
    }

    fn retryShortWrite(self: *Poller, request: io.IoRequest, success: io.IoSuccess) ?io.IoRequest {
        const written = switch (success) {
            .write => |value| value,
            else => return null,
        };
        const write = request.write;
        self.write_completed = std.math.add(u32, self.write_completed, written) catch {
            unreachable;
        };
        if (written == write.bytes.len) return null;
        const retry = io.IoRequest{ .write = .{
            .file = write.file,
            .bytes = write.bytes[written..],
            .offset = write.offset + written,
        } };
        self.pending_request = retry;
        return retry;
    }

    fn poison(self: *Poller, problem: ResumeError) ResumeError {
        self.invalidateOwnership();
        return problem;
    }
};

fn completionOverflow(request: io.IoRequest, success: io.IoSuccess) bool {
    return switch (success) {
        .write => |written| switch (request) {
            .write => |write| written > write.bytes.len,
            else => unreachable,
        },
        else => false,
    };
}

fn deliveredCompletion(write_completed: u32, completion: io.IoCompletion) io.IoCompletion {
    return switch (completion) {
        .success => |success| switch (success) {
            .write => .{ .success = .{ .write = write_completed } },
            else => completion,
        },
        .failure => completion,
    };
}
