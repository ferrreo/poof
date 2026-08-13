const std = @import("std");
const linux = std.os.linux;

const config_module = @import("load_driver_config.zig");
const engine = @import("load_driver_engine.zig");
const report = @import("load_driver_report.zig");

var storage: engine.Storage align(@alignOf(engine.Storage)) = .{};
var report_bytes: [report.bytes_max]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) void {
    const config = config_module.parse(init.args) catch |problem| {
        if (problem == error.HelpRequested) {
            writeAll(1, usage) catch {};
            linux.exit_group(0);
        }
        writeProblem("invalid command line", problem);
        writeAll(2, usage) catch {};
        linux.exit_group(2);
    };
    const result = engine.run(config, &storage) catch |problem| {
        writeProblem("load run failed", problem);
        linux.exit_group(1);
    };
    const document = report.render(&report_bytes, config, result) catch |problem| {
        writeProblem("report failed", problem);
        linux.exit_group(1);
    };
    writeAll(1, document) catch linux.exit_group(1);
    const failed = result.transport_failures != 0 or result.application_failures != 0;
    const calibration_failed = config.calibration and
        @as(u128, result.requestsPerSecond()) < @as(u128, config.rate) * 2;
    linux.exit_group(if (failed or calibration_failed) 1 else 0);
}

fn writeProblem(context: []const u8, problem: anyerror) void {
    writeAll(2, "ploof-load-driver: ") catch {};
    writeAll(2, context) catch {};
    writeAll(2, ": ") catch {};
    writeAll(2, @errorName(problem)) catch {};
    writeAll(2, "\n") catch {};
}

fn writeAll(descriptor: linux.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const raw = linux.write(descriptor, bytes[written..].ptr, bytes.len - written);
        switch (linux.errno(raw)) {
            .SUCCESS => {
                if (raw == 0) return error.WriteFailed;
                written += raw;
            },
            .INTR => {},
            else => return error.WriteFailed,
        }
    }
}

const usage =
    \\usage: ploof-load-driver [options]
    \\
    \\target:     --address IPv4 --host HOST --port N --path /PATH --method METHOD
    \\request:    --request-body TEXT | --request-body-file PATH |
    \\            --request-body-bytes N [--request-body-byte HEX]
    \\            --content-type TYPE
    \\            --header 'Name: value' (repeat up to 8; framing overrides rejected)
    \\expected:   --expect-status 200..599_except_304 --expect-body TEXT |
    \\            --expect-body-bytes N --expect-sha256 64_HEX
    \\load:       --requests N --concurrency N --timeout-ms N
    \\            --scheduling closed-loop --connections keepalive|churn
    \\            --scheduling constant-rate --rate N
    \\calibrate:  scheduler/request-loop lower bound; fails below 2x offered rate
    \\limits:     IPv4 only; HEAD, CONNECT, DNS, IPv6, and pipelining are unsupported
    \\
;

test {
    _ = config_module;
    _ = engine;
    _ = report;
}
