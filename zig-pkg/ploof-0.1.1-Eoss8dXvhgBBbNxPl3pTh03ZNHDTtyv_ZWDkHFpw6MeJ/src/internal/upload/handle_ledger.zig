const std = @import("std");
const upload_io = @import("../../upload_io.zig");

pub const Phase = enum(u8) {
    open,
    closing,
};

pub const EmergencyReason = enum(u8) {
    malformed_open,
    unexpected_open,
};

pub const CloseOutcome = enum(u8) {
    closed,
    uncertain,
};

pub const Error = error{
    InvalidHandle,
    InvalidEmergencyReason,
    Duplicate,
    Full,
    Unknown,
    WrongOwner,
    AlreadyClosing,
    NotClosing,
};

const StoredPhase = enum(u8) {
    vacant,
    open,
    closing,
};

pub fn Ledger(
    comptime Owner: type,
    comptime expected_capacity: usize,
    comptime emergency_slots: usize,
) type {
    const index_capacity = @as(usize, std.math.maxInt(u16)) + 1;
    if (expected_capacity > index_capacity) {
        @compileError("PLOOF-E3488 upload handle ledger capacity exceeds u16 indices");
    }
    if (emergency_slots > index_capacity) {
        @compileError("PLOOF-E3489 upload emergency handle slots exceed u16 indices");
    }

    return struct {
        const Self = @This();

        pub const expected_handles_max = expected_capacity;
        pub const emergency_handles_max = emergency_slots;

        pub const EmergencyId = struct {
            token: u32,

            fn fromParts(slot_index: u16, slot_generation: u16) EmergencyId {
                return .{
                    .token = @as(u32, slot_index) |
                        (@as(u32, slot_generation) << 16),
                };
            }

            pub fn index(self: EmergencyId) u16 {
                return @truncate(self.token);
            }

            pub fn generation(self: EmergencyId) u16 {
                return @truncate(self.token >> 16);
            }

            pub fn eql(left: EmergencyId, right: EmergencyId) bool {
                return left.token == right.token;
            }

            pub fn valid(self: EmergencyId) bool {
                return self.generation() != 0;
            }
        };

        pub const OpenRecord = union(enum) {
            expected,
            emergency: EmergencyId,
        };

        const Entry = struct {
            handle: upload_io.FileHandle = upload_io.FileHandle.fromParts(0, 0),
            owner: Owner = undefined,
            phase: StoredPhase = .vacant,
        };

        const EmergencyEntry = struct {
            observed: upload_io.FileHandle = upload_io.FileHandle.fromParts(0, 0),
            owner: Owner = undefined,
            reason: EmergencyReason = .unexpected_open,
            generation: u16 = 1,
            phase: StoredPhase = .vacant,
        };

        expected: [expected_capacity]Entry = @splat(.{}),
        emergency: [emergency_slots]EmergencyEntry = @splat(.{}),
        ownership_proven: bool = true,

        pub fn recordOpen(
            self: *Self,
            handle: upload_io.FileHandle,
            owner_value: Owner,
        ) Error!void {
            if (!handle.valid()) return error.InvalidHandle;
            if (self.emergencyContains(handle)) return error.Duplicate;
            if (expected_capacity == 0) return error.Full;
            var vacant: ?usize = null;
            for (&self.expected, 0..) |*entry, index| {
                if (entry.phase == .vacant) {
                    if (vacant == null) vacant = index;
                    continue;
                }
                if (entry.handle.index() == handle.index()) return error.Duplicate;
            }
            const index = vacant orelse return error.Full;
            self.expected[index] = .{
                .handle = handle,
                .owner = owner_value,
                .phase = .open,
            };
        }

        pub fn recordOpenOrEmergency(
            self: *Self,
            handle: upload_io.FileHandle,
            owner_value: Owner,
        ) Error!OpenRecord {
            if (!handle.valid()) return .{ .emergency = try self.retainEmergency(
                handle,
                owner_value,
                .malformed_open,
            ) };
            self.recordOpen(handle, owner_value) catch |problem| switch (problem) {
                error.Duplicate => {
                    self.ownership_proven = false;
                    return error.Duplicate;
                },
                error.Full => return .{ .emergency = try self.retainEmergency(
                    handle,
                    owner_value,
                    .unexpected_open,
                ) },
                else => return problem,
            };
            return .expected;
        }

        pub fn retainEmergency(
            self: *Self,
            observed: upload_io.FileHandle,
            owner_value: Owner,
            reason: EmergencyReason,
        ) Error!EmergencyId {
            if (reasonMatchesHandle(reason, observed)) {
                if (observed.valid() and self.containsExpected(observed)) {
                    return error.Duplicate;
                }
                for (&self.emergency, 0..) |*entry, index| {
                    if (entry.phase != .vacant and observed.valid() and
                        entry.observed.index() == observed.index())
                    {
                        return error.Duplicate;
                    }
                    if (entry.phase != .vacant) continue;
                    entry.observed = observed;
                    entry.owner = owner_value;
                    entry.reason = reason;
                    entry.phase = .open;
                    if (reason == .malformed_open) self.ownership_proven = false;
                    return EmergencyId.fromParts(@intCast(index), entry.generation);
                }
                self.ownership_proven = false;
                return error.Full;
            }
            return error.InvalidEmergencyReason;
        }

        pub fn owner(self: *const Self, handle: upload_io.FileHandle) Error!Owner {
            return self.expected[try self.expectedIndex(handle)].owner;
        }

        pub fn phase(
            self: *const Self,
            handle: upload_io.FileHandle,
            owner_value: Owner,
        ) Error!Phase {
            const entry = self.expected[try self.expectedIndex(handle)];
            try requireOwner(entry.owner, owner_value);
            return publicPhase(entry.phase);
        }

        pub fn beginClose(
            self: *Self,
            handle: upload_io.FileHandle,
            owner_value: Owner,
        ) Error!void {
            const entry = &self.expected[try self.expectedIndex(handle)];
            try requireOwner(entry.owner, owner_value);
            if (entry.phase == .closing) return error.AlreadyClosing;
            std.debug.assert(entry.phase == .open);
            entry.phase = .closing;
        }

        pub fn rollbackClose(
            self: *Self,
            handle: upload_io.FileHandle,
            owner_value: Owner,
        ) Error!void {
            const entry = &self.expected[try self.expectedIndex(handle)];
            try requireOwner(entry.owner, owner_value);
            if (entry.phase != .closing) return error.NotClosing;
            entry.phase = .open;
        }

        pub fn completeClose(
            self: *Self,
            handle: upload_io.FileHandle,
            owner_value: Owner,
            outcome: CloseOutcome,
        ) Error!void {
            const index = try self.expectedIndex(handle);
            const entry = &self.expected[index];
            try requireOwner(entry.owner, owner_value);
            if (entry.phase != .closing) return error.NotClosing;
            switch (outcome) {
                .closed => entry.* = .{},
                .uncertain => self.ownership_proven = false,
            }
        }

        pub fn emergencyObserved(
            self: *const Self,
            id: EmergencyId,
        ) Error!upload_io.FileHandle {
            return self.emergency[try self.emergencyIndex(id)].observed;
        }

        pub fn emergencyReason(
            self: *const Self,
            id: EmergencyId,
        ) Error!EmergencyReason {
            return self.emergency[try self.emergencyIndex(id)].reason;
        }

        pub fn emergencyPhase(
            self: *const Self,
            id: EmergencyId,
            owner_value: Owner,
        ) Error!Phase {
            const entry = self.emergency[try self.emergencyIndex(id)];
            try requireOwner(entry.owner, owner_value);
            return publicPhase(entry.phase);
        }

        pub fn beginEmergencyClose(
            self: *Self,
            id: EmergencyId,
            owner_value: Owner,
        ) Error!void {
            const entry = &self.emergency[try self.emergencyIndex(id)];
            try requireOwner(entry.owner, owner_value);
            if (entry.phase == .closing) return error.AlreadyClosing;
            std.debug.assert(entry.phase == .open);
            entry.phase = .closing;
        }

        pub fn rollbackEmergencyClose(
            self: *Self,
            id: EmergencyId,
            owner_value: Owner,
        ) Error!void {
            const entry = &self.emergency[try self.emergencyIndex(id)];
            try requireOwner(entry.owner, owner_value);
            if (entry.phase != .closing) return error.NotClosing;
            entry.phase = .open;
        }

        pub fn completeEmergencyClose(
            self: *Self,
            id: EmergencyId,
            owner_value: Owner,
            outcome: CloseOutcome,
        ) Error!void {
            const entry = &self.emergency[try self.emergencyIndex(id)];
            try requireOwner(entry.owner, owner_value);
            if (entry.phase != .closing) return error.NotClosing;
            switch (outcome) {
                .closed => {
                    const generation = nextGeneration(entry.generation);
                    entry.* = .{ .generation = generation };
                },
                .uncertain => self.ownership_proven = false,
            }
        }

        pub fn expectedCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.expected) |entry| count += @intFromBool(entry.phase != .vacant);
            return count;
        }

        pub fn emergencyCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.emergency) |entry| count += @intFromBool(entry.phase != .vacant);
            return count;
        }

        pub fn ownershipProven(self: *const Self) bool {
            return self.ownership_proven;
        }

        fn expectedIndex(
            self: *const Self,
            handle: upload_io.FileHandle,
        ) Error!usize {
            if (!handle.valid()) return error.InvalidHandle;
            for (self.expected, 0..) |entry, index| {
                if (entry.phase != .vacant and entry.handle.eql(handle)) return index;
            }
            return error.Unknown;
        }

        fn emergencyIndex(self: *const Self, id: EmergencyId) Error!usize {
            if (!id.valid() or id.index() >= self.emergency.len) return error.Unknown;
            const index: usize = id.index();
            const entry = self.emergency[index];
            if (entry.phase == .vacant or entry.generation != id.generation()) {
                return error.Unknown;
            }
            return index;
        }

        fn containsExpected(
            self: *const Self,
            handle: upload_io.FileHandle,
        ) bool {
            for (self.expected) |entry| {
                if (entry.phase != .vacant and
                    entry.handle.index() == handle.index()) return true;
            }
            return false;
        }

        fn emergencyContains(
            self: *const Self,
            handle: upload_io.FileHandle,
        ) bool {
            for (self.emergency) |entry| {
                if (entry.phase != .vacant and entry.observed.valid() and
                    entry.observed.index() == handle.index()) return true;
            }
            return false;
        }

        fn requireOwner(actual: Owner, expected: Owner) Error!void {
            if (!std.meta.eql(actual, expected)) return error.WrongOwner;
        }
    };
}

fn publicPhase(phase: StoredPhase) Phase {
    return switch (phase) {
        .open => .open,
        .closing => .closing,
        .vacant => unreachable,
    };
}

fn reasonMatchesHandle(reason: EmergencyReason, handle: upload_io.FileHandle) bool {
    return switch (reason) {
        .malformed_open => !handle.valid(),
        .unexpected_open => handle.valid(),
    };
}

fn nextGeneration(generation: u16) u16 {
    std.debug.assert(generation != 0);
    return if (generation == std.math.maxInt(u16)) 1 else generation + 1;
}

test {
    std.testing.refAllDecls(@This());
}
