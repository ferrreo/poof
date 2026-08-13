const std = @import("std");
const ploof = @import("ploof");
const poof = @import("poof");

const Runner = ploof.ServerRunner(poof.App, .{ .workers_max = 8 });
var runner: Runner align(@alignOf(Runner)) = Runner.init();

pub fn main(init: std.process.Init) void {
    const config = poof.config.Config.fromMap(init.environ_map) catch |problem| {
        std.log.err("invalid Poof configuration: {s}", .{@errorName(problem)});
        std.process.exit(78);
    };
    var database = poof.postgres.Postgres.init(
        init.io,
        init.gpa,
        config.database_url,
        config.database_pool_size,
    ) catch |problem| {
        std.log.err("PostgreSQL startup failed: {s}", .{@errorName(problem)});
        std.process.exit(69);
    };
    database.migrate() catch |problem| {
        std.log.err("database migration failed: {s}", .{@errorName(problem)});
        std.process.exit(70);
    };
    database.cleanupExpiredAuth() catch {};
    var state = poof.State.init(&config, &database, init.io, init.gpa) catch |problem| {
        std.log.err("application security startup failed: {s}", .{@errorName(problem)});
        std.process.exit(78);
    };

    runner.runOrExit(&state, .{
        .listener = .{ .address = .{ .ipv4 = .{
            .bytes = .{ 127, 0, 0, 1 },
            .port = config.listen_port,
        } } },
        .worker_count = config.workers,
        .readiness = &state.readiness,
        .forwarding = .{
            .family = .x_forwarded,
            .trusted = &.{ "127.0.0.1/32", "::1/128" },
        },
    });
}
