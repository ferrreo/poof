const json = @import("../../json.zig");

pub const Binding = struct {
    bytes: []u8,
    output: []u8,
    encoded: ?[]const u8 = null,
    written: *bool,
};

pub fn Error(comptime T: type) type {
    return json.EncodeError(T) || error{JsonWorkspaceUnavailable};
}

pub fn encode(
    comptime Response: type,
    response_workspace: anytype,
    binding: ?*Binding,
    comptime options: json.Options,
    comptime status: @import("../../response.zig").Status,
    value: anytype,
) Error(@TypeOf(value))!Response {
    const selected = binding orelse return error.JsonWorkspaceUnavailable;
    const repeated = selected.written.*;
    selected.written.* = true;
    selected.encoded = null;
    const encoded = if (repeated) repeated: {
        if (selected.output.len < selected.bytes.len) {
            return error.JsonWorkspaceUnavailable;
        }
        const temporary = try json.encodeWith(
            options,
            value,
            selected.output[0..selected.bytes.len],
        );
        @memcpy(selected.bytes[0..temporary.len], temporary);
        break :repeated selected.bytes[0..temporary.len];
    } else try json.encodeWith(options, value, selected.bytes);
    selected.encoded = encoded;
    return Response.jsonBorrowed(response_workspace, status, encoded);
}

pub fn outputFor(
    binding: ?*const Binding,
    body: []const u8,
    fallback: []u8,
) []u8 {
    const selected = binding orelse return fallback;
    const encoded = selected.encoded orelse return fallback;
    if (!sameSlice(encoded, body)) return fallback;
    return selected.output;
}

fn sameSlice(left: []const u8, right: []const u8) bool {
    return left.len == right.len and @intFromPtr(left.ptr) == @intFromPtr(right.ptr);
}

test "JSON response binding encodes into its exact borrowed region" {
    const response = @import("../../response.zig");
    const Response = response.Response(response.standard_head_limits);
    const Workspace = response.Workspace(response.standard_head_limits);
    var response_workspace = Workspace{};
    var bytes: [32]u8 = undefined;
    var output: [64]u8 = undefined;
    var written = false;
    var binding = Binding{ .bytes = &bytes, .output = &output, .written = &written };
    const value = try encode(
        Response,
        &response_workspace,
        &binding,
        .{},
        .ok,
        .{ .id = @as(u8, 7) },
    );
    try @import("std").testing.expectEqualStrings("{\"id\":7}", value.bodyBytes());
    try @import("std").testing.expectEqual(
        @intFromPtr(outputFor(&binding, value.bodyBytes(), &bytes).ptr),
        @intFromPtr(output[0..].ptr),
    );
    try @import("std").testing.expectError(
        error.ResponseBodyTooLarge,
        encode(
            Response,
            &response_workspace,
            &binding,
            .{},
            .ok,
            [_]u8{1} ** 64,
        ),
    );
    try @import("std").testing.expectEqual(
        @intFromPtr(outputFor(&binding, value.bodyBytes(), &bytes).ptr),
        @intFromPtr(bytes[0..].ptr),
    );
}

test "repeated JSON response encoding uses disjoint temporary storage" {
    const response = @import("../../response.zig");
    const Response = response.Response(response.standard_head_limits);
    const Workspace = response.Workspace(response.standard_head_limits);
    var response_workspace = Workspace{};
    var bytes: [64]u8 = undefined;
    var output: [128]u8 = undefined;
    var written = false;
    var binding = Binding{ .bytes = &bytes, .output = &output, .written = &written };
    const first = try encode(
        Response,
        &response_workspace,
        &binding,
        .{},
        .ok,
        .{ .value = "source" },
    );
    const second = try encode(
        Response,
        &response_workspace,
        &binding,
        .{},
        .ok,
        .{ .wrapped = first.bodyBytes() },
    );
    try @import("std").testing.expectEqualStrings(
        "{\"wrapped\":\"{\\\"value\\\":\\\"source\\\"}\"}",
        second.bodyBytes(),
    );
    try @import("std").testing.expectEqual(
        @intFromPtr(output[0..].ptr),
        @intFromPtr(outputFor(&binding, second.bodyBytes(), &bytes).ptr),
    );
}

test "failed repeated JSON encode keeps later retries disjoint" {
    const std = @import("std");
    const response = @import("../../response.zig");
    const Response = response.Response(response.standard_head_limits);
    const Workspace = response.Workspace(response.standard_head_limits);
    var response_workspace = Workspace{};
    var bytes: [64]u8 = undefined;
    var output: [128]u8 = undefined;
    var written = false;
    var binding = Binding{ .bytes = &bytes, .output = &output, .written = &written };
    const first = try encode(
        Response,
        &response_workspace,
        &binding,
        .{},
        .ok,
        .{ .value = "source" },
    );
    try std.testing.expectError(
        error.ResponseBodyTooLarge,
        encode(
            Response,
            &response_workspace,
            &binding,
            .{},
            .ok,
            .{ .oversized = "x" ** 80 },
        ),
    );
    const retried = try encode(
        Response,
        &response_workspace,
        &binding,
        .{},
        .ok,
        .{ .wrapped = first.bodyBytes() },
    );
    try std.testing.expectEqualStrings(
        "{\"wrapped\":\"{\\\"value\\\":\\\"source\\\"}\"}",
        retried.bodyBytes(),
    );
}
