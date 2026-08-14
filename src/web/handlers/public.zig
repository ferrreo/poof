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
    board_id: i64 = 0,
    kind: enum { all, feature, improvement, bug } = .all,
    status: enum { all, pending, reviewing, planned, in_progress, completed, closed } = .all,
    q: ?[]const u8 = null,
};

pub const ListDefinition = ploof.Endpoint(.{
    .query = ploof.Query.typed(ListQuery, .{
        .segments_max = 8,
        .unknown_fields = .reject,
    }),
});

pub const DetailDefinition = ploof.Endpoint(.{
    .query = ploof.Query.typed(struct { comments_page: u16 = 1 }, .{
        .segments_max = 2,
        .unknown_fields = .reject,
    }),
});

pub const ChangelogDefinition = ploof.Endpoint(.{
    .query = ploof.Query.typed(struct { page: u16 = 1 }, .{
        .segments_max = 2,
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

pub fn favicon(context: *app_state.Context) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse return context.empty(.not_found);
    const database = app_state.database(context) orelse return context.empty(.not_found);
    var workspace = request.Workspace.init(context) catch return context.empty(.not_found);
    const branding = page.resolveBranding(workspace.allocator(), database, settings);
    const logo = branding.logo_url orelse return context.empty(.not_found);
    return request.redirect(context, .temporary_redirect, logo);
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
        return page.htmlFailure(context, .service_unavailable, "503", "Unavailable", "Poof is not configured.");
    const database = app_state.database(context) orelse
        return page.htmlFailure(context, .service_unavailable, "503", "Unavailable", "Database unavailable.");
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
        .board_id = if (query.board_id > 0) query.board_id else null,
        .kind = switch (query.kind) {
            .all => null,
            .feature => .feature,
            .improvement => .improvement,
            .bug => .bug,
        },
        .status = switch (query.status) {
            .all => null,
            .pending => .pending,
            .reviewing => .reviewing,
            .planned => .planned,
            .in_progress => .in_progress,
            .completed => .completed,
            .closed => .closed,
        },
        .query = query.q,
        .sort = query.sort,
        .limit = 20,
        .offset = (@as(u32, page_number) - 1) * 20,
    }, &item_storage) catch return context.empty(.service_unavailable);

    const branding = page.resolveBranding(allocator, database, settings);
    var writer = workspace.writer();
    page.begin(
        &writer,
        branding,
        "Feedback",
        .feedback,
        if (current) |*value| &value.user else null,
    ) catch return context.empty(.internal_server_error);
    if (show_hero) renderHero(&writer, branding) catch
        return context.empty(.internal_server_error);
    renderFilters(&writer, boards, query) catch
        return context.empty(.internal_server_error);
    renderIssueCards(&writer, result.items, result.total) catch
        return context.empty(.internal_server_error);
    renderPager(&writer, query, result.total) catch
        return context.empty(.internal_server_error);
    writer.writeAll("</section>") catch return context.empty(.internal_server_error);
    page.end(&writer, &workspace) catch return context.empty(.internal_server_error);
    return context.htmlBorrowed(.ok, workspace.rendered(&writer));
}

pub fn detail(
    context: *app_state.Context,
    input: DetailDefinition.InputType,
) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return page.htmlFailure(context, .service_unavailable, "503", "Unavailable", "Poof is not configured.");
    const database = app_state.database(context) orelse
        return page.htmlFailure(context, .service_unavailable, "503", "Unavailable", "Database unavailable.");
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
    const viewer_voted = if (current) |value|
        database.hasVote(issue_id, value.user.id) catch
            return context.empty(.service_unavailable)
    else
        false;
    const comments_page = @max(input.query.comments_page, 1);
    var comment_storage: [5]models.Comment = undefined;
    const comments = database.listCommentsPage(
        allocator,
        issue_id,
        (@as(u32, comments_page) - 1) * 5,
        &comment_storage,
    ) catch
        return context.empty(.service_unavailable);

    const requested_slug = context.request.param("slug") orelse "";
    if (!std.mem.eql(u8, requested_slug, issue.slug)) {
        var location: [256]u8 = undefined;
        const canonical = page.issueUrl(&location, issue.id, issue.slug) catch
            return context.empty(.internal_server_error);
        return request.redirect(context, .moved_permanently, canonical);
    }

    const branding = page.resolveBranding(allocator, database, settings);
    var writer = workspace.writer();
    page.begin(
        &writer,
        branding,
        issue.title,
        .feedback,
        if (current) |*value| &value.user else null,
    ) catch return context.empty(.internal_server_error);
    writer.writeAll("<article class=\"issue-detail\"><header class=\"issue-detail-header\">") catch
        return context.empty(.internal_server_error);
    writer.writeAll("<p class=\"kicker\">") catch
        return context.empty(.internal_server_error);
    highlight.escapeHtml(&writer, issue.board_name) catch
        return context.empty(.internal_server_error);
    writer.print(" · #{d}</p><h1>", .{issue.id}) catch
        return context.empty(.internal_server_error);
    highlight.escapeHtml(&writer, issue.title) catch
        return context.empty(.internal_server_error);
    writer.writeAll("</h1><div class=\"issue-meta\">") catch
        return context.empty(.internal_server_error);
    page.statusBadge(&writer, issue.status) catch return context.empty(.internal_server_error);
    page.kindBadge(&writer, issue.kind) catch return context.empty(.internal_server_error);
    page.priorityBadge(&writer, issue.priority) catch return context.empty(.internal_server_error);
    writer.print(
        "<span>{d} votes</span><span>{d} comments</span><span>by ",
        .{ issue.vote_count, issue.comment_count },
    ) catch return context.empty(.internal_server_error);
    highlight.escapeHtml(&writer, issue.author_name) catch
        return context.empty(.internal_server_error);
    writer.writeAll("</span></div>") catch return context.empty(.internal_server_error);
    if (issue.duplicate_of_id) |target| {
        writer.print(
            "<p class=\"notice duplicate-notice\">This feedback is a duplicate of <a href=\"/issues/{d}\">issue #{d}</a>.</p>",
            .{ target, target },
        ) catch return context.empty(.internal_server_error);
    }
    writer.writeAll("</header><div class=\"issue-layout\"><div>") catch
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
        issue.comment_count,
        comments_page,
        issue,
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
        viewer_voted,
    ) catch
        return context.empty(.internal_server_error);
    if (issue.evidence_url) |url| {
        if (page.looksLikeImageUrl(url)) {
            writer.writeAll("<figure class=\"evidence-figure\"><img class=\"markdown-image\" src=\"") catch
                return context.empty(.internal_server_error);
            highlight.escapeHtml(&writer, url) catch return context.empty(.internal_server_error);
            writer.writeAll("\" alt=\"Evidence\" loading=\"lazy\"><figcaption><a class=\"text-link\" rel=\"nofollow noopener\" href=\"") catch
                return context.empty(.internal_server_error);
            highlight.escapeHtml(&writer, url) catch return context.empty(.internal_server_error);
            writer.writeAll("\">Open evidence ↗</a></figcaption></figure>") catch
                return context.empty(.internal_server_error);
        } else {
            writer.writeAll("<a class=\"button button-quiet\" rel=\"nofollow noopener\" href=\"") catch
                return context.empty(.internal_server_error);
            highlight.escapeHtml(&writer, url) catch return context.empty(.internal_server_error);
            writer.writeAll("\">View evidence ↗</a>") catch
                return context.empty(.internal_server_error);
        }
    }
    writer.writeAll("</aside></div></article>") catch
        return context.empty(.internal_server_error);
    page.end(&writer, &workspace) catch return context.empty(.internal_server_error);
    var response = context.htmlBorrowed(.ok, workspace.rendered(&writer));
    if (csrf_token) |*token| csrf.attach(&response, token);
    return response;
}

pub fn newIssue(context: *app_state.Context) app_state.Context.ResponseType {
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
    return issueFormResponse(
        context,
        &workspace,
        &current.?.user,
        emptyCreateForm(),
        null,
        .ok,
    );
}

pub fn create(
    context: *app_state.Context,
    input: CreateDefinition.InputType,
) app_state.Context.ResponseType {
    const database = app_state.database(context) orelse
        return page.htmlFailure(context, .service_unavailable, "503", "Unavailable", "Database unavailable.");
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const current = (request.principal(context, workspace.allocator()) catch
        return context.empty(.service_unavailable)) orelse
        return page.htmlFailure(context, .unauthorized, "401", "Sign in required", "Sign in with Discord to submit feedback.");
    const form = input.body;
    const payload = domain.CreateIssue{
        .board_id = form.board_id,
        .kind = form.kind,
        .title = form.title,
        .body = form.body,
        .reproduction_steps = nonEmpty(form.reproduction_steps),
        .expected_behavior = nonEmpty(form.expected_behavior),
        .actual_behavior = nonEmpty(form.actual_behavior),
        .environment = nonEmpty(form.environment),
        .evidence_url = nonEmpty(form.evidence_url),
    };
    if (!(database.allowUserAction(
        current.user.id,
        "issue_create",
        5,
        60,
    ) catch return context.empty(.service_unavailable))) {
        return issueFormResponse(
            context,
            &workspace,
            &current.user,
            form,
            "Please wait before creating more feedback.",
            .too_many_requests,
        );
    }
    domain.validateCreateIssue(payload) catch |err| {
        std.log.warn(
            "create issue rejected: {s} board_id={d} kind={s} title_len={d} body_len={d}",
            .{
                @errorName(err),
                payload.board_id,
                @tagName(payload.kind),
                payload.title.len,
                payload.body.len,
            },
        );
        return issueFormResponse(
            context,
            &workspace,
            &current.user,
            form,
            createIssueErrorMessage(err),
            .unprocessable_entity,
        );
    };
    const issue_id = database.createIssue(current.user.id, payload) catch |problem| {
        std.log.warn("create issue failed: {s}", .{@errorName(problem)});
        return switch (problem) {
            error.Conflict => issueFormResponse(
                context,
                &workspace,
                &current.user,
                form,
                "Could not save this feedback. Check the board and try again.",
                .unprocessable_entity,
            ),
            else => issueFormResponse(
                context,
                &workspace,
                &current.user,
                form,
                "Could not save this feedback. Try again in a moment.",
                .service_unavailable,
            ),
        };
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
    if (!(database.allowUserAction(
        current.user.id,
        "vote_change",
        60,
        60,
    ) catch return context.empty(.service_unavailable))) {
        return page.htmlFailure(
            context,
            .too_many_requests,
            "429",
            "Slow down",
            "Please wait before voting again.",
        );
    }
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
    if (!(database.allowUserAction(
        current.user.id,
        "comment_create",
        20,
        60,
    ) catch return context.empty(.service_unavailable))) {
        return page.htmlFailure(
            context,
            .too_many_requests,
            "429",
            "Slow down",
            "Please wait before commenting again.",
        );
    }
    const comment_id = database.addComment(
        issue_id,
        current.user.id,
        input.body.parent_id,
        input.body.body,
    ) catch |problem| return switch (problem) {
        error.Locked => page.htmlFailure(
            context,
            .conflict,
            "423",
            "Discussion locked",
            "This discussion is locked.",
        ),
        error.Conflict => page.htmlFailure(
            context,
            .unprocessable_entity,
            "422",
            "Comment invalid",
            "Comment is invalid. Check the length and try again.",
        ),
        else => context.empty(.service_unavailable),
    };
    var anchor: [48]u8 = undefined;
    const value = std.fmt.bufPrint(&anchor, "comment-{d}", .{comment_id}) catch "discussion";
    return redirectToIssue(context, database, workspace.allocator(), issue_id, value);
}

pub fn me(context: *app_state.Context) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return context.empty(.service_unavailable);
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const allocator = workspace.allocator();
    const current = (request.principal(context, allocator) catch
        return context.empty(.service_unavailable)) orelse
        return request.redirect(context, .see_other, "/auth/discord?return_to=/me");
    var issue_storage: [100]models.IssueSummary = undefined;
    const issues = database.listUserIssues(
        allocator,
        current.user.id,
        &issue_storage,
    ) catch return context.empty(.service_unavailable);
    const csrf_token = csrf.prepare(context) catch
        return context.empty(.internal_server_error);
    const branding = page.resolveBranding(allocator, database, settings);
    var writer = workspace.writer();
    page.begin(&writer, branding, "My activity", .none, &current.user) catch
        return context.empty(.internal_server_error);
    writer.writeAll("<section class=\"profile-page\"><header><h1>") catch
        return context.empty(.internal_server_error);
    highlight.escapeHtml(
        &writer,
        current.user.display_name orelse current.user.username,
    ) catch return context.empty(.internal_server_error);
    writer.writeAll("</h1><p>Feedback you filed or voted on.</p><div class=\"profile-actions\">") catch
        return context.empty(.internal_server_error);
    writer.writeAll("<a class=\"button button-quiet\" href=\"/settings/developer/tokens\">Developer tokens</a>") catch
        return context.empty(.internal_server_error);
    writer.writeAll("<form method=\"post\" action=\"/auth/logout\">") catch
        return context.empty(.internal_server_error);
    writer.writeAll(csrf_token.hiddenInput()) catch return context.empty(.internal_server_error);
    writer.writeAll("<button class=\"button button-quiet\" type=\"submit\">Sign out</button></form></div></header>") catch
        return context.empty(.internal_server_error);
    if (issues.len == 0) {
        writer.writeAll("<div class=\"empty-card\"><h2>No activity yet.</h2><p>File or vote on an item to see it here.</p></div>") catch
            return context.empty(.internal_server_error);
    } else {
        writer.writeAll("<div class=\"issue-list\">") catch
            return context.empty(.internal_server_error);
        for (issues) |issue| renderIssueCard(&writer, issue) catch
            return context.empty(.internal_server_error);
        writer.writeAll("</div>") catch return context.empty(.internal_server_error);
    }
    writer.writeAll("</section>") catch return context.empty(.internal_server_error);
    page.end(&writer, &workspace) catch return context.empty(.internal_server_error);
    var response = context.htmlBorrowed(.ok, workspace.rendered(&writer));
    csrf.attach(&response, &csrf_token);
    return response;
}

pub fn roadmap(context: *app_state.Context) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return page.htmlFailure(context, .service_unavailable, "503", "Unavailable", "Poof is not configured.");
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
        .completed_since_days = 90,
        .limit = 20,
    }, &completed_storage) catch return context.empty(.service_unavailable);

    const branding = page.resolveBranding(allocator, database, settings);
    var writer = workspace.writer();
    page.begin(
        &writer,
        branding,
        "Roadmap",
        .roadmap,
        if (current) |*value| &value.user else null,
    ) catch return context.empty(.internal_server_error);
    writer.writeAll("<section class=\"page-heading\">") catch
        return context.empty(.internal_server_error);
    writer.writeAll("<h1>Roadmap</h1><p>Planned, in progress, and recently completed. These columns query the issue tracker.</p></section>") catch
        return context.empty(.internal_server_error);
    writer.writeAll("<section class=\"roadmap-grid\">") catch
        return context.empty(.internal_server_error);
    renderRoadmapColumn(&writer, "Planned", planned) catch
        return context.empty(.internal_server_error);
    renderRoadmapColumn(&writer, "In progress", progress) catch
        return context.empty(.internal_server_error);
    renderRoadmapColumn(&writer, "Recently completed", completed) catch
        return context.empty(.internal_server_error);
    writer.writeAll("</section>") catch return context.empty(.internal_server_error);
    page.end(&writer, &workspace) catch return context.empty(.internal_server_error);
    return context.htmlBorrowed(.ok, workspace.rendered(&writer));
}

pub fn changelog(
    context: *app_state.Context,
    input: ChangelogDefinition.InputType,
) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return page.htmlFailure(context, .service_unavailable, "503", "Unavailable", "Poof is not configured.");
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const allocator = workspace.allocator();
    const current = request.principal(context, allocator) catch null;
    const changelog_page = @max(input.query.page, 1);
    var changelog_storage: [20]models.Changelog = undefined;
    const entries = database.listChangelogsPage(
        allocator,
        true,
        20,
        (@as(u32, changelog_page) - 1) * 20,
        &changelog_storage,
    ) catch return context.empty(.service_unavailable);
    const branding = page.resolveBranding(allocator, database, settings);
    var writer = workspace.writer();
    page.begin(
        &writer,
        branding,
        "Changelog",
        .changelog,
        if (current) |*value| &value.user else null,
    ) catch return context.empty(.internal_server_error);
    writer.writeAll("<section class=\"page-heading\">") catch
        return context.empty(.internal_server_error);
    writer.writeAll("<h1>Release notes</h1><p>Published updates, newest first.</p></section>") catch
        return context.empty(.internal_server_error);
    if (entries.len == 0) {
        writer.writeAll("<section class=\"empty-card\"><h2>No releases yet.</h2><p>Drafts stay off this page until they are published.</p></section>") catch
            return context.empty(.internal_server_error);
    } else {
        writer.writeAll("<section class=\"changelog-list\">") catch
            return context.empty(.internal_server_error);
        for (entries) |entry| renderChangelogCard(&writer, entry) catch
            return context.empty(.internal_server_error);
        writer.writeAll("<nav class=\"pagination\" aria-label=\"Changelog pages\">") catch
            return context.empty(.internal_server_error);
        if (changelog_page > 1) writer.print(
            "<a class=\"button button-quiet\" href=\"/changelog?page={d}\">← Newer</a>",
            .{changelog_page - 1},
        ) catch return context.empty(.internal_server_error);
        if (entries.len == 20) writer.print(
            "<a class=\"button button-quiet\" href=\"/changelog?page={d}\">Older →</a>",
            .{changelog_page + 1},
        ) catch return context.empty(.internal_server_error);
        writer.writeAll("</nav></section>") catch return context.empty(.internal_server_error);
    }
    page.end(&writer, &workspace) catch return context.empty(.internal_server_error);
    return context.htmlBorrowed(.ok, workspace.rendered(&writer));
}

pub fn changelogDetail(context: *app_state.Context) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return page.htmlFailure(context, .service_unavailable, "503", "Unavailable", "Poof is not configured.");
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
    var linked_storage: [100]models.IssueSummary = undefined;
    const linked_issues = database.listChangelogIssues(
        allocator,
        entry.id,
        &linked_storage,
    ) catch return context.empty(.service_unavailable);
    const branding = page.resolveBranding(allocator, database, settings);
    var writer = workspace.writer();
    page.begin(
        &writer,
        branding,
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
    writer.writeAll("</div>") catch return context.empty(.internal_server_error);
    if (linked_issues.len != 0) {
        writer.writeAll("<section class=\"built-from\"><h2>Linked feedback</h2><div class=\"issue-list\">") catch
            return context.empty(.internal_server_error);
        for (linked_issues) |issue| renderIssueCard(&writer, issue) catch
            return context.empty(.internal_server_error);
        writer.writeAll("</div></section>") catch
            return context.empty(.internal_server_error);
    }
    writer.writeAll("</article>") catch return context.empty(.internal_server_error);
    page.end(&writer, &workspace) catch return context.empty(.internal_server_error);
    return context.htmlBorrowed(.ok, workspace.rendered(&writer));
}

fn renderHero(writer: *std.Io.Writer, branding: models.SiteBranding) !void {
    try writer.writeAll("<section class=\"hero\"><p class=\"lede\">");
    try highlight.escapeHtml(writer, branding.tagline);
    try writer.writeAll("</p><div class=\"hero-actions\">");
    try writer.writeAll("<a class=\"button button-primary\" href=\"/issues/new\">New feedback</a>");
    try writer.writeAll("<a class=\"button button-quiet\" href=\"/roadmap\">Roadmap</a></div></section>");
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
    try writer.writeAll("<section class=\"feedback-shell\"><div class=\"section-heading\">");
    try writer.writeAll("<h2>Feedback</h2>");
    try writer.writeAll("<form class=\"filters\" method=\"get\" action=\"/issues\">");
    try writer.writeAll("<label><span class=\"sr-only\">Search</span><input type=\"search\" name=\"q\" placeholder=\"Search feedback\"");
    if (query.q) |value| {
        try writer.writeAll(" value=\"");
        try highlight.escapeHtml(writer, value);
        try writer.writeAll("\"");
    }
    try writer.writeAll("></label><select name=\"board_id\"><option value=\"0\">All boards</option>");
    for (boards) |board| {
        try writer.print("<option value=\"{d}\"{s}>", .{
            board.id,
            if (query.board_id == board.id) " selected" else "",
        });
        try highlight.escapeHtml(writer, board.name);
        try writer.writeAll("</option>");
    }
    try writer.writeAll("</select><select name=\"kind\"><option value=\"all\">All types</option>");
    inline for (std.meta.tags(domain.IssueKind)) |kind| {
        try writer.print("<option value=\"{s}\"{s}>{s}</option>", .{
            @tagName(kind),
            if (std.mem.eql(u8, @tagName(query.kind), @tagName(kind))) " selected" else "",
            kind.label(),
        });
    }
    try writer.writeAll("</select><select name=\"status\"><option value=\"all\">All statuses</option>");
    inline for (std.meta.tags(domain.IssueStatus)) |status| {
        try writer.print("<option value=\"{s}\"{s}>{s}</option>", .{
            @tagName(status),
            if (std.mem.eql(u8, @tagName(query.status), @tagName(status))) " selected" else "",
            status.label(),
        });
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
        try writer.writeAll("<div class=\"empty-card\"><h3>No feedback yet.</h3>");
        try writer.writeAll("<p>Sign in with Discord to file the first item.</p>");
        try writer.writeAll("<a class=\"text-link\" href=\"/issues/new\">New feedback</a></div>");
        return;
    }
    try writer.print("<div class=\"issue-list\" data-total=\"{d}\">", .{total});
    for (items) |issue| try renderIssueCard(writer, issue);
    try writer.writeAll("</div>");
}

fn renderPager(writer: *std.Io.Writer, query: ListQuery, total: i64) !void {
    const current = @max(query.page, 1);
    if (current == 1 and total <= 20) return;
    try writer.writeAll("<nav class=\"pagination\" aria-label=\"Feedback pages\">");
    if (current > 1) try renderPageForm(writer, query, current - 1, "← Previous");
    if (@as(i64, current) * 20 < total) try renderPageForm(writer, query, current + 1, "Next →");
    try writer.writeAll("</nav>");
}

fn renderPageForm(
    writer: *std.Io.Writer,
    query: ListQuery,
    target_page: u16,
    label: []const u8,
) !void {
    try writer.writeAll("<form method=\"get\" action=\"/issues\">");
    try writer.print("<input type=\"hidden\" name=\"page\" value=\"{d}\">", .{target_page});
    try writer.print("<input type=\"hidden\" name=\"sort\" value=\"{s}\">", .{@tagName(query.sort)});
    try writer.print("<input type=\"hidden\" name=\"board_id\" value=\"{d}\">", .{query.board_id});
    try writer.print("<input type=\"hidden\" name=\"kind\" value=\"{s}\">", .{@tagName(query.kind)});
    try writer.print("<input type=\"hidden\" name=\"status\" value=\"{s}\">", .{@tagName(query.status)});
    if (query.q) |value| {
        try writer.writeAll("<input type=\"hidden\" name=\"q\" value=\"");
        try highlight.escapeHtml(writer, value);
        try writer.writeAll("\">");
    }
    try writer.writeAll("<button class=\"button button-quiet\" type=\"submit\">");
    try writer.writeAll(label);
    try writer.writeAll("</button></form>");
}

fn renderIssueCard(writer: *std.Io.Writer, issue: models.IssueSummary) !void {
    var url_storage: [256]u8 = undefined;
    const url = try page.issueUrl(&url_storage, issue.id, issue.slug);
    try writer.writeAll("<article class=\"issue-card\"><div class=\"vote-count\"><strong>");
    try writer.print("{d}", .{issue.vote_count});
    try writer.writeAll("</strong><span>votes</span></div><div class=\"issue-card-body\"><div class=\"issue-card-meta\">");
    try page.statusBadge(writer, issue.status);
    try page.kindBadge(writer, issue.kind);
    try page.priorityBadge(writer, issue.priority);
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
    comment_total: i64,
    comments_page: u16,
    issue: models.Issue,
    csrf_input: ?[]const u8,
    locked: bool,
) !void {
    try writer.writeAll("<section class=\"discussion\" id=\"discussion\"><h2>Discussion</h2>");
    if (comments.len != 0) {
        try writer.writeAll("<div class=\"comment-list\">");
        for (comments) |comment_value| {
            if (comment_value.parent_id != null) continue;
            try renderComment(writer, comment_value, false, csrf_input);
            for (comments) |reply| {
                if (reply.parent_id != comment_value.id) continue;
                try renderComment(writer, reply, true, null);
            }
        }
        for (comments) |reply| {
            const parent_id = reply.parent_id orelse continue;
            var parent_visible = false;
            for (comments) |candidate| {
                if (candidate.id == parent_id and candidate.parent_id == null) {
                    parent_visible = true;
                    break;
                }
            }
            if (!parent_visible) try renderComment(writer, reply, true, null);
        }
        try writer.writeAll("</div>");
        if (comment_total > 5) {
            try writer.writeAll("<nav class=\"pagination\" aria-label=\"Comment pages\">");
            var base: [256]u8 = undefined;
            const url = try page.issueUrl(&base, issue.id, issue.slug);
            if (comments_page > 1) {
                try writer.print("<a class=\"button button-quiet\" href=\"{s}?comments_page={d}#discussion\">← Newer</a>", .{
                    url,
                    comments_page - 1,
                });
            }
            if (@as(i64, comments_page) * 5 < comment_total) {
                try writer.print("<a class=\"button button-quiet\" href=\"{s}?comments_page={d}#discussion\">Older →</a>", .{
                    url,
                    comments_page + 1,
                });
            }
            try writer.writeAll("</nav>");
        }
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
    try writer.writeAll("<label for=\"comment-body\">Add to the conversation <span class=\"hint\">Markdown and ![alt](https://...) images</span></label>");
    try writer.writeAll("<textarea id=\"comment-body\" name=\"body\" required maxlength=\"4096\" rows=\"5\"></textarea>");
    try page.imageUploadControl(writer, .markdown);
    try writer.writeAll("<button class=\"button button-primary\" type=\"submit\">Post comment</button></form></section>");
}

fn renderComment(
    writer: *std.Io.Writer,
    comment_value: models.Comment,
    reply: bool,
    csrf_input: ?[]const u8,
) !void {
    try writer.print(
        "<article class=\"comment{s}\" id=\"comment-{d}\"><header><strong>",
        .{ if (reply) " comment-reply" else "", comment_value.id },
    );
    try highlight.escapeHtml(writer, comment_value.author_name);
    try writer.writeAll("</strong></header><div class=\"markdown\">");
    try markdown.render(writer, comment_value.body_markdown);
    try writer.writeAll("</div>");
    if (csrf_input) |hidden| {
        try writer.writeAll("<details class=\"reply-composer\"><summary>Reply</summary><form method=\"post\" action=\"comments\">");
        try writer.writeAll(hidden);
        try writer.print("<input type=\"hidden\" name=\"parent_id\" value=\"{d}\">", .{comment_value.id});
        try writer.writeAll("<textarea name=\"body\" required maxlength=\"4096\" rows=\"3\" aria-label=\"Reply\"></textarea>");
        try writer.writeAll("<button class=\"button button-primary\" type=\"submit\">Post reply</button></form></details>");
    }
    try writer.writeAll("</article>");
}

fn renderVoteForm(
    writer: *std.Io.Writer,
    csrf_input: ?[]const u8,
    issue: models.Issue,
    viewer_voted: bool,
) !void {
    const hidden = csrf_input orelse {
        try writer.writeAll("<a class=\"button button-primary\" href=\"/auth/discord\">Sign in to vote</a>");
        return;
    };
    try writer.print("<form method=\"post\" action=\"/issues/{d}/vote\">", .{issue.id});
    try writer.writeAll(hidden);
    try writer.print("<input type=\"hidden\" name=\"selected\" value=\"{s}\">", .{
        if (viewer_voted) "false" else "true",
    });
    try writer.print("<button class=\"button {s}\" type=\"submit\">{s} · {d}</button></form>", .{
        if (viewer_voted) "button-quiet" else "button-primary",
        if (viewer_voted) "Remove vote" else "▲ Vote",
        issue.vote_count,
    });
}

fn renderIssueForm(
    writer: *std.Io.Writer,
    boards: []const models.Board,
    csrf_input: []const u8,
    values: CreateForm,
    error_message: ?[]const u8,
) !void {
    try writer.writeAll("<section class=\"form-page\"><div>");
    try writer.writeAll("<h1>New feedback</h1><p>Give enough context for someone else to understand and, for bugs, reproduce it.</p></div>");
    try writer.writeAll("<form class=\"stacked-form\" method=\"post\" action=\"/issues\">");
    try writer.writeAll(csrf_input);
    if (error_message) |message| {
        try writer.writeAll("<p class=\"form-error\" role=\"alert\">");
        try highlight.escapeHtml(writer, message);
        try writer.writeAll("</p>");
    }
    try writer.writeAll("<div class=\"form-row\"><label>Type<select name=\"kind\" data-kind-select>");
    try writeKindOption(writer, .feature, "Feature request", values.kind);
    try writeKindOption(writer, .improvement, "Improvement", values.kind);
    try writeKindOption(writer, .bug, "Bug report", values.kind);
    try writer.writeAll("</select></label><label>Board<select name=\"board_id\">");
    for (boards) |board| {
        try writer.print("<option value=\"{d}\"{s}>", .{
            board.id,
            if (board.id == values.board_id) " selected" else "",
        });
        try highlight.escapeHtml(writer, board.name);
        try writer.writeAll("</option>");
    }
    try writer.writeAll("</select></label></div>");
    try writer.writeAll("<label>Title<input name=\"title\" required minlength=\"5\" maxlength=\"160\" placeholder=\"A concise summary\" value=\"");
    try highlight.escapeHtml(writer, values.title);
    try writer.writeAll("\"></label>");
    try writer.writeAll("<label>Description <span class=\"hint\">Markdown, code fences, and ![alt](https://...) images</span><textarea name=\"body\" required minlength=\"20\" maxlength=\"16384\" rows=\"8\" placeholder=\"What problem does this solve?\">");
    try highlight.escapeHtml(writer, values.body);
    try writer.writeAll("</textarea></label>");
    try page.imageUploadControl(writer, .markdown);
    try writer.writeAll("<fieldset class=\"bug-fields\" data-bug-fields><legend>Bug details</legend>");
    try writeOptionalTextarea(writer, "reproduction_steps", "Steps to reproduce", 5, values.reproduction_steps);
    try writeOptionalTextarea(writer, "expected_behavior", "Expected behavior", 3, values.expected_behavior);
    try writeOptionalTextarea(writer, "actual_behavior", "Actual behavior", 3, values.actual_behavior);
    try writeOptionalTextarea(writer, "environment", "Environment and version", 3, values.environment);
    try writer.writeAll("</fieldset>");
    try writer.writeAll("<div class=\"upload-field\"><label>Evidence image or URL <span class=\"hint\">optional — upload a PNG/JPEG/GIF/WebP or paste an https link</span><input type=\"text\" inputmode=\"url\" name=\"evidence_url\" maxlength=\"512\" placeholder=\"https://.../screenshot.png\" value=\"");
    try highlight.escapeHtml(writer, values.evidence_url orelse "");
    try writer.writeAll("\"></label>");
    try page.imageUploadControl(writer, .url);
    try writer.writeAll("</div><div class=\"form-actions\"><a class=\"button button-quiet\" href=\"/\">Cancel</a>");
    try writer.writeAll("<button class=\"button button-primary\" type=\"submit\">Submit feedback</button></div></form></section>");
}

fn writeKindOption(
    writer: *std.Io.Writer,
    kind: domain.IssueKind,
    label: []const u8,
    selected: domain.IssueKind,
) !void {
    try writer.print("<option value=\"{s}\"{s}>{s}</option>", .{
        @tagName(kind),
        if (kind == selected) " selected" else "",
        label,
    });
}

fn writeOptionalTextarea(
    writer: *std.Io.Writer,
    name: []const u8,
    label: []const u8,
    rows: u8,
    value: ?[]const u8,
) !void {
    try writer.print(
        "<label>{s}<textarea name=\"{s}\" maxlength=\"8192\" rows=\"{d}\">",
        .{ label, name, rows },
    );
    try highlight.escapeHtml(writer, value orelse "");
    try writer.writeAll("</textarea></label>");
}

fn emptyCreateForm() CreateForm {
    return .{
        .board_id = 0,
        .kind = .feature,
        .title = "",
        .body = "",
    };
}

fn createIssueErrorMessage(err: domain.ValidationError) []const u8 {
    return switch (err) {
        error.InvalidBoard => "Pick a board.",
        error.InvalidTitle => "Title needs 5–160 characters.",
        error.InvalidBody => "Description needs at least 20 characters.",
        error.MissingBugDetails => "Bug reports need reproduction steps and what actually happened (at least 10 characters each).",
        error.InvalidDiagnostic => "A bug-detail field is empty or too long.",
        error.InvalidEvidenceUrl => "Evidence must be an http(s) link or uploaded image.",
        error.InvalidUtf8 => "Text contains invalid characters.",
    };
}

fn issueFormResponse(
    context: *app_state.Context,
    workspace: *request.Workspace,
    user: *const models.User,
    values: CreateForm,
    error_message: ?[]const u8,
    comptime status: ploof.response.Status,
) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return page.htmlFailure(context, .service_unavailable, "503", "Unavailable", "Poof is not configured.");
    const database = app_state.database(context) orelse
        return page.htmlFailure(context, .service_unavailable, "503", "Unavailable", "Database unavailable.");
    var boards_storage: [32]models.Board = undefined;
    const boards = database.listBoards(workspace.allocator(), &boards_storage, false) catch
        return context.empty(.service_unavailable);
    var csrf_token = csrf.prepare(context) catch
        return context.empty(.internal_server_error);
    const branding = page.resolveBranding(workspace.allocator(), database, settings);
    var writer = workspace.writer();
    page.begin(&writer, branding, "Share feedback", .feedback, user) catch
        return context.empty(.internal_server_error);
    renderIssueForm(&writer, boards, csrf_token.hiddenInput(), values, error_message) catch
        return context.empty(.internal_server_error);
    page.end(&writer, workspace) catch return context.empty(.internal_server_error);
    var response = context.htmlBorrowed(status, workspace.rendered(&writer));
    csrf.attach(&response, &csrf_token);
    return response;
}

fn renderRoadmapColumn(
    writer: *std.Io.Writer,
    title: []const u8,
    result: models.ListResult,
) !void {
    try writer.writeAll("<div class=\"roadmap-column\"><header><h2>");
    try writer.writeAll(title);
    try writer.print("</h2><span>{d}</span></header>", .{result.total});
    if (result.items.len == 0) {
        try writer.writeAll("<p class=\"roadmap-empty\">Nothing here yet.</p>");
    } else {
        for (result.items) |issue| {
            var url: [256]u8 = undefined;
            try writer.writeAll("<a class=\"roadmap-card\" href=\"");
            try writer.writeAll(try page.issueUrl(&url, issue.id, issue.slug));
            try writer.writeAll("\"><strong>");
            try highlight.escapeHtml(writer, issue.title);
            try writer.writeAll("</strong><span>");
            try page.priorityBadge(writer, issue.priority);
            if (issue.priority != .none) try writer.writeAll(" ");
            try highlight.escapeHtml(writer, issue.board_name);
            try writer.print(" · {d} votes</span></a>", .{issue.vote_count});
        }
        if (result.total > @as(i64, @intCast(result.items.len))) {
            try writer.print("<p class=\"roadmap-empty\">Showing {d} of {d} items.</p>", .{
                result.items.len,
                result.total,
            });
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
    return page.htmlFailure(
        context,
        .not_found,
        "404",
        "Feedback not found",
        "The requested item may have moved or been removed.",
    );
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (std.mem.trim(u8, text, " \t\r\n").len == 0) null else text;
}
