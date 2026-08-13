const std = @import("std");
const poof = @import("poof");
const ploof_testing = @import("ploof_testing");
const options = @import("integration_options");

test "PostgreSQL migrations and feedback lifecycle" {
    var database = try poof.postgres.Postgres.init(
        std.testing.io,
        std.testing.allocator,
        options.database_url,
        3,
    );
    defer database.deinit();

    _ = try database.pool.exec(
        "DROP SCHEMA public CASCADE; CREATE SCHEMA public",
        .{},
    );
    try database.migrate();
    try database.migrate();

    var migration_count = (try database.pool.row(
        "SELECT count(*) FROM schema_migrations",
        .{},
    )).?;
    defer migration_count.deinit() catch {};
    try std.testing.expectEqual(
        @as(i64, @intCast(poof.store_migrations.count())),
        try migration_count.get(i64, 0),
    );

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const admin = try database.upsertDiscordUser(arena, .{
        .discord_id = "123456789012345678",
        .username = "fer",
        .display_name = "Fer",
        .avatar_hash = null,
        .role = .admin,
    });
    try std.testing.expectEqual(poof.domain.Role.admin, admin.role);
    try std.testing.expect(!admin.disabled);

    const member = try database.upsertDiscordUser(arena, .{
        .discord_id = "223456789012345678",
        .username = "member",
        .display_name = null,
        .avatar_hash = "avatar_hash",
        .role = .member,
    });
    try std.testing.expectEqual(poof.domain.Role.member, member.role);

    var oauth_pair = poof.oauth_state.Pair.fromRaw(
        [_]u8{0x11} ** 32,
        [_]u8{0x22} ** 32,
    );
    defer oauth_pair.clear();
    try database.createOAuthState(
        oauth_pair.state.hash(),
        oauth_pair.cookie.hash(),
        "/issues/new",
    );
    const oauth = try database.consumeOAuthState(
        arena,
        oauth_pair.state.hash(),
        oauth_pair.cookie.hash(),
    );
    try std.testing.expectEqualStrings("/issues/new", oauth.return_to);
    try std.testing.expectError(
        error.NotFound,
        database.consumeOAuthState(
            arena,
            oauth_pair.state.hash(),
            oauth_pair.cookie.hash(),
        ),
    );

    var session_token = poof.session.Token.fromRaw([_]u8{0x33} ** 32);
    defer session_token.clear();
    try database.createSession(session_token.hash(), admin.id, 30);
    const principal = try database.sessionPrincipal(arena, session_token.hash());
    try std.testing.expectEqual(admin.id, principal.user.id);
    try std.testing.expectEqual(poof.domain.Role.admin, principal.user.role);
    try database.revokeSession(session_token.hash());
    try std.testing.expectError(
        error.NotFound,
        database.sessionPrincipal(arena, session_token.hash()),
    );

    var board_storage: [8]poof.store.Board = undefined;
    const boards = try database.listBoards(arena, &board_storage, false);
    try std.testing.expectEqual(@as(usize, 1), boards.len);
    try std.testing.expectEqualStrings("general", boards[0].slug);

    const issue_id = try database.createIssue(member.id, .{
        .board_id = boards[0].id,
        .kind = .feature,
        .title = "Add a portable JSON export",
        .body = "Self-hosters need a simple way to back up all public feedback.",
    });
    const issue = try database.getIssue(arena, issue_id);
    try std.testing.expectEqualStrings("add-a-portable-json-export", issue.slug);
    try std.testing.expectEqual(@as(i64, 1), issue.vote_count);
    try std.testing.expectEqual(poof.domain.IssueStatus.pending, issue.status);

    try database.setVote(issue_id, admin.id, true);
    try database.setVote(issue_id, admin.id, true);
    const comment_id = try database.addComment(
        issue_id,
        admin.id,
        null,
        "This would also make upgrades safer.",
    );
    try std.testing.expect(comment_id > 0);

    try database.updateIssueStatus(issue_id, admin.id, .completed);
    const completed = try database.getIssue(arena, issue_id);
    try std.testing.expectEqual(poof.domain.IssueStatus.completed, completed.status);
    try std.testing.expectEqual(@as(i64, 2), completed.vote_count);
    try std.testing.expectEqual(@as(i64, 1), completed.comment_count);

    var issue_storage: [10]poof.store.IssueSummary = undefined;
    const listed = try database.listIssues(arena, .{
        .status = .completed,
        .query = "portable export",
        .limit = 10,
    }, &issue_storage);
    try std.testing.expectEqual(@as(i64, 1), listed.total);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqual(issue_id, listed.items[0].id);
}

test "Ploof public routes render persisted feedback" {
    var database = try poof.postgres.Postgres.init(
        std.testing.io,
        std.testing.allocator,
        options.database_url,
        3,
    );
    defer database.deinit();
    try database.migrate();

    var environment = try webEnvironment(std.testing.allocator);
    defer environment.deinit();
    const settings = try poof.config.Config.fromMap(&environment);
    var state = try poof.State.init(
        &settings,
        &database,
        std.testing.io,
        std.testing.allocator,
    );

    const Client = ploof_testing.ConfiguredClient(poof.WebTestApp, .{
        .request_bytes_max = 64 * 1024,
        .response_bytes_max = 512 * 1024,
        .response_capture_bytes_max = 512 * 1024,
    });
    var storage: Client.Storage = .{};
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch {};

    const home = try client.get("/");
    try std.testing.expectEqual(@as(u16, 200), home.status);
    try std.testing.expect(std.mem.indexOf(
        u8,
        home.body,
        "Add a portable JSON export",
    ) != null);
    try std.testing.expectEqualStrings(
        "nosniff",
        home.header("x-content-type-options").?,
    );

    const roadmap = try client.get("/roadmap");
    try std.testing.expectEqual(@as(u16, 200), roadmap.status);
    try std.testing.expect(std.mem.indexOf(u8, roadmap.body, "Recently completed") != null);

    const canonical = try client.get("/issues/1");
    try std.testing.expectEqual(@as(u16, 301), canonical.status);
    try std.testing.expectEqualStrings(
        "/issues/1/add-a-portable-json-export",
        canonical.header("location").?,
    );

    const new_issue = try client.get("/issues/new");
    try std.testing.expectEqual(@as(u16, 303), new_issue.status);
    try std.testing.expectEqualStrings(
        "/auth/discord?return_to=/issues/new",
        new_issue.header("location").?,
    );
}

fn webEnvironment(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    try map.put("POOF_ENV", "test");
    try map.put("POOF_COMPANY_NAME", "Poof");
    try map.put("POOF_TAGLINE", "Shape what ships next.");
    try map.put("POOF_PUBLIC_URL", "http://ploof.test");
    try map.put("DATABASE_URL", options.database_url);
    try map.put("DISCORD_CLIENT_ID", "123456789012345678");
    try map.put("DISCORD_CLIENT_SECRET", "abcdefghijklmnopqrstuvwxyz0123456789");
    try map.put(
        "DISCORD_REDIRECT_URI",
        "http://ploof.test/auth/discord/callback",
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
