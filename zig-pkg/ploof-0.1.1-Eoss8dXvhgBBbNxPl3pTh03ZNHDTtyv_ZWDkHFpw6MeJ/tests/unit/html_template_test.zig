const std = @import("std");
const html_render = @import("../../src/html/render.zig");
const html_response = @import("../../src/html/response.zig");
const html_source = @import("../../src/html/source.zig");
const html_template = @import("../../src/html/template.zig");
const inline_text = @import("../../src/inline_text.zig");
const trusted_resource = @import("../../src/trusted_resource_url.zig");
const url = @import("../../src/url.zig");

const BufferWriter = struct {
    storage: []u8,
    length: usize = 0,

    const Error = error{NoSpaceLeft};

    fn init(storage: []u8) BufferWriter {
        return .{ .storage = storage };
    }

    pub fn write(writer: *BufferWriter, chunk: []const u8) Error!void {
        if (chunk.len > writer.storage.len - writer.length) return error.NoSpaceLeft;
        @memcpy(writer.storage[writer.length..][0..chunk.len], chunk);
        writer.length += chunk.len;
    }

    fn bytes(writer: *const BufferWriter) []const u8 {
        return writer.storage[0..writer.length];
    }
};

test "typed interpolation controls and exact trim render without allocation" {
    const Item = struct { name: []const u8 };
    const View = struct {
        title: []const u8,
        visible: bool,
        user: ?struct { name: []const u8 },
        items: [2]Item,
    };
    const Page = html_template.Template(.{
        .View = View,
        .source = html_source.SourceSpec{
            .kind = .fragment,
            .graph_name = "typed-basic",
            .file_path = "views/basic.html",
            .bytes = " <h1> \n\t{{- view.title -}}\r\n </h1>" ++
                "{{#if view.visible}} yes {{else}} no {{/if}}" ++
                "{{#with view.user as user}} {{user.name}}{{else}} none{{/with}}" ++
                "{{#each view.items as item,index}}[{{index}}={{item.name}}]" ++
                "{{else}}empty{{/each}}",
        },
    });
    const items = [_]Item{ .{ .name = "<&" }, .{ .name = "two" } };
    var storage: [256]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try Page.render(&writer, .{
        .title = "A&B",
        .visible = true,
        .user = .{ .name = "Ada" },
        .items = items,
    }, &.{});
    try std.testing.expectEqualStrings(
        " <h1>A&amp;B</h1> yes  Ada[0=&lt;&amp;][1=two]",
        writer.bytes(),
    );
}

test "nested controls retain typed scopes" {
    const Item = struct { label: []const u8 };
    const User = struct { items: []const Item };
    const View = struct { enabled: bool, user: ?User };
    const Page = html_template.Template(.{
        .View = View,
        .source = source(
            "nested-controls",
            "{{#if view.enabled}}{{#with view.user as user}}" ++
                "{{#each user.items as item,index}}[{{index}}:{{item.label}}]" ++
                "{{else}}empty{{/each}}{{else}}none{{/with}}{{else}}off{{/if}}",
        ),
    });
    const items = [_]Item{ .{ .label = "<one>" }, .{ .label = "two" } };
    var storage: [128]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try Page.render(&writer, .{ .enabled = true, .user = .{ .items = &items } }, &.{});
    try std.testing.expectEqualStrings("[0:&lt;one&gt;][1:two]", writer.bytes());
}

test "each without else renders populated and empty collections" {
    const Item = struct { label: []const u8 };
    const Page = html_template.Template(.{
        .View = struct { items: []const Item },
        .source = source(
            "each-without-else",
            "{{#each view.items as item}}<b>{{item.label}}</b>{{/each}}",
        ),
    });
    const items = [_]Item{.{ .label = "<&" }};
    var storage: [64]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try Page.render(&writer, .{ .items = &items }, &.{});
    try std.testing.expectEqualStrings("<b>&lt;&amp;</b>", writer.bytes());
    writer.length = 0;
    try Page.render(&writer, .{ .items = &.{} }, &.{});
    try std.testing.expectEqualStrings("", writer.bytes());
}

test "document templates render through the same typed API" {
    const View = struct { title: []const u8, message: []const u8 };
    const Document = html_template.Template(.{
        .View = View,
        .source = html_source.SourceSpec{
            .kind = .document,
            .graph_name = "document",
            .file_path = "views/document.html",
            .bytes = "<!doctype html><html><head><title>{{view.title}}</title></head>" ++
                "<body><p>{{view.message}}</p></body></html>",
        },
    });
    var storage: [256]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try Document.render(&writer, .{ .title = "Doc", .message = "<safe>" }, &.{});
    try std.testing.expectEqualStrings(
        "<!doctype html><html><head><title>Doc</title></head>" ++
            "<body><p>&lt;safe&gt;</p></body></html>",
        writer.bytes(),
    );
}

test "helpers have exact arguments and finite failures" {
    const View = struct { count: u8, reject: bool };
    const Helpers = struct {
        fn doubled(value: u8) u16 {
            return @as(u16, value) * 2;
        }

        fn checked(reject: bool) error{Rejected}![]const u8 {
            if (reject) return error.Rejected;
            return "accepted";
        }
    };
    const Page = html_template.Template(.{
        .View = View,
        .source = source("helpers", "{{doubled view.count}}/{{checked view.reject}}"),
        .helpers = .{ .doubled = Helpers.doubled, .checked = Helpers.checked },
    });
    try std.testing.expect(Page.HelperError == error{Rejected});
    try std.testing.expect(Page.ApplicationError == error{Rejected});
    try std.testing.expect(html_response.TemplateResponse(Page).HelperError == error{Rejected});
    try std.testing.expect(
        html_response.TemplateResponse(Page).ApplicationError == error{Rejected},
    );
    var storage: [64]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try Page.render(&writer, .{ .count = 9, .reject = false }, &.{});
    try std.testing.expectEqualStrings("18/accepted", writer.bytes());

    writer.length = 0;
    try std.testing.expectError(
        error.Rejected,
        Page.render(&writer, .{ .count = 9, .reject = true }, &.{}),
    );
    try std.testing.expectEqualStrings("18/", writer.bytes());
}

test "formatText values preserve their finite error set" {
    const Text = inline_text.InlineText(16);
    const Badge = struct {
        reject: bool,

        pub fn formatText(badge: @This()) error{Rejected}!Text {
            if (badge.reject) return error.Rejected;
            return Text.init("<ready>") catch unreachable;
        }
    };
    const Page = html_template.Template(.{
        .View = struct { badge: Badge },
        .source = source("formatted", "{{view.badge}}"),
    });
    try std.testing.expect(Page.HelperError == error{});
    try std.testing.expect(Page.ApplicationError == error{Rejected});
    var storage: [64]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try Page.render(&writer, .{ .badge = .{ .reject = false } }, &.{});
    try std.testing.expectEqualStrings("&lt;ready&gt;", writer.bytes());
    writer.length = 0;
    try std.testing.expectError(
        error.Rejected,
        Page.render(&writer, .{ .badge = .{ .reject = true } }, &.{}),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.length);
}

test "partials are concrete self-contained graphs" {
    const CardView = struct { label: []const u8 };
    const PageView = struct { card: CardView };
    const identity = struct {
        fn call(label: []const u8) error{Rejected}![]const u8 {
            return label;
        }
    }.call;
    const Page = html_template.Template(.{
        .View = PageView,
        .source = source("partial-page", "before/{{> card view.card}}/after"),
        .partials = .{
            .card = .{
                .View = CardView,
                .source = source("partial-card", "<b>{{identity view.label}}</b>"),
                .helpers = .{ .identity = identity },
            },
        },
    });
    try std.testing.expect(Page.HelperError == error{Rejected});
    try std.testing.expect(Page.ApplicationError == error{Rejected});
    var storage: [128]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try Page.render(&writer, .{ .card = .{ .label = "<&" } }, &.{});
    try std.testing.expectEqualStrings("before/<b>&lt;&amp;</b>/after", writer.bytes());
}

test "layout takes explicit layout and fragment views" {
    const LayoutView = struct { title: []const u8 };
    const BodyView = struct { message: []const u8 };
    const Helpers = struct {
        fn title(value: []const u8) error{LayoutRejected}![]const u8 {
            return value;
        }

        fn body(value: []const u8) error{BodyRejected}![]const u8 {
            return value;
        }
    };
    const Layout = html_template.Template(.{
        .View = LayoutView,
        .source = html_source.SourceSpec{
            .kind = .layout,
            .graph_name = "layout",
            .file_path = "views/layout.html",
            .bytes = "<!doctype html><html><head><title>{{title view.title}}</title></head>" ++
                "<body>{{@body}}</body></html>",
        },
        .helpers = .{ .title = Helpers.title },
    });
    const Body = html_template.Template(.{
        .View = BodyView,
        .source = source("layout-body", "<main>{{body view.message}}</main>"),
        .helpers = .{ .body = Helpers.body },
    });
    const LayoutErrors = error{ LayoutRejected, BodyRejected };
    try std.testing.expect(Layout.LayoutHelperError(Body) == LayoutErrors);
    try std.testing.expect(Layout.LayoutApplicationError(Body) == LayoutErrors);
    try std.testing.expect(html_response.LayoutResponse(Layout, Body).HelperError == LayoutErrors);
    try std.testing.expect(
        html_response.LayoutResponse(Layout, Body).ApplicationError == LayoutErrors,
    );
    var storage: [256]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try Layout.renderLayout(
        Body,
        &writer,
        .{ .title = "Ploof" },
        .{ .message = "safe <body>" },
        &.{},
    );
    try std.testing.expectEqualStrings(
        "<!doctype html><html><head><title>Ploof</title></head>" ++
            "<body><main>safe &lt;body&gt;</main></body></html>",
        writer.bytes(),
    );
}

test "URL contexts revalidate nominal values and enforce asset kinds" {
    const View = struct {
        navigation: url.Url,
        asset: url.Url,
        resource: *const trusted_resource.TrustedResourceUrl,
    };
    const Page = html_template.Template(.{
        .View = View,
        .source = source(
            "urls",
            "<a href='{{view.navigation}}'>go</a>" ++
                "<img src=\"{{view.asset}}\">" ++
                "<script src=\"{{view.resource}}\"></script>",
        ),
    });
    const navigation = try url.Url.local("/search?a=1&b=2");
    const asset = try url.Url.local("/app.js");
    const resource = trusted_resource.TrustedResourceUrl.literal("/trusted.js");
    var storage: [256]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try Page.render(&writer, .{
        .navigation = navigation,
        .asset = asset,
        .resource = resource,
    }, &.{});
    try std.testing.expectEqualStrings(
        "<a href='/search?a=1&amp;b=2'>go</a><img src=\"/app.js\">" ++
            "<script src=\"/trusted.js\"></script>",
        writer.bytes(),
    );

    var mail_storage: [64]u8 = undefined;
    const mail = try url.Url.mailto("a@example.com", &mail_storage);
    writer.length = 0;
    try std.testing.expectError(error.InvalidUrlKind, Page.render(&writer, .{
        .navigation = navigation,
        .asset = mail,
        .resource = resource,
    }, &.{}));
}

test "helpers accept immutable nominal resource capabilities as presentation data" {
    const Helper = struct {
        fn identity(
            value: *const trusted_resource.TrustedResourceUrl,
        ) *const trusted_resource.TrustedResourceUrl {
            return value;
        }
    };
    const Page = html_template.Template(.{
        .View = struct { resource: *const trusted_resource.TrustedResourceUrl },
        .source = source("resource-helper", "<script src=\"{{identity view.resource}}\"></script>"),
        .helpers = .{ .identity = Helper.identity },
    });
    const resource = trusted_resource.TrustedResourceUrl.literal("/trusted.js");
    var storage: [64]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try Page.render(&writer, .{ .resource = resource }, &.{});
    try std.testing.expectEqualStrings(
        "<script src=\"/trusted.js\"></script>",
        writer.bytes(),
    );
}

test "browser JSON is HTML-safe and uses caller scratch" {
    const View = struct { state: struct { value: []const u8 } };
    const Page = html_template.Template(.{
        .View = View,
        .source = source("browser-json", "{{@jsonData page-state view.state}}"),
        .browser_json = html_render.BrowserJsonOptions{ .encoded_bytes_max = 128 },
    });
    try std.testing.expect(html_template.is(Page));
    try std.testing.expectEqual(@as(u32, 128), Page.json_scratch_bytes_maximum);
    var output: [256]u8 = undefined;
    var scratch: [128]u8 = undefined;
    var writer = BufferWriter.init(&output);
    try Page.render(&writer, .{ .state = .{ .value = "</script><&" } }, &scratch);
    try std.testing.expectEqualStrings(
        "<script type=\"application/json\" id=\"page-state\">" ++
            "{\"value\":\"\\u003c/script\\u003e\\u003c\\u0026\"}</script>",
        writer.bytes(),
    );

    var tiny: [1]u8 = undefined;
    writer.length = 0;
    try std.testing.expectError(
        error.ResponseBodyTooLarge,
        Page.render(&writer, .{ .state = .{ .value = "large" } }, &tiny),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.length);
}

test "browser JSON ids may repeat across mutually exclusive partial branches" {
    const View = struct { first: bool, state: u8 };
    const Page = html_template.Template(.{
        .View = View,
        .source = source(
            "exclusive-json",
            "{{#if view.first}}{{> first view}}{{else}}{{> second view}}{{/if}}",
        ),
        .partials = .{
            .first = jsonPartial(View, "first-json"),
            .second = jsonPartial(View, "second-json"),
        },
    });
    var output: [128]u8 = undefined;
    var scratch: [32]u8 = undefined;
    var writer = BufferWriter.init(&output);
    try Page.render(&writer, .{ .first = false, .state = 7 }, &scratch);
    try std.testing.expectEqualStrings(
        "<script type=\"application/json\" id=\"state\">7</script>",
        writer.bytes(),
    );
}

test "template encoded byte limit accepts its exact hard maximum" {
    const Page = html_template.Template(.{
        .View = struct {},
        .source = source("encoded-hard-max", ""),
        .encoded_bytes_max = html_template.encoded_bytes_hard_max,
    });
    try std.testing.expectEqual(
        html_template.encoded_bytes_hard_max,
        Page.encoded_bytes_maximum,
    );
}

test "render operation budget accepts exact boundary and stops before more output" {
    const View = struct { items: []const u16 };
    const Exact = html_template.Template(.{
        .View = View,
        .source = source("render-work-exact", "{{#each view.items as item}}x{{/each}}"),
        .render_operations_max = 3,
    });
    const Tight = html_template.Template(.{
        .View = View,
        .source = source("render-work-tight", "{{#each view.items as item}}x{{/each}}"),
        .render_operations_max = 2,
    });
    const items = [_]u16{ 1, 2 };
    var storage: [8]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try Exact.render(&writer, .{ .items = &items }, &.{});
    try std.testing.expectEqualStrings("xx", writer.bytes());

    writer.length = 0;
    try std.testing.expectError(
        error.RenderWorkExhausted,
        Tight.render(&writer, .{ .items = &items }, &.{}),
    );
    try std.testing.expectEqualStrings("x", writer.bytes());
}

test "nested zero-output each loops consume the shared operation budget" {
    const View = struct { groups: []const []const u16 };
    const Page = html_template.Template(.{
        .View = View,
        .source = source(
            "render-work-nested",
            "{{#each view.groups as group}}" ++
                "{{#each group as item}}{{/each}}{{/each}}",
        ),
        .render_operations_max = 10,
    });
    const first = [_]u16{ 1, 2, 3 };
    const second = [_]u16{ 4, 5, 6 };
    const groups = [_][]const u16{ &first, &second };
    var storage: [1]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try std.testing.expectError(
        error.RenderWorkExhausted,
        Page.render(&writer, .{ .groups = &groups }, &.{}),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.length);
}

test "partial invocations share one root render operation budget" {
    const Card = struct { label: []const u8 };
    const View = struct { card: Card };
    const partial = comptime .{
        .View = Card,
        .source = source("render-work-card", "{{view.label}}"),
    };
    const Exact = html_template.Template(.{
        .View = View,
        .source = source(
            "render-work-partial-exact",
            "{{> card view.card}}{{> card view.card}}",
        ),
        .partials = .{ .card = partial },
        .render_operations_max = 4,
    });
    const Tight = html_template.Template(.{
        .View = View,
        .source = source(
            "render-work-partial-tight",
            "{{> card view.card}}{{> card view.card}}",
        ),
        .partials = .{ .card = partial },
        .render_operations_max = 3,
    });
    var storage: [8]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try Exact.render(&writer, .{ .card = .{ .label = "x" } }, &.{});
    try std.testing.expectEqualStrings("xx", writer.bytes());

    writer.length = 0;
    try std.testing.expectError(
        error.RenderWorkExhausted,
        Tight.render(&writer, .{ .card = .{ .label = "x" } }, &.{}),
    );
    try std.testing.expectEqualStrings("x", writer.bytes());
}

test "layout and body share the layout render operation budget" {
    const Body = html_template.Template(.{
        .View = struct { message: []const u8 },
        .source = source(
            "render-work-layout-body",
            "{{view.message}}{{view.message}}",
        ),
        .render_operations_max = 1,
    });
    const Exact = renderWorkLayout(4, "render-work-layout-exact");
    const Tight = renderWorkLayout(3, "render-work-layout-tight");
    var storage: [128]u8 = undefined;
    var writer = BufferWriter.init(&storage);
    try Exact.renderLayout(Body, &writer, .{ .prefix = "x" }, .{ .message = "y" }, &.{});
    try std.testing.expect(std.mem.indexOf(u8, writer.bytes(), "<body>xyy</body>") != null);

    writer.length = 0;
    try std.testing.expectError(
        error.RenderWorkExhausted,
        Tight.renderLayout(Body, &writer, .{ .prefix = "x" }, .{ .message = "y" }, &.{}),
    );
    try std.testing.expect(std.mem.endsWith(u8, writer.bytes(), "<body>xy"));

    writer.length = 0;
    try std.testing.expectError(
        error.RenderWorkExhausted,
        Body.render(&writer, .{ .message = "y" }, &.{}),
    );
    try std.testing.expectEqualStrings("y", writer.bytes());
}

test "render operation limit exposes finite defaults and accepts exact hard maximum" {
    const Default = html_template.Template(.{
        .View = struct {},
        .source = source("render-work-default", ""),
    });
    const Hard = html_template.Template(.{
        .View = struct {},
        .source = source("render-work-hard", ""),
        .render_operations_max = html_template.render_operations_hard_max,
    });
    try std.testing.expectEqual(
        html_template.standard_render_operations_max,
        Default.render_operations_maximum,
    );
    try std.testing.expectEqual(
        html_template.render_operations_hard_max,
        Hard.render_operations_maximum,
    );
}

fn renderWorkLayout(comptime operations: u32, comptime name: []const u8) type {
    return html_template.Template(.{
        .View = struct { prefix: []const u8 },
        .source = html_source.SourceSpec{
            .kind = .layout,
            .graph_name = name,
            .file_path = "views/" ++ name ++ ".html",
            .bytes = "<!doctype html><html><head></head><body>" ++
                "{{view.prefix}}{{@body}}</body></html>",
        },
        .render_operations_max = operations,
    });
}

fn jsonPartial(comptime View: type, comptime name: []const u8) struct {
    View: type,
    source: html_source.SourceSpec,
    browser_json: html_render.BrowserJsonOptions,
} {
    return .{
        .View = View,
        .source = source(name, "{{@jsonData state view.state}}"),
        .browser_json = .{ .encoded_bytes_max = 32 },
    };
}

fn source(comptime name: []const u8, comptime bytes: []const u8) html_source.SourceSpec {
    return .{
        .kind = .fragment,
        .graph_name = name,
        .file_path = "views/" ++ name ++ ".html",
        .bytes = bytes,
    };
}
