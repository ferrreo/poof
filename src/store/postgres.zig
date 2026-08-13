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

    pub fn createOAuthState(
        self: *Postgres,
        state_hash: [32]u8,
        cookie_hash: [32]u8,
        return_to: []const u8,
    ) models.Error!void {
        _ = self.pool.exec(
            \\INSERT INTO oauth_states (
            \\    state_hash, cookie_hash, return_to, expires_at
            \\) VALUES ($1, $2, $3, now() + interval '10 minutes')
        , .{
            pg.Binary{ .data = &state_hash },
            pg.Binary{ .data = &cookie_hash },
            return_to,
        }) catch return error.DatabaseUnavailable;
    }

    pub fn consumeOAuthState(
        self: *Postgres,
        allocator: std.mem.Allocator,
        state_hash: [32]u8,
        cookie_hash: [32]u8,
    ) models.Error!models.OAuthState {
        var row = (self.pool.row(
            \\UPDATE oauth_states SET consumed_at = now()
            \\WHERE state_hash = $1
            \\  AND cookie_hash = $2
            \\  AND consumed_at IS NULL
            \\  AND expires_at > now()
            \\RETURNING return_to
        , .{
            pg.Binary{ .data = &state_hash },
            pg.Binary{ .data = &cookie_hash },
        }) catch return error.DatabaseUnavailable) orelse return error.NotFound;
        defer row.deinit() catch {};
        return .{ .return_to = try copyQueryColumn(&row, allocator, 0) };
    }

    pub fn createSession(
        self: *Postgres,
        token_hash: [32]u8,
        user_id: i64,
        ttl_days: u16,
    ) models.Error!void {
        _ = self.pool.exec(
            \\INSERT INTO sessions (token_hash, user_id, expires_at)
            \\VALUES ($1, $2, now() + make_interval(days => $3))
        , .{
            pg.Binary{ .data = &token_hash },
            user_id,
            @as(i32, ttl_days),
        }) catch return error.DatabaseUnavailable;
    }

    pub fn sessionPrincipal(
        self: *Postgres,
        allocator: std.mem.Allocator,
        token_hash: [32]u8,
    ) models.Error!models.SessionPrincipal {
        var row = (self.pool.row(
            \\WITH active_session AS (
            \\    UPDATE sessions SET last_seen_at = now()
            \\    WHERE token_hash = $1
            \\      AND revoked_at IS NULL
            \\      AND expires_at > now()
            \\    RETURNING id, user_id
            \\)
            \\SELECT s.id, u.id, u.discord_id, u.username, u.display_name,
            \\       u.avatar_hash, u.role, u.disabled_at IS NOT NULL,
            \\       u.created_at, u.last_login_at
            \\FROM active_session s
            \\JOIN users u ON u.id = s.user_id
            \\WHERE u.disabled_at IS NULL
        , .{pg.Binary{ .data = &token_hash }}) catch
            return error.DatabaseUnavailable) orelse return error.NotFound;
        defer row.deinit() catch {};
        const session_bytes = row.get([]u8, 0) catch return error.InvalidDatabaseData;
        if (session_bytes.len != 16) return error.InvalidDatabaseData;
        return .{
            .session_id = session_bytes[0..16].*,
            .user = try readUserOffset(&row, allocator, 1),
        };
    }

    pub fn revokeSession(
        self: *Postgres,
        token_hash: [32]u8,
    ) models.Error!void {
        _ = self.pool.exec(
            \\UPDATE sessions SET revoked_at = now()
            \\WHERE token_hash = $1 AND revoked_at IS NULL
        , .{pg.Binary{ .data = &token_hash }}) catch return error.DatabaseUnavailable;
    }

    pub fn cleanupExpiredAuth(self: *Postgres) models.Error!void {
        _ = self.pool.exec(
            \\DELETE FROM oauth_states WHERE expires_at < now() - interval '1 day';
            \\DELETE FROM sessions
            \\WHERE expires_at < now() - interval '7 days' OR revoked_at < now() - interval '7 days';
            \\DELETE FROM idempotency_keys
            \\WHERE expires_at < now() AND response_body IS NOT NULL;
            \\DELETE FROM user_rate_buckets
            \\WHERE bucket_start < extract(epoch FROM now())::bigint - 172800;
            \\DELETE FROM api_rate_buckets
            \\WHERE bucket_start < extract(epoch FROM now())::bigint - 172800
        , .{}) catch return error.DatabaseUnavailable;
    }

    pub fn createApiToken(
        self: *Postgres,
        allocator: std.mem.Allocator,
        owner_id: i64,
        lookup_prefix: []const u8,
        digest: [32]u8,
        label: []const u8,
        scopes: domain.ScopeSet,
        expires_days: ?u16,
    ) models.Error!models.ApiToken {
        if (label.len == 0 or label.len > 80 or scopes.bits == 0 or scopes.bits > 63) {
            return error.Conflict;
        }
        const expiry: ?i32 = if (expires_days) |days| @intCast(days) else null;
        var connection = self.pool.acquire() catch return error.DatabaseUnavailable;
        defer connection.release();
        connection.begin() catch return error.DatabaseUnavailable;
        errdefer connection.tryRollback() catch {};
        _ = connection.exec(
            "SELECT pg_advisory_xact_lock(5790053260621242964)",
            .{},
        ) catch return error.DatabaseUnavailable;
        var row = (connection.row(
            \\INSERT INTO api_tokens (
            \\    owner_id, lookup_prefix, token_digest, label, scopes, expires_at
            \\)
            \\SELECT
            \\    $1, $2, $3, $4, $5,
            \\    CASE WHEN $6::integer IS NULL
            \\         THEN NULL
            \\         ELSE now() + make_interval(days => $6)
            \\    END
            \\WHERE (
            \\    SELECT count(*) FROM api_tokens
            \\    WHERE owner_id = $1 AND revoked_at IS NULL
            \\      AND (expires_at IS NULL OR expires_at > now())
            \\) < 10
            \\RETURNING id, lookup_prefix, label, scopes, expires_at,
            \\          revoked_at IS NOT NULL, last_used_at, created_at
        , .{
            owner_id,
            lookup_prefix,
            pg.Binary{ .data = &digest },
            label,
            @as(i64, @intCast(scopes.bits)),
            expiry,
        }) catch return error.DatabaseUnavailable) orelse return error.Conflict;
        const token = try readApiTokenQuery(&row, allocator, 0);
        row.deinit() catch return error.DatabaseUnavailable;
        connection.commit() catch return error.DatabaseUnavailable;
        return token;
    }

    pub fn listApiTokens(
        self: *Postgres,
        allocator: std.mem.Allocator,
        owner_id: i64,
        output: []models.ApiToken,
    ) models.Error![]models.ApiToken {
        var result = self.pool.query(
            \\SELECT id, lookup_prefix, label, scopes, expires_at,
            \\       revoked_at IS NOT NULL, last_used_at, created_at
            \\FROM api_tokens
            \\WHERE owner_id = $1
            \\ORDER BY (revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())) DESC,
            \\         created_at DESC
            \\LIMIT 100
        , .{owner_id}) catch return error.DatabaseUnavailable;
        defer result.deinit();
        var used: usize = 0;
        while (result.next() catch return error.DatabaseUnavailable) |row| {
            if (used == output.len) return error.CapacityExceeded;
            output[used] = try readApiToken(row, allocator);
            used += 1;
        }
        return output[0..used];
    }

    pub fn revokeApiToken(
        self: *Postgres,
        owner_id: i64,
        token_id: [16]u8,
    ) models.Error!void {
        const affected = self.pool.exec(
            \\UPDATE api_tokens SET revoked_at = now()
            \\WHERE id = $1 AND owner_id = $2 AND revoked_at IS NULL
        , .{ pg.Binary{ .data = &token_id }, owner_id }) catch
            return error.DatabaseUnavailable;
        if ((affected orelse 0) != 1) return error.NotFound;
    }

    pub fn apiPrincipal(
        self: *Postgres,
        allocator: std.mem.Allocator,
        lookup_prefix: []const u8,
        presented_digest: [32]u8,
    ) models.Error!models.ApiPrincipal {
        var row = (self.pool.row(
            \\SELECT t.id, t.lookup_prefix, t.token_digest, t.label, t.scopes,
            \\       t.expires_at, t.revoked_at IS NOT NULL, t.last_used_at,
            \\       t.created_at,
            \\       u.id, u.discord_id, u.username, u.display_name,
            \\       u.avatar_hash, u.role, u.disabled_at IS NOT NULL,
            \\       u.created_at, u.last_login_at
            \\FROM api_tokens t
            \\JOIN users u ON u.id = t.owner_id
            \\WHERE t.lookup_prefix = $1
            \\  AND t.revoked_at IS NULL
            \\  AND (t.expires_at IS NULL OR t.expires_at > now())
            \\  AND u.disabled_at IS NULL
        , .{lookup_prefix}) catch return error.DatabaseUnavailable) orelse return error.NotFound;
        defer row.deinit() catch {};
        const stored_digest = row.get([]u8, 2) catch return error.InvalidDatabaseData;
        if (stored_digest.len != 32 or !std.crypto.timing_safe.eql(
            [32]u8,
            stored_digest[0..32].*,
            presented_digest,
        )) return error.NotFound;

        const id_bytes = row.get([]u8, 0) catch return error.InvalidDatabaseData;
        if (id_bytes.len != 16) return error.InvalidDatabaseData;
        const scopes_value = row.get(i64, 4) catch return error.InvalidDatabaseData;
        if (scopes_value <= 0 or scopes_value > 63) return error.InvalidDatabaseData;
        const token = models.ApiToken{
            .id = id_bytes[0..16].*,
            .lookup_prefix = try copyQueryColumn(&row, allocator, 1),
            .label = try copyQueryColumn(&row, allocator, 3),
            .scopes = .{ .bits = @intCast(scopes_value) },
            .expires_at_us = row.get(?i64, 5) catch return error.InvalidDatabaseData,
            .revoked = row.get(bool, 6) catch return error.InvalidDatabaseData,
            .last_used_at_us = row.get(?i64, 7) catch return error.InvalidDatabaseData,
            .created_at_us = row.get(i64, 8) catch return error.InvalidDatabaseData,
        };
        const owner = try readUserOffset(&row, allocator, 9);
        _ = self.pool.exec(
            "UPDATE api_tokens SET last_used_at = now() WHERE id = $1",
            .{pg.Binary{ .data = &token.id }},
        ) catch {};
        return .{ .token = token, .owner = owner };
    }

    pub fn recordAutomation(
        self: *Postgres,
        token_id: [16]u8,
        owner_id: i64,
        method: []const u8,
        tool_name: ?[]const u8,
        outcome: []const u8,
        summary: []const u8,
    ) void {
        _ = self.pool.exec(
            \\INSERT INTO automation_events (
            \\    token_id, owner_id, method, tool_name, outcome, summary
            \\) VALUES ($1, $2, $3, $4, $5, $6)
        , .{
            pg.Binary{ .data = &token_id },
            owner_id,
            method,
            tool_name,
            outcome,
            summary,
        }) catch {};
    }

    pub fn listAutomationEvents(
        self: *Postgres,
        allocator: std.mem.Allocator,
        owner_id: i64,
        output: []models.AutomationEvent,
    ) models.Error![]models.AutomationEvent {
        var result = self.pool.query(
            \\SELECT method, tool_name, outcome, summary, created_at
            \\FROM automation_events
            \\WHERE owner_id = $1
            \\ORDER BY created_at DESC, id DESC
            \\LIMIT 50
        , .{owner_id}) catch return error.DatabaseUnavailable;
        defer result.deinit();
        var used: usize = 0;
        while (result.next() catch return error.DatabaseUnavailable) |row| {
            if (used == output.len) return error.CapacityExceeded;
            output[used] = .{
                .method = try copyColumn(row, allocator, 0),
                .tool_name = try copyOptionalColumn(row, allocator, 1),
                .outcome = try copyColumn(row, allocator, 2),
                .summary = try copyColumn(row, allocator, 3),
                .created_at_us = row.get(i64, 4) catch return error.InvalidDatabaseData,
            };
            used += 1;
        }
        return output[0..used];
    }

    pub fn apiRateAllowed(
        self: *Postgres,
        token_id: [16]u8,
        limit: i64,
    ) models.Error!bool {
        var row = (self.pool.row(
            \\INSERT INTO api_rate_buckets (
            \\    token_id, bucket_start, request_count
            \\) VALUES (
            \\    $1, floor(extract(epoch FROM now()) / 60)::bigint * 60, 1
            \\)
            \\ON CONFLICT (token_id, bucket_start) DO UPDATE
            \\SET request_count = api_rate_buckets.request_count + 1
            \\RETURNING request_count <= $2
        , .{ pg.Binary{ .data = &token_id }, @as(i32, @intCast(limit)) }) catch
            return error.DatabaseUnavailable) orelse return error.InvalidDatabaseData;
        defer row.deinit() catch {};
        return row.get(bool, 0) catch error.InvalidDatabaseData;
    }

    pub fn allowUserAction(
        self: *Postgres,
        user_id: i64,
        action: []const u8,
        limit: i32,
        window_seconds: i32,
    ) models.Error!bool {
        var row = (self.pool.row(
            \\INSERT INTO user_rate_buckets (
            \\    user_id, action, bucket_start, request_count
            \\) VALUES (
            \\    $1, $2,
            \\    floor(extract(epoch FROM now()) / $4::numeric)::bigint * $4::bigint,
            \\    1
            \\)
            \\ON CONFLICT (user_id, action, bucket_start) DO UPDATE
            \\SET request_count = user_rate_buckets.request_count + 1
            \\RETURNING request_count <= $3
        , .{
            user_id,
            action,
            limit,
            window_seconds,
        }) catch
            return error.DatabaseUnavailable) orelse return error.InvalidDatabaseData;
        defer row.deinit() catch {};
        return row.get(bool, 0) catch error.InvalidDatabaseData;
    }

    pub fn claimIdempotency(
        self: *Postgres,
        allocator: std.mem.Allocator,
        token_id: [16]u8,
        tool_name: []const u8,
        request_key: []const u8,
        request_digest: [32]u8,
    ) models.Error!models.IdempotencyClaim {
        var row = (self.pool.row(
            \\WITH inserted AS (
            \\    INSERT INTO idempotency_keys (
            \\        token_id, tool_name, request_key, request_digest,
            \\        response_body, expires_at
            \\    ) VALUES (
            \\        $1, $2, $3, $4, NULL, now() + interval '5 minutes'
            \\    )
            \\    ON CONFLICT (token_id, tool_name, request_key) DO NOTHING
            \\    RETURNING request_digest, response_body, true AS acquired,
            \\              false AS stale
            \\), selected AS (
            \\    SELECT request_digest, response_body, false AS acquired,
            \\           expires_at <= now() AS stale
            \\    FROM idempotency_keys
            \\    WHERE token_id = $1 AND tool_name = $2 AND request_key = $3
            \\)
            \\SELECT request_digest, response_body::text, acquired, stale FROM inserted
            \\UNION ALL
            \\SELECT request_digest, response_body::text, acquired, stale FROM selected
            \\LIMIT 1
        , .{
            pg.Binary{ .data = &token_id },
            tool_name,
            request_key,
            pg.Binary{ .data = &request_digest },
        }) catch return error.DatabaseUnavailable) orelse return error.DatabaseUnavailable;
        defer row.deinit() catch {};
        const stored_digest = row.get([]u8, 0) catch return error.InvalidDatabaseData;
        if (stored_digest.len != 32 or !std.crypto.timing_safe.eql(
            [32]u8,
            stored_digest[0..32].*,
            request_digest,
        )) return error.Conflict;
        const acquired = row.get(bool, 2) catch return error.InvalidDatabaseData;
        if (acquired) return .acquired;
        const response = row.get(?[]const u8, 1) catch return error.InvalidDatabaseData;
        if (response) |json| {
            return .{ .replay = allocator.dupe(u8, json) catch return error.CapacityExceeded };
        }
        const stale = row.get(bool, 3) catch return error.InvalidDatabaseData;
        return if (stale)
            .unknown
        else
            .pending;
    }

    pub fn saveIdempotency(
        self: *Postgres,
        token_id: [16]u8,
        tool_name: []const u8,
        request_key: []const u8,
        request_digest: [32]u8,
        response_json: []const u8,
    ) models.Error!void {
        const affected = self.pool.exec(
            \\UPDATE idempotency_keys SET
            \\    response_body = $5::jsonb,
            \\    expires_at = now() + interval '24 hours'
            \\WHERE token_id = $1 AND tool_name = $2 AND request_key = $3
            \\  AND request_digest = $4 AND response_body IS NULL
        , .{
            pg.Binary{ .data = &token_id },
            tool_name,
            request_key,
            pg.Binary{ .data = &request_digest },
            response_json,
        }) catch return error.DatabaseUnavailable;
        if ((affected orelse 0) != 1) return error.Conflict;
    }

    pub fn releaseIdempotency(
        self: *Postgres,
        token_id: [16]u8,
        tool_name: []const u8,
        request_key: []const u8,
        request_digest: [32]u8,
    ) void {
        _ = self.pool.exec(
            \\DELETE FROM idempotency_keys
            \\WHERE token_id = $1 AND tool_name = $2 AND request_key = $3
            \\  AND request_digest = $4 AND response_body IS NULL
        , .{
            pg.Binary{ .data = &token_id },
            tool_name,
            request_key,
            pg.Binary{ .data = &request_digest },
        }) catch {};
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
            \\LIMIT $2
        , .{ include_archived, @as(i32, @intCast(output.len)) }) catch
            return error.DatabaseUnavailable;
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
            \\)
            \\SELECT $1, b.id, $3, $4, $5, $6, $7, $8, $9, $10, $11
            \\FROM boards b
            \\WHERE b.id = $2 AND b.archived_at IS NULL
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
        }) catch return error.DatabaseUnavailable) orelse return error.Conflict;
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
            if (filter.completed_since_days) |days| @as(?i32, @intCast(days)) else null,
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
            if (filter.completed_since_days) |days| @as(?i32, @intCast(days)) else null,
        }) catch return error.DatabaseUnavailable) orelse return error.InvalidDatabaseData;
        defer count_row.deinit() catch {};
        const total = count_row.get(i64, 0) catch return error.InvalidDatabaseData;
        return .{ .items = output[0..used], .total = total };
    }

    pub fn listUserIssues(
        self: *Postgres,
        allocator: std.mem.Allocator,
        user_id: i64,
        output: []models.IssueSummary,
    ) models.Error![]models.IssueSummary {
        var result = self.pool.query(
            \\SELECT DISTINCT i.id, i.slug, b.name, i.board_id,
            \\       COALESCE(u.display_name, u.username),
            \\       i.kind, i.status, i.priority, i.title, i.pinned, i.locked,
            \\       i.duplicate_of_id,
            \\       (SELECT count(*) FROM issue_votes v WHERE v.issue_id = i.id),
            \\       (SELECT count(*) FROM comments c WHERE c.issue_id = i.id AND c.deleted_at IS NULL),
            \\       i.created_at
            \\FROM issues i
            \\JOIN boards b ON b.id = i.board_id
            \\JOIN users u ON u.id = i.author_id
            \\LEFT JOIN issue_votes own_vote
            \\       ON own_vote.issue_id = i.id AND own_vote.user_id = $1
            \\WHERE i.author_id = $1 OR own_vote.user_id = $1
            \\ORDER BY i.created_at DESC, i.id DESC
            \\LIMIT 100
        , .{user_id}) catch return error.DatabaseUnavailable;
        defer result.deinit();
        var used: usize = 0;
        while (result.next() catch return error.DatabaseUnavailable) |row| {
            if (used == output.len) return error.CapacityExceeded;
            output[used] = try readIssueSummary(row, allocator);
            used += 1;
        }
        return output[0..used];
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

    pub fn hasVote(
        self: *Postgres,
        issue_id: i64,
        user_id: i64,
    ) models.Error!bool {
        var row = (self.pool.row(
            \\SELECT EXISTS (
            \\    SELECT 1 FROM issue_votes WHERE issue_id = $1 AND user_id = $2
            \\)
        , .{ issue_id, user_id }) catch
            return error.DatabaseUnavailable) orelse return error.InvalidDatabaseData;
        defer row.deinit() catch {};
        return row.get(bool, 0) catch error.InvalidDatabaseData;
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

    pub fn listComments(
        self: *Postgres,
        allocator: std.mem.Allocator,
        issue_id: i64,
        output: []models.Comment,
    ) models.Error![]models.Comment {
        return self.listCommentsPage(allocator, issue_id, 0, output);
    }

    pub fn listCommentsPage(
        self: *Postgres,
        allocator: std.mem.Allocator,
        issue_id: i64,
        offset: u32,
        output: []models.Comment,
    ) models.Error![]models.Comment {
        var result = self.pool.query(
            \\SELECT c.id, c.issue_id, c.author_id,
            \\       COALESCE(u.display_name, u.username), c.parent_id,
            \\       c.body_markdown, c.created_at
            \\FROM comments c
            \\JOIN users u ON u.id = c.author_id
            \\WHERE c.issue_id = $1 AND c.deleted_at IS NULL
            \\ORDER BY c.created_at, c.id
            \\LIMIT $2
            \\OFFSET $3
        , .{
            issue_id,
            @as(i32, @intCast(output.len)),
            @as(i64, offset),
        }) catch
            return error.DatabaseUnavailable;
        defer result.deinit();
        var used: usize = 0;
        while (result.next() catch return error.DatabaseUnavailable) |row| {
            if (used == output.len) return error.CapacityExceeded;
            output[used] = .{
                .id = row.get(i64, 0) catch return error.InvalidDatabaseData,
                .issue_id = row.get(i64, 1) catch return error.InvalidDatabaseData,
                .author_id = row.get(i64, 2) catch return error.InvalidDatabaseData,
                .author_name = try copyColumn(row, allocator, 3),
                .parent_id = row.get(?i64, 4) catch return error.InvalidDatabaseData,
                .body_markdown = try copyColumn(row, allocator, 5),
                .created_at_us = row.get(i64, 6) catch return error.InvalidDatabaseData,
            };
            used += 1;
        }
        return output[0..used];
    }

    pub fn adminUpdateIssue(
        self: *Postgres,
        issue_id: i64,
        actor_id: i64,
        update: models.AdminIssueUpdate,
    ) models.Error!void {
        if (update.board_id <= 0 or update.duplicate_of_id == issue_id) return error.Conflict;
        var connection = self.pool.acquire() catch return error.DatabaseUnavailable;
        defer connection.release();
        connection.begin() catch return error.DatabaseUnavailable;
        errdefer connection.tryRollback() catch {};
        _ = connection.exec(
            "SELECT pg_advisory_xact_lock(5790053260621242963)",
            .{},
        ) catch return error.DatabaseUnavailable;

        var previous = (connection.row(
            \\SELECT status, priority, board_id, pinned, locked, duplicate_of_id
            \\FROM issues WHERE id = $1 FOR UPDATE
        , .{issue_id}) catch return error.DatabaseUnavailable) orelse return error.NotFound;
        const old_status = previous.get([]const u8, 0) catch return error.InvalidDatabaseData;
        const old_priority = previous.get([]const u8, 1) catch return error.InvalidDatabaseData;
        const old_board = previous.get(i64, 2) catch return error.InvalidDatabaseData;
        const old_pinned = previous.get(bool, 3) catch return error.InvalidDatabaseData;
        const old_locked = previous.get(bool, 4) catch return error.InvalidDatabaseData;
        const old_duplicate = previous.get(?i64, 5) catch return error.InvalidDatabaseData;
        var old_status_copy: [16]u8 = undefined;
        var old_priority_copy: [16]u8 = undefined;
        if (old_status.len > old_status_copy.len or old_priority.len > old_priority_copy.len) {
            return error.InvalidDatabaseData;
        }
        @memcpy(old_status_copy[0..old_status.len], old_status);
        @memcpy(old_priority_copy[0..old_priority.len], old_priority);
        previous.deinit() catch return error.DatabaseUnavailable;

        if (update.duplicate_of_id) |target_id| {
            var cycle_row = (connection.row(
                \\WITH RECURSIVE chain AS (
                \\    SELECT id, duplicate_of_id FROM issues WHERE id = $2
                \\    UNION
                \\    SELECT i.id, i.duplicate_of_id
                \\    FROM issues i
                \\    JOIN chain c ON i.id = c.duplicate_of_id
                \\)
                \\SELECT
                \\    EXISTS (SELECT 1 FROM issues WHERE id = $2),
                \\    EXISTS (SELECT 1 FROM chain WHERE id = $1)
            , .{ issue_id, target_id }) catch
                return error.DatabaseUnavailable) orelse return error.InvalidDatabaseData;
            const target_exists = cycle_row.get(bool, 0) catch
                return error.InvalidDatabaseData;
            const creates_cycle = cycle_row.get(bool, 1) catch
                return error.InvalidDatabaseData;
            cycle_row.deinit() catch return error.DatabaseUnavailable;
            if (!target_exists or creates_cycle) return error.Conflict;
        }

        const affected = connection.exec(
            \\UPDATE issues SET
            \\    status = $2, priority = $3, board_id = $4,
            \\    pinned = $5, locked = $6, duplicate_of_id = $7,
            \\    completed_at = CASE
            \\        WHEN $2 = 'completed' THEN COALESCE(completed_at, now())
            \\        ELSE NULL
            \\    END,
            \\    closed_at = CASE
            \\        WHEN $2 = 'closed' THEN COALESCE(closed_at, now())
            \\        ELSE NULL
            \\    END
            \\WHERE id = $1
        , .{
            issue_id,
            @tagName(update.status),
            @tagName(update.priority),
            update.board_id,
            update.pinned,
            update.locked,
            update.duplicate_of_id,
        }) catch return error.DatabaseUnavailable;
        if ((affected orelse 0) != 1) return error.NotFound;

        if (!std.mem.eql(u8, old_status_copy[0..old_status.len], @tagName(update.status))) {
            try insertEvent(
                connection,
                issue_id,
                actor_id,
                "status_changed",
                old_status_copy[0..old_status.len],
                @tagName(update.status),
            );
        }
        if (!std.mem.eql(u8, old_priority_copy[0..old_priority.len], @tagName(update.priority))) {
            try insertEvent(
                connection,
                issue_id,
                actor_id,
                "priority_changed",
                old_priority_copy[0..old_priority.len],
                @tagName(update.priority),
            );
        }
        if (old_board != update.board_id) {
            try insertIntegerEvent(
                connection,
                issue_id,
                actor_id,
                "board_changed",
                old_board,
                update.board_id,
            );
        }
        if (old_pinned != update.pinned) {
            try insertEvent(
                connection,
                issue_id,
                actor_id,
                if (update.pinned) "pinned" else "unpinned",
                null,
                null,
            );
        }
        if (old_locked != update.locked) {
            try insertEvent(
                connection,
                issue_id,
                actor_id,
                if (update.locked) "locked" else "unlocked",
                null,
                null,
            );
        }
        if (old_duplicate != update.duplicate_of_id) {
            try insertEvent(
                connection,
                issue_id,
                actor_id,
                if (update.duplicate_of_id == null)
                    "duplicate_cleared"
                else
                    "duplicate_marked",
                null,
                null,
            );
        }
        connection.commit() catch return error.DatabaseUnavailable;
    }

    pub fn editIssueContent(
        self: *Postgres,
        issue_id: i64,
        actor_id: i64,
        update: models.IssueContentUpdate,
    ) models.Error!void {
        if (std.mem.trim(u8, update.title, " \t\r\n").len < 5 or
            update.title.len > domain.title_bytes_max or
            std.mem.trim(u8, update.body_markdown, " \t\r\n").len < 20 or
            update.body_markdown.len > domain.issue_body_bytes_max)
        {
            return error.Conflict;
        }
        inline for (.{
            update.reproduction_steps,
            update.expected_behavior,
            update.actual_behavior,
            update.environment,
        }) |value| if (value) |text| {
            if (text.len == 0 or text.len > domain.diagnostic_bytes_max) return error.Conflict;
        };
        if (update.evidence_url) |url| {
            if (url.len > domain.evidence_url_bytes_max or
                (!std.mem.startsWith(u8, url, "https://") and
                    !std.mem.startsWith(u8, url, "http://")))
            {
                return error.Conflict;
            }
        }

        var slug_storage: [180]u8 = undefined;
        const slug = domain.slugify(update.title, &slug_storage) catch return error.Conflict;
        var connection = self.pool.acquire() catch return error.DatabaseUnavailable;
        defer connection.release();
        connection.begin() catch return error.DatabaseUnavailable;
        errdefer connection.tryRollback() catch {};
        const affected = connection.exec(
            \\UPDATE issues SET
            \\    slug = $2, title = $3, body_markdown = $4,
            \\    reproduction_steps = $5, expected_behavior = $6,
            \\    actual_behavior = $7, environment = $8, evidence_url = $9
            \\WHERE id = $1
            \\  AND (
            \\      kind <> 'bug'
            \\      OR (
            \\          $5::text IS NOT NULL AND char_length(btrim($5)) >= 10
            \\          AND $7::text IS NOT NULL AND char_length(btrim($7)) >= 10
            \\      )
            \\  )
        , .{
            issue_id,
            slug,
            update.title,
            update.body_markdown,
            update.reproduction_steps,
            update.expected_behavior,
            update.actual_behavior,
            update.environment,
            update.evidence_url,
        }) catch return error.DatabaseUnavailable;
        if ((affected orelse 0) != 1) return error.Conflict;
        try insertEvent(connection, issue_id, actor_id, "edited", null, null);
        connection.commit() catch return error.DatabaseUnavailable;
    }

    pub fn createBoard(
        self: *Postgres,
        name: []const u8,
        slug: []const u8,
        description: []const u8,
        color: []const u8,
    ) models.Error!i64 {
        if (!validBoard(name, slug, description, color)) return error.Conflict;
        var connection = self.pool.acquire() catch return error.DatabaseUnavailable;
        defer connection.release();
        connection.begin() catch return error.DatabaseUnavailable;
        errdefer connection.tryRollback() catch {};
        _ = connection.exec(
            "SELECT pg_advisory_xact_lock(5790053260621242962)",
            .{},
        ) catch return error.DatabaseUnavailable;
        var row = (connection.row(
            \\INSERT INTO boards (name, slug, description, color, sort_order)
            \\SELECT
            \\    $1, $2, $3, $4,
            \\    COALESCE((SELECT max(sort_order) + 1 FROM boards), 0)
            \\WHERE (SELECT count(*) FROM boards) < 32
            \\RETURNING id
        , .{ name, slug, description, color }) catch
            return error.DatabaseUnavailable) orelse return error.Conflict;
        const board_id = row.get(i64, 0) catch return error.InvalidDatabaseData;
        row.deinit() catch return error.DatabaseUnavailable;
        connection.commit() catch return error.DatabaseUnavailable;
        return board_id;
    }

    pub fn archiveBoard(self: *Postgres, board_id: i64) models.Error!void {
        var connection = self.pool.acquire() catch return error.DatabaseUnavailable;
        defer connection.release();
        connection.begin() catch return error.DatabaseUnavailable;
        errdefer connection.tryRollback() catch {};
        _ = connection.exec(
            "SELECT pg_advisory_xact_lock(5790053260621242962)",
            .{},
        ) catch return error.DatabaseUnavailable;
        const affected = connection.exec(
            \\UPDATE boards SET archived_at = now()
            \\WHERE id = $1
            \\  AND archived_at IS NULL
            \\  AND (SELECT count(*) FROM boards WHERE archived_at IS NULL) > 1
        , .{board_id}) catch return error.DatabaseUnavailable;
        if ((affected orelse 0) != 1) return error.Conflict;
        connection.commit() catch return error.DatabaseUnavailable;
    }

    pub fn updateBoard(
        self: *Postgres,
        board_id: i64,
        name: []const u8,
        slug: []const u8,
        description: []const u8,
        color: []const u8,
        sort_order: i32,
    ) models.Error!void {
        if (!validBoard(name, slug, description, color) or
            sort_order < 0 or sort_order > 10_000)
        {
            return error.Conflict;
        }
        const affected = self.pool.exec(
            \\UPDATE boards SET
            \\    name = $2, slug = $3, description = $4,
            \\    color = $5, sort_order = $6
            \\WHERE id = $1
        , .{ board_id, name, slug, description, color, sort_order }) catch
            return error.DatabaseUnavailable;
        if ((affected orelse 0) != 1) return error.NotFound;
    }

    pub fn createChangelog(
        self: *Postgres,
        author_id: i64,
        input: models.ChangelogInput,
    ) models.Error!i64 {
        if (!validChangelog(input)) return error.Conflict;
        var row = (self.pool.row(
            \\INSERT INTO changelog_entries (
            \\    author_id, slug, title, summary, body_markdown, version, tags
            \\) VALUES ($1, $2, $3, $4, $5, $6, $7)
            \\RETURNING id
        , .{
            author_id,
            input.slug,
            input.title,
            input.summary,
            input.body_markdown,
            input.version,
            input.tags,
        }) catch return error.DatabaseUnavailable) orelse return error.InvalidDatabaseData;
        defer row.deinit() catch {};
        return row.get(i64, 0) catch error.InvalidDatabaseData;
    }

    pub fn createChangelogWithIssues(
        self: *Postgres,
        author_id: i64,
        input: models.ChangelogInput,
        issue_ids: []const i64,
    ) models.Error!i64 {
        if (!validChangelog(input)) return error.Conflict;
        var connection = self.pool.acquire() catch return error.DatabaseUnavailable;
        defer connection.release();
        connection.begin() catch return error.DatabaseUnavailable;
        errdefer connection.tryRollback() catch {};
        var row = (connection.row(
            \\INSERT INTO changelog_entries (
            \\    author_id, slug, title, summary, body_markdown, version, tags
            \\) VALUES ($1, $2, $3, $4, $5, $6, $7)
            \\RETURNING id
        , .{
            author_id,
            input.slug,
            input.title,
            input.summary,
            input.body_markdown,
            input.version,
            input.tags,
        }) catch return error.DatabaseUnavailable) orelse return error.InvalidDatabaseData;
        const changelog_id = row.get(i64, 0) catch return error.InvalidDatabaseData;
        row.deinit() catch return error.DatabaseUnavailable;
        try replaceChangelogIssues(connection, changelog_id, issue_ids);
        connection.commit() catch return error.DatabaseUnavailable;
        return changelog_id;
    }

    pub fn updateChangelog(
        self: *Postgres,
        changelog_id: i64,
        input: models.ChangelogInput,
    ) models.Error!void {
        if (!validChangelog(input)) return error.Conflict;
        const affected = self.pool.exec(
            \\UPDATE changelog_entries SET
            \\    slug = $2, title = $3, summary = $4, body_markdown = $5,
            \\    version = $6, tags = $7
            \\WHERE id = $1
        , .{
            changelog_id,
            input.slug,
            input.title,
            input.summary,
            input.body_markdown,
            input.version,
            input.tags,
        }) catch return error.DatabaseUnavailable;
        if ((affected orelse 0) != 1) return error.NotFound;
    }

    pub fn updateChangelogWithIssues(
        self: *Postgres,
        changelog_id: i64,
        input: models.ChangelogInput,
        issue_ids: []const i64,
    ) models.Error!void {
        if (!validChangelog(input)) return error.Conflict;
        var connection = self.pool.acquire() catch return error.DatabaseUnavailable;
        defer connection.release();
        connection.begin() catch return error.DatabaseUnavailable;
        errdefer connection.tryRollback() catch {};
        const affected = connection.exec(
            \\UPDATE changelog_entries SET
            \\    slug = $2, title = $3, summary = $4, body_markdown = $5,
            \\    version = $6, tags = $7
            \\WHERE id = $1
        , .{
            changelog_id,
            input.slug,
            input.title,
            input.summary,
            input.body_markdown,
            input.version,
            input.tags,
        }) catch return error.DatabaseUnavailable;
        if ((affected orelse 0) != 1) return error.NotFound;
        try replaceChangelogIssues(connection, changelog_id, issue_ids);
        connection.commit() catch return error.DatabaseUnavailable;
    }

    pub fn publishChangelog(
        self: *Postgres,
        changelog_id: i64,
        published: bool,
    ) models.Error!void {
        const affected = self.pool.exec(
            \\UPDATE changelog_entries SET
            \\    status = CASE WHEN $2 THEN 'published' ELSE 'draft' END,
            \\    published_at = CASE WHEN $2 THEN COALESCE(published_at, now()) ELSE NULL END
            \\WHERE id = $1
        , .{ changelog_id, published }) catch return error.DatabaseUnavailable;
        if ((affected orelse 0) != 1) return error.NotFound;
    }

    pub fn setChangelogIssues(
        self: *Postgres,
        changelog_id: i64,
        issue_ids: []const i64,
    ) models.Error!void {
        if (issue_ids.len > 100) return error.CapacityExceeded;
        var connection = self.pool.acquire() catch return error.DatabaseUnavailable;
        defer connection.release();
        connection.begin() catch return error.DatabaseUnavailable;
        errdefer connection.tryRollback() catch {};

        try replaceChangelogIssues(connection, changelog_id, issue_ids);
        connection.commit() catch return error.DatabaseUnavailable;
    }

    pub fn listChangelogIssues(
        self: *Postgres,
        allocator: std.mem.Allocator,
        changelog_id: i64,
        output: []models.IssueSummary,
    ) models.Error![]models.IssueSummary {
        var result = self.pool.query(
            \\SELECT i.id, i.slug, b.name, i.board_id,
            \\       COALESCE(u.display_name, u.username),
            \\       i.kind, i.status, i.priority, i.title, i.pinned, i.locked,
            \\       i.duplicate_of_id,
            \\       (SELECT count(*) FROM issue_votes v WHERE v.issue_id = i.id),
            \\       (SELECT count(*) FROM comments c WHERE c.issue_id = i.id AND c.deleted_at IS NULL),
            \\       i.created_at
            \\FROM changelog_issue_links link
            \\JOIN issues i ON i.id = link.issue_id
            \\JOIN boards b ON b.id = i.board_id
            \\JOIN users u ON u.id = i.author_id
            \\WHERE link.changelog_id = $1
            \\ORDER BY link.sort_order, i.id
        , .{changelog_id}) catch return error.DatabaseUnavailable;
        defer result.deinit();
        var used: usize = 0;
        while (result.next() catch return error.DatabaseUnavailable) |row| {
            if (used == output.len) return error.CapacityExceeded;
            output[used] = try readIssueSummary(row, allocator);
            used += 1;
        }
        return output[0..used];
    }

    pub fn listChangelogs(
        self: *Postgres,
        allocator: std.mem.Allocator,
        published_only: bool,
        output: []models.Changelog,
    ) models.Error![]models.Changelog {
        return self.listChangelogsPage(
            allocator,
            published_only,
            @intCast(@min(output.len, 100)),
            0,
            output,
        );
    }

    pub fn listChangelogsPage(
        self: *Postgres,
        allocator: std.mem.Allocator,
        published_only: bool,
        limit: u8,
        offset: u32,
        output: []models.Changelog,
    ) models.Error![]models.Changelog {
        if (limit == 0 or limit > output.len) return error.CapacityExceeded;
        var result = self.pool.query(
            \\SELECT c.id, c.slug, COALESCE(u.display_name, u.username),
            \\       c.title, c.summary, ''::text, c.version,
            \\       array_to_string(c.tags, ', '), c.published_at
            \\FROM changelog_entries c
            \\JOIN users u ON u.id = c.author_id
            \\
            \\ WHERE (NOT $1 OR c.status = 'published')
            \\ ORDER BY c.published_at DESC NULLS FIRST, c.updated_at DESC, c.id DESC
            \\ LIMIT $2 OFFSET $3
        , .{ published_only, @as(i32, limit), @as(i64, offset) }) catch
            return error.DatabaseUnavailable;
        defer result.deinit();
        var used: usize = 0;
        while (result.next() catch return error.DatabaseUnavailable) |row| {
            if (used == output.len) return error.CapacityExceeded;
            output[used] = try readChangelog(row, allocator);
            used += 1;
        }
        return output[0..used];
    }

    pub fn getChangelogBySlug(
        self: *Postgres,
        allocator: std.mem.Allocator,
        slug: []const u8,
        published_only: bool,
    ) models.Error!models.Changelog {
        var row = (self.pool.row(
            changelog_select ++
                " WHERE c.slug = $1 AND (NOT $2 OR c.status = 'published')",
            .{ slug, published_only },
        ) catch return error.DatabaseUnavailable) orelse return error.NotFound;
        defer row.deinit() catch {};
        return readChangelogQuery(&row, allocator);
    }

    pub fn getChangelogById(
        self: *Postgres,
        allocator: std.mem.Allocator,
        changelog_id: i64,
    ) models.Error!models.Changelog {
        var row = (self.pool.row(
            changelog_select ++ " WHERE c.id = $1",
            .{changelog_id},
        ) catch return error.DatabaseUnavailable) orelse return error.NotFound;
        defer row.deinit() catch {};
        return readChangelogQuery(&row, allocator);
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
    \\   AND (
    \\       $5::integer IS NULL
    \\       OR i.status <> 'completed'
    \\       OR i.completed_at > now() - make_interval(days => $5)
    \\   )
;

const issue_list_sql =
    \\SELECT i.id, i.slug, b.name, i.board_id,
    \\       COALESCE(u.display_name, u.username),
    \\       i.kind, i.status, i.priority, i.title, i.pinned, i.locked,
    \\       i.duplicate_of_id,
    \\       (SELECT count(*) FROM issue_votes v WHERE v.issue_id = i.id),
    \\       (SELECT count(*) FROM comments c WHERE c.issue_id = i.id AND c.deleted_at IS NULL),
    \\       i.created_at
++ issue_filter ++
    \\ ORDER BY i.pinned DESC,
    \\   CASE WHEN $6 = 'top' THEN
    \\       (SELECT count(*) FROM issue_votes v WHERE v.issue_id = i.id)
    \\   END DESC,
    \\   i.created_at DESC, i.id DESC
    \\ LIMIT $7 OFFSET $8
;

const issue_count_sql = "SELECT count(*)" ++ issue_filter;

const changelog_select =
    \\SELECT c.id, c.slug, COALESCE(u.display_name, u.username),
    \\       c.title, c.summary, c.body_markdown, c.version,
    \\       array_to_string(c.tags, ', '), c.published_at
    \\FROM changelog_entries c
    \\JOIN users u ON u.id = c.author_id
;

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

fn readUserOffset(
    row: *pg.QueryRow,
    allocator: std.mem.Allocator,
    offset: usize,
) models.Error!models.User {
    return .{
        .id = row.get(i64, offset) catch return error.InvalidDatabaseData,
        .discord_id = try copyQueryColumn(row, allocator, offset + 1),
        .username = try copyQueryColumn(row, allocator, offset + 2),
        .display_name = try copyOptionalQueryColumn(row, allocator, offset + 3),
        .avatar_hash = try copyOptionalQueryColumn(row, allocator, offset + 4),
        .role = try models.parseRole(row.get([]const u8, offset + 5) catch
            return error.InvalidDatabaseData),
        .disabled = row.get(bool, offset + 6) catch return error.InvalidDatabaseData,
        .created_at_us = row.get(i64, offset + 7) catch return error.InvalidDatabaseData,
        .last_login_at_us = row.get(i64, offset + 8) catch return error.InvalidDatabaseData,
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
        .board_id = row.get(i64, 3) catch return error.InvalidDatabaseData,
        .author_name = try copyColumn(row, allocator, 4),
        .kind = try models.parseKind(row.get([]const u8, 5) catch
            return error.InvalidDatabaseData),
        .status = try models.parseStatus(row.get([]const u8, 6) catch
            return error.InvalidDatabaseData),
        .priority = try models.parsePriority(row.get([]const u8, 7) catch
            return error.InvalidDatabaseData),
        .title = try copyColumn(row, allocator, 8),
        .pinned = row.get(bool, 9) catch return error.InvalidDatabaseData,
        .locked = row.get(bool, 10) catch return error.InvalidDatabaseData,
        .duplicate_of_id = row.get(?i64, 11) catch return error.InvalidDatabaseData,
        .vote_count = row.get(i64, 12) catch return error.InvalidDatabaseData,
        .comment_count = row.get(i64, 13) catch return error.InvalidDatabaseData,
        .created_at_us = row.get(i64, 14) catch return error.InvalidDatabaseData,
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

fn insertEvent(
    connection: *pg.Conn,
    issue_id: i64,
    actor_id: i64,
    event_type: []const u8,
    from_value: ?[]const u8,
    to_value: ?[]const u8,
) models.Error!void {
    _ = connection.exec(
        \\INSERT INTO issue_events (
        \\    issue_id, actor_id, event_type, from_value, to_value
        \\) VALUES ($1, $2, $3, $4, $5)
    , .{ issue_id, actor_id, event_type, from_value, to_value }) catch
        return error.DatabaseUnavailable;
}

fn insertIntegerEvent(
    connection: *pg.Conn,
    issue_id: i64,
    actor_id: i64,
    event_type: []const u8,
    from_value: i64,
    to_value: i64,
) models.Error!void {
    var from_storage: [24]u8 = undefined;
    var to_storage: [24]u8 = undefined;
    const from = std.fmt.bufPrint(&from_storage, "{d}", .{from_value}) catch
        return error.InvalidDatabaseData;
    const to = std.fmt.bufPrint(&to_storage, "{d}", .{to_value}) catch
        return error.InvalidDatabaseData;
    return insertEvent(connection, issue_id, actor_id, event_type, from, to);
}

fn validChangelog(input: models.ChangelogInput) bool {
    if (std.mem.trim(u8, input.title, " \t\r\n").len < 3 or input.title.len > 160 or
        std.mem.trim(u8, input.summary, " \t\r\n").len == 0 or input.summary.len > 500 or
        std.mem.trim(u8, input.body_markdown, " \t\r\n").len == 0 or
        input.body_markdown.len > 64 * 1024 or !validSlug(input.slug, 180))
    {
        return false;
    }
    if (input.version) |version| if (version.len == 0 or version.len > 64) return false;
    if (input.tags.len > 12) return false;
    for (input.tags) |tag| if (tag.len == 0 or tag.len > 40) return false;
    return true;
}

fn validBoard(
    name: []const u8,
    slug: []const u8,
    description: []const u8,
    color: []const u8,
) bool {
    if (!validPlainText(name, 1, 80) or !validPlainText(description, 0, 500) or
        !validSlug(slug, 80))
    {
        return false;
    }
    inline for (.{ "violet", "blue", "green", "amber", "rose", "gray" }) |allowed| {
        if (std.mem.eql(u8, color, allowed)) return true;
    }
    return false;
}

fn validPlainText(value: []const u8, minimum: usize, maximum: usize) bool {
    if (value.len < minimum or value.len > maximum or
        !std.unicode.utf8ValidateSlice(value))
    {
        return false;
    }
    for (value) |byte| {
        if (byte < 0x20 and byte != '\t' and byte != '\n') return false;
    }
    return true;
}

fn validSlug(value: []const u8, maximum: usize) bool {
    if (value.len == 0 or value.len > maximum or value[0] == '-' or
        value[value.len - 1] == '-')
    {
        return false;
    }
    var previous_dash = false;
    for (value) |byte| {
        if (byte == '-') {
            if (previous_dash) return false;
            previous_dash = true;
        } else {
            if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte)) return false;
            previous_dash = false;
        }
    }
    return true;
}

fn readChangelog(
    row: pg.Row,
    allocator: std.mem.Allocator,
) models.Error!models.Changelog {
    return .{
        .id = row.get(i64, 0) catch return error.InvalidDatabaseData,
        .slug = try copyColumn(row, allocator, 1),
        .author_name = try copyColumn(row, allocator, 2),
        .title = try copyColumn(row, allocator, 3),
        .summary = try copyColumn(row, allocator, 4),
        .body_markdown = try copyColumn(row, allocator, 5),
        .version = try copyOptionalColumn(row, allocator, 6),
        .tags_csv = try copyColumn(row, allocator, 7),
        .published_at_us = row.get(?i64, 8) catch return error.InvalidDatabaseData,
    };
}

fn readChangelogQuery(
    row: *pg.QueryRow,
    allocator: std.mem.Allocator,
) models.Error!models.Changelog {
    return .{
        .id = row.get(i64, 0) catch return error.InvalidDatabaseData,
        .slug = try copyQueryColumn(row, allocator, 1),
        .author_name = try copyQueryColumn(row, allocator, 2),
        .title = try copyQueryColumn(row, allocator, 3),
        .summary = try copyQueryColumn(row, allocator, 4),
        .body_markdown = try copyQueryColumn(row, allocator, 5),
        .version = try copyOptionalQueryColumn(row, allocator, 6),
        .tags_csv = try copyQueryColumn(row, allocator, 7),
        .published_at_us = row.get(?i64, 8) catch return error.InvalidDatabaseData,
    };
}

fn copyOptionalColumn(
    row: pg.Row,
    allocator: std.mem.Allocator,
    index: usize,
) models.Error!?[]const u8 {
    const value = row.get(?[]const u8, index) catch return error.InvalidDatabaseData;
    return if (value) |bytes|
        allocator.dupe(u8, bytes) catch error.CapacityExceeded
    else
        null;
}

fn readApiToken(
    row: pg.Row,
    allocator: std.mem.Allocator,
) models.Error!models.ApiToken {
    const id = row.get([]u8, 0) catch return error.InvalidDatabaseData;
    const scopes = row.get(i64, 3) catch return error.InvalidDatabaseData;
    if (id.len != 16 or scopes <= 0 or scopes > 63) return error.InvalidDatabaseData;
    return .{
        .id = id[0..16].*,
        .lookup_prefix = try copyColumn(row, allocator, 1),
        .label = try copyColumn(row, allocator, 2),
        .scopes = .{ .bits = @intCast(scopes) },
        .expires_at_us = row.get(?i64, 4) catch return error.InvalidDatabaseData,
        .revoked = row.get(bool, 5) catch return error.InvalidDatabaseData,
        .last_used_at_us = row.get(?i64, 6) catch return error.InvalidDatabaseData,
        .created_at_us = row.get(i64, 7) catch return error.InvalidDatabaseData,
    };
}

fn readApiTokenQuery(
    row: *pg.QueryRow,
    allocator: std.mem.Allocator,
    offset: usize,
) models.Error!models.ApiToken {
    const id = row.get([]u8, offset) catch return error.InvalidDatabaseData;
    const scopes = row.get(i64, offset + 3) catch return error.InvalidDatabaseData;
    if (id.len != 16 or scopes <= 0 or scopes > 63) return error.InvalidDatabaseData;
    return .{
        .id = id[0..16].*,
        .lookup_prefix = try copyQueryColumn(row, allocator, offset + 1),
        .label = try copyQueryColumn(row, allocator, offset + 2),
        .scopes = .{ .bits = @intCast(scopes) },
        .expires_at_us = row.get(?i64, offset + 4) catch return error.InvalidDatabaseData,
        .revoked = row.get(bool, offset + 5) catch return error.InvalidDatabaseData,
        .last_used_at_us = row.get(?i64, offset + 6) catch return error.InvalidDatabaseData,
        .created_at_us = row.get(i64, offset + 7) catch return error.InvalidDatabaseData,
    };
}

fn replaceChangelogIssues(
    connection: *pg.Conn,
    changelog_id: i64,
    issue_ids: []const i64,
) models.Error!void {
    if (issue_ids.len > 100) return error.CapacityExceeded;
    _ = connection.exec(
        "DELETE FROM changelog_issue_links WHERE changelog_id = $1",
        .{changelog_id},
    ) catch return error.DatabaseUnavailable;
    for (issue_ids, 0..) |issue_id, index| {
        const affected = connection.exec(
            \\INSERT INTO changelog_issue_links (
            \\    changelog_id, issue_id, sort_order
            \\)
            \\SELECT $1, id, $3 FROM issues
            \\WHERE id = $2 AND status = 'completed'
        , .{ changelog_id, issue_id, @as(i32, @intCast(index)) }) catch
            return error.DatabaseUnavailable;
        if ((affected orelse 0) != 1) return error.Conflict;
    }
}
