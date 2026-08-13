const std = @import("std");
const linux = std.os.linux;

const lifecycle = @import("../../../lifecycle.zig");
const startup = @import("../../../server/startup.zig");

pub const success: u8 = 0;
pub const startup_failure: u8 = 1;
pub const shutdown_incomplete: u8 = 2;
pub const runner_failure: u8 = 3;

pub fn run(
    runner: anytype,
    state: anytype,
    config: anytype,
    diagnostic_descriptor: linux.fd_t,
) noreturn {
    const result = runner.run(state, config) catch |problem| {
        var output: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &output,
            "PLOOF runner failure: error={s}\n",
            .{@errorName(problem)},
        ) catch "PLOOF runner failure\n";
        writeDiagnostic(diagnostic_descriptor, rendered);
        linux.exit_group(runner_failure);
    };
    switch (result) {
        .stopped => linux.exit_group(success),
        .startup_failure => |failure| exitStartup(diagnostic_descriptor, failure),
        .incomplete => |report| exitIncomplete(diagnostic_descriptor, report),
    }
}

fn exitStartup(descriptor: linux.fd_t, failure: startup.Failure) noreturn {
    var output: [startup.rendered_bytes_max]u8 = undefined;
    const rendered = failure.render(&output) catch
        "PLOOF startup failure; no fallback reactor\n";
    writeDiagnostic(descriptor, rendered);
    linux.exit_group(startup_failure);
}

fn exitIncomplete(descriptor: linux.fd_t, report: lifecycle.ShutdownIncomplete) noreturn {
    var output: [512]u8 = undefined;
    const rendered = report.render(&output) catch "PLOOF shutdown incomplete\n";
    writeDiagnostic(descriptor, rendered);
    linux.exit_group(shutdown_incomplete);
}

fn writeDiagnostic(descriptor: linux.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const result = linux.write(descriptor, bytes[written..].ptr, bytes.len - written);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return;
                written += result;
            },
            .INTR => continue,
            else => return,
        }
    }
}

const FakeResult = union(enum) {
    startup_failure: startup.Failure,
    stopped,
    incomplete: lifecycle.ShutdownIncomplete,
};

const FakeMode = enum(u8) { stopped, startup_failure, incomplete, failed };

const FakeRunner = struct {
    mode: FakeMode,

    fn run(self: *FakeRunner, _: *u8, _: u8) error{ControlFailed}!FakeResult {
        return switch (self.mode) {
            .stopped => .stopped,
            .startup_failure => .{ .startup_failure = .{
                .configuration = .worker_count_zero,
            } },
            .incomplete => .{ .incomplete = .{
                .remaining = .{ .workers = 1 },
                .dropped_access_events = 0,
            } },
            .failed => error.ControlFailed,
        };
    }
};

test "run-or-exit writes bounded diagnostics and exact exit codes" {
    try expectExit(.stopped, success, "");
    try expectExit(.startup_failure, startup_failure, "configuration=worker_count_zero");
    try expectExit(.incomplete, shutdown_incomplete, "workers=1");
    try expectExit(.failed, runner_failure, "error=ControlFailed");
}

fn expectExit(mode: FakeMode, expected_code: u8, expected: []const u8) !void {
    var descriptors: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&descriptors, linux.O{ .CLOEXEC = true })) != .SUCCESS) {
        return error.PipeFailed;
    }
    const fork_result = linux.fork();
    if (linux.errno(fork_result) != .SUCCESS) return error.ForkFailed;
    if (fork_result == 0) {
        _ = linux.close(descriptors[0]);
        var runner = FakeRunner{ .mode = mode };
        var state: u8 = 0;
        run(&runner, &state, 0, descriptors[1]);
    }
    _ = linux.close(descriptors[1]);
    var output: [1024]u8 = undefined;
    const used = try readAll(descriptors[0], &output);
    _ = linux.close(descriptors[0]);
    var status: u32 = 0;
    const waited = linux.waitpid(@intCast(fork_result), &status, 0);
    if (linux.errno(waited) != .SUCCESS) return error.WaitFailed;
    try std.testing.expectEqual(@as(u32, 0), status & 0x7f);
    try std.testing.expectEqual(@as(u32, expected_code), (status >> 8) & 0xff);
    if (expected.len == 0) {
        try std.testing.expectEqual(@as(usize, 0), used);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, output[0..used], expected) != null);
    }
}

fn readAll(descriptor: linux.fd_t, output: []u8) !usize {
    var used: usize = 0;
    while (used < output.len) {
        const result = linux.read(descriptor, output[used..].ptr, output.len - used);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return used;
                used += result;
            },
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
    return used;
}
