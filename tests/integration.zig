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
    try std.testing.expect(try database.allowUserAction(
        member.id,
        "vote_change",
        2,
        60,
    ));
    try std.testing.expect(try database.allowUserAction(
        member.id,
        "vote_change",
        2,
        60,
    ));
    try std.testing.expect(!try database.allowUserAction(
        member.id,
        "vote_change",
        2,
        60,
    ));

    const pepper = [_]u8{0x77} ** 32;
    var generated_token = poof.api_token.Generated.fromRaw(
        [_]u8{0x41} ** poof.api_token.lookup_random_bytes,
        [_]u8{0x52} ** poof.api_token.secret_random_bytes,
        pepper,
    );
    defer generated_token.clear();
    var scopes = poof.domain.ScopeSet{};
    scopes.insert(.read);
    scopes.insert(.issues_write);
    scopes.insert(.admin_issues);
    const stored_token = try database.createApiToken(
        arena,
        admin.id,
        &generated_token.lookup,
        generated_token.digest,
        "Integration agent",
        scopes,
        30,
    );
    try std.testing.expectEqualStrings("Integration agent", stored_token.label);
    var token_storage: [8]poof.store.ApiToken = undefined;
    const tokens = try database.listApiTokens(arena, admin.id, &token_storage);
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    const parsed_token = try poof.api_token.parse(generated_token.slice(), pepper);
    const api_principal = try database.apiPrincipal(
        arena,
        &parsed_token.lookup,
        parsed_token.digest,
    );
    try std.testing.expectEqual(admin.id, api_principal.owner.id);
    try std.testing.expect(api_principal.token.scopes.contains(.admin_issues));
    const claim_digest = [_]u8{0x91} ** 32;
    const first_claim = try database.claimIdempotency(
        arena,
        stored_token.id,
        "poof_set_vote",
        "concurrent-claim",
        claim_digest,
    );
    try std.testing.expect(first_claim == .acquired);
    const pending_claim = try database.claimIdempotency(
        arena,
        stored_token.id,
        "poof_set_vote",
        "concurrent-claim",
        claim_digest,
    );
    try std.testing.expect(pending_claim == .pending);
    try std.testing.expectError(
        error.Conflict,
        database.claimIdempotency(
            arena,
            stored_token.id,
            "poof_set_vote",
            "concurrent-claim",
            [_]u8{0x92} ** 32,
        ),
    );
    database.releaseIdempotency(
        stored_token.id,
        "poof_set_vote",
        "concurrent-claim",
        claim_digest,
    );
    try database.revokeApiToken(admin.id, stored_token.id);
    try std.testing.expectError(
        error.NotFound,
        database.apiPrincipal(arena, &parsed_token.lookup, parsed_token.digest),
    );

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
    var comment_storage: [8]poof.store.Comment = undefined;
    const comments = try database.listComments(
        arena,
        issue_id,
        &comment_storage,
    );
    try std.testing.expectEqual(@as(usize, 1), comments.len);
    try std.testing.expectEqualStrings(
        "This would also make upgrades safer.",
        comments[0].body_markdown,
    );

    try database.adminUpdateIssue(issue_id, admin.id, .{
        .status = .completed,
        .priority = .high,
        .board_id = boards[0].id,
        .pinned = true,
        .locked = true,
    });
    const completed = try database.getIssue(arena, issue_id);
    try std.testing.expectEqual(poof.domain.IssueStatus.completed, completed.status);
    try std.testing.expectEqual(poof.domain.Priority.high, completed.priority);
    try std.testing.expect(completed.pinned);
    try std.testing.expect(completed.locked);
    try std.testing.expectEqual(@as(i64, 2), completed.vote_count);
    try std.testing.expectEqual(@as(i64, 1), completed.comment_count);
    try database.editIssueContent(issue_id, admin.id, .{
        .title = "Portable JSON exports for self-hosters",
        .body_markdown = "Self-hosters can now download a complete JSON backup of public feedback.",
    });
    const edited = try database.getIssue(arena, issue_id);
    try std.testing.expectEqualStrings(
        "portable-json-exports-for-self-hosters",
        edited.slug,
    );
    const duplicate_target = try database.createIssue(member.id, .{
        .board_id = boards[0].id,
        .kind = .improvement,
        .title = "Export feedback as portable JSON",
        .body = "This request intentionally overlaps the completed export feature.",
    });
    try database.adminUpdateIssue(issue_id, admin.id, .{
        .status = .completed,
        .priority = .high,
        .board_id = boards[0].id,
        .pinned = true,
        .locked = true,
        .duplicate_of_id = duplicate_target,
    });
    try std.testing.expectError(
        error.Conflict,
        database.adminUpdateIssue(duplicate_target, admin.id, .{
            .status = .pending,
            .priority = .none,
            .board_id = boards[0].id,
            .pinned = false,
            .locked = false,
            .duplicate_of_id = issue_id,
        }),
    );

    var issue_storage: [10]poof.store.IssueSummary = undefined;
    const listed = try database.listIssues(arena, .{
        .status = .completed,
        .query = "portable JSON",
        .limit = 10,
    }, &issue_storage);
    try std.testing.expectEqual(@as(i64, 1), listed.total);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqual(issue_id, listed.items[0].id);

    const board_id = try database.createBoard(
        "Integrations",
        "integrations",
        "Requests for connected tools.",
        "blue",
    );
    try database.updateBoard(
        board_id,
        "Connected tools",
        "connected-tools",
        "Requests for connected tools.",
        "green",
        5,
    );
    try database.archiveBoard(board_id);
    try std.testing.expectError(
        error.Conflict,
        database.createIssue(member.id, .{
            .board_id = board_id,
            .kind = .feature,
            .title = "This board is archived",
            .body = "Archived boards must reject newly submitted feedback.",
        }),
    );

    const changelog_id = try database.createChangelogWithIssues(admin.id, .{
        .slug = "portable-exports",
        .title = "Portable exports are here",
        .summary = "Download a complete copy of your feedback.",
        .body_markdown = "Use the new **Export** action to download JSON.",
        .version = "0.1.0",
        .tags = &.{"new-feature"},
    }, &.{issue_id});
    var changelog_storage: [8]poof.store.Changelog = undefined;
    const drafts = try database.listChangelogs(
        arena,
        false,
        &changelog_storage,
    );
    try std.testing.expectEqual(@as(usize, 1), drafts.len);
    try std.testing.expect(drafts[0].published_at_us == null);
    try database.updateChangelogWithIssues(changelog_id, .{
        .slug = "portable-json-exports",
        .title = "Portable JSON exports are here",
        .summary = "Download a complete copy of feedback.",
        .body_markdown = "Use the new **Export** action to download a complete JSON backup.",
        .version = "0.1.0",
        .tags = &.{"new-feature"},
    }, &.{issue_id});
    try database.publishChangelog(changelog_id, true);
    const published = try database.getChangelogBySlug(
        arena,
        "portable-json-exports",
        true,
    );
    try std.testing.expectEqualStrings("0.1.0", published.version.?);
    try std.testing.expect(published.published_at_us != null);
    var linked_storage: [8]poof.store.IssueSummary = undefined;
    const linked = try database.listChangelogIssues(
        arena,
        changelog_id,
        &linked_storage,
    );
    try std.testing.expectEqual(@as(usize, 1), linked.len);
    try std.testing.expectEqual(issue_id, linked[0].id);
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
        "Portable JSON exports for self-hosters",
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
        "/issues/1/portable-json-exports-for-self-hosters",
        canonical.header("location").?,
    );

    const new_issue = try client.get("/issues/new");
    try std.testing.expectEqual(@as(u16, 303), new_issue.status);
    try std.testing.expectEqualStrings(
        "/auth/discord?return_to=/issues/new",
        new_issue.header("location").?,
    );

    const admin = try database.upsertDiscordUser(std.testing.allocator, .{
        .discord_id = "123456789012345678",
        .username = "fer",
        .display_name = "Fer",
        .avatar_hash = null,
        .role = .admin,
    });
    defer {
        std.testing.allocator.free(admin.discord_id);
        std.testing.allocator.free(admin.username);
        if (admin.display_name) |value| std.testing.allocator.free(value);
    }
    var generated = poof.api_token.Generated.fromRaw(
        [_]u8{0x61} ** poof.api_token.lookup_random_bytes,
        [_]u8{0x62} ** poof.api_token.secret_random_bytes,
        settings.api_token_pepper,
    );
    defer generated.clear();
    var scopes = poof.domain.ScopeSet{};
    scopes.insert(.read);
    scopes.insert(.issues_write);
    scopes.insert(.admin_issues);
    const mcp_token = try database.createApiToken(
        std.testing.allocator,
        admin.id,
        &generated.lookup,
        generated.digest,
        "MCP route test",
        scopes,
        30,
    );
    defer {
        std.testing.allocator.free(mcp_token.lookup_prefix);
        std.testing.allocator.free(mcp_token.label);
    }
    var authorization_storage: [128]u8 = undefined;
    const authorization = try std.fmt.bufPrint(
        &authorization_storage,
        "Bearer {s}",
        .{generated.slice()},
    );
    const mcp_headers = [_]ploof_testing.Request.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "authorization", .value = authorization },
        .{ .name = "mcp-protocol-version", .value = "2025-06-18" },
    };
    const public_mcp_headers = [_]ploof_testing.Request.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "application/json" },
    };
    const unauthenticated = try client.request(.{
        .method = "POST",
        .target = "/mcp",
        .headers = &public_mcp_headers,
        .body =
        \\{"jsonrpc":"2.0","id":0,"method":"ping","params":{}}
        ,
    });
    try std.testing.expectEqual(@as(u16, 401), unauthenticated.status);
    const initialize = try client.request(.{
        .method = "POST",
        .target = "/mcp",
        .headers = &mcp_headers,
        .body =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
        ,
    });
    try std.testing.expectEqual(@as(u16, 200), initialize.status);
    try std.testing.expect(std.mem.indexOf(u8, initialize.body, "\"name\":\"poof\"") != null);

    const list_tools = try client.request(.{
        .method = "POST",
        .target = "/mcp",
        .headers = &mcp_headers,
        .body =
        \\{"jsonrpc":"2.0","id":"tools","method":"tools/list","params":{}}
        ,
    });
    try std.testing.expectEqual(@as(u16, 200), list_tools.status);
    try std.testing.expect(std.mem.indexOf(u8, list_tools.body, "poof_list_issues") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_tools.body, "poof_update_issue") != null);

    const call_tools = try client.request(.{
        .method = "POST",
        .target = "/mcp",
        .headers = &mcp_headers,
        .body =
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"poof_list_issues","arguments":{"limit":5}}}
        ,
    });
    try std.testing.expectEqual(@as(u16, 200), call_tools.status);
    try std.testing.expect(std.mem.indexOf(
        u8,
        call_tools.body,
        "Portable JSON exports for self-hosters",
    ) != null);

    const vote = try client.request(.{
        .method = "POST",
        .target = "/mcp",
        .headers = &mcp_headers,
        .body =
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"poof_set_vote","arguments":{"idempotency_key":"vote-retry-001","issue_id":1,"selected":true}}}
        ,
    });
    try std.testing.expectEqual(@as(u16, 200), vote.status);
    const replay = try client.request(.{
        .method = "POST",
        .target = "/mcp",
        .headers = &mcp_headers,
        .body =
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"poof_set_vote","arguments":{"idempotency_key":"vote-retry-001","issue_id":1,"selected":true}}}
        ,
    });
    try std.testing.expectEqual(@as(u16, 200), replay.status);
    try std.testing.expect(std.mem.indexOf(u8, replay.body, "Vote added") != null);
    const conflict = try client.request(.{
        .method = "POST",
        .target = "/mcp",
        .headers = &mcp_headers,
        .body =
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"poof_set_vote","arguments":{"idempotency_key":"vote-retry-001","issue_id":1,"selected":false}}}
        ,
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        conflict.body,
        "Idempotency key reused",
    ) != null);

    const query_token = try client.request(.{
        .method = "POST",
        .target = "/mcp?access_token=forbidden",
        .headers = &mcp_headers,
        .body =
        \\{"jsonrpc":"2.0","id":8,"method":"ping","params":{}}
        ,
    });
    try std.testing.expectEqual(@as(u16, 403), query_token.status);

    _ = try database.pool.exec(
        "UPDATE users SET role = 'member' WHERE id = $1",
        .{admin.id},
    );
    const demoted = try client.request(.{
        .method = "POST",
        .target = "/mcp",
        .headers = &mcp_headers,
        .body =
        \\{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{}}
        ,
    });
    try std.testing.expectEqual(@as(u16, 200), demoted.status);
    try std.testing.expect(std.mem.indexOf(u8, demoted.body, "poof_list_issues") != null);
    try std.testing.expect(std.mem.indexOf(u8, demoted.body, "poof_update_issue") == null);
    var automation_storage: [50]poof.store.AutomationEvent = undefined;
    const automation_events = try database.listAutomationEvents(
        std.testing.allocator,
        admin.id,
        &automation_storage,
    );
    defer for (automation_events) |event| {
        std.testing.allocator.free(event.method);
        if (event.tool_name) |value| std.testing.allocator.free(value);
        std.testing.allocator.free(event.outcome);
        std.testing.allocator.free(event.summary);
    };
    try std.testing.expect(automation_events.len >= 4);

    try database.revokeApiToken(admin.id, mcp_token.id);
    const revoked = try client.request(.{
        .method = "POST",
        .target = "/mcp",
        .headers = &mcp_headers,
        .body =
        \\{"jsonrpc":"2.0","id":4,"method":"ping","params":{}}
        ,
    });
    try std.testing.expectEqual(@as(u16, 401), revoked.status);
    try std.testing.expect(revoked.header("www-authenticate") != null);
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
