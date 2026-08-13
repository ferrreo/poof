const std = @import("std");
const application = @import("../../../application.zig");
const connection_body_runtime = @import("body_runtime.zig");
const connection_direct_send = @import("direct_send.zig");
const connection_send = @import("send.zig");
const request_head = @import("../../http1/request_head.zig");

pub fn Transitions(
    comptime App: type,
    comptime Storage: type,
    comptime DriverError: type,
) type {
    return struct {
        const write_stall_ns = Storage.runtime_limits.timeouts.write_stall_ns;

        pub fn beginContinue(
            driver: anytype,
            connection_index: u16,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[connection_index];
            if (connection.continue_cursor != 0 or connection.send_token != null) {
                return error.StateInvariant;
            }
            connection.continue_cursor = 1;
            try driver.operations.retargetTimeout(
                driver.storage,
                connection_index,
                now_ns,
                write_stall_ns,
            );
            try driver.operations.submitSend(
                driver.storage,
                connection_index,
                try connection_send.bytes(driver.storage, connection_index),
            );
        }

        pub fn beginFinal(
            driver: anytype,
            connection_index: u16,
            close_connection: bool,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[connection_index];
            connection.close_after_response = close_connection;
            connection.phase = .responding;
            if (connection.continue_cursor != 0) {
                if (connection.send_token == null) return error.StateInvariant;
                try @TypeOf(driver.operations).extendTimeoutDeadline(
                    driver.storage,
                    connection_index,
                    now_ns,
                    write_stall_ns,
                );
                return;
            }
            try driver.operations.retargetTimeout(
                driver.storage,
                connection_index,
                now_ns,
                write_stall_ns,
            );
            if (comptime @hasDecl(@TypeOf(driver.*), "completeResponse")) {
                if (try sendDirect(driver, connection_index, now_ns)) return;
            }
            try driver.operations.submitSend(
                driver.storage,
                connection_index,
                try connection_send.bytes(driver.storage, connection_index),
            );
        }

        fn sendDirect(
            driver: anytype,
            connection_index: u16,
            now_ns: u64,
        ) DriverError!bool {
            const connection = &driver.storage.connections[connection_index];
            if (comptime @hasField(@TypeOf(driver.*), "live_static")) {
                if (driver.live_static.activeForConnection(driver.storage, connection_index)) {
                    return false;
                }
            }
            if (connection.receive_flags.send_budget == 0) return false;
            const bytes = connection_send.bytes(driver.storage, connection_index) catch
                return error.StateInvariant;
            const more = connection.pipeline_read < connection.pipeline_write;
            switch (connection_direct_send.write(connection.socket, bytes, more)) {
                .would_block => return false,
                .failed => |problem| {
                    try driver.beginCloseWithOutcome(
                        connection_index,
                        @import("transport_failure.zig").outcome(problem),
                    );
                    return true;
                },
                .sent => |sent| {
                    connection.receive_flags.send_budget -= 1;
                    const request_index = connection.active_request orelse
                        return error.StateInvariant;
                    driver.observation.addResponseWire(request_index, sent) catch
                        return error.StateInvariant;
                    return switch (try connection_send.commitDirect(
                        driver.storage,
                        connection_index,
                        sent,
                    )) {
                        .partial => false,
                        .buffer_complete => complete: {
                            try driver.completeResponse(connection_index, now_ns);
                            break :complete true;
                        },
                        else => error.StateInvariant,
                    };
                },
            }
        }

        pub fn handleRuntimeError(
            driver: anytype,
            connection_index: u16,
            problem: connection_body_runtime.Error,
            now_ns: u64,
        ) DriverError!void {
            if (problem == error.ApplicationFailure) {
                const request_index = driver.storage.connections[connection_index]
                    .active_request orelse return error.StateInvariant;
                const outcome = App.__abortWithTransport(
                    &driver.storage.requests[request_index].workspace,
                    .aborted,
                ) catch return error.StateInvariant;
                try driver.recordUploadFinalization(request_index);
                try driver.startObservedFallback(
                    connection_index,
                    request_index,
                    outcome,
                    .{ .status = .internal_server_error },
                    now_ns,
                );
                return;
            }
            return switch (problem) {
                error.ResponseSerializationFailed => error.ResponseSerializationFailed,
                error.StateInvariant => error.StateInvariant,
                error.ApplicationFailure => unreachable,
            };
        }
    };
}

const TestError = error{
    ApplicationFailure,
    InvalidCompletion,
    ResponseSerializationFailed,
    StateInvariant,
};

const Call = enum(u8) {
    cancel_receive,
    retarget_timeout,
    extend_timeout,
    submit_send,
    record_finalization,
    start_fallback,
};

const CallLog = struct {
    entries: [8]Call = undefined,
    count: u8 = 0,

    fn append(self: *CallLog, call: Call) void {
        self.entries[self.count] = call;
        self.count += 1;
    }

    fn readable(self: *const CallLog) []const Call {
        return self.entries[0..self.count];
    }
};

const TestPhase = enum(u8) { receiving_body, responding };

const TestConnection = struct {
    continue_cursor: u8 = 0,
    send_token: ?u8 = null,
    close_after_response: bool = false,
    phase: TestPhase = .receiving_body,
    active_request: ?u16 = 0,
    receive_flags: struct { response_fallback: bool = false } = .{},
    pipeline_read: u32 = 0,
    pipeline_write: u32 = 0,
};

const TestWorkspace = struct {
    abort_fails: bool = false,
    abort_calls: u8 = 0,
};

const TestRequest = struct { workspace: TestWorkspace = .{} };

const TestStorage = struct {
    pub const runtime_limits = .{
        .timeouts = .{ .write_stall_ns = @as(u64, 37) },
    };

    connections: [1]TestConnection = .{.{}},
    requests: [1]TestRequest = .{.{}},
    pipeline_bytes: [1]u8 = .{0},
    submitted: []const u8 = "",
    last_now_ns: u64 = 0,
    last_timeout_ns: u64 = 0,
    log: CallLog = .{},

    pub fn responseSendReadable(_: *const TestStorage, _: u16) ![]const u8 {
        return "response";
    }

    pub fn pipeline(self: *TestStorage, _: u16) []u8 {
        return self.pipeline_bytes[0..];
    }
};

const TestApp = struct {
    pub fn __abortWithTransport(
        workspace: *TestWorkspace,
        transport: application.TransportOutcome,
    ) error{AbortFailed}!application.Outcome {
        workspace.abort_calls += 1;
        if (workspace.abort_fails) return error.AbortFailed;
        std.debug.assert(transport == .aborted);
        return .{ .status = null, .mapped_error = true, .transport = transport };
    }
};

const TestOperations = struct {
    pub fn cancelReceive(
        _: *TestOperations,
        storage: *TestStorage,
        _: u16,
    ) TestError!void {
        storage.log.append(.cancel_receive);
    }

    pub fn retargetTimeout(
        _: *TestOperations,
        storage: *TestStorage,
        _: u16,
        now_ns: u64,
        timeout_ns: u64,
    ) TestError!void {
        storage.log.append(.retarget_timeout);
        storage.last_now_ns = now_ns;
        storage.last_timeout_ns = timeout_ns;
    }

    pub fn extendTimeoutDeadline(
        storage: *TestStorage,
        _: u16,
        now_ns: u64,
        timeout_ns: u64,
    ) TestError!void {
        storage.log.append(.extend_timeout);
        storage.last_now_ns = now_ns;
        storage.last_timeout_ns = timeout_ns;
    }

    pub fn submitSend(
        _: *TestOperations,
        storage: *TestStorage,
        connection_index: u16,
        bytes: []const u8,
    ) TestError!void {
        storage.log.append(.submit_send);
        storage.submitted = bytes;
        storage.connections[connection_index].send_token = 1;
    }
};

const TestDriver = struct {
    storage: *TestStorage,
    operations: TestOperations = .{},
    fallback_outcome: ?application.Outcome = null,
    fallback_rejection: ?request_head.Rejection = null,
    fallback_now_ns: u64 = 0,

    pub fn recordUploadFinalization(self: *TestDriver, _: u16) TestError!void {
        self.storage.log.append(.record_finalization);
    }

    pub fn startObservedFallback(
        self: *TestDriver,
        _: u16,
        _: u16,
        outcome: application.Outcome,
        rejection: request_head.Rejection,
        now_ns: u64,
    ) TestError!void {
        self.storage.log.append(.start_fallback);
        self.fallback_outcome = outcome;
        self.fallback_rejection = rejection;
        self.fallback_now_ns = now_ns;
    }
};

const TestTransitions = Transitions(TestApp, TestStorage, TestError);

test "body transition table covers interim send admission" {
    const cases = [_]struct {
        cursor: u8,
        token: ?u8,
        rejected: bool,
    }{
        .{ .cursor = 0, .token = null, .rejected = false },
        .{ .cursor = 1, .token = null, .rejected = true },
        .{ .cursor = 0, .token = 9, .rejected = true },
    };
    for (cases) |case| {
        var storage = TestStorage{};
        storage.connections[0].continue_cursor = case.cursor;
        storage.connections[0].send_token = case.token;
        var driver = TestDriver{ .storage = &storage };
        const result = TestTransitions.beginContinue(&driver, 0, 11);
        if (case.rejected) {
            try std.testing.expectError(error.StateInvariant, result);
            try std.testing.expectEqual(@as(u8, 0), storage.log.count);
        } else {
            try result;
            try expectCalls(&storage, &.{ .retarget_timeout, .submit_send });
            try std.testing.expectEqual(@as(u8, 1), storage.connections[0].continue_cursor);
            try std.testing.expectEqualStrings(
                connection_send.continue_response,
                storage.submitted,
            );
            try expectTimeout(&storage, 11);
        }
    }
}

test "body transition table covers final response scheduling" {
    const cases = [_]struct {
        cursor: u8,
        token: ?u8,
        close: bool,
        rejected: bool,
        calls: []const Call,
    }{
        .{
            .cursor = 0,
            .token = null,
            .close = false,
            .rejected = false,
            .calls = &.{ .retarget_timeout, .submit_send },
        },
        .{
            .cursor = 1,
            .token = 9,
            .close = true,
            .rejected = false,
            .calls = &.{.extend_timeout},
        },
        .{
            .cursor = 1,
            .token = null,
            .close = true,
            .rejected = true,
            .calls = &.{},
        },
    };
    for (cases) |case| {
        var storage = TestStorage{};
        storage.connections[0].continue_cursor = case.cursor;
        storage.connections[0].send_token = case.token;
        var driver = TestDriver{ .storage = &storage };
        const result = TestTransitions.beginFinal(&driver, 0, case.close, 13);
        if (case.rejected) {
            try std.testing.expectError(error.StateInvariant, result);
        } else {
            try result;
        }
        try expectCalls(&storage, case.calls);
        try std.testing.expectEqual(.responding, storage.connections[0].phase);
        try std.testing.expectEqual(case.close, storage.connections[0].close_after_response);
        if (!case.rejected) try expectTimeout(&storage, 13);
    }
}

test "body transition table maps runtime failures" {
    const cases = [_]struct {
        problem: connection_body_runtime.Error,
        active_request: ?u16 = 0,
        abort_fails: bool = false,
        expected: ?TestError,
    }{
        .{ .problem = error.ApplicationFailure, .expected = null },
        .{
            .problem = error.ApplicationFailure,
            .active_request = null,
            .expected = error.StateInvariant,
        },
        .{
            .problem = error.ApplicationFailure,
            .abort_fails = true,
            .expected = error.StateInvariant,
        },
        .{
            .problem = error.ResponseSerializationFailed,
            .expected = error.ResponseSerializationFailed,
        },
        .{ .problem = error.StateInvariant, .expected = error.StateInvariant },
    };
    for (cases) |case| try expectRuntimeFailure(case);
}

fn expectRuntimeFailure(case: anytype) !void {
    var storage = TestStorage{};
    storage.connections[0].active_request = case.active_request;
    storage.requests[0].workspace.abort_fails = case.abort_fails;
    var driver = TestDriver{ .storage = &storage };
    const result = TestTransitions.handleRuntimeError(&driver, 0, case.problem, 17);
    if (case.expected) |expected| {
        try std.testing.expectError(expected, result);
        try std.testing.expectEqual(@as(u8, 0), storage.log.count);
        return;
    }
    try result;
    try expectCalls(&storage, &.{ .record_finalization, .start_fallback });
    try std.testing.expectEqual(@as(u8, 1), storage.requests[0].workspace.abort_calls);
    try std.testing.expectEqual(.internal_server_error, driver.fallback_rejection.?.status);
    try std.testing.expectEqual(
        application.TransportOutcome.aborted,
        driver.fallback_outcome.?.transport,
    );
    try std.testing.expectEqual(@as(u64, 17), driver.fallback_now_ns);
}

fn expectCalls(storage: *const TestStorage, expected: []const Call) !void {
    try std.testing.expectEqualSlices(Call, expected, storage.log.readable());
}

fn expectTimeout(storage: *const TestStorage, now_ns: u64) !void {
    try std.testing.expectEqual(now_ns, storage.last_now_ns);
    try std.testing.expectEqual(
        TestStorage.runtime_limits.timeouts.write_stall_ns,
        storage.last_timeout_ns,
    );
}

test {
    _ = std.testing.refAllDecls(@This());
}
