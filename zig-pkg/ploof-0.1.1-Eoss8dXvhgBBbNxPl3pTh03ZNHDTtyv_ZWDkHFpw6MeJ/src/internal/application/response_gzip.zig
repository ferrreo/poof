const std = @import("std");
const response = @import("../../response.zig");
const gzip_policy = @import("response_gzip_policy.zig");
const gzip_encoder = @import("../runtime/gzip/encoder.zig");
const request_accept_encoding = @import("../http1/request_accept_encoding.zig");
const response_coding_fields = @import("../http1/response_coding_fields.zig");
const response_cors_fields = @import("../http1/response_cors_fields.zig");
const response_content_coding = @import("../http1/response_content_coding.zig");
const response_head = @import("../http1/response_head.zig");
const response_headers = @import("../http1/response_headers.zig");
const response_transfer = @import("../http1/response_transfer.zig");

pub const Error = response_head.WriteError;

pub const Options = struct {
    minimum_bytes: u64,
    level: gzip_encoder.Level,
};

pub const RequestFields = struct {
    method: []const u8,
    accept_encoding: request_accept_encoding.Preferences,
    accepts_response_trailers: bool,
    date: []const u8,
    connection_close: bool,
    cors_fields: response_cors_fields.Fields = .{},
};

pub const CodingOutcome = enum(u8) {
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

pub const Prepared = struct {
    bytes: []const u8,
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

pub fn serialize(
    comptime selected_limits: response.HeadLimits,
    comptime framework_limits: response.HeadLimits,
    value: anytype,
    request: RequestFields,
    output: []u8,
    workspace: ?*gzip_encoder.Workspace,
    comptime options: Options,
    server_identity: ?response_head.ServerIdentity,
) Error!Prepared {
    return serializeWithEncoder(
        gzip_encoder,
        selected_limits,
        framework_limits,
        value,
        request,
        output,
        workspace,
        options,
        server_identity,
    );
}

pub fn serializeWithEncoder(
    comptime Encoder: type,
    comptime selected_limits: response.HeadLimits,
    comptime framework_limits: response.HeadLimits,
    value: anytype,
    request: RequestFields,
    output: []u8,
    workspace: ?*Encoder.Workspace,
    comptime options: Options,
    server_identity: ?response_head.ServerIdentity,
) Error!Prepared {
    value.validate() catch return error.InvalidResponse;
    if (value.body.isRendered()) return error.InvalidResponse;
    if (request.accept_encoding.gzip > request_accept_encoding.weight_max or
        request.accept_encoding.identity > request_accept_encoding.weight_max)
    {
        return error.InvalidResponse;
    }
    const fields = try response_coding_fields.analyze(value.headers);
    const representation = try gzip_policy.analyze(value);
    const decision = response_content_coding.select(.{
        .body = codingBody(value),
        .minimum_gzip_bytes = options.minimum_bytes,
        .preferences = request.accept_encoding,
        .eligibility = gzip_policy.eligibility(value, representation),
        .has_application_content_encoding = fields.has_application_content_encoding,
    });
    return dispatch(
        Encoder,
        selected_limits,
        framework_limits,
        value,
        request,
        output,
        workspace,
        options,
        server_identity,
        fields,
        decision,
    );
}

pub fn frameworkBytesRequired(
    comptime framework_limits: response.HeadLimits,
    comptime server_identity: ?response_head.ServerIdentity,
) ?usize {
    const probe_date = "Thu, 01 Jan 1970 00:00:00 GMT";
    const request = RequestFields{
        .method = "GET",
        .accept_encoding = .{},
        .accepts_response_trailers = false,
        .date = probe_date,
        .connection_close = false,
    };
    const cases = .{
        .{ .status = response.Status.not_acceptable, .vary = true },
        .{ .status = response.Status.service_unavailable, .vary = true },
        .{ .status = response.Status.internal_server_error, .vary = false },
    };
    var output: [framework_limits.head_bytes_max]u8 = undefined;
    var maximum: usize = 0;
    inline for (cases) |case| {
        const prepared = writeFramework(
            framework_limits,
            request,
            &output,
            server_identity,
            case.status,
            case.vary,
            .capacity_unavailable,
        ) catch return null;
        maximum = @max(maximum, prepared.bytes.len);
    }
    return maximum;
}

pub fn frameworkCapacityFits(
    comptime framework_limits: response.HeadLimits,
    comptime server_identity: ?response_head.ServerIdentity,
) bool {
    return frameworkBytesRequired(framework_limits, server_identity) != null;
}

pub fn frameworkOutputCapacityFits(
    comptime framework_limits: response.HeadLimits,
    output_bytes: usize,
    comptime server_identity: ?response_head.ServerIdentity,
) bool {
    const required = frameworkBytesRequired(framework_limits, server_identity) orelse return false;
    return output_bytes >= required;
}

fn dispatch(
    comptime Encoder: type,
    comptime selected_limits: response.HeadLimits,
    comptime framework_limits: response.HeadLimits,
    value: anytype,
    request: RequestFields,
    output: []u8,
    workspace: ?*Encoder.Workspace,
    comptime options: Options,
    server_identity: ?response_head.ServerIdentity,
    fields: response_coding_fields.Analysis,
    decision: response_content_coding.Decision,
) Error!Prepared {
    return switch (decision) {
        .application_content_encoding, .skipped, .identity => writeSelectedIdentity(
            selected_limits,
            value,
            request,
            output,
            server_identity,
            fields,
            decision,
        ),
        .gzip => |selection| gzipSelected(
            Encoder,
            selected_limits,
            framework_limits,
            value,
            request,
            output,
            workspace,
            options,
            server_identity,
            fields,
            selection,
        ),
        .not_acceptable => writeFramework(
            framework_limits,
            request,
            output,
            server_identity,
            .not_acceptable,
            true,
            .not_acceptable,
        ),
    };
}

fn writeSelectedIdentity(
    comptime selected_limits: response.HeadLimits,
    value: anytype,
    request: RequestFields,
    output: []u8,
    server_identity: ?response_head.ServerIdentity,
    fields: response_coding_fields.Analysis,
    decision: response_content_coding.Decision,
) Error!Prepared {
    const selected = switch (decision) {
        .application_content_encoding => .{
            fields.plan(.{}),
            CodingOutcome.application_content_encoding,
        },
        .skipped => |reason| .{ fields.plan(.{}), skippedOutcome(reason) },
        .identity => |reason| .{
            fields.plan(.{ .negotiation_varies = true }),
            identityOutcome(reason),
        },
        else => unreachable,
    };
    return writeIdentity(
        selected_limits,
        value,
        request,
        output,
        server_identity,
        selected[0],
        selected[1],
    );
}

fn gzipSelected(
    comptime Encoder: type,
    comptime selected_limits: response.HeadLimits,
    comptime framework_limits: response.HeadLimits,
    value: anytype,
    request: RequestFields,
    output: []u8,
    workspace: ?*Encoder.Workspace,
    comptime options: Options,
    server_identity: ?response_head.ServerIdentity,
    fields: response_coding_fields.Analysis,
    selection: response_content_coding.GzipSelection,
) Error!Prepared {
    const body = value.bodyBytes();
    const stage = gzipStage(Encoder, selected_limits, body.len, output) orelse
        return capacityUnavailable(
            selected_limits,
            framework_limits,
            value,
            request,
            output,
            server_identity,
            fields,
            selection,
        );
    const encoder = workspace orelse return capacityUnavailable(
        selected_limits,
        framework_limits,
        value,
        request,
        output,
        server_identity,
        fields,
        selection,
    );
    defer std.crypto.secureZero(u8, std.mem.asBytes(encoder));
    const encoded = Encoder.compress(encoder, body, stage, options.level) catch
        return compressionFailure(stage, framework_limits, request, output, server_identity);
    if (!validEncoded(stage, encoded))
        return compressionFailure(stage, framework_limits, request, output, server_identity);
    const prepared = writeGzip(
        selected_limits,
        value,
        request,
        output,
        server_identity,
        fields.plan(.{ .framework_gzip = true, .negotiation_varies = true }),
        encoded,
    ) catch |problem| {
        scrubStage(stage);
        return switch (problem) {
            error.OutputTooSmall, error.ResponseHeadTooLarge => capacityUnavailable(
                selected_limits,
                framework_limits,
                value,
                request,
                output,
                server_identity,
                fields,
                selection,
            ),
            else => problem,
        };
    };
    scrubUncommittedStage(stage, selected_limits.head_bytes_max, prepared.bytes.len);
    return prepared;
}

fn gzipStage(
    comptime Encoder: type,
    comptime selected_limits: response.HeadLimits,
    body_length: usize,
    output: []u8,
) ?[]u8 {
    const required = Encoder.bound(body_length) catch return null;
    const start: usize = selected_limits.head_bytes_max;
    const end = std.math.add(usize, start, required) catch return null;
    if (end > output.len) return null;
    return output[start..end];
}

fn scrubStage(stage: []u8) void {
    std.crypto.secureZero(u8, stage);
}

fn scrubUncommittedStage(stage: []u8, offset: usize, committed: usize) void {
    const preserved = if (committed > offset)
        @min(committed - offset, stage.len)
    else
        0;
    scrubStage(stage[preserved..]);
}

fn capacityUnavailable(
    comptime selected_limits: response.HeadLimits,
    comptime framework_limits: response.HeadLimits,
    value: anytype,
    request: RequestFields,
    output: []u8,
    server_identity: ?response_head.ServerIdentity,
    fields: response_coding_fields.Analysis,
    selection: response_content_coding.GzipSelection,
) Error!Prepared {
    if (selection.identity_fallback_available) {
        return writeIdentity(
            selected_limits,
            value,
            request,
            output,
            server_identity,
            fields.plan(.{ .negotiation_varies = true }),
            .identity_capacity_fallback,
        ) catch |problem| switch (problem) {
            error.OutputTooSmall, error.ResponseHeadTooLarge => writeFramework(
                framework_limits,
                request,
                output,
                server_identity,
                .service_unavailable,
                true,
                .capacity_unavailable,
            ),
            else => problem,
        };
    }
    return writeFramework(
        framework_limits,
        request,
        output,
        server_identity,
        .service_unavailable,
        true,
        .capacity_unavailable,
    );
}

fn compressionFailure(
    stage: []u8,
    comptime framework_limits: response.HeadLimits,
    request: RequestFields,
    output: []u8,
    server_identity: ?response_head.ServerIdentity,
) Error!Prepared {
    scrubStage(stage);
    return writeFramework(
        framework_limits,
        request,
        output,
        server_identity,
        .internal_server_error,
        false,
        .compression_failed,
    );
}

fn writeIdentity(
    comptime selected_limits: response.HeadLimits,
    value: anytype,
    request: RequestFields,
    output: []u8,
    server_identity: ?response_head.ServerIdentity,
    field_plan: response_coding_fields.Plan,
    outcome: CodingOutcome,
) Error!Prepared {
    const body = value.bodyBytes();
    const request_is_head = isHead(request.method);
    const body_length = if (!request_is_head and !value.body.isNone()) body.len else 0;
    if (body_length > output.len) return error.OutputTooSmall;
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
            output[0 .. output.len - body_length],
            applicationHeadInput(value, request, selected_status, body.len, server_identity),
            &headers,
        ) catch |problem| switch (problem) {
            error.ResponseHeadTooLarge, error.OutputTooSmall => {
                selected_cors = applicationCorsFallback(&selected_status, selected_cors) orelse
                    return problem;
                continue;
            },
            else => return problem,
        };
        break attempt;
    } else unreachable;
    const total = written.bytes.len + body_length;
    @memcpy(output[written.bytes.len..total], body[0..body_length]);
    return .{
        .bytes = output[0..total],
        .status = selected_status,
        .close_connection = request.connection_close,
        .coding_outcome = outcome,
    };
}

fn writeGzip(
    comptime selected_limits: response.HeadLimits,
    value: anytype,
    request: RequestFields,
    output: []u8,
    server_identity: ?response_head.ServerIdentity,
    field_plan: response_coding_fields.Plan,
    encoded: []u8,
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
            output[0..selected_limits.head_bytes_max],
            gzipHeadInput(value, request, selected_status, encoded.len, server_identity),
            &headers,
        ) catch |problem| switch (problem) {
            error.ResponseHeadTooLarge, error.OutputTooSmall => {
                selected_cors = applicationCorsFallback(&selected_status, selected_cors) orelse
                    return problem;
                continue;
            },
            else => return problem,
        };
        break attempt;
    } else unreachable;
    const body_length = if (written.plan.send_body) encoded.len else 0;
    const total = written.bytes.len + body_length;
    if (body_length != 0) {
        std.mem.copyForwards(u8, output[written.bytes.len..total], encoded);
    }
    return .{
        .bytes = output[0..total],
        .status = selected_status,
        .close_connection = request.connection_close,
        .coding_outcome = .gzip,
    };
}

fn writeFramework(
    comptime selected_limits: response.HeadLimits,
    request: RequestFields,
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
        .bytes = written.bytes,
        .status = status,
        .close_connection = true,
        .coding_outcome = outcome,
    };
}

fn applicationCorsFallback(
    status: *response.Status,
    current: response_cors_fields.Fields,
) ?response_cors_fields.Fields {
    const fallback = current.capacityFallback() orelse return null;
    if (current.isPreflight() and status.* == .no_content) status.* = .forbidden;
    return fallback;
}

fn applicationHeadInput(
    value: anytype,
    request: RequestFields,
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

fn gzipHeadInput(
    value: anytype,
    request: RequestFields,
    status: response.Status,
    length: usize,
    server_identity: ?response_head.ServerIdentity,
) response_head.HeadInput {
    var input = applicationHeadInput(value, request, status, length, server_identity);
    input.framing.body = .{ .fixed = length };
    return input;
}

fn codingBody(value: anytype) response_content_coding.Body {
    return if (value.body.isNone())
        .none
    else
        .{ .finite = @intCast(value.bodyBytes().len) };
}

pub fn isCompressibleMediaType(value: []const u8) bool {
    return gzip_policy.isCompressibleMediaType(value);
}

fn validEncoded(stage: []u8, encoded: []u8) bool {
    if (encoded.ptr != stage.ptr or encoded.len < 18 or encoded.len > stage.len) return false;
    return encoded[0] == 0x1f and encoded[1] == 0x8b and encoded[2] == 0x08;
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
