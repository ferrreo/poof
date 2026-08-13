const std = @import("std");
const limits = @import("limits.zig");
const media_type = @import("media_type.zig");
const response_head = @import("response_head.zig");
const status_module = @import("status.zig");

const line_end = "\r\n";
const server_prefix = "server: ";
const connection_close = "connection: close\r\n";

pub const Plan = struct {
    prefix: []const u8,
    status: status_module.Status,
    media: media_type.MediaType,
    body: []const u8,

    pub fn init(
        comptime status: status_module.Status,
        comptime media: media_type.MediaType,
        comptime body: []const u8,
    ) Plan {
        const status_code = comptime std.fmt.comptimePrint("{d}", .{@intFromEnum(status)});
        const body_length = comptime std.fmt.comptimePrint("{d}", .{body.len});
        const reason = comptime status.reasonPhrase();
        const selected_media = comptime media.bytes();
        const prefix = status_code ++ " " ++ reason ++
            "\r\ncontent-type: " ++ selected_media ++ "\r\ncontent-length: " ++
            body_length ++ "\r\ndate: ";
        return .{
            .prefix = "HTTP/1.1 " ++ prefix,
            .status = status,
            .media = media,
            .body = body,
        };
    }
};

pub fn write(
    comptime requested: limits.ResponseHeadLimits,
    output: []u8,
    plan: Plan,
    date: []const u8,
    server: ?response_head.ServerIdentity,
    close: bool,
) response_head.WriteError![]const u8 {
    const profile = comptime requested.validate();
    if (date.len == 0 or !response_head.validFieldValue(date)) return error.InvalidDate;
    const server_length = if (server) |value|
        server_prefix.len + value.value.len + line_end.len
    else
        0;
    const close_length = if (close) connection_close.len else 0;
    const date_length = std.math.add(usize, date.len, line_end.len) catch
        return error.ResponseHeadTooLarge;
    const total = std.math.add(usize, plan.prefix.len, date_length) catch
        return error.ResponseHeadTooLarge;
    const with_fields = std.math.add(
        usize,
        total,
        server_length + close_length + line_end.len,
    ) catch return error.ResponseHeadTooLarge;
    const fields = @as(usize, 3) + @intFromBool(server != null) + @intFromBool(close);
    if (fields > profile.fields_max or with_fields > profile.head_bytes_max) {
        return error.ResponseHeadTooLarge;
    }
    try validateFieldLine(profile, "content-type", plan.media.bytes().len);
    try validateFieldLine(profile, "content-length", decimalLength(plan.body.len));
    try validateFieldLine(profile, "date", date.len);
    if (server) |value| try validateFieldLine(profile, "server", value.value.len);
    if (close) try validateFieldLine(profile, "connection", "close".len);
    if (output.len < with_fields) return error.OutputTooSmall;

    var cursor: usize = 0;
    append(output, &cursor, plan.prefix);
    append(output, &cursor, date);
    append(output, &cursor, line_end);
    if (server) |value| {
        append(output, &cursor, server_prefix);
        append(output, &cursor, value.value);
        append(output, &cursor, line_end);
    }
    if (close) append(output, &cursor, connection_close);
    append(output, &cursor, line_end);
    std.debug.assert(cursor == with_fields);
    return output[0..cursor];
}

fn validateFieldLine(
    profile: limits.ResponseHeadLimits,
    name: []const u8,
    value_length: usize,
) response_head.WriteError!void {
    const overhead = name.len + ": \r\n".len;
    if (overhead > profile.field_line_bytes_max or
        value_length > profile.field_line_bytes_max - overhead)
    {
        return error.ResponseHeadTooLarge;
    }
}

fn decimalLength(value: usize) usize {
    var remaining = value;
    var digits: usize = 1;
    while (remaining >= 10) : (digits += 1) remaining /= 10;
    return digits;
}

fn append(output: []u8, cursor: *usize, bytes: []const u8) void {
    @memcpy(output[cursor.*..][0..bytes.len], bytes);
    cursor.* += bytes.len;
}

test {
    std.testing.refAllDecls(@This());
}
