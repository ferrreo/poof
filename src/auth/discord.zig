const std = @import("std");

pub const authorize_endpoint = "https://discord.com/oauth2/authorize";
pub const token_endpoint = "https://discord.com/api/oauth2/token";
pub const user_endpoint = "https://discord.com/api/v10/users/@me";

pub const Profile = struct {
    id: []const u8,
    username: []const u8,
    global_name: ?[]const u8,
    avatar: ?[]const u8,
};

pub const TokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: u32,

    pub fn clear(self: *TokenResponse) void {
        std.crypto.secureZero(u8, @constCast(self.access_token));
    }
};

pub const Error = error{
    NoSpaceLeft,
    InvalidJson,
    InvalidResponse,
    InvalidProfile,
    OutOfMemory,
};

pub fn authorizationUrl(
    output: []u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    state: []const u8,
) Error![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    writer.print("{s}?response_type=code&client_id=", .{authorize_endpoint}) catch
        return error.NoSpaceLeft;
    try percentEncode(&writer, client_id);
    writer.writeAll("&scope=identify&redirect_uri=") catch return error.NoSpaceLeft;
    try percentEncode(&writer, redirect_uri);
    writer.writeAll("&state=") catch return error.NoSpaceLeft;
    try percentEncode(&writer, state);
    return output[0..writer.end];
}

pub fn tokenRequestBody(
    output: []u8,
    client_id: []const u8,
    client_secret: []const u8,
    code: []const u8,
    redirect_uri: []const u8,
) Error![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    writer.writeAll("grant_type=authorization_code&client_id=") catch
        return error.NoSpaceLeft;
    try percentEncode(&writer, client_id);
    writer.writeAll("&client_secret=") catch return error.NoSpaceLeft;
    try percentEncode(&writer, client_secret);
    writer.writeAll("&code=") catch return error.NoSpaceLeft;
    try percentEncode(&writer, code);
    writer.writeAll("&redirect_uri=") catch return error.NoSpaceLeft;
    try percentEncode(&writer, redirect_uri);
    return output[0..writer.end];
}

pub fn parseTokenResponse(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!TokenResponse {
    const Wire = struct {
        access_token: []const u8,
        token_type: []const u8,
        expires_in: u32,
    };
    const parsed = std.json.parseFromSlice(Wire, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;
    defer parsed.deinit();
    if (parsed.value.access_token.len < 16 or
        !std.ascii.eqlIgnoreCase(parsed.value.token_type, "Bearer") or
        parsed.value.expires_in == 0)
    {
        return error.InvalidResponse;
    }
    const token = allocator.dupe(u8, parsed.value.access_token) catch
        return error.OutOfMemory;
    errdefer allocator.free(token);
    const token_type = allocator.dupe(u8, parsed.value.token_type) catch
        return error.OutOfMemory;
    return .{
        .access_token = token,
        .token_type = token_type,
        .expires_in = parsed.value.expires_in,
    };
}

pub fn parseProfile(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!Profile {
    const Wire = struct {
        id: []const u8,
        username: []const u8,
        global_name: ?[]const u8 = null,
        avatar: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(Wire, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;
    defer parsed.deinit();
    const value = parsed.value;
    if (!validSnowflake(value.id) or !validText(value.username, 1, 80) or
        (value.global_name != null and !validText(value.global_name.?, 1, 80)) or
        (value.avatar != null and !validAvatar(value.avatar.?)))
    {
        return error.InvalidProfile;
    }
    return .{
        .id = allocator.dupe(u8, value.id) catch return error.OutOfMemory,
        .username = allocator.dupe(u8, value.username) catch return error.OutOfMemory,
        .global_name = if (value.global_name) |name|
            allocator.dupe(u8, name) catch return error.OutOfMemory
        else
            null,
        .avatar = if (value.avatar) |avatar|
            allocator.dupe(u8, avatar) catch return error.OutOfMemory
        else
            null,
    };
}

fn percentEncode(writer: *std.Io.Writer, value: []const u8) Error!void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or
            byte == '_' or byte == '~')
        {
            writer.writeByte(byte) catch return error.NoSpaceLeft;
        } else {
            writer.writeByte('%') catch return error.NoSpaceLeft;
            writer.writeByte(hex[byte >> 4]) catch return error.NoSpaceLeft;
            writer.writeByte(hex[byte & 0x0f]) catch return error.NoSpaceLeft;
        }
    }
}

fn validSnowflake(value: []const u8) bool {
    if (value.len < 17 or value.len > 20) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn validText(value: []const u8, minimum: usize, maximum: usize) bool {
    if (value.len < minimum or value.len > maximum or
        !std.unicode.utf8ValidateSlice(value))
    {
        return false;
    }
    for (value) |byte| {
        if (byte < 0x20) return false;
    }
    return true;
}

fn validAvatar(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

test "Discord authorization URL is encoded and least privilege" {
    var output: [512]u8 = undefined;
    const url = try authorizationUrl(
        &output,
        "123456789012345678",
        "https://feedback.example.com/auth/discord/callback",
        "abc_-123",
    );
    try std.testing.expect(std.mem.indexOf(u8, url, "scope=identify") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        url,
        "redirect_uri=https%3A%2F%2Ffeedback.example.com%2Fauth%2Fdiscord%2Fcallback",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "email") == null);
}

test "Discord profile parser rejects malformed identities" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const profile = try parseProfile(
        arena_state.allocator(),
        "{\"id\":\"123456789012345678\",\"username\":\"fer\",\"global_name\":\"Fer\",\"avatar\":null}",
    );
    try std.testing.expectEqualStrings("Fer", profile.global_name.?);
    try std.testing.expectError(
        error.InvalidProfile,
        parseProfile(
            arena_state.allocator(),
            "{\"id\":\"not-a-snowflake\",\"username\":\"fer\"}",
        ),
    );
}

test "Discord token parser ignores refresh tokens and validates bearer type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const token = try parseTokenResponse(
        arena_state.allocator(),
        "{\"access_token\":\"a_secure_access_token_value\",\"token_type\":\"Bearer\",\"expires_in\":604800,\"refresh_token\":\"discard-me\"}",
    );
    try std.testing.expectEqualStrings("a_secure_access_token_value", token.access_token);
    try std.testing.expectError(
        error.InvalidResponse,
        parseTokenResponse(
            arena_state.allocator(),
            "{\"access_token\":\"a_secure_access_token_value\",\"token_type\":\"Basic\",\"expires_in\":1}",
        ),
    );
}
