const std = @import("std");
const ploof = @import("ploof");
const app_state = @import("../../app_state.zig");
const api_token = @import("../../auth/api_token.zig");
const domain = @import("../../domain.zig");
const models = @import("../../store.zig");
const csrf = @import("../csrf.zig");
const page = @import("../page.zig");
const request = @import("../request.zig");
const highlight = @import("../highlight.zig");

pub const CreateDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(struct {
        label: []const u8,
        expires_days: ?u16 = null,
        read: bool = true,
        issues_write: bool = false,
        comments_write: bool = false,
        admin_issues: bool = false,
        admin_boards: bool = false,
        admin_changelog: bool = false,
    }, .{
        .encoded_wire_bytes_max = 4 * 1024,
        .decoded_bytes_max = 4 * 1024,
        .segments_max = 10,
        .unknown_fields = .reject,
    }),
});

pub const RevokeDefinition = ploof.Endpoint(.{
    .body = ploof.Form.typed(struct { confirm: bool }, .{
        .encoded_wire_bytes_max = 512,
        .decoded_bytes_max = 512,
        .segments_max = 2,
        .unknown_fields = .reject,
    }),
});

pub fn index(context: *app_state.Context) app_state.Context.ResponseType {
    return render(context, null);
}

pub fn create(
    context: *app_state.Context,
    input: CreateDefinition.InputType,
) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return context.empty(.service_unavailable);
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    const io = context.state.io orelse return context.empty(.service_unavailable);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const principal = (request.principal(context, workspace.allocator()) catch
        return context.empty(.service_unavailable)) orelse return context.empty(.unauthorized);
    if (!(database.allowUserAction(
        principal.user.id,
        "token_create",
        10,
        3600,
    ) catch return context.empty(.service_unavailable))) {
        return page.htmlFailure(
            context,
            .too_many_requests,
            "429",
            "Slow down",
            "Token creation limit reached.",
        );
    }
    var scopes = domain.ScopeSet{};
    if (input.body.read) scopes.insert(.read);
    if (input.body.issues_write) scopes.insert(.issues_write);
    if (input.body.comments_write) scopes.insert(.comments_write);
    if (input.body.admin_issues) scopes.insert(.admin_issues);
    if (input.body.admin_boards) scopes.insert(.admin_boards);
    if (input.body.admin_changelog) scopes.insert(.admin_changelog);
    if (!scopes.allowedFor(principal.user.role) or !scopes.contains(.read)) {
        return context.empty(.forbidden);
    }

    var generated = api_token.Generated.generate(io, settings.api_token_pepper);
    defer generated.clear();
    _ = database.createApiToken(
        workspace.allocator(),
        principal.user.id,
        &generated.lookup,
        generated.digest,
        input.body.label,
        scopes,
        input.body.expires_days,
    ) catch |problem| return switch (problem) {
        error.Conflict => page.htmlFailure(
            context,
            .unprocessable_entity,
            "422",
            "Invalid token",
            "Token details are invalid.",
        ),
        else => context.empty(.service_unavailable),
    };
    return render(context, generated.slice());
}

pub fn revoke(
    context: *app_state.Context,
    input: RevokeDefinition.InputType,
) app_state.Context.ResponseType {
    if (!input.body.confirm) return context.empty(.bad_request);
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const principal = (request.principal(context, workspace.allocator()) catch
        return context.empty(.service_unavailable)) orelse return context.empty(.unauthorized);
    const encoded_id = context.request.param("id") orelse return context.empty(.not_found);
    const token_id = api_token.parseId(encoded_id) catch return context.empty(.not_found);
    database.revokeApiToken(principal.user.id, token_id) catch |problem| return switch (problem) {
        error.NotFound => context.empty(.not_found),
        else => context.empty(.service_unavailable),
    };
    return request.redirect(context, .see_other, "/settings/developer/tokens");
}

fn render(
    context: *app_state.Context,
    plaintext: ?[]const u8,
) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse
        return context.empty(.service_unavailable);
    const database = app_state.database(context) orelse
        return context.empty(.service_unavailable);
    var workspace = request.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const allocator = workspace.allocator();
    const principal = (request.principal(context, allocator) catch
        return context.empty(.service_unavailable)) orelse
        return request.redirect(context, .see_other, "/auth/discord?return_to=/settings/developer/tokens");
    var token_storage: [100]models.ApiToken = undefined;
    const tokens = database.listApiTokens(
        allocator,
        principal.user.id,
        &token_storage,
    ) catch return context.empty(.service_unavailable);
    var event_storage: [50]models.AutomationEvent = undefined;
    const events = database.listAutomationEvents(
        allocator,
        principal.user.id,
        &event_storage,
    ) catch return context.empty(.service_unavailable);
    const csrf_token = csrf.prepare(context) catch
        return context.empty(.internal_server_error);

    const branding = page.resolveBranding(allocator, database, settings);
    var writer = workspace.writer();
    page.begin(&writer, branding, "Developer tokens", .none, &principal.user, page.colorScheme(context)) catch
        return context.empty(.internal_server_error);
    writer.writeAll("<section class=\"developer-page\"><header>") catch
        return context.empty(.internal_server_error);
    writer.writeAll("<h1>MCP tokens</h1><p>Scoped, expiring bearer tokens for the remote Poof MCP server.</p></header>") catch
        return context.empty(.internal_server_error);
    if (plaintext) |token| renderNewToken(&writer, settings.public_url, token) catch
        return context.empty(.internal_server_error);
    renderTokenList(&writer, tokens, csrf_token.hiddenInput()) catch
        return context.empty(.internal_server_error);
    renderCreateForm(
        &writer,
        principal.user.role,
        csrf_token.hiddenInput(),
    ) catch return context.empty(.internal_server_error);
    renderAuditEvents(&writer, events) catch return context.empty(.internal_server_error);
    renderSetup(&writer, settings.public_url) catch
        return context.empty(.internal_server_error);
    page.end(&writer, &workspace) catch return context.empty(.internal_server_error);
    var response = context.htmlBorrowed(.ok, workspace.rendered(&writer));
    csrf.attach(&response, &csrf_token);
    response.setHeaderStatic("cache-control", "no-store") catch {};
    return response;
}

fn renderNewToken(writer: *std.Io.Writer, public_url: []const u8, token: []const u8) !void {
    try writer.writeAll("<section class=\"token-reveal\" role=\"status\">");
    try writer.writeAll("<h2>Copy this token now. It will not be shown again.</h2><pre><code>");
    try highlight.escapeHtml(writer, token);
    try writer.writeAll("</code></pre><p>Send it only as <code>Authorization: Bearer …</code> to ");
    try highlight.escapeHtml(writer, public_url);
    try writer.writeAll("/mcp.</p></section>");
}

fn renderTokenList(
    writer: *std.Io.Writer,
    tokens: []const models.ApiToken,
    csrf_input: []const u8,
) !void {
    try writer.writeAll("<section class=\"developer-card\"><h2>Your tokens</h2>");
    if (tokens.len == 0) {
        try writer.writeAll("<p class=\"notice\">No tokens yet.</p>");
    } else {
        try writer.writeAll("<div class=\"token-list\">");
        for (tokens) |token| {
            const id = api_token.formatId(token.id);
            try writer.writeAll("<article><div><strong>");
            try highlight.escapeHtml(writer, token.label);
            try writer.writeAll("</strong><code>");
            try highlight.escapeHtml(writer, token.lookup_prefix);
            try writer.writeAll("…</code><span>");
            if (token.revoked) {
                try writer.writeAll("Revoked");
            } else {
                try writer.writeAll("Active");
            }
            try writer.writeAll("</span></div>");
            if (!token.revoked) {
                try writer.writeAll("<form method=\"post\" action=\"/settings/developer/tokens/");
                try writer.writeAll(&id);
                try writer.writeAll("/revoke\" data-confirm=\"Revoke this token?\">");
                try writer.writeAll(csrf_input);
                try writer.writeAll("<input type=\"hidden\" name=\"confirm\" value=\"true\"><button class=\"button button-quiet\" type=\"submit\">Revoke</button></form>");
            }
            try writer.writeAll("</article>");
        }
        try writer.writeAll("</div>");
    }
    try writer.writeAll("</section>");
}

fn renderCreateForm(
    writer: *std.Io.Writer,
    role: domain.Role,
    csrf_input: []const u8,
) !void {
    try writer.writeAll("<form class=\"developer-card token-create\" method=\"post\" action=\"/settings/developer/tokens\">");
    try writer.writeAll(csrf_input);
    try writer.writeAll("<h2>Create a token</h2><label>Label<input name=\"label\" required maxlength=\"80\" placeholder=\"Cursor on my laptop\"></label>");
    try writer.writeAll("<label>Expires after<select name=\"expires_days\"><option value=\"30\">30 days</option><option value=\"90\">90 days</option><option value=\"365\">1 year</option></select></label>");
    try writer.writeAll("<fieldset><legend>Scopes</legend><input type=\"hidden\" name=\"read\" value=\"true\">");
    try scopeCheck(writer, "issues_write", "Create and vote on issues");
    try scopeCheck(writer, "comments_write", "Create comments and replies");
    if (role == .admin) {
        try scopeCheck(writer, "admin_issues", "Triage and update issues");
        try scopeCheck(writer, "admin_boards", "Manage boards");
        try scopeCheck(writer, "admin_changelog", "Draft and publish changelogs");
    }
    try writer.writeAll("</fieldset><button class=\"button button-primary\" type=\"submit\">Create token</button></form>");
}

fn scopeCheck(writer: *std.Io.Writer, name: []const u8, label: []const u8) !void {
    try writer.print("<label class=\"scope-check\"><input type=\"checkbox\" name=\"{s}\" value=\"true\"><span>{s}</span></label>", .{ name, label });
}

fn renderSetup(writer: *std.Io.Writer, public_url: []const u8) !void {
    try writer.writeAll("<section class=\"developer-card\"><h2>Remote MCP setup</h2><p>Use Streamable HTTP with a custom authorization header.</p><pre><code>{\n  \"mcpServers\": {\n    \"poof\": {\n      \"url\": \"");
    try highlight.escapeHtml(writer, public_url);
    try writer.writeAll("/mcp\",\n      \"headers\": {\n        \"Authorization\": \"Bearer YOUR_TOKEN\"\n      }\n    }\n  }\n}</code></pre></section>");
}

fn renderAuditEvents(
    writer: *std.Io.Writer,
    events: []const models.AutomationEvent,
) !void {
    try writer.writeAll("<section class=\"developer-card\"><h2>Recent automation</h2>");
    if (events.len == 0) {
        try writer.writeAll("<p class=\"notice\">No MCP activity yet.</p>");
    } else {
        try writer.writeAll("<div class=\"audit-list\">");
        for (events) |event| {
            try writer.writeAll("<article><div><strong>");
            try highlight.escapeHtml(writer, event.tool_name orelse event.method);
            try writer.writeAll("</strong><span>");
            try highlight.escapeHtml(writer, event.outcome);
            try writer.writeAll("</span></div>");
            if (event.summary.len != 0) {
                try writer.writeAll("<p>");
                try highlight.escapeHtml(writer, event.summary);
                try writer.writeAll("</p>");
            }
            try writer.writeAll("</article>");
        }
        try writer.writeAll("</div>");
    }
    try writer.writeAll("</section>");
}
