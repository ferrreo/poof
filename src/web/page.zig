const std = @import("std");
const ploof = @import("ploof");
const assets = @import("assets");
const config = @import("../config.zig");
const domain = @import("../domain.zig");
const store = @import("../store.zig");
const highlight = @import("highlight.zig");

pub const css_path = assetPath("app.css");
pub const javascript_path = assetPath("app.js");

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

pub fn begin(
    writer: *std.Io.Writer,
    branding: store.SiteBranding,
    title: []const u8,
    active: enum { feedback, roadmap, changelog, admin, none },
    user: ?*const store.User,
) std.Io.Writer.Error!void {
    try writer.writeAll("<!doctype html><html lang=\"en\"><head>");
    try writer.print("<link rel=\"stylesheet\" href=\"{s}\">", .{css_path});
    try writer.print("<script src=\"{s}\" defer></script>", .{javascript_path});
    try writer.writeAll(
        "<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">",
    );
    try writer.writeAll("<title>");
    try highlight.escapeHtml(writer, title);
    try writer.writeAll(" — ");
    try highlight.escapeHtml(writer, branding.company_name);
    try writer.writeAll("</title></head><body>");
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

pub fn end(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        "</main><footer><p class=\"colophon\">Free, open-source feedback software for one company. BSD-3-Clause. Zig, Ploof, zhl, PostgreSQL.</p>" ++
            "<a href=\"/settings/developer/tokens\">MCP tokens</a></footer></body></html>",
    );
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

pub fn errorPage(
    writer: *std.Io.Writer,
    settings: *const config.Config,
    status: []const u8,
    title: []const u8,
    message: []const u8,
) std.Io.Writer.Error!void {
    try begin(writer, .{
        .company_name = settings.company_name,
        .tagline = settings.tagline,
        .logo_url = null,
    }, title, .none, null);
    try writer.writeAll("<section class=\"empty-card error-page\"><p class=\"kicker\">");
    try highlight.escapeHtml(writer, status);
    try writer.writeAll("</p><h1>");
    try highlight.escapeHtml(writer, title);
    try writer.writeAll("</h1><p>");
    try highlight.escapeHtml(writer, message);
    try writer.writeAll("</p><a class=\"button button-primary\" href=\"/\">Back to feedback</a></section>");
    try end(writer);
}

pub fn looksLikeImageUrl(url: []const u8) bool {
    const path_end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..path_end];
    inline for (.{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif" }) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
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

comptime {
    _ = ploof;
}
