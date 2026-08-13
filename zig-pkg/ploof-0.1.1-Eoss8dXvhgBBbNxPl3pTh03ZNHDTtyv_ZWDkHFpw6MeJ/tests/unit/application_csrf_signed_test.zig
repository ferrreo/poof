const std = @import("std");
const application = @import("../../src/application.zig");
const csrf = @import("../../src/csrf.zig");
const endpoint = @import("../../src/endpoint.zig");
const form = @import("../../src/form.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const startup = @import("../../src/startup.zig");
const testing = @import("../../src/testing.zig");

const Origins = csrf.OriginSet(4, 128);

const State = struct {
    origins: Origins = .{},
    source_origins: Origins = .{},
    binding: ?csrf.LoginBinding = null,
    keys: csrf.Keyring = .{},
    handler_calls: u16 = 0,
};

const Context = application.Context(State, response.standard_head_limits);
const Response = Context.ResponseType;

fn originsProvider(state: *const State) *const Origins {
    return &state.origins;
}

fn sourceOriginsProvider(state: *const State) *const Origins {
    return &state.source_origins;
}

fn keysProvider(state: *const State) *const csrf.Keyring {
    return &state.keys;
}

fn bindingProvider(context: *Context) ?csrf.LoginBinding {
    return context.state.binding;
}

const policy = csrf.signedDoubleSubmit(Context, .{
    .origins = originsProvider,
    .source_origins = sourceOriginsProvider,
    .keys = keysProvider,
    .binding = bindingProvider,
    .form_name = "csrf&amp",
});

const FormDefinition = endpoint.Endpoint(.{
    .body = form.raw(.{
        .encoded_wire_bytes_max = 512,
        .decoded_bytes_max = 512,
        .segments_max = 8,
    }),
});

fn submit(context: *Context) Response {
    context.state.handler_calls += 1;
    return context.textStatic(.ok, "accepted");
}

fn submitForm(context: *Context, input: FormDefinition.InputType) Response {
    for (input.body.pairs) |pair| {
        if (std.mem.eql(u8, pair.name, @TypeOf(policy).form_name)) {
            return context.empty(.internal_server_error);
        }
    }
    return submit(context);
}

fn issue(context: *Context) Response {
    var token = policy.issue(context, [_]u8{0x77} ** 32) catch {
        return context.empty(.internal_server_error);
    };
    defer token.clear();
    context.state.handler_calls += 1;
    return context.htmlStatic(.ok, "<main>signed CSRF token response</main>");
}

const App = application.Application(.{
    .State = State,
    .middleware = .{policy},
    .routes = .{
        route.post("/submit", submit),
        route.post("/form", FormDefinition.handle(submitForm)),
        route.get("/issue", issue),
    },
    .response_gzip = application.ResponseGzip{ .minimum_bytes = 0 },
});

const Client = testing.ConfiguredClient(App, .{
    .request_bytes_max = 4096,
    .response_bytes_max = 8192,
    .response_capture_bytes_max = 8192,
});

test "signed CSRF accepts matching cookie and header" {
    var state = try readyState();
    var token = try state.keys.sign(state.binding.?, [_]u8{0x31} ** 32);
    defer token.clear();
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const actual = try signedRequest(&client, token.slice(), token.slice());
    try std.testing.expectEqual(@as(u16, 200), actual.status);
    try std.testing.expectEqual(@as(u16, 1), state.handler_calls);
}

test "signed CSRF accepts an explicit different-site source" {
    var state = try readyState();
    state.source_origins = try Origins.init(&.{"https://app.example"});
    var token = try state.keys.sign(state.binding.?, [_]u8{0x39} ** 32);
    defer token.clear();
    var cookie_storage: [192]u8 = undefined;
    const cookie = try std.fmt.bufPrint(
        &cookie_storage,
        "__Host-ploof-csrf={s}",
        .{token.slice()},
    );
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{
        .method = "POST",
        .target = "/submit",
        .headers = &.{
            .{ .name = "Sec-Fetch-Site", .value = "cross-site" },
            .{ .name = "Origin", .value = "https://app.example" },
            .{ .name = "X-CSRF-Token", .value = token.slice() },
            .{ .name = "Cookie", .value = cookie },
        },
    });
    try std.testing.expectEqual(@as(u16, 200), actual.status);
    try std.testing.expectEqual(@as(u16, 1), state.handler_calls);
}

test "signed CSRF accepts one URL-encoded token and rejects duplicate sources" {
    var state = try readyState();
    var token = try state.keys.sign(state.binding.?, [_]u8{0x36} ** 32);
    defer token.clear();
    var valid_storage: [256]u8 = undefined;
    const valid = try std.fmt.bufPrint(
        &valid_storage,
        "csrf%26amp={s}&name=zig",
        .{token.slice()},
    );
    var duplicate_storage: [384]u8 = undefined;
    const duplicate = try std.fmt.bufPrint(
        &duplicate_storage,
        "csrf%26amp={s}&csrf%26amp={s}",
        .{ token.slice(), token.slice() },
    );
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    try std.testing.expectEqual(
        @as(u16, 200),
        (try signedFormRequest(&client, token.slice(), valid, null)).status,
    );
    try expectForbidden(try signedFormRequest(&client, token.slice(), duplicate, null));
    try expectForbidden(try signedFormRequest(
        &client,
        token.slice(),
        valid,
        token.slice(),
    ));
    try std.testing.expectEqual(@as(u16, 1), state.handler_calls);
}

test "signed CSRF rejects missing invalid and duplicate cookies" {
    var state = try readyState();
    var token = try state.keys.sign(state.binding.?, [_]u8{0x32} ** 32);
    defer token.clear();
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const missing = try client.request(.{
        .method = "POST",
        .target = "/submit",
        .headers = &.{
            .{ .name = "Origin", .value = "http://ploof.test" },
            .{ .name = "X-CSRF-Token", .value = token.slice() },
        },
    });
    try expectForbidden(missing);
    const invalid = try signedRequest(&client, "invalid", token.slice());
    try expectForbidden(invalid);
    var duplicate_storage: [256]u8 = undefined;
    const duplicate = try std.fmt.bufPrint(
        &duplicate_storage,
        "__Host-ploof-csrf={s}; __Host-ploof-csrf={s}",
        .{ token.slice(), token.slice() },
    );
    const duplicate_response = try requestWithCookie(&client, duplicate, token.slice());
    try expectForbidden(duplicate_response);
    try std.testing.expectEqual(@as(u16, 0), state.handler_calls);
}

test "signed CSRF rejects a token bound to another login" {
    var state = try readyState();
    const other = try csrf.LoginBinding.fromRandomLoginValue([_]u8{0x52} ** 32);
    var token = try state.keys.sign(other, [_]u8{0x33} ** 32);
    defer token.clear();
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    try expectForbidden(try signedRequest(&client, token.slice(), token.slice()));
    try std.testing.expectEqual(@as(u16, 0), state.handler_calls);
}

test "signed CSRF startup and rotation accept active and previous keys" {
    const old_key = try csrf.Key.init(1, [_]u8{0x11} ** 32);
    const active_key = try csrf.Key.init(2, [_]u8{0x22} ** 32);
    const old_keys = try csrf.Keyring.init(old_key, null);
    var state = try readyStateWith(try csrf.Keyring.init(active_key, old_key));
    switch (startup.checkApplication(App, &state)) {
        .ready => {},
        .failure => return error.TestUnexpectedResult,
    }
    var previous = try old_keys.sign(state.binding.?, [_]u8{0x34} ** 32);
    defer previous.clear();
    var active = try state.keys.sign(state.binding.?, [_]u8{0x35} ** 32);
    defer active.clear();
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    try std.testing.expectEqual(
        @as(u16, 200),
        (try signedRequest(&client, previous.slice(), previous.slice())).status,
    );
    try std.testing.expectEqual(
        @as(u16, 200),
        (try signedRequest(&client, active.slice(), active.slice())).status,
    );
    try std.testing.expectEqual(@as(u16, 2), state.handler_calls);

    var invalid = State{
        .origins = state.origins,
        .source_origins = state.source_origins,
        .binding = state.binding,
    };
    switch (startup.checkApplication(App, &invalid)) {
        .ready => return error.TestUnexpectedResult,
        .failure => |failure| try std.testing.expect(failure.issue == .keyring),
    }
}

test "signed CSRF token exposure disables gzip" {
    var state = try readyState();
    var storage: Client.Storage = undefined;
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{
        .method = "GET",
        .target = "/issue",
        .headers = &.{.{ .name = "Accept-Encoding", .value = "gzip" }},
    });
    try std.testing.expectEqual(@as(u16, 200), actual.status);
    try std.testing.expectEqualStrings(
        "no-store, no-transform",
        actual.header("Cache-Control").?,
    );
    try std.testing.expect(actual.header("Content-Encoding") == null);
}

fn signedRequest(
    client: *Client,
    cookie_token: []const u8,
    header_token: []const u8,
) !testing.Response {
    var cookie_storage: [192]u8 = undefined;
    const cookie = try std.fmt.bufPrint(
        &cookie_storage,
        "__Host-ploof-csrf={s}",
        .{cookie_token},
    );
    return requestWithCookie(client, cookie, header_token);
}

fn requestWithCookie(
    client: *Client,
    cookie: []const u8,
    header_token: []const u8,
) !testing.Response {
    const headers = [_]testing.Request.Header{
        .{ .name = "Origin", .value = "http://ploof.test" },
        .{ .name = "X-CSRF-Token", .value = header_token },
        .{ .name = "Cookie", .value = cookie },
    };
    return client.request(.{
        .method = "POST",
        .target = "/submit",
        .headers = &headers,
    });
}

fn signedFormRequest(
    client: *Client,
    cookie_token: []const u8,
    body_bytes: []const u8,
    header_token: ?[]const u8,
) !testing.Response {
    var cookie_storage: [192]u8 = undefined;
    const cookie = try std.fmt.bufPrint(
        &cookie_storage,
        "__Host-ploof-csrf={s}",
        .{cookie_token},
    );
    var headers: [4]testing.Request.Header = undefined;
    headers[0] = .{ .name = "Origin", .value = "http://ploof.test" };
    headers[1] = .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" };
    headers[2] = .{ .name = "Cookie", .value = cookie };
    if (header_token) |value| headers[3] = .{ .name = "X-CSRF-Token", .value = value };
    const header_count = @as(usize, 3) + @intFromBool(header_token != null);
    return client.request(.{
        .method = "POST",
        .target = "/form",
        .headers = headers[0..header_count],
        .body = body_bytes,
    });
}

fn expectForbidden(actual: testing.Response) !void {
    try std.testing.expectEqual(@as(u16, 403), actual.status);
    try std.testing.expectEqualStrings("", actual.body);
    try std.testing.expectEqualStrings("no-store", actual.header("Cache-Control").?);
}

fn readyState() !State {
    const key = try csrf.Key.init(1, [_]u8{0x11} ** 32);
    return readyStateWith(try csrf.Keyring.init(key, null));
}

fn readyStateWith(keys: csrf.Keyring) !State {
    return .{
        .origins = try Origins.init(&.{"http://ploof.test"}),
        .source_origins = try Origins.init(&.{"http://ploof.test"}),
        .binding = try csrf.LoginBinding.fromRandomLoginValue([_]u8{0x51} ** 32),
        .keys = keys,
    };
}

test {
    std.testing.refAllDecls(@This());
}
