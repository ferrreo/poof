const std = @import("std");
const reactor = @import("../reactor.zig");

/// Connection operation submission and borrowed receive ownership.
pub fn Operations(
    comptime Storage: type,
    comptime Reactor: type,
    comptime OperationError: type,
) type {
    return struct {
        const Self = @This();

        io: *Reactor,
        worker_index: u16,

        pub fn init(io: *Reactor, worker_index: u16) Self {
            return .{ .io = io, .worker_index = worker_index };
        }

        pub fn submitReceive(
            self: *const Self,
            storage: *Storage,
            connection_index: u16,
            multishot: bool,
        ) OperationError!void {
            const connection = &storage.connections[connection_index];
            std.debug.assert(connection.receive_token == null);
            std.debug.assert(!connection.receive_flags.gzip_rejecting);
            std.debug.assert(!connection.receive_flags.upload_paused);
            const token = try self.submit(storage, connection_index, .receive, .{
                .receive = .{ .socket = connection.socket, .multishot = multishot },
            });
            connection.receive_token = token;
            connection.receive_flags.multishot = multishot;
            connection.receive_flags.paused = false;
            connection.receive_flags.upload_paused = false;
            connection.receive_flags.gzip_paused = false;
        }

        pub fn submitReceiveForPhase(
            self: *const Self,
            storage: *Storage,
            connection_index: u16,
        ) OperationError!void {
            const connection = &storage.connections[connection_index];
            const gzip_active = if (comptime Storage.gzip_decoder_thread_count != 0)
                if (connection.active_request) |request_index|
                    storage.requests[request_index].gzip_lease != null
                else
                    false
            else
                false;
            const upload_active = if (comptime Storage.upload_async_enabled)
                if (connection.active_request) |request_index|
                    storage.requests[request_index].body.multipart
                else
                    false
            else
                false;
            const multishot = connection.phase == .receiving_body and
                !gzip_active and !upload_active;
            return self.submitReceive(storage, connection_index, multishot);
        }

        pub fn submitSend(
            self: *const Self,
            storage: *Storage,
            connection_index: u16,
            bytes: []const u8,
        ) OperationError!void {
            const connection = &storage.connections[connection_index];
            std.debug.assert(connection.send_token == null);
            std.debug.assert(bytes.len != 0);
            const token = try self.submit(storage, connection_index, .send, .{
                .send = .{ .socket = connection.socket, .bytes = bytes },
            });
            connection.send_token = token;
        }

        pub fn submitClose(
            self: *const Self,
            storage: *Storage,
            connection_index: u16,
        ) OperationError!void {
            const connection = &storage.connections[connection_index];
            std.debug.assert(connection.close_token == null);
            const token = try self.submit(storage, connection_index, .close, .{
                .close = .{ .socket = connection.socket },
            });
            connection.close_token = token;
        }

        pub fn replaceTimeout(
            self: *const Self,
            storage: *Storage,
            connection_index: u16,
            now_ns: u64,
            duration_ns: u64,
        ) OperationError!void {
            const deadline_ns = std.math.add(u64, now_ns, duration_ns) catch {
                return error.ClockOverflow;
            };
            try self.cancelTimeout(storage, connection_index);
            try self.submitTimeoutAt(storage, connection_index, deadline_ns);
        }

        /// Reuses an earlier timeout for extensions; earlier deadlines still replace it.
        pub fn retargetTimeout(
            self: *const Self,
            storage: *Storage,
            connection_index: u16,
            now_ns: u64,
            duration_ns: u64,
        ) OperationError!void {
            const deadline_ns = std.math.add(u64, now_ns, duration_ns) catch {
                return error.ClockOverflow;
            };
            const connection = &storage.connections[connection_index];
            if (connection.timeout_token != null) {
                if (connection.timeout_deadline_ns == 0) return error.StateInvariant;
                if (connection.timeout_deadline_ns <= deadline_ns) {
                    if (connection.timeout_deadline_ns < deadline_ns) {
                        connection.receive_flags.timeout_extended = true;
                    }
                    connection.timeout_deadline_ns = deadline_ns;
                    return;
                }
            }
            try self.cancelTimeout(storage, connection_index);
            try self.submitTimeoutAt(storage, connection_index, deadline_ns);
        }

        pub fn extendTimeoutDeadline(
            storage: *Storage,
            connection_index: u16,
            now_ns: u64,
            duration_ns: u64,
        ) OperationError!void {
            const deadline_ns = std.math.add(u64, now_ns, duration_ns) catch {
                return error.ClockOverflow;
            };
            const connection = &storage.connections[connection_index];
            if (connection.timeout_token == null or connection.timeout_deadline_ns == 0) {
                return error.StateInvariant;
            }
            if (deadline_ns < connection.timeout_deadline_ns) return error.StateInvariant;
            if (connection.timeout_deadline_ns < deadline_ns) {
                connection.receive_flags.timeout_extended = true;
            }
            connection.timeout_deadline_ns = deadline_ns;
        }

        pub fn submitTimeoutAt(
            self: *const Self,
            storage: *Storage,
            connection_index: u16,
            deadline_ns: u64,
        ) OperationError!void {
            const token = try self.submit(storage, connection_index, .timeout, .{
                .timeout = .{ .deadline_ns = deadline_ns },
            });
            const connection = &storage.connections[connection_index];
            connection.timeout_token = token;
            connection.timeout_deadline_ns = deadline_ns;
            connection.receive_flags.timeout_extended = false;
        }

        pub fn cancelReceive(
            self: *const Self,
            storage: *Storage,
            connection_index: u16,
        ) OperationError!void {
            if (storage.connections[connection_index].receive_token) |token| {
                try self.submitCancel(storage, connection_index, token);
            }
        }

        pub fn cancelTimeout(
            self: *const Self,
            storage: *Storage,
            connection_index: u16,
        ) OperationError!void {
            if (storage.connections[connection_index].timeout_token) |token| {
                try self.submitCancel(storage, connection_index, token);
            }
        }

        pub fn submitCancel(
            self: *const Self,
            storage: *Storage,
            connection_index: u16,
            target: reactor.OperationToken,
        ) OperationError!void {
            _ = try self.submitCancelTracked(storage, connection_index, target);
        }

        pub fn submitCancelTracked(
            self: *const Self,
            storage: *Storage,
            connection_index: u16,
            target: reactor.OperationToken,
        ) OperationError!reactor.OperationToken {
            return self.submit(storage, connection_index, .cancel, .{
                .cancel = .{ .target = target },
            });
        }

        pub fn recycleIfBorrowed(
            self: *const Self,
            completion: reactor.Completion,
        ) OperationError!void {
            switch (completion.result) {
                .failure => {},
                .success => |success| switch (success) {
                    .receive => |received| switch (received) {
                        .bytes => |borrowed| try self.recycleBorrowed(borrowed),
                        .end_of_stream => {},
                    },
                    else => {},
                },
            }
        }

        pub fn recycleBorrowed(
            self: *const Self,
            borrowed: reactor.BorrowedReceive,
        ) OperationError!void {
            self.io.recycle(borrowed) catch return error.BackendFailure;
        }

        fn submit(
            self: *const Self,
            storage: *Storage,
            connection_index: u16,
            kind: reactor.OperationKind,
            operation: reactor.Operation,
        ) OperationError!reactor.OperationToken {
            const connection = &storage.connections[connection_index];
            if (connection.inflight_operations >= reactor.connection_operation_capacity) {
                return error.StateInvariant;
            }
            const next_inflight = std.math.add(
                u16,
                connection.inflight_operations,
                1,
            ) catch return error.StateInvariant;
            const selection = try self.selectToken(connection, connection_index, kind);
            const token = selection.token;
            self.io.submit(.{ .token = token, .operation = operation }) catch {
                return error.BackendFailure;
            };
            connection.sequence = selection.next_sequence;
            connection.inflight_operations = next_inflight;
            return token;
        }

        const TokenSelection = struct {
            token: reactor.OperationToken,
            next_sequence: u16,
        };

        fn selectToken(
            self: *const Self,
            connection: anytype,
            connection_index: u16,
            kind: reactor.OperationKind,
        ) OperationError!TokenSelection {
            var sequence = connection.sequence;
            for (0..reactor.connection_operation_capacity + 1) |_| {
                const token = reactor.OperationToken.init(.{
                    .kind = kind,
                    .worker_index = self.worker_index,
                    .slot_index = connection_index,
                    .slot_generation = connection.generation,
                    .sequence = sequence,
                }) catch return error.StateInvariant;
                const next_sequence = reactor.nextSequence(sequence);
                if (!self.io.tokenActive(token)) {
                    return .{ .token = token, .next_sequence = next_sequence };
                }
                sequence = next_sequence;
            }
            return error.StateInvariant;
        }
    };
}
