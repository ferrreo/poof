const std = @import("std");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const syntax = @import("../src/internal/http1/syntax.zig");
const serializer = @import("../src/internal/application/stream_output.zig");
const response = @import("../src/response.zig");
const response_stream = @import("../src/response/stream.zig");
const stream_response = @import("../src/response/streaming.zig");

const sentinel: u8 = 0xa5;
const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const limits = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 12,
});
const Workspace = response.Workspace(limits);

const Producer = struct {
    marker: [8]u8,

    pub fn poll(
        _: *@This(),
        _: []u8,
        _: response_stream.Wake,
    ) response_stream.PollError!response_stream.PollResult {
        return .pending;
    }
};

const StreamResponse = stream_response.Response(limits, Producer);

const Flags = packed struct(u8) {
    head: bool,
    unknown: bool,
    accepts_trailers: bool,
    identity_allowed: bool,
    connection_close: bool,
    application_encoding: bool,
    _padding: u2 = 0,
};

const no_names = [_][]const u8{};
const digest_name = [_][]const u8{"digest"};
const two_names = [_][]const u8{ "digest", "x-stats" };
const forbidden_name = [_][]const u8{"content-length"};
const duplicate_names = [_][]const u8{ "digest", "DIGEST" };
const malformed_name = [_][]const u8{"bad name"};

test "stream response head serializer bounded composition fuzz" {
    try std.testing.fuzz({}, fuzzSerializer, .{ .corpus = &fuzz_corpus });
}

fn fuzzSerializer(_: void, smith: *std.testing.Smith) !void {
    const flags: Flags = @bitCast(smith.value(u8));
    const trailer_shape = smith.valueRangeAtMost(u8, 0, 5);
    const vary_shape = smith.valueRangeAtMost(u8, 0, 5);
    const exact_length = smith.valueRangeAtMost(u16, 0, 4096);
    const capacity = smith.valueRangeAtMost(u16, 0, limits.head_bytes_max);
    const declarations = trailerNames(trailer_shape);

    var workspace = Workspace{};
    var value = try streamValue(
        &workspace,
        flags,
        exact_length,
        declarations,
    );
    try applyVary(&value, vary_shape);
    if (flags.application_encoding) {
        try value.setHeader("Content-Encoding", "gzip");
    }
    const workspace_before = workspace;
    const value_before = value;
    var guarded = [_]u8{sentinel} ** (limits.head_bytes_max + 2);
    const output = guarded[1 .. 1 + capacity];

    const result = serializer.serialize(
        limits,
        limits,
        value,
        &workspace,
        request(flags),
        output,
        null,
    ) catch |problem| return expectFailure(
        problem,
        expectedSemanticError(flags, trailer_shape, vary_shape),
        workspace_before,
        workspace,
        value_before,
        value,
        &guarded,
    );

    try std.testing.expect(expectedSemanticError(flags, trailer_shape, vary_shape) == null);
    try expectSourceUnchanged(workspace_before, workspace, value_before, value);
    try expectSuccessGuard(&guarded, capacity, result.bytes.len);
    try expectPrepared(
        result,
        flags,
        trailer_shape,
        vary_shape,
        exact_length,
        output,
    );
}

fn streamValue(
    workspace: *Workspace,
    flags: Flags,
    exact_length: u16,
    declarations: []const []const u8,
) !StreamResponse {
    const producer = Producer{ .marker = @splat(0x3c) };
    if (flags.unknown) {
        return StreamResponse.init(
            workspace,
            .ok,
            response.media.text,
            response_stream.unknown(producer, declarations),
        );
    }
    var value = try StreamResponse.init(
        workspace,
        .ok,
        response.media.text,
        response_stream.exact(exact_length, producer),
    );
    value.stream.trailer_names = declarations;
    return value;
}

fn request(flags: Flags) serializer.RequestFields {
    return .{
        .method = if (flags.head) "HEAD" else "GET",
        .accept_encoding = .{
            .gzip = 1000,
            .identity = if (flags.identity_allowed) 1000 else 0,
        },
        .accepts_response_trailers = flags.accepts_trailers,
        .date = fixed_date,
        .connection_close = flags.connection_close,
    };
}

fn trailerNames(shape: u8) []const []const u8 {
    return switch (shape) {
        0 => &no_names,
        1 => &digest_name,
        2 => &two_names,
        3 => &forbidden_name,
        4 => &duplicate_names,
        5 => &malformed_name,
        else => unreachable,
    };
}

fn applyVary(value: *StreamResponse, shape: u8) !void {
    const bytes: ?[]const u8 = switch (shape) {
        0 => null,
        1 => "Accept-Language",
        2 => "accept-encoding",
        3 => "*",
        4 => "Accept-Encoding;",
        5 => "Accept-Language, Accept-Encoding",
        else => unreachable,
    };
    if (bytes) |selected| try value.setHeader("Vary", selected);
}

fn expectedSemanticError(
    flags: Flags,
    trailer_shape: u8,
    vary_shape: u8,
) ?serializer.Error {
    if (!flags.unknown and trailer_shape != 0) return error.InvalidResponse;
    if (vary_shape == 4) return error.InvalidHeader;
    if (flags.application_encoding) return error.InvalidResponse;
    if (flags.identity_allowed and flags.unknown and trailer_shape >= 3) {
        return error.InvalidTrailer;
    }
    return null;
}

fn expectFailure(
    problem: serializer.Error,
    expected: ?serializer.Error,
    workspace_before: Workspace,
    workspace_after: Workspace,
    value_before: StreamResponse,
    value_after: StreamResponse,
    guarded: []const u8,
) !void {
    try expectSourceUnchanged(
        workspace_before,
        workspace_after,
        value_before,
        value_after,
    );
    for (guarded) |byte| try std.testing.expectEqual(sentinel, byte);
    if (expected) |semantic| {
        try std.testing.expectEqual(semantic, problem);
        return;
    }
    try std.testing.expectEqual(error.OutputTooSmall, problem);
}

fn expectSourceUnchanged(
    workspace_before: Workspace,
    workspace_after: Workspace,
    value_before: StreamResponse,
    value_after: StreamResponse,
) !void {
    try std.testing.expectEqualDeep(workspace_before, workspace_after);
    try std.testing.expectEqualDeep(value_before, value_after);
}

fn expectSuccessGuard(guarded: []const u8, capacity: usize, used: usize) !void {
    try std.testing.expectEqual(sentinel, guarded[0]);
    try std.testing.expect(used <= capacity);
    for (guarded[1 + used ..]) |byte| try std.testing.expectEqual(sentinel, byte);
}

fn expectPrepared(
    prepared: serializer.Prepared,
    flags: Flags,
    trailer_shape: u8,
    vary_shape: u8,
    exact_length: u16,
    output: []const u8,
) !void {
    try std.testing.expect(prepared.bytes.ptr == output.ptr);
    const wire = try Wire.parse(prepared.bytes);
    const rejected = !flags.identity_allowed;
    try std.testing.expectEqual(
        if (rejected) response.Status.not_acceptable else response.Status.ok,
        prepared.status,
    );
    try std.testing.expectEqual(rejected or flags.connection_close, prepared.close_connection);
    try expectVary(wire.head, rejected, vary_shape);
    try expectFraming(prepared, wire.head, flags, rejected, exact_length);
    try expectTrailers(prepared, wire.head, flags, rejected, trailer_shape);
}

fn expectVary(head: []const u8, rejected: bool, shape: u8) !void {
    const expected_count: usize = if (rejected or shape == 0)
        1
    else if (shape == 1)
        2
    else
        1;
    try std.testing.expectEqual(expected_count, headerCount(head, "vary"));
    if (rejected or shape == 0 or shape == 1) {
        try std.testing.expect(headerHasValue(head, "vary", "Accept-Encoding"));
    }
}

fn expectFraming(
    prepared: serializer.Prepared,
    head: []const u8,
    flags: Flags,
    rejected: bool,
    exact_length: u16,
) !void {
    if (rejected) {
        try std.testing.expectEqual(@as(u64, 0), prepared.framing.framing.fixed);
        try std.testing.expect(!prepared.framing.invoke_stream);
        try std.testing.expectEqualStrings("0", headerValue(head, "content-length").?);
        try std.testing.expect(headerValue(head, "transfer-encoding") == null);
        return;
    }
    if (flags.head) {
        try std.testing.expect(!prepared.framing.send_body);
        try std.testing.expect(!prepared.framing.invoke_stream);
        if (flags.unknown) {
            try std.testing.expect(prepared.framing.framing == .none);
            try std.testing.expect(headerValue(head, "content-length") == null);
        } else {
            try expectFixed(prepared, head, exact_length);
        }
        return;
    }
    try std.testing.expect(prepared.framing.invoke_stream);
    if (flags.unknown) {
        try std.testing.expect(prepared.framing.framing == .chunked);
        try std.testing.expectEqualStrings(
            "chunked",
            headerValue(head, "transfer-encoding").?,
        );
    } else {
        try expectFixed(prepared, head, exact_length);
    }
}

fn expectFixed(prepared: serializer.Prepared, head: []const u8, length: u16) !void {
    try std.testing.expectEqual(@as(u64, length), prepared.framing.framing.fixed);
    const actual = try std.fmt.parseInt(u64, headerValue(head, "content-length").?, 10);
    try std.testing.expectEqual(@as(u64, length), actual);
}

fn expectTrailers(
    prepared: serializer.Prepared,
    head: []const u8,
    flags: Flags,
    rejected: bool,
    trailer_shape: u8,
) !void {
    const emitted = !rejected and !flags.head and flags.unknown and
        flags.accepts_trailers and trailer_shape != 0;
    try std.testing.expectEqual(emitted, prepared.trailers.emitted);
    try std.testing.expectEqual(emitted, headerValue(head, "trailer") != null);
    const expected_count: usize = if (!emitted)
        0
    else if (trailer_shape == 1)
        1
    else
        2;
    try std.testing.expectEqual(expected_count, prepared.trailers.declarations.len);
}

const Wire = struct {
    head: []const u8,

    fn parse(bytes: []const u8) !Wire {
        const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse {
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(end + 4, bytes.len);
        return .{ .head = bytes };
    }
};

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    const status_end = std.mem.indexOf(u8, head, "\r\n") orelse return null;
    var remaining = head[status_end + 2 ..];
    while (remaining.len != 0) {
        const line_end = std.mem.indexOf(u8, remaining, "\r\n") orelse return null;
        const line = remaining[0..line_end];
        if (line.len == 0) return null;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        if (syntax.eqlIgnoreCase(line[0..colon], name)) {
            return syntax.trimOws(line[colon + 1 ..]);
        }
        remaining = remaining[line_end + 2 ..];
    }
    return null;
}

fn headerCount(head: []const u8, name: []const u8) usize {
    const status_end = std.mem.indexOf(u8, head, "\r\n") orelse return 0;
    var remaining = head[status_end + 2 ..];
    var count: usize = 0;
    while (remaining.len != 0) {
        const line_end = std.mem.indexOf(u8, remaining, "\r\n") orelse return count;
        const line = remaining[0..line_end];
        if (line.len == 0) return count;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return count;
        count += @intFromBool(syntax.eqlIgnoreCase(line[0..colon], name));
        remaining = remaining[line_end + 2 ..];
    }
    return count;
}

fn headerHasValue(head: []const u8, name: []const u8, value: []const u8) bool {
    const status_end = std.mem.indexOf(u8, head, "\r\n") orelse return false;
    var remaining = head[status_end + 2 ..];
    while (remaining.len != 0) {
        const line_end = std.mem.indexOf(u8, remaining, "\r\n") orelse return false;
        const line = remaining[0..line_end];
        if (line.len == 0) return false;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
        const matches_name = syntax.eqlIgnoreCase(line[0..colon], name);
        const matches_value = syntax.eqlIgnoreCase(
            syntax.trimOws(line[colon + 1 ..]),
            value,
        );
        if (matches_name and matches_value) return true;
        remaining = remaining[line_end + 2 ..];
    }
    return false;
}

// Smith values: flags, trailer shape, Vary shape, exact length, output capacity.
const vary_append_regression = [_]u8{
    0x1a, 0, 0, 0, 0, 0, 0, 0,
    1,    0, 0, 0, 0, 0, 0, 0,
    1,    0, 0, 0, 0, 0, 0, 0,
    0xb4, 0, 0, 0, 0, 0, 0, 0,
    0x50, 1, 0, 0, 0, 0, 0, 0,
};

const fuzz_corpus = [_][]const u8{
    &vary_append_regression,
    &fuzz_support.smithInput(""),
    &fuzz_support.smithInput("exact-get"),
    &fuzz_support.smithInput("unknown-head-trailers"),
    &fuzz_support.smithInput("identity-forbidden"),
    &fuzz_support.smithInput("malformed-vary-and-declaration"),
};
