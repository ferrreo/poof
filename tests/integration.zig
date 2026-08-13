const std = @import("std");
const poof = @import("poof");
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
