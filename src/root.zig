const ploof = @import("ploof");
const app_state_module = @import("app_state.zig");
const admin_handlers = @import("web/handlers/admin.zig");
const auth_handlers = @import("web/handlers/auth.zig");
const developer_handlers = @import("web/handlers/developer.zig");
const mcp_transport = @import("mcp/transport.zig");
const public_handlers = @import("web/handlers/public.zig");
const csrf_module = @import("web/csrf.zig");
const web_middleware = @import("web/middleware.zig");

pub const config = @import("config.zig");
pub const domain = @import("domain.zig");
pub const api_token = @import("auth/api_token.zig");
pub const cookie = @import("auth/cookie.zig");
pub const discord = @import("auth/discord.zig");
pub const oauth_state = @import("auth/oauth_state.zig");
pub const session = @import("auth/session.zig");
pub const store = @import("store.zig");
pub const postgres = @import("store/postgres.zig");
pub const store_migrations = @import("store/migrations.zig");
pub const highlight = @import("web/highlight.zig");
pub const markdown = @import("web/markdown.zig");
pub const page = @import("web/page.zig");
pub const web_request = @import("web/request.zig");
pub const mcp_protocol = @import("mcp/protocol.zig");
pub const mcp_tools = @import("mcp/tools.zig");
pub const Assets = ploof.Asset.Bundle(@import("assets"));

pub const State = app_state_module.State;
pub const Context = app_state_module.Context;

const HomePage = blk: {
    @setEvalBranchQuota(100_000);
    break :blk ploof.HtmlTemplate.Template(.{
        .View = struct {
            css: @TypeOf(Assets.local("app.css")),
            javascript: @TypeOf(Assets.local("app.js")),
        },
        .encoded_bytes_max = 16 * 1024,
        .source = ploof.HtmlSource.SourceSpec{
            .kind = .document,
            .graph_name = "poof-home",
            .file_path = "src/views/home.html",
            .bytes = @embedFile("views/home.html"),
        },
    });
};

fn home(context: *Context) ploof.HtmlResponse.TemplateResponse(HomePage) {
    return context.html(.ok, HomePage, .{
        .css = Assets.local("app.css"),
        .javascript = Assets.local("app.js"),
    });
}

const Live = ploof.Health.Liveness(Context);
const Ready = ploof.Health.Readiness(Context, readiness);

fn readiness(state: *State) *const ploof.Lifecycle.Readiness {
    return &state.readiness;
}

const BrowserRoutes = ploof.group("", .{csrf_module.policy}, .{
    ploof.get("/", public_handlers.home),
    ploof.get(
        "/issues",
        public_handlers.ListDefinition.handle(public_handlers.list),
    ),
    ploof.get("/issues/new", public_handlers.newIssue),
    ploof.post(
        "/issues",
        public_handlers.CreateDefinition.handle(public_handlers.create),
    ),
    ploof.get("/issues/:id", public_handlers.detail),
    ploof.get("/issues/:id/:slug", public_handlers.detail),
    ploof.post(
        "/issues/:id/vote",
        public_handlers.VoteDefinition.handle(public_handlers.vote),
    ),
    ploof.post(
        "/issues/:id/comments",
        public_handlers.CommentDefinition.handle(public_handlers.comment),
    ),
    ploof.get("/roadmap", public_handlers.roadmap),
    ploof.get("/changelog", public_handlers.changelog),
    ploof.get("/changelog/:slug", public_handlers.changelogDetail),
    ploof.get("/me", public_handlers.me),
    ploof.get("/admin", admin_handlers.dashboard),
    ploof.post(
        "/admin/issues/:id",
        admin_handlers.IssueUpdateDefinition.handle(admin_handlers.updateIssue),
    ),
    ploof.get("/admin/issues/:id/edit", admin_handlers.editIssuePage),
    ploof.post(
        "/admin/issues/:id/content",
        admin_handlers.IssueContentDefinition.handle(admin_handlers.editIssueContent),
    ),
    ploof.post(
        "/admin/boards",
        admin_handlers.BoardCreateDefinition.handle(admin_handlers.createBoard),
    ),
    ploof.post(
        "/admin/boards/:id",
        admin_handlers.BoardUpdateDefinition.handle(admin_handlers.updateBoard),
    ),
    ploof.post(
        "/admin/boards/:id/archive",
        admin_handlers.BoardArchiveDefinition.handle(admin_handlers.archiveBoard),
    ),
    ploof.post(
        "/admin/changelog",
        admin_handlers.ChangelogCreateDefinition.handle(admin_handlers.createChangelog),
    ),
    ploof.post(
        "/admin/changelog/:id/publish",
        admin_handlers.ChangelogPublishDefinition.handle(admin_handlers.publishChangelog),
    ),
    ploof.get("/admin/changelog/:id/edit", admin_handlers.editChangelogPage),
    ploof.post(
        "/admin/changelog/:id/content",
        admin_handlers.ChangelogCreateDefinition.handle(admin_handlers.updateChangelog),
    ),
    ploof.get(
        "/auth/discord",
        auth_handlers.StartDefinition.handle(auth_handlers.start),
    ),
    ploof.get(
        "/auth/discord/callback",
        auth_handlers.CallbackDefinition.handle(auth_handlers.callback),
    ),
    ploof.post(
        "/auth/logout",
        auth_handlers.LogoutDefinition.handle(auth_handlers.logout),
    ),
    ploof.get("/settings/developer/tokens", developer_handlers.index),
    ploof.post(
        "/settings/developer/tokens",
        developer_handlers.CreateDefinition.handle(developer_handlers.create),
    ),
    ploof.post(
        "/settings/developer/tokens/:id/revoke",
        developer_handlers.RevokeDefinition.handle(developer_handlers.revoke),
    ),
});

pub const App = ploof.Application(.{
    .State = State,
    .assets = Assets,
    .middleware = .{web_middleware.SecurityHeaders{}},
    .response_body_bytes_max = 512 * 1024,
    .routes = .{
        BrowserRoutes,
        ploof.post("/mcp", mcp_transport.Definition.handle(mcp_transport.handle)),
        ploof.get("/live", Live.handle),
        ploof.get("/ready", Ready.handle),
        ploof.openMetrics("/metrics"),
    },
});

pub const WebTestApp = ploof.Application(.{
    .State = State,
    .assets = Assets,
    .middleware = .{web_middleware.SecurityHeaders{}},
    .response_body_bytes_max = 512 * 1024,
    .routes = .{
        BrowserRoutes,
        ploof.post("/mcp", mcp_transport.Definition.handle(mcp_transport.handle)),
        ploof.get("/live", Live.handle),
        ploof.get("/ready", Ready.handle),
    },
});

pub const TestApp = ploof.Application(.{
    .State = State,
    .assets = Assets,
    .routes = .{
        ploof.get("/", home),
        ploof.get("/live", Live.handle),
        ploof.get("/ready", Ready.handle),
    },
});

test {
    _ = config;
    _ = domain;
    _ = api_token;
    _ = cookie;
    _ = discord;
    _ = oauth_state;
    _ = session;
    _ = store;
    _ = postgres;
    _ = store_migrations;
    _ = highlight;
    _ = markdown;
    _ = page;
    _ = web_request;
    _ = auth_handlers;
    _ = admin_handlers;
    _ = developer_handlers;
    _ = mcp_transport;
    _ = mcp_protocol;
    _ = mcp_tools;
    _ = public_handlers;
    _ = csrf_module;
    _ = web_middleware;
}
