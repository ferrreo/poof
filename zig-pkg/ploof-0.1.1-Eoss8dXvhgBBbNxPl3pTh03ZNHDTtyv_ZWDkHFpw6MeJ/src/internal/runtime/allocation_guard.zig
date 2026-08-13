const std = @import("std");
const linux = std.os.linux;
const audit_arch_x86_64: u32 = 0xc000_003e;

pub const InstallError = error{
    NoNewPrivilegesFailed,
    SeccompInstallFailed,
};

const Filter = extern struct {
    code: u16,
    jump_true: u8,
    jump_false: u8,
    value: u32,
};

const Program = extern struct {
    length: u16,
    filters: [*]const Filter,
};

/// Irreversibly kills this process if it requests new address-space storage.
pub fn denyAddressSpaceGrowth() InstallError!void {
    const bpf = linux.BPF;
    const seccomp = linux.SECCOMP;
    const filters = [_]Filter{
        statement(bpf.LD | bpf.W | bpf.ABS, @offsetOf(seccomp.data, "arch")),
        jump(bpf.JMP | bpf.JEQ | bpf.K, audit_arch_x86_64, 1, 0),
        statement(bpf.RET | bpf.K, seccomp.RET.KILL_PROCESS),
        statement(bpf.LD | bpf.W | bpf.ABS, @offsetOf(seccomp.data, "nr")),
        denySyscall(.mmap),
        statement(bpf.RET | bpf.K, seccomp.RET.KILL_PROCESS),
        denySyscall(.mremap),
        statement(bpf.RET | bpf.K, seccomp.RET.KILL_PROCESS),
        denySyscall(.brk),
        statement(bpf.RET | bpf.K, seccomp.RET.KILL_PROCESS),
        statement(bpf.RET | bpf.K, seccomp.RET.ALLOW),
    };
    const program = Program{
        .length = @intCast(filters.len),
        .filters = &filters,
    };
    try install(&program);
}

fn install(program: *const Program) InstallError!void {
    const no_new_privileges = linux.prctl(
        @intFromEnum(linux.PR.SET_NO_NEW_PRIVS),
        1,
        0,
        0,
        0,
    );
    if (linux.errno(no_new_privileges) != .SUCCESS) {
        return error.NoNewPrivilegesFailed;
    }
    const installed = linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, 0, program);
    if (linux.errno(installed) != .SUCCESS) return error.SeccompInstallFailed;
}

fn denySyscall(syscall: linux.SYS) Filter {
    return jump(
        linux.BPF.JMP | linux.BPF.JEQ | linux.BPF.K,
        @intCast(@intFromEnum(syscall)),
        0,
        1,
    );
}

fn statement(code: u16, value: u32) Filter {
    return .{ .code = code, .jump_true = 0, .jump_false = 0, .value = value };
}

fn jump(code: u16, value: u32, jump_true: u8, jump_false: u8) Filter {
    return .{
        .code = code,
        .jump_true = jump_true,
        .jump_false = jump_false,
        .value = value,
    };
}

test "address-space guard kills a forbidden mapping" {
    const fork_result = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fork_result));
    if (fork_result == 0) {
        denyAddressSpaceGrowth() catch linux.exit_group(101);
        _ = linux.mmap(
            null,
            std.heap.page_size_min,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        linux.exit_group(102);
    }

    var status: u32 = 0;
    const waited = linux.waitpid(@intCast(fork_result), &status, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(waited));
    try std.testing.expectEqual(
        @as(u32, @intFromEnum(linux.SIG.SYS)),
        status & 0x7f,
    );
}

const StartupFault = enum(u8) {
    setup,
    sq_cq_mapping,
    sqe_mapping,
    descriptor_mapping,
    registration,
};

test "backend startup unwinds every ring mapping and registration phase" {
    const faults = [_]StartupFault{
        .setup,
        .sq_cq_mapping,
        .sqe_mapping,
        .descriptor_mapping,
        .registration,
    };
    for (faults) |fault| {
        const fork_result = linux.fork();
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fork_result));
        if (fork_result == 0) runStartupFault(fault);

        var status: u32 = 0;
        const waited = linux.waitpid(@intCast(fork_result), &status, 0);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(waited));
        try std.testing.expectEqual(@as(u32, 0), status & 0x7f);
        try std.testing.expectEqual(@as(u32, 0), (status >> 8) & 0xff);
    }
}

fn runStartupFault(fault: StartupFault) noreturn {
    const before = openFileDescriptorCount() catch linux.exit_group(111);
    installStartupFault(fault) catch linux.exit_group(112);

    const buffer_ring = @import("buffer_ring.zig");
    const config = @import("config.zig");
    const io_uring_backend = @import("io_uring/backend.zig");
    const limits = comptime config.Limits.validate(.{
        .connection_slots = 1,
        .request_slots = 1,
        .receive_buffers = 2,
        .receive_buffer_bytes = 64,
        .pipeline_bytes_per_connection = 64,
        .response_bytes_per_request = 256,
        .submission_entries = 8,
        .completion_entries = 16,
    });
    const ReceiveBuffers = buffer_ring.BufferRing(2, 64, 41);
    const Backend = io_uring_backend.IoUringBackend(limits, ReceiveBuffers);

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    backend.init(&buffers) catch |problem| {
        const expected = switch (fault) {
            .setup, .sq_cq_mapping, .sqe_mapping => error.RingResourceLimit,
            .descriptor_mapping => error.OutOfMemory,
            .registration => error.RegistrationResourceLimit,
        };
        if (problem != expected) linux.exit_group(113);
        if (backend.memoryMappings() != null) linux.exit_group(114);
        const after = openFileDescriptorCount() catch linux.exit_group(115);
        if (after != before) linux.exit_group(116);
        linux.exit_group(0);
    };
    linux.exit_group(117);
}

fn installStartupFault(fault: StartupFault) InstallError!void {
    const bpf = linux.BPF;
    const seccomp = linux.SECCOMP;
    const reject = @as(u32, seccomp.RET.ERRNO) |
        @as(u32, @intFromEnum(linux.E.NOMEM));
    switch (fault) {
        .setup => {
            const filters = [_]Filter{
                statement(bpf.LD | bpf.W | bpf.ABS, @offsetOf(seccomp.data, "arch")),
                jump(bpf.JMP | bpf.JEQ | bpf.K, audit_arch_x86_64, 1, 0),
                statement(bpf.RET | bpf.K, seccomp.RET.KILL_PROCESS),
                statement(bpf.LD | bpf.W | bpf.ABS, @offsetOf(seccomp.data, "nr")),
                denySyscall(.io_uring_setup),
                statement(bpf.RET | bpf.K, reject),
                statement(bpf.RET | bpf.K, seccomp.RET.ALLOW),
            };
            return installFilters(&filters);
        },
        .registration => {
            const filters = [_]Filter{
                statement(bpf.LD | bpf.W | bpf.ABS, @offsetOf(seccomp.data, "arch")),
                jump(bpf.JMP | bpf.JEQ | bpf.K, audit_arch_x86_64, 1, 0),
                statement(bpf.RET | bpf.K, seccomp.RET.KILL_PROCESS),
                statement(bpf.LD | bpf.W | bpf.ABS, @offsetOf(seccomp.data, "nr")),
                denySyscall(.io_uring_register),
                statement(bpf.RET | bpf.K, reject),
                statement(bpf.RET | bpf.K, seccomp.RET.ALLOW),
            };
            return installFilters(&filters);
        },
        .sq_cq_mapping => {
            const filters = mappingOffsetFault(linux.IORING_OFF_SQ_RING, reject);
            return installFilters(&filters);
        },
        .sqe_mapping => {
            const filters = mappingOffsetFault(linux.IORING_OFF_SQES, reject);
            return installFilters(&filters);
        },
        .descriptor_mapping => {
            const filters = descriptorMappingFault(reject);
            return installFilters(&filters);
        },
    }
}

fn installFilters(filters: []const Filter) InstallError!void {
    const program = Program{
        .length = @intCast(filters.len),
        .filters = filters.ptr,
    };
    try install(&program);
}

fn mappingOffsetFault(offset: u64, reject: u32) [9]Filter {
    const bpf = linux.BPF;
    const seccomp = linux.SECCOMP;
    return .{
        statement(bpf.LD | bpf.W | bpf.ABS, @offsetOf(seccomp.data, "arch")),
        jump(bpf.JMP | bpf.JEQ | bpf.K, audit_arch_x86_64, 1, 0),
        statement(bpf.RET | bpf.K, seccomp.RET.KILL_PROCESS),
        statement(bpf.LD | bpf.W | bpf.ABS, @offsetOf(seccomp.data, "nr")),
        jump(bpf.JMP | bpf.JEQ | bpf.K, @intFromEnum(linux.SYS.mmap), 0, 3),
        statement(bpf.LD | bpf.W | bpf.ABS, @offsetOf(seccomp.data, "arg5")),
        jump(bpf.JMP | bpf.JEQ | bpf.K, @truncate(offset), 0, 1),
        statement(bpf.RET | bpf.K, reject),
        statement(bpf.RET | bpf.K, seccomp.RET.ALLOW),
    };
}

fn descriptorMappingFault(reject: u32) [9]Filter {
    const bpf = linux.BPF;
    const seccomp = linux.SECCOMP;
    return .{
        statement(bpf.LD | bpf.W | bpf.ABS, @offsetOf(seccomp.data, "arch")),
        jump(bpf.JMP | bpf.JEQ | bpf.K, audit_arch_x86_64, 1, 0),
        statement(bpf.RET | bpf.K, seccomp.RET.KILL_PROCESS),
        statement(bpf.LD | bpf.W | bpf.ABS, @offsetOf(seccomp.data, "nr")),
        jump(bpf.JMP | bpf.JEQ | bpf.K, @intFromEnum(linux.SYS.mmap), 0, 3),
        statement(bpf.LD | bpf.W | bpf.ABS, @offsetOf(seccomp.data, "arg4")),
        jump(bpf.JMP | bpf.JEQ | bpf.K, std.math.maxInt(u32), 0, 1),
        statement(bpf.RET | bpf.K, reject),
        statement(bpf.RET | bpf.K, seccomp.RET.ALLOW),
    };
}

fn openFileDescriptorCount() !u16 {
    const opened = linux.open(
        "/proc/self/fd",
        .{ .DIRECTORY = true, .CLOEXEC = true },
        0,
    );
    if (linux.errno(opened) != .SUCCESS) return error.FdDirectoryOpenFailed;
    const directory: linux.fd_t = @intCast(opened);
    defer _ = linux.close(directory);

    var entries: [4096]u8 align(@alignOf(u64)) = undefined;
    var count: u16 = 0;
    while (true) {
        const read_result = linux.getdents64(directory, &entries, entries.len);
        if (linux.errno(read_result) != .SUCCESS) return error.FdDirectoryReadFailed;
        if (read_result == 0) return count;

        var offset: usize = 0;
        while (offset < read_result) {
            if (read_result - offset < 19) return error.InvalidFdDirectoryEntry;
            const length = std.mem.readInt(
                u16,
                entries[offset + 16 ..][0..2],
                .little,
            );
            if (length < 19 or length > read_result - offset) {
                return error.InvalidFdDirectoryEntry;
            }
            count = std.math.add(u16, count, 1) catch return error.TooManyFileDescriptors;
            offset += length;
        }
    }
}
