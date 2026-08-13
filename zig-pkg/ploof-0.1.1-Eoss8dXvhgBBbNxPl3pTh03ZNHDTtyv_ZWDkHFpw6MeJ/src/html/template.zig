const std = @import("std");
const compile = @import("../internal/html/template_compile.zig");
const diagnostic = @import("../internal/html/template_diagnostic.zig");
const runtime = @import("../internal/html/template_runtime.zig");
const types = @import("../internal/html/template_types.zig");

pub const standard_encoded_bytes_max: u32 = 1024 * 1024;
pub const encoded_bytes_hard_max: u32 = 64 * 1024 * 1024;
pub const standard_render_operations_max: u32 = 1024 * 1024;
pub const render_operations_hard_max: u32 = 64 * 1024 * 1024;
const TemplateBrand = opaque {};

pub fn is(comptime Candidate: type) bool {
    if (@typeInfo(Candidate) != .@"struct" or
        !@hasDecl(Candidate, "ploof_html_template_brand")) return false;
    const candidate_brand = @field(Candidate, "ploof_html_template_brand");
    if (@TypeOf(candidate_brand) != type) return false;
    return candidate_brand == TemplateBrand;
}

pub fn Template(comptime config: anytype) type {
    const Root = compile.Node(config, .{});
    comptime compile.validateGraph(Root);
    const TemplateErrors = compile.TemplateError(Root);
    const encoded_bytes_max = comptime encodedBytesMax(config);
    const render_operations_max = comptime renderOperationsMax(config);
    const json_scratch_bytes_max = comptime jsonScratchBytesMax(Root, encoded_bytes_max);
    return struct {
        pub const ploof_html_template = true;
        pub const View = Root.ViewType;
        pub const Error = TemplateErrors;
        pub const HelperError = compile.TemplateHelperError(Root);
        pub const ApplicationError = compile.TemplateApplicationError(Root);
        pub const kind = Root.SourceType.kind;
        pub const graph_name = Root.SourceType.graph_name;
        pub const file_path = Root.SourceType.file_path;
        pub const template_node = Root;
        pub const encoded_bytes_maximum = encoded_bytes_max;
        pub const render_operations_maximum = render_operations_max;
        pub const json_scratch_bytes_maximum = json_scratch_bytes_max;
        const ploof_html_template_brand = TemplateBrand;

        pub fn RenderError(comptime Writer: type) type {
            return templateRenderError(Root, Writer);
        }

        pub fn render(
            writer: anytype,
            view: View,
            json_scratch: []u8,
        ) RenderError(@TypeOf(writer))!void {
            return renderTemplate(
                Root,
                render_operations_max,
                writer,
                view,
                json_scratch,
            );
        }

        pub fn LayoutError(comptime Body: type, comptime Writer: type) type {
            return layoutRenderError(Root, Body, Writer);
        }

        pub fn LayoutHelperError(comptime Body: type) type {
            const BodyNode = checkedBody(Body, Root);
            return HelperError || compile.TemplateHelperError(BodyNode);
        }

        pub fn LayoutApplicationError(comptime Body: type) type {
            const BodyNode = checkedBody(Body, Root);
            return ApplicationError || compile.TemplateApplicationError(BodyNode);
        }

        pub fn LayoutBodyView(comptime Body: type) type {
            return BodyView(Body, Root);
        }

        pub fn renderLayout(
            comptime Body: type,
            writer: anytype,
            layout_view: View,
            body_view: BodyView(Body, Root),
            json_scratch: []u8,
        ) LayoutError(Body, @TypeOf(writer))!void {
            return renderTemplateLayout(
                Root,
                Body,
                render_operations_max,
                writer,
                layout_view,
                body_view,
                json_scratch,
            );
        }
    };
}

fn templateRenderError(comptime Root: type, comptime Writer: type) type {
    return compile.TemplateError(Root) || types.WriterError(Writer);
}

fn renderTemplate(
    comptime Root: type,
    comptime operations_max: u32,
    writer: anytype,
    view: Root.ViewType,
    json_scratch: []u8,
) templateRenderError(Root, @TypeOf(writer))!void {
    if (comptime Root.SourceType.kind == .layout) {
        diagnostic.fail(
            .invalid_render_kind,
            Root.SourceType,
            0,
            "layout requires renderLayout with an explicit body template",
        );
    }
    const Errors = templateRenderError(Root, @TypeOf(writer));
    return runtime.render(Root, Errors, operations_max, writer, view, json_scratch);
}

fn layoutRenderError(comptime Layout: type, comptime Body: type, comptime Writer: type) type {
    const BodyNode = checkedBody(Body, Layout);
    return compile.TemplateError(Layout) || compile.TemplateError(BodyNode) ||
        types.WriterError(Writer);
}

fn renderTemplateLayout(
    comptime Layout: type,
    comptime Body: type,
    comptime operations_max: u32,
    writer: anytype,
    layout_view: Layout.ViewType,
    body_view: BodyView(Body, Layout),
    json_scratch: []u8,
) layoutRenderError(Layout, Body, @TypeOf(writer))!void {
    const BodyNode = checkedBody(Body, Layout);
    const Errors = layoutRenderError(Layout, Body, @TypeOf(writer));
    return runtime.renderLayout(
        Layout,
        BodyNode,
        Errors,
        operations_max,
        writer,
        layout_view,
        body_view,
        json_scratch,
    );
}

fn renderOperationsMax(comptime config: anytype) u32 {
    if (!@hasField(@TypeOf(config), "render_operations_max")) {
        return standard_render_operations_max;
    }
    const value = config.render_operations_max;
    const T = @TypeOf(value);
    if (@typeInfo(T) != .comptime_int and @typeInfo(T) != .int) {
        @compileError("PLOOF-E3963 template render operation limit must be an integer");
    }
    if (value <= 0) {
        @compileError("PLOOF-E3964 template render operation limit must be nonzero");
    }
    if (value > render_operations_hard_max) {
        @compileError("PLOOF-E3965 template render operation limit exceeds 64 Mi operations");
    }
    return @intCast(value);
}

fn encodedBytesMax(comptime config: anytype) u32 {
    if (!@hasField(@TypeOf(config), "encoded_bytes_max")) {
        return standard_encoded_bytes_max;
    }
    const value = config.encoded_bytes_max;
    const T = @TypeOf(value);
    if (@typeInfo(T) != .comptime_int and @typeInfo(T) != .int) {
        @compileError("PLOOF-E3960 template encoded byte limit must be an integer");
    }
    if (value <= 0) {
        @compileError("PLOOF-E3961 template encoded byte limit must be nonzero");
    }
    if (value > encoded_bytes_hard_max) {
        @compileError("PLOOF-E3962 template encoded byte limit exceeds 64 MiB");
    }
    return @intCast(value);
}

fn jsonScratchBytesMax(comptime Root: type, comptime encoded_bytes_max: u32) u32 {
    const maximum = compile.browserJsonScratchBytes(Root);
    if (maximum > encoded_bytes_max) {
        diagnostic.fail(
            .browser_json_limit,
            Root.SourceType,
            0,
            "browser JSON scratch limit exceeds template encoded byte limit",
        );
    }
    return @intCast(maximum);
}

comptime {
    std.debug.assert(standard_encoded_bytes_max <= encoded_bytes_hard_max);
    std.debug.assert(standard_render_operations_max <= render_operations_hard_max);
}

fn BodyView(comptime Body: type, comptime Layout: type) type {
    return checkedBody(Body, Layout).ViewType;
}

fn checkedBody(comptime Body: type, comptime Layout: type) type {
    if (Layout.SourceType.kind != .layout) {
        diagnostic.fail(
            .invalid_render_kind,
            Layout.SourceType,
            0,
            "renderLayout is available only on layout templates",
        );
    }
    if (!is(Body)) {
        diagnostic.fail(
            .invalid_layout_body,
            Layout.SourceType,
            0,
            "Body must be a compiled html_template.Template",
        );
    }
    const Node = Body.template_node;
    if (Node.SourceType.kind != .fragment) {
        diagnostic.fail(
            .invalid_layout_body,
            Layout.SourceType,
            0,
            "layout body template must be a fragment",
        );
    }
    compile.validateCombinedJson(Layout, Node);
    return Node;
}
