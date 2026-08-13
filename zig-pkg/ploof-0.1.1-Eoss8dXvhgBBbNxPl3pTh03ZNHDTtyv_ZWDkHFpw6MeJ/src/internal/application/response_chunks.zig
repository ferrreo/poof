const std = @import("std");
const response = @import("../../response.zig");
const response_gzip = @import("../../response/gzip.zig");
const chunk_output = @import("chunk_output.zig");
const gzip_policy = @import("response_gzip_policy.zig");
const gzip_encoder = @import("../runtime/gzip/encoder.zig");
const response_chunk_chain = @import("../response/chunk_chain.zig");
const request_accept_encoding = @import("../http1/request_accept_encoding.zig");
const response_coding_fields = @import("../http1/response_coding_fields.zig");
const response_content_coding = @import("../http1/response_content_coding.zig");
const response_cors_fields = @import("../http1/response_cors_fields.zig");
const response_head = @import("../http1/response_head.zig");
const response_headers = @import("../http1/response_headers.zig");
const response_transfer = @import("../http1/response_transfer.zig");

pub const Error = response_head.WriteError;

pub const CodingOutcome = enum(u8) {
    identity_disabled,
    application_content_encoding,
    skipped_ineligible,
    skipped_bodyless_status,
    skipped_bodyless,
    identity_below_threshold,
    identity_negotiated,
    identity_capacity_fallback,
    gzip,
    not_acceptable,
    capacity_unavailable,
    compression_failed,
};

pub const Request = struct {
    method: []const u8,
    accept_encoding: request_accept_encoding.Preferences,
    accepts_response_trailers: bool,
    date: []const u8,
    connection_close: bool,
    cors_fields: response_cors_fields.Fields,
};

pub const Prepared = struct {
    head: []const u8,
    body: response_chunk_chain.Chain,
    status: response.Status,
    close_connection: bool,
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

const BodyStage = union(enum) {
    ready,
    invalid,
    length_mismatch,
    capacity: chunk_output.WriteError,
};

pub fn serialize(
    comptime gzip_enabled: bool,
    comptime selected_limits: response.HeadLimits,
    comptime framework_limits: response.HeadLimits,
    comptime options: response_gzip.ResponseGzip,
    value: anytype,
    request: Request,
    head_output: []u8,
    writer: *chunk_output.Writer,
    workspace: ?*gzip_encoder.Workspace,
    server_identity: ?response_head.ServerIdentity,
) Error!Prepared {
    switch (stageBody(value, writer)) {
        .ready => {},
        .invalid => return error.InvalidResponse,
        .capacity => |problem| return writeCapacityFailure(
            framework_limits,
            request,
            head_output,
            server_identity,
            problem,
        ),
        .length_mismatch => {
            writer.abort();
            return writeFramework(
                framework_limits,
                request,
                head_output,
                server_identity,
                .internal_server_error,
                false,
                .compression_failed,
            );
        },
    }
    if (comptime !gzip_enabled) {
        return writeIdentity(
            selected_limits,
            value,
            request,
            head_output,
            writer,
            server_identity,
            .{},
            .identity_disabled,
        );
    }
    return serializeGzip(
        selected_limits,
        framework_limits,
        options,
        value,
        request,
        head_output,
        writer,
        workspace,
        server_identity,
    );
}

fn stageBody(value: anytype, writer: *chunk_output.Writer) BodyStage {
    value.validate() catch return .invalid;
    if (value.body.isRendered()) {
        return if (writer.bytesWritten() == value.bodyLength())
            .ready
        else
            .length_mismatch;
    }
    writer.reset();
    writer.write(value.bodyBytes()) catch |problem| return .{ .capacity = problem };
    return .ready;
}

fn serializeGzip(
    comptime selected_limits: response.HeadLimits,
    comptime framework_limits: response.HeadLimits,
    comptime options: response_gzip.ResponseGzip,
    value: anytype,
    request: Request,
    head_output: []u8,
    writer: *chunk_output.Writer,
    workspace: ?*gzip_encoder.Workspace,
    server_identity: ?response_head.ServerIdentity,
) Error!Prepared {
    if (request.accept_encoding.gzip > request_accept_encoding.weight_max or
        request.accept_encoding.identity > request_accept_encoding.weight_max)
    {
        writer.abort();
        return error.InvalidResponse;
    }
    const fields = response_coding_fields.analyze(value.headers) catch {
        writer.abort();
        return error.InvalidResponse;
    };
    const representation = gzip_policy.analyze(value) catch {
        writer.abort();
        return error.InvalidResponse;
    };
    return dispatch(
        selected_limits,
        framework_limits,
        value,
        request,
        head_output,
        writer,
        workspace,
        options.level,
        server_identity,
        fields,
        response_content_coding.select(.{
            .body = if (value.body.isNone()) .none else .{ .finite = value.bodyLength() },
            .minimum_gzip_bytes = options.minimum_bytes,
            .preferences = request.accept_encoding,
            .eligibility = gzip_policy.eligibility(value, representation),
            .has_application_content_encoding = fields.has_application_content_encoding,
        }),
    );
}

fn dispatch(
    comptime selected_limits: response.HeadLimits,
    comptime framework_limits: response.HeadLimits,
    value: anytype,
    request: Request,
    head_output: []u8,
    writer: *chunk_output.Writer,
    workspace: ?*gzip_encoder.Workspace,
    level: gzip_encoder.Level,
    server_identity: ?response_head.ServerIdentity,
    fields: response_coding_fields.Analysis,
    decision: response_content_coding.Decision,
) Error!Prepared {
    return switch (decision) {
        .application_content_encoding => writeIdentity(
            selected_limits,
            value,
            request,
            head_output,
            writer,
            server_identity,
            fields.plan(.{}),
            .application_content_encoding,
        ),
        .skipped => |reason| writeIdentity(
            selected_limits,
            value,
            request,
            head_output,
            writer,
            server_identity,
            fields.plan(.{}),
            skippedOutcome(reason),
        ),
        .identity => |reason| writeIdentity(
            selected_limits,
            value,
            request,
            head_output,
            writer,
            server_identity,
            fields.plan(.{ .negotiation_varies = true }),
            identityOutcome(reason),
        ),
        .gzip => |selection| writeGzipSelected(
            selected_limits,
            framework_limits,
            value,
            request,
            head_output,
            writer,
            workspace,
            level,
            server_identity,
            fields,
            selection,
        ),
        .not_acceptable => writeNotAcceptable(
            framework_limits,
            request,
            head_output,
            writer,
            server_identity,
        ),
    };
}

fn writeGzipSelected(
    comptime selected_limits: response.HeadLimits,
    comptime framework_limits: response.HeadLimits,
    value: anytype,
    request: Request,
    head_output: []u8,
    writer: *chunk_output.Writer,
    workspace: ?*gzip_encoder.Workspace,
    level: gzip_encoder.Level,
    server_identity: ?response_head.ServerIdentity,
    fields: response_coding_fields.Analysis,
    selection: response_content_coding.GzipSelection,
) Error!Prepared {
    const encoder = workspace orelse return capacityUnavailable(
        selected_limits,
        framework_limits,
        value,
        request,
        head_output,
        writer,
        server_identity,
        fields,
        selection,
    );
    return switch (writer.compress(encoder, level)) {
        .success => |length| {
            std.crypto.secureZero(u8, std.mem.asBytes(encoder));
            return writeCompressed(
                selected_limits,
                framework_limits,
                value,
                request,
                head_output,
                writer,
                server_identity,
                fields,
                selection,
                length,
            );
        },
        .capacity_unavailable => capacityUnavailable(
            selected_limits,
            framework_limits,
            value,
            request,
            head_output,
            writer,
            server_identity,
            fields,
            selection,
        ),
        .failed => {
            std.crypto.secureZero(u8, std.mem.asBytes(encoder));
            writer.abort();
            return writeFramework(
                framework_limits,
                request,
                head_output,
                server_identity,
                .internal_server_error,
                false,
                .compression_failed,
            );
        },
    };
}

fn writeCompressed(
    comptime selected_limits: response.HeadLimits,
    comptime framework_limits: response.HeadLimits,
    value: anytype,
    request: Request,
    head_output: []u8,
    writer: *chunk_output.Writer,
    server_identity: ?response_head.ServerIdentity,
    fields: response_coding_fields.Analysis,
    selection: response_content_coding.GzipSelection,
    length: u32,
) Error!Prepared {
    return writeEncoded(
        selected_limits,
        value,
        request,
        head_output,
        writer,
        server_identity,
        fields.plan(.{ .framework_gzip = true, .negotiation_varies = true }),
        length,
    ) catch |problem| switch (problem) {
        error.OutputTooSmall, error.ResponseHeadTooLarge => capacityUnavailable(
            selected_limits,
            framework_limits,
            value,
            request,
            head_output,
            writer,
            server_identity,
            fields,
            selection,
        ),
        else => {
            writer.abort();
            return problem;
        },
    };
}

fn writeNotAcceptable(
    comptime framework_limits: response.HeadLimits,
    request: Request,
    head_output: []u8,
    writer: *chunk_output.Writer,
    server_identity: ?response_head.ServerIdentity,
) Error!Prepared {
    writer.abort();
    return writeFramework(
        framework_limits,
        request,
        head_output,
        server_identity,
        .not_acceptable,
        true,
        .not_acceptable,
    );
}

fn capacityUnavailable(
    comptime selected_limits: response.HeadLimits,
    comptime framework_limits: response.HeadLimits,
    value: anytype,
    request: Request,
    head_output: []u8,
    writer: *chunk_output.Writer,
    server_identity: ?response_head.ServerIdentity,
    fields: response_coding_fields.Analysis,
    selection: response_content_coding.GzipSelection,
) Error!Prepared {
    if (selection.identity_fallback_available) {
        _ = writer.restoreIdentity();
        return writeIdentity(
            selected_limits,
            value,
            request,
            head_output,
            writer,
            server_identity,
            fields.plan(.{ .negotiation_varies = true }),
            .identity_capacity_fallback,
        ) catch {
            writer.abort();
            return writeFramework(
                framework_limits,
                request,
                head_output,
                server_identity,
                .service_unavailable,
                true,
                .capacity_unavailable,
            );
        };
    }
    writer.abort();
    return writeFramework(
        framework_limits,
        request,
        head_output,
        server_identity,
        .service_unavailable,
        true,
        .capacity_unavailable,
    );
}

fn writeIdentity(
    comptime selected_limits: response.HeadLimits,
    value: anytype,
    request: Request,
    head_output: []u8,
    writer: *chunk_output.Writer,
    server_identity: ?response_head.ServerIdentity,
    field_plan: response_coding_fields.Plan,
    outcome: CodingOutcome,
) Error!Prepared {
    var selected_status = value.status;
    var selected_cors = request.cors_fields;
    const written = for (0..response_cors_fields.capacity_attempts_max) |_| {
        var cors_headers = response_cors_fields.Overlay(@TypeOf(value.headers.*)).init(
            value.headers,
            selected_cors,
        ) catch {
            writer.abort();
            return error.InvalidResponse;
        };
        var headers = response_coding_fields.overlay(&cors_headers, field_plan);
        const attempt = response_head.write(
            selected_limits,
            response_transfer.standard_trailer_limits,
            head_output,
            headInput(value, request, selected_status, value.bodyLength(), server_identity),
            &headers,
        ) catch |problem| switch (problem) {
            error.ResponseHeadTooLarge, error.OutputTooSmall => {
                selected_cors = corsFallback(&selected_status, selected_cors) orelse {
                    writer.abort();
                    return problem;
                };
                continue;
            },
            else => {
                writer.abort();
                return problem;
            },
        };
        break attempt;
    } else unreachable;
    if (!written.plan.send_body) writer.reset();
    const chain = writer.finish() catch return error.InvalidResponse;
    return .{
        .head = written.bytes,
        .body = chain,
        .status = selected_status,
        .close_connection = request.connection_close,
        .coding_outcome = outcome,
    };
}

fn writeEncoded(
    comptime selected_limits: response.HeadLimits,
    value: anytype,
    request: Request,
    head_output: []u8,
    writer: *chunk_output.Writer,
    server_identity: ?response_head.ServerIdentity,
    field_plan: response_coding_fields.Plan,
    length: u32,
) Error!Prepared {
    var selected_status = value.status;
    var selected_cors = request.cors_fields;
    const written = for (0..response_cors_fields.capacity_attempts_max) |_| {
        var cors_headers = response_cors_fields.Overlay(@TypeOf(value.headers.*)).init(
            value.headers,
            selected_cors,
        ) catch return error.InvalidResponse;
        var headers = response_coding_fields.overlay(&cors_headers, field_plan);
        const attempt = response_head.write(
            selected_limits,
            response_transfer.standard_trailer_limits,
            head_output,
            headInput(value, request, selected_status, length, server_identity),
            &headers,
        ) catch |problem| switch (problem) {
            error.ResponseHeadTooLarge, error.OutputTooSmall => {
                selected_cors = corsFallback(&selected_status, selected_cors) orelse return problem;
                continue;
            },
            else => return problem,
        };
        break attempt;
    } else unreachable;
    if (!written.plan.send_body) writer.reset();
    return .{
        .head = written.bytes,
        .body = writer.finish() catch return error.InvalidResponse,
        .status = selected_status,
        .close_connection = request.connection_close,
        .coding_outcome = .gzip,
    };
}

fn writeCapacityFailure(
    comptime framework_limits: response.HeadLimits,
    request: Request,
    output: []u8,
    server_identity: ?response_head.ServerIdentity,
    problem: chunk_output.WriteError,
) Error!Prepared {
    return writeFramework(
        framework_limits,
        request,
        output,
        server_identity,
        if (problem == error.ResponseChunksExhausted)
            .service_unavailable
        else
            .internal_server_error,
        problem == error.ResponseChunksExhausted,
        if (problem == error.ResponseChunksExhausted)
            .capacity_unavailable
        else
            .compression_failed,
    );
}

pub fn writeFramework(
    comptime selected_limits: response.HeadLimits,
    request: Request,
    output: []u8,
    server_identity: ?response_head.ServerIdentity,
    status: response.Status,
    vary: bool,
    outcome: CodingOutcome,
) Error!Prepared {
    var empty = EmptyHeaders{};
    var selected_cors = request.cors_fields;
    const written = for (0..response_cors_fields.capacity_attempts_max) |_| {
        var cors_headers = response_cors_fields.Overlay(EmptyHeaders).init(
            &empty,
            selected_cors,
        ) catch return error.InvalidResponse;
        var headers = response_coding_fields.overlay(&cors_headers, .{
            .append_vary_accept_encoding = vary,
        });
        const attempt = response_head.write(
            selected_limits,
            response_transfer.standard_trailer_limits,
            output,
            .{
                .framing = .{
                    .status = status,
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
    return .{
        .head = written.bytes,
        .body = .{},
        .status = status,
        .close_connection = true,
        .coding_outcome = outcome,
    };
}

fn headInput(
    value: anytype,
    request: Request,
    status: response.Status,
    length: usize,
    server_identity: ?response_head.ServerIdentity,
) response_head.HeadInput {
    return .{
        .framing = .{
            .status = status,
            .request_is_head = isHead(request.method),
            .request_accepts_trailers = request.accepts_response_trailers,
            .body = if (value.body.isNone()) .none else .{ .fixed = length },
            .trailers_declared = false,
        },
        .default_content_type = value.media_type orelse response.media.octet_stream,
        .date = request.date,
        .server_identity = server_identity,
        .connection_close = request.connection_close,
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

fn skippedOutcome(reason: response_content_coding.SkipReason) CodingOutcome {
    return switch (reason) {
        .bodyless_status => .skipped_bodyless_status,
        .bodyless => .skipped_bodyless,
        .stream => unreachable,
    };
}

fn identityOutcome(reason: response_content_coding.IdentityReason) CodingOutcome {
    return switch (reason) {
        .ineligible => .skipped_ineligible,
        .below_threshold => .identity_below_threshold,
        .negotiated => .identity_negotiated,
    };
}

fn isHead(method: []const u8) bool {
    return std.mem.eql(u8, method, "HEAD");
}
