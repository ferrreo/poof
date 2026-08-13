pub fn writeString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '\\', '"' => {
            try writer.writeByte('\\');
            try writer.writeByte(byte);
        },
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}
