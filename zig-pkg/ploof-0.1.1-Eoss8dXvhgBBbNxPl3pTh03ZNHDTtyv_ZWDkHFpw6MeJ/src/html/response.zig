const html_template = @import("template.zig");
const response = @import("../response.zig");

var brand_token: u8 = 0;
const brand = &brand_token;

pub fn TemplateResponse(comptime Page: type) type {
    validateTemplate(Page);
    return struct {
        const __ploof_html_response_brand = brand;
        pub const encoded_bytes_max = Page.encoded_bytes_maximum;
        pub const render_operations_max = Page.render_operations_maximum;
        pub const json_scratch_bytes_max = Page.json_scratch_bytes_maximum;
        pub const ApplicationError = Page.ApplicationError;
        pub const HelperError = Page.HelperError;

        status: response.Status,
        view: Page.View,

        pub fn render(value: @This(), writer: anytype, scratch: []u8) !void {
            return Page.render(writer, value.view, scratch);
        }
    };
}

pub fn LayoutResponse(comptime Layout: type, comptime Body: type) type {
    validateTemplate(Layout);
    validateTemplate(Body);
    const BodyView = Layout.LayoutBodyView(Body);
    return struct {
        const __ploof_html_response_brand = brand;
        pub const encoded_bytes_max = Layout.encoded_bytes_maximum;
        pub const render_operations_max = Layout.render_operations_maximum;
        pub const json_scratch_bytes_max = @max(
            Layout.json_scratch_bytes_maximum,
            Body.json_scratch_bytes_maximum,
        );
        pub const ApplicationError = Layout.LayoutApplicationError(Body);
        pub const HelperError = Layout.LayoutHelperError(Body);

        status: response.Status,
        layout_view: Layout.View,
        body_view: BodyView,

        pub fn render(value: @This(), writer: anytype, scratch: []u8) !void {
            return Layout.renderLayout(
                Body,
                writer,
                value.layout_view,
                value.body_view,
                scratch,
            );
        }
    };
}

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "__ploof_html_response_brand")) {
        return false;
    }
    const candidate_brand = @field(T, "__ploof_html_response_brand");
    if (@TypeOf(candidate_brand) != @TypeOf(brand)) return false;
    if (candidate_brand != brand) return false;
    return @hasDecl(T, "encoded_bytes_max") and @hasDecl(T, "render_operations_max") and
        @hasDecl(T, "json_scratch_bytes_max") and @hasDecl(T, "ApplicationError") and
        @hasDecl(T, "HelperError") and @hasDecl(T, "render");
}

fn validateTemplate(comptime Template: type) void {
    if (!html_template.is(Template)) {
        @compileError("context HTML response requires html.Template");
    }
    if (Template.encoded_bytes_maximum == 0 or
        Template.encoded_bytes_maximum > html_template.encoded_bytes_hard_max)
    {
        @compileError("invalid compiled template encoded byte limit");
    }
    if (Template.render_operations_maximum == 0 or
        Template.render_operations_maximum > html_template.render_operations_hard_max)
    {
        @compileError("invalid compiled template render operation limit");
    }
}
