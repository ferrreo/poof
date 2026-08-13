const std = @import("std");
const pg = @import("pg");
const store = @import("../store.zig");

const Migration = struct {
    version: i32,
    name: []const u8,
    sql: []const u8,
};

const migrations = [_]Migration{
    .{
        .version = 1,
        .name = "initial",
        .sql = @embedFile("migration_001"),
    },
    .{
        .version = 2,
        .name = "seed_default_board",
        .sql = @embedFile("migration_002"),
    },
    .{
        .version = 3,
        .name = "action_rate_limits",
        .sql = @embedFile("migration_003"),
    },
};

const advisory_lock_id: i64 = 0x506f6f664d696772;

pub fn apply(pool: *pg.Pool) store.Error!void {
    var connection = pool.acquire() catch return error.DatabaseUnavailable;
    defer connection.release();

    connection.begin() catch return error.DatabaseUnavailable;
    errdefer connection.tryRollback() catch {};

    _ = connection.exec(
        "SELECT pg_advisory_xact_lock($1)",
        .{advisory_lock_id},
    ) catch return error.DatabaseUnavailable;

    const has_table = querySchemaTable(connection) catch return error.DatabaseUnavailable;
    if (has_table) try rejectUnknownMigrations(connection);

    for (migrations) |migration| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(migration.sql, &digest, .{});

        if (has_table or migration.version != 1) {
            if (try appliedChecksum(connection, migration.version)) |stored| {
                if (!std.crypto.timing_safe.eql([32]u8, stored, digest)) {
                    return error.MigrationMismatch;
                }
                continue;
            }
        }

        _ = connection.exec(migration.sql, .{}) catch return error.DatabaseUnavailable;
        _ = connection.exec(
            "INSERT INTO schema_migrations (version, name, checksum) VALUES ($1, $2, $3)",
            .{ migration.version, migration.name, pg.Binary{ .data = &digest } },
        ) catch return error.DatabaseUnavailable;
    }

    connection.commit() catch return error.DatabaseUnavailable;
}

fn querySchemaTable(connection: *pg.Conn) !bool {
    var row = (try connection.row(
        "SELECT to_regclass('public.schema_migrations') IS NOT NULL",
        .{},
    )) orelse return error.InvalidDatabaseData;
    defer row.deinit() catch {};
    return row.get(bool, 0) catch error.InvalidDatabaseData;
}

fn rejectUnknownMigrations(connection: *pg.Conn) store.Error!void {
    var row = (connection.row(
        "SELECT COALESCE(max(version), 0) FROM schema_migrations",
        .{},
    ) catch return error.DatabaseUnavailable) orelse return error.InvalidDatabaseData;
    defer row.deinit() catch {};
    const maximum = row.get(i32, 0) catch return error.InvalidDatabaseData;
    if (maximum > migrations[migrations.len - 1].version) return error.UnknownMigration;
}

fn appliedChecksum(connection: *pg.Conn, version: i32) store.Error!?[32]u8 {
    var row = (connection.row(
        "SELECT checksum FROM schema_migrations WHERE version = $1",
        .{version},
    ) catch return error.DatabaseUnavailable) orelse return null;
    defer row.deinit() catch {};
    const bytes = row.get([]u8, 0) catch return error.InvalidDatabaseData;
    if (bytes.len != 32) return error.InvalidDatabaseData;
    return bytes[0..32].*;
}

pub fn count() usize {
    return migrations.len;
}
