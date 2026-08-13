const std = @import("std");
const route = @import("../../route.zig");

pub const Parsed = enum(u8) {
    get,
    head,
    post,
    put,
    patch,
    delete,
    options,

    pub fn declared(parsed: Parsed) ?route.Method {
        return switch (parsed) {
            .get => .get,
            .head => .head,
            .post => .post,
            .put => .put,
            .patch => .patch,
            .delete => .delete,
            .options => null,
        };
    }
};

pub fn parse(bytes: []const u8) ?Parsed {
    if (equal(bytes, "GET")) return .get;
    if (equal(bytes, "HEAD")) return .head;
    if (equal(bytes, "POST")) return .post;
    if (equal(bytes, "PUT")) return .put;
    if (equal(bytes, "PATCH")) return .patch;
    if (equal(bytes, "DELETE")) return .delete;
    if (equal(bytes, "OPTIONS")) return .options;
    return null;
}

fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
