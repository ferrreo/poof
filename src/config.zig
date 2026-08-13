const std = @import("std");

pub const Environment = enum {
    development,
    testing,
    production,
};

pub const AdminIds = struct {
    values: [32][]const u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const AdminIds) []const []const u8 {
        return self.values[0..self.len];
    }

    pub fn contains(self: *const AdminIds, discord_id: []const u8) bool {
        for (self.slice()) |candidate| {
            if (std.mem.eql(u8, candidate, discord_id)) return true;
        }
        return false;
    }
};

pub const Config = struct {
    environment: Environment,
    company_name: []const u8,
    tagline: []const u8,
    public_url: []const u8,
    database_url: []const u8,
    discord_client_id: []const u8,
    discord_client_secret: []const u8,
    discord_redirect_uri: []const u8,
    admin_discord_ids: AdminIds,
    csrf_key: [32]u8,
    api_token_pepper: [32]u8,
    listen_port: u16,
    workers: u8,
    database_pool_size: u8,
    session_ttl_days: u16,

    pub fn fromMap(map: *const std.process.Environ.Map) Error!Config {
        const environment = try parseEnvironment(optional(map, "POOF_ENV") orelse "development");
        const company_name = try text(try required(map, "POOF_COMPANY_NAME"), 1, 80);
        const tagline = try text(optional(map, "POOF_TAGLINE") orelse
            "Share feedback, follow the roadmap, and see what shipped.", 0, 200);
        const public_url = try required(map, "POOF_PUBLIC_URL");
        try validatePublicUrl(public_url, environment);

        const database_url = try required(map, "DATABASE_URL");
        try validateDatabaseUrl(database_url);
        const discord_client_id = try required(map, "DISCORD_CLIENT_ID");
        if (!isDiscordId(discord_client_id)) return error.InvalidDiscordClientId;
        const discord_client_secret = try required(map, "DISCORD_CLIENT_SECRET");
        if (discord_client_secret.len < 32 or discord_client_secret.len > 256) {
            return error.InvalidDiscordClientSecret;
        }

        const redirect_uri = try required(map, "DISCORD_REDIRECT_URI");
        try validateRedirectUri(public_url, redirect_uri);
        const admin_ids = try parseAdminIds(optional(map, "POOF_ADMIN_DISCORD_IDS") orelse "");
        if (environment == .production and admin_ids.len == 0) return error.AdminRequired;

        return .{
            .environment = environment,
            .company_name = company_name,
            .tagline = tagline,
            .public_url = public_url,
            .database_url = database_url,
            .discord_client_id = discord_client_id,
            .discord_client_secret = discord_client_secret,
            .discord_redirect_uri = redirect_uri,
            .admin_discord_ids = admin_ids,
            .csrf_key = try decodeKey(try required(map, "POOF_CSRF_KEY")),
            .api_token_pepper = try decodeKey(try required(map, "POOF_API_TOKEN_PEPPER")),
            .listen_port = try boundedUnsigned(
                optional(map, "POOF_LISTEN_PORT") orelse "8080",
                u16,
                1,
                65535,
            ),
            .workers = try boundedUnsigned(
                optional(map, "POOF_WORKERS") orelse "4",
                u8,
                1,
                64,
            ),
            .database_pool_size = try boundedUnsigned(
                optional(map, "POOF_DATABASE_POOL_SIZE") orelse "8",
                u8,
                1,
                64,
            ),
            .session_ttl_days = try boundedUnsigned(
                optional(map, "POOF_SESSION_TTL_DAYS") orelse "30",
                u16,
                1,
                365,
            ),
        };
    }
};

pub const Error = error{
    MissingEnvironmentVariable,
    InvalidEnvironment,
    InvalidText,
    InvalidPublicUrl,
    InvalidDatabaseUrl,
    InvalidDiscordClientId,
    InvalidDiscordClientSecret,
    InvalidDiscordRedirectUri,
    InvalidAdminId,
    TooManyAdmins,
    DuplicateAdminId,
    AdminRequired,
    InvalidSecretKey,
    InvalidNumber,
};

fn required(map: *const std.process.Environ.Map, key: []const u8) Error![]const u8 {
    const value = map.get(key) orelse return error.MissingEnvironmentVariable;
    if (value.len == 0) return error.MissingEnvironmentVariable;
    return value;
}

fn optional(map: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = map.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

fn parseEnvironment(value: []const u8) Error!Environment {
    if (std.mem.eql(u8, value, "development")) return .development;
    if (std.mem.eql(u8, value, "test")) return .testing;
    if (std.mem.eql(u8, value, "production")) return .production;
    return error.InvalidEnvironment;
}

fn text(value: []const u8, minimum: usize, maximum: usize) Error![]const u8 {
    if (!std.unicode.utf8ValidateSlice(value) or value.len < minimum or value.len > maximum) {
        return error.InvalidText;
    }
    for (value) |byte| {
        if (byte < 0x20 and byte != '\n' and byte != '\t') return error.InvalidText;
    }
    return value;
}

fn validatePublicUrl(value: []const u8, environment: Environment) Error!void {
    const uri = std.Uri.parse(value) catch return error.InvalidPublicUrl;
    if (uri.host == null or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null or
        (uri.path.percent_encoded.len != 0 and
            !std.mem.eql(u8, uri.path.percent_encoded, "/")))
    {
        return error.InvalidPublicUrl;
    }
    if (std.mem.endsWith(u8, value, "/")) return error.InvalidPublicUrl;
    if (environment == .production) {
        if (!std.mem.eql(u8, uri.scheme, "https")) return error.InvalidPublicUrl;
    } else if (!std.mem.eql(u8, uri.scheme, "https") and
        !(std.mem.eql(u8, uri.scheme, "http") and isLocalhost(uri.host.?.percent_encoded)))
    {
        return error.InvalidPublicUrl;
    }
}

fn validateDatabaseUrl(value: []const u8) Error!void {
    const uri = std.Uri.parse(value) catch return error.InvalidDatabaseUrl;
    if ((!std.mem.eql(u8, uri.scheme, "postgres") and
        !std.mem.eql(u8, uri.scheme, "postgresql")) or uri.host == null)
    {
        return error.InvalidDatabaseUrl;
    }
}

fn validateRedirectUri(public_url: []const u8, redirect_uri: []const u8) Error!void {
    if (!std.mem.startsWith(u8, redirect_uri, public_url)) {
        return error.InvalidDiscordRedirectUri;
    }
    const suffix = redirect_uri[public_url.len..];
    if (!std.mem.eql(u8, suffix, "/auth/discord/callback")) {
        return error.InvalidDiscordRedirectUri;
    }
}

fn parseAdminIds(value: []const u8) Error!AdminIds {
    var result = AdminIds{};
    var iterator = std.mem.splitScalar(u8, value, ',');
    while (iterator.next()) |raw| {
        const candidate = std.mem.trim(u8, raw, " \t");
        if (candidate.len == 0) continue;
        if (!isDiscordId(candidate)) return error.InvalidAdminId;
        if (result.len == result.values.len) return error.TooManyAdmins;
        if (result.contains(candidate)) return error.DuplicateAdminId;
        result.values[result.len] = candidate;
        result.len += 1;
    }
    return result;
}

fn isDiscordId(value: []const u8) bool {
    if (value.len < 17 or value.len > 20) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn decodeKey(value: []const u8) Error![32]u8 {
    if (value.len != 64) return error.InvalidSecretKey;
    var output: [32]u8 = undefined;
    for (&output, 0..) |*byte, index| {
        const high = hexNibble(value[index * 2]) orelse return error.InvalidSecretKey;
        const low = hexNibble(value[index * 2 + 1]) orelse return error.InvalidSecretKey;
        byte.* = high << 4 | low;
    }
    if (std.mem.allEqual(u8, &output, 0)) return error.InvalidSecretKey;
    return output;
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn boundedUnsigned(
    value: []const u8,
    comptime T: type,
    minimum: T,
    maximum: T,
) Error!T {
    const parsed = std.fmt.parseUnsigned(T, value, 10) catch return error.InvalidNumber;
    if (parsed < minimum or parsed > maximum) return error.InvalidNumber;
    return parsed;
}

fn isLocalhost(host: []const u8) bool {
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "[::1]");
}

fn validMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    try map.put("POOF_ENV", "production");
    try map.put("POOF_COMPANY_NAME", "Acme");
    try map.put("POOF_TAGLINE", "Shape what ships next.");
    try map.put("POOF_PUBLIC_URL", "https://feedback.example.com");
    try map.put("DATABASE_URL", "postgresql://poof:secret@localhost:5432/poof");
    try map.put("DISCORD_CLIENT_ID", "123456789012345678");
    try map.put("DISCORD_CLIENT_SECRET", "abcdefghijklmnopqrstuvwxyz0123456789");
    try map.put(
        "DISCORD_REDIRECT_URI",
        "https://feedback.example.com/auth/discord/callback",
    );
    try map.put("POOF_ADMIN_DISCORD_IDS", "123456789012345678");
    try map.put(
        "POOF_CSRF_KEY",
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
    );
    try map.put(
        "POOF_API_TOKEN_PEPPER",
        "f0e0d0c0b0a090807060504030201000112233445566778899aabbccddeeff00",
    );
    return map;
}

test "production configuration is strict and single-company" {
    var map = try validMap(std.testing.allocator);
    defer map.deinit();
    const config = try Config.fromMap(&map);
    try std.testing.expectEqual(Environment.production, config.environment);
    try std.testing.expectEqualStrings("Acme", config.company_name);
    try std.testing.expect(config.admin_discord_ids.contains("123456789012345678"));
    try std.testing.expectEqual(@as(u16, 8080), config.listen_port);
}

test "production requires HTTPS and at least one administrator" {
    var map = try validMap(std.testing.allocator);
    defer map.deinit();
    try map.put("POOF_PUBLIC_URL", "http://feedback.example.com");
    try std.testing.expectError(error.InvalidPublicUrl, Config.fromMap(&map));

    try map.put("POOF_PUBLIC_URL", "https://feedback.example.com");
    try map.put("POOF_ADMIN_DISCORD_IDS", "");
    try std.testing.expectError(error.AdminRequired, Config.fromMap(&map));
}

test "callback must be the exact local Discord endpoint" {
    var map = try validMap(std.testing.allocator);
    defer map.deinit();
    try map.put("DISCORD_REDIRECT_URI", "https://evil.example/callback");
    try std.testing.expectError(error.InvalidDiscordRedirectUri, Config.fromMap(&map));
}

test "secret keys reject zero and malformed values" {
    var map = try validMap(std.testing.allocator);
    defer map.deinit();
    try map.put(
        "POOF_CSRF_KEY",
        "0000000000000000000000000000000000000000000000000000000000000000",
    );
    try std.testing.expectError(error.InvalidSecretKey, Config.fromMap(&map));
}
