const std = @import("std");
const response = @import("../../src/response.zig");
const serializer = @import("../../src/internal/application/response_gzip.zig");
const gzip_encoder = @import("../../src/internal/runtime/gzip/encoder.zig");
const response_head = @import("../../src/internal/http1/response_head.zig");

const test_limits = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 16,
});

const tight_field_limits = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 4,
});

const selected_too_small = response.HeadLimits.validate(.{
    .head_bytes_max = 128,
    .field_line_bytes_max = 64,
    .fields_max = 1,
});

const ResponseWorkspace = response.Workspace(test_limits);
const Response = response.Response(test_limits);
const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const gzip_options = serializer.Options{ .minimum_bytes = 0, .level = .fastest };

const identity_wire =
    "HTTP/1.1 200 OK\r\n" ++
    "vary: Accept-Encoding\r\n" ++
    "content-type: application/octet-stream\r\n" ++
    "content-length: 4\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "\r\n" ++
    "data";

const application_encoded_wire =
    "HTTP/1.1 200 OK\r\n" ++
    "content-encoding: br\r\n" ++
    "content-type: text/plain; charset=utf-8\r\n" ++
    "content-length: 4\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "\r\n" ++
    "data";

const not_acceptable_wire =
    "HTTP/1.1 406 Not Acceptable\r\n" ++
    "vary: Accept-Encoding\r\n" ++
    "content-length: 0\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "connection: close\r\n" ++
    "\r\n";

const unavailable_wire =
    "HTTP/1.1 503 Service Unavailable\r\n" ++
    "vary: Accept-Encoding\r\n" ++
    "content-length: 0\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "connection: close\r\n" ++
    "\r\n";

test "compressibility classifier covers textual structured and binary media" {
    const compressible = [_][]const u8{
        "text/plain",
        "TEXT/HTML; charset=utf-8",
        "application/json",
        "application/problem+json",
        "application/javascript",
        "application/xml",
        "application/atom+xml",
        "image/svg+xml",
    };
    for (compressible) |value| {
        try std.testing.expect(serializer.isCompressibleMediaType(value));
    }

    const incompressible = [_][]const u8{
        "application/octet-stream",
        "application/zip",
        "application/jsonp",
        "image/png",
        "audio/mpeg",
        "not-a-media-type",
    };
    for (incompressible) |value| {
        try std.testing.expect(!serializer.isCompressibleMediaType(value));
    }
}

test "ineligible identity negotiates while application coding bypasses negotiation" {
    var workspace = ResponseWorkspace{};
    const identity = Response.bytesStatic(&workspace, .ok, "data");
    var identity_output: [identity_wire.len]u8 = undefined;
    const identity_prepared = try serializer.serialize(
        test_limits,
        test_limits,
        &identity,
        request("GET", .{ .gzip = 1000, .identity = 1000 }),
        &identity_output,
        null,
        gzip_options,
        null,
    );
    try std.testing.expectEqualStrings(identity_wire, identity_prepared.bytes);
    try std.testing.expectEqual(
        serializer.CodingOutcome.skipped_ineligible,
        identity_prepared.coding_outcome,
    );

    var too_short = [_]u8{0xa5} ** (identity_wire.len - 1);
    const before = too_short;
    try std.testing.expectError(error.OutputTooSmall, serializer.serialize(
        test_limits,
        test_limits,
        &identity,
        request("GET", .{ .gzip = 1000, .identity = 1000 }),
        &too_short,
        null,
        gzip_options,
        null,
    ));
    try std.testing.expectEqualSlices(u8, &before, &too_short);

    var forbidden_output: [not_acceptable_wire.len]u8 = undefined;
    const forbidden = try serializer.serialize(
        test_limits,
        test_limits,
        &identity,
        request("GET", .{ .gzip = 1000, .identity = 0 }),
        &forbidden_output,
        null,
        gzip_options,
        null,
    );
    try std.testing.expectEqualStrings(not_acceptable_wire, forbidden.bytes);
    try std.testing.expectEqual(.not_acceptable, forbidden.coding_outcome);

    var encoded = Response.textStatic(&workspace, .ok, "data");
    try encoded.setHeader("Content-Encoding", "br");
    const headers_before = workspace.headers;
    var encoded_output: [application_encoded_wire.len]u8 = undefined;
    const encoded_prepared = try serializer.serialize(
        test_limits,
        test_limits,
        &encoded,
        request("GET", .{ .gzip = 0, .identity = 0 }),
        &encoded_output,
        null,
        gzip_options,
        null,
    );
    try std.testing.expectEqualStrings(application_encoded_wire, encoded_prepared.bytes);
    try std.testing.expectEqual(
        serializer.CodingOutcome.application_content_encoding,
        encoded_prepared.coding_outcome,
    );
    try std.testing.expectEqualDeep(headers_before, workspace.headers);
}

test "identity serializes explicit request and server fields exactly" {
    const expected =
        "HTTP/1.1 200 OK\r\n" ++
        "vary: Accept-Encoding\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 2\r\n" ++
        "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
        "server: ploof-test\r\n" ++
        "connection: close\r\n" ++
        "\r\n" ++
        "ok";
    var workspace = ResponseWorkspace{};
    const value = Response.textStatic(&workspace, .ok, "ok");
    var output: [expected.len]u8 = undefined;
    var fields = request("GET", .{ .gzip = 0, .identity = 1000 });
    fields.accepts_response_trailers = true;
    fields.connection_close = true;
    const prepared = try serializer.serialize(
        test_limits,
        test_limits,
        &value,
        fields,
        &output,
        null,
        gzip_options,
        response_head.ServerIdentity.init("ploof-test"),
    );
    try std.testing.expectEqualStrings(expected, prepared.bytes);
    try std.testing.expect(prepared.close_connection);
    try std.testing.expectEqual(.identity_negotiated, prepared.coding_outcome);
}

test "gzip stages safely and round trips at every level" {
    const body = ("compressible html and json payload " ** 12) ++ "done";
    var workspace = ResponseWorkspace{};
    var value = Response.htmlStatic(&workspace, .ok, body);
    try value.setHeader("X-Test", "yes");
    const headers_before = workspace.headers;
    var encoder: gzip_encoder.Workspace = undefined;
    var guarded = [_]u8{0xa5} ** 4098;

    inline for ([_]gzip_encoder.Level{ .fastest, .default, .best }) |level| {
        @memset(&guarded, 0xa5);
        const prepared = try serializer.serialize(
            test_limits,
            test_limits,
            &value,
            request("GET", .{ .gzip = 1000, .identity = 1000 }),
            guarded[1 .. guarded.len - 1],
            &encoder,
            .{ .minimum_bytes = 0, .level = level },
            null,
        );
        try std.testing.expectEqual(serializer.CodingOutcome.gzip, prepared.coding_outcome);
        try std.testing.expect(std.mem.startsWith(
            u8,
            prepared.bytes,
            "HTTP/1.1 200 OK\r\n" ++
                "x-test: yes\r\n" ++
                "content-encoding: gzip\r\n" ++
                "vary: Accept-Encoding\r\n",
        ));
        try expectGzipRoundTrip(prepared.bytes, body);
        try std.testing.expectEqual(@as(u8, 0xa5), guarded[0]);
        try std.testing.expectEqual(@as(u8, 0xa5), guarded[guarded.len - 1]);
        try std.testing.expectEqualDeep(headers_before, workspace.headers);
    }
}

test "all weight ties and zero combinations select exact outcomes" {
    const Case = struct {
        preferences: serializer.RequestFields,
        outcome: serializer.CodingOutcome,
        status: response.Status,
        gzip: bool,
    };
    const cases = [_]Case{
        .{
            .preferences = request("GET", .{ .gzip = 1000, .identity = 1000 }),
            .outcome = .gzip,
            .status = .ok,
            .gzip = true,
        },
        .{
            .preferences = request("GET", .{ .gzip = 900, .identity = 400 }),
            .outcome = .gzip,
            .status = .ok,
            .gzip = true,
        },
        .{
            .preferences = request("GET", .{ .gzip = 400, .identity = 900 }),
            .outcome = .identity_negotiated,
            .status = .ok,
            .gzip = false,
        },
        .{
            .preferences = request("GET", .{ .gzip = 0, .identity = 1000 }),
            .outcome = .identity_negotiated,
            .status = .ok,
            .gzip = false,
        },
        .{
            .preferences = request("GET", .{ .gzip = 1000, .identity = 0 }),
            .outcome = .gzip,
            .status = .ok,
            .gzip = true,
        },
        .{
            .preferences = request("GET", .{ .gzip = 0, .identity = 0 }),
            .outcome = .not_acceptable,
            .status = .not_acceptable,
            .gzip = false,
        },
    };
    var workspace = ResponseWorkspace{};
    var encoder: gzip_encoder.Workspace = undefined;
    var output: [4096]u8 = undefined;
    for (cases) |case| {
        const value = Response.textStatic(&workspace, .ok, "weight table");
        const prepared = try serializer.serialize(
            test_limits,
            test_limits,
            &value,
            case.preferences,
            &output,
            &encoder,
            gzip_options,
            null,
        );
        try std.testing.expectEqual(case.outcome, prepared.coding_outcome);
        try std.testing.expectEqual(case.status, prepared.status);
        try std.testing.expectEqual(
            case.gzip,
            std.mem.indexOf(u8, prepared.bytes, "content-encoding: gzip\r\n") != null,
        );
        try std.testing.expect(std.mem.indexOf(
            u8,
            prepared.bytes,
            "vary: Accept-Encoding\r\n",
        ) != null);
    }
}

test "threshold and capacity failures follow deterministic fallback policy" {
    var workspace = ResponseWorkspace{};
    const value = Response.textStatic(&workspace, .ok, "data");
    var encoder: gzip_encoder.Workspace = undefined;
    var output: [4096]u8 = undefined;

    const below = try serializer.serialize(
        test_limits,
        test_limits,
        &value,
        request("GET", .{ .gzip = 1000, .identity = 1000 }),
        &output,
        &encoder,
        .{ .minimum_bytes = 5, .level = .fastest },
        null,
    );
    try std.testing.expectEqual(.identity_below_threshold, below.coding_outcome);

    const below_forbidden = try serializer.serialize(
        selected_too_small,
        test_limits,
        &value,
        request("GET", .{ .gzip = 1000, .identity = 0 }),
        &output,
        &encoder,
        .{ .minimum_bytes = 5, .level = .fastest },
        null,
    );
    try std.testing.expectEqualStrings(not_acceptable_wire, below_forbidden.bytes);

    const no_workspace = try serializer.serialize(
        test_limits,
        test_limits,
        &value,
        request("GET", .{ .gzip = 1000, .identity = 1000 }),
        &output,
        null,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(.identity_capacity_fallback, no_workspace.coding_outcome);
    try std.testing.expect(std.mem.endsWith(u8, no_workspace.bytes, "\r\n\r\ndata"));

    var small_output: [256]u8 = undefined;
    const output_fallback = try serializer.serialize(
        test_limits,
        test_limits,
        &value,
        request("GET", .{ .gzip = 1000, .identity = 1000 }),
        &small_output,
        &encoder,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(.identity_capacity_fallback, output_fallback.coding_outcome);

    const unavailable = try serializer.serialize(
        test_limits,
        test_limits,
        &value,
        request("GET", .{ .gzip = 1000, .identity = 0 }),
        &small_output,
        null,
        gzip_options,
        null,
    );
    try std.testing.expectEqualStrings(unavailable_wire, unavailable.bytes);
    try std.testing.expectEqual(.capacity_unavailable, unavailable.coding_outcome);
    try std.testing.expect(unavailable.close_connection);
}

test "synthetic head capacity falls back before commitment" {
    var workspace = ResponseWorkspace{};
    const value = Response.textStatic(&workspace, .ok, "head capacity");
    var encoder: gzip_encoder.Workspace = undefined;
    var output: [4096]u8 = undefined;

    const fallback = try serializer.serialize(
        tight_field_limits,
        test_limits,
        &value,
        request("GET", .{ .gzip = 1000, .identity = 1000 }),
        &output,
        &encoder,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(.identity_capacity_fallback, fallback.coding_outcome);
    try std.testing.expect(std.mem.indexOf(u8, fallback.bytes, "content-encoding") == null);

    const unavailable = try serializer.serialize(
        selected_too_small,
        test_limits,
        &value,
        request("GET", .{ .gzip = 1000, .identity = 0 }),
        &output,
        &encoder,
        gzip_options,
        null,
    );
    try std.testing.expectEqualStrings(unavailable_wire, unavailable.bytes);
}

test "HEAD performs gzip work and emits GET metadata without a body" {
    const body = "the same representation metadata must be selected for HEAD" ** 4;
    var workspace = ResponseWorkspace{};
    const value = Response.textStatic(&workspace, .ok, body);
    var encoder: gzip_encoder.Workspace = undefined;
    var get_output: [4096]u8 = undefined;
    var head_output: [4096]u8 = undefined;
    const get = try serializer.serialize(
        test_limits,
        test_limits,
        &value,
        request("GET", .{ .gzip = 1000, .identity = 1000 }),
        &get_output,
        &encoder,
        gzip_options,
        null,
    );
    const head = try serializer.serialize(
        test_limits,
        test_limits,
        &value,
        request("HEAD", .{ .gzip = 1000, .identity = 1000 }),
        &head_output,
        &encoder,
        gzip_options,
        null,
    );
    const get_parts = try wireParts(get.bytes);
    try std.testing.expectEqualStrings(get_parts.head, head.bytes);
    try std.testing.expectEqual(.gzip, head.coding_outcome);
    try std.testing.expectEqual(@as(usize, 0), (try wireParts(head.bytes)).body.len);
    try expectGzipRoundTrip(get.bytes, body);

    const rejected = try serializer.serialize(
        test_limits,
        test_limits,
        &value,
        request("HEAD", .{ .gzip = 0, .identity = 0 }),
        &head_output,
        null,
        gzip_options,
        null,
    );
    try std.testing.expectEqualStrings(not_acceptable_wire, rejected.bytes);
    const unavailable = try serializer.serialize(
        test_limits,
        test_limits,
        &value,
        request("HEAD", .{ .gzip = 1000, .identity = 0 }),
        &head_output,
        null,
        gzip_options,
        null,
    );
    try std.testing.expectEqualStrings(unavailable_wire, unavailable.bytes);
}

test "absent and present-empty bodies retain distinct coding decisions" {
    var workspace = ResponseWorkspace{};
    var output: [4096]u8 = undefined;
    var encoder: gzip_encoder.Workspace = undefined;

    const none = Response.empty(&workspace, .ok);
    const none_prepared = try serializer.serialize(
        test_limits,
        test_limits,
        &none,
        request("GET", .{ .gzip = 1000, .identity = 1000 }),
        &output,
        null,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(.skipped_bodyless, none_prepared.coding_outcome);
    try std.testing.expect(std.mem.indexOf(u8, none_prepared.bytes, "vary:") == null);

    const present = Response.textStatic(&workspace, .ok, "");
    const identity = try serializer.serialize(
        test_limits,
        test_limits,
        &present,
        request("GET", .{ .gzip = 1000, .identity = 1000 }),
        &output,
        null,
        .{ .minimum_bytes = 1, .level = .fastest },
        null,
    );
    try std.testing.expectEqual(.identity_below_threshold, identity.coding_outcome);
    try std.testing.expect(std.mem.indexOf(u8, identity.bytes, "vary: Accept-Encoding") != null);

    const gzip = try serializer.serialize(
        test_limits,
        test_limits,
        &present,
        request("GET", .{ .gzip = 1000, .identity = 1000 }),
        &output,
        &encoder,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(serializer.CodingOutcome.gzip, gzip.coding_outcome);
    try expectGzipRoundTrip(gzip.bytes, "");
}

test "malformed application coding fields reject before output mutation" {
    const Case = struct { name: []const u8, value: []const u8 };
    const cases = [_]Case{
        .{ .name = "Content-Encoding", .value = "" },
        .{ .name = "Content-Encoding", .value = "gzip;q=1" },
        .{ .name = "Vary", .value = "Accept Encoding" },
        .{ .name = "Vary", .value = "Accept-Encoding;q=1" },
    };
    var workspace = ResponseWorkspace{};
    var encoder: gzip_encoder.Workspace = undefined;
    for (cases) |case| {
        var value = Response.textStatic(&workspace, .ok, "body");
        try value.setHeader(case.name, case.value);
        const headers_before = workspace.headers;
        var output = [_]u8{0xa5} ** 1024;
        const before = output;
        try std.testing.expectError(error.InvalidHeader, serializer.serialize(
            test_limits,
            test_limits,
            &value,
            request("GET", .{ .gzip = 1000, .identity = 1000 }),
            &output,
            &encoder,
            gzip_options,
            null,
        ));
        try std.testing.expectEqualSlices(u8, &before, &output);
        try std.testing.expectEqualDeep(headers_before, workspace.headers);
    }
}

test "Vary suppression and Content-Type overrides drive actual representation" {
    var workspace = ResponseWorkspace{};
    var encoder: gzip_encoder.Workspace = undefined;
    var output: [4096]u8 = undefined;

    var wildcard = Response.textStatic(&workspace, .ok, "wildcard vary");
    try wildcard.setHeader("Vary", "*, Accept-Language");
    const wildcard_before = workspace.headers;
    const wildcard_prepared = try serializer.serialize(
        test_limits,
        test_limits,
        &wildcard,
        request("GET", .{ .gzip = 1000, .identity = 1000 }),
        &output,
        &encoder,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, wildcard_prepared.bytes, "vary:"),
    );
    try std.testing.expect(
        std.mem.indexOf(u8, wildcard_prepared.bytes, "vary: *, Accept-Language") != null,
    );
    try std.testing.expectEqualDeep(wildcard_before, workspace.headers);

    var override_compressible = Response.bytesStatic(&workspace, .ok, "json bytes");
    try override_compressible.setHeader("Content-Type", "application/problem+json");
    const compressed = try serializer.serialize(
        test_limits,
        test_limits,
        &override_compressible,
        request("GET", .{ .gzip = 1000, .identity = 1000 }),
        &output,
        &encoder,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(serializer.CodingOutcome.gzip, compressed.coding_outcome);

    var override_binary = Response.textStatic(&workspace, .ok, "text bytes");
    try override_binary.setHeader("Content-Type", "application/octet-stream");
    const binary = try serializer.serialize(
        test_limits,
        test_limits,
        &override_binary,
        request("GET", .{ .gzip = 1000, .identity = 1000 }),
        &output,
        &encoder,
        gzip_options,
        null,
    );
    try std.testing.expectEqual(.skipped_ineligible, binary.coding_outcome);
    try std.testing.expect(
        std.mem.indexOf(u8, binary.bytes, "vary: Accept-Encoding") != null,
    );
}

fn request(
    method: []const u8,
    preferences: @import("../../src/internal/http1/request_accept_encoding.zig").Preferences,
) serializer.RequestFields {
    return .{
        .method = method,
        .accept_encoding = preferences,
        .accepts_response_trailers = false,
        .date = fixed_date,
        .connection_close = false,
    };
}

const WireParts = struct {
    head: []const u8,
    body: []const u8,
};

fn wireParts(bytes: []const u8) !WireParts {
    const marker = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse {
        return error.TestUnexpectedResult;
    };
    const body_start = marker + "\r\n\r\n".len;
    return .{ .head = bytes[0..body_start], .body = bytes[body_start..] };
}

fn expectGzipRoundTrip(wire: []const u8, expected: []const u8) !void {
    const parts = try wireParts(wire);
    try std.testing.expectEqual(parts.body.len, try contentLength(parts.head));
    var input_reader = std.Io.Reader.fixed(parts.body);
    var decoder = std.compress.flate.Decompress.init(&input_reader, .gzip, &.{});
    var decoded: [1024]u8 = undefined;
    if (expected.len > decoded.len) return error.TestUnexpectedResult;
    var writer = std.Io.Writer.fixed(decoded[0..expected.len]);
    const written = try decoder.reader.streamRemaining(&writer);
    try std.testing.expectEqual(expected.len, written);
    try std.testing.expectEqualStrings(expected, decoded[0..written]);
}

fn contentLength(head: []const u8) !usize {
    const prefix = "content-length: ";
    const start = (std.mem.indexOf(u8, head, prefix) orelse {
        return error.TestUnexpectedResult;
    }) + prefix.len;
    const end = std.mem.indexOfPos(u8, head, start, "\r\n") orelse {
        return error.TestUnexpectedResult;
    };
    return std.fmt.parseInt(usize, head[start..end], 10);
}
