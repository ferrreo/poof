const ploof = @import("ploof_compile").ploof;
const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;

const FakeTrustedHtml = struct {
    bytes: []const u8,

    pub const ploof_trusted_html = true;
    pub const bytes_maximum: u32 = 32;

    pub fn literal(comptime value: []const u8) FakeTrustedHtml {
        return .{ .bytes = value };
    }

    pub fn unsafeAssumeSanitized(value: []const u8) error{}!FakeTrustedHtml {
        return .{ .bytes = value };
    }

    pub fn validatedBytes(value: FakeTrustedHtml) error{}![]const u8 {
        return value.bytes;
    }
};

pub fn main() void {
    _ = template.Template(.{
        .View = struct { markup: FakeTrustedHtml },
        .source = source.SourceSpec{
            .kind = .fragment,
            .graph_name = "trusted-html-spoof",
            .file_path = "trusted-html-spoof.html",
            .bytes = "{{view.markup}}",
        },
    });
}
