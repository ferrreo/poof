const std = @import("std");
const ploof = @import("ploof");
const poof = @import("poof");

const Runner = ploof.ServerRunner(poof.App, .{ .workers_max = 8 });
var runner: Runner align(@alignOf(Runner)) = Runner.init();

pub fn main(init: std.process.Init) void {
    _ = init;

    var state = poof.State{};
    runner.runOrExit(&state, .{
        .listener = .{ .address = .{ .ipv4 = .{
            .bytes = .{ 127, 0, 0, 1 },
            .port = 8080,
        } } },
        .worker_count = 4,
        .readiness = &state.readiness,
    });
}
