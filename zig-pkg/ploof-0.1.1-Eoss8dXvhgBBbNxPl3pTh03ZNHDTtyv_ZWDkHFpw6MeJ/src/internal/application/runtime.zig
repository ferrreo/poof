const std = @import("std");
const application_context = @import("../../application/context.zig");
const syntax = @import("../http1/syntax.zig");

pub const RedirectError = error{ RedirectLocationTooLarge, InvalidRoutePlan };

pub fn terminalSlashIsLiteral(input: anytype) bool {
    if (input.path.len == 0 or input.path[input.path.len - 1] != '/') return true;
    return input.raw_path.len != 0 and input.raw_path[input.raw_path.len - 1] == '/';
}

pub fn headLimitsEqual(left: anytype, right: @TypeOf(left)) bool {
    return left.head_bytes_max == right.head_bytes_max and
        left.field_line_bytes_max == right.field_line_bytes_max and
        left.fields_max == right.fields_max;
}

pub fn requestFromInput(input: application_context.Input) application_context.Request {
    return .{
        .method = input.method,
        .raw_target = input.raw_target,
        .raw_path = input.raw_path,
        .path = input.path,
        .raw_query = input.raw_query,
        .accepts_response_trailers = input.accepts_response_trailers,
        .trailers = input.trailers,
        .headers = input.headers,
        .forwarding = input.forwarding,
    };
}

pub fn buildRedirectLocation(
    workspace: anytype,
    input: anytype,
    redirect: anytype,
) RedirectError![]const u8 {
    if (!rawPathMatches(input.raw_path, input.path)) return error.InvalidRoutePlan;
    const add_slash = redirect.slash_change == .add;
    const source_length = if (add_slash) input.raw_path.len else remove: {
        if (input.raw_path.len <= 1) return error.InvalidRoutePlan;
        if (input.raw_path[input.raw_path.len - 1] != '/') return error.InvalidRoutePlan;
        break :remove input.raw_path.len - 1;
    };
    const plain_length = std.math.add(
        usize,
        source_length,
        @intFromBool(add_slash),
    ) catch return error.RedirectLocationTooLarge;
    const second_byte: ?u8 = if (plain_length < 2)
        null
    else if (source_length >= 2)
        input.raw_path[1]
    else
        '/';
    const escape_second_slash = second_byte == '/';
    const path_length = std.math.add(
        usize,
        plain_length,
        if (escape_second_slash) 2 else 0,
    ) catch return error.RedirectLocationTooLarge;
    const query = input.raw_query orelse "";
    const query_separator = @intFromBool(input.raw_query != null);
    const with_separator = std.math.add(usize, path_length, query_separator) catch {
        return error.RedirectLocationTooLarge;
    };
    const total = std.math.add(usize, with_separator, query.len) catch {
        return error.RedirectLocationTooLarge;
    };
    if (total > workspace.redirect_location.len) return error.RedirectLocationTooLarge;
    const output = workspace.redirect_location[0..total];
    var cursor: usize = 0;
    const source_start: usize = if (escape_second_slash) escaped: {
        @memcpy(output[0..4], "/%2F");
        cursor = 4;
        break :escaped @min(source_length, 2);
    } else 0;
    const source = input.raw_path[source_start..source_length];
    @memcpy(output[cursor..][0..source.len], source);
    cursor += source.len;
    if (add_slash and !(escape_second_slash and source_length == 1)) {
        output[cursor] = '/';
        cursor += 1;
    }
    std.debug.assert(cursor == path_length);
    if (input.raw_query != null) {
        output[cursor] = '?';
        @memcpy(output[cursor + 1 ..], query);
    }
    return output;
}

fn rawPathMatches(raw_path: []const u8, decoded_path: []const u8) bool {
    if (raw_path.len == 0 or raw_path[0] != '/') return false;
    var raw_index: usize = 0;
    var decoded_index: usize = 0;
    while (raw_index < raw_path.len) {
        const byte = if (raw_path[raw_index] == '%') decoded: {
            if (raw_index + 2 >= raw_path.len) return false;
            const high = hexNibble(raw_path[raw_index + 1]) orelse return false;
            const low = hexNibble(raw_path[raw_index + 2]) orelse return false;
            raw_index += 3;
            break :decoded high << 4 | low;
        } else decoded: {
            const value = raw_path[raw_index];
            if (value != '/' and !syntax.isUriPchar(value)) return false;
            raw_index += 1;
            break :decoded value;
        };
        if (decoded_index >= decoded_path.len or decoded_path[decoded_index] != byte) return false;
        decoded_index += 1;
    }
    return decoded_index == decoded_path.len;
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

test "redirect slash removal rejects forged raw paths in every build mode" {
    var workspace: struct { redirect_location: [32]u8 = undefined } = .{};
    const redirect = .{ .slash_change = @import("../route_graph.zig").SlashChange.remove };
    inline for (.{ "", "/", "/missing" }) |raw_path| {
        try std.testing.expectError(
            error.InvalidRoutePlan,
            buildRedirectLocation(
                &workspace,
                .{
                    .path = raw_path,
                    .raw_path = raw_path,
                    .raw_query = @as(?[]const u8, null),
                },
                redirect,
            ),
        );
    }
    const valid = try buildRedirectLocation(
        &workspace,
        .{
            .path = "/valid/",
            .raw_path = "/valid/",
            .raw_query = @as(?[]const u8, "x=1"),
        },
        redirect,
    );
    try std.testing.expectEqualStrings("/valid?x=1", valid);
}

test "redirect locations cannot become network-path references" {
    var workspace: struct { redirect_location: [64]u8 = undefined } = .{};
    const route_graph = @import("../route_graph.zig");
    const cases = .{
        .{
            "//evil.example/",
            "//evil.example/",
            route_graph.SlashChange.remove,
            "/%2Fevil.example",
        },
        .{
            "/%5Cevil.example/",
            "/\\evil.example/",
            route_graph.SlashChange.remove,
            "/%5Cevil.example",
        },
        .{ "/", "/", route_graph.SlashChange.add, "/%2F" },
        .{
            "/%2Fevil.example/",
            "//evil.example/",
            route_graph.SlashChange.remove,
            "/%2Fevil.example",
        },
    };
    inline for (cases) |case| {
        const location = try buildRedirectLocation(
            &workspace,
            .{
                .raw_path = case[0],
                .path = case[1],
                .raw_query = @as(?[]const u8, null),
            },
            .{ .slash_change = case[2] },
        );
        try std.testing.expectEqualStrings(case[3], location);
    }
}

test "redirect network-path escaping preserves queries for add and remove" {
    var workspace: struct { redirect_location: [64]u8 = undefined } = .{};
    const route_graph = @import("../route_graph.zig");
    const added = try buildRedirectLocation(
        &workspace,
        .{
            .raw_path = "//evil",
            .path = "//evil",
            .raw_query = @as(?[]const u8, "x=1"),
        },
        .{ .slash_change = route_graph.SlashChange.add },
    );
    try std.testing.expectEqualStrings("/%2Fevil/?x=1", added);
    const removed = try buildRedirectLocation(
        &workspace,
        .{
            .raw_path = "///evil/",
            .path = "///evil/",
            .raw_query = @as(?[]const u8, ""),
        },
        .{ .slash_change = route_graph.SlashChange.remove },
    );
    try std.testing.expectEqualStrings("/%2F/evil?", removed);
}

test "redirect validation is transactional at the escaped capacity boundary" {
    const route_graph = @import("../route_graph.zig");
    inline for (.{ route_graph.SlashChange.add, route_graph.SlashChange.remove }) |change| {
        const raw_path = if (change == .add) "//evil" else "//evil/";
        const capacity = if (change == .add) 8 else 7;
        var workspace: struct {
            redirect_location: [capacity]u8 = [_]u8{0xa5} ** capacity,
        } = .{};
        try std.testing.expectError(
            error.RedirectLocationTooLarge,
            buildRedirectLocation(
                &workspace,
                .{
                    .raw_path = raw_path,
                    .path = raw_path,
                    .raw_query = @as(?[]const u8, null),
                },
                .{ .slash_change = change },
            ),
        );
        try std.testing.expectEqualSlices(
            u8,
            &([_]u8{0xa5} ** capacity),
            &workspace.redirect_location,
        );
    }
}

test "redirect validation rejects mismatched raw and decoded paths" {
    var workspace: struct { redirect_location: [64]u8 = undefined } = .{};
    const route_graph = @import("../route_graph.zig");
    inline for (.{ route_graph.SlashChange.add, route_graph.SlashChange.remove }) |change| {
        const raw_path = if (change == .add) "//evil" else "//evil/";
        try std.testing.expectError(
            error.InvalidRoutePlan,
            buildRedirectLocation(
                &workspace,
                .{
                    .raw_path = raw_path,
                    .path = "/different",
                    .raw_query = @as(?[]const u8, null),
                },
                .{ .slash_change = change },
            ),
        );
    }
}

test "redirect validation rejects raw bytes outside URI path grammar" {
    var workspace: struct { redirect_location: [64]u8 = undefined } = .{};
    const route_graph = @import("../route_graph.zig");
    inline for (.{ "/\\evil/", "/\t/evil/", "/ evil/" }) |raw_path| {
        try std.testing.expectError(
            error.InvalidRoutePlan,
            buildRedirectLocation(
                &workspace,
                .{
                    .raw_path = raw_path,
                    .path = raw_path,
                    .raw_query = @as(?[]const u8, null),
                },
                .{ .slash_change = route_graph.SlashChange.remove },
            ),
        );
    }
}
