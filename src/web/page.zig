const std = @import("std");
const ploof = @import("ploof");
const assets = @import("assets");
const app_state = @import("../app_state.zig");
const config = @import("../config.zig");
const domain = @import("../domain.zig");
const store = @import("../store.zig");
const highlight = @import("highlight.zig");
const request = @import("request.zig");

pub const css_path = assetPath("app.css");
pub const javascript_path = assetPath("app.js");

/// Chrome often checks this before external CSS. Keep it inline in <head>.
pub const view_transition_css =
    "@media (prefers-reduced-motion: no-preference){@view-transition{navigation:auto}}";

pub const view_transition_style_hash: [44]u8 = blk: {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(view_transition_css, &digest, .{});
    var encoded: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &digest);
    break :blk encoded;
};

pub fn resolveBranding(
    allocator: std.mem.Allocator,
    database: anytype,
    settings: *const config.Config,
) store.SiteBranding {
    return database.getSiteSettings(allocator) catch .{
        .company_name = settings.company_name,
        .tagline = settings.tagline,
        .logo_url = null,
    };
}

pub const ColorScheme = enum { system, light, dark };

pub const theme_cookie = "poof_theme";

pub fn parseColorScheme(value: []const u8) ColorScheme {
    if (std.mem.eql(u8, value, "dark")) return .dark;
    if (std.mem.eql(u8, value, "light")) return .light;
    return .system;
}

pub fn colorScheme(context: *app_state.Context) ColorScheme {
    return parseColorScheme(request.cookieValue(context, theme_cookie) orelse "system");
}

pub fn begin(
    writer: *std.Io.Writer,
    branding: store.SiteBranding,
    title: []const u8,
    active: enum { feedback, roadmap, changelog, admin, none },
    user: ?*const store.User,
    scheme: ColorScheme,
) std.Io.Writer.Error!void {
    try writer.writeAll("<!doctype html><html lang=\"en\"");
    switch (scheme) {
        .system => {},
        .light => try writer.writeAll(" data-theme=\"light\""),
        .dark => try writer.writeAll(" data-theme=\"dark\""),
    }
    try writer.writeAll("><head>");
    try writer.writeAll(
        "<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">",
    );
    try writer.writeAll("<meta name=\"color-scheme\" content=\"");
    try writer.writeAll(switch (scheme) {
        .system => "light dark",
        .light => "light",
        .dark => "dark",
    });
    try writer.writeAll("\"><style>");
    try writer.writeAll(view_transition_css);
    try writer.writeAll("</style>");
    try writer.print(
        "<link rel=\"stylesheet\" href=\"{s}\" blocking=\"render\"><link rel=\"expect\" href=\"#site-footer\" blocking=\"render\">",
        .{css_path},
    );
    try writer.writeAll("<title>");
    try highlight.escapeHtml(writer, title);
    try writer.writeAll(" — ");
    try highlight.escapeHtml(writer, branding.company_name);
    try writer.writeAll("</title>");
    try writer.print("<script src=\"{s}\" defer></script>", .{javascript_path});
    if (branding.logo_url) |logo| {
        try writer.writeAll("<link rel=\"icon\" href=\"");
        try escapeAttribute(writer, logo);
        try writer.writeAll("\"><link rel=\"apple-touch-icon\" href=\"");
        try escapeAttribute(writer, logo);
        try writer.writeAll("\">");
    }
    try writer.writeAll("</head><body>");
    try writer.writeAll("<header class=\"site-header\">");
    try writer.writeAll("<a class=\"brand\" href=\"/\">");
    if (branding.logo_url) |logo| {
        try writer.writeAll("<img class=\"brand-logo\" src=\"");
        try escapeAttribute(writer, logo);
        try writer.writeAll("\" alt=\"");
        try escapeAttribute(writer, branding.company_name);
        try writer.writeAll("\">");
    }
    try highlight.escapeHtml(writer, branding.company_name);
    try writer.writeAll("</a><div class=\"masthead-bar\"><nav aria-label=\"Primary navigation\">");
    try navLink(writer, "/", "Feedback", active == .feedback);
    try navLink(writer, "/roadmap", "Roadmap", active == .roadmap);
    try navLink(writer, "/changelog", "Changelog", active == .changelog);
    try writer.writeAll("</nav>");
    try writer.writeAll(
        "<button type=\"button\" class=\"button button-quiet theme-toggle\" data-theme-toggle aria-label=\"Color scheme\">",
    );
    try writer.writeAll(switch (scheme) {
        .system => "Auto",
        .light => "Light",
        .dark => "Dark",
    });
    try writer.writeAll("</button>");
    if (user) |principal| {
        if (principal.role == .admin) {
            try writer.writeAll("<a class=\"button button-quiet\" href=\"/admin\">Admin</a>");
        } else {
            try writer.writeAll("<a class=\"button button-quiet\" href=\"/me\">");
            try highlight.escapeHtml(
                writer,
                principal.display_name orelse principal.username,
            );
            try writer.writeAll("</a>");
        }
    } else {
        try writer.writeAll("<a class=\"button button-quiet\" href=\"/auth/discord\">Sign in</a>");
    }
    try writer.writeAll("</div></header><main>");
}

pub fn end(writer: *std.Io.Writer, workspace: *const request.Workspace) std.Io.Writer.Error!void {
    try writer.writeAll(
        "</main><footer id=\"site-footer\"><p class=\"colophon\">Free, open-source feedback software for one company. BSD-3-Clause. Zig, Ploof, zhl, PostgreSQL.</p>",
    );
    try writeRenderTime(writer, workspace.elapsedNs());
    try writer.writeAll("<a href=\"/settings/developer/tokens\">MCP tokens</a></footer></body></html>");
}

fn writeRenderTime(writer: *std.Io.Writer, elapsed_ns: u64) std.Io.Writer.Error!void {
    try writer.writeAll("<p class=\"render-time\">rendered in ");
    if (elapsed_ns < std.time.ns_per_ms) {
        try writer.print("{d} µs", .{elapsed_ns / std.time.ns_per_us});
    } else {
        try writer.print("{d} ms", .{elapsed_ns / std.time.ns_per_ms});
    }
    try writer.writeAll("</p>");
}

pub fn writeQueryComponent(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or
            byte == '.' or byte == '~')
        {
            try writer.writeByte(byte);
        } else if (byte == ' ') {
            try writer.writeByte('+');
        } else {
            try writer.print("%{X:0>2}", .{byte});
        }
    }
}

pub fn issueUrl(
    output: []u8,
    issue_id: i64,
    slug: []const u8,
) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(output, "/issues/{d}/{s}", .{ issue_id, slug }) catch
        error.NoSpaceLeft;
}

pub fn statusBadge(
    writer: *std.Io.Writer,
    status: domain.IssueStatus,
) std.Io.Writer.Error!void {
    try writer.print(
        "<span class=\"status status-{s}\">{s}</span>",
        .{ @tagName(status), status.label() },
    );
}

pub fn kindBadge(
    writer: *std.Io.Writer,
    kind: domain.IssueKind,
) std.Io.Writer.Error!void {
    try writer.print(
        "<span class=\"kind kind-{s}\">{s}</span>",
        .{ @tagName(kind), kind.label() },
    );
}

pub fn priorityBadge(
    writer: *std.Io.Writer,
    priority: domain.Priority,
) std.Io.Writer.Error!void {
    if (priority == .none) return;
    try writer.print(
        "<span class=\"priority priority-{s}\">{s}</span>",
        .{ @tagName(priority), priority.label() },
    );
}

pub fn htmlFailure(
    context: *app_state.Context,
    comptime status: ploof.response.Status,
    kicker: []const u8,
    title: []const u8,
    message: []const u8,
) app_state.Context.ResponseType {
    const settings = app_state.config(context) orelse return context.empty(status);
    var workspace = request.Workspace.init(context) catch return context.empty(status);
    var writer = workspace.writer();
    errorPage(&writer, settings, kicker, title, message, &workspace, colorScheme(context)) catch
        return context.empty(.internal_server_error);
    return context.htmlBorrowed(status, workspace.rendered(&writer));
}

pub fn errorPage(
    writer: *std.Io.Writer,
    settings: *const config.Config,
    status: []const u8,
    title: []const u8,
    message: []const u8,
    workspace: *const request.Workspace,
    scheme: ColorScheme,
) std.Io.Writer.Error!void {
    try begin(writer, .{
        .company_name = settings.company_name,
        .tagline = settings.tagline,
        .logo_url = null,
    }, title, .none, null, scheme);
    try writer.writeAll("<section class=\"empty-card error-page list-scroll\"><p class=\"kicker\">");
    try highlight.escapeHtml(writer, status);
    try writer.writeAll("</p><h1>");
    try highlight.escapeHtml(writer, title);
    try writer.writeAll("</h1><p>");
    try highlight.escapeHtml(writer, message);
    try writer.writeAll("</p><a class=\"button button-primary\" href=\"/\">Back to feedback</a></section>");
    try end(writer, workspace);
}

pub fn looksLikeImageUrl(url: []const u8) bool {
    const path_end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..path_end];
    inline for (.{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif" }) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}

pub const markdown_hint = "CommonMark + GFM: headings, lists, [ ] tasks, tables, code, images";

pub const IssueEditValues = struct {
    kind: domain.IssueKind,
    title: []const u8,
    body: []const u8,
    reproduction_steps: ?[]const u8 = null,
    expected_behavior: ?[]const u8 = null,
    actual_behavior: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    evidence_url: ?[]const u8 = null,
    project_id: i64 = 0,
};

pub fn issueEditValues(issue: store.Issue) IssueEditValues {
    return .{
        .kind = issue.kind,
        .title = issue.title,
        .body = issue.body_markdown,
        .reproduction_steps = issue.reproduction_steps,
        .expected_behavior = issue.expected_behavior,
        .actual_behavior = issue.actual_behavior,
        .environment = issue.environment,
        .evidence_url = issue.evidence_url,
        .project_id = issue.project_id orelse 0,
    };
}

pub fn issueEditForm(
    writer: *std.Io.Writer,
    values: IssueEditValues,
    projects: []const store.Project,
    csrf_input: []const u8,
    action: []const u8,
    cancel_href: []const u8,
    error_message: ?[]const u8,
) std.Io.Writer.Error!void {
    try writer.writeAll("<section class=\"form-page\"><div><h1>Edit feedback</h1><p>Changes are recorded in the issue activity history.</p></div>");
    try writer.writeAll("<form class=\"stacked-form list-scroll\" method=\"post\" action=\"");
    try highlight.escapeHtml(writer, action);
    try writer.writeAll("\">");
    try writer.writeAll(csrf_input);
    if (error_message) |message| {
        try writer.writeAll("<p class=\"form-error\" role=\"alert\">");
        try highlight.escapeHtml(writer, message);
        try writer.writeAll("</p>");
    }
    try writeProjectField(writer, projects, values.project_id);
    try writer.writeAll("<label>Title<input name=\"title\" required minlength=\"5\" maxlength=\"160\" value=\"");
    try highlight.escapeHtml(writer, values.title);
    try writer.writeAll("\"></label><label>Description <span class=\"hint\">");
    try writer.writeAll(markdown_hint);
    try writer.writeAll("</span><textarea name=\"body\" required minlength=\"20\" maxlength=\"16384\" rows=\"10\">");
    try highlight.escapeHtml(writer, values.body);
    try writer.writeAll("</textarea></label>");
    try imageUploadControl(writer, .markdown);
    if (values.kind == .bug) {
        try writer.writeAll("<div class=\"form-row\"><label>Steps to reproduce<textarea name=\"reproduction_steps\" required maxlength=\"8192\" rows=\"5\">");
        try highlight.escapeHtml(writer, values.reproduction_steps orelse "");
        try writer.writeAll("</textarea></label><label>Actual behavior<textarea name=\"actual_behavior\" required maxlength=\"8192\" rows=\"5\">");
        try highlight.escapeHtml(writer, values.actual_behavior orelse "");
        try writer.writeAll("</textarea></label></div><div class=\"form-row\"><label>Expected behavior<textarea name=\"expected_behavior\" maxlength=\"8192\" rows=\"4\">");
        try highlight.escapeHtml(writer, values.expected_behavior orelse "");
        try writer.writeAll("</textarea></label><label>Environment<textarea name=\"environment\" maxlength=\"8192\" rows=\"4\">");
        try highlight.escapeHtml(writer, values.environment orelse "");
        try writer.writeAll("</textarea></label></div>");
    }
    try writer.writeAll("<div class=\"upload-field\"><label>Evidence image or URL <span class=\"hint\">optional — upload a PNG/JPEG/GIF/WebP or paste an https link</span><input type=\"text\" inputmode=\"url\" name=\"evidence_url\" maxlength=\"512\" value=\"");
    try highlight.escapeHtml(writer, values.evidence_url orelse "");
    try writer.writeAll("\"></label>");
    try imageUploadControl(writer, .url);
    try writer.writeAll("</div><div class=\"form-actions\"><a class=\"button button-quiet\" href=\"");
    try highlight.escapeHtml(writer, cancel_href);
    try writer.writeAll("\">Cancel</a><button class=\"button button-primary\" type=\"submit\">Save changes</button></div></form></section>");
}

pub fn writeProjectField(
    writer: *std.Io.Writer,
    projects: []const store.Project,
    selected_id: i64,
) std.Io.Writer.Error!void {
    if (projects.len == 0) return;
    try writer.writeAll("<label>Project <span class=\"hint\">optional — which app or git repo</span>");
    try writer.writeAll("<select name=\"project_id\"><option value=\"0\">None</option>");
    for (projects) |project| {
        if (project.archived and project.id != selected_id) continue;
        try writer.print("<option value=\"{d}\"{s}>", .{
            project.id,
            if (project.id == selected_id) " selected" else "",
        });
        try highlight.escapeHtml(writer, project.name);
        try writer.writeAll("</option>");
    }
    try writer.writeAll("</select></label>");
}

/// File picker that POSTs to `/uploads` and fills a URL input or Markdown textarea.
pub fn imageUploadControl(
    writer: *std.Io.Writer,
    comptime mode: enum { url, markdown },
) std.Io.Writer.Error!void {
    const label = switch (mode) {
        .url => "Upload image",
        .markdown => "Insert image",
    };
    const mode_attr = switch (mode) {
        .url => "url",
        .markdown => "markdown",
    };
    try writer.print(
        \\<label class="button button-quiet upload-trigger">{s}<input class="sr-only" type="file" accept="image/png,image/jpeg,image/gif,image/webp" data-image-upload="{s}"></label><p class="hint upload-status" data-upload-status hidden></p>
    ,
        .{ label, mode_attr },
    );
}

fn navLink(
    writer: *std.Io.Writer,
    href: []const u8,
    label: []const u8,
    active: bool,
) std.Io.Writer.Error!void {
    try writer.print(
        "<a{s} href=\"{s}\">{s}</a>",
        .{ if (active) " class=\"active\"" else "", href, label },
    );
}

fn escapeAttribute(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(byte),
        }
    }
}

fn assetPath(comptime name: []const u8) []const u8 {
    inline for (assets.assets) |asset| {
        if (std.mem.eql(u8, asset.logical_name, name)) return asset.path;
    }
    @compileError("missing generated asset " ++ name);
}

test "render time uses microseconds under one millisecond" {
    var storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeRenderTime(&writer, 842 * std.time.ns_per_us);
    try std.testing.expectEqualStrings(
        "<p class=\"render-time\">rendered in 842 µs</p>",
        storage[0..writer.end],
    );
}

test "render time uses milliseconds at one millisecond and above" {
    var storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeRenderTime(&writer, 12 * std.time.ns_per_ms);
    try std.testing.expectEqualStrings(
        "<p class=\"render-time\">rendered in 12 ms</p>",
        storage[0..writer.end],
    );
}

test "color scheme cookie values" {
    try std.testing.expectEqual(ColorScheme.dark, parseColorScheme("dark"));
    try std.testing.expectEqual(ColorScheme.light, parseColorScheme("light"));
    try std.testing.expectEqual(ColorScheme.system, parseColorScheme("system"));
    try std.testing.expectEqual(ColorScheme.system, parseColorScheme(""));
    try std.testing.expectEqual(ColorScheme.system, parseColorScheme("auto"));
}

test "query component encodes spaces and reserved bytes" {
    var storage: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeQueryComponent(&writer, "a b&c");
    try std.testing.expectEqualStrings("a+b%26c", storage[0..writer.end]);
}

comptime {
    _ = ploof;
}
