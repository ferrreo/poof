const std = @import("std");
const ploof = @import("ploof");
const app_state = @import("../../app_state.zig");
const cookie = @import("../../auth/cookie.zig");
const discord = @import("../../auth/discord.zig");
const oauth_state = @import("../../auth/oauth_state.zig");
const session = @import("../../auth/session.zig");
const domain = @import("../../domain.zig");
const request = @import("../request.zig");

const StartQuery = struct {
    return_to: []const u8 = "/",
};

pub const StartDefinition = ploof.Endpoint(.{
    .query = ploof.Query.typed(StartQuery, .{
        .segments_max = 2,
        .unknown_fields = .reject,
    }),
});

const CallbackQuery = struct {
    code: ?[]const u8 = null,
    state: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

pub const CallbackDefinition = ploof.Endpoint(.{
    .query = ploof.Query.typed(CallbackQuery, .{
        .segments_max = 4,
        .unknown_fields = .ignore,
    }),
});

pub const LogoutDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(struct {}, .{
        .encoded_wire_bytes_max = 512,
        .decoded_bytes_max = 512,
        .segments_max = 2,
        .unknown_fields = .reject,
    }),
});

pub fn start(
    context: *app_state.Context,
    input: StartDefinition.InputType,
) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return context.empty(.service_unavailable);
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    const io = context.state.io orelse return context.empty(.service_unavailable);
    const return_to = if (oauth_state.validReturnTarget(input.query.return_to))
        input.query.return_to
    else
        "/";

    var pair = oauth_state.Pair.generate(io);
    defer pair.clear();
    database.createOAuthState(
        pair.state.hash(),
        pair.cookie.hash(),
        return_to,
    ) catch return context.empty(.service_unavailable);

    var location_storage: [1024]u8 = undefined;
    const location = discord.authorizationUrl(
        &location_storage,
        settings.discord_client_id,
        settings.discord_redirect_uri,
        pair.state.slice(),
    ) catch return context.empty(.internal_server_error);
    var cookie_storage: [256]u8 = undefined;
    const cookie_header = cookie.write(
        &cookie_storage,
        oauthCookieName(app_state.isProduction(context)),
        pair.cookie.slice(),
        .{
            .secure = app_state.isProduction(context),
            .same_site = .lax,
            .max_age_seconds = 600,
        },
    ) catch return context.empty(.internal_server_error);

    var response = request.redirect(context, .temporary_redirect, location);
    response.appendHeader("set-cookie", cookie_header) catch
        return context.empty(.internal_server_error);
    response.setHeaderStatic("cache-control", "no-store") catch {};
    return response;
}

pub fn callback(
    context: *app_state.Context,
    input: CallbackDefinition.InputType,
) app_state.Context.ResponseType {
    if (input.query.@"error" != null) {
        return context.textStatic(.unauthorized, "Discord authorization was cancelled.");
    }
    const code = input.query.code orelse return context.empty(.bad_request);
    const encoded_state = input.query.state orelse return context.empty(.bad_request);
    const settings = app_state.config(context) orelse
        return context.empty(.service_unavailable);
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    const io = context.state.io orelse return context.empty(.service_unavailable);
    const allocator = context.state.allocator orelse
        return context.empty(.service_unavailable);

    const encoded_cookie = oauthCookie(context) orelse return context.empty(.unauthorized);
    var state_token = session.Token.parse(encoded_state) catch
        return context.empty(.unauthorized);
    defer state_token.clear();
    var cookie_token = session.Token.parse(encoded_cookie) catch
        return context.empty(.unauthorized);
    defer cookie_token.clear();

    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const grant = database.consumeOAuthState(
        workspace.allocator(),
        state_token.hash(),
        cookie_token.hash(),
    ) catch return context.empty(.unauthorized);

    var token_body: [2048]u8 = undefined;
    defer std.crypto.secureZero(u8, &token_body);
    const payload = discord.tokenRequestBody(
        &token_body,
        settings.discord_client_id,
        settings.discord_client_secret,
        code,
        settings.discord_redirect_uri,
    ) catch return context.empty(.bad_request);
    var token_response_storage: [64 * 1024]u8 = undefined;
    const token_json = fetch(
        io,
        allocator,
        discord.token_endpoint,
        .POST,
        payload,
        &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }},
        &token_response_storage,
    ) catch return context.empty(.bad_gateway);
    var oauth_token = discord.parseTokenResponse(workspace.allocator(), token_json) catch
        return context.empty(.bad_gateway);
    defer oauth_token.clear();

    var authorization_storage: [512]u8 = undefined;
    defer std.crypto.secureZero(u8, &authorization_storage);
    const authorization = std.fmt.bufPrint(
        &authorization_storage,
        "Bearer {s}",
        .{oauth_token.access_token},
    ) catch return context.empty(.internal_server_error);
    var profile_storage: [64 * 1024]u8 = undefined;
    const profile_json = fetch(
        io,
        allocator,
        discord.user_endpoint,
        .GET,
        null,
        &.{.{ .name = "authorization", .value = authorization }},
        &profile_storage,
    ) catch return context.empty(.bad_gateway);
    const profile = discord.parseProfile(workspace.allocator(), profile_json) catch
        return context.empty(.bad_gateway);
    const role: domain.Role = if (settings.admin_discord_ids.contains(profile.id))
        .admin
    else
        .member;
    const user = database.upsertDiscordUser(workspace.allocator(), .{
        .discord_id = profile.id,
        .username = profile.username,
        .display_name = profile.global_name,
        .avatar_hash = profile.avatar,
        .role = role,
    }) catch return context.empty(.service_unavailable);

    var session_token = session.Token.generate(io);
    defer session_token.clear();
    database.createSession(
        session_token.hash(),
        user.id,
        settings.session_ttl_days,
    ) catch return context.empty(.service_unavailable);

    var session_cookie_storage: [256]u8 = undefined;
    const session_cookie = session.writeCookie(
        &session_cookie_storage,
        &session_token,
        app_state.isProduction(context),
        settings.session_ttl_days,
    ) catch return context.empty(.internal_server_error);
    var oauth_cookie_storage: [256]u8 = undefined;
    const cleared_oauth = cookie.write(
        &oauth_cookie_storage,
        oauthCookieName(app_state.isProduction(context)),
        "",
        .{
            .secure = app_state.isProduction(context),
            .max_age_seconds = 0,
        },
    ) catch return context.empty(.internal_server_error);

    var response = request.redirect(context, .see_other, grant.return_to);
    response.appendHeader("set-cookie", session_cookie) catch
        return context.empty(.internal_server_error);
    response.appendHeader("set-cookie", cleared_oauth) catch
        return context.empty(.internal_server_error);
    response.setHeaderStatic("cache-control", "no-store") catch {};
    database.cleanupExpiredAuth() catch {};
    return response;
}

pub fn logout(
    context: *app_state.Context,
    _: LogoutDefinition.InputType,
) app_state.Context.ResponseType {
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    if (sessionCookie(context)) |encoded| {
        var token = session.Token.parse(encoded) catch null;
        if (token) |*valid| {
            database.revokeSession(valid.hash()) catch {};
            valid.clear();
        }
    }
    var clear_storage: [256]u8 = undefined;
    const clear_header = session.clearCookie(
        &clear_storage,
        app_state.isProduction(context),
    ) catch return context.empty(.internal_server_error);
    var response = request.redirect(context, .see_other, "/");
    response.appendHeader("set-cookie", clear_header) catch
        return context.empty(.internal_server_error);
    response.setHeaderStatic("cache-control", "no-store") catch {};
    return response;
}

fn fetch(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    method: std.http.Method,
    payload: ?[]const u8,
    headers: []const std.http.Header,
    output: []u8,
) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    var writer = std.Io.Writer.fixed(output);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .extra_headers = headers,
        .response_writer = &writer,
        .redirect_behavior = .unhandled,
    });
    if (result.status != .ok) return error.UnexpectedStatus;
    return output[0..writer.end];
}

fn oauthCookie(context: *app_state.Context) ?[]const u8 {
    return selectedCookie(context, oauthCookieName(app_state.isProduction(context)));
}

fn sessionCookie(context: *app_state.Context) ?[]const u8 {
    return selectedCookie(context, session.cookieName(app_state.isProduction(context)));
}

fn selectedCookie(context: *app_state.Context, name: []const u8) ?[]const u8 {
    var values: [8][]const u8 = undefined;
    var count: usize = 0;
    var iterator = context.request.headers.all("cookie").iterator();
    while (iterator.next()) |value| {
        if (count == values.len) return null;
        values[count] = value;
        count += 1;
    }
    return cookie.find(values[0..count], name) catch null;
}

fn oauthCookieName(production: bool) []const u8 {
    return if (production) "__Host-poof-oauth" else "poof_oauth";
}
