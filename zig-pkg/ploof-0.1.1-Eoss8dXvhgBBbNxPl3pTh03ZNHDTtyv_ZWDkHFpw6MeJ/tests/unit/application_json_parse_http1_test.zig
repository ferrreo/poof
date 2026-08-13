const std = @import("std");
const application = @import("../../src/application.zig");
const endpoint = @import("../../src/endpoint.zig");
const json = @import("../../src/json.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const testing = @import("../../src/testing.zig");

var root_calls = std.atomic.Value(u32).init(0);
var nested_calls = std.atomic.Value(u32).init(0);

const NestedValue = struct {
    value: u16,

    pub fn jsonParse(parser: anytype) json.ParseError!@This() {
        _ = nested_calls.fetchAdd(1, .monotonic);
        const wire = try parser.parse(struct { value: u16 });
        return .{ .value = wire.value };
    }
};

const Accepted = struct {
    label: []const u8,
    nested: NestedValue,
    values: []const u16,

    pub fn jsonParse(parser: anytype) json.ParseError!@This() {
        _ = root_calls.fetchAdd(1, .monotonic);
        const object = try parser.object();
        const label = object.get("label") orelse return error.InvalidValue;
        const nested = object.get("nested") orelse return error.InvalidValue;
        const values = object.get("values") orelse return error.InvalidValue;
        return .{
            .label = try label.parse([]const u8),
            .nested = try nested.parse(NestedValue),
            .values = try values.parse([]const u16),
        };
    }
};

const Rejected = struct {
    pub fn jsonParse(parser: anytype) json.ParseError!@This() {
        _ = try parser.cursor();
        return error.InvalidValue;
    }
};

const ForgedInternal = struct {
    pub fn jsonParse(_: anytype) json.ParseError!@This() {
        return error.PlanMismatch;
    }
};

const ForgedCapacity = struct {
    pub fn jsonParse(_: anytype) json.ParseError!@This() {
        return error.WorkspaceTooSmall;
    }
};

const Exhausted = struct {
    bytes: []u8,

    pub fn jsonParse(parser: anytype) json.ParseError!@This() {
        return .{ .bytes = try parser.parse([]u8) };
    }
};

const AcceptedEndpoint = endpoint.Endpoint(.{
    .body = json.typed(Accepted, .{
        .encoded_wire_bytes_max = 256,
        .decoded_bytes_max = 256,
        .parse_memory_bytes_max = 4096,
    }),
    .response_json_bytes_max = 128,
});
const RejectedEndpoint = endpoint.Endpoint(.{ .body = json.typed(Rejected, .{
    .encoded_wire_bytes_max = 32,
    .decoded_bytes_max = 32,
    .parse_memory_bytes_max = 128,
}) });
const ForgedInternalEndpoint = endpoint.Endpoint(.{
    .body = json.typed(ForgedInternal, .{
        .encoded_wire_bytes_max = 32,
        .decoded_bytes_max = 32,
        .parse_memory_bytes_max = 128,
    }),
});
const ForgedCapacityEndpoint = endpoint.Endpoint(.{
    .body = json.typed(ForgedCapacity, .{
        .encoded_wire_bytes_max = 32,
        .decoded_bytes_max = 32,
        .parse_memory_bytes_max = 128,
    }),
});
const ExhaustedEndpoint = endpoint.Endpoint(.{ .body = json.typed(Exhausted, .{
    .encoded_wire_bytes_max = 64,
    .decoded_bytes_max = 64,
    .parse_memory_bytes_max = 32,
}) });

const State = struct {
    handler_calls: u8 = 0,
    after_calls: u8 = 0,
};
const Context = application.Context(State, response.standard_head_limits);
const Response = Context.ResponseType;

fn acceptedHandler(context: *Context, input: AcceptedEndpoint.InputType) Response {
    context.state.handler_calls += 1;
    return context.json(.ok, .{
        .label = input.body.label,
        .nested = input.body.nested.value,
        .count = input.body.values.len,
    }) catch context.empty(.internal_server_error);
}

fn rejectedHandler(context: *Context, _: RejectedEndpoint.InputType) Response {
    context.state.handler_calls += 1;
    return context.empty(.internal_server_error);
}

fn forgedInternalHandler(
    context: *Context,
    _: ForgedInternalEndpoint.InputType,
) Response {
    context.state.handler_calls += 1;
    return context.empty(.internal_server_error);
}

fn forgedCapacityHandler(
    context: *Context,
    _: ForgedCapacityEndpoint.InputType,
) Response {
    context.state.handler_calls += 1;
    return context.empty(.internal_server_error);
}

fn exhaustedHandler(context: *Context, _: ExhaustedEndpoint.InputType) Response {
    context.state.handler_calls += 1;
    return context.empty(.internal_server_error);
}

const ObserveAfter = struct {
    pub const State = void;

    pub fn init(_: ObserveAfter) @This().State {
        return {};
    }

    pub fn head(
        _: ObserveAfter,
        _: *Context,
        _: *@This().State,
    ) ?Response {
        return null;
    }

    pub fn after(
        _: ObserveAfter,
        context: *const Context,
        _: *@This().State,
        _: application.Outcome,
    ) void {
        context.state.after_calls += 1;
    }
};

const App = application.Application(.{
    .State = State,
    .middleware = .{ObserveAfter{}},
    .routes = .{
        route.post("/accepted", AcceptedEndpoint.handle(acceptedHandler)),
        route.post("/rejected", RejectedEndpoint.handle(rejectedHandler)),
        route.post("/forged-internal", ForgedInternalEndpoint.handle(forgedInternalHandler)),
        route.post("/forged-capacity", ForgedCapacityEndpoint.handle(forgedCapacityHandler)),
        route.post("/exhausted", ExhaustedEndpoint.handle(exhaustedHandler)),
    },
});

const Client = testing.ConfiguredClient(App, .{
    .request_bytes_max = 1024,
    .response_bytes_max = 1024,
    .response_capture_bytes_max = 1024,
});

const content_type_json = testing.Request.Header{
    .name = "Content-Type",
    .value = "application/json",
};

test "public Endpoint runs structured jsonParse once and retains escaped data" {
    root_calls.store(0, .monotonic);
    nested_calls.store(0, .monotonic);
    var state = State{};
    var storage: Client.Storage = .{};
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const actual = try client.request(.{
        .method = "POST",
        .target = "/accepted",
        .headers = &.{content_type_json},
        .body =
        \\{"label":"zig\u0021","nested":{"value":7},"values":[1,2,3]}
        ,
    });
    try std.testing.expectEqual(@as(u16, 200), actual.status);
    try std.testing.expectEqualStrings(
        "{\"label\":\"zig!\",\"nested\":7,\"count\":3}",
        actual.body,
    );
    try std.testing.expectEqual(@as(u32, 1), root_calls.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), nested_calls.load(.monotonic));
    try std.testing.expectEqual(@as(u8, 1), state.handler_calls);
    try std.testing.expectEqual(@as(u8, 1), state.after_calls);
}

test "public Endpoint normalizes hook failures and preserves real exhaustion" {
    var state = State{};
    var storage: Client.Storage = .{};
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const cases = [_]struct {
        target: []const u8,
        body: []const u8,
        status: u16,
    }{
        .{ .target = "/rejected", .body = "null", .status = 400 },
        .{ .target = "/forged-internal", .body = "null", .status = 400 },
        .{ .target = "/forged-capacity", .body = "null", .status = 400 },
        .{
            .target = "/exhausted",
            .body = "\"abcdefghijklmnopqrstuvwxyz\"",
            .status = 413,
        },
    };
    for (cases) |case| {
        const actual = try client.request(.{
            .method = "POST",
            .target = case.target,
            .headers = &.{content_type_json},
            .body = case.body,
        });
        try std.testing.expectEqual(case.status, actual.status);
    }
    try std.testing.expectEqual(@as(u8, 0), state.handler_calls);
    try std.testing.expectEqual(@as(u8, cases.len), state.after_calls);
}
