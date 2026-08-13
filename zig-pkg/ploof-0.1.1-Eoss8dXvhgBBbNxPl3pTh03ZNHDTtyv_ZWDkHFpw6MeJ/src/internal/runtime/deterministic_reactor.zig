const std = @import("std");
const reactor = @import("reactor.zig");

pub const SubmitError = error{
    BackendClosed,
    InvalidSubmission,
    DuplicateToken,
    SubmissionCapacityExhausted,
};

pub const CompleteError = error{
    BackendClosed,
    UnknownToken,
    CompletionAfterTerminal,
    InvalidCompletion,
    CompletionCapacityExhausted,
    BorrowCapacityExhausted,
    DuplicateBorrow,
};

pub const TimeError = error{TimeOverflow};

pub const RecycleError = error{
    BackendClosed,
    InvalidBorrow,
    StaleBorrow,
};

pub const AbortError = error{BackendClosed};
pub const DiscardError = error{DiscardFailed};

/// Test-only bounded completion scheduler for production state machines.
pub fn DeterministicReactor(comptime capacity: u16) type {
    if (capacity == 0) @compileError("deterministic reactor capacity must be nonzero");

    return struct {
        const Self = @This();

        const BorrowRecord = struct {
            identity: reactor.BorrowedReceiveIdentity,
            pointer: usize,
            length: usize,
        };

        active: [capacity]reactor.Submission = undefined,
        active_terminal_queued: [capacity]bool = undefined,
        completions: [capacity]reactor.Completion = undefined,
        borrows: [capacity]BorrowRecord = undefined,
        buffer_generations: [capacity]u16 = [_]u16{1} ** capacity,
        active_count: u16 = 0,
        completion_head: u16 = 0,
        completion_count: u16 = 0,
        borrow_count: u16 = 0,
        recycled_count: u64 = 0,
        discarded_count: u64 = 0,
        fail_next_discard: bool = false,
        fail_next_submit: bool = false,
        flush_retries_remaining: u16 = 0,
        monotonic_ns: u64 = 1,
        aborted: bool = false,
        abort_ownership_proven: bool = true,

        pub fn submit(self: *Self, value: reactor.Submission) SubmitError!void {
            if (self.aborted) return error.BackendClosed;
            if (value.validate() != null) return error.InvalidSubmission;
            if (self.find(value.token) != null) return error.DuplicateToken;
            if (self.fail_next_submit) {
                self.fail_next_submit = false;
                return error.SubmissionCapacityExhausted;
            }
            if (self.active_count == capacity) return error.SubmissionCapacityExhausted;
            self.active[self.active_count] = value;
            self.active_terminal_queued[self.active_count] = false;
            self.active_count += 1;
        }

        pub fn complete(
            self: *Self,
            operation_token: reactor.OperationToken,
            result: reactor.CompletionResult,
            more: bool,
        ) CompleteError!void {
            if (self.aborted) return error.BackendClosed;
            const active_index = self.find(operation_token) orelse return error.UnknownToken;
            if (self.active_terminal_queued[active_index]) {
                return error.CompletionAfterTerminal;
            }
            const completion = reactor.Completion{
                .token = operation_token,
                .result = result,
                .more = more,
            };
            if (completion.validate() != null) {
                switch (completion.result) {
                    .success => |success| if (success == .accept) {
                        self.discarded_count +|= 1;
                    },
                    .failure => {},
                }
                return error.InvalidCompletion;
            }
            if (self.completion_count == capacity) {
                return error.CompletionCapacityExhausted;
            }
            if (borrowedReceive(completion)) |borrowed| try self.recordBorrow(borrowed);
            const tail = (self.completion_head + self.completion_count) % capacity;
            self.completions[tail] = completion;
            self.completion_count += 1;
            if (!more) self.active_terminal_queued[active_index] = true;
        }

        pub fn nextCompletion(self: *Self) ?reactor.Completion {
            if (self.completion_count == 0) return null;
            const completion = self.completions[self.completion_head];
            self.completion_head = (self.completion_head + 1) % capacity;
            self.completion_count -= 1;
            if (!completion.more) {
                const active_index = self.find(completion.token) orelse unreachable;
                std.debug.assert(self.active_terminal_queued[active_index]);
                self.removeActive(active_index);
            }
            return completion;
        }

        pub fn activeSubmission(self: *const Self, index: u16) ?reactor.Submission {
            if (index >= self.active_count) return null;
            return self.active[index];
        }

        pub fn operation(
            self: *const Self,
            operation_token: reactor.OperationToken,
        ) ?reactor.Operation {
            const index = self.find(operation_token) orelse return null;
            return self.active[index].operation;
        }

        pub fn activeCount(self: *const Self) u16 {
            return self.active_count;
        }

        pub fn tokenActive(
            self: *const Self,
            operation_token: reactor.OperationToken,
        ) bool {
            return self.find(operation_token) != null;
        }

        pub fn flush(
            self: *Self,
        ) error{ BackendClosed, FatalInvariant, SubmissionFailed, SubmissionRetry }!u32 {
            if (self.aborted) return error.BackendClosed;
            if (self.flush_retries_remaining != 0) {
                self.flush_retries_remaining -= 1;
                return error.SubmissionRetry;
            }
            return 0;
        }

        pub fn injectFlushRetries(self: *Self, count: u16) void {
            self.flush_retries_remaining = count;
        }

        pub fn injectDiscardFailure(self: *Self) void {
            self.fail_next_discard = true;
        }

        pub fn injectSubmitFailure(self: *Self) void {
            self.fail_next_submit = true;
        }

        pub fn injectUnprovenAbort(self: *Self) void {
            self.abort_ownership_proven = false;
        }

        pub fn queuedCount(self: *const Self) u32 {
            _ = self;
            return 0;
        }

        pub fn pendingCompletionCount(self: *const Self) u16 {
            return self.completion_count;
        }

        pub fn borrowedCount(self: *const Self) u16 {
            return self.borrow_count;
        }

        pub fn recycledCount(self: *const Self) u64 {
            return self.recycled_count;
        }

        pub fn discardedCount(self: *const Self) u64 {
            return self.discarded_count;
        }

        pub fn discard(self: *Self, socket: reactor.Socket) DiscardError!void {
            _ = socket;
            if (self.fail_next_discard) {
                self.fail_next_discard = false;
                return error.DiscardFailed;
            }
            self.discarded_count +|= 1;
        }

        pub fn recycle(
            self: *Self,
            borrowed: reactor.BorrowedReceive,
        ) RecycleError!void {
            if (self.aborted) return error.BackendClosed;
            if (borrowed.identity.validate() != null or borrowed.bytes.len == 0) {
                return error.InvalidBorrow;
            }
            const index = self.findBorrow(borrowed) orelse return error.StaleBorrow;
            const buffer_index = borrowed.identity.buffer_index;
            self.buffer_generations[buffer_index] = reactor.nextGeneration(
                self.buffer_generations[buffer_index],
            );
            const last = self.borrow_count - 1;
            if (index != last) self.borrows[index] = self.borrows[last];
            self.borrow_count = last;
            self.recycled_count += 1;
        }

        pub fn abort(self: *Self) AbortError!reactor.AbortStatus {
            if (self.aborted) return error.BackendClosed;
            var discarded: u32 = 0;
            var index: u16 = 0;
            while (index < self.completion_count) : (index += 1) {
                const completion_index = (self.completion_head + index) % capacity;
                const completion = self.completions[completion_index];
                switch (completion.result) {
                    .success => |success| switch (success) {
                        .accept => {
                            discarded += 1;
                            self.discarded_count += 1;
                        },
                        else => {},
                    },
                    .failure => {},
                }
            }
            self.active_count = 0;
            self.completion_head = 0;
            self.completion_count = 0;
            self.borrow_count = 0;
            self.fail_next_discard = false;
            self.fail_next_submit = false;
            self.flush_retries_remaining = 0;
            self.aborted = true;
            return .{
                .ownership_proven = self.abort_ownership_proven,
                .accepted_sockets_discarded = discarded,
            };
        }

        pub fn now(self: *const Self) u64 {
            return self.monotonic_ns;
        }

        pub fn advance(self: *Self, nanoseconds: u64) TimeError!void {
            self.monotonic_ns = std.math.add(
                u64,
                self.monotonic_ns,
                nanoseconds,
            ) catch return error.TimeOverflow;
        }

        fn find(self: *const Self, operation_token: reactor.OperationToken) ?u16 {
            for (self.active[0..self.active_count], 0..) |submission_value, index| {
                if (submission_value.token.eql(operation_token)) return @intCast(index);
            }
            return null;
        }

        fn removeActive(self: *Self, index: u16) void {
            std.debug.assert(index < self.active_count);
            const last = self.active_count - 1;
            if (index != last) {
                self.active[index] = self.active[last];
                self.active_terminal_queued[index] = self.active_terminal_queued[last];
            }
            self.active_count = last;
        }

        fn recordBorrow(
            self: *Self,
            borrowed: reactor.BorrowedReceive,
        ) CompleteError!void {
            if (self.borrow_count == capacity) return error.BorrowCapacityExhausted;
            const buffer_index = borrowed.identity.buffer_index;
            if (buffer_index >= capacity or
                borrowed.identity.buffer_generation != self.buffer_generations[buffer_index])
            {
                return error.InvalidCompletion;
            }
            for (self.borrows[0..self.borrow_count]) |record| {
                if (sameBuffer(record.identity, borrowed.identity)) {
                    return error.DuplicateBorrow;
                }
            }
            self.borrows[self.borrow_count] = .{
                .identity = borrowed.identity,
                .pointer = @intFromPtr(borrowed.bytes.ptr),
                .length = borrowed.bytes.len,
            };
            self.borrow_count += 1;
        }

        fn findBorrow(self: *const Self, borrowed: reactor.BorrowedReceive) ?u16 {
            for (self.borrows[0..self.borrow_count], 0..) |record, index| {
                if (record.identity.owner.eql(borrowed.identity.owner) and
                    record.identity.buffer_index == borrowed.identity.buffer_index and
                    record.identity.buffer_generation == borrowed.identity.buffer_generation and
                    record.pointer == @intFromPtr(borrowed.bytes.ptr) and
                    record.length == borrowed.bytes.len)
                {
                    return @intCast(index);
                }
            }
            return null;
        }
    };
}

fn borrowedReceive(completion: reactor.Completion) ?reactor.BorrowedReceive {
    return switch (completion.result) {
        .success => |success| switch (success) {
            .receive => |receive| switch (receive) {
                .bytes => |borrowed| borrowed,
                .end_of_stream => null,
            },
            else => null,
        },
        .failure => null,
    };
}

fn sameBuffer(
    left: reactor.BorrowedReceiveIdentity,
    right: reactor.BorrowedReceiveIdentity,
) bool {
    return left.buffer_index == right.buffer_index;
}

fn testToken(kind: reactor.OperationKind, sequence: u16) reactor.OperationToken {
    return reactor.OperationToken.init(.{
        .kind = kind,
        .worker_index = 0,
        .slot_index = if (kind == .wake) reactor.wake_control_slot else 2,
        .slot_generation = 3,
        .sequence = sequence,
    }) catch unreachable;
}

test "deterministic reactor controls completion order and multishot lifetime" {
    const TestReactor = DeterministicReactor(4);
    var test_reactor = TestReactor{};
    const receive = testToken(.receive, 1);
    const send = testToken(.send, 2);
    try test_reactor.submit(.{
        .token = receive,
        .operation = .{ .receive = .{ .socket = .{ .value = 9 } } },
    });
    try test_reactor.submit(.{
        .token = send,
        .operation = .{ .send = .{ .socket = .{ .value = 9 }, .bytes = "pong" } },
    });

    try test_reactor.complete(send, .{ .success = .{ .send = 4 } }, false);
    const borrowed = reactor.BorrowedReceive{
        .identity = .{
            .owner = try receive.slot(),
            .buffer_index = 1,
            .buffer_generation = 1,
        },
        .bytes = "GET ",
    };
    try test_reactor.complete(
        receive,
        .{ .success = .{ .receive = .{ .bytes = borrowed } } },
        true,
    );
    try std.testing.expectEqual(@as(u16, 2), test_reactor.activeCount());
    try std.testing.expect(test_reactor.nextCompletion().?.token.eql(send));
    try std.testing.expectEqual(@as(u16, 1), test_reactor.activeCount());
    try std.testing.expect(test_reactor.nextCompletion().?.token.eql(receive));
    try std.testing.expect(test_reactor.operation(receive) != null);
    try std.testing.expectEqual(@as(u16, 1), test_reactor.borrowedCount());
    try test_reactor.recycle(borrowed);
    try std.testing.expectEqual(@as(u16, 0), test_reactor.borrowedCount());
    try std.testing.expectEqual(@as(u64, 1), test_reactor.recycledCount());
    try std.testing.expectError(error.StaleBorrow, test_reactor.recycle(borrowed));

    try test_reactor.complete(receive, .{ .failure = .canceled }, false);
    try std.testing.expectEqual(@as(u16, 1), test_reactor.activeCount());
    _ = test_reactor.nextCompletion().?;
    try std.testing.expectEqual(@as(u16, 0), test_reactor.activeCount());
}

test "deterministic reactor bounds queues tokens and virtual time" {
    const TestReactor = DeterministicReactor(1);
    var test_reactor = TestReactor{};
    const receive = testToken(.receive, 1);
    try test_reactor.submit(.{
        .token = receive,
        .operation = .{ .receive = .{
            .socket = .{ .value = 9 },
            .multishot = false,
        } },
    });
    try std.testing.expect(!test_reactor.operation(receive).?.receive.multishot);
    try std.testing.expectError(error.DuplicateToken, test_reactor.submit(.{
        .token = receive,
        .operation = .{ .receive = .{ .socket = .{ .value = 9 } } },
    }));
    try std.testing.expectError(error.SubmissionCapacityExhausted, test_reactor.submit(.{
        .token = testToken(.send, 2),
        .operation = .{ .send = .{ .socket = .{ .value = 9 }, .bytes = "x" } },
    }));
    try std.testing.expectError(
        error.UnknownToken,
        test_reactor.complete(testToken(.send, 2), .{ .success = .{ .send = 1 } }, false),
    );
    try test_reactor.complete(receive, .{ .failure = .canceled }, false);
    try std.testing.expectError(
        error.CompletionAfterTerminal,
        test_reactor.complete(receive, .{ .failure = .canceled }, false),
    );
    try std.testing.expectEqual(@as(u16, 1), test_reactor.activeCount());
    _ = test_reactor.nextCompletion().?;
    try std.testing.expectEqual(@as(u16, 0), test_reactor.activeCount());
    try std.testing.expectEqual(@as(u64, 1), test_reactor.now());
    try test_reactor.advance(9);
    try std.testing.expectEqual(@as(u64, 10), test_reactor.now());
    test_reactor.monotonic_ns = std.math.maxInt(u64);
    try std.testing.expectError(error.TimeOverflow, test_reactor.advance(1));
}

test "deterministic reactor models one-shot event wake" {
    const TestReactor = DeterministicReactor(2);
    var test_reactor = TestReactor{};
    const wake = testToken(.wake, 1);
    try test_reactor.submit(.{
        .token = wake,
        .operation = .{ .wake = .{ .source = .{ .value = 7 } } },
    });
    try std.testing.expectEqual(@as(u64, 7), test_reactor.operation(wake).?.wake.source.value);
    try std.testing.expectError(
        error.InvalidCompletion,
        test_reactor.complete(wake, .{ .success = .{ .wake = {} } }, true),
    );
    try test_reactor.complete(wake, .{ .success = .{ .wake = {} } }, false);
    const completion = test_reactor.nextCompletion().?;
    try std.testing.expect(completion.token.eql(wake));
    try std.testing.expectEqual(@as(u16, 0), test_reactor.activeCount());
}

test "reborrow advances generation and rejects copied stale handles" {
    const TestReactor = DeterministicReactor(2);
    var test_reactor = TestReactor{};
    const receive = testToken(.receive, 1);
    try test_reactor.submit(.{
        .token = receive,
        .operation = .{ .receive = .{ .socket = .{ .value = 9 } } },
    });
    const first = reactor.BorrowedReceive{
        .identity = .{
            .owner = try receive.slot(),
            .buffer_index = 1,
            .buffer_generation = 1,
        },
        .bytes = "GET ",
    };
    try test_reactor.complete(receive, .{ .success = .{ .receive = .{
        .bytes = first,
    } } }, true);
    _ = test_reactor.nextCompletion().?;
    try test_reactor.recycle(first);

    var second = first;
    second.identity.buffer_generation = 2;
    try test_reactor.complete(receive, .{ .success = .{ .receive = .{
        .bytes = second,
    } } }, true);
    _ = test_reactor.nextCompletion().?;
    try std.testing.expectError(error.StaleBorrow, test_reactor.recycle(first));
    try test_reactor.recycle(second);
}

test "deterministic abort owns queued accepts and clears bounded state" {
    const TestReactor = DeterministicReactor(2);
    var test_reactor = TestReactor{};
    const accept = testToken(.accept, 1);
    try test_reactor.submit(.{
        .token = accept,
        .operation = .{ .accept = .{ .listener = .{ .value = 4 } } },
    });
    try std.testing.expectError(error.InvalidCompletion, test_reactor.complete(
        accept,
        .{ .success = .{ .accept = reactor.Accepted.loopback(.{ .value = 8 }) } },
        true,
    ));
    try std.testing.expectEqual(@as(u64, 1), test_reactor.discardedCount());
    try test_reactor.complete(
        accept,
        .{ .success = .{ .accept = reactor.Accepted.loopback(.{ .value = 9 }) } },
        false,
    );

    const status = try test_reactor.abort();
    try std.testing.expect(status.ownership_proven);
    try std.testing.expectEqual(@as(u32, 1), status.accepted_sockets_discarded);
    try std.testing.expectEqual(@as(u16, 0), test_reactor.activeCount());
    try std.testing.expectEqual(@as(u16, 0), test_reactor.pendingCompletionCount());
    try std.testing.expectEqual(@as(u64, 2), test_reactor.discardedCount());
    try std.testing.expectError(error.BackendClosed, test_reactor.submit(.{
        .token = testToken(.send, 2),
        .operation = .{ .send = .{ .socket = .{ .value = 9 }, .bytes = "x" } },
    }));
}
