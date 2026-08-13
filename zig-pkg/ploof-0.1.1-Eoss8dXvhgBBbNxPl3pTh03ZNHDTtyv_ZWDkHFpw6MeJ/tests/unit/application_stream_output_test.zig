const std = @import("std");
const serializer = @import("../../src/internal/application/stream_output.zig");
const response = @import("../../src/response.zig");
const response_stream = @import("../../src/response/stream.zig");
const stream_response = @import("../../src/response/streaming.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const limits = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 12,
});
const Workspace = response.Workspace(limits);
const Producer = struct { marker: u32 };
const StreamResponse = stream_response.Response(limits, Producer);

fn request() serializer.RequestFields {
    return .{
        .method = "GET",
        .accept_encoding = .{},
        .accepts_response_trailers = false,
        .date = fixed_date,
        .connection_close = false,
    };
}

fn exact(workspace: *Workspace, length: u64) !StreamResponse {
    return StreamResponse.init(
        workspace,
        .ok,
        response.media.text,
        response_stream.exact(length, Producer{ .marker = 17 }),
    );
}

fn unknown(workspace: *Workspace, declarations: []const []const u8) !StreamResponse {
    return StreamResponse.init(
        workspace,
        .ok,
        response.media.json,
        response_stream.unknown(Producer{ .marker = 19 }, declarations),
    );
}

test "exact stream emits identity Vary and fixed framing" {
    var workspace = Workspace{};
    const value = try exact(&workspace, 5);
    const before = workspace;
    var output: [512]u8 = @splat(0xa5);

    const result = try serializer.serialize(
        limits,
        limits,
        value,
        &workspace,
        request(),
        &output,
        null,
    );

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++
            "vary: Accept-Encoding\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 5\r\n" ++
            "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n\r\n",
        result.bytes,
    );
    try std.testing.expectEqual(@as(u64, 5), result.framing.framing.fixed);
    try std.testing.expect(result.framing.send_body);
    try std.testing.expect(result.framing.invoke_stream);
    try std.testing.expect(!result.trailers.emitted);
    try std.testing.expectEqual(serializer.CodingOutcome.identity, result.coding_outcome);
    try std.testing.expectEqualDeep(before, workspace);
    try std.testing.expectEqual(@as(u8, 0xa5), output[result.bytes.len]);
}

test "unknown stream emits negotiated trailer declaration" {
    const declarations = [_][]const u8{ "digest", "x-stats" };
    var workspace = Workspace{};
    const value = try unknown(&workspace, &declarations);
    var accepted = request();
    accepted.accepts_response_trailers = true;
    var output: [512]u8 = undefined;

    const result = try serializer.serialize(
        limits,
        limits,
        value,
        &workspace,
        accepted,
        &output,
        null,
    );

    try std.testing.expect(
        std.mem.indexOf(u8, result.bytes, "transfer-encoding: chunked\r\n") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, result.bytes, "trailer: digest, x-stats\r\n") != null,
    );
    try std.testing.expect(result.framing.framing == .chunked);
    try std.testing.expect(result.framing.emit_trailers);
    try std.testing.expect(result.trailers.emitted);
    try std.testing.expectEqual(@as(usize, 2), result.trailers.declarations.len);
}

test "unnegotiated unknown stream omits trailers but remains chunked" {
    const declarations = [_][]const u8{"digest"};
    var workspace = Workspace{};
    const value = try unknown(&workspace, &declarations);
    var output: [512]u8 = undefined;
    const result = try serializer.serialize(
        limits,
        limits,
        value,
        &workspace,
        request(),
        &output,
        null,
    );

    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "trailer:") == null);
    try std.testing.expect(result.framing.framing == .chunked);
    try std.testing.expect(!result.framing.emit_trailers);
    try std.testing.expect(!result.trailers.emitted);
    try std.testing.expectEqual(@as(usize, 0), result.trailers.declarations.len);
}

test "HEAD suppresses exact and unknown producer invocation" {
    inline for (.{ false, true }) |use_unknown| {
        var workspace = Workspace{};
        const value = if (use_unknown)
            try unknown(&workspace, &.{"digest"})
        else
            try exact(&workspace, 41);
        var head = request();
        head.method = "HEAD";
        head.accepts_response_trailers = true;
        var output: [512]u8 = undefined;
        const result = try serializer.serialize(
            limits,
            limits,
            value,
            &workspace,
            head,
            &output,
            null,
        );

        try std.testing.expect(!result.framing.send_body);
        try std.testing.expect(!result.framing.invoke_stream);
        try std.testing.expect(!result.framing.emit_trailers);
        try std.testing.expect(!result.trailers.emitted);
        if (use_unknown) {
            try std.testing.expect(result.framing.framing == .none);
            try std.testing.expect(std.mem.indexOf(u8, result.bytes, "content-length:") == null);
        } else {
            try std.testing.expectEqual(@as(u64, 41), result.framing.framing.fixed);
        }
    }
}

test "forbidden identity selects closed 406 without producer invocation" {
    const declarations = [_][]const u8{"digest"};
    var workspace = Workspace{};
    const value = try unknown(&workspace, &declarations);
    const before = workspace;
    var rejected = request();
    rejected.accept_encoding = .{ .gzip = 1000, .identity = 0 };
    var output: [512]u8 = @splat(0xa5);

    const result = try serializer.serialize(
        limits,
        limits,
        value,
        &workspace,
        rejected,
        &output,
        null,
    );

    try std.testing.expectEqual(response.Status.not_acceptable, result.status);
    try std.testing.expect(result.close_connection);
    try std.testing.expect(!result.framing.invoke_stream);
    try std.testing.expectEqual(serializer.CodingOutcome.not_acceptable, result.coding_outcome);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "vary: Accept-Encoding\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "connection: close\r\n") != null);
    try std.testing.expectEqualDeep(before, workspace);
    try std.testing.expectEqual(@as(u32, 19), value.stream.producer.marker);
}

test "existing Vary suppresses only redundant synthetic field" {
    const cases = .{
        .{ "Accept-Language", 2 },
        .{ "accept-encoding", 1 },
        .{ "*", 1 },
    };
    inline for (cases) |case| {
        var workspace = Workspace{};
        var value = try exact(&workspace, 3);
        try value.setHeader("Vary", case[0]);
        var output: [512]u8 = undefined;
        const result = try serializer.serialize(
            limits,
            limits,
            value,
            &workspace,
            request(),
            &output,
            null,
        );
        try std.testing.expectEqual(
            @as(usize, case[1]),
            std.mem.count(u8, result.bytes, "vary:"),
        );
    }
}

test "foreign ownership coding and malformed inputs fail transactionally" {
    var owner = Workspace{};
    var foreign = Workspace{};
    var value = try exact(&owner, 3);
    var output: [512]u8 = @splat(0xa5);
    try std.testing.expectError(
        error.InvalidResponse,
        serializer.serialize(limits, limits, value, &foreign, request(), &output, null),
    );
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 512), &output);

    var invalid_preferences = request();
    invalid_preferences.accept_encoding.identity = 1001;
    try std.testing.expectError(
        error.InvalidResponse,
        serializer.serialize(limits, limits, value, &owner, invalid_preferences, &output, null),
    );

    try value.setHeader("Content-Encoding", "gzip");
    try std.testing.expectError(
        error.InvalidResponse,
        serializer.serialize(limits, limits, value, &owner, request(), &output, null),
    );
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 512), &output);
}

test "invalid declarations and tight output preserve destination" {
    var workspace = Workspace{};
    const invalid_names = [_][]const u8{"content-length"};
    const invalid = try unknown(&workspace, &invalid_names);
    var output: [512]u8 = @splat(0xa5);
    var accepted = request();
    accepted.accepts_response_trailers = true;
    try std.testing.expectError(
        error.InvalidTrailer,
        serializer.serialize(limits, limits, invalid, &workspace, accepted, &output, null),
    );
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 512), &output);

    const valid = try exact(&workspace, 3);
    var tight: [8]u8 = @splat(0xa5);
    try std.testing.expectError(
        error.OutputTooSmall,
        serializer.serialize(limits, limits, valid, &workspace, request(), &tight, null),
    );
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 8), &tight);
}

test "framework 406 fits selected standard profile" {
    const bytes = serializer.frameworkBytesRequired(limits, null) orelse unreachable;
    try std.testing.expect(bytes > 0);
    try std.testing.expect(bytes <= limits.head_bytes_max);
}
