const std = @import("std");
const reactor = @import("../reactor.zig");

const TimeoutOutcome = union(enum) {
    expired,
    canceled,
    failed: reactor.CompletionError,
};

pub fn Handler(
    comptime App: type,
    comptime Storage: type,
    comptime Reactor: type,
    comptime Error: type,
    comptime Start: type,
    comptime Event: type,
) type {
    return struct {
        pub fn handle(
            self: anytype,
            io: *Reactor,
            index: u16,
            completion: reactor.Completion,
            now_ns: u64,
        ) Error!Event {
            const root = &self.roots[index];
            if (matches(root.token, completion.token)) {
                root.token = null;
                return switch (root.phase) {
                    .opening, .stating, .closing_failed => completeTarget(
                        self,
                        io,
                        index,
                        completion,
                        now_ns,
                    ),
                    .closing => completeClose(self, io, index, completion),
                    .closed, .ready => error.InvalidCompletion,
                };
            }
            if (matches(root.timeout_token, completion.token)) {
                root.timeout_token = null;
                return completeTimeout(self, io, index, completion, now_ns);
            }
            if (matches(root.cancel_token, completion.token)) {
                root.cancel_token = null;
                try validateCancel(completion);
                return settleRace(self, io, index, now_ns);
            }
            return error.InvalidCompletion;
        }

        fn completeTarget(
            self: anytype,
            io: *Reactor,
            index: u16,
            completion: reactor.Completion,
            now_ns: u64,
        ) Error!Event {
            const root = &self.roots[index];
            try validateTarget(root.phase, completion.result);
            if (root.target_result_valid) return error.InvalidCompletion;
            root.target_result = completion.result;
            root.target_result_valid = true;
            switch (root.winner) {
                .none => {
                    root.winner = .target;
                    try submitTimeoutCancel(self, io, index);
                },
                .timeout => {},
                .target => return error.InvalidCompletion,
            }
            return settleRace(self, io, index, now_ns);
        }

        fn completeTimeout(
            self: anytype,
            io: *Reactor,
            index: u16,
            completion: reactor.Completion,
            now_ns: u64,
        ) Error!Event {
            const root = &self.roots[index];
            const outcome = timeoutOutcome(completion.result);
            switch (root.winner) {
                .none => {
                    if (outcome == .canceled) return error.BackendFailure;
                    root.winner = .timeout;
                    recordTimeoutFailure(self, index, outcome);
                    try submitTargetCancel(self, io, index);
                },
                .target => switch (outcome) {
                    .canceled => {},
                    .expired, .failed => {
                        root.winner = .timeout;
                        recordTimeoutFailure(self, index, outcome);
                    },
                },
                .timeout => return error.InvalidCompletion,
            }
            return settleRace(self, io, index, now_ns);
        }

        fn settleRace(
            self: anytype,
            io: *Reactor,
            index: u16,
            now_ns: u64,
        ) Error!Event {
            const root = &self.roots[index];
            if (root.token != null or root.timeout_token != null or root.cancel_token != null) {
                return .none;
            }
            if (!root.target_result_valid or root.winner == .none) {
                return error.StateInvariant;
            }
            return switch (root.winner) {
                .target => finishTarget(self, io, index, now_ns),
                .timeout => finishTimeout(self, io, index, now_ns),
                .none => unreachable,
            };
        }

        fn finishTarget(
            self: anytype,
            io: *Reactor,
            index: u16,
            now_ns: u64,
        ) Error!Event {
            const root = &self.roots[index];
            const result = root.target_result;
            resetRace(root);
            return switch (root.phase) {
                .opening => finishOpen(self, io, index, result, now_ns),
                .stating => finishStat(self, io, index, result, now_ns),
                .closing_failed => finishFailedClose(self, io, index, result, now_ns),
                else => error.StateInvariant,
            };
        }

        fn finishTimeout(
            self: anytype,
            io: *Reactor,
            index: u16,
            now_ns: u64,
        ) Error!Event {
            const root = &self.roots[index];
            const result = root.target_result;
            const phase = root.phase;
            resetRace(root);
            if (phase == .closing_failed) {
                switch (result) {
                    .success => root.file = null,
                    .failure => {},
                }
                return error.BackendFailure;
            }
            if (phase == .opening) {
                switch (result) {
                    .success => |success| switch (success) {
                        .file_open => |file| root.file = file,
                        else => return error.InvalidCompletion,
                    },
                    .failure => {},
                }
            }
            return beginFailureRollback(self, io, now_ns);
        }

        fn finishOpen(
            self: anytype,
            io: *Reactor,
            index: u16,
            result: reactor.CompletionResult,
            now_ns: u64,
        ) Error!Event {
            switch (result) {
                .failure => |problem| {
                    recordFailure(self, index, problem, .io);
                    return beginFailureRollback(self, io, now_ns);
                },
                .success => |success| switch (success) {
                    .file_open => |file| self.roots[index].file = file,
                    else => return error.InvalidCompletion,
                },
            }
            try submitStat(self, io, index, now_ns);
            return .none;
        }

        fn finishStat(
            self: anytype,
            io: *Reactor,
            index: u16,
            result: reactor.CompletionResult,
            now_ns: u64,
        ) Error!Event {
            const problem: ?reactor.CompletionError = switch (result) {
                .failure => |failure| failure,
                .success => if (validDirectory(&self.roots[index].statx))
                    null
                else
                    .invalid_resource,
            };
            if (problem) |failure| {
                recordFailure(self, index, failure, .io);
                return beginFailureRollback(self, io, now_ns);
            }
            return finishReady(self, io, index, now_ns);
        }

        fn finishReady(
            self: anytype,
            io: *Reactor,
            index: u16,
            now_ns: u64,
        ) Error!Event {
            self.roots[index].phase = .ready;
            self.root_cursor = index + 1;
            if (self.stop_requested) {
                self.roots_phase = .closing;
                self.root_cursor = 0;
                return switch (try closeNext(self, io)) {
                    .ready => .stopped,
                    .pending => .none,
                };
            }
            if (self.root_cursor < self.roots.len) {
                try submitOpen(self, io, self.root_cursor, now_ns);
                return .none;
            }
            self.roots_phase = .ready;
            return .roots_ready;
        }

        fn completeClose(
            self: anytype,
            io: *Reactor,
            index: u16,
            completion: reactor.Completion,
        ) Error!Event {
            try validateClose(completion);
            self.roots[index].file = null;
            self.roots[index].phase = .closed;
            self.root_cursor = index + 1;
            return switch (try closeNext(self, io)) {
                .ready => .stopped,
                .pending => .none,
            };
        }

        fn finishFailedClose(
            self: anytype,
            io: *Reactor,
            index: u16,
            result: reactor.CompletionResult,
            now_ns: u64,
        ) Error!Event {
            switch (result) {
                .failure => return error.BackendFailure,
                .success => {},
            }
            self.roots[index].file = null;
            self.roots[index].phase = .closed;
            self.root_cursor = index + 1;
            return failureCloseNext(self, io, now_ns);
        }

        pub fn closeNext(self: anytype, io: *Reactor) Error!Start {
            while (self.root_cursor < self.roots.len) : (self.root_cursor += 1) {
                const root = &self.roots[self.root_cursor];
                if (root.file == null) {
                    root.phase = .closed;
                    continue;
                }
                root.phase = .closing;
                try submitClose(self, io, self.root_cursor);
                return .pending;
            }
            self.roots_phase = .stopped;
            return .ready;
        }

        fn beginFailureRollback(
            self: anytype,
            io: *Reactor,
            now_ns: u64,
        ) Error!Event {
            self.roots_phase = .failed;
            self.root_cursor = 0;
            return failureCloseNext(self, io, now_ns);
        }

        fn failureCloseNext(
            self: anytype,
            io: *Reactor,
            now_ns: u64,
        ) Error!Event {
            while (self.root_cursor < self.roots.len) : (self.root_cursor += 1) {
                const root = &self.roots[self.root_cursor];
                if (root.file == null) {
                    root.phase = .closed;
                    continue;
                }
                root.phase = .closing_failed;
                try submitFailureClose(self, io, self.root_cursor, now_ns);
                return .none;
            }
            return error.BackendFailure;
        }

        pub fn submitOpen(
            self: anytype,
            io: *Reactor,
            index: u16,
            now_ns: u64,
        ) Error!void {
            inline for (App.live_static_root_paths, 0..) |path, route_index| {
                if (index == route_index) {
                    const terminated = path ++ "\x00";
                    const operation = reactor.Operation{ .file_open = .{
                        .base = .working_directory,
                        .path = terminated[0..path.len :0],
                        .access = .read_only,
                        .kind = .directory,
                        .no_follow = true,
                    } };
                    try submitTimed(self, io, index, .file_open, operation, now_ns);
                    self.roots[index].phase = .opening;
                    return;
                }
            }
            unreachable;
        }

        fn submitStat(
            self: anytype,
            io: *Reactor,
            index: u16,
            now_ns: u64,
        ) Error!void {
            const root = &self.roots[index];
            root.statx = std.mem.zeroes(std.os.linux.Statx);
            const operation = reactor.Operation{ .file_stat = .{
                .file = root.file.?,
                .output = &root.statx,
            } };
            try submitTimed(self, io, index, .file_stat, operation, now_ns);
            root.phase = .stating;
        }

        fn submitTimed(
            self: anytype,
            io: *Reactor,
            index: u16,
            kind: reactor.OperationKind,
            operation: reactor.Operation,
            now_ns: u64,
        ) Error!void {
            const deadline_ns = std.math.add(
                u64,
                now_ns,
                Storage.runtime_limits.timeouts.startup_io_ns,
            ) catch {
                recordFailure(self, index, .io_failure, .clock_overflow);
                return error.BackendFailure;
            };
            const root = &self.roots[index];
            const target = try nextToken(self, io, index, kind);
            io.submit(.{ .token = target, .operation = operation }) catch {
                recordFailure(self, index, .io_failure, .io);
                return error.BackendFailure;
            };
            root.token = target;
            const timeout = try nextToken(self, io, index, .timeout);
            io.submit(.{ .token = timeout, .operation = .{ .timeout = .{
                .deadline_ns = deadline_ns,
            } } }) catch {
                recordFailure(self, index, .io_failure, .io);
                return error.BackendFailure;
            };
            root.timeout_token = timeout;
            root.winner = .none;
            root.target_result_valid = false;
        }

        fn submitTimeoutCancel(self: anytype, io: *Reactor, index: u16) Error!void {
            const root = &self.roots[index];
            const token = try nextToken(self, io, index, .cancel);
            io.submit(.{ .token = token, .operation = .{ .cancel = .{
                .target = root.timeout_token.?,
            } } }) catch return error.BackendFailure;
            root.cancel_token = token;
        }

        fn submitTargetCancel(self: anytype, io: *Reactor, index: u16) Error!void {
            const root = &self.roots[index];
            const token = try nextToken(self, io, index, .file_cancel);
            io.submit(.{ .token = token, .operation = .{ .file_cancel = .{
                .target = root.token.?,
            } } }) catch return error.BackendFailure;
            root.cancel_token = token;
        }

        fn submitClose(self: anytype, io: *Reactor, index: u16) Error!void {
            const root = &self.roots[index];
            const token = try nextToken(self, io, index, .file_close);
            io.submit(.{ .token = token, .operation = .{ .file_close = .{
                .file = root.file.?,
            } } }) catch return error.BackendFailure;
            root.token = token;
        }

        fn submitFailureClose(
            self: anytype,
            io: *Reactor,
            index: u16,
            now_ns: u64,
        ) Error!void {
            const root = &self.roots[index];
            const operation = reactor.Operation{ .file_close = .{ .file = root.file.? } };
            try submitTimed(self, io, index, .file_close, operation, now_ns);
        }

        fn nextToken(
            self: anytype,
            io: *Reactor,
            index: u16,
            kind: reactor.OperationKind,
        ) Error!reactor.OperationToken {
            const root = &self.roots[index];
            var sequence = root.sequence;
            for (0..8) |_| {
                const token = reactor.OperationToken.init(.{
                    .kind = kind,
                    .worker_index = self.worker_index,
                    .slot_index = reactor.live_static_root_slot_base + index,
                    .slot_generation = root.generation,
                    .sequence = sequence,
                }) catch return error.StateInvariant;
                const next = reactor.nextSequence(sequence);
                if (!io.tokenActive(token)) {
                    root.sequence = next;
                    return token;
                }
                sequence = next;
            }
            return error.StateInvariant;
        }

        fn recordTimeoutFailure(self: anytype, index: u16, outcome: TimeoutOutcome) void {
            switch (outcome) {
                .expired => recordFailure(self, index, .io_failure, .deadline),
                .failed => |problem| recordFailure(self, index, problem, .io),
                .canceled => unreachable,
            }
        }

        fn recordFailure(
            self: anytype,
            index: u16,
            problem: reactor.CompletionError,
            kind: anytype,
        ) void {
            if (self.startup_failure != null) return;
            self.startup_failure = .{
                .root_index = index,
                .path = App.live_static_root_paths[index],
                .problem = problem,
                .kind = kind,
            };
        }

        fn validDirectory(statx: *const std.os.linux.Statx) bool {
            return statx.mask.TYPE and statx.mode & 0o170000 == 0o040000;
        }

        fn validateTarget(phase: anytype, result: reactor.CompletionResult) Error!void {
            switch (result) {
                .failure => {},
                .success => |success| switch (phase) {
                    .opening => if (success != .file_open) return error.InvalidCompletion,
                    .stating => if (success != .file_stat) return error.InvalidCompletion,
                    .closing_failed => if (success != .file_close) {
                        return error.InvalidCompletion;
                    },
                    else => return error.StateInvariant,
                },
            }
        }

        fn timeoutOutcome(result: reactor.CompletionResult) TimeoutOutcome {
            return switch (result) {
                .success => |success| if (success == .timeout)
                    .expired
                else
                    .{ .failed = .invalid_resource },
                .failure => |failure| if (failure == .canceled)
                    .canceled
                else
                    .{ .failed = failure },
            };
        }

        fn validateCancel(completion: reactor.Completion) Error!void {
            const kind = (completion.token.fields() catch return error.InvalidCompletion).kind;
            return switch (completion.result) {
                .failure => |problem| if (problem == .canceled) {} else error.BackendFailure,
                .success => |success| switch (kind) {
                    .cancel => if (success != .cancel) return error.InvalidCompletion,
                    .file_cancel => if (success != .file_cancel) return error.InvalidCompletion,
                    else => error.InvalidCompletion,
                },
            };
        }

        fn validateClose(completion: reactor.Completion) Error!void {
            return switch (completion.result) {
                .success => |success| if (success == .file_close) {} else error.InvalidCompletion,
                .failure => error.BackendFailure,
            };
        }

        fn resetRace(root: anytype) void {
            root.winner = .none;
            root.target_result_valid = false;
        }

        fn matches(candidate: ?reactor.OperationToken, actual: reactor.OperationToken) bool {
            return if (candidate) |token| token.eql(actual) else false;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
