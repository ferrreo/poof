const asset_http = @import("http.zig");
const limits = @import("../http1/limits.zig");
const media_type = @import("../http1/media_type.zig");
const request_accept_encoding = @import("../http1/request_accept_encoding.zig");
const response_head = @import("../http1/response_head.zig");
const response_headers = @import("../http1/response_headers.zig");
const response_transfer = @import("../http1/response_transfer.zig");
const status = @import("../http1/status.zig");

pub const Input = struct {
    method: asset_http.Method,
    accept_encoding: request_accept_encoding.Preferences,
    date: []const u8,
    connection_close: bool = false,
};

pub const Prepared = struct {
    head: []const u8,
    body: []const u8,
    status: status.Status,
    coding: ?asset_http.Coding,
    close_connection: bool,
};

pub fn prepare(
    comptime head_limits: limits.ResponseHeadLimits,
    output: []u8,
    record: anytype,
    input: Input,
    request_headers: anytype,
    server_identity: ?response_head.ServerIdentity,
) response_head.WriteError!Prepared {
    if (input.accept_encoding.gzip > request_accept_encoding.weight_max or
        input.accept_encoding.identity > request_accept_encoding.weight_max)
    {
        return error.InvalidResponse;
    }
    const decision = asset_http.select(record, input.method, input.accept_encoding);
    return switch (decision) {
        .not_acceptable => prepareNotAcceptable(
            head_limits,
            output,
            input,
            server_identity,
        ),
        .selected => |selected| prepareSelected(
            head_limits,
            output,
            selected,
            input,
            request_headers,
            server_identity,
        ),
    };
}

fn prepareSelected(
    comptime head_limits: limits.ResponseHeadLimits,
    output: []u8,
    selected: asset_http.Selection,
    input: Input,
    request_headers: anytype,
    server_identity: ?response_head.ServerIdentity,
) response_head.WriteError!Prepared {
    const not_modified = matchesIfNoneMatch(selected.etag, request_headers);
    const response_status: status.Status = if (not_modified) .not_modified else .ok;
    const body: @import("../http1/response_framing.zig").Body = if (not_modified)
        .none
    else
        .{ .fixed = selected.contentLength() };
    const fields = AssetFields{ .selected = selected };
    const written = try response_head.write(
        head_limits,
        response_transfer.standard_trailer_limits,
        output,
        .{
            .framing = .{
                .status = response_status,
                .request_is_head = input.method == .head,
                .request_accepts_trailers = false,
                .body = body,
                .trailers_declared = false,
            },
            .default_content_type = media_type.parse(selected.media_type) catch unreachable,
            .date = input.date,
            .server_identity = server_identity,
            .connection_close = input.connection_close,
        },
        &fields,
    );
    return .{
        .head = written.bytes,
        .body = if (!not_modified and selected.transfer_body) selected.body else "",
        .status = response_status,
        .coding = selected.coding,
        .close_connection = input.connection_close,
    };
}

fn prepareNotAcceptable(
    comptime head_limits: limits.ResponseHeadLimits,
    output: []u8,
    input: Input,
    server_identity: ?response_head.ServerIdentity,
) response_head.WriteError!Prepared {
    const fields = NotAcceptableFields{};
    const written = try response_head.write(
        head_limits,
        response_transfer.standard_trailer_limits,
        output,
        .{
            .framing = .{
                .status = .not_acceptable,
                .request_is_head = input.method == .head,
                .request_accepts_trailers = false,
                .body = .none,
                .trailers_declared = false,
            },
            .default_content_type = media_type.octet_stream,
            .date = input.date,
            .server_identity = server_identity,
            .connection_close = true,
        },
        &fields,
    );
    return .{
        .head = written.bytes,
        .body = "",
        .status = .not_acceptable,
        .coding = null,
        .close_connection = true,
    };
}

fn matchesIfNoneMatch(etag: []const u8, request_headers: anytype) bool {
    var matcher = asset_http.IfNoneMatch.init(etag);
    var values = request_headers.all("if-none-match").iterator();
    while (values.next()) |value| matcher.add(value);
    return matcher.notModified();
}

const AssetFields = struct {
    selected: asset_http.Selection,

    pub fn len(fields: *const AssetFields) usize {
        return if (fields.selected.coding == .gzip) 5 else 4;
    }

    pub fn at(fields: *const AssetFields, index: usize) response_headers.Field {
        return switch (index) {
            0 => .{ .name = "cache-control", .value = asset_http.cache_control },
            1 => .{ .name = "etag", .value = fields.selected.etag },
            2 => .{ .name = "x-content-type-options", .value = asset_http.nosniff },
            3 => .{ .name = "vary", .value = asset_http.vary },
            4 => .{ .name = "content-encoding", .value = "gzip" },
            else => unreachable,
        };
    }
};

const NotAcceptableFields = struct {
    pub fn len(_: *const NotAcceptableFields) usize {
        return 3;
    }

    pub fn at(_: *const NotAcceptableFields, index: usize) response_headers.Field {
        return switch (index) {
            0 => .{ .name = "cache-control", .value = "no-store" },
            1 => .{ .name = "x-content-type-options", .value = asset_http.nosniff },
            2 => .{ .name = "vary", .value = asset_http.vary },
            else => unreachable,
        };
    }
};
