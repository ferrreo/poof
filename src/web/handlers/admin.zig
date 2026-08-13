const std = @import("std");
const ploof = @import("ploof");
const app_state = @import("../../app_state.zig");
const domain = @import("../../domain.zig");
const models = @import("../../store.zig");
const csrf = @import("../csrf.zig");
const page = @import("../page.zig");
const request = @import("../request.zig");
const highlight = @import("../highlight.zig");

const DashboardQuery = struct {
    page: u16 = 1,
    release_page: u16 = 1,
    q: ?[]const u8 = null,
    status: enum { all, pending, reviewing, planned, in_progress, completed, closed } = .all,
};

pub const DashboardDefinition = ploof.Endpoint(.{
    .query = ploof.Query.typed(DashboardQuery, .{
        .segments_max = 4,
        .unknown_fields = .reject,
    }),
});

pub const IssueUpdateDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(struct {
        status: domain.IssueStatus,
        priority: domain.Priority,
        board_id: i64,
        pinned: bool = false,
        locked: bool = false,
        duplicate_of_id: ?[]const u8 = null,
    }, formOptions(12 * 1024, 8)),
});

pub const IssueContentDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(struct {
        title: []const u8,
        body: []const u8,
        reproduction_steps: ?[]const u8 = null,
        expected_behavior: ?[]const u8 = null,
        actual_behavior: ?[]const u8 = null,
        environment: ?[]const u8 = null,
        evidence_url: ?[]const u8 = null,
    }, formOptions(64 * 1024, 12)),
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

pub const BoardUpdateDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(struct {
        name: []const u8,
        slug: []const u8,
        description: []const u8 = "",
        color: []const u8 = "violet",
        sort_order: i32,
    }, formOptions(4 * 1024, 8)),
});

pub const ChangelogCreateDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(struct {
        title: []const u8,
        slug: []const u8,
        summary: []const u8,
        body: []const u8,
        version: ?[]const u8 = null,
        tags: ?[]const u8 = null,
        issue_ids: ?[]const u8 = null,
    }, formOptions(96 * 1024, 12)),
});

pub const ChangelogPublishDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(struct {
        published: bool,
        confirm: bool,
    }, formOptions(1024, 3)),
});

pub fn dashboard(
    context: *app_state.Context,
    input: DashboardDefinition.InputType,
) app_state.Context.ResponseType {
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
    const query = input.query;
    const issues = database.listIssues(allocator, .{
        .query = query.q,
        .status = switch (query.status) {
            .all => null,
            .pending => .pending,
            .reviewing => .reviewing,
            .planned => .planned,
            .in_progress => .in_progress,
            .completed => .completed,
            .closed => .closed,
        },
        .limit = 20,
        .offset = (@as(u32, @max(query.page, 1)) - 1) * 20,
    }, &issue_storage) catch
        return context.empty(.service_unavailable);
    var board_storage: [32]models.Board = undefined;
    const boards = database.listBoards(allocator, &board_storage, true) catch
        return context.empty(.service_unavailable);
    var changelog_storage: [20]models.Changelog = undefined;
    const changelogs = database.listChangelogsPage(
        allocator,
        false,
        20,
        (@as(u32, @max(query.release_page, 1)) - 1) * 20,
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
    renderIssues(&writer, issues, boards, token.hiddenInput(), query) catch
        return context.empty(.internal_server_error);
    renderBoards(&writer, boards, token.hiddenInput()) catch
        return context.empty(.internal_server_error);
    renderChangelogs(
        &writer,
        changelogs,
        @max(query.release_page, 1),
        token.hiddenInput(),
    ) catch
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
        .duplicate_of_id = parseOptionalId(input.body.duplicate_of_id) catch
            return context.textStatic(.unprocessable_entity, "Duplicate issue ID is invalid."),
    }) catch |problem| return switch (problem) {
        error.NotFound => context.empty(.not_found),
        error.Conflict => context.textStatic(.conflict, "Invalid issue transition."),
        else => context.empty(.service_unavailable),
    };
    return request.redirect(context, .see_other, "/admin#issues");
}

pub fn editIssuePage(context: *app_state.Context) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return context.empty(.service_unavailable);
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    const issue_id = request.parseIssueId(context) orelse return context.empty(.not_found);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const allocator = workspace.allocator();
    const principal = adminPrincipal(context, allocator) catch |problem| return switch (problem) {
        error.Forbidden => context.empty(.forbidden),
        else => context.empty(.service_unavailable),
    };
    const issue = database.getIssue(allocator, issue_id) catch |problem| return switch (problem) {
        error.NotFound => context.empty(.not_found),
        else => context.empty(.service_unavailable),
    };
    const token = csrf.prepare(context) catch return context.empty(.internal_server_error);
    var writer = workspace.writer();
    page.begin(&writer, settings, "Edit feedback", .admin, &principal.user) catch
        return context.empty(.internal_server_error);
    tryRenderIssueContentForm(&writer, issue, token.hiddenInput()) catch
        return context.empty(.internal_server_error);
    page.end(&writer) catch return context.empty(.internal_server_error);
    var response = context.htmlBorrowed(.ok, workspace.rendered(&writer));
    csrf.attach(&response, &token);
    return response;
}

pub fn editIssueContent(
    context: *app_state.Context,
    input: IssueContentDefinition.InputType,
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
    database.editIssueContent(issue_id, principal.user.id, .{
        .title = input.body.title,
        .body_markdown = input.body.body,
        .reproduction_steps = nonEmpty(input.body.reproduction_steps),
        .expected_behavior = nonEmpty(input.body.expected_behavior),
        .actual_behavior = nonEmpty(input.body.actual_behavior),
        .environment = nonEmpty(input.body.environment),
        .evidence_url = nonEmpty(input.body.evidence_url),
    }) catch |problem| return switch (problem) {
        error.Conflict => context.textStatic(.unprocessable_entity, "Issue content is invalid."),
        else => context.empty(.service_unavailable),
    };
    var target: [256]u8 = undefined;
    const location = std.fmt.bufPrint(&target, "/admin/issues/{d}/edit", .{issue_id}) catch
        return context.empty(.internal_server_error);
    return request.redirect(context, .see_other, location);
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

pub fn updateBoard(
    context: *app_state.Context,
    input: BoardUpdateDefinition.InputType,
) app_state.Context.ResponseType {
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    const board_id = request.parseIssueId(context) orelse return context.empty(.not_found);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    _ = adminPrincipal(context, workspace.allocator()) catch |problem| return switch (problem) {
        error.Forbidden => context.empty(.forbidden),
        else => context.empty(.service_unavailable),
    };
    database.updateBoard(
        board_id,
        input.body.name,
        input.body.slug,
        input.body.description,
        input.body.color,
        input.body.sort_order,
    ) catch |problem| return switch (problem) {
        error.NotFound => context.empty(.not_found),
        error.Conflict => context.textStatic(.unprocessable_entity, "Board details are invalid."),
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
    var issue_id_storage: [100]i64 = undefined;
    const issue_ids = parseIds(input.body.issue_ids, &issue_id_storage) catch
        return context.textStatic(.unprocessable_entity, "Linked issue IDs are invalid.");
    _ = database.createChangelogWithIssues(principal.user.id, .{
        .title = input.body.title,
        .slug = input.body.slug,
        .summary = input.body.summary,
        .body_markdown = input.body.body,
        .version = nonEmpty(input.body.version),
        .tags = tags,
    }, issue_ids) catch |problem| return switch (problem) {
        error.Conflict => context.textStatic(.unprocessable_entity, "Changelog details or linked issues are invalid."),
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

pub fn editChangelogPage(context: *app_state.Context) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return context.empty(.service_unavailable);
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    const changelog_id = request.parseIssueId(context) orelse return context.empty(.not_found);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const allocator = workspace.allocator();
    const principal = adminPrincipal(context, allocator) catch |problem| return switch (problem) {
        error.Forbidden => context.empty(.forbidden),
        else => context.empty(.service_unavailable),
    };
    const entry = database.getChangelogById(allocator, changelog_id) catch |problem| return switch (problem) {
        error.NotFound => context.empty(.not_found),
        else => context.empty(.service_unavailable),
    };
    var linked_storage: [100]models.IssueSummary = undefined;
    const linked = database.listChangelogIssues(
        allocator,
        changelog_id,
        &linked_storage,
    ) catch return context.empty(.service_unavailable);
    const token = csrf.prepare(context) catch return context.empty(.internal_server_error);
    var writer = workspace.writer();
    page.begin(&writer, settings, "Edit changelog", .admin, &principal.user) catch
        return context.empty(.internal_server_error);
    renderChangelogEditForm(&writer, entry, linked, token.hiddenInput()) catch
        return context.empty(.internal_server_error);
    page.end(&writer) catch return context.empty(.internal_server_error);
    var response = context.htmlBorrowed(.ok, workspace.rendered(&writer));
    csrf.attach(&response, &token);
    return response;
}

pub fn updateChangelog(
    context: *app_state.Context,
    input: ChangelogCreateDefinition.InputType,
) app_state.Context.ResponseType {
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    const changelog_id = request.parseIssueId(context) orelse return context.empty(.not_found);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    _ = adminPrincipal(context, workspace.allocator()) catch |problem| return switch (problem) {
        error.Forbidden => context.empty(.forbidden),
        else => context.empty(.service_unavailable),
    };
    var tag_storage: [12][]const u8 = undefined;
    var issue_storage: [100]i64 = undefined;
    const linked = parseIds(input.body.issue_ids, &issue_storage) catch
        return context.textStatic(.unprocessable_entity, "Linked issue IDs are invalid.");
    database.updateChangelogWithIssues(changelog_id, .{
        .title = input.body.title,
        .slug = input.body.slug,
        .summary = input.body.summary,
        .body_markdown = input.body.body,
        .version = nonEmpty(input.body.version),
        .tags = parseTags(input.body.tags, &tag_storage),
    }, linked) catch |problem| return switch (problem) {
        error.NotFound => context.empty(.not_found),
        error.Conflict => context.textStatic(.unprocessable_entity, "Changelog details or linked issues are invalid."),
        else => context.empty(.service_unavailable),
    };
    var target: [256]u8 = undefined;
    const location = std.fmt.bufPrint(&target, "/admin/changelog/{d}/edit", .{changelog_id}) catch
        return context.empty(.internal_server_error);
    return request.redirect(context, .see_other, location);
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
    result: models.ListResult,
    boards: []const models.Board,
    csrf_input: []const u8,
    query: DashboardQuery,
) !void {
    try writer.writeAll("<section class=\"admin-section\" id=\"issues\"><div class=\"admin-section-heading\"><div><p class=\"kicker\">Triage</p><h2>Feedback backlog</h2></div></div>");
    try writer.writeAll("<form class=\"admin-filters\" method=\"get\" action=\"/admin\"><input type=\"search\" name=\"q\" placeholder=\"Search feedback\" value=\"");
    if (query.q) |value| try highlight.escapeHtml(writer, value);
    try writer.writeAll("\"><select name=\"status\"><option value=\"all\">All statuses</option>");
    inline for (std.meta.tags(domain.IssueStatus)) |status| {
        try writer.print("<option value=\"{s}\"{s}>{s}</option>", .{
            @tagName(status),
            if (std.mem.eql(u8, @tagName(query.status), @tagName(status))) " selected" else "",
            status.label(),
        });
    }
    try writer.writeAll("</select><button class=\"button button-quiet\" type=\"submit\">Filter</button></form>");
    if (result.items.len == 0) {
        try writer.writeAll("<p class=\"notice\">No feedback needs triage.</p></section>");
        return;
    }
    try writer.writeAll("<div class=\"admin-list\">");
    for (result.items) |issue| {
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
        try writer.writeAll("<label>Duplicate of<input type=\"number\" name=\"duplicate_of_id\" min=\"1\" value=\"");
        if (issue.duplicate_of_id) |target| try writer.print("{d}", .{target});
        try writer.writeAll("\"></label>");
        try writer.print("<a class=\"button button-quiet\" href=\"/admin/issues/{d}/edit\">Edit</a>", .{issue.id});
        try writer.writeAll("<button class=\"button button-primary\" type=\"submit\">Save</button></form>");
    }
    try writer.writeAll("</div><nav class=\"pagination\" aria-label=\"Admin feedback pages\">");
    const page_number = @max(query.page, 1);
    if (page_number > 1) {
        try writer.print("<a class=\"button button-quiet\" href=\"/admin?page={d}\">← Previous</a>", .{page_number - 1});
    }
    if (@as(i64, page_number) * 20 < result.total) {
        try writer.print("<a class=\"button button-quiet\" href=\"/admin?page={d}\">Next →</a>", .{page_number + 1});
    }
    try writer.writeAll("</nav></section>");
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
            try writer.print("<form class=\"board-edit\" method=\"post\" action=\"/admin/boards/{d}\">", .{board.id});
            try writer.writeAll(csrf_input);
            try writer.writeAll("<label>Name<input name=\"name\" required maxlength=\"80\" value=\"");
            try highlight.escapeHtml(writer, board.name);
            try writer.writeAll("\"></label><label>Slug<input name=\"slug\" required maxlength=\"80\" value=\"");
            try highlight.escapeHtml(writer, board.slug);
            try writer.writeAll("\"></label><label>Description<input name=\"description\" maxlength=\"500\" value=\"");
            try highlight.escapeHtml(writer, board.description);
            try writer.print("\"></label><label>Order<input type=\"number\" name=\"sort_order\" min=\"0\" max=\"10000\" value=\"{d}\"></label>", .{board.sort_order});
            try writer.writeAll("<input type=\"hidden\" name=\"color\" value=\"");
            try highlight.escapeHtml(writer, board.color);
            try writer.writeAll("\"><button class=\"button button-primary\" type=\"submit\">Save</button></form>");
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

fn tryRenderIssueContentForm(
    writer: *std.Io.Writer,
    issue: models.Issue,
    csrf_input: []const u8,
) !void {
    try writer.writeAll("<section class=\"form-page\"><div><p class=\"kicker\">Admin editor</p><h1>Edit feedback.</h1><p>Changes are recorded in the issue activity history.</p></div>");
    try writer.print("<form class=\"stacked-form\" method=\"post\" action=\"/admin/issues/{d}/content\">", .{issue.id});
    try writer.writeAll(csrf_input);
    try writer.writeAll("<label>Title<input name=\"title\" required minlength=\"5\" maxlength=\"160\" value=\"");
    try highlight.escapeHtml(writer, issue.title);
    try writer.writeAll("\"></label><label>Description<textarea name=\"body\" required minlength=\"20\" maxlength=\"16384\" rows=\"10\">");
    try highlight.escapeHtml(writer, issue.body_markdown);
    try writer.writeAll("</textarea></label>");
    if (issue.kind == .bug) {
        try writer.writeAll("<div class=\"form-row\"><label>Steps to reproduce<textarea name=\"reproduction_steps\" required maxlength=\"8192\" rows=\"5\">");
        try optionalText(writer, issue.reproduction_steps);
        try writer.writeAll("</textarea></label><label>Actual behavior<textarea name=\"actual_behavior\" required maxlength=\"8192\" rows=\"5\">");
        try optionalText(writer, issue.actual_behavior);
        try writer.writeAll("</textarea></label></div><div class=\"form-row\"><label>Expected behavior<textarea name=\"expected_behavior\" maxlength=\"8192\" rows=\"4\">");
        try optionalText(writer, issue.expected_behavior);
        try writer.writeAll("</textarea></label><label>Environment<textarea name=\"environment\" maxlength=\"8192\" rows=\"4\">");
        try optionalText(writer, issue.environment);
        try writer.writeAll("</textarea></label></div>");
    }
    try writer.writeAll("<label>Evidence URL<input type=\"url\" name=\"evidence_url\" maxlength=\"512\" value=\"");
    try optionalText(writer, issue.evidence_url);
    try writer.writeAll("\"></label><div class=\"form-actions\"><a class=\"button button-quiet\" href=\"/admin\">Cancel</a><button class=\"button button-primary\" type=\"submit\">Save changes</button></div></form></section>");
}

fn optionalText(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| try highlight.escapeHtml(writer, text);
}

fn renderChangelogs(
    writer: *std.Io.Writer,
    entries: []const models.Changelog,
    current_page: u16,
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
            try writer.print("<button class=\"button button-quiet\" type=\"submit\">{s}</button></form>", .{
                if (entry.published_at_us == null) "Publish" else "Revert to draft",
            });
            try writer.print("<a class=\"button button-quiet\" href=\"/admin/changelog/{d}/edit\">Edit</a>", .{entry.id});
            try writer.writeAll("</article>");
        }
        try writer.writeAll("</div><nav class=\"pagination\" aria-label=\"Admin changelog pages\">");
        if (current_page > 1) try writer.print(
            "<a class=\"button button-quiet\" href=\"/admin?release_page={d}#changelog\">← Newer</a>",
            .{current_page - 1},
        );
        if (entries.len == 20) try writer.print(
            "<a class=\"button button-quiet\" href=\"/admin?release_page={d}#changelog\">Older →</a>",
            .{current_page + 1},
        );
        try writer.writeAll("</nav>");
    }
    try writer.writeAll("<form class=\"stacked-form admin-changelog-form\" method=\"post\" action=\"/admin/changelog\">");
    try writer.writeAll(csrf_input);
    try writer.writeAll("<div class=\"form-row\"><label>Title<input name=\"title\" required maxlength=\"160\"></label><label>Slug<input name=\"slug\" required pattern=\"[a-z0-9-]+\" maxlength=\"180\"></label></div>");
    try writer.writeAll("<div class=\"form-row\"><label>Version<input name=\"version\" maxlength=\"64\" placeholder=\"1.0.0\"></label><label>Tags<input name=\"tags\" maxlength=\"300\" placeholder=\"new-feature, improvement\"></label></div>");
    try writer.writeAll("<label>Completed issue IDs <span class=\"hint\">optional, comma separated</span><input name=\"issue_ids\" maxlength=\"500\" placeholder=\"42, 57\"></label>");
    try writer.writeAll("<label>Summary<input name=\"summary\" required maxlength=\"500\"></label>");
    try writer.writeAll("<label>Release notes<textarea name=\"body\" required maxlength=\"65536\" rows=\"10\" placeholder=\"Markdown and fenced code are supported.\"></textarea></label>");
    try writer.writeAll("<div class=\"form-actions\"><button class=\"button button-primary\" type=\"submit\">Save draft</button></div></form></section>");
}

fn renderChangelogEditForm(
    writer: *std.Io.Writer,
    entry: models.Changelog,
    linked: []const models.IssueSummary,
    csrf_input: []const u8,
) !void {
    try writer.writeAll("<section class=\"form-page\"><div><p class=\"kicker\">Changelog editor</p><h1>Edit release notes.</h1><p>Save the draft here, then publish explicitly from the admin dashboard.</p></div>");
    try writer.print("<form class=\"stacked-form\" method=\"post\" action=\"/admin/changelog/{d}/content\">", .{entry.id});
    try writer.writeAll(csrf_input);
    try writer.writeAll("<div class=\"form-row\"><label>Title<input name=\"title\" required maxlength=\"160\" value=\"");
    try highlight.escapeHtml(writer, entry.title);
    try writer.writeAll("\"></label><label>Slug<input name=\"slug\" required maxlength=\"180\" value=\"");
    try highlight.escapeHtml(writer, entry.slug);
    try writer.writeAll("\"></label></div><div class=\"form-row\"><label>Version<input name=\"version\" maxlength=\"64\" value=\"");
    try optionalText(writer, entry.version);
    try writer.writeAll("\"></label><label>Tags<input name=\"tags\" maxlength=\"300\" value=\"");
    try highlight.escapeHtml(writer, entry.tags_csv);
    try writer.writeAll("\"></label></div>");
    try writer.writeAll("<label>Completed issue IDs<input name=\"issue_ids\" maxlength=\"500\" value=\"");
    for (linked, 0..) |issue, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("{d}", .{issue.id});
    }
    try writer.writeAll("\"></label><label>Summary<input name=\"summary\" required maxlength=\"500\" value=\"");
    try highlight.escapeHtml(writer, entry.summary);
    try writer.writeAll("\"></label><label>Release notes<textarea name=\"body\" required maxlength=\"65536\" rows=\"12\">");
    try highlight.escapeHtml(writer, entry.body_markdown);
    try writer.writeAll("</textarea></label><div class=\"form-actions\"><a class=\"button button-quiet\" href=\"/admin#changelog\">Cancel</a><button class=\"button button-primary\" type=\"submit\">Save changes</button></div></form></section>");
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

fn parseIds(value: ?[]const u8, output: *[100]i64) ![]const i64 {
    const input = value orelse return &.{};
    var used: usize = 0;
    var iterator = std.mem.splitScalar(u8, input, ',');
    while (iterator.next()) |raw| {
        const text = std.mem.trim(u8, raw, " \t");
        if (text.len == 0) continue;
        if (used == output.len) return error.TooManyIds;
        const id = std.fmt.parseInt(i64, text, 10) catch return error.InvalidId;
        if (id <= 0) return error.InvalidId;
        for (output[0..used]) |existing| if (existing == id) return error.DuplicateId;
        output[used] = id;
        used += 1;
    }
    return output[0..used];
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (std.mem.trim(u8, text, " \t\r\n").len == 0) null else text;
}

fn parseOptionalId(value: ?[]const u8) !?i64 {
    const text = nonEmpty(value) orelse return null;
    const id = std.fmt.parseInt(i64, text, 10) catch return error.InvalidId;
    return if (id > 0) id else error.InvalidId;
}
