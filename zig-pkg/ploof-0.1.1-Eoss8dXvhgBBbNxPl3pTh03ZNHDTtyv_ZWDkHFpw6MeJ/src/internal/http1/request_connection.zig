const std = @import("std");
const request_head = @import("request_head.zig");
const syntax = @import("syntax.zig");

pub const Policy = struct {
    close: bool = false,
};

pub const Result = union(enum) {
    accepted: Policy,
    rejected: request_head.Rejection,
};

pub fn analyze(fields: []const request_head.Field, bytes: []const u8) Result {
    var policy = Policy{};
    for (fields) |field| {
        if (!syntax.eqlIgnoreCase(field.name.slice(bytes), "connection")) continue;
        if (!parseValue(field.value.slice(bytes), &policy)) {
            return .{ .rejected = .{ .status = .bad_request } };
        }
    }
    return .{ .accepted = policy };
}

fn parseValue(value: []const u8, policy: *Policy) bool {
    var cursor: usize = 0;
    while (cursor < value.len) {
        const comma = std.mem.indexOfScalarPos(u8, value, cursor, ',') orelse value.len;
        const token = syntax.trimOws(value[cursor..comma]);
        if (!syntax.isToken(token)) return false;
        if (syntax.eqlIgnoreCase(token, "close")) policy.close = true;
        if (comma == value.len) return true;
        cursor = comma + 1;
    }
    return false;
}

const prefix = "GET / HTTP/1.1\r\nHost: example.test\r\n";

test "connection list combines ordered fields and detects close" {
    try expectPolicy(prefix ++ "\r\n", false);
    try expectPolicy(prefix ++ "Connection: keep-alive\r\n\r\n", false);
    try expectPolicy(prefix ++ "Connection: upgrade, CLOSE\r\n\r\n", true);
    try expectPolicy(
        prefix ++ "Connection: keep-alive\r\nConnection:\tclose \r\n\r\n",
        true,
    );
}

test "connection list rejects empty malformed and injected members" {
    const values = [_][]const u8{
        "",
        " ",
        ",close",
        "close,",
        "close,,upgrade",
        "close;wait",
        "\"close\"",
        "close\r\nx-test: bad",
    };
    for (values) |value| {
        var policy = Policy{};
        try std.testing.expect(!parseValue(value, &policy));
    }
}

fn expectPolicy(wire: []const u8, close: bool) !void {
    const Decoder = request_head.Decoder(@import("limits.zig").standard_request_head_limits);
    var decoder = Decoder.init();
    const parsed = decoder.feed(wire);
    const head = switch (parsed.state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    const result = analyze(decoder.fields(), decoder.bytes());
    const policy = switch (result) {
        .accepted => |accepted| accepted,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, head.fields_count), decoder.fields().len);
    try std.testing.expectEqual(close, policy.close);
}
