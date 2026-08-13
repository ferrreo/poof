const ploof = @import("ploof_compile").ploof;
const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;

fn unsafeHelper(_: u32) anyerror!u32 {
    return 1;
}

pub fn main() void {
    _ = template.Template(.{
        .View = struct { value: u32 },
        .source = source.SourceSpec{
            .kind = .fragment,
            .graph_name = "anyerror-helper",
            .file_path = "anyerror-helper.html",
            .bytes = "{{unsafe view.value}}",
        },
        .helpers = .{ .unsafe = unsafeHelper },
    });
}
