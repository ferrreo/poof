const std = @import("std");
const application = @import("../../application.zig");
const application_body = @import("../application/body.zig");
const multipart_boundary = @import("../multipart/boundary.zig");
const query = @import("../http1/query.zig");
const request_accept_encoding = @import("../http1/request_accept_encoding.zig");
const request_analysis = @import("../http1/request_analysis.zig");
const request_connection = @import("../http1/request_connection.zig");
const request_content = @import("../http1/request_content.zig");
const request_expect = @import("../http1/request_expect.zig");
const request_framing = @import("../http1/request_framing.zig");
const request_head = @import("../http1/request_head.zig");
const request_target = @import("../http1/request_target.zig");
const request_trailers = @import("../http1/request_trailers.zig");

pub fn Admission(comptime trailer_names_max: u16) type {
    return struct {
        input: application.Input,
        analysis: request_analysis.Analysis(trailer_names_max),
        expect_continue: bool,
        decoded_path_used: u32,
    };
}

pub fn AdmissionResult(comptime trailer_names_max: u16) type {
    return union(enum) {
        admitted: Admission(trailer_names_max),
        rejected: request_head.Rejection,
    };
}

pub const ContentAdmission = struct {
    plan: application.BodyPlan,
    content: ?request_content.Admission,
    multipart_boundary: MultipartBoundary,
};

pub const MultipartBoundary = struct {
    storage: [multipart_boundary.protocol_bytes_max]u8 = undefined,
    length: u8 = 0,

    pub fn bytes(boundary: *const MultipartBoundary) ?[]const u8 {
        const length: usize = boundary.length;
        if (length == 0 or length > boundary.storage.len) return null;
        return boundary.storage[0..length];
    }
};

pub const ContentResult = union(enum) {
    admitted: ContentAdmission,
    rejected: request_head.Rejection,
    invalid_plan,
};

/// Applies protocol and semantic policy without requiring an application request slot.
pub fn admit(
    comptime trailer_names_max: u16,
    decoder: anytype,
    head: request_head.Head,
    decoded_path: []u8,
    date: []const u8,
) AdmissionResult(trailer_names_max) {
    const fields = decoder.fields();
    const head_bytes = decoder.bytes();
    const connection = switch (request_connection.analyze(fields, head_bytes)) {
        .accepted => |accepted| accepted,
        .rejected => |rejected| return .{ .rejected = rejected },
    };
    const analysis = switch (request_analysis.analyze(
        query.segments_hard_max,
        trailer_names_max,
        head,
        fields,
        head_bytes,
        decoded_path,
    )) {
        .accepted => |accepted| accepted,
        .rejected => |rejected| {
            std.crypto.secureZero(u8, decoded_path);
            return .{ .rejected = rejected };
        },
    };
    const decoded_path_used = decodedPathUsed(analysis.target, decoded_path);
    const expect_continue = request_expect.analyze(fields, head_bytes) catch {
        clearDecodedPath(decoded_path, decoded_path_used);
        return reject(trailer_names_max, .expectation_failed);
    };
    const input = inputFromTarget(
        head.method.slice(head_bytes),
        analysis.target,
        date,
        connection.close,
        analysis.accept_encoding,
        analysis.accepts_response_trailers,
        .{ .bytes = head_bytes, .fields = fields },
    );
    return .{ .admitted = .{
        .input = input,
        .analysis = analysis,
        .expect_continue = expect_continue,
        .decoded_path_used = decoded_path_used,
    } };
}

/// Applies route-selected media, coding, and known-length limits.
pub fn admitContent(
    plan: application.BodyPlan,
    framing: request_framing.BodyFraming,
    fields: []const request_head.Field,
    bytes: []const u8,
) ContentResult {
    if (plan.kind == .none) return admittedContent(plan, null, .{});
    if (plan.kind == .input) return admitInputOnly(plan, framing);
    if (plan.decoders.len == 0 or plan.decoders.len > 4 or
        plan.accepted_media.len != plan.media_decoder_indices.len)
    {
        return .invalid_plan;
    }
    var modes: [4]request_content.Mode = undefined;
    for (plan.decoders, 0..) |decoder, index| {
        if (!validBoundaryConfiguration(decoder)) return .invalid_plan;
        modes[index] = decoderMode(decoder.kind);
    }
    const content = switch (request_content.analyzeMapped(
        .{
            .pattern_decoder_indices = plan.media_decoder_indices,
            .decoder_modes = modes[0..plan.decoders.len],
        },
        plan.accepted_media,
        fields,
        bytes,
    )) {
        .accepted => |accepted| accepted,
        .rejected => |rejected| return rejectContent(rejected.status, rejected.close),
    };
    const selected = plan.selectMedia(content.matched_pattern) orelse {
        return .invalid_plan;
    };
    const selected_index = selected.selected_decoder orelse return .invalid_plan;
    if (selected_index >= selected.decoders.len) return .invalid_plan;
    const selected_decoder = selected.decoders[selected_index];
    var owned_boundary = MultipartBoundary{};
    if (selected_decoder.kind == .multipart) {
        const boundary = multipart_boundary.parse(
            content.media.raw,
            selected_decoder.multipart_boundary_bytes_max,
            &owned_boundary.storage,
        ) catch |problem| return switch (problem) {
            error.Malformed => rejectContent(.bad_request, true),
            error.LimitExceeded => rejectContent(.payload_too_large, true),
        };
        owned_boundary.length = @intCast(boundary.len);
    }
    const fixed = switch (framing) {
        .fixed => |length| length,
        .none, .chunked => return admittedContent(selected, content, owned_boundary),
    };
    if (fixed > selected.encoded_wire_bytes_max) {
        return rejectContent(.payload_too_large, true);
    }
    if (content.coding == .identity and fixed > selected.decoded_bytes_max) {
        return rejectContent(.payload_too_large, true);
    }
    return admittedContent(selected, content, owned_boundary);
}

fn admitInputOnly(
    plan: application.BodyPlan,
    framing: request_framing.BodyFraming,
) ContentResult {
    return switch (framing) {
        .none => admittedContent(plan, null, .{}),
        .fixed => |length| if (length == 0)
            admittedContent(plan, null, .{})
        else
            rejectContent(.payload_too_large, true),
        .chunked => rejectContent(.payload_too_large, true),
    };
}

fn decoderMode(kind: body.DecoderKind) request_content.Mode {
    return switch (kind) {
        .bytes, .multipart => .bytes,
        .text, .json, .form => .text,
    };
}

fn validBoundaryConfiguration(decoder: application_body.Decoder) bool {
    return switch (decoder.kind) {
        .multipart => decoder.multipart_boundary_bytes_max > 0 and
            decoder.multipart_boundary_bytes_max <= multipart_boundary.protocol_bytes_max,
        .bytes, .text, .json, .form => decoder.multipart_boundary_bytes_max == 0,
    };
}

fn admittedContent(
    plan: application.BodyPlan,
    content: ?request_content.Admission,
    multipart_boundary_value: MultipartBoundary,
) ContentResult {
    return .{ .admitted = .{
        .plan = plan,
        .content = content,
        .multipart_boundary = multipart_boundary_value,
    } };
}

fn decodedPathUsed(target: request_target.Target, storage: []u8) u32 {
    return switch (target) {
        .origin => |origin| pathStorageUsed(origin.decoded_path, storage),
        .asterisk => 0,
        .absolute => |absolute| pathStorageUsed(absolute.decoded_path, storage),
    };
}

fn pathStorageUsed(path: []const u8, storage: []u8) u32 {
    if (@intFromPtr(path.ptr) != @intFromPtr(storage.ptr)) return 0;
    return @intCast(path.len);
}

fn clearDecodedPath(storage: []u8, used: u32) void {
    std.crypto.secureZero(u8, storage[0..used]);
}

fn inputFromTarget(
    method: []const u8,
    target: request_target.Target,
    date: []const u8,
    connection_close: bool,
    accept_encoding: request_accept_encoding.Preferences,
    accepts_response_trailers: bool,
    headers: application.RequestHeaders,
) application.Input {
    return switch (target) {
        .origin => |origin| .{
            .method = method,
            .path = origin.decoded_path,
            .raw_target = origin.raw_target,
            .raw_path = origin.raw_path,
            .raw_query = origin.raw_query,
            .date = date,
            .connection_close = connection_close,
            .accept_encoding = accept_encoding,
            .accepts_response_trailers = accepts_response_trailers,
            .headers = headers,
        },
        .asterisk => |raw| .{
            .method = method,
            .path = raw,
            .raw_target = raw,
            .raw_path = raw,
            .date = date,
            .connection_close = connection_close,
            .accept_encoding = accept_encoding,
            .accepts_response_trailers = accepts_response_trailers,
            .headers = headers,
        },
        .absolute => |absolute| .{
            .method = method,
            .path = absolute.decoded_path,
            .raw_target = absolute.raw_target,
            .raw_path = absolute.raw_path,
            .raw_query = absolute.raw_query,
            .date = date,
            .connection_close = connection_close,
            .accept_encoding = accept_encoding,
            .accepts_response_trailers = accepts_response_trailers,
            .headers = headers,
        },
    };
}

fn reject(
    comptime trailer_names_max: u16,
    status: request_head.Status,
) AdmissionResult(trailer_names_max) {
    return .{ .rejected = .{ .status = status } };
}

fn rejectContent(status: request_head.Status, close: bool) ContentResult {
    return .{ .rejected = .{ .status = status, .close = close } };
}

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const TestState = struct { calls: u16 = 0 };
const TestContext = application.Context(
    TestState,
    @import("../../response.zig").standard_head_limits,
);
const body = @import("../../body.zig");
const route = @import("../../route.zig");

fn ping(context: *TestContext) TestContext.ResponseType {
    context.state.calls += 1;
    return context.textStatic(.ok, "pong");
}

const TestApp = application.Application(.{
    .State = TestState,
    .routes = .{route.get("/ping", ping)},
});
const json_media = [_]body.MediaPattern{.{ .exact = "application/json" }};

fn upload(context: *TestContext, value: body.Bytes) TestContext.ResponseType {
    _ = value;
    return context.empty(.no_content);
}

const BodyApp = application.Application(.{
    .State = TestState,
    .routes = .{route.post(
        "/upload",
        body.bytes(.{
            .encoded_wire_bytes_max = 5,
            .decoded_bytes_max = 3,
            .accepted_media = &json_media,
        }, upload),
    )},
});
const Decoder = request_head.Decoder(@import("../http1/limits.zig").standard_request_head_limits);

test "adapter admits origin request and owns close policy" {
    const wire =
        "GET /p%69ng HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Connection: close\r\n" ++
        "TE: trailers\r\n" ++
        "Accept-Encoding: gzip;q=0.6, identity;q=0.2\r\n\r\n";
    var decoder = Decoder.init();
    const head = switch (decoder.feed(wire).state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    var state = TestState{};
    var workspace = TestApp.Workspace{};
    var route_workspace: TestApp.RouteSearchWorkspace = undefined;
    var path: [wire.len]u8 = undefined;
    var output: [512]u8 = undefined;
    const admission = switch (admit(
        request_trailers.standard_names_max,
        &decoder,
        head,
        &path,
        fixed_date,
    )) {
        .admitted => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    const prepared = try TestApp.prepare(
        &state,
        &workspace,
        &route_workspace,
        admission.input,
        &output,
    );
    try std.testing.expect(admission.input.connection_close);
    try std.testing.expectEqual(@as(u16, 600), admission.input.accept_encoding.gzip);
    try std.testing.expectEqual(@as(u16, 200), admission.input.accept_encoding.identity);
    try std.testing.expect(admission.input.accepts_response_trailers);
    try std.testing.expect(!admission.expect_continue);
    try std.testing.expect(admission.analysis.framing.body == .none);
    try std.testing.expectEqual(@as(u32, 5), admission.decoded_path_used);
    try std.testing.expectEqual(@as(u16, 1), state.calls);
    try std.testing.expect(std.mem.endsWith(u8, prepared.bytes, "\r\n\r\npong"));
    try std.testing.expect(
        std.mem.indexOf(u8, prepared.bytes, "connection: close\r\n") != null,
    );
    _ = try TestApp.complete(&workspace);
}

test "adapter admits framed requests and retains strict continue intent" {
    const wire =
        "POST /ping HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Content-Length: 3\r\n" ++
        "Expect: 100-continue\r\n\r\n";
    var decoder = Decoder.init();
    const head = switch (decoder.feed(wire).state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    var path: [wire.len]u8 = undefined;
    const admission = switch (admit(
        request_trailers.standard_names_max,
        &decoder,
        head,
        &path,
        fixed_date,
    )) {
        .admitted => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    const length = switch (admission.analysis.framing.body) {
        .fixed => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(admission.expect_continue);
    try std.testing.expectEqual(@as(u64, 3), length);
}

test "adapter rejects untrusted heads before application" {
    const Case = struct {
        wire: []const u8,
        status: request_head.Status,
    };
    const cases = [_]Case{
        .{
            .wire = "GET /ping HTTP/1.1\r\nHost: example.test\r\nExpect: x\r\n\r\n",
            .status = .expectation_failed,
        },
        .{
            .wire = "POST /ping HTTP/1.1\r\nHost: example.test\r\n" ++
                "Content-Length: 1\r\nTransfer-Encoding: chunked\r\n" ++
                "Expect: 100-continue\r\n\r\n",
            .status = .bad_request,
        },
        .{
            .wire = "GET /ping HTTP/1.1\r\nHost: example.test\r\n" ++
                "Content-Length: nope\r\nExpect: x\r\n\r\n",
            .status = .bad_request,
        },
        .{
            .wire = "GET /ping HTTP/1.1\r\nHost: example.test\r\nConnection: ,close\r\n\r\n",
            .status = .bad_request,
        },
        .{
            .wire = "GET /ping HTTP/1.1\r\nHost: example.test\r\n" ++
                "Accept-Encoding: gzip;q=1.001\r\n\r\n",
            .status = .bad_request,
        },
    };
    for (cases) |case| try expectRejectedBeforeApplication(case.wire, case.status);
}

test "adapter retains absolute form for forwarding admission" {
    const wire =
        "GET https://example.test/p%69ng?q HTTP/1.1\r\n" ++
        "Host: example.test\r\n\r\n";
    var decoder = Decoder.init();
    const head = switch (decoder.feed(wire).state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    var path: [wire.len]u8 = undefined;
    const admission = switch (admit(
        request_trailers.standard_names_max,
        &decoder,
        head,
        &path,
        fixed_date,
    )) {
        .admitted => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expect(admission.analysis.target == .absolute);
    try std.testing.expectEqualStrings("/ping", admission.input.path);
    try std.testing.expectEqualStrings("/p%69ng", admission.input.raw_path);
    try std.testing.expectEqualStrings("q", admission.input.raw_query.?);
    try std.testing.expectEqual(@as(u32, 5), admission.decoded_path_used);
}

test "adapter clears decoded path bytes when later semantics reject" {
    const cases = [_][]const u8{
        "GET /s%65cret HTTP/1.1\r\nHost: example.test\r\nContent-Length: nope\r\n\r\n",
    };
    for (cases) |wire| {
        var decoder = Decoder.init();
        const head = switch (decoder.feed(wire).state) {
            .ready => |ready| ready,
            else => return error.TestUnexpectedResult,
        };
        var path = [_]u8{0xa5} ** 512;
        const result = admit(
            request_trailers.standard_names_max,
            &decoder,
            head,
            &path,
            fixed_date,
        );
        try std.testing.expect(result == .rejected);
        try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 7), path[0..7]);
    }
}

test "content admission skips bodyless routes" {
    var decoder = Decoder.init();
    const framing = try decodeFraming(
        &decoder,
        "GET /ping HTTP/1.1\r\nHost: example.test\r\n" ++
            "Content-Length: 99\r\nContent-Type: malformed\r\n\r\n",
    );
    var route_workspace: TestApp.RouteSearchWorkspace = undefined;
    const plan = TestApp.plan(testInput("GET", "/ping"), &route_workspace).body;
    const result = admitContent(plan, framing, decoder.fields(), decoder.bytes());
    const admitted = switch (result) {
        .admitted => |value| value,
        .rejected => return error.TestUnexpectedResult,
        .invalid_plan => return error.TestUnexpectedResult,
    };
    try std.testing.expect(admitted.content == null);
    try std.testing.expect(admitted.plan.kind == .none);
}

test "content admission applies identity and gzip fixed limits" {
    const Case = struct {
        length: u8,
        coding: request_content.Coding,
        rejected: bool,
    };
    const cases = [_]Case{
        .{ .length = 3, .coding = .identity, .rejected = false },
        .{ .length = 4, .coding = .identity, .rejected = true },
        .{ .length = 4, .coding = .gzip, .rejected = false },
        .{ .length = 6, .coding = .gzip, .rejected = true },
    };
    var route_workspace: BodyApp.RouteSearchWorkspace = undefined;
    const plan = BodyApp.plan(testInput("POST", "/upload"), &route_workspace).body;
    for (cases) |case| try expectContentLimit(plan, case.length, case.coding, case.rejected);
}

test "content admission maps syntax and media before size" {
    var route_workspace: BodyApp.RouteSearchWorkspace = undefined;
    const plan = BodyApp.plan(testInput("POST", "/upload"), &route_workspace).body;
    const cases = [_]struct {
        field: []const u8,
        status: request_head.Status,
    }{
        .{ .field = "Content-Type: malformed\r\n", .status = .bad_request },
        .{ .field = "Content-Type: text/plain\r\n", .status = .unsupported_media_type },
        .{ .field = "", .status = .unsupported_media_type },
    };
    for (cases) |case| {
        var decoder = Decoder.init();
        const prefix = "POST /upload HTTP/1.1\r\nHost: example.test\r\nContent-Length: 99\r\n";
        var wire: [256]u8 = undefined;
        const request = try std.fmt.bufPrint(&wire, "{s}{s}\r\n", .{ prefix, case.field });
        const framing = try decodeFraming(&decoder, request);
        const rejection = switch (admitContent(
            plan,
            framing,
            decoder.fields(),
            decoder.bytes(),
        )) {
            .admitted => return error.TestUnexpectedResult,
            .rejected => |value| value,
            .invalid_plan => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(case.status, rejection.status);
    }
}

fn testInput(method: []const u8, path: []const u8) application.Input {
    return .{
        .method = method,
        .path = path,
        .raw_target = path,
        .raw_path = path,
        .date = fixed_date,
    };
}

fn decodeFraming(decoder: *Decoder, wire: []const u8) !request_framing.BodyFraming {
    decoder.* = Decoder.init();
    _ = switch (decoder.feed(wire).state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    return switch (request_framing.analyze(decoder.fields(), decoder.bytes())) {
        .accepted => |value| value.body,
        .rejected => error.TestUnexpectedResult,
    };
}

fn expectContentLimit(
    plan: application.BodyPlan,
    length: u8,
    coding: request_content.Coding,
    rejected: bool,
) !void {
    var wire: [256]u8 = undefined;
    const encoding = if (coding == .gzip) "Content-Encoding: gzip\r\n" else "";
    const request = try std.fmt.bufPrint(
        &wire,
        "POST /upload HTTP/1.1\r\nHost: example.test\r\n" ++
            "Content-Length: {d}\r\nContent-Type: application/json\r\n{s}\r\n",
        .{ length, encoding },
    );
    var decoder = Decoder.init();
    const framing = try decodeFraming(&decoder, request);
    const result = admitContent(plan, framing, decoder.fields(), decoder.bytes());
    if (rejected) {
        const rejection = switch (result) {
            .admitted => return error.TestUnexpectedResult,
            .rejected => |value| value,
            .invalid_plan => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(request_head.Status.payload_too_large, rejection.status);
        return;
    }
    const admitted = switch (result) {
        .admitted => |value| value.content orelse return error.TestUnexpectedResult,
        .rejected => return error.TestUnexpectedResult,
        .invalid_plan => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(coding, admitted.coding);
}

fn expectRejectedBeforeApplication(wire: []const u8, status: request_head.Status) !void {
    var decoder = Decoder.init();
    const head = switch (decoder.feed(wire).state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    var path: [512]u8 = undefined;
    const rejection = switch (admit(
        request_trailers.standard_names_max,
        &decoder,
        head,
        &path,
        fixed_date,
    )) {
        .admitted => return error.TestUnexpectedResult,
        .rejected => |rejected| rejected,
    };
    try std.testing.expectEqual(status, rejection.status);
}
