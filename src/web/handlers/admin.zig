const std = @import("std");
const ploof = @import("ploof");
const app_state = @import("../../app_state.zig");
const domain = @import("../../domain.zig");
const models = @import("../../store.zig");
const csrf = @import("../csrf.zig");
const page = @import("../page.zig");
const request = @import("../request.zig");
const highlight = @import("../highlight.zig");

pub const IssueUpdateDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(struct {
        status: domain.IssueStatus,
        priority: domain.Priority,
        board_id: i64,
        pinned: bool = false,
        locked: bool = false,
        duplicate_of_id: ?i64 = null,
    }, formOptions(12 * 1024, 8)),
});

pub const BoardCreateDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(struct {
        name: []const u8,
        slug: []const u8,
        description: []const u8 = "",
        color: []const u8 = "violet",
    }, formOptions(4 * 1024, 8)),
});

pub const BoardArchiveDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(struct { confirm: bool }, formOptions(1024, 2)),
});

pub const ChangelogCreateDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(struct {
        title: []const u8,
        slug: []const u8,
        summary: []const u8,
        body: []const u8,
        version: ?[]const u8 = null,
        tags: ?[]const u8 = null,
    }, formOptions(96 * 1024, 10)),
});

pub const ChangelogPublishDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(struct {
        published: bool,
        confirm: bool,
    }, formOptions(1024, 3)),
});

pub fn dashboard(context: *app_state.Context) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return context.empty(.service_unavailable);
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const allocator = workspace.allocator();
    const principal = adminPrincipal(context, allocator) catch |problem| return switch (problem) {
        error.Forbidden => context.empty(.forbidden),
        else => context.empty(.service_unavailable),
    };
    var issue_storage: [20]models.IssueSummary = undefined;
    const issues = database.listIssues(allocator, .{ .limit = 20 }, &issue_storage) catch
        return context.empty(.service_unavailable);
    var board_storage: [32]models.Board = undefined;
    const boards = database.listBoards(allocator, &board_storage, true) catch
        return context.empty(.service_unavailable);
    var changelog_storage: [100]models.Changelog = undefined;
    const changelogs = database.listChangelogs(
        allocator,
        false,
        &changelog_storage,
    ) catch return context.empty(.service_unavailable);
    const token = csrf.prepare(context) catch return context.empty(.internal_server_error);

    var writer = workspace.writer();
    page.begin(&writer, settings, "Admin", .admin, &principal.user) catch
        return context.empty(.internal_server_error);
    writer.writeAll("<section class=\"admin-shell\"><header class=\"admin-heading\"><div><p class=\"kicker\">Single-company admin</p>") catch
        return context.empty(.internal_server_error);
    writer.writeAll("<h1>Keep feedback moving.</h1><p>Triage the backlog, shape the roadmap, and publish what shipped.</p></div>") catch
        return context.empty(.internal_server_error);
    writer.print("<div class=\"admin-stat\"><strong>{d}</strong><span>feedback items</span></div></header>", .{issues.total}) catch
        return context.empty(.internal_server_error);
    renderIssues(&writer, issues.items, boards, token.hiddenInput()) catch
        return context.empty(.internal_server_error);
    renderBoards(&writer, boards, token.hiddenInput()) catch
        return context.empty(.internal_server_error);
    renderChangelogs(&writer, changelogs, token.hiddenInput()) catch
        return context.empty(.internal_server_error);
    page.end(&writer) catch return context.empty(.internal_server_error);
    var response = context.htmlBorrowed(.ok, workspace.rendered(&writer));
    csrf.attach(&response, &token);
    return response;
}

pub fn updateIssue(
    context: *app_state.Context,
    input: IssueUpdateDefinition.InputType,
) app_state.Context.ResponseType {
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    const issue_id = request.parseIssueId(context) orelse return context.empty(.not_found);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const principal = adminPrincipal(context, workspace.allocator()) catch |problem| return switch (problem) {
        error.Forbidden => context.empty(.forbidden),
        else => context.empty(.service_unavailable),
    };
    database.adminUpdateIssue(issue_id, principal.user.id, .{
        .status = input.body.status,
        .priority = input.body.priority,
        .board_id = input.body.board_id,
        .pinned = input.body.pinned,
        .locked = input.body.locked,
        .duplicate_of_id = input.body.duplicate_of_id,
    }) catch |problem| return switch (problem) {
        error.NotFound => context.empty(.not_found),
        error.Conflict => context.textStatic(.conflict, "Invalid issue transition."),
        else => context.empty(.service_unavailable),
    };
    return request.redirect(context, .see_other, "/admin#issues");
}

pub fn createBoard(
    context: *app_state.Context,
    input: BoardCreateDefinition.InputType,
) app_state.Context.ResponseType {
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    _ = adminPrincipal(context, workspace.allocator()) catch |problem| return switch (problem) {
        error.Forbidden => context.empty(.forbidden),
        else => context.empty(.service_unavailable),
    };
    _ = database.createBoard(
        input.body.name,
        input.body.slug,
        input.body.description,
        input.body.color,
    ) catch |problem| return switch (problem) {
        error.Conflict => context.textStatic(.unprocessable_entity, "Board details are invalid."),
        else => context.empty(.service_unavailable),
    };
    return request.redirect(context, .see_other, "/admin#boards");
}

pub fn archiveBoard(
    context: *app_state.Context,
    input: BoardArchiveDefinition.InputType,
) app_state.Context.ResponseType {
    if (!input.body.confirm) return context.empty(.bad_request);
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    const board_id = request.parseIssueId(context) orelse return context.empty(.not_found);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    _ = adminPrincipal(context, workspace.allocator()) catch |problem| return switch (problem) {
        error.Forbidden => context.empty(.forbidden),
        else => context.empty(.service_unavailable),
    };
    database.archiveBoard(board_id) catch |problem| return switch (problem) {
        error.Conflict => context.textStatic(.conflict, "The final active board cannot be archived."),
        else => context.empty(.service_unavailable),
    };
    return request.redirect(context, .see_other, "/admin#boards");
}

pub fn createChangelog(
    context: *app_state.Context,
    input: ChangelogCreateDefinition.InputType,
) app_state.Context.ResponseType {
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const principal = adminPrincipal(context, workspace.allocator()) catch |problem| return switch (problem) {
        error.Forbidden => context.empty(.forbidden),
        else => context.empty(.service_unavailable),
    };
    var tag_storage: [12][]const u8 = undefined;
    const tags = parseTags(input.body.tags, &tag_storage);
    _ = database.createChangelog(principal.user.id, .{
        .title = input.body.title,
        .slug = input.body.slug,
        .summary = input.body.summary,
        .body_markdown = input.body.body,
        .version = nonEmpty(input.body.version),
        .tags = tags,
    }) catch |problem| return switch (problem) {
        error.Conflict => context.textStatic(.unprocessable_entity, "Changelog details are invalid."),
        else => context.empty(.service_unavailable),
    };
    return request.redirect(context, .see_other, "/admin#changelog");
}

pub fn publishChangelog(
    context: *app_state.Context,
    input: ChangelogPublishDefinition.InputType,
) app_state.Context.ResponseType {
    if (!input.body.confirm) return context.empty(.bad_request);
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    const changelog_id = request.parseIssueId(context) orelse return context.empty(.not_found);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    _ = adminPrincipal(context, workspace.allocator()) catch |problem| return switch (problem) {
        error.Forbidden => context.empty(.forbidden),
        else => context.empty(.service_unavailable),
    };
    database.publishChangelog(changelog_id, input.body.published) catch |problem| return switch (problem) {
        error.NotFound => context.empty(.not_found),
        else => context.empty(.service_unavailable),
    };
    return request.redirect(context, .see_other, "/admin#changelog");
}

fn adminPrincipal(
    context: *app_state.Context,
    allocator: std.mem.Allocator,
) models.Error!models.SessionPrincipal {
    const principal = (try request.principal(context, allocator)) orelse
        return error.Forbidden;
    if (principal.user.role != .admin) return error.Forbidden;
    return principal;
}

fn renderIssues(
    writer: *std.Io.Writer,
    issues: []const models.IssueSummary,
    boards: []const models.Board,
    csrf_input: []const u8,
) !void {
    try writer.writeAll("<section class=\"admin-section\" id=\"issues\"><div class=\"admin-section-heading\"><div><p class=\"kicker\">Triage</p><h2>Feedback backlog</h2></div></div>");
    if (issues.len == 0) {
        try writer.writeAll("<p class=\"notice\">No feedback needs triage.</p></section>");
        return;
    }
    try writer.writeAll("<div class=\"admin-list\">");
    for (issues) |issue| {
        try writer.print("<form class=\"admin-issue\" method=\"post\" action=\"/admin/issues/{d}\">", .{issue.id});
        try writer.writeAll(csrf_input);
        try writer.writeAll("<div class=\"admin-issue-title\"><strong>");
        try highlight.escapeHtml(writer, issue.title);
        try writer.print("</strong><span>#{d} · {d} votes</span></div>", .{ issue.id, issue.vote_count });
        try writer.writeAll("<label>Status<select name=\"status\">");
        inline for (std.meta.tags(domain.IssueStatus)) |status| {
            try writer.print("<option value=\"{s}\"{s}>{s}</option>", .{
                @tagName(status),
                if (issue.status == status) " selected" else "",
                status.label(),
            });
        }
        try writer.writeAll("</select></label><label>Priority<select name=\"priority\">");
        inline for (std.meta.tags(domain.Priority)) |priority| {
            try writer.print("<option value=\"{s}\"{s}>{s}</option>", .{
                @tagName(priority),
                if (issue.priority == priority) " selected" else "",
                @tagName(priority),
            });
        }
        try writer.writeAll("</select></label><label>Board<select name=\"board_id\">");
        for (boards) |board| {
            if (board.archived) continue;
            try writer.print("<option value=\"{d}\"{s}>", .{
                board.id,
                if (issue.board_id == board.id) " selected" else "",
            });
            try highlight.escapeHtml(writer, board.name);
            try writer.writeAll("</option>");
        }
        try writer.print("</select></label><label class=\"check\"><input type=\"checkbox\" name=\"pinned\" value=\"true\"{s}> Pin</label>", .{
            if (issue.pinned) " checked" else "",
        });
        try writer.print("<label class=\"check\"><input type=\"checkbox\" name=\"locked\" value=\"true\"{s}> Lock</label>", .{
            if (issue.locked) " checked" else "",
        });
        try writer.writeAll("<button class=\"button button-primary\" type=\"submit\">Save</button></form>");
    }
    try writer.writeAll("</div></section>");
}

fn renderBoards(
    writer: *std.Io.Writer,
    boards: []const models.Board,
    csrf_input: []const u8,
) !void {
    try writer.writeAll("<section class=\"admin-section\" id=\"boards\"><div class=\"admin-section-heading\"><div><p class=\"kicker\">Organization</p><h2>Boards</h2></div></div><div class=\"board-admin-grid\">");
    for (boards) |board| {
        try writer.writeAll("<article class=\"admin-card\"><div><strong>");
        try highlight.escapeHtml(writer, board.name);
        try writer.writeAll("</strong><p>");
        try highlight.escapeHtml(writer, board.description);
        try writer.writeAll("</p></div>");
        if (board.archived) {
            try writer.writeAll("<span class=\"status status-closed\">Archived</span>");
        } else {
            try writer.print("<form method=\"post\" action=\"/admin/boards/{d}/archive\" data-confirm=\"Archive this board?\">", .{board.id});
            try writer.writeAll(csrf_input);
            try writer.writeAll("<input type=\"hidden\" name=\"confirm\" value=\"true\"><button class=\"button button-quiet\" type=\"submit\">Archive</button></form>");
        }
        try writer.writeAll("</article>");
    }
    try writer.writeAll("</div><form class=\"admin-card inline-create\" method=\"post\" action=\"/admin/boards\">");
    try writer.writeAll(csrf_input);
    try writer.writeAll("<label>Name<input name=\"name\" required maxlength=\"80\"></label><label>Slug<input name=\"slug\" required pattern=\"[a-z0-9-]+\" maxlength=\"80\"></label>");
    try writer.writeAll("<label>Description<input name=\"description\" maxlength=\"500\"></label><input type=\"hidden\" name=\"color\" value=\"violet\">");
    try writer.writeAll("<button class=\"button button-primary\" type=\"submit\">Add board</button></form></section>");
}

fn renderChangelogs(
    writer: *std.Io.Writer,
    entries: []const models.Changelog,
    csrf_input: []const u8,
) !void {
    try writer.writeAll("<section class=\"admin-section\" id=\"changelog\"><div class=\"admin-section-heading\"><div><p class=\"kicker\">Releases</p><h2>Changelog</h2></div></div>");
    if (entries.len != 0) {
        try writer.writeAll("<div class=\"board-admin-grid\">");
        for (entries) |entry| {
            try writer.writeAll("<article class=\"admin-card\"><div><strong>");
            try highlight.escapeHtml(writer, entry.title);
            try writer.writeAll("</strong><p>");
            try highlight.escapeHtml(writer, entry.summary);
            try writer.writeAll("</p></div>");
            try writer.print("<form method=\"post\" action=\"/admin/changelog/{d}/publish\" data-confirm=\"Change publication state?\">", .{entry.id});
            try writer.writeAll(csrf_input);
            try writer.print("<input type=\"hidden\" name=\"published\" value=\"{s}\"><input type=\"hidden\" name=\"confirm\" value=\"true\">", .{
                if (entry.published_at_us == null) "true" else "false",
            });
            try writer.print("<button class=\"button button-quiet\" type=\"submit\">{s}</button></form></article>", .{
                if (entry.published_at_us == null) "Publish" else "Revert to draft",
            });
        }
        try writer.writeAll("</div>");
    }
    try writer.writeAll("<form class=\"stacked-form admin-changelog-form\" method=\"post\" action=\"/admin/changelog\">");
    try writer.writeAll(csrf_input);
    try writer.writeAll("<div class=\"form-row\"><label>Title<input name=\"title\" required maxlength=\"160\"></label><label>Slug<input name=\"slug\" required pattern=\"[a-z0-9-]+\" maxlength=\"180\"></label></div>");
    try writer.writeAll("<div class=\"form-row\"><label>Version<input name=\"version\" maxlength=\"64\" placeholder=\"1.0.0\"></label><label>Tags<input name=\"tags\" maxlength=\"300\" placeholder=\"new-feature, improvement\"></label></div>");
    try writer.writeAll("<label>Summary<input name=\"summary\" required maxlength=\"500\"></label>");
    try writer.writeAll("<label>Release notes<textarea name=\"body\" required maxlength=\"65536\" rows=\"10\" placeholder=\"Markdown and fenced code are supported.\"></textarea></label>");
    try writer.writeAll("<div class=\"form-actions\"><button class=\"button button-primary\" type=\"submit\">Save draft</button></div></form></section>");
}

fn formOptions(comptime bytes: u64, comptime segments: u16) ploof.Form.Options {
    return .{
        .encoded_wire_bytes_max = bytes,
        .decoded_bytes_max = bytes,
        .segments_max = segments,
        .unknown_fields = .reject,
    };
}

fn parseTags(value: ?[]const u8, output: *[12][]const u8) []const []const u8 {
    const input = value orelse return &.{};
    var used: usize = 0;
    var iterator = std.mem.splitScalar(u8, input, ',');
    while (iterator.next()) |raw| {
        const tag = std.mem.trim(u8, raw, " \t");
        if (tag.len == 0) continue;
        if (used == output.len) break;
        output[used] = tag;
        used += 1;
    }
    return output[0..used];
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (std.mem.trim(u8, text, " \t\r\n").len == 0) null else text;
}
