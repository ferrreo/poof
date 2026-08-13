const std = @import("std");
const request_accept_encoding = @import("../http1/request_accept_encoding.zig");
const syntax = @import("../http1/syntax.zig");

pub const cache_control = "public, max-age=31536000, immutable";
pub const vary = "Accept-Encoding";
pub const nosniff = "nosniff";

pub const Method = enum(u1) {
    get,
    head,
};

pub const Coding = enum(u1) {
    identity,
    gzip,
};

pub const Selection = struct {
    body: []const u8,
    etag: []const u8,
    media_type: []const u8,
    coding: Coding,
    transfer_body: bool,

    pub fn contentLength(selection: Selection) u64 {
        return selection.body.len;
    }
};

pub const Decision = union(enum) {
    selected: Selection,
    not_acceptable,
};

pub fn select(
    record: anytype,
    method: Method,
    preferences: request_accept_encoding.Preferences,
) Decision {
    std.debug.assert(preferences.gzip <= request_accept_encoding.weight_max);
    std.debug.assert(preferences.identity <= request_accept_encoding.weight_max);

    if (record.gzip) |gzip| {
        if (preferences.gzip != 0 and preferences.gzip >= preferences.identity) {
            return .{ .selected = makeSelection(
                record.media_type,
                gzip,
                method,
                .gzip,
            ) };
        }
    }
    if (preferences.identity == 0) return .not_acceptable;
    return .{ .selected = makeSelection(
        record.media_type,
        record.identity,
        method,
        .identity,
    ) };
}

fn makeSelection(
    media_type: []const u8,
    representation: anytype,
    method: Method,
    coding: Coding,
) Selection {
    return .{
        .body = representation.bytes,
        .etag = representation.etag,
        .media_type = media_type,
        .coding = coding,
        .transfer_body = method == .get and representation.bytes.len != 0,
    };
}

pub const IfNoneMatch = struct {
    current_token: []const u8,
    seen: bool = false,
    wildcard: bool = false,
    matched: bool = false,
    valid: bool = true,

    pub fn init(etag: []const u8) IfNoneMatch {
        const tag = parseEntityTag(etag) orelse unreachable;
        return .{ .current_token = tag.token };
    }

    pub fn add(matcher: *IfNoneMatch, value: []const u8) void {
        if (!matcher.valid) return;
        const trimmed = syntax.trimOws(value);
        if (std.mem.eql(u8, trimmed, "*")) {
            if (matcher.seen) return matcher.invalidate();
            matcher.seen = true;
            matcher.wildcard = true;
            return;
        }
        if (matcher.wildcard) return matcher.invalidate();

        var cursor: usize = 0;
        if (trimmed.len == 0) return matcher.invalidate();
        while (cursor < trimmed.len) {
            skipOws(trimmed, &cursor);
            const tag = parseEntityTagAt(trimmed, &cursor) orelse
                return matcher.invalidate();
            matcher.seen = true;
            matcher.matched = matcher.matched or
                std.mem.eql(u8, tag.token, matcher.current_token);
            skipOws(trimmed, &cursor);
            if (cursor == trimmed.len) return;
            if (trimmed[cursor] != ',') return matcher.invalidate();
            cursor += 1;
            skipOws(trimmed, &cursor);
            if (cursor == trimmed.len) return matcher.invalidate();
        }
    }

    pub fn notModified(matcher: IfNoneMatch) bool {
        return matcher.valid and matcher.seen and (matcher.wildcard or matcher.matched);
    }

    fn invalidate(matcher: *IfNoneMatch) void {
        matcher.valid = false;
        matcher.matched = false;
        matcher.wildcard = false;
    }
};

const EntityTag = struct {
    token: []const u8,
};

fn parseEntityTag(value: []const u8) ?EntityTag {
    var cursor: usize = 0;
    const tag = parseEntityTagAt(value, &cursor) orelse return null;
    return if (cursor == value.len) tag else null;
}

fn parseEntityTagAt(value: []const u8, cursor: *usize) ?EntityTag {
    if (value.len - cursor.* >= 2 and std.mem.eql(u8, value[cursor.*..][0..2], "W/")) {
        cursor.* += 2;
    }
    if (cursor.* == value.len or value[cursor.*] != '"') return null;
    cursor.* += 1;
    const start = cursor.*;
    while (cursor.* < value.len) : (cursor.* += 1) {
        const byte = value[cursor.*];
        if (byte == '"') {
            const token = value[start..cursor.*];
            cursor.* += 1;
            return .{ .token = token };
        }
        const visible = byte == 0x21 or (byte >= 0x23 and byte <= 0x7e);
        if (!visible and byte < 0x80) return null;
    }
    return null;
}

fn skipOws(value: []const u8, cursor: *usize) void {
    while (cursor.* < value.len and
        (value[cursor.*] == ' ' or value[cursor.*] == '\t'))
    {
        cursor.* += 1;
    }
}

comptime {
    std.debug.assert(std.mem.eql(u8, vary, "Accept-Encoding"));
}
