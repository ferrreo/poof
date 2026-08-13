const std = @import("std");
const linux = std.os.linux;
const upload_io = @import("../../upload_io.zig");

pub const Operation = enum(u8) {
    none,
    nop,
    accept,
    recv,
    send,
    sendmsg,
    read,
    close,
    timeout,
    async_cancel,
    register_probe,
    register_buffer_ring,
    socket,
    bind,
    listen,
    connect,
    eventfd,
    poll_add,
    write,
    openat2,
    statx,
    linkat,
    unlinkat,
    renameat,
    fsync,
};

pub const Requirement = enum(u8) {
    none,
    ring_profile,
    kernel_6_1,
    setup_flags,
    queue_shape,
    single_mmap,
    no_drop,
    submit_stable,
    fast_poll,
    opcode,
    non_incremental_buffer_ring,
    multishot_accept,
    multishot_receive,
    selected_send,
    timeout,
    cancellation,
    no_dropped_submissions,
    no_completion_overflow,
    monotonic_clock,
    event_wake,
};

pub const FeatureRequirement = struct {
    bit: u32,
    requirement: Requirement,
};

pub const OpcodeRequirement = struct {
    opcode: linux.IORING_OP,
    operation: Operation,
};

pub const BufferRingRequirement = struct {
    group_id: u16,
    buffer_count: u16,
    buffer_size: u16,
    ring_bytes: u32,
    incremental: bool,
};

pub const Proof = packed struct(u16) {
    nop: bool = false,
    multishot_accept: bool = false,
    provided_buffer_receive: bool = false,
    send: bool = false,
    timeout: bool = false,
    cancellation: bool = false,
    event_wake: bool = false,
    _: u9 = 0,
};

pub const ReactorCapabilityManifest = struct {
    setup_flags: u32,
    feature_mask: u32,
    feature_requirements: [4]FeatureRequirement,
    opcode_requirements: []const OpcodeRequirement,
    buffer_ring: BufferRingRequirement,
    active_proofs: Proof,
};

pub const FeatureRequirements = struct {
    io_requirements: upload_io.IoRequirements = .none,
    live_static: bool = false,
};

const setup_flags: u32 = linux.IORING_SETUP_CQSIZE |
    linux.IORING_SETUP_SUBMIT_ALL |
    linux.IORING_SETUP_COOP_TASKRUN |
    linux.IORING_SETUP_SINGLE_ISSUER |
    linux.IORING_SETUP_DEFER_TASKRUN;

const feature_mask = 0x27;

const feature_requirements = [4]FeatureRequirement{
    .{ .bit = linux.IORING_FEAT_SINGLE_MMAP, .requirement = .single_mmap },
    .{ .bit = linux.IORING_FEAT_NODROP, .requirement = .no_drop },
    .{ .bit = linux.IORING_FEAT_SUBMIT_STABLE, .requirement = .submit_stable },
    .{ .bit = linux.IORING_FEAT_FAST_POLL, .requirement = .fast_poll },
};

const core_opcodes = [10]OpcodeRequirement{
    .{ .opcode = .NOP, .operation = .nop },
    .{ .opcode = .ACCEPT, .operation = .accept },
    .{ .opcode = .RECV, .operation = .recv },
    .{ .opcode = .SEND, .operation = .send },
    .{ .opcode = .SENDMSG, .operation = .sendmsg },
    .{ .opcode = .READ, .operation = .read },
    .{ .opcode = .CLOSE, .operation = .close },
    .{ .opcode = .TIMEOUT, .operation = .timeout },
    .{ .opcode = .ASYNC_CANCEL, .operation = .async_cancel },
    .{ .opcode = .POLL_ADD, .operation = .poll_add },
};

const upload_opcodes = [_]struct {
    kind: upload_io.IoKind,
    requirement: OpcodeRequirement,
}{
    .{ .kind = .open, .requirement = .{ .opcode = .OPENAT2, .operation = .openat2 } },
    .{ .kind = .write, .requirement = .{ .opcode = .WRITE, .operation = .write } },
    .{ .kind = .link, .requirement = .{ .opcode = .LINKAT, .operation = .linkat } },
    .{ .kind = .unlink, .requirement = .{ .opcode = .UNLINKAT, .operation = .unlinkat } },
    .{
        .kind = .rename_no_replace,
        .requirement = .{ .opcode = .RENAMEAT, .operation = .renameat },
    },
    .{ .kind = .sync, .requirement = .{ .opcode = .FSYNC, .operation = .fsync } },
};

const buffer_ring = BufferRingRequirement{
    .group_id = 1,
    .buffer_count = 4,
    .buffer_size = 64,
    .ring_bytes = 64,
    .incremental = false,
};

const active_proofs = Proof{
    .nop = true,
    .multishot_accept = true,
    .provided_buffer_receive = true,
    .send = true,
    .timeout = true,
    .cancellation = true,
    .event_wake = true,
};

pub fn Manifest(comptime requirements: FeatureRequirements) type {
    if (!requirements.io_requirements.valid()) {
        @compileError("PLOOF-E3504 invalid reactor I/O requirements");
    }
    return struct {
        pub const opcode_requirements = buildOpcodes(requirements);
        pub const value = ReactorCapabilityManifest{
            .setup_flags = setup_flags,
            .feature_mask = feature_mask,
            .feature_requirements = feature_requirements,
            .opcode_requirements = &opcode_requirements,
            .buffer_ring = buffer_ring,
            .active_proofs = active_proofs,
        };
    };
}

pub fn manifest(comptime requirements: FeatureRequirements) ReactorCapabilityManifest {
    return Manifest(requirements).value;
}

pub fn merge(
    left: FeatureRequirements,
    right: FeatureRequirements,
) FeatureRequirements {
    return .{
        .io_requirements = left.io_requirements.merge(right.io_requirements),
        .live_static = left.live_static or right.live_static,
    };
}

pub fn accumulate(
    comptime declarations: []const FeatureRequirements,
) FeatureRequirements {
    var result = FeatureRequirements{};
    for (declarations) |declaration| result = merge(result, declaration);
    return result;
}

pub fn accumulatedManifest(
    comptime declarations: []const FeatureRequirements,
) ReactorCapabilityManifest {
    return manifest(accumulate(declarations));
}

pub const reactor_capability_manifest = manifest(.{});

pub fn missingOpcode(
    capability_manifest: ReactorCapabilityManifest,
    probe: linux.io_uring_probe,
) ?OpcodeRequirement {
    for (capability_manifest.opcode_requirements) |requirement| {
        if (!probe.is_supported(requirement.opcode)) return requirement;
    }
    return null;
}

fn buildOpcodes(
    comptime requirements: FeatureRequirements,
) [opcodeCount(requirements)]OpcodeRequirement {
    var result: [opcodeCount(requirements)]OpcodeRequirement = undefined;
    var index: usize = 0;
    for (core_opcodes) |requirement| appendOpcode(&result, &index, requirement);
    for (upload_opcodes) |entry| {
        if (requirements.io_requirements.contains(entry.kind)) {
            appendOpcode(&result, &index, entry.requirement);
        }
    }
    if (requirements.live_static) {
        if (!requirements.io_requirements.open) appendOpcode(&result, &index, .{
            .opcode = .OPENAT2,
            .operation = .openat2,
        });
        appendOpcode(&result, &index, .{ .opcode = .STATX, .operation = .statx });
    }
    std.debug.assert(index == result.len);
    return result;
}

fn appendOpcode(
    result: anytype,
    index: *usize,
    requirement: OpcodeRequirement,
) void {
    result[index.*] = requirement;
    index.* += 1;
}

fn opcodeCount(comptime requirements: FeatureRequirements) comptime_int {
    var count: comptime_int = core_opcodes.len;
    for (upload_opcodes) |entry| {
        count += @intFromBool(requirements.io_requirements.contains(entry.kind));
    }
    if (requirements.live_static) {
        count += 1;
        if (!requirements.io_requirements.open) count += 1;
    }
    return count;
}

fn assertUnique(comptime requirements: FeatureRequirements) void {
    const opcodes = Manifest(requirements).opcode_requirements;
    for (opcodes, 0..) |requirement, index| {
        for (opcodes[index + 1 ..]) |other| {
            std.debug.assert(requirement.opcode != other.opcode);
        }
    }
}

comptime {
    @setEvalBranchQuota(200_000);
    std.debug.assert(setup_flags == 0x3188);
    std.debug.assert(@popCount(setup_flags) == 5);
    var observed_feature_mask: u32 = 0;
    for (feature_requirements) |requirement| observed_feature_mask |= requirement.bit;
    std.debug.assert(feature_mask == observed_feature_mask);
    std.debug.assert(!buffer_ring.incremental);
    std.debug.assert(std.math.isPowerOfTwo(buffer_ring.buffer_count));
    std.debug.assert(
        buffer_ring.ring_bytes == buffer_ring.buffer_count * @sizeOf(linux.io_uring_buf),
    );
    std.debug.assert(@as(u16, @bitCast(active_proofs)) == 0x7f);
    for (0..128) |raw| {
        assertUnique(.{ .io_requirements = @bitCast(@as(u8, @intCast(raw))) });
        assertUnique(.{
            .io_requirements = @bitCast(@as(u8, @intCast(raw))),
            .live_static = true,
        });
    }
}

const anonymous_io_requirements = upload_io.IoRequirements{
    .open = true,
    .write = true,
    .close = true,
    .link = true,
    .unlink = true,
};
const named_io_requirements = upload_io.IoRequirements{
    .open = true,
    .write = true,
    .close = true,
    .unlink = true,
    .rename_no_replace = true,
};
const durable_io_requirements = upload_io.IoRequirements{ .sync = true };

test "capability accumulation maps exact I/O requirement sets" {
    const file = [_]linux.IORING_OP{ .OPENAT2, .WRITE };
    const anonymous = file ++ [_]linux.IORING_OP{ .LINKAT, .UNLINKAT };
    const named = file ++ [_]linux.IORING_OP{ .UNLINKAT, .RENAMEAT };
    const both = file ++ [_]linux.IORING_OP{ .LINKAT, .UNLINKAT, .RENAMEAT };
    try expectOpcodes(.{}, &.{});
    try expectOpcodes(.{ .io_requirements = .{ .close = true } }, &.{});
    try expectOpcodes(
        .{ .io_requirements = anonymous_io_requirements },
        &anonymous,
    );
    try expectOpcodes(.{ .io_requirements = anonymous_io_requirements.merge(
        durable_io_requirements,
    ) }, &(anonymous ++ [_]linux.IORING_OP{.FSYNC}));
    try expectOpcodes(.{ .io_requirements = named_io_requirements }, &named);
    try expectOpcodes(.{ .io_requirements = named_io_requirements.merge(
        durable_io_requirements,
    ) }, &(named ++ [_]linux.IORING_OP{.FSYNC}));
    try expectOpcodes(.{ .io_requirements = anonymous_io_requirements.merge(
        named_io_requirements,
    ) }, &both);
    try expectOpcodes(
        .{ .io_requirements = upload_io.IoRequirements.all },
        &(both ++ [_]linux.IORING_OP{.FSYNC}),
    );
}

test "each declared I/O kind selects only its non-core opcode" {
    try expectOpcodes(.{ .io_requirements = .{ .open = true } }, &.{.OPENAT2});
    try expectOpcodes(.{ .io_requirements = .{ .write = true } }, &.{.WRITE});
    try expectOpcodes(.{ .io_requirements = .{ .close = true } }, &.{});
    try expectOpcodes(.{ .io_requirements = .{ .link = true } }, &.{.LINKAT});
    try expectOpcodes(.{ .io_requirements = .{ .unlink = true } }, &.{.UNLINKAT});
    try expectOpcodes(
        .{ .io_requirements = .{ .rename_no_replace = true } },
        &.{.RENAMEAT},
    );
    try expectOpcodes(.{ .io_requirements = .{ .sync = true } }, &.{.FSYNC});
    try expectOpcodes(.{ .live_static = true }, &.{ .OPENAT2, .STATX });
    try expectOpcodes(
        .{ .io_requirements = .{ .open = true }, .live_static = true },
        &.{ .OPENAT2, .STATX },
    );
}

test "feature accumulation ORs custom sink I/O requirements" {
    const declarations = [_]FeatureRequirements{
        .{ .io_requirements = anonymous_io_requirements },
        .{ .io_requirements = named_io_requirements },
        .{ .io_requirements = durable_io_requirements },
    };
    const expected = FeatureRequirements{ .io_requirements = .all };
    try std.testing.expectEqual(expected, accumulate(&declarations));
    try std.testing.expectEqual(expected, merge(
        .{ .io_requirements = anonymous_io_requirements },
        .{ .io_requirements = named_io_requirements.merge(durable_io_requirements) },
    ));
    try std.testing.expectEqual(reactor_capability_manifest, accumulatedManifest(&.{}));
    try std.testing.expectEqual(
        @as(usize, 16),
        accumulatedManifest(&declarations).opcode_requirements.len,
    );
}

test "opcode check consumes exact selected manifest" {
    var probe = std.mem.zeroes(linux.io_uring_probe);
    probe.last_op = .LINKAT;
    probe.ops_len = @intFromEnum(linux.IORING_OP.LINKAT) + 1;
    for (core_opcodes) |requirement| {
        probe.ops[@intFromEnum(requirement.opcode)].flags = linux.IO_URING_OP_SUPPORTED;
    }
    try std.testing.expectEqual(null, missingOpcode(reactor_capability_manifest, probe));

    const anonymous = manifest(.{ .io_requirements = anonymous_io_requirements });
    try std.testing.expectEqual(linux.IORING_OP.OPENAT2, missingOpcode(anonymous, probe).?.opcode);
    for (anonymous.opcode_requirements[core_opcodes.len..]) |requirement| {
        probe.ops[@intFromEnum(requirement.opcode)].flags = linux.IO_URING_OP_SUPPORTED;
    }
    try std.testing.expectEqual(null, missingOpcode(anonymous, probe));

    const all = manifest(.{ .io_requirements = .all });
    try std.testing.expectEqual(linux.IORING_OP.RENAMEAT, missingOpcode(all, probe).?.opcode);
    probe.ops[@intFromEnum(linux.IORING_OP.RENAMEAT)].flags = linux.IO_URING_OP_SUPPORTED;
    try std.testing.expectEqual(linux.IORING_OP.FSYNC, missingOpcode(all, probe).?.opcode);
}

fn expectOpcodes(
    comptime requirements: FeatureRequirements,
    expected_tail: []const linux.IORING_OP,
) !void {
    const opcodes = Manifest(requirements).opcode_requirements;
    try std.testing.expectEqual(core_opcodes.len + expected_tail.len, opcodes.len);
    var seen = std.bit_set.IntegerBitSet(256).initEmpty();
    for (opcodes, 0..) |requirement, index| {
        const expected = if (index < core_opcodes.len)
            core_opcodes[index].opcode
        else
            expected_tail[index - core_opcodes.len];
        try std.testing.expectEqual(expected, requirement.opcode);
        const opcode = @intFromEnum(requirement.opcode);
        try std.testing.expect(!seen.isSet(opcode));
        seen.set(opcode);
    }
}
