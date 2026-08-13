const std = @import("std");
const upload_io = @import("../../../upload_io.zig");
const reactor = @import("../reactor.zig");

/// Rename borrows its tracked source and both syscall directories.
pub const operation_leases_max: u32 = 3;

pub const OwnerScope = enum(u8) {
    runtime,
    request,
};

pub const Owner = struct {
    scope: OwnerScope,
    registry_index: u16,
    instance_index: u16,
    slot: reactor.SlotIdentity,

    pub fn eql(left: Owner, right: Owner) bool {
        return left.scope == right.scope and
            left.registry_index == right.registry_index and
            left.instance_index == right.instance_index and
            left.slot.eql(right.slot);
    }
};

pub const Phase = enum(u8) {
    free,
    opening,
    open,
    closing,
    ownership_unproven,
};

pub const CloseOutcome = enum(u8) {
    closed,
    canceled,
    uncertain,
};

pub const Requirement = struct {
    kind: upload_io.OpenKind,
    access: upload_io.Access,
    create: ?upload_io.Create = null,
};

pub const Descriptor = struct {
    raw_fd: i32,
    kind: upload_io.OpenKind,
    access: upload_io.Access,
    create: upload_io.Create,
};

const path_digest_bytes = 16;

/// Allocation-free identity of the exact base incarnation and path used for an open.
pub const OpenIdentity = struct {
    base_incarnation: u64,
    path_digest: [path_digest_bytes]u8,

    fn init(base_incarnation: u64, path: []const u8) OpenIdentity {
        var path_digest: [path_digest_bytes]u8 = undefined;
        std.crypto.hash.Blake3.hash(path, &path_digest, .{});
        return .{ .base_incarnation = base_incarnation, .path_digest = path_digest };
    }

    pub fn eql(left: OpenIdentity, right: OpenIdentity) bool {
        return left.base_incarnation == right.base_incarnation and
            std.mem.eql(u8, &left.path_digest, &right.path_digest);
    }
};

pub const CleanupCursor = struct {
    next_index: u32 = 0,
};

pub const CleanupEntry = struct {
    handle: upload_io.FileHandle,
    owner: Owner,
    phase: Phase,
    descriptor: ?Descriptor,
    references: u32,
};

pub const Error = error{
    AccessDenied,
    Busy,
    Full,
    InvalidDescriptor,
    InvalidHandle,
    InvalidOpenIdentity,
    InvalidOwner,
    IncarnationExhausted,
    NoReferences,
    NotClosing,
    NotOpen,
    NotOpening,
    OwnershipUnproven,
    ReferenceOverflow,
    InvalidLease,
    StaleLease,
    StaleGeneration,
    Unknown,
    WrongCreation,
    WrongKind,
    WrongOpenIdentity,
    WrongOwner,
};

pub fn Table(comptime handle_capacity: usize, comptime lease_capacity: usize) type {
    const handle_index_capacity = @as(usize, std.math.maxInt(u16)) + 1;
    if (handle_capacity > handle_index_capacity) {
        @compileError("PLOOF-E3500 upload file table capacity exceeds u16 indices");
    }
    if (lease_capacity > std.math.maxInt(u32)) {
        @compileError("PLOOF-E3501 upload file lease capacity exceeds u32 count");
    }

    return struct {
        const Self = @This();

        const Entry = struct {
            owner: Owner = undefined,
            incarnation: u64 = 0,
            generation: u16 = 1,
            raw_fd: i32 = -1,
            references: u32 = 0,
            kind: upload_io.OpenKind = .file,
            access: upload_io.Access = .read_only,
            create: upload_io.Create = .none,
            open_identity: OpenIdentity = undefined,
            phase: Phase = .free,
        };

        const LeaseEntry = struct {
            borrower: Owner = undefined,
            handle: upload_io.FileHandle = .{ .token = 0 },
            generation: u32 = 1,
            active: bool = false,
        };

        pub const Lease = enum(u64) { _ };

        pub const Borrowed = struct {
            descriptor: Descriptor,
            lease: Lease,
        };

        pub const handles_max = handle_capacity;
        pub const leases_max = lease_capacity;
        pub const entry_bytes = @sizeOf(Entry);

        entries: [handle_capacity]Entry = @splat(.{}),
        free_indices: [handle_capacity]u16 = initialFreeIndices(handle_capacity, u16),
        free_count: u32 = @intCast(handle_capacity),
        active_count: u32 = 0,
        incarnation_cursor: u64 = 0,
        leases: [lease_capacity]LeaseEntry = @splat(.{}),
        free_lease_indices: [lease_capacity]u32 = initialFreeIndices(lease_capacity, u32),
        free_lease_count: u32 = @intCast(lease_capacity),
        ownership_proven: bool = true,

        pub fn reserveOpen(self: *Self, owner: Owner) Error!upload_io.FileHandle {
            return self.reserveOpenIdentity(owner, null);
        }

        pub fn reserveOpenAt(
            self: *Self,
            owner: Owner,
            base: upload_io.OpenBase,
            path: []const u8,
        ) Error!upload_io.FileHandle {
            const identity = try self.identityAt(owner, base, path);
            return self.reserveOpenIdentity(owner, identity);
        }

        fn reserveOpenIdentity(
            self: *Self,
            owner: Owner,
            identity: ?OpenIdentity,
        ) Error!upload_io.FileHandle {
            if (owner.slot.validate() != null) return error.InvalidOwner;
            if (!self.ownership_proven) return error.OwnershipUnproven;
            if (comptime handle_capacity == 0) return error.Full;
            if (self.free_count == 0) return error.Full;
            if (self.incarnation_cursor == std.math.maxInt(u64)) {
                return error.IncarnationExhausted;
            }

            self.free_count -= 1;
            const free_index: usize = @intCast(self.free_count);
            const index = self.free_indices[free_index];
            const entry = &self.entries[index];
            std.debug.assert(entry.phase == .free);
            std.debug.assert(entry.incarnation == 0);
            std.debug.assert(entry.generation != 0);
            self.incarnation_cursor += 1;
            entry.owner = owner;
            entry.incarnation = self.incarnation_cursor;
            entry.raw_fd = -1;
            entry.references = 0;
            if (identity) |value| entry.open_identity = value;
            entry.create = if (identity != null) .exclusive else .none;
            entry.phase = .opening;
            self.active_count += 1;
            std.debug.assert(entry.incarnation != 0);
            return upload_io.FileHandle.fromParts(index, entry.generation);
        }

        pub fn rollbackOpen(
            self: *Self,
            handle: upload_io.FileHandle,
            owner: Owner,
        ) Error!void {
            try self.retireOpening(handle, owner);
        }

        pub fn completeOpenFailure(
            self: *Self,
            handle: upload_io.FileHandle,
            owner: Owner,
        ) Error!void {
            try self.retireOpening(handle, owner);
        }

        pub fn completeOpenPositive(
            self: *Self,
            handle: upload_io.FileHandle,
            owner: Owner,
            raw_fd: i32,
            kind: upload_io.OpenKind,
            access: upload_io.Access,
            create: upload_io.Create,
        ) Error!void {
            if (raw_fd < 0) return error.InvalidDescriptor;
            const entry = try self.requireEntry(handle);
            try requireExactOwner(entry.owner, owner);
            if (entry.phase != .opening) return error.NotOpening;
            if ((create == .exclusive) != (entry.create == .exclusive)) {
                return error.InvalidOpenIdentity;
            }

            entry.raw_fd = raw_fd;
            entry.kind = kind;
            entry.access = access;
            entry.create = create;
            entry.references = 0;
            entry.phase = .open;
        }

        pub fn borrow(
            self: *Self,
            handle: upload_io.FileHandle,
            borrower: Owner,
            requirement: Requirement,
        ) Error!Borrowed {
            return self.borrowInternal(handle, borrower, requirement, null);
        }

        pub fn borrowOpenedAt(
            self: *Self,
            handle: upload_io.FileHandle,
            borrower: Owner,
            requirement: Requirement,
            base: upload_io.OpenBase,
            path: []const u8,
        ) Error!Borrowed {
            if (requirement.create != .exclusive) return error.InvalidOpenIdentity;
            const identity = try self.identityAt(borrower, base, path);
            return self.borrowInternal(handle, borrower, requirement, identity);
        }

        pub fn identityAt(
            self: *const Self,
            borrower: Owner,
            base: upload_io.OpenBase,
            path: []const u8,
        ) Error!OpenIdentity {
            if (borrower.slot.validate() != null) return error.InvalidOwner;
            if (!self.ownership_proven) return error.OwnershipUnproven;
            const base_incarnation = switch (base) {
                .working_directory => 0,
                .handle => |handle| try self.directoryIncarnation(handle, borrower),
            };
            return OpenIdentity.init(base_incarnation, path);
        }

        fn borrowInternal(
            self: *Self,
            handle: upload_io.FileHandle,
            borrower: Owner,
            requirement: Requirement,
            identity: ?OpenIdentity,
        ) Error!Borrowed {
            if (borrower.slot.validate() != null) return error.InvalidOwner;
            if (!self.ownership_proven) return error.OwnershipUnproven;
            const entry = try self.requireEntry(handle);
            if (entry.phase != .open) return error.NotOpen;
            if (!mayBorrow(entry.*, borrower)) return error.WrongOwner;
            if (entry.kind != requirement.kind) return error.WrongKind;
            if (!allows(entry.access, requirement.access)) return error.AccessDenied;
            if (requirement.create) |create| {
                if (entry.create != create) return error.WrongCreation;
            }
            if (identity) |expected| {
                if (!entry.open_identity.eql(expected)) return error.WrongOpenIdentity;
            }
            if (entry.references == std.math.maxInt(u32)) return error.ReferenceOverflow;
            const lease = try self.reserveLease(handle, borrower);
            entry.references += 1;
            return .{ .descriptor = descriptor(entry.*), .lease = lease };
        }

        pub fn releaseBorrow(
            self: *Self,
            lease: Lease,
            borrower: Owner,
        ) Error!void {
            if (borrower.slot.validate() != null) return error.InvalidOwner;
            const lease_entry = try self.requireLease(lease);
            try requireExactOwner(lease_entry.borrower, borrower);
            const entry = try self.requireEntry(lease_entry.handle);
            if (entry.phase != .open) return error.NotOpen;
            if (entry.references == 0) return error.NoReferences;
            entry.references -= 1;
            self.releaseLease(leaseIndex(lease));
        }

        pub fn beginClose(
            self: *Self,
            handle: upload_io.FileHandle,
            owner: Owner,
        ) Error!Descriptor {
            const entry = try self.requireEntry(handle);
            try requireExactOwner(entry.owner, owner);
            if (entry.phase != .open) return error.NotOpen;
            if (entry.references != 0) return error.Busy;
            entry.phase = .closing;
            return descriptor(entry.*);
        }

        pub fn completeClose(
            self: *Self,
            handle: upload_io.FileHandle,
            owner: Owner,
            outcome: CloseOutcome,
        ) Error!void {
            const entry = try self.requireEntry(handle);
            try requireExactOwner(entry.owner, owner);
            if (entry.phase != .closing) return error.NotClosing;
            std.debug.assert(entry.references == 0);

            switch (outcome) {
                .closed => self.releaseEntry(handle.index()),
                .canceled => entry.phase = .open,
                .uncertain => {
                    entry.phase = .ownership_unproven;
                    self.ownership_proven = false;
                },
            }
        }

        pub fn phase(self: *const Self, handle: upload_io.FileHandle) Error!Phase {
            return (try self.requireEntryConst(handle)).phase;
        }

        pub fn references(
            self: *const Self,
            handle: upload_io.FileHandle,
            owner: Owner,
        ) Error!u32 {
            const entry = try self.requireEntryConst(handle);
            try requireExactOwner(entry.owner, owner);
            return entry.references;
        }

        pub fn active(self: *const Self) u32 {
            return self.active_count;
        }

        pub fn incarnation(
            self: *const Self,
            handle: upload_io.FileHandle,
        ) Error!u64 {
            return (try self.requireEntryConst(handle)).incarnation;
        }

        pub fn available(self: *const Self) u32 {
            return self.free_count;
        }

        pub fn ownershipProven(self: *const Self) bool {
            return self.ownership_proven;
        }

        pub fn abandon(
            self: *Self,
            handle: upload_io.FileHandle,
            owner: Owner,
        ) Error!void {
            const entry = try self.requireEntry(handle);
            try requireExactOwner(entry.owner, owner);
            entry.phase = .ownership_unproven;
            self.ownership_proven = false;
        }

        pub fn nextCleanup(
            self: *const Self,
            cursor: *CleanupCursor,
        ) ?CleanupEntry {
            while (cursor.next_index < handle_capacity) {
                const index = cursor.next_index;
                cursor.next_index += 1;
                const entry = self.entries[index];
                if (entry.phase == .free) continue;
                return cleanupEntry(@intCast(index), entry);
            }
            return null;
        }

        fn retireOpening(
            self: *Self,
            handle: upload_io.FileHandle,
            owner: Owner,
        ) Error!void {
            const entry = try self.requireEntry(handle);
            try requireExactOwner(entry.owner, owner);
            if (entry.phase != .opening) return error.NotOpening;
            self.releaseEntry(handle.index());
        }

        fn releaseEntry(self: *Self, index: u16) void {
            const entry = &self.entries[index];
            std.debug.assert(entry.phase != .free);
            std.debug.assert(entry.references == 0);
            std.debug.assert(self.active_count > 0);
            std.debug.assert(self.free_count < handle_capacity);
            entry.generation = reactor.nextGeneration(entry.generation);
            entry.incarnation = 0;
            entry.raw_fd = -1;
            entry.references = 0;
            entry.create = .none;
            entry.phase = .free;
            self.free_indices[self.free_count] = index;
            self.free_count += 1;
            self.active_count -= 1;
        }

        fn requireEntry(
            self: *Self,
            handle: upload_io.FileHandle,
        ) Error!*Entry {
            const index = try checkedIndex(handle);
            const entry = &self.entries[index];
            if (entry.generation != handle.generation()) return error.StaleGeneration;
            if (entry.phase == .free) return error.Unknown;
            return entry;
        }

        fn requireEntryConst(
            self: *const Self,
            handle: upload_io.FileHandle,
        ) Error!*const Entry {
            const index = try checkedIndex(handle);
            const entry = &self.entries[index];
            if (entry.generation != handle.generation()) return error.StaleGeneration;
            if (entry.phase == .free) return error.Unknown;
            return entry;
        }

        fn checkedIndex(handle: upload_io.FileHandle) Error!u16 {
            if (!handle.valid()) return error.InvalidHandle;
            if (@as(usize, handle.index()) >= handle_capacity) return error.InvalidHandle;
            return handle.index();
        }

        fn directoryIncarnation(
            self: *const Self,
            handle: upload_io.FileHandle,
            borrower: Owner,
        ) Error!u64 {
            const entry = try self.requireEntryConst(handle);
            if (entry.phase != .open) return error.NotOpen;
            if (!mayBorrow(entry.*, borrower)) return error.WrongOwner;
            if (entry.kind != .directory) return error.WrongKind;
            if (!allows(entry.access, .read_only)) return error.AccessDenied;
            std.debug.assert(entry.incarnation != 0);
            return entry.incarnation;
        }

        fn reserveLease(
            self: *Self,
            handle: upload_io.FileHandle,
            borrower: Owner,
        ) Error!Lease {
            if (comptime lease_capacity == 0) return error.Full;
            if (self.free_lease_count == 0) return error.Full;
            self.free_lease_count -= 1;
            const free_index: usize = @intCast(self.free_lease_count);
            const index = self.free_lease_indices[free_index];
            const entry = &self.leases[index];
            std.debug.assert(!entry.active);
            entry.borrower = borrower;
            entry.handle = handle;
            entry.active = true;
            return leaseFromParts(index, entry.generation);
        }

        fn requireLease(self: *Self, lease: Lease) Error!*LeaseEntry {
            const index = leaseIndex(lease);
            if (leaseGeneration(lease) == 0) return error.InvalidLease;
            if (@as(usize, index) >= lease_capacity) return error.InvalidLease;
            const entry = &self.leases[index];
            if (!entry.active or entry.generation != leaseGeneration(lease)) {
                return error.StaleLease;
            }
            return entry;
        }

        fn releaseLease(self: *Self, index: u32) void {
            const entry = &self.leases[index];
            std.debug.assert(entry.active);
            std.debug.assert(self.free_lease_count < lease_capacity);
            entry.generation = nextLeaseGeneration(entry.generation);
            entry.handle = .{ .token = 0 };
            entry.active = false;
            self.free_lease_indices[self.free_lease_count] = index;
            self.free_lease_count += 1;
        }

        fn leaseFromParts(index: u32, generation: u32) Lease {
            std.debug.assert(generation != 0);
            return @enumFromInt(@as(u64, index) | (@as(u64, generation) << 32));
        }

        fn leaseIndex(lease: Lease) u32 {
            return @truncate(@intFromEnum(lease));
        }

        fn leaseGeneration(lease: Lease) u32 {
            return @truncate(@intFromEnum(lease) >> 32);
        }

        fn nextLeaseGeneration(generation: u32) u32 {
            return if (generation == std.math.maxInt(u32)) 1 else generation + 1;
        }

        fn initialFreeIndices(comptime count: usize, comptime Index: type) [count]Index {
            @setEvalBranchQuota(@max(1_000, count * 2));
            var indices: [count]Index = undefined;
            for (&indices, 0..) |*index, position| {
                index.* = @intCast(count - 1 - position);
            }
            return indices;
        }
    };
}

fn requireExactOwner(stored: Owner, provided: Owner) Error!void {
    if (!stored.eql(provided)) return error.WrongOwner;
}

fn mayBorrow(entry: anytype, borrower: Owner) bool {
    if (entry.owner.eql(borrower)) return true;
    return entry.kind == .directory and
        entry.owner.scope == .runtime and
        borrower.scope == .request and
        entry.owner.registry_index == borrower.registry_index and
        entry.owner.slot.worker_index == borrower.slot.worker_index;
}

fn allows(stored: upload_io.Access, requested: upload_io.Access) bool {
    return switch (stored) {
        .read_only => requested == .read_only,
        .write_only => requested == .write_only,
        .read_write => true,
    };
}

fn descriptor(entry: anytype) Descriptor {
    std.debug.assert(entry.raw_fd >= 0);
    return .{
        .raw_fd = entry.raw_fd,
        .kind = entry.kind,
        .access = entry.access,
        .create = entry.create,
    };
}

fn cleanupEntry(index: u16, entry: anytype) CleanupEntry {
    return .{
        .handle = upload_io.FileHandle.fromParts(index, entry.generation),
        .owner = entry.owner,
        .phase = entry.phase,
        .descriptor = if (entry.raw_fd >= 0) descriptor(entry) else null,
        .references = entry.references,
    };
}
