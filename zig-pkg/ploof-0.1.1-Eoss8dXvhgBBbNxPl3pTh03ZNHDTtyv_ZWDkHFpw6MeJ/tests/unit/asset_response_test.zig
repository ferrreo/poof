const std = @import("std");
const application_context = @import("../../src/application/context.zig");
const asset_response = @import("../../src/internal/asset/response.zig");
const request_head = @import("../../src/internal/http1/request_head.zig");
const response = @import("../../src/response.zig");

const date = "Tue, 14 Jul 2026 12:00:00 GMT";
const etag = "\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"";
const gzip_etag = "\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"";

const Representation = struct {
    bytes: []const u8,
    digest: [32]u8,
    etag: []const u8,
};

const record = .{
    .media_type = "text/css; charset=utf-8",
    .identity = Representation{
        .bytes = "body",
        .digest = [_]u8{0xaa} ** 32,
        .etag = etag,
    },
    .gzip = @as(?Representation, .{
        .bytes = "gz",
        .digest = [_]u8{0xbb} ** 32,
        .etag = gzip_etag,
    }),
};

test "GET emits immutable precompressed response with borrowed body" {
    var output: [1024]u8 = undefined;
    const prepared = try asset_response.prepare(
        .{},
        &output,
        record,
        .{ .method = .get, .accept_encoding = .{ .gzip = 1000 }, .date = date },
        emptyHeaders(),
        null,
    );
    try std.testing.expectEqualStrings("gz", prepared.body);
    try std.testing.expectEqual(.gzip, prepared.coding.?);
    try expectContains(prepared.head, "HTTP/1.1 200 OK\r\n");
    try expectContains(prepared.head, "content-type: text/css; charset=utf-8\r\n");
    try expectContains(prepared.head, "content-length: 2\r\n");
    try expectContains(prepared.head, "content-encoding: gzip\r\n");
    try expectCommon(prepared.head, gzip_etag);
}

test "HEAD retains selected representation metadata and suppresses body" {
    var output: [1024]u8 = undefined;
    const prepared = try asset_response.prepare(
        .{},
        &output,
        record,
        .{ .method = .head, .accept_encoding = .{ .gzip = 1000 }, .date = date },
        emptyHeaders(),
        null,
    );
    try std.testing.expectEqualStrings("", prepared.body);
    try expectContains(prepared.head, "content-length: 2\r\n");
    try expectContains(prepared.head, "content-encoding: gzip\r\n");
    try expectCommon(prepared.head, gzip_etag);
}

test "If-None-Match selects negotiated ETag and emits bodyless 304" {
    var request = RequestHeaders.init(&.{.{ .name = "If-None-Match", .value = gzip_etag }});
    var output: [1024]u8 = undefined;
    const prepared = try asset_response.prepare(
        .{},
        &output,
        record,
        .{ .method = .get, .accept_encoding = .{ .gzip = 1000 }, .date = date },
        request.view(),
        null,
    );
    try std.testing.expectEqualStrings("", prepared.body);
    try std.testing.expectEqual(response.Status.not_modified, prepared.status);
    try expectContains(prepared.head, "HTTP/1.1 304 Not Modified\r\n");
    try std.testing.expect(std.mem.indexOf(u8, prepared.head, "content-length") == null);
    try expectCommon(prepared.head, gzip_etag);
}

test "Range request is ignored and the complete representation is returned" {
    var request = RequestHeaders.init(&.{.{ .name = "Range", .value = "bytes=1-2" }});
    var output: [1024]u8 = undefined;
    const prepared = try asset_response.prepare(
        .{},
        &output,
        record,
        .{ .method = .get, .accept_encoding = .{}, .date = date },
        request.view(),
        null,
    );
    try std.testing.expectEqual(@import("../../src/response.zig").Status.ok, prepared.status);
    try std.testing.expectEqualStrings("body", prepared.body);
    try expectContains(prepared.head, "content-length: 4\r\n");
    try std.testing.expect(std.mem.indexOf(u8, prepared.head, "accept-ranges") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.head, "content-range") == null);
}

test "identity can be rejected without advertising range support" {
    var output: [1024]u8 = undefined;
    const prepared = try asset_response.prepare(
        .{},
        &output,
        record,
        .{ .method = .get, .accept_encoding = .{ .identity = 0 }, .date = date },
        emptyHeaders(),
        null,
    );
    try std.testing.expectEqual(response.Status.not_acceptable, prepared.status);
    try std.testing.expect(prepared.close_connection);
    try expectContains(prepared.head, "cache-control: no-store\r\n");
    try expectContains(prepared.head, "vary: Accept-Encoding\r\n");
    try std.testing.expect(std.mem.indexOf(u8, prepared.head, "accept-ranges") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.head, "content-range") == null);
}

fn expectCommon(head: []const u8, expected_etag: []const u8) !void {
    try expectContains(head, "cache-control: public, max-age=31536000, immutable\r\n");
    try expectContains(head, "etag: ");
    try expectContains(head, expected_etag);
    try expectContains(head, "x-content-type-options: nosniff\r\n");
    try expectContains(head, "vary: Accept-Encoding\r\n");
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn emptyHeaders() application_context.RequestHeaders {
    return .{};
}

const Header = struct {
    name: []const u8,
    value: []const u8,
};

const RequestHeaders = struct {
    bytes: [256]u8 = undefined,
    fields: [4]request_head.Field = undefined,
    bytes_used: usize = 0,
    fields_used: usize = 0,

    fn init(headers: []const Header) RequestHeaders {
        var result = RequestHeaders{};
        for (headers) |header| result.append(header);
        return result;
    }

    fn append(headers: *RequestHeaders, field: Header) void {
        const name_start = headers.bytes_used;
        @memcpy(headers.bytes[name_start..][0..field.name.len], field.name);
        headers.bytes_used += field.name.len;
        const value_start = headers.bytes_used;
        @memcpy(headers.bytes[value_start..][0..field.value.len], field.value);
        headers.bytes_used += field.value.len;
        headers.fields[headers.fields_used] = .{
            .name = span(name_start, field.name.len),
            .value = span(value_start, field.value.len),
            .raw_value = span(value_start, field.value.len),
        };
        headers.fields_used += 1;
    }

    fn view(headers: *const RequestHeaders) application_context.RequestHeaders {
        return .{
            .bytes = headers.bytes[0..headers.bytes_used],
            .fields = headers.fields[0..headers.fields_used],
        };
    }
};

fn span(offset: usize, length: usize) request_head.Span {
    return .{ .offset = @intCast(offset), .length = @intCast(length) };
}
