const html_source = @import("../../html/source.zig");

pub fn isControl(kind: html_source.DirectiveKind) bool {
    return kind == .if_open or kind == .with_open or kind == .each_open;
}

pub fn writeStatic(writer: anytype, bytes: []const u8) !void {
    if (bytes.len != 0) try writer.write(bytes);
}

pub fn spendOperation(remaining: *u32) error{RenderWorkExhausted}!void {
    if (remaining.* == 0) return error.RenderWorkExhausted;
    remaining.* -= 1;
}

pub fn htmlSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == '\x0c';
}
