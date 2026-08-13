const reactor = @import("../reactor.zig");

pub const Winner = enum(u2) { none, target, deadline };
pub const FailureKind = enum(u2) { deadline, timer_failure, clock_overflow };
pub const Action = enum(u2) { none, cancel_timeout, cancel_target };

pub fn Race(comptime Cookie: type, comptime Delivery: type) type {
    return struct {
        const Self = @This();

        active: bool = false,
        cookie: Cookie = undefined,
        target_token: ?reactor.OperationToken = null,
        timeout_token: ?reactor.OperationToken = null,
        target_cancel_token: ?reactor.OperationToken = null,
        timeout_cancel_token: ?reactor.OperationToken = null,
        timeout_cancel_submitted: bool = false,
        delivery: ?Delivery = null,
        winner: Winner = .none,
        failure_kind: ?FailureKind = null,
        deadline_ns: u64 = 0,

        pub const Outcome = union(enum) {
            target: Delivery,
            deadline: struct {
                cookie: Cookie,
                kind: FailureKind,
                deadline_ns: u64,
                delivery: Delivery,
            },
        };

        pub fn begin(
            self: *Self,
            cookie: Cookie,
            target: reactor.OperationToken,
            timeout: reactor.OperationToken,
            deadline_ns: u64,
        ) !void {
            if (self.active or deadline_ns == 0) return error.StateInvariant;
            self.* = .{
                .active = true,
                .cookie = cookie,
                .target_token = target,
                .timeout_token = timeout,
                .deadline_ns = deadline_ns,
            };
        }

        pub fn observeTransport(
            self: *Self,
            token: reactor.OperationToken,
            delivery: ?Delivery,
        ) !Action {
            if (!self.active) return error.StateInvariant;
            if (matches(self.target_token, token)) {
                self.target_token = null;
            } else if (matches(self.target_cancel_token, token)) {
                self.target_cancel_token = null;
            } else {
                return error.InvalidCompletion;
            }
            if (delivery) |value| {
                if (self.delivery != null) return error.InvalidCompletion;
                self.delivery = value;
                if (self.winner == .none) {
                    self.winner = .target;
                    if (self.timeout_token != null and self.timeout_cancel_token == null) {
                        return .cancel_timeout;
                    }
                }
            }
            return .none;
        }

        pub fn observeTimeout(self: *Self, completion: reactor.Completion) !Action {
            if (!self.active or !matches(self.timeout_token, completion.token)) {
                return error.InvalidCompletion;
            }
            self.timeout_token = null;
            const fired = switch (completion.result) {
                .success => |success| if (success == .timeout)
                    true
                else
                    return error.InvalidCompletion,
                .failure => |failure| if (failure == .canceled)
                    false
                else failure: {
                    self.failure_kind = .timer_failure;
                    break :failure true;
                },
            };
            if (!fired) {
                if (self.winner != .target or !self.timeout_cancel_submitted) {
                    return error.InvalidCompletion;
                }
                return .none;
            }
            self.winner = .deadline;
            if (self.failure_kind == null) self.failure_kind = .deadline;
            if (self.target_token != null and self.target_cancel_token == null) {
                return .cancel_target;
            }
            return .none;
        }

        pub fn observeTimeoutCancel(self: *Self, completion: reactor.Completion) !void {
            if (!self.active or !matches(self.timeout_cancel_token, completion.token)) {
                return error.InvalidCompletion;
            }
            switch (completion.result) {
                .success => |success| if (success != .cancel) return error.InvalidCompletion,
                .failure => return error.BackendFailure,
            }
            self.timeout_cancel_token = null;
        }

        pub fn armTargetCancel(self: *Self, token: reactor.OperationToken) !void {
            if (!self.active or self.target_token == null or self.target_cancel_token != null) {
                return error.StateInvariant;
            }
            self.target_cancel_token = token;
        }

        pub fn armTimeoutCancel(self: *Self, token: reactor.OperationToken) !void {
            if (!self.active or self.timeout_token == null or self.timeout_cancel_token != null) {
                return error.StateInvariant;
            }
            self.timeout_cancel_token = token;
            self.timeout_cancel_submitted = true;
        }

        pub fn takeOutcome(self: *Self) !?Outcome {
            if (!self.active or self.target_token != null or self.timeout_token != null or
                self.target_cancel_token != null or self.timeout_cancel_token != null)
            {
                return null;
            }
            const delivery = self.delivery orelse return error.StateInvariant;
            const outcome: Outcome = switch (self.winner) {
                .target => .{ .target = delivery },
                .deadline => .{ .deadline = .{
                    .cookie = self.cookie,
                    .kind = self.failure_kind orelse return error.StateInvariant,
                    .deadline_ns = self.deadline_ns,
                    .delivery = delivery,
                } },
                .none => return error.StateInvariant,
            };
            self.* = .{};
            return outcome;
        }

        pub fn controlPending(self: *const Self) u32 {
            return @as(u32, @intFromBool(self.timeout_token != null)) +
                @as(u32, @intFromBool(self.timeout_cancel_token != null));
        }

        pub fn contains(self: *const Self, token: reactor.OperationToken) bool {
            return matches(self.target_token, token) or matches(self.timeout_token, token) or
                matches(self.target_cancel_token, token) or
                matches(self.timeout_cancel_token, token);
        }

        fn matches(candidate: ?reactor.OperationToken, actual: reactor.OperationToken) bool {
            return if (candidate) |token| token.eql(actual) else false;
        }
    };
}

const std = @import("std");

test "target winner settles after timeout and cancel in either order" {
    inline for (.{ false, true }) |cancel_first| {
        var race = Race(u8, u8){};
        const target = try testToken(.file_open, 1);
        const timeout = try testToken(.timeout, 2);
        const cancel = try testToken(.cancel, 3);
        try race.begin(4, target, timeout, 99);
        try std.testing.expectEqual(
            Action.cancel_timeout,
            try race.observeTransport(target, 7),
        );
        try race.armTimeoutCancel(cancel);
        try std.testing.expectEqual(@as(u32, 2), race.controlPending());
        const timeout_completion = reactor.Completion{
            .token = timeout,
            .result = .{ .failure = .canceled },
            .more = false,
        };
        const cancel_completion = reactor.Completion{
            .token = cancel,
            .result = .{ .success = .{ .cancel = .canceled } },
            .more = false,
        };
        if (cancel_first) {
            try race.observeTimeoutCancel(cancel_completion);
            try std.testing.expectEqual(Action.none, try race.observeTimeout(timeout_completion));
        } else {
            try std.testing.expectEqual(Action.none, try race.observeTimeout(timeout_completion));
            try race.observeTimeoutCancel(cancel_completion);
        }
        const outcome = (try race.takeOutcome()).?;
        try std.testing.expectEqual(@as(u8, 7), outcome.target);
        try std.testing.expect(!race.active);
    }
}

test "deadline winner settles after target and cancel in either order" {
    inline for (.{ false, true }) |cancel_first| {
        var race = Race(u8, u8){};
        const target = try testToken(.file_open, 4);
        const timeout = try testToken(.timeout, 5);
        const cancel = try testToken(.upload_cancel, 6);
        try race.begin(8, target, timeout, 101);
        try std.testing.expectEqual(
            Action.cancel_target,
            try race.observeTimeout(.{
                .token = timeout,
                .result = .{ .success = .{ .timeout = {} } },
                .more = false,
            }),
        );
        try race.armTargetCancel(cancel);
        if (cancel_first) {
            try std.testing.expectEqual(Action.none, try race.observeTransport(cancel, null));
            try std.testing.expectEqual(Action.none, try race.observeTransport(target, 9));
        } else {
            try std.testing.expectEqual(Action.none, try race.observeTransport(target, null));
            try std.testing.expectEqual(Action.none, try race.observeTransport(cancel, 9));
        }
        const outcome = (try race.takeOutcome()).?;
        try std.testing.expectEqual(@as(u8, 8), outcome.deadline.cookie);
        try std.testing.expectEqual(FailureKind.deadline, outcome.deadline.kind);
        try std.testing.expectEqual(@as(u64, 101), outcome.deadline.deadline_ns);
        try std.testing.expect(!race.active);
    }
}

test "timer failure is a deadline winner and still retires target" {
    var race = Race(u8, u8){};
    const target = try testToken(.file_stat, 7);
    const timeout = try testToken(.timeout, 8);
    const cancel = try testToken(.upload_cancel, 9);
    try race.begin(11, target, timeout, 103);
    try std.testing.expectEqual(
        Action.cancel_target,
        try race.observeTimeout(.{
            .token = timeout,
            .result = .{ .failure = .backend_failure },
            .more = false,
        }),
    );
    try race.armTargetCancel(cancel);
    _ = try race.observeTransport(cancel, null);
    _ = try race.observeTransport(target, 12);
    const outcome = (try race.takeOutcome()).?;
    try std.testing.expectEqual(FailureKind.timer_failure, outcome.deadline.kind);
}

fn testToken(kind: reactor.OperationKind, sequence: u16) !reactor.OperationToken {
    return reactor.OperationToken.init(.{
        .kind = kind,
        .worker_index = 0,
        .slot_index = reactor.upload_runtime_control_slot,
        .slot_generation = 1,
        .sequence = sequence,
    });
}

test {
    std.testing.refAllDecls(@This());
}
