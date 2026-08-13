const std = @import("std");
const linux = std.os.linux;

const IoUring = linux.IoUring;
const page_size_min = std.heap.page_size_min;

const ConfigurationIssue = enum(u8) {
    count_out_of_range,
    count_not_power_of_two,
    size_out_of_range,
};

fn configurationIssue(buffer_count: usize, buffer_size: usize) ?ConfigurationIssue {
    if (buffer_count == 0 or buffer_count > 1 << 15) return .count_out_of_range;
    if (!std.math.isPowerOfTwo(buffer_count)) return .count_not_power_of_two;
    if (buffer_size == 0 or buffer_size > std.math.maxInt(u32)) {
        return .size_out_of_range;
    }
    return null;
}

/// Non-incremental io_uring provided buffers owned by one reactor thread.
///
/// `buffers` must remain at the same address from `register` through `deinit`.
/// Registration and all borrow/recycle calls must use the ring's single issuer.
pub fn BufferRing(
    comptime buffer_count: u16,
    comptime buffer_size: u32,
    comptime group_id: u16,
) type {
    comptime {
        if (configurationIssue(buffer_count, buffer_size)) |issue| {
            @compileError(switch (issue) {
                .count_out_of_range => "provided buffer count must be in the range 1...32768",
                .count_not_power_of_two => "provided buffer count must be a power of two",
                .size_out_of_range => "provided buffer size must be in the range 1...maxInt(u32)",
            });
        }
    }

    return struct {
        const Self = @This();
        const BorrowedSet = std.StaticBitSet(buffer_count);

        const State = enum(u8) {
            empty,
            registered,
            unregistered,
        };

        pub const count: u16 = buffer_count;
        pub const size: u32 = buffer_size;
        pub const group: u16 = group_id;
        pub const descriptor_bytes: usize =
            @as(usize, buffer_count) * @sizeOf(linux.io_uring_buf);
        pub const Buffers = [buffer_count][buffer_size]u8;

        pub const Borrowed = struct {
            buffer_id: u16,
            bytes: []const u8,
        };

        pub const RegisterError = std.posix.MMapError || error{
            AlreadyRegistered,
            GroupAlreadyRegistered,
            RegistrationRejected,
            RegistrationResourceLimit,
            RegistrationPermissionDenied,
            RingClosed,
            RegistrationFailed,
        };

        pub const BorrowError = error{
            NotRegistered,
            CompletionFailed,
            NoBufferSelected,
            IncrementalBufferCompletion,
            BufferIdOutOfRange,
            BufferLengthOutOfRange,
            BufferAlreadyBorrowed,
        };

        pub const RecycleError = error{
            NotRegistered,
            BufferIdOutOfRange,
            BufferNotBorrowed,
            BorrowedSliceInvalid,
        };

        pub const UnregisterError = error{
            NotRegistered,
            BuffersBorrowed,
            RegistrationMissing,
            UnregisterRejected,
            RingClosed,
            UnregisterFailed,
        };

        pub const UnmapError = error{
            NotMapped,
            StillRegistered,
        };

        state: State = .empty,
        fd: linux.fd_t = -1,
        mapping: ?[]align(page_size_min) u8 = null,
        descriptor_ring: ?*align(page_size_min) linux.io_uring_buf_ring = null,
        buffers: ?*Buffers = null,
        borrowed: BorrowedSet = .empty,
        borrowed_count: u16 = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn mappedBytes(self: *const Self) ?usize {
            return if (self.mapping) |mapping| mapping.len else null;
        }

        /// Maps and registers descriptors, then publishes every caller-owned buffer.
        pub fn register(self: *Self, ring: *IoUring, buffers: *Buffers) RegisterError!void {
            self.assertInvariants();
            if (self.state != .empty) return error.AlreadyRegistered;

            const mapping = try std.posix.mmap(
                null,
                descriptor_bytes,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                -1,
                0,
            );
            errdefer std.posix.munmap(mapping);

            const descriptor_ring: *align(page_size_min) linux.io_uring_buf_ring =
                @ptrCast(mapping.ptr);
            try registerDescriptors(ring.fd, descriptor_ring);
            initializeDescriptors(descriptor_ring, buffers);

            self.* = .{
                .state = .registered,
                .fd = ring.fd,
                .mapping = mapping,
                .descriptor_ring = descriptor_ring,
                .buffers = buffers,
            };
            self.assertInvariants();
        }

        /// Borrows bytes selected by a successful receive completion.
        /// `result` and `flags` are normalized CQE fields; no CQE type crosses this API.
        pub fn borrow(self: *Self, result: i32, flags: u32) BorrowError!Borrowed {
            self.assertInvariants();
            if (self.state != .registered) return error.NotRegistered;
            if (result < 0) return error.CompletionFailed;
            if (flags & linux.IORING_CQE_F_BUFFER == 0) return error.NoBufferSelected;
            if (flags & linux.IORING_CQE_F_BUF_MORE != 0) {
                return error.IncrementalBufferCompletion;
            }

            const buffer_id: u16 = @intCast(flags >> linux.IORING_CQE_BUFFER_SHIFT);
            if (buffer_id >= buffer_count) return error.BufferIdOutOfRange;

            const length: usize = @intCast(result);
            if (length > buffer_size) return error.BufferLengthOutOfRange;
            if (self.borrowed.isSet(buffer_id)) return error.BufferAlreadyBorrowed;

            std.debug.assert(self.borrowed_count < buffer_count);
            self.borrowed.set(buffer_id);
            self.borrowed_count += 1;

            const buffers = self.buffers.?;
            const borrowed = Borrowed{
                .buffer_id = buffer_id,
                .bytes = buffers[buffer_id][0..length],
            };
            self.assertInvariants();
            return borrowed;
        }

        /// Returns one previously borrowed buffer to the kernel.
        pub fn recycle(self: *Self, loan: Borrowed) RecycleError!void {
            self.assertInvariants();
            if (self.state != .registered) return error.NotRegistered;
            if (loan.buffer_id >= buffer_count) return error.BufferIdOutOfRange;
            if (!self.borrowed.isSet(loan.buffer_id)) return error.BufferNotBorrowed;

            const buffers = self.buffers.?;
            const buffer = &buffers[loan.buffer_id];
            if (@intFromPtr(loan.bytes.ptr) != @intFromPtr(buffer) or
                loan.bytes.len > buffer_size)
            {
                return error.BorrowedSliceInvalid;
            }

            IoUring.buf_ring_add(
                self.descriptor_ring.?,
                buffer,
                loan.buffer_id,
                IoUring.buf_ring_mask(buffer_count),
                0,
            );
            IoUring.buf_ring_advance(self.descriptor_ring.?, 1);
            self.borrowed.unset(loan.buffer_id);
            self.borrowed_count -= 1;
            self.assertInvariants();
        }

        /// Unregisters descriptors. All borrowed slices must be recycled first.
        pub fn unregister(self: *Self) UnregisterError!void {
            self.assertInvariants();
            if (self.state != .registered) return error.NotRegistered;
            if (self.borrowed_count != 0) return error.BuffersBorrowed;

            try unregisterDescriptors(self.fd);
            std.crypto.secureZero(u8, std.mem.asBytes(self.buffers.?));
            self.state = .unregistered;
            self.fd = -1;
            self.buffers = null;
            self.assertInvariants();
        }

        /// Unmaps descriptors after successful kernel unregistration.
        pub fn unmap(self: *Self) UnmapError!void {
            self.assertInvariants();
            if (self.state == .empty) return error.NotMapped;
            if (self.state == .registered) return error.StillRegistered;

            std.posix.munmap(self.mapping.?);
            self.* = Self.init();
            self.assertInvariants();
        }

        pub fn deinit(self: *Self) (UnregisterError || UnmapError)!void {
            try self.unregister();
            try self.unmap();
        }

        /// Fatal-only teardown after the owning ring fd is closed.
        pub fn forceAbandonAfterRingClose(self: *Self) void {
            self.assertInvariants();
            std.debug.assert(self.state == .registered);
            std.crypto.secureZero(u8, std.mem.asBytes(self.buffers.?));
            std.posix.munmap(self.mapping.?);
            self.* = Self.init();
            self.assertInvariants();
        }

        pub fn isRegistered(self: *const Self) bool {
            self.assertInvariants();
            return self.state == .registered;
        }

        pub fn borrowedCount(self: *const Self) u16 {
            self.assertInvariants();
            return self.borrowed_count;
        }

        fn registerDescriptors(
            fd: linux.fd_t,
            descriptor_ring: *align(page_size_min) linux.io_uring_buf_ring,
        ) RegisterError!void {
            var registration = std.mem.zeroInit(linux.io_uring_buf_reg, .{
                .ring_addr = @intFromPtr(descriptor_ring),
                .ring_entries = buffer_count,
                .bgid = group_id,
                .flags = linux.io_uring_buf_reg.Flags{ .inc = false },
            });
            const result = linux.io_uring_register(
                fd,
                .REGISTER_PBUF_RING,
                @ptrCast(&registration),
                1,
            );
            switch (linux.errno(result)) {
                .SUCCESS => {},
                .EXIST => return error.GroupAlreadyRegistered,
                .INVAL, .OPNOTSUPP => return error.RegistrationRejected,
                .NOMEM => return error.RegistrationResourceLimit,
                .ACCES, .PERM => return error.RegistrationPermissionDenied,
                .BADF => return error.RingClosed,
                else => return error.RegistrationFailed,
            }
        }

        fn unregisterDescriptors(fd: linux.fd_t) UnregisterError!void {
            var registration = std.mem.zeroInit(linux.io_uring_buf_reg, .{
                .bgid = group_id,
            });
            const result = linux.io_uring_register(
                fd,
                .UNREGISTER_PBUF_RING,
                @ptrCast(&registration),
                1,
            );
            switch (linux.errno(result)) {
                .SUCCESS => {},
                .NOENT => return error.RegistrationMissing,
                .INVAL => return error.UnregisterRejected,
                .BADF => return error.RingClosed,
                else => return error.UnregisterFailed,
            }
        }

        fn initializeDescriptors(
            descriptor_ring: *align(page_size_min) linux.io_uring_buf_ring,
            buffers: *Buffers,
        ) void {
            IoUring.buf_ring_init(descriptor_ring);
            const mask = IoUring.buf_ring_mask(buffer_count);
            for (buffers, 0..) |*buffer, index| {
                IoUring.buf_ring_add(
                    descriptor_ring,
                    buffer,
                    @intCast(index),
                    mask,
                    @intCast(index),
                );
            }
            IoUring.buf_ring_advance(descriptor_ring, buffer_count);
        }

        fn attachForTest(
            self: *Self,
            mapping: []align(page_size_min) u8,
            buffers: *Buffers,
        ) void {
            std.debug.assert(mapping.len == descriptor_bytes);
            const descriptor_ring: *align(page_size_min) linux.io_uring_buf_ring =
                @ptrCast(mapping.ptr);
            initializeDescriptors(descriptor_ring, buffers);
            self.* = .{
                .state = .registered,
                .fd = 42,
                .mapping = mapping,
                .descriptor_ring = descriptor_ring,
                .buffers = buffers,
            };
            self.assertInvariants();
        }

        fn assertInvariants(self: *const Self) void {
            std.debug.assert(self.borrowed.count() == self.borrowed_count);
            std.debug.assert(self.borrowed_count <= buffer_count);
            switch (self.state) {
                .empty => {
                    std.debug.assert(self.fd == -1);
                    std.debug.assert(self.mapping == null);
                    std.debug.assert(self.descriptor_ring == null);
                    std.debug.assert(self.buffers == null);
                    std.debug.assert(self.borrowed_count == 0);
                },
                .registered => {
                    std.debug.assert(self.fd >= 0);
                    std.debug.assert(self.mapping != null);
                    std.debug.assert(self.mapping.?.len == descriptor_bytes);
                    std.debug.assert(self.descriptor_ring != null);
                    std.debug.assert(self.buffers != null);
                },
                .unregistered => {
                    std.debug.assert(self.fd == -1);
                    std.debug.assert(self.mapping != null);
                    std.debug.assert(self.mapping.?.len == descriptor_bytes);
                    std.debug.assert(self.descriptor_ring != null);
                    std.debug.assert(self.buffers == null);
                    std.debug.assert(self.borrowed_count == 0);
                },
            }
        }
    };
}

fn completionFlags(buffer_id: u16, extra: u32) u32 {
    return linux.IORING_CQE_F_BUFFER |
        (@as(u32, buffer_id) << linux.IORING_CQE_BUFFER_SHIFT) |
        extra;
}

test "buffer ring configuration validation is exact" {
    try std.testing.expectEqual(
        ConfigurationIssue.count_out_of_range,
        configurationIssue(0, 1).?,
    );
    try std.testing.expectEqual(
        ConfigurationIssue.count_not_power_of_two,
        configurationIssue(3, 1).?,
    );
    try std.testing.expectEqual(
        ConfigurationIssue.count_out_of_range,
        configurationIssue((1 << 15) + 1, 1).?,
    );
    try std.testing.expectEqual(
        ConfigurationIssue.size_out_of_range,
        configurationIssue(4, 0).?,
    );
    try std.testing.expectEqual(
        ConfigurationIssue.size_out_of_range,
        configurationIssue(4, @as(usize, std.math.maxInt(u32)) + 1).?,
    );
    try std.testing.expectEqual(null, configurationIssue(1, 1));
    try std.testing.expectEqual(null, configurationIssue(1 << 15, 1));

    const Ring = BufferRing(4, 16, 7);
    try std.testing.expectEqual(@as(u16, 4), Ring.count);
    try std.testing.expectEqual(@as(u32, 16), Ring.size);
    try std.testing.expectEqual(@as(u16, 7), Ring.group);
    try std.testing.expectEqual(@as(usize, 64), Ring.descriptor_bytes);
}

test "buffer ring declarations compile" {
    std.testing.refAllDecls(BufferRing(4, 16, 7));
}

test "buffer ring populates descriptors and recycles a checked loan" {
    const Ring = BufferRing(4, 16, 7);
    var descriptor_storage: [Ring.descriptor_bytes]u8 align(page_size_min) =
        [_]u8{0} ** Ring.descriptor_bytes;
    var buffers: Ring.Buffers = undefined;
    var group = Ring.init();
    group.attachForTest(descriptor_storage[0..], &buffers);

    const descriptor_ring = group.descriptor_ring.?;
    const descriptors: [*]linux.io_uring_buf = @ptrCast(descriptor_ring);
    try std.testing.expectEqual(Ring.count, descriptor_ring.tail);
    for (0..Ring.count) |index| {
        try std.testing.expectEqual(@intFromPtr(&buffers[index]), descriptors[index].addr);
        try std.testing.expectEqual(Ring.size, descriptors[index].len);
        try std.testing.expectEqual(@as(u16, @intCast(index)), descriptors[index].bid);
    }

    @memcpy(buffers[2][0..3], "zig");
    const loan = try group.borrow(3, completionFlags(2, linux.IORING_CQE_F_MORE));
    try std.testing.expectEqual(@as(u16, 2), loan.buffer_id);
    try std.testing.expectEqualStrings("zig", loan.bytes);
    try std.testing.expectEqual(@as(u16, 1), group.borrowedCount());
    try std.testing.expectError(
        error.BufferAlreadyBorrowed,
        group.borrow(3, completionFlags(2, 0)),
    );

    try group.recycle(loan);
    try std.testing.expectEqual(@as(u16, 0), group.borrowedCount());
    try std.testing.expectEqual(@as(u16, Ring.count + 1), descriptor_ring.tail);
    try std.testing.expectEqual(@as(u16, 2), descriptors[0].bid);
    try std.testing.expectError(error.BufferNotBorrowed, group.recycle(loan));
}

test "buffer ring rejects malformed completions without changing ownership" {
    const Ring = BufferRing(4, 8, 11);
    var descriptor_storage: [Ring.descriptor_bytes]u8 align(page_size_min) =
        [_]u8{0} ** Ring.descriptor_bytes;
    var buffers: Ring.Buffers = undefined;
    var group = Ring.init();

    try std.testing.expectError(
        error.NotRegistered,
        group.borrow(1, completionFlags(0, 0)),
    );
    group.attachForTest(descriptor_storage[0..], &buffers);
    try std.testing.expectError(
        error.CompletionFailed,
        group.borrow(-1, completionFlags(0, 0)),
    );
    try std.testing.expectError(error.NoBufferSelected, group.borrow(1, 0));
    try std.testing.expectError(
        error.IncrementalBufferCompletion,
        group.borrow(1, completionFlags(0, linux.IORING_CQE_F_BUF_MORE)),
    );
    try std.testing.expectError(
        error.BufferIdOutOfRange,
        group.borrow(1, completionFlags(Ring.count, 0)),
    );
    try std.testing.expectError(
        error.BufferLengthOutOfRange,
        group.borrow(@as(i32, @intCast(Ring.size + 1)), completionFlags(0, 0)),
    );
    try std.testing.expectEqual(@as(u16, 0), group.borrowedCount());
    try std.testing.expectEqual(Ring.count, group.descriptor_ring.?.tail);
}

test "buffer ring validates recycle and cleanup preconditions" {
    const Ring = BufferRing(2, 8, 13);
    var descriptor_storage: [Ring.descriptor_bytes]u8 align(page_size_min) =
        [_]u8{0} ** Ring.descriptor_bytes;
    var buffers: Ring.Buffers = [_][Ring.size]u8{
        [_]u8{0xa5} ** Ring.size,
    } ** Ring.count;
    var group = Ring.init();

    try std.testing.expect(!group.isRegistered());
    try std.testing.expectError(error.NotRegistered, group.unregister());
    try std.testing.expectError(error.NotMapped, group.unmap());

    group.attachForTest(descriptor_storage[0..], &buffers);
    const loan = try group.borrow(4, completionFlags(1, linux.IORING_CQE_F_SOCK_NONEMPTY));
    const wrong_pointer = Ring.Borrowed{
        .buffer_id = loan.buffer_id,
        .bytes = buffers[0][0..loan.bytes.len],
    };
    try std.testing.expectError(error.BorrowedSliceInvalid, group.recycle(wrong_pointer));
    try std.testing.expectError(error.BuffersBorrowed, group.unregister());
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0xa5} ** @sizeOf(Ring.Buffers)),
        std.mem.asBytes(&buffers),
    );
    try std.testing.expectError(error.StillRegistered, group.unmap());
    try group.recycle(loan);
}

test "clean teardown clears every caller-owned receive buffer byte" {
    const Ring = BufferRing(2, 8, 15);
    var io = try IoUring.init(8, 0);
    defer io.deinit();
    var buffers: Ring.Buffers = [_][Ring.size]u8{
        [_]u8{0xa5} ** Ring.size,
    } ** Ring.count;
    var group = Ring.init();
    try group.register(&io, &buffers);

    buffers[0][0] = 0x11;
    buffers[1][Ring.size - 1] = 0x22;
    try group.deinit();

    try std.testing.expect(!group.isRegistered());
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** @sizeOf(Ring.Buffers)),
        std.mem.asBytes(&buffers),
    );
}

test "fatal abandon clears borrowed buffers after ring close" {
    const Ring = BufferRing(2, 8, 14);
    const mapping = try std.posix.mmap(
        null,
        Ring.descriptor_bytes,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    var buffers: Ring.Buffers = [_][Ring.size]u8{[_]u8{0xa5} ** Ring.size} ** Ring.count;
    var group = Ring.init();
    group.attachForTest(mapping, &buffers);
    _ = try group.borrow(4, completionFlags(1, 0));

    group.forceAbandonAfterRingClose();
    try std.testing.expect(!group.isRegistered());
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** @sizeOf(Ring.Buffers)),
        std.mem.asBytes(&buffers),
    );
}
