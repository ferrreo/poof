const ploof = @import("ploof");

pub const config = @import("config.zig");
pub const domain = @import("domain.zig");
pub const Assets = ploof.Asset.Bundle(@import("assets"));

pub const State = struct {
    readiness: ploof.Lifecycle.Readiness = .{},
};

pub const Context = ploof.Context(State, ploof.response.standard_head_limits);

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

pub const App = ploof.Application(.{
    .State = State,
    .assets = Assets,
    .routes = .{
        ploof.get("/", home),
        ploof.get("/live", Live.handle),
        ploof.get("/ready", Ready.handle),
        ploof.openMetrics("/metrics"),
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
}
