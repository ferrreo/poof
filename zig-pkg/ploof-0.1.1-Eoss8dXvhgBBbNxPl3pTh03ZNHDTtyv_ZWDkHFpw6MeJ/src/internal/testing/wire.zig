const std = @import("std");

const syntax = @import("../http1/syntax.zig");

pub const Error = error{
    InvalidMethod,
    InvalidTarget,
    InvalidHeader,
    ReservedHeader,
    RequestTooLarge,
};

pub fn writeRequest(output: []u8, request: anytype) Error![]const u8 {
    var used: usize = 0;
    errdefer std.crypto.secureZero(u8, output[0..used]);
    try append(output, &used, request.method);
    if (!syntax.isToken(request.method)) return error.InvalidMethod;
    try append(output, &used, " ");
    try append(output, &used, request.target);
    if (!validTarget(request.target)) return error.InvalidTarget;
    try append(output, &used, " HTTP/1.1\r\nHost: ploof.test\r\n");
    for (request.headers) |header| {
        try append(output, &used, header.name);
        if (!syntax.isToken(header.name)) return error.InvalidHeader;
        if (reservedHeader(header.name)) return error.ReservedHeader;
        try append(output, &used, ": ");
        try append(output, &used, header.value);
        if (!syntax.isFieldValue(header.value)) return error.InvalidHeader;
        try append(output, &used, "\r\n");
    }
    try appendFraming(output, &used, request);
    try appendBody(output, &used, request);
    return output[0..used];
}

fn appendFraming(output: []u8, used: *usize, request: anytype) Error!void {
    if (request.chunked) {
        try append(output, used, "Transfer-Encoding: chunked\r\n");
    } else if (request.body) |body| {
        var length_buffer: [32]u8 = undefined;
        const length = std.fmt.bufPrint(&length_buffer, "{d}", .{body.len}) catch unreachable;
        try append(output, used, "Content-Length: ");
        try append(output, used, length);
        try append(output, used, "\r\n");
    }
    try append(output, used, "Connection: close\r\n\r\n");
}

fn appendBody(output: []u8, used: *usize, request: anytype) Error!void {
    if (!request.chunked) {
        if (request.body) |body| try append(output, used, body);
        return;
    }
    const body = request.body orelse "";
    if (body.len != 0) {
        var length_buffer: [32]u8 = undefined;
        const length = std.fmt.bufPrint(&length_buffer, "{x}", .{body.len}) catch unreachable;
        try append(output, used, length);
        try append(output, used, "\r\n");
        try append(output, used, body);
        try append(output, used, "\r\n");
    }
    try append(output, used, "0\r\n\r\n");
}

fn append(output: []u8, used: *usize, bytes: []const u8) Error!void {
    if (bytes.len > output.len - used.*) return error.RequestTooLarge;
    @memcpy(output[used.*..][0..bytes.len], bytes);
    used.* += bytes.len;
}

fn reservedHeader(name: []const u8) bool {
    const reserved = [_][]const u8{
        "Host",
        "Content-Length",
        "Connection",
        "Transfer-Encoding",
    };
    for (reserved) |candidate| {
        if (syntax.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn validTarget(target: []const u8) bool {
    if (target.len == 0 or (target[0] != '/' and !std.mem.eql(u8, target, "*"))) {
        return false;
    }
    for (target) |byte| {
        if (byte == ' ' or byte == '\r' or byte == '\n') return false;
    }
    return true;
}
