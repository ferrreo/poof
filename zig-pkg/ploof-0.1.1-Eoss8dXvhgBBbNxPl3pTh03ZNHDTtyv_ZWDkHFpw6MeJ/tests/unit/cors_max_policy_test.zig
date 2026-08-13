const std = @import("std");
const application = @import("../../src/application.zig");
const cors = @import("../../src/cors.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const limits = @import("../../src/internal/http1/limits.zig");
const request_accept_encoding = @import("../../src/internal/http1/request_accept_encoding.zig");
const request_cors = @import("../../src/internal/http1/request_cors.zig");
const request_head = @import("../../src/internal/http1/request_head.zig");

const fixed_date = "Wed, 15 Jul 2026 12:00:00 GMT";
const Decoder = request_head.Decoder(limits.standard_request_head_limits);

const origins = [_][]const u8{
    "https://o00.example", "https://o01.example", "https://o02.example", "https://o03.example",
    "https://o04.example", "https://o05.example", "https://o06.example", "https://o07.example",
    "https://o08.example", "https://o09.example", "https://o10.example", "https://o11.example",
    "https://o12.example", "https://o13.example", "https://o14.example", "https://o15.example",
    "https://o16.example", "https://o17.example", "https://o18.example", "https://o19.example",
    "https://o20.example", "https://o21.example", "https://o22.example", "https://o23.example",
    "https://o24.example", "https://o25.example", "https://o26.example", "https://o27.example",
    "https://o28.example", "https://o29.example", "https://o30.example", "https://o31.example",
    "https://o32.example", "https://o33.example", "https://o34.example", "https://o35.example",
    "https://o36.example", "https://o37.example", "https://o38.example", "https://o39.example",
    "https://o40.example", "https://o41.example", "https://o42.example", "https://o43.example",
    "https://o44.example", "https://o45.example", "https://o46.example", "https://o47.example",
    "https://o48.example", "https://o49.example", "https://o50.example", "https://o51.example",
    "https://o52.example", "https://o53.example", "https://o54.example", "https://o55.example",
    "https://o56.example", "https://o57.example", "https://o58.example", "https://o59.example",
    "https://o60.example", "https://o61.example", "https://o62.example", "https://o63.example",
};

const headers = [_][]const u8{
    "X-H00", "X-H01", "X-H02", "X-H03", "X-H04", "X-H05", "X-H06", "X-H07",
    "X-H08", "X-H09", "X-H10", "X-H11", "X-H12", "X-H13", "X-H14", "X-H15",
    "X-H16", "X-H17", "X-H18", "X-H19", "X-H20", "X-H21", "X-H22", "X-H23",
    "X-H24", "X-H25", "X-H26", "X-H27", "X-H28", "X-H29", "X-H30", "X-H31",
    "X-H32", "X-H33", "X-H34", "X-H35", "X-H36", "X-H37", "X-H38", "X-H39",
    "X-H40", "X-H41", "X-H42", "X-H43", "X-H44", "X-H45", "X-H46", "X-H47",
    "X-H48", "X-H49", "X-H50", "X-H51", "X-H52", "X-H53", "X-H54", "X-H55",
    "X-H56", "X-H57", "X-H58", "X-H59", "X-H60", "X-H61", "X-H62", "X-H63",
};

const Context = application.Context(void, response.standard_head_limits);
const Response = Context.ResponseType;

fn handler(context: *Context) Response {
    return context.empty(.ok);
}

// No caller branch-quota override: hard-max public policy and Application must compile directly.
const maximum_policy = cors.exact(&origins, .{
    .request_headers = .{ .exact = &headers },
});
const MaximumApp = application.Application(.{
    .State = void,
    .cors = maximum_policy,
    .routes = .{route.get("/maximum", handler)},
});

test "hard-max exact policy and Application compile under the caller default quota" {
    try std.testing.expectEqual(@as(usize, cors.exact_origins_hard_max), origins.len);
    try std.testing.expectEqual(@as(usize, cors.exact_request_headers_hard_max), headers.len);
    try std.testing.expectEqual(origins.len, maximum_policy.allow_exact.parsed_origins.len);
    try std.testing.expect(request_cors.originEquivalentOrigins(
        request_cors.parseOrigin(origins[origins.len - 1]).?,
        maximum_policy.allow_exact.parsed_origins[origins.len - 1],
    ));
    try std.testing.expect(MaximumApp.cors_policy_enabled);
}

test "hard-max policy serves last origin actual and all-header preflight" {
    var workspace = MaximumApp.Workspace{};
    var request: [4096]u8 = undefined;
    var output: [4096]u8 = undefined;
    const last_origin = origins[origins.len - 1];
    const actual_wire = try std.fmt.bufPrint(
        &request,
        "GET /maximum HTTP/1.1\r\nHost: example.test\r\nOrigin: {s}\r\n\r\n",
        .{last_origin},
    );
    const actual = try serve(actual_wire, &workspace, &output);
    try std.testing.expectEqual(response.Status.ok, actual.status);
    try expectFieldValue(actual.bytes, "access-control-allow-origin", last_origin);
    try expectField(actual.bytes, "vary: Origin\r\n");

    const preflight_request = buildPreflight(&request, last_origin);
    const preflight = try serve(preflight_request.wire, &workspace, &output);
    try std.testing.expectEqual(response.Status.no_content, preflight.status);
    try expectFieldValue(preflight.bytes, "access-control-allow-origin", last_origin);
    try expectField(preflight.bytes, "access-control-allow-methods: GET\r\n");
    try expectFieldValue(
        preflight.bytes,
        "access-control-allow-headers",
        preflight_request.request_headers,
    );
    try expectField(
        preflight.bytes,
        "vary: Origin, Access-Control-Request-Method, Access-Control-Request-Headers\r\n",
    );
}

const PreflightRequest = struct { wire: []const u8, request_headers: []const u8 };

fn buildPreflight(storage: []u8, origin: []const u8) PreflightRequest {
    var used: usize = 0;
    append(storage, &used, "OPTIONS /maximum HTTP/1.1\r\nHost: example.test\r\nOrigin: ");
    append(storage, &used, origin);
    append(storage, &used, "\r\nAccess-Control-Request-Method: GET\r\n");
    append(storage, &used, "Access-Control-Request-Headers: ");
    const headers_start = used;
    for (headers, 0..) |name, index| {
        if (index != 0) append(storage, &used, ", ");
        append(storage, &used, name);
    }
    const headers_end = used;
    append(storage, &used, "\r\n\r\n");
    return .{ .wire = storage[0..used], .request_headers = storage[headers_start..headers_end] };
}

fn append(output: []u8, used: *usize, bytes: []const u8) void {
    std.debug.assert(bytes.len <= output.len - used.*);
    @memcpy(output[used.*..][0..bytes.len], bytes);
    used.* += bytes.len;
}

fn serve(
    wire: []const u8,
    workspace: *MaximumApp.Workspace,
    output: []u8,
) !application.ServeResult {
    var decoder = Decoder.init();
    const head = switch (decoder.feed(wire).state) {
        .ready => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const bytes = decoder.bytes();
    const target = head.target.slice(bytes);
    const accept_encoding = switch (request_accept_encoding.analyze(decoder.fields(), bytes)) {
        .accepted => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    const input = application.Input{
        .method = head.method.slice(bytes),
        .path = target,
        .raw_target = target,
        .raw_path = target,
        .date = fixed_date,
        .accept_encoding = accept_encoding,
        .headers = .{ .bytes = bytes, .fields = decoder.fields() },
    };
    var state: void = {};
    var route_workspace: MaximumApp.RouteSearchWorkspace = undefined;
    var request_plan = MaximumApp.plan(input, &route_workspace);
    var gzip_workspace: MaximumApp.ResponseGzipWorkspace = undefined;
    const head_result = try MaximumApp.__prepareHeadPlannedWithResponseGzip(
        &state,
        workspace,
        &.{},
        output,
        &request_plan,
        .{},
        &gzip_workspace,
    );
    const prepared = switch (head_result) {
        .prepared => |value| value,
        .receive_body => return error.TestUnexpectedResult,
    };
    const outcome = try MaximumApp.complete(workspace);
    return .{
        .bytes = prepared.bytes,
        .status = prepared.status,
        .transport = outcome.transport,
    };
}

fn expectFieldValue(wire: []const u8, name: []const u8, value: []const u8) !void {
    const start = std.mem.indexOf(u8, wire, name) orelse return error.TestUnexpectedResult;
    const value_start = start + name.len + ": ".len;
    if (value.len + "\r\n".len > wire.len - value_start) return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(value, wire[value_start .. value_start + value.len]);
    try std.testing.expectEqualStrings("\r\n", wire[value_start + value.len ..][0..2]);
}

fn expectField(wire: []const u8, field: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, wire, field) != null);
}
