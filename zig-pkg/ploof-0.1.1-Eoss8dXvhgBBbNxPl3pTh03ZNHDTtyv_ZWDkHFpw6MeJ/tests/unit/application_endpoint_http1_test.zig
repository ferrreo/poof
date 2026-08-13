const std = @import("std");
const linux = std.os.linux;
const application = @import("../../src/application.zig");
const body = @import("../../src/body.zig");
const endpoint = @import("../../src/endpoint.zig");
const form = @import("../../src/form.zig");
const json = @import("../../src/json.zig");
const query = @import("../../src/query.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const testing = @import("../../src/testing.zig");
const allocation_guard = @import("../../src/internal/runtime/allocation_guard.zig");
const runtime_config = @import("../../src/internal/runtime/config.zig");
const worker_storage = @import("../../src/internal/runtime/worker/storage.zig");

const QueryInput = struct {
    page: u16 = 1,
};

const Payload = struct {
    name: []const u8,
    enabled: bool = false,
};

const Definition = endpoint.Endpoint(.{
    .query = query.typed(QueryInput, .{
        .segments_max = 2,
        .unknown_fields = .reject,
    }),
    .body = body.oneOf(.{
        .form = form.typed(Payload, .{
            .encoded_wire_bytes_max = 128,
            .decoded_bytes_max = 128,
            .segments_max = 3,
            .unknown_fields = .reject,
        }),
        .json = json.typed(Payload, .{
            .encoded_wire_bytes_max = 128,
            .decoded_bytes_max = 128,
            .parse_memory_bytes_max = 2048,
            .unknown_fields = .reject,
        }),
    }),
    .response_json_bytes_max = 256,
});

const AppState = struct {
    const HeadMode = enum {
        continue_request,
        encode_continue,
        short_json,
        discard_to_internal,
        mapped_error,
        rebind_retry,
    };

    handler_calls: u8 = 0,
    head_calls: u8 = 0,
    after_calls: u8 = 0,
    after_mapped_error: bool = false,
    after_view_valid: bool = false,
    head_json_view: []const u8 = "",
    head_mode: HeadMode = .continue_request,
};

const Context = application.Context(AppState, response.standard_head_limits);
const Response = Context.ResponseType;

fn handler(context: *Context, input: Definition.InputType) Response {
    context.state.handler_calls += 1;
    if (context.state.head_mode == .rebind_retry) {
        _ = context.json(.ok, .{ .oversized = "x" ** 300 }) catch {};
        return context.json(.ok, .{ .wrapped = context.state.head_json_view }) catch
            context.empty(.internal_server_error);
    }
    const selected = switch (input.body) {
        .form => |value| .{ value, "form" },
        .json => |value| .{ value, "json" },
    };
    return context.jsonWith(.{ .html_safe = true }, .ok, .{
        .page = input.query.page,
        .name = selected[0].name,
        .enabled = selected[0].enabled,
        .source = selected[1],
    }) catch context.empty(.internal_server_error);
}

const Lifecycle = struct {
    pub const State = struct { json_view: []const u8 = "" };

    pub fn init(_: Lifecycle) State {
        return .{};
    }

    pub fn head(
        _: Lifecycle,
        context: *Context,
        state: *State,
    ) error{Denied}!?Response {
        context.state.head_calls += 1;
        return switch (context.state.head_mode) {
            .continue_request => null,
            .encode_continue => encoded: {
                _ = context.json(.ok, .{ .discarded = true }) catch {
                    break :encoded context.empty(.internal_server_error);
                };
                break :encoded null;
            },
            .short_json => encoded: {
                const value = context.json(.unauthorized, .{ .error_message = "token" }) catch
                    break :encoded context.empty(.internal_server_error);
                state.json_view = value.bodyBytes();
                break :encoded value;
            },
            .discard_to_internal => internal: {
                const value = context.json(.ok, .{ .error_message = "token" }) catch
                    break :internal context.empty(.internal_server_error);
                state.json_view = value.bodyBytes();
                break :internal context.textStatic(.ok, "replacement");
            },
            .mapped_error => error.Denied,
            .rebind_retry => encoded: {
                const value = context.json(.ok, .{ .value = "head-source" }) catch
                    break :encoded context.empty(.internal_server_error);
                context.state.head_json_view = value.bodyBytes();
                break :encoded null;
            },
        };
    }

    pub fn after(
        _: Lifecycle,
        context: *const Context,
        state: *State,
        outcome: application.Outcome,
    ) void {
        context.state.after_calls += 1;
        context.state.after_mapped_error = outcome.mapped_error;
        if (state.json_view.len != 0) {
            context.state.after_view_valid = std.mem.eql(
                u8,
                state.json_view,
                "{\"error_message\":\"token\"}",
            );
        }
    }
};

fn mapError(context: *Context, _: error{Denied}) Response {
    return context.json(.forbidden, .{ .error_message = "denied" }) catch
        context.empty(.internal_server_error);
}

const App = application.Application(.{
    .State = AppState,
    .Error = error{Denied},
    .middleware = .{Lifecycle{}},
    .routes = .{
        route.post("/items", Definition.handle(handler)),
        route.get("/retry-json", RetryDefinition.handle(retryJsonHandler)),
    },
    .map_error = mapError,
});

const RetryDefinition = endpoint.Endpoint(.{ .response_json_bytes_max = 128 });

fn retryJsonHandler(context: *Context, _: RetryDefinition.InputType) Response {
    const first = context.json(.ok, .{ .value = "source" }) catch
        return context.empty(.internal_server_error);
    _ = context.json(.ok, .{ .oversized = "x" ** 160 }) catch {};
    return context.json(.ok, .{ .wrapped = first.bodyBytes() }) catch
        context.empty(.internal_server_error);
}

const Client = testing.ConfiguredClient(App, .{
    .request_bytes_max = 1024,
    .response_bytes_max = 2048,
    .response_capture_bytes_max = 2048,
});

test "non-multipart application erases upload transaction workspace" {
    try std.testing.expectEqual(
        @as(usize, 0),
        @sizeOf(@FieldType(App.Workspace, "multipart_commit")),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        @sizeOf(@FieldType(App.Workspace, "multipart_finalization")),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        @sizeOf(@FieldType(App.Workspace, "multipart_abort_mapped_error")),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        @sizeOf(@FieldType(App.Workspace, "multipart_abort_cause")),
    );
}

const content_type_form = testing.Request.Header{
    .name = "Content-Type",
    .value = "application/x-www-form-urlencoded",
};
const content_type_json = testing.Request.Header{
    .name = "Content-Type",
    .value = "application/problem+json",
};

test "public Endpoint selects form or suffix JSON and returns typed JSON" {
    var state = AppState{};
    var client_storage: Client.Storage = .{};
    var client = try Client.init(&state, &client_storage);
    defer client.deinit() catch unreachable;

    const form_response = try client.request(.{
        .method = "POST",
        .target = "/items?page=7",
        .headers = &.{content_type_form},
        .body = "name=zig&enabled=1",
    });
    try expectResponse(
        form_response,
        "{\"page\":7,\"name\":\"zig\",\"enabled\":true,\"source\":\"form\"}",
    );

    const json_response = try client.request(.{
        .method = "POST",
        .target = "/items?page=9",
        .headers = &.{content_type_json},
        .body = "{\"name\":\"ploof\",\"enabled\":true}",
    });
    try expectResponse(
        json_response,
        "{\"page\":9,\"name\":\"ploof\",\"enabled\":true,\"source\":\"json\"}",
    );

    const html_safe_response = try client.request(.{
        .method = "POST",
        .target = "/items",
        .headers = &.{content_type_form},
        .body = "name=%3C%26%3E",
    });
    try expectResponse(
        html_safe_response,
        "{\"page\":1,\"name\":\"\\u003c\\u0026\\u003e\"," ++
            "\"enabled\":false,\"source\":\"form\"}",
    );
    try std.testing.expectEqual(@as(u8, 3), state.handler_calls);
    try std.testing.expectEqual(@as(u8, 3), state.head_calls);
    try std.testing.expectEqual(@as(u8, 3), state.after_calls);
}

test "public JSON retry stays disjoint after a caught encode failure" {
    var state = AppState{};
    var client_storage: Client.Storage = .{};
    var client = try Client.init(&state, &client_storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{ .method = "GET", .target = "/retry-json" });
    try std.testing.expectEqual(@as(u16, 200), actual.status);
    try std.testing.expectEqualStrings(
        "{\"wrapped\":\"{\\\"value\\\":\\\"source\\\"}\"}",
        actual.body,
    );
}

test "JSON retry stays disjoint across head to body workspace rebind" {
    var state = AppState{ .head_mode = .rebind_retry };
    var client_storage: Client.Storage = .{};
    var client = try Client.init(&state, &client_storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{
        .method = "POST",
        .target = "/items",
        .headers = &.{content_type_json},
        .body = "{\"name\":\"ignored\"}",
    });
    try std.testing.expectEqual(@as(u16, 200), actual.status);
    try std.testing.expectEqualStrings(
        "{\"wrapped\":\"{\\\"value\\\":\\\"head-source\\\"}\"}",
        actual.body,
    );
    try std.testing.expectEqual(@as(u8, 1), state.handler_calls);
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);
}

test "Endpoint head middleware JSON short circuit uses route workspace" {
    var state = AppState{ .head_mode = .short_json };
    var client_storage: Client.Storage = .{};
    var client = try Client.init(&state, &client_storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{
        .method = "POST",
        .target = "/items",
        .headers = &.{content_type_json},
        .body = "{\"name\":\"ignored\"}",
    });
    try std.testing.expectEqual(@as(u16, 401), actual.status);
    try std.testing.expectEqualStrings("{\"error_message\":\"token\"}", actual.body);
    try std.testing.expectEqual(@as(u8, 1), state.head_calls);
    try std.testing.expectEqual(@as(u8, 0), state.handler_calls);
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);
    try std.testing.expect(!state.after_mapped_error);
    try std.testing.expect(state.after_view_valid);
}

test "after observes discarded head JSON through internal final response" {
    var state = AppState{ .head_mode = .discard_to_internal };
    var client_storage: Client.Storage = .{};
    var client = try Client.init(&state, &client_storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{
        .method = "POST",
        .target = "/items",
        .headers = &.{content_type_form},
        .body = "name=ignored",
    });
    try std.testing.expectEqual(@as(u16, 200), actual.status);
    try std.testing.expectEqualStrings("replacement", actual.body);
    try std.testing.expect(state.after_view_valid);
}

test "Endpoint head error mapper can encode JSON before body intake" {
    var state = AppState{ .head_mode = .mapped_error };
    var client_storage: Client.Storage = .{};
    var client = try Client.init(&state, &client_storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{
        .method = "POST",
        .target = "/items",
        .headers = &.{content_type_form},
        .body = "name=ignored",
    });
    try std.testing.expectEqual(@as(u16, 403), actual.status);
    try std.testing.expectEqualStrings("{\"error_message\":\"denied\"}", actual.body);
    try std.testing.expectEqual(@as(u8, 0), state.handler_calls);
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);
    try std.testing.expect(state.after_mapped_error);
}

test "Endpoint body continuation replaces discarded head JSON binding" {
    var state = AppState{ .head_mode = .encode_continue };
    var client_storage: Client.Storage = .{};
    var client = try Client.init(&state, &client_storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{
        .method = "POST",
        .target = "/items?page=3",
        .headers = &.{content_type_form},
        .body = "name=body",
    });
    try expectResponse(
        actual,
        "{\"page\":3,\"name\":\"body\",\"enabled\":false,\"source\":\"form\"}",
    );
    try std.testing.expectEqual(@as(u8, 1), state.handler_calls);
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);
}

const head_storage_limits = runtime_config.Limits.validate(.{
    .connection_slots = 2,
    .request_slots = 2,
    .body_workspace_slots = 1,
    .chunked_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 1024,
    .pipeline_bytes_per_connection = 1024,
    .response_bytes_per_request = 2048,
    .submission_entries = 8,
    .completion_entries = 16,
});
const HeadStorage = worker_storage.Storage(App, head_storage_limits);

test "prepared head JSON owns its lease through completion and pool pressure" {
    var slab: [HeadStorage.required_bytes]u8 align(HeadStorage.slab_alignment) = undefined;
    var storage: HeadStorage = undefined;
    try storage.init(&slab);
    const first = storage.acquireConnection(.{ .value = 1 }).?;
    const second = storage.acquireConnection(.{ .value = 2 }).?;
    var state = AppState{ .head_mode = .short_json };
    const request_input = endpointInput();
    var plan = App.plan(request_input, &storage.route_search_workspace);
    const request = switch (storage.acquireRequestClassified(
        first,
        plan.body.headWorkspaceClass(),
        false,
    )) {
        .acquired => |index| index,
        else => return error.TestUnexpectedResult,
    };
    const leased = try storage.bodyWorkspace(request);
    const head = try App.prepareHeadPlannedIn(
        &state,
        &storage.requests[request].workspace,
        leased,
        storage.responseWritable(request),
        &plan,
        .{},
    );
    const prepared = switch (head) {
        .prepared => |value| value,
        .receive_body => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.endsWith(
        u8,
        prepared.bytes,
        "\r\n\r\n{\"error_message\":\"token\"}",
    ));
    try std.testing.expectEqual(@as(u16, 0), storage.bodyWorkspaceAvailable());
    try std.testing.expectEqual(
        worker_storage.AcquireResult.body_workspace_exhausted,
        storage.acquireRequestClassified(second, plan.body.headWorkspaceClass(), false),
    );
    _ = try App.complete(&storage.requests[request].workspace);
    try std.testing.expectEqual(@as(u16, 0), storage.bodyWorkspaceAvailable());
    storage.releaseRequest(first, request);
    try std.testing.expectEqual(@as(u16, 1), storage.bodyWorkspaceAvailable());
    try std.testing.expect(std.mem.allEqual(u8, leased, 0));
}

test "aborted head JSON retains then securely clears its route lease" {
    var slab: [HeadStorage.required_bytes]u8 align(HeadStorage.slab_alignment) = undefined;
    var storage: HeadStorage = undefined;
    try storage.init(&slab);
    const connection = storage.acquireConnection(.{ .value = 3 }).?;
    var state = AppState{ .head_mode = .short_json };
    const request_input = endpointInput();
    var plan = App.plan(request_input, &storage.route_search_workspace);
    const request = switch (storage.acquireRequestClassified(
        connection,
        plan.body.headWorkspaceClass(),
        false,
    )) {
        .acquired => |index| index,
        else => return error.TestUnexpectedResult,
    };
    const leased = try storage.bodyWorkspace(request);
    const head = try App.prepareHeadPlannedIn(
        &state,
        &storage.requests[request].workspace,
        leased,
        storage.responseWritable(request),
        &plan,
        .{},
    );
    switch (head) {
        .prepared => {},
        .receive_body => return error.TestUnexpectedResult,
    }
    _ = try App.abort(&storage.requests[request].workspace);
    try std.testing.expectEqual(@as(u16, 0), storage.bodyWorkspaceAvailable());
    storage.releaseRequest(connection, request);
    try std.testing.expectEqual(@as(u16, 1), storage.bodyWorkspaceAvailable());
    try std.testing.expect(std.mem.allEqual(u8, leased, 0));
}

fn endpointInput() application.Input {
    return .{
        .method = "POST",
        .path = "/items",
        .raw_target = "/items",
        .raw_path = "/items",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
    };
}

test "head JSON remains allocation free after client initialization" {
    const child = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(child));
    if (child == 0) {
        runGuardedHeadJson() catch linux.exit_group(121);
        linux.exit_group(0);
    }
    var status: u32 = 0;
    const waited = linux.waitpid(@intCast(child), &status, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(waited));
    try std.testing.expectEqual(@as(u32, 0), status & 0x7f);
    try std.testing.expectEqual(@as(u32, 0), (status >> 8) & 0xff);
}

fn runGuardedHeadJson() !void {
    var state = AppState{ .head_mode = .short_json };
    var storage: Client.Storage = .{};
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch linux.exit_group(122);
    try allocation_guard.denyAddressSpaceGrowth();
    var index: u8 = 0;
    while (index < 3) : (index += 1) {
        const actual = try client.request(.{
            .method = "POST",
            .target = "/items",
            .headers = &.{content_type_form},
            .body = "name=ignored",
        });
        if (actual.status != 401 or
            !std.mem.eql(u8, actual.body, "{\"error_message\":\"token\"}"))
        {
            return error.TestUnexpectedResult;
        }
    }
}

test "Endpoint bind failures map 400 and 413 after middleware without parser fallback" {
    var state = AppState{};
    var client_storage: Client.Storage = .{};
    var client = try Client.init(&state, &client_storage);
    defer client.deinit() catch unreachable;

    const malformed_query = try client.request(.{
        .method = "POST",
        .target = "/items?page=1&page=2",
        .headers = &.{content_type_form},
        .body = "name=zig",
    });
    try std.testing.expectEqual(@as(u16, 400), malformed_query.status);
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);

    const excessive_form = try client.request(.{
        .method = "POST",
        .target = "/items",
        .headers = &.{content_type_form},
        .body = "name=zig&enabled=1&x=2&y=3",
    });
    try std.testing.expectEqual(@as(u16, 413), excessive_form.status);
    try std.testing.expectEqual(@as(u8, 2), state.after_calls);

    const invalid_json = try client.request(.{
        .method = "POST",
        .target = "/items",
        .headers = &.{content_type_json},
        .body = "{\"name\":\"zig\",\"extra\":1}",
    });
    try std.testing.expectEqual(@as(u16, 400), invalid_json.status);
    try std.testing.expectEqual(@as(u8, 3), state.after_calls);

    const unsupported = try client.request(.{
        .method = "POST",
        .target = "/items",
        .headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
        .body = "name=zig",
    });
    try std.testing.expectEqual(@as(u16, 415), unsupported.status);

    const missing_content_type = try client.request(.{
        .method = "POST",
        .target = "/items",
        .body = "name=zig",
    });
    try std.testing.expectEqual(@as(u16, 415), missing_content_type.status);
    try std.testing.expectEqual(@as(u8, 0), state.handler_calls);
    try std.testing.expectEqual(@as(u8, 3), state.after_calls);
}

fn expectResponse(actual: testing.Response, expected_body: []const u8) !void {
    try std.testing.expectEqual(@as(u16, 200), actual.status);
    try std.testing.expectEqualStrings(expected_body, actual.body);
    try std.testing.expectEqualStrings(
        "application/json; charset=utf-8",
        actual.header("content-type").?,
    );
}

const large_data = "x" ** (74 * 1024);
const large_json_bytes = large_data.len + "{\"data\":\"\"}".len;
const LargeDefinition = endpoint.Endpoint(.{
    .response_json_bytes_max = large_json_bytes,
});
const LargeState = struct { calls: u8 = 0 };
const LargeContext = application.Context(LargeState, response.standard_head_limits);

fn largeHandler(
    context: *LargeContext,
    _: LargeDefinition.InputType,
) LargeContext.ResponseType {
    context.state.calls += 1;
    return context.json(.ok, .{ .data = large_data }) catch
        context.empty(.internal_server_error);
}

const LargeApp = application.Application(.{
    .State = LargeState,
    .routes = .{route.get("/large", LargeDefinition.handle(largeHandler))},
});
const LargeClient = testing.ConfiguredClient(LargeApp, .{
    .request_bytes_max = 256,
    .response_bytes_max = 72 * 1024,
    .response_capture_bytes_max = 80 * 1024,
});

test "testing client completes Endpoint response larger than internal staging" {
    var state = LargeState{};
    var client_storage: LargeClient.Storage = .{};
    var client = try LargeClient.init(&state, &client_storage);
    defer client.deinit() catch unreachable;

    const actual = try client.get("/large");
    try std.testing.expectEqual(@as(u16, 200), actual.status);
    try std.testing.expectEqual(@as(usize, large_json_bytes), actual.body.len);
    try std.testing.expect(std.mem.startsWith(u8, actual.body, "{\"data\":\"xxx"));
    try std.testing.expect(std.mem.endsWith(u8, actual.body, "xxx\"}"));
    try std.testing.expectEqual(@as(u8, 1), state.calls);
}

const extended_query = "&" ** query.standard_segments_max;
const ExtendedQueryDefinition = endpoint.Endpoint(.{
    .query = query.typed(struct { marker: u8 = 7 }, .{
        .segments_max = query.standard_segments_max + 1,
    }),
    .response_json_bytes_max = 32,
});
const ExtendedQueryState = struct { calls: u8 = 0 };
const ExtendedQueryContext = application.Context(
    ExtendedQueryState,
    response.standard_head_limits,
);

fn extendedQueryHandler(
    context: *ExtendedQueryContext,
    input: ExtendedQueryDefinition.InputType,
) ExtendedQueryContext.ResponseType {
    context.state.calls += 1;
    return context.json(.ok, .{ .marker = input.query.marker }) catch
        context.empty(.internal_server_error);
}

const ExtendedQueryApp = application.Application(.{
    .State = ExtendedQueryState,
    .routes = .{route.get(
        "/extended-query",
        ExtendedQueryDefinition.handle(extendedQueryHandler),
    )},
});
const ExtendedQueryClient = testing.ConfiguredClient(ExtendedQueryApp, .{
    .request_bytes_max = 2048,
    .response_bytes_max = 512,
});

test "route query segment limit above the standard admission default is reachable" {
    var state = ExtendedQueryState{};
    var client_storage: ExtendedQueryClient.Storage = .{};
    var client = try ExtendedQueryClient.init(&state, &client_storage);
    defer client.deinit() catch unreachable;

    const actual = try client.get("/extended-query?" ++ extended_query);
    try expectResponse(actual, "{\"marker\":7}");
    try std.testing.expectEqual(@as(u8, 1), state.calls);
}
