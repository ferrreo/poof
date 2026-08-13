const std = @import("std");
const ploof = @import("ploof");
const config_module = @import("config.zig");
const postgres_module = @import("store/postgres.zig");

pub const Origins = ploof.Csrf.OriginSet(2, 512);

pub const State = struct {
    readiness: ploof.Lifecycle.Readiness = .{},
    config: ?*const config_module.Config = null,
    database: ?*postgres_module.Postgres = null,
    io: ?std.Io = null,
    allocator: ?std.mem.Allocator = null,
    csrf_origins: Origins = .{},
    csrf_keys: ploof.Csrf.Keyring = .{},

    pub fn init(
        settings: *const config_module.Config,
        database_store: *postgres_module.Postgres,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !State {
        return .{
            .config = settings,
            .database = database_store,
            .io = io,
            .allocator = allocator,
            .csrf_origins = try Origins.init(&.{settings.public_url}),
            .csrf_keys = try ploof.Csrf.Keyring.init(
                try ploof.Csrf.Key.init(1, settings.csrf_key),
                null,
            ),
        };
    }
};

pub const Context = ploof.Context(State, ploof.response.standard_head_limits);

pub fn database(context: *Context) ?*postgres_module.Postgres {
    return context.state.database;
}

pub fn config(context: *Context) ?*const config_module.Config {
    return context.state.config;
}

pub fn isProduction(context: *Context) bool {
    const value = config(context) orelse return false;
    return value.environment == .production;
}
