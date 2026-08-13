const std = @import("std");
const response = @import("../../response.zig");
const response_head = @import("../http1/response_head.zig");
const response_static = @import("../http1/response_static.zig");
const response_cors_fields = @import("../http1/response_cors_fields.zig");
const response_transfer = @import("../http1/response_transfer.zig");

pub const Prepared = struct {
    bytes: []const u8,
    status: response.Status,
    close_connection: bool,
};

pub const BorrowedPrepared = struct {
    head: []const u8,
    body: []const u8,
    status: response.Status,
    close_connection: bool,
};

pub fn serializeBorrowed(
    comptime selected_limits: response.HeadLimits,
    workspace: anytype,
    input: anytype,
    cors_fields: response_cors_fields.Fields,
    output: []u8,
    value: anytype,
    server_identity: ?response_head.ServerIdentity,
) response_head.WriteError!BorrowedPrepared {
    value.validate() catch return error.InvalidResponse;
    if (value.body.isRendered() or value.body.isExternal()) return error.InvalidResponse;
    const body = value.bodyBytes();
    const request_is_head = std.mem.eql(u8, input.method, "HEAD");
    if (staticPlan(value, cors_fields)) |plan| {
        const head = try response_static.write(
            selected_limits,
            output,
            plan,
            input.date,
            server_identity,
            input.connection_close,
        );
        return .{
            .head = head,
            .body = if (request_is_head) "" else body,
            .status = value.status,
            .close_connection = input.connection_close,
        };
    }
    const head_output = workspace.response_head_bytes[0..@min(
        workspace.response_head_bytes.len,
        output.len,
    )];
    var selected_status = value.status;
    var selected_cors = cors_fields;
    const written = for (0..response_cors_fields.capacity_attempts_max) |_| {
        var headers = response_cors_fields.Overlay(@TypeOf(value.headers.*)).init(
            value.headers,
            selected_cors,
        ) catch return error.InvalidResponse;
        const attempt = response_head.write(
            selected_limits,
            response_transfer.standard_trailer_limits,
            head_output,
            .{
                .framing = .{
                    .status = selected_status,
                    .request_is_head = request_is_head,
                    .request_accepts_trailers = input.accepts_response_trailers,
                    .body = if (value.body.isNone()) .none else .{ .fixed = body.len },
                    .trailers_declared = false,
                },
                .default_content_type = value.media_type orelse response.media.octet_stream,
                .date = input.date,
                .server_identity = server_identity,
                .connection_close = input.connection_close,
            },
            &headers,
        ) catch |problem| switch (problem) {
            error.ResponseHeadTooLarge, error.OutputTooSmall => {
                selected_cors = corsFallback(&selected_status, selected_cors) orelse
                    return problem;
                continue;
            },
            else => return problem,
        };
        break attempt;
    } else unreachable;
    if (output.len < written.bytes.len) return error.OutputTooSmall;
    @memcpy(output[0..written.bytes.len], written.bytes);
    return .{
        .head = output[0..written.bytes.len],
        .body = if (written.plan.send_body) body else "",
        .status = selected_status,
        .close_connection = input.connection_close,
    };
}

fn staticPlan(value: anytype, cors_fields: response_cors_fields.Fields) ?response_static.Plan {
    const plan = value.__static_head orelse return null;
    if (cors_fields.count != 0 or value.headers.len() != 0) return null;
    if (plan.status != value.status or value.media_type == null) return null;
    if (!std.mem.eql(u8, plan.media.bytes(), value.media_type.?.bytes())) return null;
    return switch (value.body) {
        .static => |body| if (body.ptr == plan.body.ptr and body.len == plan.body.len)
            plan
        else
            null,
        else => null,
    };
}

pub fn serialize(
    comptime selected_limits: response.HeadLimits,
    workspace: anytype,
    input: anytype,
    cors_fields: response_cors_fields.Fields,
    output: []u8,
    value: anytype,
    server_identity: ?response_head.ServerIdentity,
) response_head.WriteError!Prepared {
    value.validate() catch return error.InvalidResponse;
    if (value.body.isRendered()) return error.InvalidResponse;
    const body = value.bodyBytes();
    const body_length = value.bodyLength();
    if (value.body.isExternal() and body_length == std.math.maxInt(usize)) {
        return error.InvalidResponse;
    }
    const request_is_head = std.mem.eql(u8, input.method, "HEAD");
    const reserved_body_length = if (!request_is_head and !value.body.isNone() and
        !value.body.isExternal()) body.len else 0;
    if (reserved_body_length > output.len) return error.OutputTooSmall;
    const head_capacity = output.len - reserved_body_length;
    const head_output = workspace.response_head_bytes[0..@min(
        workspace.response_head_bytes.len,
        head_capacity,
    )];
    var selected_status = value.status;
    var selected_cors = cors_fields;
    const written = for (0..response_cors_fields.capacity_attempts_max) |_| {
        var headers = response_cors_fields.Overlay(@TypeOf(value.headers.*)).init(
            value.headers,
            selected_cors,
        ) catch return error.InvalidResponse;
        const attempt = response_head.write(
            selected_limits,
            response_transfer.standard_trailer_limits,
            head_output,
            .{
                .framing = .{
                    .status = selected_status,
                    .request_is_head = request_is_head,
                    .request_accepts_trailers = input.accepts_response_trailers,
                    .body = if (value.body.isNone()) .none else .{ .fixed = body_length },
                    .trailers_declared = false,
                },
                .default_content_type = value.media_type orelse response.media.octet_stream,
                .date = input.date,
                .server_identity = server_identity,
                .connection_close = input.connection_close,
            },
            &headers,
        ) catch |problem| switch (problem) {
            error.ResponseHeadTooLarge, error.OutputTooSmall => {
                selected_cors = corsFallback(&selected_status, selected_cors) orelse
                    return problem;
                continue;
            },
            else => return problem,
        };
        break attempt;
    } else unreachable;
    const copied_body_length = if (written.plan.send_body and !value.body.isExternal())
        body.len
    else
        0;
    std.debug.assert(copied_body_length <= reserved_body_length);
    const total = std.math.add(usize, written.bytes.len, copied_body_length) catch {
        return error.OutputTooSmall;
    };
    if (output.len < total) return error.OutputTooSmall;
    @memcpy(output[0..written.bytes.len], written.bytes);
    @memcpy(output[written.bytes.len..total], body[0..copied_body_length]);
    return .{
        .bytes = output[0..total],
        .status = selected_status,
        .close_connection = input.connection_close,
    };
}

fn corsFallback(
    status: *response.Status,
    current: response_cors_fields.Fields,
) ?response_cors_fields.Fields {
    const fallback = current.capacityFallback() orelse return null;
    if (current.isPreflight() and status.* == .no_content) status.* = .forbidden;
    return fallback;
}

test {
    std.testing.refAllDecls(@This());
}
