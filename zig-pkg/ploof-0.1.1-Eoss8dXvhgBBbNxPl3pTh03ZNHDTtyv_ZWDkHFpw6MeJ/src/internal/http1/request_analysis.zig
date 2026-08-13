const std = @import("std");
const query_parser = @import("query.zig");
const request_accept_encoding = @import("request_accept_encoding.zig");
const request_framing = @import("request_framing.zig");
const request_head = @import("request_head.zig");
const request_target = @import("request_target.zig");
const request_te = @import("request_te.zig");
const request_trailers = @import("request_trailers.zig");

pub fn Analysis(comptime trailer_names_max: u16) type {
    return struct {
        target: request_target.Target,
        query: ?query_parser.Query,
        framing: request_framing.Analysis,
        accept_encoding: request_accept_encoding.Preferences,
        accepts_response_trailers: bool,
        trailer_declarations: request_trailers.Declarations(trailer_names_max),
    };
}

pub fn Result(comptime trailer_names_max: u16) type {
    return union(enum) {
        accepted: Analysis(trailer_names_max),
        rejected: request_head.Rejection,
    };
}

pub fn analyze(
    comptime query_segments_max: usize,
    comptime trailer_names_max: u16,
    head: request_head.Head,
    fields: []const request_head.Field,
    head_bytes: []const u8,
    decoded_path_output: []u8,
) Result(trailer_names_max) {
    std.debug.assert(head.fields_count == fields.len);
    std.debug.assert(head.bytes_count == head_bytes.len);

    const target = switch (request_target.parse(
        head.method.slice(head_bytes),
        head.target.slice(head_bytes),
        decoded_path_output,
    )) {
        .ready => |ready| ready,
        .rejected => |rejection| return reject(trailer_names_max, rejection),
    };
    const parsed_query = if (rawQuery(target)) |raw|
        switch (query_parser.parse(query_segments_max, raw)) {
            .ready => |ready| ready,
            .rejected => |rejection| return reject(trailer_names_max, rejection),
        }
    else
        null;
    const framing = switch (request_framing.analyze(fields, head_bytes)) {
        .accepted => |accepted| accepted,
        .rejected => |rejection| return reject(trailer_names_max, rejection),
    };
    const te = switch (request_te.analyze(fields, head_bytes)) {
        .accepted => |accepted| accepted,
        .rejected => |rejection| return reject(trailer_names_max, rejection),
    };
    const accept_encoding = switch (request_accept_encoding.analyze(fields, head_bytes)) {
        .accepted => |accepted| accepted,
        .rejected => |rejection| return reject(trailer_names_max, rejection),
    };
    const DeclarationSet = request_trailers.Declarations(trailer_names_max);
    const declarations = DeclarationSet.parse(fields, head_bytes) catch {
        return .{ .rejected = .{ .status = .bad_request } };
    };
    return .{ .accepted = .{
        .target = target,
        .query = parsed_query,
        .framing = framing,
        .accept_encoding = accept_encoding,
        .accepts_response_trailers = te.accepts_trailers,
        .trailer_declarations = declarations,
    } };
}

fn rawQuery(target: request_target.Target) ?[]const u8 {
    return switch (target) {
        .origin => |origin| origin.raw_query,
        .absolute => |absolute| absolute.raw_query,
        .asterisk => null,
    };
}

fn reject(comptime names_max: u16, rejection: anytype) Result(names_max) {
    return .{ .rejected = .{
        .status = rejection.status,
        .close = rejection.close,
    } };
}

const semantic_request =
    "POST /items?a=%41+b&a=c HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "TE: gzip, trailers\r\n" ++
    "Accept-Encoding: gzip;q=0.7, identity;q=0.2\r\n" ++
    "Trailer: Content-Digest\r\n" ++
    "\r\n";

test "composes every request-head semantic before dispatch" {
    const Decoder = request_head.Decoder(@import("limits.zig").standard_request_head_limits);
    var decoder = Decoder.init();
    const decoded = decoder.feed(semantic_request);
    const head = switch (decoded.state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    var path_output: [semantic_request.len]u8 = undefined;
    const result = analyze(16, 4, head, decoder.fields(), decoder.bytes(), &path_output);
    const analysis = switch (result) {
        .accepted => |accepted| accepted,
        .rejected => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqualStrings("/items", analysis.target.origin.decoded_path);
    try std.testing.expect(analysis.framing.body == .chunked);
    try std.testing.expectEqual(@as(u16, 700), analysis.accept_encoding.gzip);
    try std.testing.expectEqual(@as(u16, 200), analysis.accept_encoding.identity);
    try std.testing.expect(analysis.accepts_response_trailers);
    try std.testing.expect(analysis.trailer_declarations.contains(
        decoder.bytes(),
        "content-digest",
    ));
    var pairs = analysis.query.?.iterator();
    try std.testing.expect(pairs.next().?.value.eqlDecoded("A b"));
    try std.testing.expect(pairs.next().?.value.eqlDecoded("c"));
    try std.testing.expect(pairs.next() == null);
}

test "rejects failure in every request-head semantic layer" {
    const Case = struct {
        request: []const u8,
        status: request_head.Status,
    };
    const prefix = "GET / HTTP/1.1\r\nHost: example.test\r\n";
    const cases = [_]Case{
        .{ .request = "GET /% HTTP/1.1\r\nHost: example.test\r\n\r\n", .status = .bad_request },
        .{
            .request = "GET /?x=a;b HTTP/1.1\r\nHost: example.test\r\n\r\n",
            .status = .bad_request,
        },
        .{
            .request = "GET /?a=1&b=2 HTTP/1.1\r\nHost: example.test\r\n\r\n",
            .status = .bad_request,
        },
        .{ .request = prefix ++ "TE: trailers;q=1\r\n\r\n", .status = .bad_request },
        .{
            .request = prefix ++ "Accept-Encoding: gzip;q=1.001\r\n\r\n",
            .status = .bad_request,
        },
        .{
            .request = prefix ++
                "Transfer-Encoding: chunked\r\nTrailer: Host\r\n\r\n",
            .status = .bad_request,
        },
        .{
            .request = prefix ++ "Transfer-Encoding: gzip\r\n\r\n",
            .status = .not_implemented,
        },
    };
    for (cases) |case| try expectRejected(case.request, case.status);
}

fn expectRejected(input: []const u8, status: request_head.Status) !void {
    const Decoder = request_head.Decoder(@import("limits.zig").standard_request_head_limits);
    var decoder = Decoder.init();
    const decoded = decoder.feed(input);
    const head = switch (decoded.state) {
        .ready => |ready| ready,
        .rejected => |rejection| {
            try std.testing.expectEqual(status, rejection.status);
            try std.testing.expect(rejection.close);
            return;
        },
        .need_more => return error.TestUnexpectedResult,
    };
    var path_output: [512]u8 = undefined;
    const rejection = switch (analyze(
        1,
        4,
        head,
        decoder.fields(),
        decoder.bytes(),
        &path_output,
    )) {
        .accepted => return error.TestUnexpectedResult,
        .rejected => |rejected| rejected,
    };
    try std.testing.expectEqual(status, rejection.status);
    try std.testing.expect(rejection.close);
}
