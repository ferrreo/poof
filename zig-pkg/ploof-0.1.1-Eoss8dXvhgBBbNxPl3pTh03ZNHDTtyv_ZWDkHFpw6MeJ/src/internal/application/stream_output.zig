const std = @import("std");
const response = @import("../../response.zig");
const request_accept_encoding = @import("../http1/request_accept_encoding.zig");
const response_coding_fields = @import("../http1/response_coding_fields.zig");
const response_cors_fields = @import("../http1/response_cors_fields.zig");
const response_framing = @import("../http1/response_framing.zig");
const response_head = @import("../http1/response_head.zig");
const response_headers = @import("../http1/response_headers.zig");
const response_transfer = @import("../http1/response_transfer.zig");

pub const Error = response_head.WriteError;

pub const RequestFields = struct {
    method: []const u8,
    accept_encoding: request_accept_encoding.Preferences,
    accepts_response_trailers: bool,
    date: []const u8,
    connection_close: bool,
    cors_fields: response_cors_fields.Fields = .{},
};

pub const CodingOutcome = enum(u8) {
    identity,
    not_acceptable,
};

pub const Prepared = struct {
    bytes: []const u8,
    status: response.Status,
    close_connection: bool,
    framing: response_framing.Plan,
    trailers: response_transfer.TrailerPlan,
    coding_outcome: CodingOutcome,
};

const EmptyHeaders = struct {
    pub fn len(_: *const EmptyHeaders) usize {
        return 0;
    }

    pub fn at(_: *const EmptyHeaders, _: usize) response_headers.Field {
        unreachable;
    }
};

/// Serializes only the HTTP/1.1 head. The transport owns producer execution.
pub fn serialize(
    comptime selected_limits: response.HeadLimits,
    comptime framework_limits: response.HeadLimits,
    value: anytype,
    response_workspace: anytype,
    request: RequestFields,
    output: []u8,
    server_identity: ?response_head.ServerIdentity,
) Error!Prepared {
    value.validateOwned(response_workspace) catch return error.InvalidResponse;
    if (!std.meta.eql(value.selectedLimits(), selected_limits)) {
        return error.InvalidResponse;
    }
    if (request.accept_encoding.gzip > request_accept_encoding.weight_max or
        request.accept_encoding.identity > request_accept_encoding.weight_max)
    {
        return error.InvalidResponse;
    }

    const fields = try response_coding_fields.analyze(value.headers);
    if (fields.has_application_content_encoding) return error.InvalidResponse;
    if (request.accept_encoding.identity == 0) {
        return writeNotAcceptable(framework_limits, request, output, server_identity);
    }

    var selected_cors = request.cors_fields;
    const written = for (0..response_cors_fields.capacity_attempts_max) |_| {
        var cors_headers = response_cors_fields.Overlay(@TypeOf(value.headers.*)).init(
            value.headers,
            selected_cors,
        ) catch return error.InvalidResponse;
        var headers = response_coding_fields.overlay(
            &cors_headers,
            fields.plan(.{ .negotiation_varies = true }),
        );
        const attempt = response_head.write(
            selected_limits,
            response_transfer.standard_trailer_limits,
            output,
            .{
                .framing = .{
                    .status = value.status,
                    .request_is_head = isHead(request.method),
                    .request_accepts_trailers = request.accepts_response_trailers,
                    .body = streamBody(value.stream.framing),
                    .trailers_declared = value.stream.trailer_names.len != 0,
                },
                .default_content_type = value.media_type,
                .trailer_names = value.stream.trailer_names,
                .date = request.date,
                .server_identity = server_identity,
                .connection_close = request.connection_close,
            },
            &headers,
        ) catch |problem| switch (problem) {
            error.ResponseHeadTooLarge, error.OutputTooSmall => {
                selected_cors = selected_cors.capacityFallback() orelse return problem;
                continue;
            },
            else => return problem,
        };
        break attempt;
    } else unreachable;
    return prepared(
        written,
        value.status,
        request.connection_close,
        .identity,
    );
}

pub fn frameworkBytesRequired(
    comptime framework_limits: response.HeadLimits,
    comptime server_identity: ?response_head.ServerIdentity,
) ?usize {
    var output: [framework_limits.head_bytes_max]u8 = undefined;
    const result = writeNotAcceptable(
        framework_limits,
        .{
            .method = "GET",
            .accept_encoding = .{ .identity = 0 },
            .accepts_response_trailers = false,
            .date = "Thu, 01 Jan 1970 00:00:00 GMT",
            .connection_close = false,
        },
        &output,
        server_identity,
    ) catch return null;
    return result.bytes.len;
}

fn writeNotAcceptable(
    comptime framework_limits: response.HeadLimits,
    request: RequestFields,
    output: []u8,
    server_identity: ?response_head.ServerIdentity,
) Error!Prepared {
    var empty = EmptyHeaders{};
    var selected_cors = request.cors_fields;
    const written = for (0..response_cors_fields.capacity_attempts_max) |_| {
        var cors_headers = response_cors_fields.Overlay(EmptyHeaders).init(
            &empty,
            selected_cors,
        ) catch return error.InvalidResponse;
        var headers = response_coding_fields.overlay(&cors_headers, .{
            .append_vary_accept_encoding = true,
        });
        const attempt = response_head.write(
            framework_limits,
            response_transfer.standard_trailer_limits,
            output,
            .{
                .framing = .{
                    .status = .not_acceptable,
                    .request_is_head = isHead(request.method),
                    .request_accepts_trailers = request.accepts_response_trailers,
                    .body = .{ .fixed = 0 },
                    .trailers_declared = false,
                },
                .default_content_type = response.media.octet_stream,
                .date = request.date,
                .server_identity = server_identity,
                .connection_close = true,
            },
            &headers,
        ) catch |problem| switch (problem) {
            error.ResponseHeadTooLarge, error.OutputTooSmall => {
                selected_cors = selected_cors.capacityFallback() orelse return problem;
                continue;
            },
            else => return problem,
        };
        break attempt;
    } else unreachable;
    return prepared(written, .not_acceptable, true, .not_acceptable);
}

fn prepared(
    written: response_head.WriteResult,
    status: response.Status,
    close_connection: bool,
    coding_outcome: CodingOutcome,
) Prepared {
    return .{
        .bytes = written.bytes,
        .status = status,
        .close_connection = close_connection,
        .framing = written.plan,
        .trailers = written.trailer_plan,
        .coding_outcome = coding_outcome,
    };
}

fn streamBody(framing: anytype) response_framing.Body {
    return switch (framing) {
        .unknown => .stream_unknown,
        .exact => |length| .{ .stream_exact = length },
    };
}

fn isHead(method: []const u8) bool {
    return std.mem.eql(u8, method, "HEAD");
}
