const std = @import("std");
const ploof = @import("ploof");
const app_state = @import("../../app_state.zig");
const domain = @import("../../domain.zig");
const models = @import("../../store.zig");
const csrf = @import("../csrf.zig");
const markdown = @import("../markdown.zig");
const page = @import("../page.zig");
const request = @import("../request.zig");
const highlight = @import("../highlight.zig");

const ListQuery = struct {
    page: u16 = 1,
    sort: models.IssueSort = .top,
    board_id: ?i64 = null,
    kind: ?domain.IssueKind = null,
    status: ?domain.IssueStatus = null,
    q: ?[]const u8 = null,
};

pub const ListDefinition = ploof.Endpoint(.{
    .query = ploof.Query.typed(ListQuery, .{
        .segments_max = 8,
        .unknown_fields = .reject,
    }),
});

const CreateForm = struct {
    board_id: i64,
    kind: domain.IssueKind,
    title: []const u8,
    body: []const u8,
    reproduction_steps: ?[]const u8 = null,
    expected_behavior: ?[]const u8 = null,
    actual_behavior: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    evidence_url: ?[]const u8 = null,
};

pub const CreateDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(CreateForm, .{
        .encoded_wire_bytes_max = 64 * 1024,
        .decoded_bytes_max = 64 * 1024,
        .segments_max = 16,
        .unknown_fields = .reject,
    }),
});

pub const VoteDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(struct { selected: bool }, .{
        .encoded_wire_bytes_max = 1024,
        .decoded_bytes_max = 1024,
        .segments_max = 2,
        .unknown_fields = .reject,
    }),
});

pub const CommentDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(struct {
        body: []const u8,
        parent_id: ?i64 = null,
    }, .{
        .encoded_wire_bytes_max = 8 * 1024,
        .decoded_bytes_max = 8 * 1024,
        .segments_max = 3,
        .unknown_fields = .reject,
    }),
});

pub fn home(context: *app_state.Context) app_state.Context.ResponseType {
    return renderIssueList(context, .{}, true);
}

pub fn list(
    context: *app_state.Context,
    input: ListDefinition.InputType,
) app_state.Context.ResponseType {
    return renderIssueList(context, input.query, false);
}

fn renderIssueList(
    context: *app_state.Context,
    query: ListQuery,
    show_hero: bool,
) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return context.textStatic(.service_unavailable, "Poof is not configured");
    const database = app_state.database(context) orelse
        return context.textStatic(.service_unavailable, "Database unavailable");
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const allocator = workspace.allocator();
    const current = request.principal(context, allocator) catch
        return context.empty(.service_unavailable);

    var board_storage: [32]models.Board = undefined;
    const boards = database.listBoards(allocator, &board_storage, false) catch
        return context.empty(.service_unavailable);
    var item_storage: [20]models.IssueSummary = undefined;
    const page_number = @max(query.page, 1);
    const result = database.listIssues(allocator, .{
        .board_id = query.board_id,
        .kind = query.kind,
        .status = query.status,
        .query = query.q,
        .sort = query.sort,
        .limit = 20,
        .offset = (@as(u32, page_number) - 1) * 20,
    }, &item_storage) catch return context.empty(.service_unavailable);

    var writer = workspace.writer();
    page.begin(
        &writer,
        settings,
        if (show_hero) "Shape what ships next" else "Feedback",
        .feedback,
        if (current) |*value| &value.user else null,
    ) catch return context.empty(.internal_server_error);
    if (show_hero) renderHero(&writer, settings) catch
        return context.empty(.internal_server_error);
    renderFilters(&writer, boards, query) catch
        return context.empty(.internal_server_error);
    renderIssueCards(&writer, result.items, result.total) catch
        return context.empty(.internal_server_error);
    page.end(&writer) catch return context.empty(.internal_server_error);
    return context.htmlBorrowed(.ok, workspace.rendered(&writer));
}

pub fn detail(context: *app_state.Context) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return context.textStatic(.service_unavailable, "Poof is not configured");
    const database = app_state.database(context) orelse
        return context.textStatic(.service_unavailable, "Database unavailable");
    const issue_id = request.parseIssueId(context) orelse return renderNotFound(context);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const allocator = workspace.allocator();
    const current = request.principal(context, allocator) catch
        return context.empty(.service_unavailable);
    const csrf_token: ?csrf.FormToken = if (current != null)
        csrf.prepare(context) catch return context.empty(.internal_server_error)
    else
        null;
    const issue = database.getIssue(allocator, issue_id) catch |problem| return switch (problem) {
        error.NotFound => renderNotFound(context),
        else => context.empty(.service_unavailable),
    };
    var comment_storage: [100]models.Comment = undefined;
    const comments = database.listComments(allocator, issue_id, &comment_storage) catch
        return context.empty(.service_unavailable);

    const requested_slug = context.request.param("slug") orelse "";
    if (!std.mem.eql(u8, requested_slug, issue.slug)) {
        var location: [256]u8 = undefined;
        const canonical = page.issueUrl(&location, issue.id, issue.slug) catch
            return context.empty(.internal_server_error);
        return request.redirect(context, .moved_permanently, canonical);
    }

    var writer = workspace.writer();
    page.begin(
        &writer,
        settings,
        issue.title,
        .feedback,
        if (current) |*value| &value.user else null,
    ) catch return context.empty(.internal_server_error);
    writer.writeAll("<article class=\"issue-detail\"><header class=\"issue-detail-header\">") catch
        return context.empty(.internal_server_error);
    writer.print("<p class=\"kicker\">{s} · #{d}</p><h1>", .{ issue.board_name, issue.id }) catch
        return context.empty(.internal_server_error);
    highlight.escapeHtml(&writer, issue.title) catch
        return context.empty(.internal_server_error);
    writer.writeAll("</h1><div class=\"issue-meta\">") catch
        return context.empty(.internal_server_error);
    page.statusBadge(&writer, issue.status) catch return context.empty(.internal_server_error);
    page.kindBadge(&writer, issue.kind) catch return context.empty(.internal_server_error);
    writer.print(
        "<span>{d} votes</span><span>{d} comments</span><span>by ",
        .{ issue.vote_count, issue.comment_count },
    ) catch return context.empty(.internal_server_error);
    highlight.escapeHtml(&writer, issue.author_name) catch
        return context.empty(.internal_server_error);
    writer.writeAll("</span></div></header><div class=\"issue-layout\"><div>") catch
        return context.empty(.internal_server_error);
    writer.writeAll("<section class=\"card markdown\">") catch
        return context.empty(.internal_server_error);
    markdown.render(&writer, issue.body_markdown) catch
        return context.empty(.internal_server_error);
    writer.writeAll("</section>") catch return context.empty(.internal_server_error);
    if (issue.kind == .bug) renderDiagnostics(&writer, issue) catch
        return context.empty(.internal_server_error);
    renderDiscussion(
        &writer,
        comments,
        if (csrf_token) |*token| token.hiddenInput() else null,
        issue.locked,
    ) catch
        return context.empty(.internal_server_error);
    writer.writeAll("</div><aside class=\"issue-actions\">") catch
        return context.empty(.internal_server_error);
    renderVoteForm(
        &writer,
        if (csrf_token) |*token| token.hiddenInput() else null,
        issue,
    ) catch
        return context.empty(.internal_server_error);
    if (issue.evidence_url) |url| {
        writer.writeAll("<a class=\"button button-quiet\" rel=\"nofollow noopener\" href=\"") catch
            return context.empty(.internal_server_error);
        highlight.escapeHtml(&writer, url) catch return context.empty(.internal_server_error);
        writer.writeAll("\">View evidence ↗</a>") catch
            return context.empty(.internal_server_error);
    }
    writer.writeAll("</aside></div></article>") catch
        return context.empty(.internal_server_error);
    page.end(&writer) catch return context.empty(.internal_server_error);
    var response = context.htmlBorrowed(.ok, workspace.rendered(&writer));
    if (csrf_token) |*token| csrf.attach(&response, token);
    return response;
}

pub fn newIssue(context: *app_state.Context) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return context.textStatic(.service_unavailable, "Poof is not configured");
    const database = app_state.database(context) orelse
        return context.textStatic(.service_unavailable, "Database unavailable");
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const allocator = workspace.allocator();
    const current = request.principal(context, allocator) catch
        return context.empty(.service_unavailable);
    if (current == null) return request.redirect(
        context,
        .see_other,
        "/auth/discord?return_to=/issues/new",
    );
    var boards_storage: [32]models.Board = undefined;
    const boards = database.listBoards(allocator, &boards_storage, false) catch
        return context.empty(.service_unavailable);
    var csrf_token = csrf.prepare(context) catch
        return context.empty(.internal_server_error);

    var writer = workspace.writer();
    page.begin(&writer, settings, "Share feedback", .feedback, &current.?.user) catch
        return context.empty(.internal_server_error);
    renderIssueForm(&writer, boards, csrf_token.hiddenInput()) catch
        return context.empty(.internal_server_error);
    page.end(&writer) catch return context.empty(.internal_server_error);
    var response = context.htmlBorrowed(.ok, workspace.rendered(&writer));
    csrf.attach(&response, &csrf_token);
    return response;
}

pub fn create(
    context: *app_state.Context,
    input: CreateDefinition.InputType,
) app_state.Context.ResponseType {
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const current = (request.principal(context, workspace.allocator()) catch
        return context.empty(.service_unavailable)) orelse
        return context.empty(.unauthorized);
    const form = input.body;
    const issue_id = database.createIssue(current.user.id, .{
        .board_id = form.board_id,
        .kind = form.kind,
        .title = form.title,
        .body = form.body,
        .reproduction_steps = nonEmpty(form.reproduction_steps),
        .expected_behavior = nonEmpty(form.expected_behavior),
        .actual_behavior = nonEmpty(form.actual_behavior),
        .environment = nonEmpty(form.environment),
        .evidence_url = nonEmpty(form.evidence_url),
    }) catch |problem| return switch (problem) {
        error.Conflict => context.textStatic(.unprocessable_entity, "Please check the feedback form."),
        else => context.empty(.service_unavailable),
    };
    var location: [64]u8 = undefined;
    const target = std.fmt.bufPrint(&location, "/issues/{d}", .{issue_id}) catch
        return context.empty(.internal_server_error);
    return request.redirect(context, .see_other, target);
}

pub fn vote(
    context: *app_state.Context,
    input: VoteDefinition.InputType,
) app_state.Context.ResponseType {
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    const issue_id = request.parseIssueId(context) orelse return context.empty(.not_found);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const current = (request.principal(context, workspace.allocator()) catch
        return context.empty(.service_unavailable)) orelse return context.empty(.unauthorized);
    database.setVote(issue_id, current.user.id, input.body.selected) catch
        return context.empty(.service_unavailable);
    return redirectToIssue(context, database, workspace.allocator(), issue_id, "votes");
}

pub fn comment(
    context: *app_state.Context,
    input: CommentDefinition.InputType,
) app_state.Context.ResponseType {
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    const issue_id = request.parseIssueId(context) orelse return context.empty(.not_found);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const current = (request.principal(context, workspace.allocator()) catch
        return context.empty(.service_unavailable)) orelse return context.empty(.unauthorized);
    const comment_id = database.addComment(
        issue_id,
        current.user.id,
        input.body.parent_id,
        input.body.body,
    ) catch |problem| return switch (problem) {
        error.Locked => context.textStatic(.conflict, "This discussion is locked."),
        error.Conflict => context.textStatic(.unprocessable_entity, "Comment is invalid."),
        else => context.empty(.service_unavailable),
    };
    var anchor: [48]u8 = undefined;
    const value = std.fmt.bufPrint(&anchor, "comment-{d}", .{comment_id}) catch "discussion";
    return redirectToIssue(context, database, workspace.allocator(), issue_id, value);
}

pub fn roadmap(context: *app_state.Context) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return context.textStatic(.service_unavailable, "Poof is not configured");
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const allocator = workspace.allocator();
    const current = request.principal(context, allocator) catch
        return context.empty(.service_unavailable);
    var planned_storage: [20]models.IssueSummary = undefined;
    var progress_storage: [20]models.IssueSummary = undefined;
    var completed_storage: [20]models.IssueSummary = undefined;
    const planned = database.listIssues(allocator, .{
        .status = .planned,
        .limit = 20,
    }, &planned_storage) catch return context.empty(.service_unavailable);
    const progress = database.listIssues(allocator, .{
        .status = .in_progress,
        .limit = 20,
    }, &progress_storage) catch return context.empty(.service_unavailable);
    const completed = database.listIssues(allocator, .{
        .status = .completed,
        .limit = 20,
    }, &completed_storage) catch return context.empty(.service_unavailable);

    var writer = workspace.writer();
    page.begin(
        &writer,
        settings,
        "Roadmap",
        .roadmap,
        if (current) |*value| &value.user else null,
    ) catch return context.empty(.internal_server_error);
    writer.writeAll("<section class=\"page-heading\"><p class=\"kicker\">Public roadmap</p>") catch
        return context.empty(.internal_server_error);
    writer.writeAll("<h1>See what we’re building.</h1><p>Every item comes directly from community feedback.</p></section>") catch
        return context.empty(.internal_server_error);
    writer.writeAll("<section class=\"roadmap-grid\">") catch
        return context.empty(.internal_server_error);
    renderRoadmapColumn(&writer, "Planned", planned.items) catch
        return context.empty(.internal_server_error);
    renderRoadmapColumn(&writer, "In progress", progress.items) catch
        return context.empty(.internal_server_error);
    renderRoadmapColumn(&writer, "Recently completed", completed.items) catch
        return context.empty(.internal_server_error);
    writer.writeAll("</section>") catch return context.empty(.internal_server_error);
    page.end(&writer) catch return context.empty(.internal_server_error);
    return context.htmlBorrowed(.ok, workspace.rendered(&writer));
}

pub fn changelog(context: *app_state.Context) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return context.textStatic(.service_unavailable, "Poof is not configured");
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const allocator = workspace.allocator();
    const current = request.principal(context, allocator) catch null;
    var changelog_storage: [100]models.Changelog = undefined;
    const entries = database.listChangelogs(
        allocator,
        true,
        &changelog_storage,
    ) catch return context.empty(.service_unavailable);
    var writer = workspace.writer();
    page.begin(
        &writer,
        settings,
        "Changelog",
        .changelog,
        if (current) |*value| &value.user else null,
    ) catch return context.empty(.internal_server_error);
    writer.writeAll("<section class=\"page-heading\"><p class=\"kicker\">Changelog</p>") catch
        return context.empty(.internal_server_error);
    writer.writeAll("<h1>Freshly shipped.</h1><p>Product updates will appear here as they are published.</p></section>") catch
        return context.empty(.internal_server_error);
    if (entries.len == 0) {
        writer.writeAll("<section class=\"empty-card\"><h2>No releases yet.</h2><p>The first changelog is being written.</p></section>") catch
            return context.empty(.internal_server_error);
    } else {
        writer.writeAll("<section class=\"changelog-list\">") catch
            return context.empty(.internal_server_error);
        for (entries) |entry| renderChangelogCard(&writer, entry) catch
            return context.empty(.internal_server_error);
        writer.writeAll("</section>") catch return context.empty(.internal_server_error);
    }
    page.end(&writer) catch return context.empty(.internal_server_error);
    return context.htmlBorrowed(.ok, workspace.rendered(&writer));
}

pub fn changelogDetail(context: *app_state.Context) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return context.textStatic(.service_unavailable, "Poof is not configured");
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    const slug = context.request.param("slug") orelse return context.empty(.not_found);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const allocator = workspace.allocator();
    const current = request.principal(context, allocator) catch null;
    const entry = database.getChangelogBySlug(allocator, slug, true) catch |problem| return switch (problem) {
        error.NotFound => context.empty(.not_found),
        else => context.empty(.service_unavailable),
    };
    var writer = workspace.writer();
    page.begin(
        &writer,
        settings,
        entry.title,
        .changelog,
        if (current) |*value| &value.user else null,
    ) catch return context.empty(.internal_server_error);
    writer.writeAll("<article class=\"changelog-detail\"><header><p class=\"kicker\">") catch
        return context.empty(.internal_server_error);
    if (entry.version) |version| {
        highlight.escapeHtml(&writer, version) catch return context.empty(.internal_server_error);
    } else {
        writer.writeAll("Product update") catch return context.empty(.internal_server_error);
    }
    writer.writeAll("</p><h1>") catch return context.empty(.internal_server_error);
    highlight.escapeHtml(&writer, entry.title) catch return context.empty(.internal_server_error);
    writer.writeAll("</h1><p>") catch return context.empty(.internal_server_error);
    highlight.escapeHtml(&writer, entry.summary) catch return context.empty(.internal_server_error);
    writer.writeAll("</p><span>Published by ") catch return context.empty(.internal_server_error);
    highlight.escapeHtml(&writer, entry.author_name) catch
        return context.empty(.internal_server_error);
    writer.writeAll("</span></header><div class=\"card markdown\">") catch
        return context.empty(.internal_server_error);
    markdown.render(&writer, entry.body_markdown) catch
        return context.empty(.internal_server_error);
    writer.writeAll("</div></article>") catch return context.empty(.internal_server_error);
    page.end(&writer) catch return context.empty(.internal_server_error);
    return context.htmlBorrowed(.ok, workspace.rendered(&writer));
}

fn renderHero(writer: *std.Io.Writer, settings: *const @import("../../config.zig").Config) !void {
    try writer.writeAll("<section class=\"hero\"><div class=\"eyebrow\"><span></span> Built in the open</div>");
    try writer.writeAll("<h1>Help shape what<br><em>ships next.</em></h1><p>");
    try highlight.escapeHtml(writer, settings.tagline);
    try writer.writeAll("</p><div class=\"hero-actions\">");
    try writer.writeAll("<a class=\"button button-primary\" href=\"/issues/new\">Share feedback →</a>");
    try writer.writeAll("<a class=\"button button-quiet\" href=\"/roadmap\">Explore the roadmap</a></div></section>");
}

fn renderChangelogCard(writer: *std.Io.Writer, entry: models.Changelog) !void {
    try writer.writeAll("<article class=\"changelog-card\"><div><p class=\"kicker\">");
    if (entry.version) |version| {
        try highlight.escapeHtml(writer, version);
    } else {
        try writer.writeAll("Product update");
    }
    try writer.writeAll("</p><h2><a href=\"/changelog/");
    try highlight.escapeHtml(writer, entry.slug);
    try writer.writeAll("\">");
    try highlight.escapeHtml(writer, entry.title);
    try writer.writeAll("</a></h2><p>");
    try highlight.escapeHtml(writer, entry.summary);
    try writer.writeAll("</p></div><span>by ");
    try highlight.escapeHtml(writer, entry.author_name);
    try writer.writeAll("</span></article>");
}

fn renderFilters(writer: *std.Io.Writer, boards: []const models.Board, query: ListQuery) !void {
    try writer.writeAll("<section class=\"feedback-shell\"><div class=\"section-heading\"><div>");
    try writer.writeAll("<p class=\"kicker\">Community board</p><h2>What should we build?</h2></div>");
    try writer.writeAll("<form class=\"filters\" method=\"get\" action=\"/issues\">");
    try writer.writeAll("<label><span class=\"sr-only\">Search</span><input type=\"search\" name=\"q\" placeholder=\"Search feedback\"");
    if (query.q) |value| {
        try writer.writeAll(" value=\"");
        try highlight.escapeHtml(writer, value);
        try writer.writeAll("\"");
    }
    try writer.writeAll("></label><select name=\"board_id\"><option value=\"\">All boards</option>");
    for (boards) |board| {
        try writer.print("<option value=\"{d}\"{s}>", .{
            board.id,
            if (query.board_id == board.id) " selected" else "",
        });
        try highlight.escapeHtml(writer, board.name);
        try writer.writeAll("</option>");
    }
    try writer.writeAll("</select><select name=\"sort\">");
    try writer.print("<option value=\"top\"{s}>Top</option>", .{
        if (query.sort == .top) " selected" else "",
    });
    try writer.print("<option value=\"newest\"{s}>Newest</option>", .{
        if (query.sort == .newest) " selected" else "",
    });
    try writer.writeAll("</select><button class=\"button button-quiet\" type=\"submit\">Filter</button></form></div>");
}

fn renderIssueCards(writer: *std.Io.Writer, items: []const models.IssueSummary, total: i64) !void {
    if (items.len == 0) {
        try writer.writeAll("<div class=\"empty-card\"><h3>The board is ready for its first idea.</h3>");
        try writer.writeAll("<p>Sign in with Discord and tell us what would make this product better.</p>");
        try writer.writeAll("<a class=\"text-link\" href=\"/issues/new\">Start the conversation →</a></div></section>");
        return;
    }
    try writer.print("<div class=\"issue-list\" data-total=\"{d}\">", .{total});
    for (items) |issue| try renderIssueCard(writer, issue);
    try writer.writeAll("</div></section>");
}

fn renderIssueCard(writer: *std.Io.Writer, issue: models.IssueSummary) !void {
    var url_storage: [256]u8 = undefined;
    const url = try page.issueUrl(&url_storage, issue.id, issue.slug);
    try writer.writeAll("<article class=\"issue-card\"><div class=\"vote-count\"><strong>");
    try writer.print("{d}", .{issue.vote_count});
    try writer.writeAll("</strong><span>votes</span></div><div class=\"issue-card-body\"><div class=\"issue-card-meta\">");
    try page.statusBadge(writer, issue.status);
    try page.kindBadge(writer, issue.kind);
    try writer.writeAll("</div><h3><a href=\"");
    try writer.writeAll(url);
    try writer.writeAll("\">");
    try highlight.escapeHtml(writer, issue.title);
    try writer.writeAll("</a></h3><p>");
    try highlight.escapeHtml(writer, issue.board_name);
    try writer.writeAll(" · by ");
    try highlight.escapeHtml(writer, issue.author_name);
    try writer.print(" · {d} comments</p></div></article>", .{issue.comment_count});
}

fn renderDiagnostics(writer: *std.Io.Writer, issue: models.Issue) !void {
    try writer.writeAll("<section class=\"card diagnostics\"><h2>Bug report</h2>");
    inline for (.{
        .{ "Steps to reproduce", issue.reproduction_steps },
        .{ "Expected behavior", issue.expected_behavior },
        .{ "Actual behavior", issue.actual_behavior },
        .{ "Environment", issue.environment },
    }) |entry| {
        if (entry[1]) |value| {
            try writer.writeAll("<h3>");
            try writer.writeAll(entry[0]);
            try writer.writeAll("</h3><div class=\"markdown\">");
            try markdown.render(writer, value);
            try writer.writeAll("</div>");
        }
    }
    try writer.writeAll("</section>");
}

fn renderDiscussion(
    writer: *std.Io.Writer,
    comments: []const models.Comment,
    csrf_input: ?[]const u8,
    locked: bool,
) !void {
    try writer.writeAll("<section class=\"discussion\" id=\"discussion\"><h2>Discussion</h2>");
    if (comments.len != 0) {
        try writer.writeAll("<div class=\"comment-list\">");
        for (comments) |comment_value| {
            if (comment_value.parent_id != null) continue;
            try renderComment(writer, comment_value, false);
            for (comments) |reply| {
                if (reply.parent_id != comment_value.id) continue;
                try renderComment(writer, reply, true);
            }
        }
        try writer.writeAll("</div>");
    }
    if (locked) {
        try writer.writeAll("<p class=\"notice\">This discussion is locked.</p></section>");
        return;
    }
    const hidden = csrf_input orelse {
        try writer.writeAll("<p class=\"notice\"><a href=\"/auth/discord\">Sign in with Discord</a> to comment.</p></section>");
        return;
    };
    try writer.writeAll("<form class=\"comment-form\" method=\"post\" action=\"comments\">");
    try writer.writeAll(hidden);
    try writer.writeAll("<label for=\"comment-body\">Add to the conversation</label>");
    try writer.writeAll("<textarea id=\"comment-body\" name=\"body\" required maxlength=\"4096\" rows=\"5\"></textarea>");
    try writer.writeAll("<button class=\"button button-primary\" type=\"submit\">Post comment</button></form></section>");
}

fn renderComment(writer: *std.Io.Writer, comment_value: models.Comment, reply: bool) !void {
    try writer.print(
        "<article class=\"comment{s}\" id=\"comment-{d}\"><header><strong>",
        .{ if (reply) " comment-reply" else "", comment_value.id },
    );
    try highlight.escapeHtml(writer, comment_value.author_name);
    try writer.writeAll("</strong></header><div class=\"markdown\">");
    try markdown.render(writer, comment_value.body_markdown);
    try writer.writeAll("</div></article>");
}

fn renderVoteForm(
    writer: *std.Io.Writer,
    csrf_input: ?[]const u8,
    issue: models.Issue,
) !void {
    const hidden = csrf_input orelse {
        try writer.writeAll("<a class=\"button button-primary\" href=\"/auth/discord\">Sign in to vote</a>");
        return;
    };
    try writer.print("<form method=\"post\" action=\"/issues/{d}/vote\">", .{issue.id});
    try writer.writeAll(hidden);
    try writer.writeAll("<input type=\"hidden\" name=\"selected\" value=\"true\">");
    try writer.print("<button class=\"button button-primary\" type=\"submit\">▲ Vote · {d}</button></form>", .{issue.vote_count});
}

fn renderIssueForm(
    writer: *std.Io.Writer,
    boards: []const models.Board,
    csrf_input: []const u8,
) !void {
    try writer.writeAll("<section class=\"form-page\"><div><p class=\"kicker\">Share feedback</p>");
    try writer.writeAll("<h1>What would make this better?</h1><p>Give enough context for the community to understand and reproduce it.</p></div>");
    try writer.writeAll("<form class=\"stacked-form\" method=\"post\" action=\"/issues\">");
    try writer.writeAll(csrf_input);
    try writer.writeAll("<div class=\"form-row\"><label>Type<select name=\"kind\" data-kind-select>");
    try writer.writeAll("<option value=\"feature\">Feature request</option><option value=\"improvement\">Improvement</option><option value=\"bug\">Bug report</option>");
    try writer.writeAll("</select></label><label>Board<select name=\"board_id\">");
    for (boards) |board| {
        try writer.print("<option value=\"{d}\">", .{board.id});
        try highlight.escapeHtml(writer, board.name);
        try writer.writeAll("</option>");
    }
    try writer.writeAll("</select></label></div>");
    try writer.writeAll("<label>Title<input name=\"title\" required minlength=\"5\" maxlength=\"160\" placeholder=\"A concise summary\"></label>");
    try writer.writeAll("<label>Description<textarea name=\"body\" required minlength=\"20\" maxlength=\"16384\" rows=\"8\" placeholder=\"What problem does this solve? Markdown and code fences are supported.\"></textarea></label>");
    try writer.writeAll("<fieldset class=\"bug-fields\" data-bug-fields><legend>Bug details</legend>");
    try writer.writeAll("<label>Steps to reproduce<textarea name=\"reproduction_steps\" maxlength=\"8192\" rows=\"5\"></textarea></label>");
    try writer.writeAll("<label>Expected behavior<textarea name=\"expected_behavior\" maxlength=\"8192\" rows=\"3\"></textarea></label>");
    try writer.writeAll("<label>Actual behavior<textarea name=\"actual_behavior\" maxlength=\"8192\" rows=\"3\"></textarea></label>");
    try writer.writeAll("<label>Environment and version<textarea name=\"environment\" maxlength=\"8192\" rows=\"3\"></textarea></label></fieldset>");
    try writer.writeAll("<label>Evidence URL <span class=\"hint\">optional</span><input type=\"url\" name=\"evidence_url\" maxlength=\"512\" placeholder=\"https://...\"></label>");
    try writer.writeAll("<div class=\"form-actions\"><a class=\"button button-quiet\" href=\"/\">Cancel</a>");
    try writer.writeAll("<button class=\"button button-primary\" type=\"submit\">Submit feedback</button></div></form></section>");
}

fn renderRoadmapColumn(
    writer: *std.Io.Writer,
    title: []const u8,
    issues: []const models.IssueSummary,
) !void {
    try writer.writeAll("<div class=\"roadmap-column\"><header><h2>");
    try writer.writeAll(title);
    try writer.print("</h2><span>{d}</span></header>", .{issues.len});
    if (issues.len == 0) {
        try writer.writeAll("<p class=\"roadmap-empty\">Nothing here yet.</p>");
    } else {
        for (issues) |issue| {
            var url: [256]u8 = undefined;
            try writer.writeAll("<a class=\"roadmap-card\" href=\"");
            try writer.writeAll(try page.issueUrl(&url, issue.id, issue.slug));
            try writer.writeAll("\"><strong>");
            try highlight.escapeHtml(writer, issue.title);
            try writer.writeAll("</strong><span>");
            try highlight.escapeHtml(writer, issue.board_name);
            try writer.print(" · {d} votes</span></a>", .{issue.vote_count});
        }
    }
    try writer.writeAll("</div>");
}

fn redirectToIssue(
    context: *app_state.Context,
    database: anytype,
    allocator: std.mem.Allocator,
    issue_id: i64,
    anchor: []const u8,
) app_state.Context.ResponseType {
    const issue = database.getIssue(allocator, issue_id) catch
        return context.empty(.not_found);
    var base: [256]u8 = undefined;
    const url = page.issueUrl(&base, issue.id, issue.slug) catch
        return context.empty(.internal_server_error);
    var location: [320]u8 = undefined;
    const target = std.fmt.bufPrint(&location, "{s}#{s}", .{ url, anchor }) catch
        return context.empty(.internal_server_error);
    return request.redirect(context, .see_other, target);
}

fn renderNotFound(context: *app_state.Context) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return context.textStatic(.not_found, "Not found");
    var workspace = request.Workspace.init(context) catch
        return context.empty(.not_found);
    var writer = workspace.writer();
    page.errorPage(&writer, settings, "404", "Feedback not found", "The requested item may have moved or been removed.") catch
        return context.empty(.not_found);
    return context.htmlBorrowed(.not_found, workspace.rendered(&writer));
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (std.mem.trim(u8, text, " \t\r\n").len == 0) null else text;
}
