const std = @import("std");
const application = @import("../../../application.zig");
const application_types = @import("../../application/types.zig");
const reactor = @import("../reactor.zig");
const live_static_completion = @import("live_static_completion.zig");
const live_static_io = @import("live_static_io.zig");
const live_static_root = @import("live_static_root.zig");
const live_static_stage = @import("live_static_stage.zig");

pub const Start = enum(u1) { ready, pending };
pub const Event = enum(u2) { none, roots_ready, stopped };

pub const StartupFailureKind = enum(u2) {
    io,
    deadline,
    clock_overflow,
};

pub const StartupDiagnostic = struct {
    root_index: u16,
    path: []const u8,
    problem: reactor.CompletionError,
    kind: StartupFailureKind = .io,
};

pub fn Controller(
    comptime App: type,
    comptime Storage: type,
    comptime Reactor: type,
    comptime DriverError: type,
    comptime BodyTransport: type,
    comptime ResponseTransport: type,
) type {
    if (Storage.live_static_slot_count == 0) return Disabled(DriverError);
    return Enabled(App, Storage, Reactor, DriverError, BodyTransport, ResponseTransport);
}

fn Disabled(comptime DriverError: type) type {
    return struct {
        pub fn init(_: u16) DriverError!@This() {
            return .{};
        }
        pub fn beginRoots(_: *@This(), _: anytype, _: u64) DriverError!Start {
            return .ready;
        }
        pub fn beginStop(_: *@This(), _: anytype) DriverError!Start {
            return .ready;
        }
        pub fn handle(
            _: *@This(),
            _: anytype,
            _: reactor.Completion,
            _: i64,
            _: u64,
        ) DriverError!Event {
            return error.InvalidCompletion;
        }
        pub fn beginRequest(
            _: *@This(),
            _: anytype,
            _: u16,
            _: u16,
            _: anytype,
            _: u64,
        ) DriverError!void {
            unreachable;
        }
        pub fn responseBufferComplete(_: *@This(), _: anytype, _: u16, _: u64) DriverError!bool {
            return false;
        }
        pub fn sendCompletedDuringClose(
            _: *@This(),
            _: anytype,
            _: u16,
            _: bool,
            _: u64,
        ) DriverError!bool {
            return false;
        }
        pub fn cancelConnection(
            _: *@This(),
            _: anytype,
            _: u16,
            _: application.TransportOutcome,
        ) DriverError!void {}
        pub fn activeForConnection(_: *const @This(), _: anytype, _: u16) bool {
            return false;
        }
        pub fn rootsReady(_: *const @This()) bool {
            return true;
        }
        pub fn isStopped(_: *const @This()) bool {
            return true;
        }
        pub fn pendingOperations(_: *const @This()) u16 {
            return 0;
        }
        pub fn activeRequests(_: *const @This()) u16 {
            return 0;
        }
        pub fn startupDiagnostic(_: *const @This()) ?StartupDiagnostic {
            return null;
        }
        pub fn abort(_: *@This(), _: anytype) bool {
            return true;
        }
    };
}

fn Enabled(
    comptime App: type,
    comptime Storage: type,
    comptime Reactor: type,
    comptime DriverError: type,
    comptime BodyTransport: type,
    comptime ResponseTransport: type,
) type {
    const slot_count: u16 = Storage.live_static_slot_count;
    const root_count: u16 = App.live_static_root_count;
    const RequestIo = live_static_io.Operations(Reactor, DriverError);
    const RequestCompletion = live_static_completion.Handler(
        App,
        Storage,
        DriverError,
        BodyTransport,
        ResponseTransport,
        RequestIo,
    );
    const RootHandler = live_static_root.Handler(
        App,
        Storage,
        Reactor,
        DriverError,
        Start,
        Event,
    );
    comptime std.debug.assert(slot_count > 0 and slot_count <= reactor.live_static_slots_hard_max);
    comptime std.debug.assert(root_count <= reactor.live_static_slots_hard_max);

    const RootPhase = enum(u3) { closed, opening, stating, ready, closing, closing_failed };
    const RootWinner = enum(u2) { none, target, timeout };
    const RootsPhase = enum(u3) { idle, opening, ready, failed, closing, stopped };
    const Root = struct {
        phase: RootPhase = .closed,
        file: ?reactor.FileDescriptor = null,
        token: ?reactor.OperationToken = null,
        timeout_token: ?reactor.OperationToken = null,
        cancel_token: ?reactor.OperationToken = null,
        winner: RootWinner = .none,
        target_result: reactor.CompletionResult = undefined,
        target_result_valid: bool = false,
        statx: std.os.linux.Statx = undefined,
        generation: u16 = 1,
        sequence: u16 = 1,
    };
    const SlotPhase = enum(u4) {
        free,
        opening,
        stating,
        closing_index_directory,
        closing_abort_directory,
        closing_before_prepared,
        sending_head,
        reading,
        verifying,
        sending_chunk,
        closing_complete,
        closing_abort,
    };
    const FileIdentity = struct {
        device_major: u32,
        device_minor: u32,
        inode: u64,
        size: u64,
        mtime_seconds: i64,
        mtime_nanoseconds: u32,

        pub fn from(statx: *const std.os.linux.Statx) @This() {
            return .{
                .device_major = statx.dev_major,
                .device_minor = statx.dev_minor,
                .inode = statx.ino,
                .size = statx.size,
                .mtime_seconds = statx.mtime.sec,
                .mtime_nanoseconds = statx.mtime.nsec,
            };
        }

        pub fn matches(identity: @This(), statx: *const std.os.linux.Statx) bool {
            return statx.mask.TYPE and statx.mask.SIZE and statx.mask.MTIME and
                statx.mask.INO and statx.mode & 0o170000 == 0o100000 and
                identity.device_major == statx.dev_major and
                identity.device_minor == statx.dev_minor and identity.inode == statx.ino and
                identity.size == statx.size and identity.mtime_seconds == statx.mtime.sec and
                identity.mtime_nanoseconds == statx.mtime.nsec;
        }
    };
    const Slot = struct {
        phase: SlotPhase = .free,
        generation: u16 = 1,
        sequence: u16 = 1,
        token: ?reactor.OperationToken = null,
        cancel_token: ?reactor.OperationToken = null,
        file: ?reactor.FileDescriptor = null,
        directory_file: ?reactor.FileDescriptor = null,
        statx: std.os.linux.Statx = undefined,
        identity: FileIdentity = undefined,
        intent: application_types.LiveStaticIntent = undefined,
        prepared: application.Prepared = undefined,
        connection_index: u16 = 0,
        request_index: u16 = 0,
        path_length: u16 = 0,
        read_requested: u32 = 0,
        read_used: u32 = 0,
        next_offset: u64 = 0,
        remaining: u64 = 0,
        abort_outcome: ?application.TransportOutcome = null,
        prepared_valid: bool = false,
        index_lookup: bool = false,
        send_pending: bool = false,
        completion_won: bool = false,
    };

    return struct {
        const Self = @This();

        worker_index: u16,
        roots: [root_count]Root,
        slots: [slot_count]Slot,
        free_bits: u64,
        roots_phase: RootsPhase,
        root_cursor: u16,
        startup_failure: ?StartupDiagnostic,
        stop_requested: bool,

        pub fn init(worker_index: u16) DriverError!Self {
            if (worker_index > reactor.max_worker_index) return error.InvalidWorkerIndex;
            return .{
                .worker_index = worker_index,
                .roots = [_]Root{.{}} ** root_count,
                .slots = [_]Slot{.{}} ** slot_count,
                .free_bits = if (slot_count == 64)
                    std.math.maxInt(u64)
                else
                    (@as(u64, 1) << @intCast(slot_count)) - 1,
                .roots_phase = .idle,
                .root_cursor = 0,
                .startup_failure = null,
                .stop_requested = false,
            };
        }

        pub fn beginRoots(self: *Self, io: *Reactor, now_ns: u64) DriverError!Start {
            if (self.roots_phase != .idle) return error.StateInvariant;
            if (root_count == 0) {
                self.roots_phase = .ready;
                return .ready;
            }
            self.roots_phase = .opening;
            try RootHandler.submitOpen(self, io, 0, now_ns);
            return .pending;
        }

        pub fn beginStop(self: *Self, io: *Reactor) DriverError!Start {
            if (self.activeRequests() != 0) return error.StateInvariant;
            switch (self.roots_phase) {
                .stopped => return .ready,
                .ready, .failed => {},
                .idle => {
                    self.roots_phase = .stopped;
                    return .ready;
                },
                .opening => {
                    self.stop_requested = true;
                    return .pending;
                },
                .closing => return .pending,
            }
            self.roots_phase = .closing;
            self.root_cursor = 0;
            return RootHandler.closeNext(self, io);
        }

        pub fn handle(
            self: *Self,
            driver: anytype,
            completion: reactor.Completion,
            epoch_second: i64,
            now_ns: u64,
        ) DriverError!Event {
            const fields = completion.token.fields() catch return error.InvalidCompletion;
            if (fields.worker_index != self.worker_index) return error.InvalidCompletion;
            if (reactor.liveStaticRootIndex(fields.slot_index)) |index| {
                if (index >= root_count) return error.InvalidCompletion;
                return RootHandler.handle(
                    self,
                    driver.operations.io,
                    index,
                    completion,
                    now_ns,
                );
            }
            const index = reactor.liveStaticRequestIndex(fields.slot_index) orelse
                return error.InvalidCompletion;
            if (index >= slot_count) return error.InvalidCompletion;
            try self.handleRequest(driver, index, completion, epoch_second, now_ns);
            return .none;
        }

        pub fn beginRequest(
            self: *Self,
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            intent: application_types.LiveStaticIntent,
            now_ns: u64,
        ) DriverError!void {
            if (self.roots_phase != .ready or intent.root_index >= root_count) {
                return error.StateInvariant;
            }
            const slot_index = self.acquire() orelse {
                return self.prepareWithoutFile(
                    driver,
                    connection_index,
                    request_index,
                    intent,
                    .unavailable,
                    now_ns,
                );
            };
            const request = &driver.storage.requests[request_index];
            if (request.live_static_slot != null) return error.StateInvariant;
            request.live_static_slot = slot_index;
            const slot = &self.slots[slot_index];
            slot.intent = intent;
            slot.connection_index = connection_index;
            slot.request_index = request_index;
            if (!RequestIo.copyInitialPath(driver.storage, slot, slot_index)) {
                request.live_static_slot = null;
                self.release(driver.storage, slot_index);
                return self.prepareWithoutFile(
                    driver,
                    connection_index,
                    request_index,
                    intent,
                    .not_found,
                    now_ns,
                );
            }
            try self.armWait(driver, connection_index, intent.input.connection_close, now_ns);
            try RequestIo.submitOpen(self, driver, slot_index);
        }

        pub fn responseBufferComplete(
            self: *Self,
            driver: anytype,
            connection_index: u16,
            now_ns: u64,
        ) DriverError!bool {
            const slot_index = self.slotForConnection(driver.storage, connection_index) orelse
                return false;
            const slot = &self.slots[slot_index];
            switch (slot.phase) {
                .sending_head, .sending_chunk => {},
                else => return error.StateInvariant,
            }
            if (!slot.send_pending) return error.StateInvariant;
            self.retireSendBuffer(driver.storage, slot_index);
            if (slot.remaining != 0) {
                try driver.operations.retargetTimeout(
                    driver.storage,
                    connection_index,
                    now_ns,
                    Storage.runtime_limits.timeouts.write_stall_ns,
                );
                try RequestIo.submitRead(self, driver, slot_index);
            } else {
                slot.phase = .closing_complete;
                try RequestIo.submitClose(self, driver, slot_index);
            }
            return true;
        }

        pub fn sendCompletedDuringClose(
            self: *Self,
            driver: anytype,
            connection_index: u16,
            buffer_complete: bool,
            now_ns: u64,
        ) DriverError!bool {
            const index = self.slotForConnection(driver.storage, connection_index) orelse
                return false;
            const slot = &self.slots[index];
            if (!slot.send_pending) return error.StateInvariant;
            self.retireSendBuffer(driver.storage, index);
            if (buffer_complete and slot.remaining == 0) {
                slot.completion_won = true;
                try RequestCompletion.settleClosing(self, driver, index, now_ns);
            } else {
                try RequestCompletion.settleAbort(self, driver, index);
            }
            return true;
        }

        pub fn cancelConnection(
            self: *Self,
            driver: anytype,
            connection_index: u16,
            outcome: application.TransportOutcome,
        ) DriverError!void {
            const slot_index = self.slotForConnection(driver.storage, connection_index) orelse
                return;
            const slot = &self.slots[slot_index];
            if (slot.abort_outcome == null) slot.abort_outcome = outcome;
            if (slot.send_pending and
                driver.storage.connections[connection_index].send_token == null)
            {
                self.retireSendBuffer(driver.storage, slot_index);
            }
            if (slot.prepared_valid) live_static_stage.discardPrepared(driver.storage, slot);
            if (slot.token) |target| {
                if (slot.cancel_token == null) {
                    try RequestIo.submitCancel(self, driver.operations.io, slot_index, target);
                }
                return;
            }
            if (slot.cancel_token != null) return;
            if (slot.file != null) {
                slot.phase = .closing_abort;
                try RequestIo.submitClose(self, driver, slot_index);
            } else if (!slot.send_pending) {
                RequestCompletion.finishAbort(self, driver, slot_index);
            }
        }

        pub fn activeForConnection(
            self: *const Self,
            storage: anytype,
            connection_index: u16,
        ) bool {
            return self.slotForConnection(storage, connection_index) != null;
        }

        pub fn rootsReady(self: *const Self) bool {
            return self.roots_phase == .ready;
        }

        pub fn isStopped(self: *const Self) bool {
            return self.roots_phase == .stopped and self.pendingOperations() == 0 and
                self.activeRequests() == 0;
        }

        pub fn pendingOperations(self: *const Self) u16 {
            var total: u16 = 0;
            for (self.roots) |root| {
                total += @intFromBool(root.token != null);
                total += @intFromBool(root.timeout_token != null);
                total += @intFromBool(root.cancel_token != null);
            }
            for (self.slots) |slot| {
                total += @intFromBool(slot.token != null);
                total += @intFromBool(slot.cancel_token != null);
            }
            return total;
        }

        pub fn activeRequests(self: *const Self) u16 {
            return @intCast(slot_count - @popCount(self.free_bits));
        }

        pub fn startupDiagnostic(self: *const Self) ?StartupDiagnostic {
            return self.startup_failure;
        }

        pub fn abort(self: *Self, storage: *Storage) bool {
            if (self.pendingOperations() != 0) return false;
            var ownership_proven = true;
            for (&self.roots) |*root| {
                if (root.file) |file| {
                    const result = std.os.linux.close(file.value);
                    if (std.os.linux.errno(result) != .SUCCESS) ownership_proven = false;
                }
                root.* = .{ .generation = reactor.nextGeneration(root.generation) };
            }
            for (&self.slots, 0..) |*slot, index| {
                live_static_stage.discardPrepared(storage, slot);
                if (slot.file) |file| {
                    const result = std.os.linux.close(file.value);
                    if (std.os.linux.errno(result) != .SUCCESS) ownership_proven = false;
                }
                if (slot.directory_file) |file| {
                    const result = std.os.linux.close(file.value);
                    if (std.os.linux.errno(result) != .SUCCESS) ownership_proven = false;
                }
                if (slot.phase != .free and slot.request_index < storage.requests.len) {
                    storage.requests[slot.request_index].live_static_slot = null;
                }
                std.crypto.secureZero(u8, storage.liveStaticPath(@intCast(index)));
                std.crypto.secureZero(u8, storage.liveStaticRead(@intCast(index)));
                slot.* = .{ .generation = reactor.nextGeneration(slot.generation) };
            }
            self.free_bits = if (slot_count == 64)
                std.math.maxInt(u64)
            else
                (@as(u64, 1) << @intCast(slot_count)) - 1;
            self.roots_phase = .stopped;
            self.stop_requested = true;
            return ownership_proven;
        }

        fn acquire(self: *Self) ?u16 {
            if (self.free_bits == 0) return null;
            const index: u16 = @intCast(@ctz(self.free_bits));
            self.free_bits &= ~(@as(u64, 1) << @intCast(index));
            const generation = self.slots[index].generation;
            const sequence = self.slots[index].sequence;
            self.slots[index] = .{ .generation = generation, .sequence = sequence };
            return index;
        }

        pub fn release(self: *Self, storage: anytype, index: u16) void {
            const slot = &self.slots[index];
            std.debug.assert(!slot.send_pending);
            std.debug.assert(slot.file == null and slot.directory_file == null);
            std.crypto.secureZero(u8, storage.liveStaticPath(index));
            std.crypto.secureZero(u8, storage.liveStaticRead(index));
            const generation = reactor.nextGeneration(slot.generation);
            const sequence = slot.sequence;
            slot.* = .{ .generation = generation, .sequence = sequence };
            const mask = @as(u64, 1) << @intCast(index);
            std.debug.assert(self.free_bits & mask == 0);
            self.free_bits |= mask;
        }

        fn retireSendBuffer(self: *Self, storage: anytype, index: u16) void {
            const slot = &self.slots[index];
            std.debug.assert(slot.send_pending);
            if (slot.read_used != 0) {
                std.crypto.secureZero(u8, storage.liveStaticRead(index)[0..slot.read_used]);
                slot.read_used = 0;
            }
            storage.clearResponse(slot.request_index);
            slot.send_pending = false;
        }

        fn slotForConnection(
            _: *const Self,
            storage: anytype,
            connection_index: u16,
        ) ?u16 {
            if (connection_index >= storage.connections.len) return null;
            const request_index = storage.connections[connection_index].active_request orelse
                return null;
            const request = &storage.requests[request_index];
            return request.live_static_slot;
        }

        fn armWait(
            _: *Self,
            driver: anytype,
            connection_index: u16,
            close_connection: bool,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[connection_index];
            connection.close_after_response = close_connection;
            connection.phase = .responding;
            try driver.operations.cancelReceive(driver.storage, connection_index);
            try driver.operations.retargetTimeout(
                driver.storage,
                connection_index,
                now_ns,
                Storage.runtime_limits.timeouts.write_stall_ns,
            );
        }

        fn prepareWithoutFile(
            _: *Self,
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            intent: application_types.LiveStaticIntent,
            resolution: application.LiveStaticResolution,
            now_ns: u64,
        ) DriverError!void {
            const request = &driver.storage.requests[request_index];
            const prepared = App.__prepareLiveStatic(
                &request.workspace,
                intent,
                resolution,
                driver.storage.responseWritable(request_index),
            ) catch {
                try driver.beginClose(connection_index);
                return;
            };
            try live_static_stage.normal(
                App,
                BodyTransport,
                driver,
                connection_index,
                request_index,
                prepared,
                now_ns,
            );
        }

        fn handleRequest(
            self: *Self,
            driver: anytype,
            index: u16,
            completion: reactor.Completion,
            epoch_second: i64,
            now_ns: u64,
        ) DriverError!void {
            return RequestCompletion.handle(
                self,
                driver,
                index,
                completion,
                epoch_second,
                now_ns,
            );
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
