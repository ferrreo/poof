const std = @import("std");
const application = @import("../../src/application.zig");
const body = @import("../../src/body.zig");
const csrf = @import("../../src/csrf.zig");
const endpoint = @import("../../src/endpoint.zig");
const form = @import("../../src/form.zig");
const json = @import("../../src/json.zig");
const multipart = @import("../../src/multipart.zig");
const response = @import("../../src/response.zig");
const response_stream = @import("../../src/response/stream.zig");
const route = @import("../../src/route.zig");
const startup = @import("../../src/startup.zig");
const testing = @import("../../src/testing.zig");
const config = @import("../../src/internal/runtime/config.zig");
const deterministic_reactor = @import("../../src/internal/runtime/deterministic_reactor.zig");
const worker_runtime = @import("../../src/internal/runtime/worker.zig");
const worker_storage = @import("../../src/internal/runtime/worker/storage.zig");
const gzip_encoder = @import("../../src/internal/runtime/gzip/encoder.zig");

const Origins = csrf.OriginSet(4, 128);

const State = struct {
    origins: Origins = .{},
    source_origins: Origins = .{},
    session: ?csrf.SessionToken = null,
    stored: ?csrf.SessionToken = null,
    load_calls: u16 = 0,
    handler_calls: u16 = 0,
    after_calls: u16 = 0,
    body_calls: u16 = 0,
    after_saw_cleared_state: bool = false,
    raw_pairs: u16 = 0,
    raw_segments: u16 = 0,
    raw_token_exposed: bool = false,
    corrupt_cache_control: bool = false,
    saturate_token_response: bool = false,
    last_mapped_error: bool = false,
    stream_polls: u16 = 0,
    stream_aborts: u16 = 0,
    stream_joins: u16 = 0,
};

const Context = application.Context(State, response.standard_head_limits);
const Response = Context.ResponseType;

fn originsProvider(state: *const State) *const Origins {
    return &state.origins;
}

fn sourceOriginsProvider(state: *const State) *const Origins {
    return &state.source_origins;
}

fn loadSession(context: *Context) ?csrf.SessionToken {
    context.state.load_calls += 1;
    return context.state.session;
}

fn storeSession(context: *Context, token: csrf.SessionToken) void {
    context.state.stored = token;
}

fn clearSession(context: *Context) void {
    context.state.stored = null;
}

const policy = csrf.synchronizer(Context, .{
    .origins = originsProvider,
    .source_origins = sourceOriginsProvider,
    .load = loadSession,
    .store = storeSession,
    .clear = clearSession,
});

const HostileResponse = struct {
    pub const State = void;

    pub fn response(
        _: HostileResponse,
        context: *Context,
        _: *void,
        value: anytype,
    ) void {
        if (comptime @TypeOf(value.*) == Response) {
            if (value.status == .forbidden or value.status == .misdirected_request) {
                value.* = context.textStatic(.ok, "bypassed");
                value.setHeaderStatic("Cache-Control", "public") catch unreachable;
                value.setHeaderStatic("X-Hostile", "retained") catch unreachable;
                value.appendHeaderStatic("Set-Cookie", "secret=retained") catch unreachable;
            } else if (context.state.corrupt_cache_control) {
                value.setHeaderStatic("Cache-Control", "public") catch unreachable;
            }
        } else if (context.state.corrupt_cache_control) {
            value.setHeaderStatic("Cache-Control", "public") catch unreachable;
        }
    }

    pub fn after(
        _: HostileResponse,
        context: *const Context,
        _: *void,
        outcome: application.Outcome,
    ) void {
        context.state.after_calls += 1;
        context.state.last_mapped_error = outcome.mapped_error;
        const state = context.csrf_request orelse return;
        context.state.after_saw_cleared_state = state.status == .pending and
            state.expected == .none and !state.token_exposed;
    }
};

const BodyAfterCsrf = struct {
    pub const State = void;

    pub fn body(
        _: BodyAfterCsrf,
        context: *Context,
        _: *void,
        _: anytype,
    ) ?Response {
        const state = context.csrf_request orelse unreachable;
        std.debug.assert(state.status == .accepted or state.status == .safe);
        context.state.body_calls += 1;
        return null;
    }
};

const RawDefinition = endpoint.Endpoint(.{
    .body = form.raw(.{
        .encoded_wire_bytes_max = 512,
        .decoded_bytes_max = 512,
        .segments_max = 8,
    }),
});

const TypedDefinition = endpoint.Endpoint(.{
    .body = form.typed(struct { age: u16 }, .{
        .encoded_wire_bytes_max = 512,
        .decoded_bytes_max = 512,
        .segments_max = 8,
        .unknown_fields = .reject,
    }),
});

const JsonDefinition = endpoint.Endpoint(.{
    .body = json.typed(struct { age: u16 }, .{
        .encoded_wire_bytes_max = 512,
        .decoded_bytes_max = 512,
        .parse_memory_bytes_max = 2048,
    }),
});

const MarkerlessBody = multipart.decode(.{
    .note = multipart.bytesField(multipart.optional),
}, .{});
const MarkerlessDefinition = endpoint.Endpoint(.{ .body = MarkerlessBody });
const MarkerlessSpec = @TypeOf(MarkerlessBody);

const MarkerlessConsumer = struct {
    pub const State = void;

    pub fn init(_: MarkerlessConsumer, _: *Context) MarkerlessConsumer.State {}

    pub fn field(
        _: MarkerlessConsumer,
        _: *MarkerlessConsumer.State,
        _: MarkerlessSpec.Field,
    ) void {}

    pub fn complete(
        _: MarkerlessConsumer,
        context: *Context,
        _: *MarkerlessConsumer.State,
        _: MarkerlessDefinition.InputType,
        _: MarkerlessSpec.Summaries,
    ) multipart.Decision(Response) {
        context.state.handler_calls += 1;
        return multipart.commit(context.textStatic(.ok, "multipart"));
    }
};

fn rawHandler(context: *Context, input: RawDefinition.InputType) Response {
    context.state.handler_calls += 1;
    context.state.raw_pairs = @intCast(input.body.pairs.len);
    context.state.raw_segments = input.body.segments_count;
    for (input.body.pairs) |pair| {
        if (std.mem.eql(u8, pair.name, @TypeOf(policy).form_name)) {
            context.state.raw_token_exposed = true;
        }
    }
    return context.textStatic(.ok, "accepted");
}

fn typedHandler(context: *Context, _: TypedDefinition.InputType) Response {
    context.state.handler_calls += 1;
    return context.textStatic(.ok, "typed");
}

fn jsonHandler(context: *Context, _: JsonDefinition.InputType) Response {
    context.state.handler_calls += 1;
    return context.textStatic(.ok, "json");
}

fn bodylessHandler(context: *Context) Response {
    context.state.handler_calls += 1;
    return context.textStatic(.ok, "bodyless");
}

fn tokenHandler(context: *Context) Response {
    var token = policy.token(context) catch return context.empty(.internal_server_error);
    defer token.clear();
    context.state.handler_calls += 1;
    var value = context.htmlStatic(.ok, "<form>protected token response</form>");
    if (context.state.saturate_token_response) saturateHeaders(&value);
    return value;
}

const TokenProducer = struct {
    state: *State,

    pub fn poll(
        self: *@This(),
        _: []u8,
        _: response_stream.Wake,
    ) response_stream.PollError!response_stream.PollResult {
        self.state.stream_polls += 1;
        return .pending;
    }

    pub fn abort(self: *@This()) void {
        self.state.stream_aborts += 1;
    }

    pub fn join(self: *@This()) void {
        self.state.stream_joins += 1;
    }
};

fn streamTokenHandler(context: *Context) Context.StreamResponse(TokenProducer) {
    var token = policy.token(context) catch unreachable;
    defer token.clear();
    context.state.handler_calls += 1;
    var value = context.streamUnknown(
        .ok,
        response.media.text,
        TokenProducer{ .state = context.state },
        &.{},
    );
    if (context.state.saturate_token_response) saturateHeaders(&value);
    return value;
}

fn saturateHeaders(value: anytype) void {
    while (true) value.appendHeaderStatic("X-Fill", "x") catch return;
}

const App = application.Application(.{
    .State = State,
    .middleware = .{ HostileResponse{}, policy, BodyAfterCsrf{} },
    .routes = .{
        route.post("/form", RawDefinition.handle(rawHandler)),
        route.post("/typed", TypedDefinition.handle(typedHandler)),
        route.post("/json", JsonDefinition.handle(jsonHandler)),
        route.post("/bodyless", bodylessHandler),
        route.post("/multipart", MarkerlessDefinition.handle(MarkerlessConsumer{})),
        route.get("/token", tokenHandler),
        route.get("/stream-token", streamTokenHandler),
    },
    .response_gzip = application.ResponseGzip{ .minimum_bytes = 0 },
});

test "planned CSRF-protected method cannot mutate from POST to GET" {
    const input = application.Input{
        .method = "POST",
        .path = "/bodyless",
        .raw_target = "/bodyless",
        .raw_path = "/bodyless",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
    };
    var route_workspace: App.RouteSearchWorkspace = undefined;
    var plan = App.plan(input, &route_workspace);
    plan.input.method = "GET";
    var state = State{};
    var workspace = App.Workspace{};
    var output: [1024]u8 = undefined;

    try std.testing.expectError(
        error.InvalidRoutePlan,
        App.prepareHeadPlanned(&state, &workspace, &output, &plan, .{}),
    );
    try std.testing.expectEqual(.idle, workspace.lifecycle);
    try std.testing.expectEqual(@as(u16, 0), state.load_calls);
    try std.testing.expectEqual(@as(u16, 0), state.handler_calls);
    try std.testing.expectEqual(@as(u16, 0), state.after_calls);
}

const Client = testing.ConfiguredClient(App, .{
    .request_bytes_max = 4096,
    .response_bytes_max = 8192,
    .response_capture_bytes_max = 8192,
});

const ProxyClient = testing.ConfiguredClient(App, .{
    .request_bytes_max = 4096,
    .response_bytes_max = 8192,
    .response_capture_bytes_max = 8192,
    .forwarding = .{
        .family = .forwarded,
        .trusted = &.{"127.0.0.1"},
    },
});

const XProxyClient = testing.ConfiguredClient(App, .{
    .request_bytes_max = 4096,
    .response_bytes_max = 8192,
    .response_capture_bytes_max = 8192,
    .forwarding = .{
        .family = .x_forwarded,
        .trusted = &.{"127.0.0.1"},
    },
});

test "CSRF form source strips token and preserves raw segment accounting" {
    var state = try readyState();
    var encoded = try csrf.EncodedSynchronizerToken.init(state.session.?);
    defer encoded.clear();
    var body_buffer: [256]u8 = undefined;
    const request_body = try std.fmt.bufPrint(
        &body_buffer,
        "_csrf={s}&name=zig",
        .{encoded.slice()},
    );
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{
        .method = "POST",
        .target = "/form",
        .headers = &.{
            .{ .name = "Origin", .value = "http://ploof.test" },
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        },
        .body = request_body,
    });
    try std.testing.expectEqual(@as(u16, 200), actual.status);
    try std.testing.expectEqual(@as(u16, 1), state.handler_calls);
    try std.testing.expectEqual(@as(u16, 1), state.body_calls);
    try std.testing.expectEqual(@as(u16, 1), state.raw_pairs);
    try std.testing.expectEqual(@as(u16, 2), state.raw_segments);
    try std.testing.expect(!state.raw_token_exposed);
    try std.testing.expect(state.after_saw_cleared_state);
}

test "CSRF validates a genuinely gzip-compressed form body" {
    var state = try readyState();
    var encoded = try csrf.EncodedSynchronizerToken.init(state.session.?);
    defer encoded.clear();
    var form_storage: [256]u8 = undefined;
    const form_body = try std.fmt.bufPrint(
        &form_storage,
        "_csrf={s}&name=zig",
        .{encoded.slice()},
    );
    var gzip_workspace: gzip_encoder.Workspace = undefined;
    var gzip_storage: [512]u8 = undefined;
    const gzip_body = try gzip_encoder.compress(
        &gzip_workspace,
        form_body,
        &gzip_storage,
        .fastest,
    );
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{
        .method = "POST",
        .target = "/form",
        .headers = &.{
            .{ .name = "Origin", .value = "http://ploof.test" },
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Content-Encoding", .value = "gzip" },
        },
        .body = gzip_body,
    });
    try std.testing.expectEqual(@as(u16, 200), actual.status);
    try std.testing.expectEqual(@as(u16, 1), state.handler_calls);
    try std.testing.expectEqual(@as(u16, 1), state.body_calls);
    try std.testing.expectEqual(@as(u16, 1), state.raw_pairs);
    try std.testing.expect(!state.raw_token_exposed);
}

test "CSRF form rejection preempts binding and hostile response middleware" {
    var state = try readyState();
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{
        .method = "POST",
        .target = "/typed",
        .headers = &.{
            .{ .name = "Origin", .value = "http://ploof.test" },
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Expect", .value = "100-continue" },
        },
        .body = "age=not-a-number",
    });
    try expectFixedRejection(actual, 403);
    try std.testing.expect(std.mem.indexOf(u8, actual.bytes, "100 Continue") == null);
    try std.testing.expectEqual(@as(u16, 0), state.handler_calls);
    try std.testing.expectEqual(@as(u16, 0), state.body_calls);
}

test "CSRF rejects duplicate body and header plus body token sources" {
    var state = try readyState();
    var encoded = try csrf.EncodedSynchronizerToken.init(state.session.?);
    defer encoded.clear();
    var duplicate_buffer: [256]u8 = undefined;
    const duplicate = try std.fmt.bufPrint(
        &duplicate_buffer,
        "_csrf={s}&_csrf={s}",
        .{ encoded.slice(), encoded.slice() },
    );
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const duplicate_response = try formRequest(&client, duplicate, &.{});
    try expectFixedRejection(duplicate_response, 403);
    const mixed_response = try formRequest(&client, duplicate[0 .. 6 + encoded.slice().len], &.{
        .{ .name = "X-CSRF-Token", .value = encoded.slice() },
    });
    try expectFixedRejection(mixed_response, 403);
    try std.testing.expectEqual(@as(u16, 0), state.handler_calls);
}

test "CSRF rejects JSON and bodyless routes in head before dispatch" {
    var state = try readyState();
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const json_response = try client.request(.{
        .method = "POST",
        .target = "/json",
        .headers = &.{
            .{ .name = "Origin", .value = "http://ploof.test" },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Expect", .value = "100-continue" },
        },
        .body = "{\"age\":7}",
    });
    try expectFixedRejection(json_response, 403);
    try std.testing.expect(std.mem.indexOf(u8, json_response.bytes, "100 Continue") == null);

    const bodyless = try client.request(.{
        .method = "POST",
        .target = "/bodyless",
        .headers = &.{.{ .name = "Origin", .value = "http://ploof.test" }},
    });
    try expectFixedRejection(bodyless, 403);
    try std.testing.expectEqual(@as(u16, 0), state.handler_calls);
}

test "CSRF markerless multipart requires header in head and sends no continue" {
    var state = try readyState();
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{
        .method = "POST",
        .target = "/multipart",
        .headers = &.{
            .{ .name = "Origin", .value = "http://ploof.test" },
            .{ .name = "Content-Type", .value = "multipart/form-data; boundary=C" },
            .{ .name = "Expect", .value = "100-continue" },
        },
        .body = "--C--\r\n",
    });
    try expectFixedRejection(actual, 403);
    try std.testing.expect(std.mem.indexOf(u8, actual.bytes, "100 Continue") == null);
    try std.testing.expectEqual(@as(u16, 0), state.handler_calls);
}

test "CSRF token exposure forces no-transform after hostile middleware" {
    var state = try readyState();
    state.corrupt_cache_control = true;
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{
        .method = "GET",
        .target = "/token",
        .headers = &.{.{ .name = "Accept-Encoding", .value = "gzip" }},
    });
    try std.testing.expectEqual(@as(u16, 200), actual.status);
    try std.testing.expectEqualStrings(
        "no-store, no-transform",
        actual.header("Cache-Control").?,
    );
    try std.testing.expect(actual.header("Content-Encoding") == null);
}

test "CSRF token response saturation becomes fixed mapped 500" {
    var state = try readyState();
    state.saturate_token_response = true;
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{ .method = "GET", .target = "/token" });
    try expectFixedRejection(actual, 500);
    try std.testing.expect(actual.header("X-Fill") == null);
    try std.testing.expect(state.last_mapped_error);
}

test "CSRF stream token response saturation aborts and becomes mapped 500" {
    var state = try readyState();
    state.saturate_token_response = true;
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{ .method = "GET", .target = "/stream-token" });
    try expectFixedRejection(actual, 500);
    try std.testing.expect(actual.header("X-Fill") == null);
    try std.testing.expect(state.last_mapped_error);
    try std.testing.expectEqual(@as(u16, 0), state.stream_polls);
    try std.testing.expectEqual(@as(u16, 1), state.stream_aborts);
    try std.testing.expectEqual(@as(u16, 1), state.stream_joins);
}

test "trusted proxy keeps public Host separate from cross-site CSRF source" {
    var state = State{
        .origins = try Origins.init(&.{"https://api.example"}),
        .source_origins = try Origins.init(&.{"https://app.example"}),
        .session = try csrf.SessionToken.fromRandomBytes([_]u8{0x61} ** 32),
    };
    var encoded = try csrf.EncodedSynchronizerToken.init(state.session.?);
    defer encoded.clear();
    var storage: ProxyClient.Storage = undefined;
    var client = try ProxyClient.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const accepted = try proxyCsrfRequest(&client, encoded.slice(), "api.example", .app);
    try std.testing.expectEqual(@as(u16, 200), accepted.status);
    try std.testing.expectEqual(@as(u16, 1), state.handler_calls);

    const wrong_host = try proxyCsrfRequest(&client, encoded.slice(), "app.example", .app);
    try expectFixedRejection(wrong_host, 421);
    const missing_source = try proxyCsrfRequest(&client, encoded.slice(), "api.example", .none);
    try expectFixedRejection(missing_source, 403);
    const wrong_source = try proxyCsrfRequest(&client, encoded.slice(), "api.example", .other);
    try expectFixedRejection(wrong_source, 403);
    var wrong_token = encoded.bytes;
    wrong_token[0] = if (wrong_token[0] == 'A') 'B' else 'A';
    const invalid_token = try proxyCsrfRequest(&client, &wrong_token, "api.example", .app);
    try expectFixedRejection(invalid_token, 403);
    try std.testing.expectEqual(@as(u16, 1), state.handler_calls);
}

test "trusted X-Forwarded keeps public Host separate from CSRF source" {
    var state = State{
        .origins = try Origins.init(&.{"https://api.example"}),
        .source_origins = try Origins.init(&.{"https://app.example"}),
        .session = try csrf.SessionToken.fromRandomBytes([_]u8{0x62} ** 32),
    };
    var encoded = try csrf.EncodedSynchronizerToken.init(state.session.?);
    defer encoded.clear();
    var storage: XProxyClient.Storage = undefined;
    var client = try XProxyClient.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const accepted = try xProxyCsrfRequest(&client, encoded.slice(), "api.example");
    try std.testing.expectEqual(@as(u16, 200), accepted.status);
    const wrong_host = try xProxyCsrfRequest(&client, encoded.slice(), "app.example");
    try expectFixedRejection(wrong_host, 421);
    try std.testing.expectEqual(@as(u16, 1), state.handler_calls);
}

test "CSRF origin mismatch stays fixed 421 and startup validates before accept" {
    var state = try readyStateFor("http://other.test");
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;
    const actual = try client.request(.{ .method = "GET", .target = "/token" });
    try expectFixedRejection(actual, 421);

    var invalid = State{};
    switch (startup.checkApplication(App, &invalid)) {
        .ready => return error.TestUnexpectedResult,
        .failure => {},
    }
    const limits = comptime config.Limits.validate(.{
        .connection_slots = 1,
        .request_slots = 1,
        .receive_buffers = 2,
        .receive_buffer_bytes = 512,
        .pipeline_bytes_per_connection = 512,
        .response_bytes_per_request = 2048,
        .submission_entries = 16,
        .completion_entries = 32,
    });
    const Storage = worker_storage.Storage(App, limits);
    const Reactor = deterministic_reactor.DeterministicReactor(64);
    const Worker = worker_runtime.Worker(App, Storage, Reactor);
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    var worker_storage_value: Storage = undefined;
    try worker_storage_value.init(&slab);
    var reactor_value = Reactor{};
    var worker: Worker = undefined;
    try std.testing.expectError(error.InvalidApplicationConfiguration, worker.init(
        &invalid,
        &worker_storage_value,
        &reactor_value,
        0,
        .{ .value = 1 },
        null,
    ));
}

fn formRequest(
    client: *Client,
    request_body: []const u8,
    extra: []const testing.Request.Header,
) !testing.Response {
    var headers: [3]testing.Request.Header = undefined;
    headers[0] = .{ .name = "Origin", .value = "http://ploof.test" };
    headers[1] = .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" };
    if (extra.len > 1) return error.TestUnexpectedResult;
    if (extra.len == 1) headers[2] = extra[0];
    return client.request(.{
        .method = "POST",
        .target = "/form",
        .headers = headers[0 .. 2 + extra.len],
        .body = request_body,
    });
}

const ProxySource = enum { app, other, none };

fn proxyCsrfRequest(
    client: *ProxyClient,
    token: []const u8,
    host: []const u8,
    source: ProxySource,
) !testing.Response {
    var forwarded_buffer: [96]u8 = undefined;
    const forwarded = try std.fmt.bufPrint(
        &forwarded_buffer,
        "for=198.51.100.7;proto=https;host={s}",
        .{host},
    );
    var headers: [4]testing.Request.Header = undefined;
    headers[0] = .{ .name = "Forwarded", .value = forwarded };
    headers[1] = .{ .name = "Sec-Fetch-Site", .value = "cross-site" };
    headers[2] = .{ .name = "X-CSRF-Token", .value = token };
    const count: usize = switch (source) {
        .app => blk: {
            headers[3] = .{ .name = "Origin", .value = "https://app.example" };
            break :blk 4;
        },
        .other => blk: {
            headers[3] = .{ .name = "Origin", .value = "https://other.example" };
            break :blk 4;
        },
        .none => 3,
    };
    return client.request(.{
        .method = "POST",
        .target = "/bodyless",
        .headers = headers[0..count],
    });
}

fn xProxyCsrfRequest(
    client: *XProxyClient,
    token: []const u8,
    host: []const u8,
) !testing.Response {
    return client.request(.{
        .method = "POST",
        .target = "/bodyless",
        .headers = &.{
            .{ .name = "X-Forwarded-For", .value = "198.51.100.7" },
            .{ .name = "X-Forwarded-Host", .value = host },
            .{ .name = "X-Forwarded-Proto", .value = "https" },
            .{ .name = "Sec-Fetch-Site", .value = "cross-site" },
            .{ .name = "Origin", .value = "https://app.example" },
            .{ .name = "X-CSRF-Token", .value = token },
        },
    });
}

fn expectFixedRejection(actual: testing.Response, status: u16) !void {
    try std.testing.expectEqual(status, actual.status);
    try std.testing.expectEqualStrings("", actual.body);
    try std.testing.expectEqualStrings("no-store", actual.header("Cache-Control").?);
    try std.testing.expect(actual.header("X-Hostile") == null);
    try std.testing.expect(actual.header("Set-Cookie") == null);
}

fn readyState() !State {
    return readyStateFor("http://ploof.test");
}

fn readyStateFor(origin: []const u8) !State {
    return .{
        .origins = try Origins.init(&.{origin}),
        .source_origins = try Origins.init(&.{origin}),
        .session = try csrf.SessionToken.fromRandomBytes([_]u8{0x61} ** 32),
    };
}

test {
    std.testing.refAllDecls(@This());
    _ = body;
}
