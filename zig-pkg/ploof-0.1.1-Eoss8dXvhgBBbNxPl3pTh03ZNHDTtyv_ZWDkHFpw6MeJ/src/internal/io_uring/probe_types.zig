const std = @import("std");
const linux = std.os.linux;
const capabilities = @import("capabilities.zig");

pub const RingProfile = struct {
    submission_entries: u16 = 8,
    completion_entries: u32 = 16,

    pub fn validate(profile: RingProfile) ?ProfileIssue {
        if (profile.submission_entries < 2 or profile.submission_entries > 32768) {
            return .submission_entries_out_of_range;
        }
        if (!std.math.isPowerOfTwo(profile.submission_entries)) {
            return .submission_entries_not_power_of_two;
        }
        if (profile.completion_entries < 4 or profile.completion_entries > 65536) {
            return .completion_entries_out_of_range;
        }
        if (!std.math.isPowerOfTwo(profile.completion_entries)) {
            return .completion_entries_not_power_of_two;
        }
        if (profile.completion_entries < @as(u32, profile.submission_entries) * 2) {
            return .completion_queue_too_small;
        }
        return null;
    }
};

pub const ProfileIssue = enum(u8) {
    submission_entries_out_of_range,
    submission_entries_not_power_of_two,
    completion_entries_out_of_range,
    completion_entries_not_power_of_two,
    completion_queue_too_small,
};

pub const Config = struct {
    worker_index: u16 = 0,
    ring: RingProfile = .{},
};

pub const ErrorCode = enum(u16) {
    invalid_profile = 1001,
    kernel_too_old = 1002,
    ring_setup_failed = 1003,
    ring_shape_mismatch = 1004,
    ring_mapping_failed = 1005,
    feature_missing = 1006,
    opcode_probe_failed = 1007,
    opcode_missing = 1008,
    buffer_ring_failed = 1009,
    socket_probe_failed = 1010,
    submission_failed = 1011,
    completion_failed = 1012,
    probe_timed_out = 1013,
    runtime_invariant = 1014,
    cleanup_failed = 1015,
    kernel_version_unavailable = 1016,
    monotonic_clock_unavailable = 1017,
    event_counter_failed = 1018,

    pub fn text(code: ErrorCode) []const u8 {
        return switch (code) {
            .invalid_profile => "PLOOF-E1001",
            .kernel_too_old => "PLOOF-E1002",
            .ring_setup_failed => "PLOOF-E1003",
            .ring_shape_mismatch => "PLOOF-E1004",
            .ring_mapping_failed => "PLOOF-E1005",
            .feature_missing => "PLOOF-E1006",
            .opcode_probe_failed => "PLOOF-E1007",
            .opcode_missing => "PLOOF-E1008",
            .buffer_ring_failed => "PLOOF-E1009",
            .socket_probe_failed => "PLOOF-E1010",
            .submission_failed => "PLOOF-E1011",
            .completion_failed => "PLOOF-E1012",
            .probe_timed_out => "PLOOF-E1013",
            .runtime_invariant => "PLOOF-E1014",
            .cleanup_failed => "PLOOF-E1015",
            .kernel_version_unavailable => "PLOOF-E1016",
            .monotonic_clock_unavailable => "PLOOF-E1017",
            .event_counter_failed => "PLOOF-E1018",
        };
    }
};

pub const Phase = enum(u8) {
    profile,
    kernel_version,
    ring_setup,
    ring_mapping,
    feature_manifest,
    opcode_manifest,
    buffer_registration,
    nop,
    listener,
    multishot_accept,
    multishot_receive,
    send,
    timeout,
    cancellation,
    event_wake,
    cleanup,
};

pub const Operation = capabilities.Operation;
pub const Requirement = capabilities.Requirement;
pub const FeatureRequirement = capabilities.FeatureRequirement;
pub const OpcodeRequirement = capabilities.OpcodeRequirement;
pub const BufferRingRequirement = capabilities.BufferRingRequirement;
pub const Proof = capabilities.Proof;
pub const ReactorCapabilityManifest = capabilities.ReactorCapabilityManifest;
pub const FeatureRequirements = capabilities.FeatureRequirements;
pub const Manifest = capabilities.Manifest;
pub const capabilityManifest = capabilities.manifest;
pub const mergeFeatureRequirements = capabilities.merge;
pub const accumulateFeatureRequirements = capabilities.accumulate;
pub const accumulatedCapabilityManifest = capabilities.accumulatedManifest;
pub const reactor_capability_manifest = capabilities.reactor_capability_manifest;
pub const missingOpcode = capabilities.missingOpcode;

pub const KnownSystemEvidence = packed struct(u8) {
    kernel_release: bool = false,
    io_uring_disabled: bool = false,
    io_uring_group: bool = false,
    seccomp_mode: bool = false,
    rlimit_nofile: bool = false,
    rlimit_memlock: bool = false,
    _: u2 = 0,
};

pub const SystemEvidence = extern struct {
    kernel_release: [64]u8 = [_]u8{0} ** 64,
    kernel_release_len: u8 = 0,
    io_uring_disabled: i32 = 0,
    io_uring_group: i32 = 0,
    seccomp_mode: i8 = 0,
    rlimit_nofile: u64 = 0,
    rlimit_memlock: u64 = 0,
    known: KnownSystemEvidence = .{},

    pub fn release(evidence: *const SystemEvidence) []const u8 {
        return evidence.kernel_release[0..evidence.kernel_release_len];
    }
};

pub const ErrnoStatus = enum(u8) {
    none,
    known,
    unavailable,
};

pub const CleanupStatus = enum(u8) {
    clean,
    process_exit_required,
};

pub const Failure = extern struct {
    code: ErrorCode,
    phase: Phase,
    operation: Operation,
    requirement: Requirement,
    worker_index: u16,
    errno_status: ErrnoStatus,
    cleanup_status: CleanupStatus = .clean,
    errno: u16,
    requested_submission_entries: u16,
    requested_completion_entries: u32,
    returned_submission_entries: u32,
    returned_completion_entries: u32,
    returned_features: u32,
    requested_setup_flags: u32,
    requested_buffer_group_id: u16,
    requested_buffer_count: u16,
    requested_buffer_size: u16,
    requested_buffer_ring_bytes: u32,
    expected_user_data: u64 = 0,
    observed_user_data: u64 = 0,
    observed_cqe_flags: u32 = 0,
    expected: i64,
    observed: i64,
    system: SystemEvidence,

    pub fn requiresProcessExit(failure: *const Failure) bool {
        return failure.cleanup_status == .process_exit_required;
    }

    pub fn markProcessExitRequired(failure: *Failure) void {
        failure.cleanup_status = .process_exit_required;
    }

    pub fn render(failure: *const Failure, buffer: []u8) std.fmt.BufPrintError![]const u8 {
        var scratch: DiagnosticScratch = undefined;
        const diagnostic = diagnosticText(failure, &scratch);
        return std.fmt.bufPrint(
            buffer,
            "{s} startup failure: phase={s} operation={s} requirement={s} " ++
                "errno={s} cleanup={s} worker={d} kernel={s} sq={d}/{d} cq={d}/{d} " ++
                "flags=0x{x} features=0x{x} buffer_group={d} buffers={d}x{d} " ++
                "buffer_ring_bytes={d} user_data=0x{x}/0x{x} cqe_flags=0x{x} " ++
                "expected={d} observed={d} " ++
                "io_uring_disabled={s} io_uring_policy={s} " ++
                "io_uring_group={s} seccomp={s} rlimit_nofile={s} " ++
                "rlimit_memlock={s}; errno may indicate kernel, seccomp/LSM, " ++
                "policy, or resource constraints; no fallback reactor\n",
            .{
                failure.code.text(),
                @tagName(failure.phase),
                @tagName(failure.operation),
                @tagName(failure.requirement),
                diagnostic.errno,
                @tagName(failure.cleanup_status),
                failure.worker_index,
                diagnostic.kernel,
                failure.returned_submission_entries,
                failure.requested_submission_entries,
                failure.returned_completion_entries,
                failure.requested_completion_entries,
                failure.requested_setup_flags,
                failure.returned_features,
                failure.requested_buffer_group_id,
                failure.requested_buffer_count,
                failure.requested_buffer_size,
                failure.requested_buffer_ring_bytes,
                failure.observed_user_data,
                failure.expected_user_data,
                failure.observed_cqe_flags,
                failure.expected,
                failure.observed,
                diagnostic.io_uring_disabled,
                diagnostic.io_uring_policy,
                diagnostic.io_uring_group,
                diagnostic.seccomp,
                diagnostic.rlimit_nofile,
                diagnostic.rlimit_memlock,
            },
        );
    }
};

comptime {
    std.debug.assert(@sizeOf(Failure) <= 256);
}

const DiagnosticScratch = struct {
    errno: [32]u8,
    io_uring_disabled: [16]u8,
    io_uring_group: [16]u8,
    seccomp: [16]u8,
    rlimit_nofile: [32]u8,
    rlimit_memlock: [32]u8,
};

const DiagnosticText = struct {
    errno: []const u8,
    kernel: []const u8,
    io_uring_disabled: []const u8,
    io_uring_policy: []const u8,
    io_uring_group: []const u8,
    seccomp: []const u8,
    rlimit_nofile: []const u8,
    rlimit_memlock: []const u8,
};

fn diagnosticText(failure: *const Failure, scratch: *DiagnosticScratch) DiagnosticText {
    return .{
        .errno = formatErrno(&scratch.errno, failure.errno_status, failure.errno),
        .kernel = if (failure.system.known.kernel_release)
            failure.system.release()
        else
            "unknown",
        .io_uring_disabled = formatKnown(
            &scratch.io_uring_disabled,
            failure.system.known.io_uring_disabled,
            failure.system.io_uring_disabled,
        ),
        .io_uring_policy = if (failure.system.known.io_uring_disabled and
            failure.system.io_uring_disabled != 0)
            "io_uring_disabled_nonzero"
        else
            "not_proven",
        .io_uring_group = formatKnown(
            &scratch.io_uring_group,
            failure.system.known.io_uring_group,
            failure.system.io_uring_group,
        ),
        .seccomp = formatKnown(
            &scratch.seccomp,
            failure.system.known.seccomp_mode,
            failure.system.seccomp_mode,
        ),
        .rlimit_nofile = formatLimit(
            &scratch.rlimit_nofile,
            failure.system.known.rlimit_nofile,
            failure.system.rlimit_nofile,
        ),
        .rlimit_memlock = formatLimit(
            &scratch.rlimit_memlock,
            failure.system.known.rlimit_memlock,
            failure.system.rlimit_memlock,
        ),
    };
}

fn formatErrno(buffer: []u8, status: ErrnoStatus, errno_value: u16) []const u8 {
    return switch (status) {
        .none => "none",
        .unavailable => "unknown",
        .known => std.fmt.bufPrint(
            buffer,
            "{s}({d})",
            .{ @tagName(@as(linux.E, @enumFromInt(errno_value))), errno_value },
        ) catch "unknown",
    };
}

fn formatKnown(buffer: []u8, known: bool, value: anytype) []const u8 {
    if (!known) return "unknown";
    return std.fmt.bufPrint(buffer, "{d}", .{value}) catch "overflow";
}

fn formatLimit(buffer: []u8, known: bool, value: u64) []const u8 {
    if (!known) return "unknown";
    if (value == linux.RLIM.INFINITY) return "unlimited";
    return std.fmt.bufPrint(buffer, "{d}", .{value}) catch "overflow";
}

pub const Report = extern struct {
    submission_entries: u32,
    completion_entries: u32,
    setup_flags: u32,
    features: u32,
    proofs: Proof,
};

pub const Result = union(enum) {
    ready: Report,
    failure: Failure,
};

pub const Context = struct {
    config: Config,
    system: SystemEvidence,
    capabilities: ReactorCapabilityManifest = reactor_capability_manifest,
    returned_submission_entries: u32 = 0,
    returned_completion_entries: u32 = 0,
    returned_features: u32 = 0,

    pub fn failure(
        context: *const Context,
        code: ErrorCode,
        phase: Phase,
        operation: Operation,
        requirement: Requirement,
        errno_value: linux.E,
        expected: i64,
        observed: i64,
    ) Failure {
        const manifest = context.capabilities;
        return .{
            .code = code,
            .phase = phase,
            .operation = operation,
            .requirement = requirement,
            .worker_index = context.config.worker_index,
            .errno_status = if (errno_value == .SUCCESS) .none else .known,
            .errno = @intFromEnum(errno_value),
            .requested_submission_entries = context.config.ring.submission_entries,
            .requested_completion_entries = context.config.ring.completion_entries,
            .returned_submission_entries = context.returned_submission_entries,
            .returned_completion_entries = context.returned_completion_entries,
            .returned_features = context.returned_features,
            .requested_setup_flags = manifest.setup_flags,
            .requested_buffer_group_id = manifest.buffer_ring.group_id,
            .requested_buffer_count = manifest.buffer_ring.buffer_count,
            .requested_buffer_size = manifest.buffer_ring.buffer_size,
            .requested_buffer_ring_bytes = manifest.buffer_ring.ring_bytes,
            .expected = expected,
            .observed = observed,
            .system = context.system,
        };
    }

    pub fn failureWithoutErrno(
        context: *const Context,
        code: ErrorCode,
        phase: Phase,
        operation: Operation,
        requirement: Requirement,
        expected: i64,
        observed: i64,
    ) Failure {
        var result = context.failure(
            code,
            phase,
            operation,
            requirement,
            .SUCCESS,
            expected,
            observed,
        );
        result.errno_status = .unavailable;
        return result;
    }
};

test "ring profile has bounded power-of-two queues" {
    try std.testing.expectEqual(null, (RingProfile{}).validate());
    try std.testing.expectEqual(
        null,
        (RingProfile{ .submission_entries = 2, .completion_entries = 4 }).validate(),
    );
    try std.testing.expectEqual(
        ProfileIssue.submission_entries_out_of_range,
        (RingProfile{ .submission_entries = 1 }).validate(),
    );
    try std.testing.expectEqual(
        ProfileIssue.submission_entries_not_power_of_two,
        (RingProfile{ .submission_entries = 3 }).validate(),
    );
    try std.testing.expectEqual(
        ProfileIssue.completion_entries_out_of_range,
        (RingProfile{ .completion_entries = 131072 }).validate(),
    );
    try std.testing.expectEqual(
        ProfileIssue.completion_entries_not_power_of_two,
        (RingProfile{ .completion_entries = 24 }).validate(),
    );
    try std.testing.expectEqual(
        ProfileIssue.completion_queue_too_small,
        (RingProfile{ .submission_entries = 16, .completion_entries = 16 }).validate(),
    );
    try std.testing.expectEqual(
        null,
        (RingProfile{
            .submission_entries = 32768,
            .completion_entries = 65536,
        }).validate(),
    );
}

test "error codes have stable unique text" {
    inline for (@typeInfo(ErrorCode).@"enum".fields, 0..) |field, index| {
        const code: ErrorCode = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(u16, 1001 + index), @intFromEnum(code));
        try std.testing.expect(std.mem.startsWith(u8, code.text(), "PLOOF-E10"));
        inline for (@typeInfo(ErrorCode).@"enum".fields[index + 1 ..]) |other_field| {
            const other: ErrorCode = @enumFromInt(other_field.value);
            try std.testing.expect(!std.mem.eql(u8, code.text(), other.text()));
        }
    }
}

test "startup failure is fixed-size and renders bounded diagnostics" {
    try std.testing.expect(@sizeOf(Failure) <= 256);
    var context = Context{ .config = .{}, .system = .{} };
    context.system.kernel_release_len = 3;
    @memcpy(context.system.kernel_release[0..3], "7.1");
    context.system.known.kernel_release = true;
    const failure = context.failure(
        .ring_setup_failed,
        .ring_setup,
        .none,
        .setup_flags,
        .PERM,
        reactor_capability_manifest.setup_flags,
        0,
    );
    var buffer: [768]u8 = undefined;
    const rendered = try failure.render(&buffer);
    try std.testing.expect(std.mem.startsWith(u8, rendered, "PLOOF-E1003"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "errno=PERM(1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cleanup=clean") != null);
    try std.testing.expect(!failure.requiresProcessExit());
    try std.testing.expect(std.mem.indexOf(u8, rendered, "io_uring_policy=not_proven") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "kernel=7.1") != null);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            rendered,
            "buffer_group=1 buffers=4x64 buffer_ring_bytes=64",
        ) != null,
    );
    try std.testing.expect(std.mem.endsWith(u8, rendered, "no fallback reactor\n"));

    const unavailable = context.failureWithoutErrno(
        .ring_mapping_failed,
        .ring_mapping,
        .none,
        .single_mmap,
        0,
        0,
    );
    const unavailable_rendered = try unavailable.render(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, unavailable_rendered, "errno=unknown") != null);

    var policy_failure = failure;
    policy_failure.system.known.io_uring_disabled = true;
    policy_failure.system.io_uring_disabled = 2;
    const policy_rendered = try policy_failure.render(&buffer);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            policy_rendered,
            "io_uring_policy=io_uring_disabled_nonzero",
        ) != null,
    );

    var unproven = failure;
    unproven.markProcessExitRequired();
    try std.testing.expect(unproven.requiresProcessExit());
    const unproven_rendered = try unproven.render(&buffer);
    try std.testing.expect(
        std.mem.indexOf(u8, unproven_rendered, "cleanup=process_exit_required") != null,
    );
}

test "worst-case startup diagnostic fits require buffer" {
    var context = Context{ .config = .{ .worker_index = std.math.maxInt(u16) }, .system = .{} };
    @memset(&context.system.kernel_release, 'x');
    context.system.kernel_release_len = context.system.kernel_release.len;
    context.system.io_uring_disabled = std.math.maxInt(i32);
    context.system.io_uring_group = std.math.maxInt(i32);
    context.system.seccomp_mode = std.math.maxInt(i8);
    context.system.rlimit_nofile = std.math.maxInt(u64);
    context.system.rlimit_memlock = std.math.maxInt(u64);
    context.system.known = .{
        .kernel_release = true,
        .io_uring_disabled = true,
        .io_uring_group = true,
        .seccomp_mode = true,
        .rlimit_nofile = true,
        .rlimit_memlock = true,
    };
    context.returned_submission_entries = std.math.maxInt(u32);
    context.returned_completion_entries = std.math.maxInt(u32);
    context.returned_features = std.math.maxInt(u32);
    var failure = context.failure(
        .completion_failed,
        .cancellation,
        .async_cancel,
        .cancellation,
        .PERM,
        std.math.maxInt(i64),
        std.math.minInt(i64),
    );
    failure.expected_user_data = std.math.maxInt(u64);
    failure.observed_user_data = std.math.maxInt(u64);
    failure.observed_cqe_flags = std.math.maxInt(u32);

    var buffer: [768]u8 = undefined;
    const rendered = try failure.render(&buffer);
    try std.testing.expect(rendered.len <= buffer.len);
}

test "reactor capability manifest stays exact" {
    const expected_features = [_]FeatureRequirement{
        .{ .bit = linux.IORING_FEAT_SINGLE_MMAP, .requirement = .single_mmap },
        .{ .bit = linux.IORING_FEAT_NODROP, .requirement = .no_drop },
        .{ .bit = linux.IORING_FEAT_SUBMIT_STABLE, .requirement = .submit_stable },
        .{ .bit = linux.IORING_FEAT_FAST_POLL, .requirement = .fast_poll },
    };
    const expected_opcodes = [_]OpcodeRequirement{
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
    const manifest = reactor_capability_manifest;

    try std.testing.expectEqual(@as(u32, 0x3188), manifest.setup_flags);
    try std.testing.expectEqual(@as(u32, 0x27), manifest.feature_mask);
    try std.testing.expectEqualSlices(
        FeatureRequirement,
        &expected_features,
        &manifest.feature_requirements,
    );
    try std.testing.expectEqualSlices(
        OpcodeRequirement,
        &expected_opcodes,
        manifest.opcode_requirements,
    );
    try std.testing.expectEqual(
        BufferRingRequirement{
            .group_id = 1,
            .buffer_count = 4,
            .buffer_size = 64,
            .ring_bytes = 64,
            .incremental = false,
        },
        manifest.buffer_ring,
    );
    try std.testing.expectEqual(
        @as(u16, 0x7f),
        @as(u16, @bitCast(manifest.active_proofs)),
    );
}
