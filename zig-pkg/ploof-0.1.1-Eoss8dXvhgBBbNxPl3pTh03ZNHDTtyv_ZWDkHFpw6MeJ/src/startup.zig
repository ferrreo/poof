const std = @import("std");
const linux = std.os.linux;
const application_csrf = @import("internal/application/csrf.zig");
const upload_catalog = @import("internal/application/upload_catalog.zig");
const upload_route_metrics = @import("internal/runtime/worker/upload_route_metrics.zig");
const probe = @import("internal/io_uring/probe.zig");

pub const RingProfile = probe.RingProfile;
pub const ProfileIssue = probe.ProfileIssue;
pub const Config = probe.Config;
pub const ErrorCode = probe.ErrorCode;
pub const Phase = probe.Phase;
pub const Operation = probe.Operation;
pub const Requirement = probe.Requirement;
pub const SystemEvidence = probe.SystemEvidence;
pub const ErrnoStatus = probe.ErrnoStatus;
pub const CleanupStatus = probe.CleanupStatus;
pub const Failure = probe.Failure;
pub const FileSinkConfiguration = upload_catalog.FileSinkConfiguration;
pub const UploadRouteProfile = upload_catalog.UploadRouteProfile;

pub const ConfigurationReport = struct {
    file_sinks: []const FileSinkConfiguration,
    upload_routes: []const UploadRouteProfile,
    upload_route_metric_cell_bytes: u16,
    upload_route_metrics_per_worker_bytes: u64,
};

pub const Result = union(enum) {
    ready,
    failure: Failure,
};

pub const ApplicationFailure = application_csrf.StartupFailure;

pub const ApplicationResult = union(enum) {
    ready,
    failure: ApplicationFailure,
};

pub fn check(comptime App: type, config: Config) Result {
    return switch (probe.checkWithManifest(config, applicationManifest(App))) {
        .ready => .ready,
        .failure => |failure| .{ .failure = failure },
    };
}

pub fn require(comptime App: type, config: Config) void {
    switch (check(App, config)) {
        .ready => return,
        .failure => |failure| {
            var buffer: [768]u8 = undefined;
            const rendered = failure.render(&buffer) catch
                "PLOOF startup failure; no fallback reactor\n";
            writeDiagnostic(2, rendered);
            linux.exit_group(1);
        },
    }
}

pub fn checkApplication(comptime App: type, state: *const App.StateType) ApplicationResult {
    if (!@hasDecl(App, "__csrfStartupFailure")) {
        @compileError("PLOOF-E3624 startup requires a Ploof Application type");
    }
    const failure = App.__csrfStartupFailure(state) orelse return .ready;
    return .{ .failure = failure };
}

pub fn requireApplication(comptime App: type, state: *const App.StateType) void {
    switch (checkApplication(App, state)) {
        .ready => return,
        .failure => |failure| {
            var buffer: [256]u8 = undefined;
            const rendered = renderApplicationFailure(failure, &buffer) catch
                "PLOOF startup failure: invalid CSRF application configuration\n";
            writeDiagnostic(2, rendered);
            linux.exit_group(1);
        },
    }
}

pub fn renderApplicationFailure(
    failure: ApplicationFailure,
    output: []u8,
) error{NoSpaceLeft}![]const u8 {
    const kind: []const u8 = switch (failure.issue) {
        .origins => "origin set",
        .source_origins => "source origin set",
        .keyring => "keyring",
    };
    const detail: []const u8 = switch (failure.issue) {
        .origins => |issue| @tagName(issue),
        .source_origins => |issue| @tagName(issue),
        .keyring => |issue| @tagName(issue),
    };
    return if (failure.route_id) |route_id|
        std.fmt.bufPrint(
            output,
            "PLOOF startup failure: CSRF {s} {s} on route {d}\n",
            .{ kind, detail, route_id },
        ) catch error.NoSpaceLeft
    else
        std.fmt.bufPrint(
            output,
            "PLOOF startup failure: CSRF {s} {s} in application middleware\n",
            .{ kind, detail },
        ) catch error.NoSpaceLeft;
}

pub fn configurationReport(comptime App: type) ConfigurationReport {
    if (!@hasDecl(App, "upload_file_sink_configurations")) {
        @compileError("PLOOF-E3526 startup requires a Ploof Application type");
    }
    const route_metric_cell_bytes: u64 = @sizeOf(upload_route_metrics.Cell);
    const upload_route_count: u64 = App.upload_route_profiles.len;
    return .{
        .file_sinks = App.upload_file_sink_configurations[0..],
        .upload_routes = App.upload_route_profiles[0..],
        .upload_route_metric_cell_bytes = @intCast(@sizeOf(upload_route_metrics.Cell)),
        .upload_route_metrics_per_worker_bytes = route_metric_cell_bytes * upload_route_count,
    };
}

fn applicationManifest(comptime App: type) probe.ReactorCapabilityManifest {
    if (!@hasDecl(App, "upload_io_requirements") or
        !@hasDecl(App, "live_static_root_count"))
    {
        @compileError("PLOOF-E3526 startup requires a Ploof Application type");
    }
    return probe.capabilityManifest(.{
        .io_requirements = App.upload_io_requirements,
        .live_static = App.live_static_root_count != 0,
    });
}

const diagnostic_write_attempts_max: u8 = 4;

fn writeDiagnostic(fd: linux.fd_t, bytes: []const u8) void {
    if (!setNonBlocking(fd)) return;

    var written: usize = 0;
    var attempts: u8 = 0;
    while (written < bytes.len and attempts < diagnostic_write_attempts_max) {
        attempts += 1;
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        const errno_value = linux.errno(result);
        if (errno_value == .SUCCESS) {
            if (result == 0) return;
            written += result;
        } else if (errno_value != .INTR) {
            return;
        }
    }
}

fn setNonBlocking(fd: linux.fd_t) bool {
    const get_result = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(get_result) != .SUCCESS) return false;

    const nonblocking: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    const set_result = linux.fcntl(fd, linux.F.SETFL, get_result | nonblocking);
    return linux.errno(set_result) == .SUCCESS;
}

test {
    std.testing.refAllDecls(@This());
}

test "application startup manifest includes exact upload opcodes" {
    const Core = struct {
        pub const upload_io_requirements = @import("multipart.zig").IoRequirements.none;
        pub const live_static_root_count = 0;
    };
    const Upload = struct {
        pub const upload_io_requirements = @import("multipart.zig").IoRequirements{
            .open = true,
            .rename_no_replace = true,
            .sync = true,
        };
        pub const live_static_root_count = 0;
    };
    const Static = struct {
        pub const upload_io_requirements = @import("multipart.zig").IoRequirements.none;
        pub const live_static_root_count = 1;
    };
    const core = applicationManifest(Core);
    const upload = applicationManifest(Upload);
    const static = applicationManifest(Static);
    try std.testing.expectEqual(core.opcode_requirements.len + 3, upload.opcode_requirements.len);
    try std.testing.expectEqual(Operation.openat2, upload.opcode_requirements[10].operation);
    try std.testing.expectEqual(Operation.renameat, upload.opcode_requirements[11].operation);
    try std.testing.expectEqual(Operation.fsync, upload.opcode_requirements[12].operation);
    try std.testing.expectEqual(core.opcode_requirements.len + 2, static.opcode_requirements.len);
    try std.testing.expectEqual(Operation.openat2, static.opcode_requirements[10].operation);
    try std.testing.expectEqual(Operation.statx, static.opcode_requirements[11].operation);
}
