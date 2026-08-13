const std = @import("std");
const ploof = @import("ploof");

pub const Value = ploof.Json.Value;

pub fn field(root: *const Value, name: []const u8) ?*const Value {
    return root.get(name) catch null;
}

pub fn string(root: *const Value, name: []const u8) ?[]const u8 {
    const value = field(root, name) orelse return null;
    return switch (value.*) {
        .string => |text| text,
        else => null,
    };
}

pub fn boolean(root: *const Value, name: []const u8) ?bool {
    const value = field(root, name) orelse return null;
    return switch (value.*) {
        .boolean => |selected| selected,
        else => null,
    };
}

pub fn integer(root: *const Value, name: []const u8) ?i64 {
    const value = field(root, name) orelse return null;
    return switch (value.*) {
        .number => |number| number.asInt(i64) catch null,
        else => null,
    };
}

pub fn object(object_value: *const Value, name: []const u8) ?*const Value {
    const value = field(object_value, name) orelse return null;
    return switch (value.*) {
        .object => value,
        else => null,
    };
}

pub fn writeId(writer: *std.Io.Writer, id: ?*const Value) std.Io.Writer.Error!void {
    const value = id orelse return writer.writeAll("null");
    switch (value.*) {
        .null => try writer.writeAll("null"),
        .string => |text| try writeJsonString(writer, text),
        .number => |number| try writer.writeAll(number.bytes()),
        else => try writer.writeAll("null"),
    }
}

pub fn writeJsonString(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11...12, 14...0x1f => try writer.print("\\u00{x:0>2}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

pub fn beginResult(
    writer: *std.Io.Writer,
    id: ?*const Value,
) std.Io.Writer.Error!void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(writer, id);
    try writer.writeAll(",\"result\":");
}

pub fn writeError(
    writer: *std.Io.Writer,
    id: ?*const Value,
    code: i32,
    message: []const u8,
) std.Io.Writer.Error!void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(writer, id);
    try writer.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try writeJsonString(writer, message);
    try writer.writeAll("}}");
}

pub fn writeToolText(
    writer: *std.Io.Writer,
    text: []const u8,
) std.Io.Writer.Error!void {
    try writer.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(writer, text);
    try writer.writeAll("}]");
}

test "JSON-RPC strings escape control and executable characters" {
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeJsonString(&writer, "\"line\n<script>");
    try std.testing.expectEqualStrings(
        "\"\\\"line\\n<script>\"",
        storage[0..writer.end],
    );
}
