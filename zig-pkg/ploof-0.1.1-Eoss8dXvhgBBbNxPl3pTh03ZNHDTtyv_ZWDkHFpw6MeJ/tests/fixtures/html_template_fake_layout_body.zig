const ploof = @import("ploof_compile").ploof;

const Fake = struct {
    pub const ploof_html_template = true;
    pub const template_node = struct {};
};

pub fn main() void {
    const Layout = ploof.HtmlTemplate.Template(.{
        .View = struct {},
        .source = ploof.HtmlSource.SourceSpec{
            .kind = .layout,
            .graph_name = "fake-layout-body",
            .file_path = "fake-layout-body.html",
            .bytes = "<!doctype html><html><head></head><body>{{@body}}</body></html>",
        },
    });
    _ = Layout.LayoutBodyView(Fake);
}
