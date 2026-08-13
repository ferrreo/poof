const std = @import("std");
const pg = @import("pg");
const domain = @import("../domain.zig");
const models = @import("../store.zig");
const migrations = @import("migrations.zig");

pub const Postgres = struct {
    pool: *pg.Pool,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        database_url: []const u8,
        pool_size: u8,
    ) models.Error!Postgres {
        const uri = std.Uri.parse(database_url) catch return error.DatabaseUnavailable;
        const pool = pg.Pool.initUri(io, allocator, uri, .{
            .size = pool_size,
            .timeout = 5_000,
        }) catch return error.DatabaseUnavailable;
        return .{ .pool = pool };
    }

    pub fn deinit(self: *Postgres) void {
        self.pool.deinit();
    }

    pub fn migrate(self: *Postgres) models.Error!void {
        return migrations.apply(self.pool);
    }

    pub fn upsertDiscordUser(
        self: *Postgres,
        allocator: std.mem.Allocator,
        profile: models.DiscordProfile,
    ) models.Error!models.User {
        var row = (self.pool.row(
            \\INSERT INTO users (
            \\    discord_id, username, display_name, avatar_hash, role, last_login_at
            \\) VALUES ($1, $2, $3, $4, $5, now())
            \\ON CONFLICT (discord_id) DO UPDATE SET
            \\    username = EXCLUDED.username,
            \\    display_name = EXCLUDED.display_name,
            \\    avatar_hash = EXCLUDED.avatar_hash,
            \\    role = CASE
            \\        WHEN EXCLUDED.role = 'admin' THEN 'admin'
            \\        ELSE users.role
            \\    END,
            \\    last_login_at = now()
            \\RETURNING id, discord_id, username, display_name, avatar_hash, role,
            \\          disabled_at IS NOT NULL, created_at, last_login_at
        , .{
            profile.discord_id,
            profile.username,
            profile.display_name,
            profile.avatar_hash,
            @tagName(profile.role),
        }) catch return error.DatabaseUnavailable) orelse return error.InvalidDatabaseData;
        defer row.deinit() catch {};
        return readUser(&row, allocator);
    }

    pub fn listBoards(
        self: *Postgres,
        allocator: std.mem.Allocator,
        output: []models.Board,
        include_archived: bool,
    ) models.Error![]models.Board {
        var result = self.pool.query(
            \\SELECT id, slug, name, description, color, sort_order,
            \\       archived_at IS NOT NULL
            \\FROM boards
            \\WHERE $1 OR archived_at IS NULL
            \\ORDER BY sort_order, id
        , .{include_archived}) catch return error.DatabaseUnavailable;
        defer result.deinit();

        var used: usize = 0;
        while (result.next() catch return error.DatabaseUnavailable) |row| {
            if (used == output.len) return error.CapacityExceeded;
            output[used] = .{
                .id = row.get(i64, 0) catch return error.InvalidDatabaseData,
                .slug = try copyColumn(row, allocator, 1),
                .name = try copyColumn(row, allocator, 2),
                .description = try copyColumn(row, allocator, 3),
                .color = try copyColumn(row, allocator, 4),
                .sort_order = row.get(i32, 5) catch return error.InvalidDatabaseData,
                .archived = row.get(bool, 6) catch return error.InvalidDatabaseData,
            };
            used += 1;
        }
        return output[0..used];
    }

    pub fn createIssue(
        self: *Postgres,
        author_id: i64,
        input: domain.CreateIssue,
    ) models.Error!i64 {
        domain.validateCreateIssue(input) catch return error.Conflict;
        var slug_storage: [180]u8 = undefined;
        const slug = domain.slugify(input.title, &slug_storage) catch return error.Conflict;

        var connection = self.pool.acquire() catch return error.DatabaseUnavailable;
        defer connection.release();
        connection.begin() catch return error.DatabaseUnavailable;
        errdefer connection.tryRollback() catch {};

        var row = (connection.row(
            \\INSERT INTO issues (
            \\    slug, board_id, author_id, kind, title, body_markdown,
            \\    reproduction_steps, expected_behavior, actual_behavior,
            \\    environment, evidence_url
            \\) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
            \\RETURNING id
        , .{
            slug,
            input.board_id,
            author_id,
            @tagName(input.kind),
            input.title,
            input.body,
            input.reproduction_steps,
            input.expected_behavior,
            input.actual_behavior,
            input.environment,
            input.evidence_url,
        }) catch return error.DatabaseUnavailable) orelse return error.InvalidDatabaseData;
        const issue_id = row.get(i64, 0) catch return error.InvalidDatabaseData;
        row.deinit() catch return error.DatabaseUnavailable;

        _ = connection.exec(
            "INSERT INTO issue_votes (issue_id, user_id) VALUES ($1, $2)",
            .{ issue_id, author_id },
        ) catch return error.DatabaseUnavailable;
        _ = connection.exec(
            \\INSERT INTO issue_events (issue_id, actor_id, event_type)
            \\VALUES ($1, $2, 'created')
        , .{ issue_id, author_id }) catch return error.DatabaseUnavailable;

        connection.commit() catch return error.DatabaseUnavailable;
        return issue_id;
    }

    pub fn getIssue(
        self: *Postgres,
        allocator: std.mem.Allocator,
        issue_id: i64,
    ) models.Error!models.Issue {
        var row = (self.pool.row(issue_select ++ " WHERE i.id = $1", .{issue_id}) catch
            return error.DatabaseUnavailable) orelse return error.NotFound;
        defer row.deinit() catch {};
        return readIssue(&row, allocator);
    }

    pub fn listIssues(
        self: *Postgres,
        allocator: std.mem.Allocator,
        filter: models.IssueFilter,
        output: []models.IssueSummary,
    ) models.Error!models.ListResult {
        if (filter.limit == 0 or filter.limit > domain.page_size_max or
            filter.limit > output.len)
        {
            return error.CapacityExceeded;
        }
        const kind: ?[]const u8 = if (filter.kind) |value| @tagName(value) else null;
        const status: ?[]const u8 = if (filter.status) |value| @tagName(value) else null;
        const query = if (filter.query) |value|
            if (std.mem.trim(u8, value, " \t\r\n").len == 0) null else value
        else
            null;

        const arguments = .{
            filter.board_id,
            kind,
            status,
            query,
            @tagName(filter.sort),
            @as(i32, filter.limit),
            @as(i64, filter.offset),
        };
        var result = self.pool.query(issue_list_sql, arguments) catch
            return error.DatabaseUnavailable;
        defer result.deinit();

        var used: usize = 0;
        while (result.next() catch return error.DatabaseUnavailable) |row| {
            if (used == output.len) return error.CapacityExceeded;
            output[used] = try readIssueSummary(row, allocator);
            used += 1;
        }

        var count_row = (self.pool.row(issue_count_sql, .{
            filter.board_id,
            kind,
            status,
            query,
        }) catch return error.DatabaseUnavailable) orelse return error.InvalidDatabaseData;
        defer count_row.deinit() catch {};
        const total = count_row.get(i64, 0) catch return error.InvalidDatabaseData;
        return .{ .items = output[0..used], .total = total };
    }

    pub fn setVote(
        self: *Postgres,
        issue_id: i64,
        user_id: i64,
        selected: bool,
    ) models.Error!void {
        if (selected) {
            _ = self.pool.exec(
                \\INSERT INTO issue_votes (issue_id, user_id)
                \\VALUES ($1, $2)
                \\ON CONFLICT DO NOTHING
            , .{ issue_id, user_id }) catch return error.DatabaseUnavailable;
        } else {
            _ = self.pool.exec(
                "DELETE FROM issue_votes WHERE issue_id = $1 AND user_id = $2",
                .{ issue_id, user_id },
            ) catch return error.DatabaseUnavailable;
        }
    }

    pub fn addComment(
        self: *Postgres,
        issue_id: i64,
        author_id: i64,
        parent_id: ?i64,
        body: []const u8,
    ) models.Error!i64 {
        domain.validateComment(body) catch return error.Conflict;
        var row = (self.pool.row(
            \\INSERT INTO comments (issue_id, author_id, parent_id, body_markdown)
            \\SELECT $1, $2, $3, $4
            \\FROM issues
            \\WHERE id = $1 AND locked = false
            \\RETURNING id
        , .{ issue_id, author_id, parent_id, body }) catch
            return error.DatabaseUnavailable) orelse return error.Locked;
        defer row.deinit() catch {};
        return row.get(i64, 0) catch error.InvalidDatabaseData;
    }

    pub fn updateIssueStatus(
        self: *Postgres,
        issue_id: i64,
        actor_id: i64,
        status: domain.IssueStatus,
    ) models.Error!void {
        var connection = self.pool.acquire() catch return error.DatabaseUnavailable;
        defer connection.release();
        connection.begin() catch return error.DatabaseUnavailable;
        errdefer connection.tryRollback() catch {};

        var row = (connection.row(
            \\UPDATE issues SET
            \\    status = $2,
            \\    completed_at = CASE WHEN $2 = 'completed' THEN now() ELSE NULL END,
            \\    closed_at = CASE WHEN $2 = 'closed' THEN now() ELSE NULL END
            \\WHERE id = $1 AND status <> $2
            \\RETURNING status
        , .{ issue_id, @tagName(status) }) catch
            return error.DatabaseUnavailable) orelse return error.Conflict;
        const stored_status = row.get([]const u8, 0) catch return error.InvalidDatabaseData;
        if (!std.mem.eql(u8, stored_status, @tagName(status))) {
            return error.InvalidDatabaseData;
        }
        row.deinit() catch return error.DatabaseUnavailable;

        _ = connection.exec(
            \\INSERT INTO issue_events (
            \\    issue_id, actor_id, event_type, to_value
            \\) VALUES ($1, $2, 'status_changed', $3)
        , .{ issue_id, actor_id, @tagName(status) }) catch
            return error.DatabaseUnavailable;
        connection.commit() catch return error.DatabaseUnavailable;
    }
};

const issue_select =
    \\SELECT i.id, i.slug, i.board_id, b.name, i.author_id,
    \\       COALESCE(u.display_name, u.username), i.kind, i.status, i.priority,
    \\       i.title, i.body_markdown, i.reproduction_steps, i.expected_behavior,
    \\       i.actual_behavior, i.environment, i.evidence_url, i.duplicate_of_id,
    \\       i.pinned, i.locked,
    \\       (SELECT count(*) FROM issue_votes v WHERE v.issue_id = i.id),
    \\       (SELECT count(*) FROM comments c WHERE c.issue_id = i.id AND c.deleted_at IS NULL),
    \\       i.created_at, i.updated_at
    \\FROM issues i
    \\JOIN boards b ON b.id = i.board_id
    \\JOIN users u ON u.id = i.author_id
;

const issue_filter =
    \\ FROM issues i
    \\ JOIN boards b ON b.id = i.board_id
    \\ JOIN users u ON u.id = i.author_id
    \\ WHERE ($1::bigint IS NULL OR i.board_id = $1)
    \\   AND ($2::text IS NULL OR i.kind = $2)
    \\   AND ($3::text IS NULL OR i.status = $3)
    \\   AND (
    \\       $4::text IS NULL
    \\       OR to_tsvector('simple', i.title || ' ' || i.body_markdown)
    \\          @@ websearch_to_tsquery('simple', $4)
    \\   )
;

const issue_list_sql =
    \\SELECT i.id, i.slug, b.name, COALESCE(u.display_name, u.username),
    \\       i.kind, i.status, i.title, i.pinned,
    \\       (SELECT count(*) FROM issue_votes v WHERE v.issue_id = i.id),
    \\       (SELECT count(*) FROM comments c WHERE c.issue_id = i.id AND c.deleted_at IS NULL),
    \\       i.created_at
++ issue_filter ++
    \\ ORDER BY i.pinned DESC,
    \\   CASE WHEN $5 = 'top' THEN
    \\       (SELECT count(*) FROM issue_votes v WHERE v.issue_id = i.id)
    \\   END DESC,
    \\   i.created_at DESC, i.id DESC
    \\ LIMIT $6 OFFSET $7
;

const issue_count_sql = "SELECT count(*)" ++ issue_filter;

fn readUser(
    row: *pg.QueryRow,
    allocator: std.mem.Allocator,
) models.Error!models.User {
    return .{
        .id = row.get(i64, 0) catch return error.InvalidDatabaseData,
        .discord_id = try copyQueryColumn(row, allocator, 1),
        .username = try copyQueryColumn(row, allocator, 2),
        .display_name = try copyOptionalQueryColumn(row, allocator, 3),
        .avatar_hash = try copyOptionalQueryColumn(row, allocator, 4),
        .role = try models.parseRole(row.get([]const u8, 5) catch
            return error.InvalidDatabaseData),
        .disabled = row.get(bool, 6) catch return error.InvalidDatabaseData,
        .created_at_us = row.get(i64, 7) catch return error.InvalidDatabaseData,
        .last_login_at_us = row.get(i64, 8) catch return error.InvalidDatabaseData,
    };
}

fn readIssue(
    row: *pg.QueryRow,
    allocator: std.mem.Allocator,
) models.Error!models.Issue {
    return .{
        .id = row.get(i64, 0) catch return error.InvalidDatabaseData,
        .slug = try copyQueryColumn(row, allocator, 1),
        .board_id = row.get(i64, 2) catch return error.InvalidDatabaseData,
        .board_name = try copyQueryColumn(row, allocator, 3),
        .author_id = row.get(i64, 4) catch return error.InvalidDatabaseData,
        .author_name = try copyQueryColumn(row, allocator, 5),
        .kind = try models.parseKind(row.get([]const u8, 6) catch
            return error.InvalidDatabaseData),
        .status = try models.parseStatus(row.get([]const u8, 7) catch
            return error.InvalidDatabaseData),
        .priority = try models.parsePriority(row.get([]const u8, 8) catch
            return error.InvalidDatabaseData),
        .title = try copyQueryColumn(row, allocator, 9),
        .body_markdown = try copyQueryColumn(row, allocator, 10),
        .reproduction_steps = try copyOptionalQueryColumn(row, allocator, 11),
        .expected_behavior = try copyOptionalQueryColumn(row, allocator, 12),
        .actual_behavior = try copyOptionalQueryColumn(row, allocator, 13),
        .environment = try copyOptionalQueryColumn(row, allocator, 14),
        .evidence_url = try copyOptionalQueryColumn(row, allocator, 15),
        .duplicate_of_id = row.get(?i64, 16) catch return error.InvalidDatabaseData,
        .pinned = row.get(bool, 17) catch return error.InvalidDatabaseData,
        .locked = row.get(bool, 18) catch return error.InvalidDatabaseData,
        .vote_count = row.get(i64, 19) catch return error.InvalidDatabaseData,
        .comment_count = row.get(i64, 20) catch return error.InvalidDatabaseData,
        .created_at_us = row.get(i64, 21) catch return error.InvalidDatabaseData,
        .updated_at_us = row.get(i64, 22) catch return error.InvalidDatabaseData,
    };
}

fn readIssueSummary(
    row: pg.Row,
    allocator: std.mem.Allocator,
) models.Error!models.IssueSummary {
    return .{
        .id = row.get(i64, 0) catch return error.InvalidDatabaseData,
        .slug = try copyColumn(row, allocator, 1),
        .board_name = try copyColumn(row, allocator, 2),
        .author_name = try copyColumn(row, allocator, 3),
        .kind = try models.parseKind(row.get([]const u8, 4) catch
            return error.InvalidDatabaseData),
        .status = try models.parseStatus(row.get([]const u8, 5) catch
            return error.InvalidDatabaseData),
        .title = try copyColumn(row, allocator, 6),
        .pinned = row.get(bool, 7) catch return error.InvalidDatabaseData,
        .vote_count = row.get(i64, 8) catch return error.InvalidDatabaseData,
        .comment_count = row.get(i64, 9) catch return error.InvalidDatabaseData,
        .created_at_us = row.get(i64, 10) catch return error.InvalidDatabaseData,
    };
}

fn copyColumn(
    row: pg.Row,
    allocator: std.mem.Allocator,
    index: usize,
) models.Error![]const u8 {
    const value = row.get([]const u8, index) catch return error.InvalidDatabaseData;
    return allocator.dupe(u8, value) catch error.CapacityExceeded;
}

fn copyQueryColumn(
    row: *pg.QueryRow,
    allocator: std.mem.Allocator,
    index: usize,
) models.Error![]const u8 {
    const value = row.get([]const u8, index) catch return error.InvalidDatabaseData;
    return allocator.dupe(u8, value) catch error.CapacityExceeded;
}

fn copyOptionalQueryColumn(
    row: *pg.QueryRow,
    allocator: std.mem.Allocator,
    index: usize,
) models.Error!?[]const u8 {
    const value = row.get(?[]const u8, index) catch return error.InvalidDatabaseData;
    return if (value) |bytes|
        allocator.dupe(u8, bytes) catch error.CapacityExceeded
    else
        null;
}
