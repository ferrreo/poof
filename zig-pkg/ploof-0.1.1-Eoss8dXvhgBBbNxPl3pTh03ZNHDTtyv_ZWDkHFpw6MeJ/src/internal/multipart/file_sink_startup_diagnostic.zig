const std = @import("std");

const config = @import("../../multipart/file_sink_config.zig");
const runtime = @import("file_sink_runtime.zig");
const upload = @import("../../multipart/upload.zig");

pub const cause_name_bytes_max: usize = 64;
const render_overhead_bytes_max: usize = 1536;
const rendered_capacity: usize = config.root_bytes_hard_max +
    render_overhead_bytes_max;
pub const rendered_bytes_max = rendered_capacity;

pub const Cause = struct {
    bytes: [cause_name_bytes_max]u8,
    length: u8,

    pub fn init(problem: anytype) Cause {
        const Error = @TypeOf(problem);
        const names = @typeInfo(Error).error_set orelse
            @compileError("FileSink startup diagnostic cause must be finite");
        comptime for (names) |error_field| {
            if (error_field.name.len > cause_name_bytes_max) {
                @compileError("FileSink startup diagnostic cause name exceeds capacity");
            }
        };

        const cause_name = @errorName(problem);
        var cause = Cause{
            .bytes = [_]u8{0} ** cause_name_bytes_max,
            .length = @intCast(cause_name.len),
        };
        @memcpy(cause.bytes[0..cause_name.len], cause_name);
        return cause;
    }

    pub fn name(self: *const Cause) []const u8 {
        return self.bytes[0..self.length];
    }
};

pub const DeadlineFailureKind = enum(u8) {
    deadline,
    timer_failure,
    clock_overflow,
};

pub const DeadlineFailure = struct {
    kind: DeadlineFailureKind,
    timeout_ns: u64,
    started_ns: u64,
    /// Zero only when computing the absolute deadline overflowed.
    deadline_ns: u64,
};

pub const Failure = struct {
    code: []const u8,
    root: []const u8,
    staging: config.FileStagingKind,
    mode: u16,
    durability: config.FileDurability,
    phase: runtime.StartupPhase,
    operation: upload.IoKind,
    cause: Cause,
    cleanup: runtime.CleanupStatus,
    anonymous_compatibility_hint: bool,
    deadline: ?DeadlineFailure = null,
};

pub const Diagnostic = struct {
    pub const rendered_bytes_max = rendered_capacity;

    sink_registry_index: u16,
    failure: Failure,

    pub fn render(self: Diagnostic, buffer: []u8) error{NoSpaceLeft}![]const u8 {
        const value = self.failure;
        const rendered = try std.fmt.bufPrint(
            buffer,
            "{s} FileSink startup probe failed " ++
                "sink_registry_index={d} root({d})={s} staging={s} " ++
                "durability={s} mode=0o{o} phase={s} operation={s} cause={s} " ++
                "cleanup(destination_unlink={s},source_unlink={s}," ++
                "staging_sync={s},root_sync={s},probe_close={s}," ++
                "staging_close={s},root_close={s},generator_cleared={})",
            .{
                value.code,
                self.sink_registry_index,
                value.root.len,
                value.root,
                @tagName(value.staging),
                @tagName(value.durability),
                value.mode,
                @tagName(value.phase),
                @tagName(value.operation),
                value.cause.name(),
                @tagName(value.cleanup.destination_unlink),
                @tagName(value.cleanup.source_unlink),
                @tagName(value.cleanup.staging_sync),
                @tagName(value.cleanup.root_sync),
                @tagName(value.cleanup.probe_close),
                @tagName(value.cleanup.staging_close),
                @tagName(value.cleanup.root_close),
                value.cleanup.generator_cleared,
            },
        );
        var length = rendered.len;
        if (value.deadline) |deadline| {
            const deadline_rendered = try std.fmt.bufPrint(
                buffer[length..],
                " startup_deadline(kind={s},timeout_ns={d},started_ns={d},deadline_ns={d})",
                .{
                    @tagName(deadline.kind),
                    deadline.timeout_ns,
                    deadline.started_ns,
                    deadline.deadline_ns,
                },
            );
            length += deadline_rendered.len;
        }
        if (!value.anonymous_compatibility_hint) {
            const newline = try std.fmt.bufPrint(buffer[length..], "\n", .{});
            return buffer[0 .. length + newline.len];
        }
        const hint = try std.fmt.bufPrint(
            buffer[length..],
            "; anonymous staging remains required and Ploof did not fall back; " ++
                "to use compatibility mode, explicitly select " ++
                ".staging = .{{ .named_staging = \"relative/pre-existing-directory\" }}\n",
            .{},
        );
        return buffer[0 .. length + hint.len];
    }
};

pub fn capture(
    comptime Sink: type,
    state: *const Sink.StartupState,
) ?Failure {
    if (comptime !fileSink(Sink)) return null;
    const failure = Sink.startupFailure(state) orelse return null;
    std.debug.assert(std.mem.eql(u8, failure.code, runtime.startup_failure_code));
    return .{
        .code = runtime.startup_failure_code,
        .root = failure.root,
        .staging = Sink.startup_report.staging,
        .mode = failure.mode,
        .durability = failure.durability,
        .phase = failure.phase,
        .operation = failure.operation,
        .cause = Cause.init(failure.cause),
        .cleanup = failure.cleanup,
        .anonymous_compatibility_hint = failure.anonymous_compatibility_hint,
    };
}

fn fileSink(comptime Sink: type) bool {
    if (!@hasDecl(Sink, "ploof_file_sink")) return false;
    return Sink.ploof_file_sink;
}

test {
    std.testing.refAllDecls(@This());
}

test "maximum FileSink startup diagnostic has a published render bound" {
    const root = [_]u8{'r'} ** config.root_bytes_hard_max;
    const diagnostic = Diagnostic{
        .sink_registry_index = std.math.maxInt(u16),
        .failure = .{
            .code = runtime.startup_failure_code,
            .root = &root,
            .staging = .named_staging,
            .mode = std.math.maxInt(u16),
            .durability = .crash_durable,
            .phase = .rollback_unlink_destination,
            .operation = .rename_no_replace,
            .cause = .{
                .bytes = [_]u8{'C'} ** cause_name_bytes_max,
                .length = cause_name_bytes_max,
            },
            .cleanup = .{
                .destination_unlink = .not_needed,
                .source_unlink = .not_needed,
                .staging_sync = .not_needed,
                .root_sync = .not_needed,
                .probe_close = .not_needed,
                .staging_close = .not_needed,
                .root_close = .not_needed,
                .generator_cleared = false,
            },
            .anonymous_compatibility_hint = true,
            .deadline = .{
                .kind = .clock_overflow,
                .timeout_ns = std.math.maxInt(u64),
                .started_ns = std.math.maxInt(u64),
                .deadline_ns = 0,
            },
        },
    };
    var buffer: [Diagnostic.rendered_bytes_max]u8 = undefined;
    const rendered = try diagnostic.render(&buffer);
    try std.testing.expect(rendered.len <= Diagnostic.rendered_bytes_max);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "kind=clock_overflow") != null);
    try std.testing.expectError(
        error.NoSpaceLeft,
        diagnostic.render(buffer[0 .. rendered.len - 1]),
    );
}
