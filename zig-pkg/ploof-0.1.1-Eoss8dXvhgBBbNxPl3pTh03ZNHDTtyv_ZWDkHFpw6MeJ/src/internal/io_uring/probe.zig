const std = @import("std");
const linux = std.os.linux;

const IoUring = linux.IoUring;
const model = @import("probe_types.zig");
const network = @import("probe_network.zig");
const runtime = @import("probe_runtime.zig");
const system = @import("probe_system.zig");
const wake = @import("probe_wake.zig");

pub const RingProfile = model.RingProfile;
pub const ProfileIssue = model.ProfileIssue;
pub const Config = model.Config;
pub const ErrorCode = model.ErrorCode;
pub const Phase = model.Phase;
pub const Operation = model.Operation;
pub const Requirement = model.Requirement;
pub const KnownSystemEvidence = model.KnownSystemEvidence;
pub const SystemEvidence = model.SystemEvidence;
pub const ErrnoStatus = model.ErrnoStatus;
pub const CleanupStatus = model.CleanupStatus;
pub const Failure = model.Failure;
pub const Proof = model.Proof;
pub const Report = model.Report;
pub const Result = model.Result;
pub const ReactorCapabilityManifest = model.ReactorCapabilityManifest;
pub const FeatureRequirements = model.FeatureRequirements;
pub const capabilityManifest = model.capabilityManifest;
pub const accumulatedCapabilityManifest = model.accumulatedCapabilityManifest;

const capabilities = model.reactor_capability_manifest;
const Context = model.Context;
const BufferRing = runtime.BufferRing;
const buffer_count = runtime.buffer_count;
const buffer_size = runtime.buffer_size;
const FeatureRequirement = model.FeatureRequirement;
const missingOpcode = model.missingOpcode;
const proveNetwork = network.proveNetwork;
const proveNop = runtime.proveNop;
const proveTimeout = runtime.proveTimeout;
const proveWake = wake.proveWake;
const captureSystemEvidence = system.captureSystemEvidence;
const packQueueShape = system.packQueueShape;
const packVersion = system.packVersion;
const validateKernelRelease = system.validateKernelRelease;

const RingResult = union(enum) {
    ring: IoUring,
    failure: Failure,
};

const RingSetupResult = union(enum) {
    fd: linux.fd_t,
    failure: Failure,
};

const ReturnedParametersIssue = union(enum) {
    queue_shape,
    setup_flags,
    feature: FeatureRequirement,
};

pub fn check(config: Config) Result {
    return checkWithManifest(config, capabilities);
}

pub fn checkWithManifest(
    config: Config,
    comptime manifest: ReactorCapabilityManifest,
) Result {
    var context = Context{
        .config = config,
        .system = captureSystemEvidence(),
        .capabilities = manifest,
    };
    if (validateStartup(&context)) |failure| return .{ .failure = failure };

    const ring_result = createRing(&context);
    var ring = switch (ring_result) {
        .ring => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    var ring_live = true;
    defer if (ring_live) ring.deinit();

    if (checkOpcodes(&context, &ring)) |failure| {
        return .{ .failure = failure };
    }

    const buffer_result = BufferRing.create(&context, ring.fd);
    var buffer_ring = switch (buffer_result) {
        .buffer_ring => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    var buffer_ring_live = true;
    defer if (buffer_ring_live) {
        ring.deinit();
        ring_live = false;
        buffer_ring.unmap();
    };

    var buffers: [buffer_count][buffer_size]u8 = undefined;
    initializeBuffers(&buffer_ring, &buffers);

    var proofs = Proof{};
    if (proveCapabilities(&context, &ring, &buffer_ring, &buffers, &proofs)) |failure| {
        return .{ .failure = failure };
    }
    if (checkRingCounters(&context, &ring)) |failure| {
        return .{ .failure = failure };
    }
    if (unregisterBufferRing(&context, &ring, &buffer_ring)) |failure| {
        return .{ .failure = failure };
    }
    buffer_ring.unmap();
    buffer_ring_live = false;
    return readyResult(&context, &ring, proofs);
}

fn validateStartup(context: *const Context) ?Failure {
    if (context.config.ring.validate()) |issue| {
        return context.failure(
            .invalid_profile,
            .profile,
            .none,
            .ring_profile,
            .SUCCESS,
            0,
            @intFromEnum(issue),
        );
    }
    if (validateKernelRelease(context.system.release())) |issue| {
        return switch (issue) {
            .unavailable => context.failure(
                .kernel_version_unavailable,
                .kernel_version,
                .none,
                .kernel_6_1,
                .SUCCESS,
                packVersion(6, 1),
                -1,
            ),
            .too_old => |version| context.failure(
                .kernel_too_old,
                .kernel_version,
                .none,
                .kernel_6_1,
                .SUCCESS,
                packVersion(6, 1),
                packVersion(version.major, version.minor),
            ),
        };
    }
    return null;
}

fn initializeBuffers(
    buffer_ring: *BufferRing,
    buffers: *[buffer_count][buffer_size]u8,
) void {
    const buffer_mask = IoUring.buf_ring_mask(buffer_count);
    for (buffers, 0..) |*buffer, index| {
        IoUring.buf_ring_add(
            buffer_ring.ring,
            buffer,
            @intCast(index),
            buffer_mask,
            @intCast(index),
        );
    }
    IoUring.buf_ring_advance(buffer_ring.ring, buffer_count);
}

fn proveCapabilities(
    context: *const Context,
    ring: *IoUring,
    buffer_ring: *BufferRing,
    buffers: *[buffer_count][buffer_size]u8,
    proofs: *Proof,
) ?Failure {
    if (proveNop(context, ring)) |failure| return failure;
    proofs.nop = true;
    if (proveWake(context, ring)) |failure| return failure;
    proofs.event_wake = true;
    if (proveNetwork(context, ring, buffer_ring, buffers, proofs)) |failure| return failure;
    if (proveTimeout(context, ring)) |failure| return failure;
    proofs.timeout = true;
    return null;
}

fn checkRingCounters(context: *const Context, ring: *IoUring) ?Failure {
    if (ring.sq.dropped.* != 0) {
        return context.failure(
            .runtime_invariant,
            .cleanup,
            .none,
            .no_dropped_submissions,
            .SUCCESS,
            0,
            ring.sq.dropped.*,
        );
    }
    if (ring.cq.overflow.* != 0) {
        return context.failure(
            .runtime_invariant,
            .cleanup,
            .none,
            .no_completion_overflow,
            .SUCCESS,
            0,
            ring.cq.overflow.*,
        );
    }
    return null;
}

fn unregisterBufferRing(
    context: *const Context,
    ring: *IoUring,
    buffer_ring: *BufferRing,
) ?Failure {
    const errno_value = buffer_ring.unregister(ring.fd);
    if (errno_value == .SUCCESS) return null;
    return context.failure(
        .cleanup_failed,
        .cleanup,
        .register_buffer_ring,
        .non_incremental_buffer_ring,
        errno_value,
        0,
        0,
    );
}

fn readyResult(context: *const Context, ring: *const IoUring, proofs: Proof) Result {
    const manifest = context.capabilities;
    std.debug.assert(
        @as(u16, @bitCast(proofs)) == @as(u16, @bitCast(manifest.active_proofs)),
    );
    return .{ .ready = .{
        .submission_entries = context.returned_submission_entries,
        .completion_entries = context.returned_completion_entries,
        .setup_flags = manifest.setup_flags,
        .features = ring.features,
        .proofs = proofs,
    } };
}

fn createRing(context: *Context) RingResult {
    var parameters: linux.io_uring_params = undefined;
    const setup_result = setupRing(context, &parameters);
    const fd = switch (setup_result) {
        .fd => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    var fd_live = true;
    defer {
        if (fd_live) _ = linux.close(fd);
    }
    var submission_queue = IoUring.SubmissionQueue.init(fd, parameters) catch {
        return .{ .failure = ringMappingFailure(context) };
    };
    var submission_queue_live = true;
    defer if (submission_queue_live) submission_queue.deinit();
    const completion_queue = IoUring.CompletionQueue.init(
        fd,
        parameters,
        submission_queue,
    ) catch {
        return .{ .failure = ringMappingFailure(context) };
    };

    fd_live = false;
    submission_queue_live = false;
    return .{ .ring = .{
        .fd = fd,
        .sq = submission_queue,
        .cq = completion_queue,
        .flags = parameters.flags,
        .features = parameters.features,
    } };
}

fn setupRing(context: *Context, parameters: *linux.io_uring_params) RingSetupResult {
    const manifest = context.capabilities;
    parameters.* = std.mem.zeroes(linux.io_uring_params);
    parameters.flags = manifest.setup_flags;
    parameters.cq_entries = context.config.ring.completion_entries;
    const result = linux.io_uring_setup(context.config.ring.submission_entries, parameters);
    const errno_value = linux.errno(result);
    if (errno_value != .SUCCESS) {
        return .{ .failure = context.failure(
            .ring_setup_failed,
            .ring_setup,
            .none,
            .setup_flags,
            errno_value,
            manifest.setup_flags,
            0,
        ) };
    }

    const fd: linux.fd_t = @intCast(result);
    context.returned_submission_entries = parameters.sq_entries;
    context.returned_completion_entries = parameters.cq_entries;
    context.returned_features = parameters.features;
    if (validateReturnedParameters(manifest, context.config.ring, parameters.*)) |issue| {
        const failure = returnedParametersFailure(context, parameters.*, issue);
        _ = linux.close(fd);
        return .{ .failure = failure };
    }
    return .{ .fd = fd };
}

fn returnedParametersFailure(
    context: *const Context,
    parameters: linux.io_uring_params,
    issue: ReturnedParametersIssue,
) Failure {
    const manifest = context.capabilities;
    return switch (issue) {
        .queue_shape => context.failure(
            .ring_shape_mismatch,
            .ring_setup,
            .none,
            .queue_shape,
            .SUCCESS,
            packQueueShape(
                context.config.ring.submission_entries,
                context.config.ring.completion_entries,
            ),
            packQueueShape(parameters.sq_entries, parameters.cq_entries),
        ),
        .setup_flags => context.failure(
            .ring_shape_mismatch,
            .ring_setup,
            .none,
            .setup_flags,
            .SUCCESS,
            manifest.setup_flags,
            parameters.flags,
        ),
        .feature => |requirement| context.failure(
            .feature_missing,
            .feature_manifest,
            .none,
            requirement.requirement,
            .SUCCESS,
            requirement.bit,
            parameters.features,
        ),
    };
}

fn ringMappingFailure(context: *const Context) Failure {
    return context.failureWithoutErrno(
        .ring_mapping_failed,
        .ring_mapping,
        .none,
        .single_mmap,
        0,
        0,
    );
}

fn checkOpcodes(context: *const Context, ring: *IoUring) ?Failure {
    const manifest = context.capabilities;
    var probe = std.mem.zeroes(linux.io_uring_probe);
    const result = linux.io_uring_register(
        ring.fd,
        .REGISTER_PROBE,
        &probe,
        @intCast(probe.ops.len),
    );
    const errno_value = linux.errno(result);
    if (errno_value != .SUCCESS) {
        return context.failure(
            .opcode_probe_failed,
            .opcode_manifest,
            .register_probe,
            .opcode,
            errno_value,
            @intCast(manifest.opcode_requirements.len),
            0,
        );
    }

    return missingOpcodeFailure(context, probe);
}

fn missingOpcodeFailure(context: *const Context, probe: linux.io_uring_probe) ?Failure {
    const requirement = missingOpcode(context.capabilities, probe) orelse return null;
    return context.failure(
        .opcode_missing,
        .opcode_manifest,
        requirement.operation,
        .opcode,
        .SUCCESS,
        1,
        0,
    );
}

fn missingFeature(manifest: ReactorCapabilityManifest, features: u32) ?FeatureRequirement {
    for (manifest.feature_requirements) |requirement| {
        if (features & requirement.bit == 0) return requirement;
    }
    return null;
}

fn validateReturnedParameters(
    manifest: ReactorCapabilityManifest,
    profile: RingProfile,
    parameters: linux.io_uring_params,
) ?ReturnedParametersIssue {
    if (parameters.sq_entries != profile.submission_entries or
        parameters.cq_entries != profile.completion_entries)
    {
        return .queue_shape;
    }
    if (parameters.flags != manifest.setup_flags) return .setup_flags;
    if (missingFeature(manifest, parameters.features)) |feature| return .{ .feature = feature };
    return null;
}

test "required feature and opcode manifests are unique" {
    var features: u32 = 0;
    for (capabilities.feature_requirements) |requirement| {
        try std.testing.expectEqual(@as(u32, 0), features & requirement.bit);
        features |= requirement.bit;
    }
    try std.testing.expectEqual(capabilities.feature_mask, features);

    var opcodes = std.bit_set.IntegerBitSet(256).initEmpty();
    for (capabilities.opcode_requirements) |requirement| {
        const opcode = @intFromEnum(requirement.opcode);
        try std.testing.expect(!opcodes.isSet(opcode));
        opcodes.set(opcode);
    }
}

test "feature classifier identifies every missing requirement" {
    const feature_mask = capabilities.feature_mask;
    try std.testing.expectEqual(null, missingFeature(capabilities, feature_mask));
    for (capabilities.feature_requirements) |requirement| {
        const missing = missingFeature(capabilities, feature_mask & ~requirement.bit).?;
        try std.testing.expectEqual(requirement.bit, missing.bit);
        try std.testing.expectEqual(requirement.requirement, missing.requirement);
    }
}

test "returned ring parameter classifier rejects every mismatch" {
    const profile = RingProfile{};
    const valid = linux.io_uring_params{
        .sq_entries = profile.submission_entries,
        .cq_entries = profile.completion_entries,
        .flags = capabilities.setup_flags,
        .sq_thread_cpu = 0,
        .sq_thread_idle = 0,
        .features = capabilities.feature_mask,
        .wq_fd = 0,
        .resv = .{ 0, 0, 0 },
        .sq_off = std.mem.zeroes(linux.io_sqring_offsets),
        .cq_off = std.mem.zeroes(linux.io_cqring_offsets),
    };
    try std.testing.expectEqual(null, validateReturnedParameters(capabilities, profile, valid));

    var changed = valid;
    changed.sq_entries = 4;
    try std.testing.expectEqual(
        ReturnedParametersIssue.queue_shape,
        validateReturnedParameters(capabilities, profile, changed).?,
    );
    changed = valid;
    changed.cq_entries = 32;
    try std.testing.expectEqual(
        ReturnedParametersIssue.queue_shape,
        validateReturnedParameters(capabilities, profile, changed).?,
    );
    changed = valid;
    changed.flags = 0;
    try std.testing.expectEqual(
        ReturnedParametersIssue.setup_flags,
        validateReturnedParameters(capabilities, profile, changed).?,
    );
    for (capabilities.feature_requirements) |requirement| {
        changed = valid;
        changed.features &= ~requirement.bit;
        const issue = validateReturnedParameters(capabilities, profile, changed).?;
        try std.testing.expectEqual(requirement.bit, issue.feature.bit);
        try std.testing.expectEqual(requirement.requirement, issue.feature.requirement);
    }
}

test "opcode classifier identifies every missing requirement" {
    var probe = std.mem.zeroes(linux.io_uring_probe);
    probe.last_op = .LINKAT;
    probe.ops_len = @intFromEnum(linux.IORING_OP.LINKAT) + 1;
    for (capabilities.opcode_requirements) |requirement| {
        probe.ops[@intFromEnum(requirement.opcode)].flags = linux.IO_URING_OP_SUPPORTED;
    }
    try std.testing.expectEqual(null, missingOpcode(capabilities, probe));

    for (capabilities.opcode_requirements) |requirement| {
        const index = @intFromEnum(requirement.opcode);
        probe.ops[index].flags = 0;
        const missing = missingOpcode(capabilities, probe).?;
        try std.testing.expectEqual(requirement.opcode, missing.opcode);
        try std.testing.expectEqual(requirement.operation, missing.operation);
        probe.ops[index].flags = linux.IO_URING_OP_SUPPORTED;
    }
}

test "upload opcode failure keeps exact application operation identity" {
    const manifest = capabilityManifest(.{
        .io_requirements = .{ .open = true, .sync = true },
    });
    var context = Context{ .config = .{}, .system = .{}, .capabilities = manifest };
    var operation_probe = std.mem.zeroes(linux.io_uring_probe);
    operation_probe.last_op = .LINKAT;
    operation_probe.ops_len = @intFromEnum(linux.IORING_OP.LINKAT) + 1;
    for (manifest.opcode_requirements) |requirement| {
        operation_probe.ops[@intFromEnum(requirement.opcode)].flags =
            linux.IO_URING_OP_SUPPORTED;
    }
    operation_probe.ops[@intFromEnum(linux.IORING_OP.FSYNC)].flags = 0;
    const failure = missingOpcodeFailure(&context, operation_probe).?;
    try std.testing.expectEqual(ErrorCode.opcode_missing, failure.code);
    try std.testing.expectEqual(Phase.opcode_manifest, failure.phase);
    try std.testing.expectEqual(Operation.fsync, failure.operation);
    try std.testing.expectEqual(Requirement.opcode, failure.requirement);
}

test "invalid public profiles fail before ring setup" {
    const Case = struct {
        profile: RingProfile,
        issue: ProfileIssue,
    };
    const cases = [_]Case{
        .{
            .profile = .{ .submission_entries = 1 },
            .issue = .submission_entries_out_of_range,
        },
        .{
            .profile = .{ .submission_entries = 3 },
            .issue = .submission_entries_not_power_of_two,
        },
        .{
            .profile = .{ .completion_entries = 2 },
            .issue = .completion_entries_out_of_range,
        },
        .{
            .profile = .{ .completion_entries = 24 },
            .issue = .completion_entries_not_power_of_two,
        },
        .{
            .profile = .{ .submission_entries = 16, .completion_entries = 16 },
            .issue = .completion_queue_too_small,
        },
    };
    for (cases) |case| {
        const result = check(.{ .worker_index = 42, .ring = case.profile });
        const failure = switch (result) {
            .failure => |value| value,
            .ready => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(ErrorCode.invalid_profile, failure.code);
        try std.testing.expectEqual(Phase.profile, failure.phase);
        try std.testing.expectEqual(@as(u16, 42), failure.worker_index);
        try std.testing.expectEqual(@as(i64, @intFromEnum(case.issue)), failure.observed);
    }
}

test "completion failures preserve every active proof dimension" {
    const context = Context{ .config = .{}, .system = .{} };
    const Case = struct {
        phase: Phase,
        operation: Operation,
        tag: runtime.Tag,
        expected_result: i32,
        observed_result: i32,
        flags: u32,
        requirement: Requirement,
    };
    const cases = [_]Case{
        .{
            .phase = .nop,
            .operation = .nop,
            .tag = .nop,
            .expected_result = 0,
            .observed_result = -@as(i32, @intFromEnum(linux.E.PERM)),
            .flags = 0,
            .requirement = .opcode,
        },
        .{
            .phase = .timeout,
            .operation = .timeout,
            .tag = .timeout,
            .expected_result = -@as(i32, @intFromEnum(linux.E.TIME)),
            .observed_result = 0,
            .flags = 0,
            .requirement = .timeout,
        },
        .{
            .phase = .multishot_receive,
            .operation = .recv,
            .tag = .receive,
            .expected_result = 1,
            .observed_result = 1,
            .flags = linux.IORING_CQE_F_MORE,
            .requirement = .multishot_receive,
        },
        .{
            .phase = .send,
            .operation = .send,
            .tag = .send,
            .expected_result = 1,
            .observed_result = 0,
            .flags = 0,
            .requirement = .selected_send,
        },
    };

    for (cases) |case| {
        const cqe = linux.io_uring_cqe{
            .user_data = @intFromEnum(case.tag),
            .res = case.observed_result,
            .flags = case.flags,
        };
        const failure = runtime.completionFailure(
            &context,
            case.phase,
            case.operation,
            cqe,
            @intFromEnum(case.tag),
            case.expected_result,
        );
        try std.testing.expectEqual(ErrorCode.completion_failed, failure.code);
        try std.testing.expectEqual(case.phase, failure.phase);
        try std.testing.expectEqual(case.operation, failure.operation);
        try std.testing.expectEqual(case.requirement, failure.requirement);
        try std.testing.expectEqual(@as(i64, case.expected_result), failure.expected);
        try std.testing.expectEqual(@as(i64, case.observed_result), failure.observed);
        try std.testing.expectEqual(case.flags, failure.observed_cqe_flags);
    }
}
