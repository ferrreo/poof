const ploof = @import("ploof_compile").ploof;

const Fake = struct {
    bytes_value: []const u8,

    pub const ploof_trusted_html = true;
    pub const bytes_maximum: u32 = 32;

    pub fn validatedBytes(value: Fake) error{}![]const u8 {
        return value.bytes_value;
    }
};

const Writer = struct {
    pub fn write(_: *Writer, _: []const u8) error{}!void {}
};

pub fn main() void {
    var writer = Writer{};
    ploof.Html.writeTrustedHtml(&writer, Fake{ .bytes_value = "<script>" }) catch {};
}
