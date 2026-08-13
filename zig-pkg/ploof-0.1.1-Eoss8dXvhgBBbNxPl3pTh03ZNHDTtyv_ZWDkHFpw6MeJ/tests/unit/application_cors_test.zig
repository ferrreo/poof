const std = @import("std");
const application = @import("../../src/application.zig");
const application_context = @import("../../src/application/context.zig");
const cors = @import("../../src/cors.zig");
const html_response = @import("../../src/html/response.zig");
const html_source = @import("../../src/html/source.zig");
const html_template = @import("../../src/html/template.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const request_accept_encoding = @import("../../src/internal/http1/request_accept_encoding.zig");
const request_head = @import("../../src/internal/http1/request_head.zig");
const response_cors_fields = @import("../../src/internal/http1/response_cors_fields.zig");
const limits = @import("../../src/internal/http1/limits.zig");

const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
const State = struct { middleware_calls: u16 = 0, handler_calls: u16 = 0 };
const Context = application.Context(State, response.standard_head_limits);
const Response = Context.ResponseType;
const Decoder = request_head.Decoder(limits.standard_request_head_limits);

const Count = struct {
    pub const State = void;

    pub fn head(_: Count, context: *Context, _: *void) ?Response {
        context.state.middleware_calls += 1;
        return null;
    }
};

fn handler(context: *Context) Response {
    context.state.handler_calls += 1;
    return context.textStatic(.ok, "ok");
}

fn noContentHandler(context: *Context) Response {
    context.state.handler_calls += 1;
    var result = context.empty(.no_content);
    result.setHeader("X-Handler", "preserved") catch unreachable;
    return result;
}

const exact_policy = cors.exact(&.{"https://app.example"}, .{
    .credentials = true,
});

const App = application.Application(.{
    .State = State,
    .cors = cors.allow_any,
    .middleware = .{Count{}},
    .routes = .{
        route.get("/public", handler),
        route.post("/exact", handler).withCors(exact_policy),
        route.get("/null", handler).withCors(cors.any(.{ .allow_null = true })),
    },
});

const GzipApp = application.Application(.{
    .State = State,
    .cors = cors.allow_any,
    .response_gzip = application.ResponseGzip{ .minimum_bytes = 0 },
    .routes = .{route.get("/public", handler)},
});

const limited_response = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 96,
    .fields_max = 16,
});

const CapacityApp = application.Application(.{
    .State = State,
    .cors = cors.allow_any_credentialed,
    .routes = .{
        route.get("/standard", handler),
        route.configured(.get, "/limited", handler, .{}, limited_response),
    },
});

const wider_response = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 16,
});

const RedirectCapacityApp = application.Application(.{
    .State = State,
    .cors = cors.allow_any_credentialed,
    .response_head_limits = limited_response,
    .routes = .{
        route.configured(.get, "/wide/", handler, .{}, wider_response),
    },
});

const disabled_route_response = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 64,
    .fields_max = 16,
});

const DisabledRouteCorsApp = application.Application(.{
    .State = State,
    .cors = cors.allow_any,
    .routes = .{
        route.configured(
            .get,
            "/disabled",
            handler,
            .{},
            disabled_route_response,
        ).withCors(cors.disabled),
    },
});

const cors_byte_capacity = response.HeadLimits.validate(.{
    .head_bytes_max = 170,
    .field_line_bytes_max = 77,
    .fields_max = 16,
});

const CorsByteCapacityApp = application.Application(.{
    .State = State,
    .cors = cors.allow_any_credentialed,
    .response_head_limits = cors_byte_capacity,
    .routes = .{
        route.get("/actual", handler),
        route.get("/empty-204", noContentHandler),
    },
});

const cors_count_capacity = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 96,
    .fields_max = 4,
});

const CorsCountCapacityApp = application.Application(.{
    .State = State,
    .cors = cors.allow_any_credentialed,
    .response_head_limits = cors_count_capacity,
    .routes = .{
        route.get("/actual", handler),
        route.get("/empty-204", noContentHandler),
    },
});

const allow_origin_wire_overhead = "access-control-allow-origin: \r\n".len;
const standard_reflected_origin_max: usize =
    limits.standard_response_head_limits.field_line_bytes_max - allow_origin_wire_overhead;
const limited_reflected_origin_max: usize =
    limited_response.field_line_bytes_max - allow_origin_wire_overhead;
const allow_headers_wire_overhead = "access-control-allow-headers: \r\n".len;
const limited_reflected_headers_max: usize =
    limited_response.field_line_bytes_max - allow_headers_wire_overhead;

const DisabledApp = application.Application(.{
    .State = State,
    .routes = .{route.get("/public", handler)},
});
const EnabledSizeApp = application.Application(.{
    .State = State,
    .cors = cors.allow_any,
    .routes = .{route.get("/public", handler)},
});
const DisabledCorsStorage = @FieldType(DisabledApp.Workspace, "cors_fields");
const EnabledCorsStorage = @FieldType(App.Workspace, "cors_fields");

const HtmlPage = html_template.Template(.{
    .View = struct {},
    .encoded_bytes_max = 32,
    .source = html_source.SourceSpec{
        .kind = .fragment,
        .graph_name = "cors-preflight-html",
        .file_path = "views/cors-preflight.html",
        .bytes = "<p>must not render</p>",
    },
});

fn htmlHandler(context: *Context) html_response.TemplateResponse(HtmlPage) {
    context.state.handler_calls += 1;
    return context.html(.ok, HtmlPage, .{});
}

const HtmlApp = application.Application(.{
    .State = State,
    .cors = cors.exact(&.{"https://allowed.example"}, .{}),
    .routes = .{route.get("/html", htmlHandler)},
});

comptime {
    if (@sizeOf(response_cors_fields.Fields) != 64) @compileError("CORS Fields size drift");
    if (@sizeOf(application.Input) != 304) @compileError("Application Input size drift");
    if (@sizeOf(DisabledApp.Plan) != 440) @compileError("disabled CORS Plan size drift");
    if (@sizeOf(EnabledSizeApp.Plan) != 440) @compileError("enabled CORS Plan size drift");
    // Context carries one nullable CSRF request-state pointer in every workspace.
    if (@sizeOf(DisabledApp.Workspace) != 58_832) {
        @compileError("disabled CORS Workspace size drift");
    }
    if (@sizeOf(EnabledSizeApp.Workspace) != 58_896) {
        @compileError("enabled CORS Workspace size drift");
    }
    if (@hasField(application.Input, "__cors_fields")) @compileError("CORS fields tax Input");
    if (@sizeOf(DisabledCorsStorage) != 0) @compileError("disabled CORS storage is not empty");
    if (@sizeOf(EnabledCorsStorage) != @sizeOf(response_cors_fields.Fields)) {
        @compileError("enabled CORS storage shape changed");
    }
}

test "disabled applications pay no response CORS field storage" {
    const workspace = DisabledApp.Workspace{};
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(DisabledCorsStorage));
    try std.testing.expect(@sizeOf(EnabledCorsStorage) > 0);
    try std.testing.expectEqual(
        @as(u8, 0),
        application_context.storedCorsFields(workspace.cors_fields).count,
    );
}

test "CORS capacity fallback is bounded full then Vary-only then empty" {
    try std.testing.expectEqual(@as(usize, 3), response_cors_fields.capacity_attempts_max);
    const full = response_cors_fields.actual(
        cors.allow_any_credentialed,
        .{ .value = "https://app.example" },
    );
    try std.testing.expectEqual(@as(u8, 3), full.count);
    const vary_only = full.capacityFallback().?;
    try std.testing.expectEqual(@as(u8, 1), vary_only.count);
    try std.testing.expectEqualStrings("vary", vary_only.at(0).name);
    const empty = vary_only.capacityFallback().?;
    try std.testing.expectEqual(@as(u8, 0), empty.count);
    try std.testing.expect(empty.managed);
    try std.testing.expectEqual(
        @as(?response_cors_fields.Fields, null),
        empty.capacityFallback(),
    );
}

fn serve(
    comptime TargetApp: type,
    wire: []const u8,
    state: *State,
    workspace: *TargetApp.Workspace,
    output: []u8,
) !application.ServeResult {
    var decoder = Decoder.init();
    const head = switch (decoder.feed(wire).state) {
        .ready => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const bytes = decoder.bytes();
    const target = head.target.slice(bytes);
    const accept_encoding = switch (request_accept_encoding.analyze(
        decoder.fields(),
        bytes,
    )) {
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
    var route_workspace: TargetApp.RouteSearchWorkspace = undefined;
    var request_plan = TargetApp.plan(input, &route_workspace);
    var gzip_workspace: TargetApp.ResponseGzipWorkspace = undefined;
    const head_result = try TargetApp.__prepareHeadPlannedWithResponseGzip(
        state,
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
    const outcome = try TargetApp.complete(workspace);
    return .{
        .bytes = prepared.bytes,
        .status = prepared.status,
        .transport = outcome.transport,
    };
}

test "actual CORS wildcard and exact credentialed decisions overlay responses" {
    var state = State{};
    var workspace = App.Workspace{};
    var output: [2048]u8 = undefined;
    const wildcard = try serve(
        App,
        "GET /public HTTP/1.1\r\n" ++
            "Host: example.test\r\n" ++
            "Origin: https://other.example\r\n\r\n",
        &state,
        &workspace,
        &output,
    );
    try expectField(wildcard.bytes, "access-control-allow-origin: *\r\n");
    try expectField(wildcard.bytes, "vary: Origin\r\n");

    const exact = try serve(
        App,
        "POST /exact HTTP/1.1\r\n" ++
            "Host: example.test\r\n" ++
            "Origin: HTTPS://APP.EXAMPLE:443\r\n\r\n",
        &state,
        &workspace,
        &output,
    );
    try expectField(
        exact.bytes,
        "access-control-allow-origin: HTTPS://APP.EXAMPLE:443\r\n",
    );
    try expectField(exact.bytes, "access-control-allow-credentials: true\r\n");
    try std.testing.expectEqual(@as(u16, 2), state.handler_calls);
    try std.testing.expectEqual(@as(u16, 2), state.middleware_calls);
}

test "denied actual CORS still executes while null needs explicit opt in" {
    var state = State{};
    var workspace = App.Workspace{};
    var output: [2048]u8 = undefined;
    const denied = try serve(
        App,
        "POST /exact HTTP/1.1\r\n" ++
            "Host: example.test\r\n" ++
            "Origin: https://denied.example\r\n\r\n",
        &state,
        &workspace,
        &output,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        denied.bytes,
        "access-control-allow-origin",
    ) == null);
    try expectField(denied.bytes, "vary: Origin\r\n");

    const allowed_null = try serve(
        App,
        "GET /null HTTP/1.1\r\n" ++
            "Host: example.test\r\n" ++
            "Origin: null\r\n\r\n",
        &state,
        &workspace,
        &output,
    );
    try expectField(allowed_null.bytes, "access-control-allow-origin: *\r\n");
    try std.testing.expectEqual(@as(u16, 2), state.handler_calls);
}

test "route-derived preflight bypasses middleware and handler" {
    var state = State{};
    var workspace = App.Workspace{};
    var output: [2048]u8 = undefined;
    const allowed = try serve(
        App,
        "OPTIONS /exact HTTP/1.1\r\n" ++
            "Host: example.test\r\n" ++
            "Origin: https://app.example\r\n" ++
            "Access-Control-Request-Method: POST\r\n\r\n",
        &state,
        &workspace,
        &output,
    );
    try std.testing.expectEqual(response.Status.no_content, allowed.status);
    try expectField(allowed.bytes, "access-control-allow-methods: POST\r\n");
    try expectField(allowed.bytes, "access-control-max-age: 600\r\n");
    try expectField(
        allowed.bytes,
        "vary: Origin, Access-Control-Request-Method, Access-Control-Request-Headers\r\n",
    );

    const denied = try serve(
        App,
        "OPTIONS /missing HTTP/1.1\r\n" ++
            "Host: example.test\r\n" ++
            "Origin: https://app.example\r\n" ++
            "Access-Control-Request-Method: POST\r\n\r\n",
        &state,
        &workspace,
        &output,
    );
    try std.testing.expectEqual(response.Status.forbidden, denied.status);
    try std.testing.expectEqual(@as(u16, 0), state.middleware_calls);
    try std.testing.expectEqual(@as(u16, 0), state.handler_calls);
}

test "HTML route preflight needs no render chunk workspace" {
    var state = State{};
    var workspace = HtmlApp.Workspace{};
    var output: [2048]u8 = undefined;
    inline for (.{
        .{ "https://allowed.example", response.Status.no_content },
        .{ "https://denied.example", response.Status.forbidden },
    }) |case| {
        var wire_storage: [256]u8 = undefined;
        const request = try std.fmt.bufPrint(
            &wire_storage,
            "OPTIONS /html HTTP/1.1\r\nHost: example.test\r\nOrigin: {s}\r\n" ++
                "Access-Control-Request-Method: GET\r\n\r\n",
            .{case[0]},
        );
        const result = try serve(HtmlApp, request, &state, &workspace, &output);
        try std.testing.expectEqual(case[1], result.status);
    }
    try std.testing.expectEqual(@as(u16, 0), state.handler_calls);
}

test "CORS overlay survives finite response gzip coding" {
    var state = State{};
    var workspace = GzipApp.Workspace{};
    var output: [20 * 1024]u8 = undefined;
    const result = try serve(
        GzipApp,
        "GET /public HTTP/1.1\r\nHost: example.test\r\n" ++
            "Origin: https://app.example\r\nAccept-Encoding: gzip, identity;q=0\r\n\r\n",
        &state,
        &workspace,
        &output,
    );
    try expectField(result.bytes, "content-encoding: gzip\r\n");
    try expectField(result.bytes, "access-control-allow-origin: *\r\n");
    try expectField(result.bytes, "vary: Origin\r\n");
    try expectField(result.bytes, "vary: Accept-Encoding\r\n");
}

test "standard reflected Origin serializes at exact line limit and denies max plus one" {
    const at_limit = makeOrigin(standard_reflected_origin_max);
    const over_limit = makeOrigin(standard_reflected_origin_max + 1);
    var state = State{};
    var workspace = CapacityApp.Workspace{};
    var request: [standard_reflected_origin_max + 128]u8 = undefined;
    var output: [20 * 1024]u8 = undefined;

    const allowed_wire = try std.fmt.bufPrint(
        &request,
        "GET /standard HTTP/1.1\r\nHost: example.test\r\nOrigin: {s}\r\n\r\n",
        .{&at_limit},
    );
    const allowed = try serve(CapacityApp, allowed_wire, &state, &workspace, &output);
    try std.testing.expectEqual(response.Status.ok, allowed.status);
    try expectFieldValue(allowed.bytes, "access-control-allow-origin", &at_limit);

    const denied_wire = try std.fmt.bufPrint(
        &request,
        "GET /standard HTTP/1.1\r\nHost: example.test\r\nOrigin: {s}\r\n\r\n",
        .{&over_limit},
    );
    const denied = try serve(CapacityApp, denied_wire, &state, &workspace, &output);
    try std.testing.expectEqual(response.Status.ok, denied.status);
    try std.testing.expect(std.mem.indexOf(
        u8,
        denied.bytes,
        "access-control-allow-origin",
    ) == null);
    try expectField(denied.bytes, "vary: Origin\r\n");
    try std.testing.expectEqual(@as(u16, 2), state.handler_calls);
}

test "route response limit denies oversized actual and preflight before serialization" {
    const at_limit = makeOrigin(limited_reflected_origin_max);
    const over_limit = makeOrigin(limited_reflected_origin_max + 1);
    var state = State{};
    var workspace = CapacityApp.Workspace{};
    var request: [512]u8 = undefined;
    var output: [2048]u8 = undefined;

    const allowed_wire = try std.fmt.bufPrint(
        &request,
        "GET /limited HTTP/1.1\r\nHost: example.test\r\nOrigin: {s}\r\n\r\n",
        .{&at_limit},
    );
    const allowed = try serve(CapacityApp, allowed_wire, &state, &workspace, &output);
    try expectFieldValue(allowed.bytes, "access-control-allow-origin", &at_limit);

    const denied_wire = try std.fmt.bufPrint(
        &request,
        "GET /limited HTTP/1.1\r\nHost: example.test\r\nOrigin: {s}\r\n\r\n",
        .{&over_limit},
    );
    const denied = try serve(CapacityApp, denied_wire, &state, &workspace, &output);
    try std.testing.expectEqual(response.Status.ok, denied.status);
    try std.testing.expect(std.mem.indexOf(
        u8,
        denied.bytes,
        "access-control-allow-origin",
    ) == null);
    try expectField(denied.bytes, "vary: Origin\r\n");

    const preflight_wire = try std.fmt.bufPrint(
        &request,
        "OPTIONS /limited HTTP/1.1\r\nHost: example.test\r\nOrigin: {s}\r\n" ++
            "Access-Control-Request-Method: GET\r\n\r\n",
        .{&over_limit},
    );
    const preflight = try serve(CapacityApp, preflight_wire, &state, &workspace, &output);
    try std.testing.expectEqual(response.Status.forbidden, preflight.status);
    try expectField(
        preflight.bytes,
        "vary: Origin, Access-Control-Request-Method, Access-Control-Request-Headers\r\n",
    );
    try std.testing.expectEqual(@as(u16, 2), state.handler_calls);
}

test "route response limit checks the complete preflight decision" {
    const at_limit = [_]u8{'x'} ** limited_reflected_headers_max;
    const over_limit = [_]u8{'x'} ** (limited_reflected_headers_max + 1);
    var state = State{};
    var workspace = CapacityApp.Workspace{};
    var request: [512]u8 = undefined;
    var output: [2048]u8 = undefined;

    const allowed_wire = try std.fmt.bufPrint(
        &request,
        "OPTIONS /limited HTTP/1.1\r\nHost: example.test\r\n" ++
            "Origin: https://app.example\r\nAccess-Control-Request-Method: GET\r\n" ++
            "Access-Control-Request-Headers: {s}\r\n\r\n",
        .{&at_limit},
    );
    const allowed = try serve(CapacityApp, allowed_wire, &state, &workspace, &output);
    try std.testing.expectEqual(response.Status.no_content, allowed.status);
    try expectFieldValue(allowed.bytes, "access-control-allow-headers", &at_limit);

    const denied_wire = try std.fmt.bufPrint(
        &request,
        "OPTIONS /limited HTTP/1.1\r\nHost: example.test\r\n" ++
            "Origin: https://app.example\r\nAccess-Control-Request-Method: GET\r\n" ++
            "Access-Control-Request-Headers: {s}\r\n\r\n",
        .{&over_limit},
    );
    const denied = try serve(CapacityApp, denied_wire, &state, &workspace, &output);
    try std.testing.expectEqual(response.Status.forbidden, denied.status);
    try std.testing.expect(std.mem.indexOf(
        u8,
        denied.bytes,
        "access-control-allow-headers",
    ) == null);
    try expectField(
        denied.bytes,
        "vary: Origin, Access-Control-Request-Method, Access-Control-Request-Headers\r\n",
    );
    try std.testing.expectEqual(@as(u16, 0), state.handler_calls);
}

test "redirect reflected Origin uses generated application line limit" {
    const at_limit = makeOrigin(limited_reflected_origin_max);
    const over_limit = makeOrigin(limited_reflected_origin_max + 1);
    var state = State{};
    var workspace = RedirectCapacityApp.Workspace{};
    var request: [512]u8 = undefined;
    var output: [2048]u8 = undefined;

    const allowed_wire = try std.fmt.bufPrint(
        &request,
        "GET /wide HTTP/1.1\r\nHost: example.test\r\nOrigin: {s}\r\n\r\n",
        .{&at_limit},
    );
    const allowed = try serve(RedirectCapacityApp, allowed_wire, &state, &workspace, &output);
    try std.testing.expectEqual(response.Status.moved_permanently, allowed.status);
    try expectFieldValue(allowed.bytes, "access-control-allow-origin", &at_limit);

    const denied_wire = try std.fmt.bufPrint(
        &request,
        "GET /wide HTTP/1.1\r\nHost: example.test\r\nOrigin: {s}\r\n\r\n",
        .{&over_limit},
    );
    const denied = try serve(RedirectCapacityApp, denied_wire, &state, &workspace, &output);
    try std.testing.expectEqual(response.Status.moved_permanently, denied.status);
    try std.testing.expect(std.mem.indexOf(
        u8,
        denied.bytes,
        "access-control-allow-origin",
    ) == null);
    try expectField(denied.bytes, "vary: Origin\r\n");
    try std.testing.expectEqual(@as(u16, 0), state.handler_calls);
}

test "explicitly disabled route permits a sub-77 line limit and emits no CORS" {
    var state = State{};
    var workspace = DisabledRouteCorsApp.Workspace{};
    var output: [2048]u8 = undefined;
    const actual_result = try serve(
        DisabledRouteCorsApp,
        "GET /disabled HTTP/1.1\r\nHost: example.test\r\n" ++
            "Origin: https://app.example\r\n\r\n",
        &state,
        &workspace,
        &output,
    );
    try std.testing.expectEqual(response.Status.ok, actual_result.status);
    try std.testing.expect(std.mem.indexOf(u8, actual_result.bytes, "access-control-") == null);
    try std.testing.expect(std.mem.indexOf(u8, actual_result.bytes, "vary:") == null);

    const preflight_result = try serve(
        DisabledRouteCorsApp,
        "OPTIONS /disabled HTTP/1.1\r\nHost: example.test\r\n" ++
            "Origin: https://app.example\r\n" ++
            "Access-Control-Request-Method: GET\r\n\r\n",
        &state,
        &workspace,
        &output,
    );
    try std.testing.expectEqual(response.Status.forbidden, preflight_result.status);
    try std.testing.expect(std.mem.indexOf(
        u8,
        preflight_result.bytes,
        "access-control-",
    ) == null);
    try std.testing.expect(std.mem.indexOf(u8, preflight_result.bytes, "vary:") == null);
    try std.testing.expectEqual(@as(u16, 1), state.handler_calls);
}

test "aggregate CORS byte and field limits fail closed without changing handlers" {
    inline for (.{ CorsByteCapacityApp, CorsCountCapacityApp }) |TargetApp| {
        try expectAggregateCapacityFallback(TargetApp);
    }
}

test "finite identity output capacity retries CORS but preserves baseline failure" {
    var state = State{};
    var workspace = CapacityApp.Workspace{};
    var disabled_workspace = DisabledApp.Workspace{};
    var output: [2048]u8 = undefined;
    const vary_only = try serve(
        CapacityApp,
        "GET /standard HTTP/1.1\r\nHost: example.test\r\n\r\n",
        &state,
        &workspace,
        &output,
    );
    const vary_only_length = vary_only.bytes.len;
    const full = try serve(
        CapacityApp,
        "GET /standard HTTP/1.1\r\nHost: example.test\r\n" ++
            "Origin: https://app.example\r\n\r\n",
        &state,
        &workspace,
        output[0..vary_only_length],
    );
    try std.testing.expectEqual(response.Status.ok, full.status);
    try std.testing.expectEqual(vary_only_length, full.bytes.len);
    try expectPermissionsSuppressed(full.bytes);
    try expectField(full.bytes, "vary: Origin\r\n");

    const baseline = try serve(
        DisabledApp,
        "GET /public HTTP/1.1\r\nHost: example.test\r\n\r\n",
        &state,
        &disabled_workspace,
        &output,
    );
    try std.testing.expectError(error.OutputTooSmall, serve(
        CapacityApp,
        "GET /standard HTTP/1.1\r\nHost: example.test\r\n" ++
            "Origin: https://app.example\r\n\r\n",
        &state,
        &workspace,
        output[0 .. baseline.bytes.len - 1],
    ));
}

fn expectAggregateCapacityFallback(comptime TargetApp: type) !void {
    const origin = makeOrigin(46);
    const requested_headers = [_]u8{'x'} ** 45;
    var state = State{};
    var workspace = TargetApp.Workspace{};
    var request: [512]u8 = undefined;
    var output: [2048]u8 = undefined;

    const actual_wire = try std.fmt.bufPrint(
        &request,
        "GET /actual HTTP/1.1\r\nHost: example.test\r\nOrigin: {s}\r\n\r\n",
        .{&origin},
    );
    const actual = try serve(TargetApp, actual_wire, &state, &workspace, &output);
    try std.testing.expectEqual(response.Status.ok, actual.status);
    try std.testing.expect(std.mem.endsWith(u8, actual.bytes, "\r\n\r\nok"));
    try expectPermissionsSuppressed(actual.bytes);
    try expectField(actual.bytes, "vary: Origin\r\n");

    const preflight_wire = try std.fmt.bufPrint(
        &request,
        "OPTIONS /actual HTTP/1.1\r\nHost: example.test\r\nOrigin: {s}\r\n" ++
            "Access-Control-Request-Method: GET\r\n" ++
            "Access-Control-Request-Headers: {s}\r\n\r\n",
        .{ &origin, &requested_headers },
    );
    const preflight = try serve(TargetApp, preflight_wire, &state, &workspace, &output);
    try std.testing.expectEqual(response.Status.forbidden, preflight.status);
    try expectPermissionsSuppressed(preflight.bytes);
    try expectField(
        preflight.bytes,
        "vary: Origin, Access-Control-Request-Method, Access-Control-Request-Headers\r\n",
    );

    const no_content_wire = try std.fmt.bufPrint(
        &request,
        "GET /empty-204 HTTP/1.1\r\nHost: example.test\r\nOrigin: {s}\r\n\r\n",
        .{&origin},
    );
    const no_content = try serve(TargetApp, no_content_wire, &state, &workspace, &output);
    try std.testing.expectEqual(response.Status.no_content, no_content.status);
    try std.testing.expect(std.mem.endsWith(u8, no_content.bytes, "\r\n\r\n"));
    try expectPermissionsSuppressed(no_content.bytes);
    try expectField(no_content.bytes, "vary: Origin\r\n");
    try expectField(no_content.bytes, "x-handler: preserved\r\n");
    try std.testing.expectEqual(@as(u16, 2), state.handler_calls);
}

fn expectPermissionsSuppressed(wire: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, wire, "access-control-allow-") == null);
}

fn makeOrigin(comptime length: usize) [length]u8 {
    comptime std.debug.assert(length >= "https://a".len);
    var result = [_]u8{'a'} ** length;
    @memcpy(result[0.."https://".len], "https://");
    return result;
}

fn expectFieldValue(wire: []const u8, name: []const u8, value: []const u8) !void {
    const start = std.mem.indexOf(u8, wire, name) orelse return error.TestUnexpectedResult;
    const value_start = start + name.len + ": ".len;
    if (value.len + "\r\n".len > wire.len - value_start) {
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqualStrings(value, wire[value_start .. value_start + value.len]);
    try std.testing.expectEqualStrings("\r\n", wire[value_start + value.len ..][0..2]);
}

fn expectField(wire: []const u8, field: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, wire, field) != null);
}
