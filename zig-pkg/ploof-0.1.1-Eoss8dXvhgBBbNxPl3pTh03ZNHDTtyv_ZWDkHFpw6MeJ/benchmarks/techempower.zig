const std = @import("std");
const ploof = @import("../src/ploof.zig");

const State = struct {};
const response_limits = ploof.response.HeadLimits{
    .head_bytes_max = 256,
    .field_line_bytes_max = 128,
    .fields_max = 8,
};
const Context = ploof.Context(State, response_limits);
const JsonEndpoint = ploof.Endpoint(.{ .response_json_bytes_max = 28 });

fn json(context: *Context, _: JsonEndpoint.InputType) Context.ResponseType {
    return context.json(.ok, .{ .message = "Hello, World!" }) catch unreachable;
}

fn plaintext(context: *Context) Context.ResponseType {
    return context.textStatic(.ok, "Hello, World!");
}

const App = ploof.Application(.{
    .State = State,
    .server_identity = "Ploof",
    .response_workspace_limits = response_limits,
    .response_body_bytes_max = 28,
    .routes = .{
        ploof.get("/json", JsonEndpoint.handle(json)),
        ploof.get("/plaintext", plaintext),
    },
});

const workers = 32;
const Runner = ploof.ServerRunner(App, .{
    .workers_max = workers,
    .limits = .{
        .connection_slots = 128,
        .request_slots = 128,
        .body_workspace_slots = 32,
        .receive_buffers = 128,
        .receive_buffer_bytes = 2048,
        .pipeline_bytes_per_connection = 2048,
        .response_bytes_per_request = 256,
        .response_chunk_count = 2,
        .submission_entries = 256,
        .completion_entries = 512,
    },
});

var runner: Runner align(@alignOf(Runner)) = Runner.init();

pub fn main() void {
    var state = State{};
    runner.runOrExit(&state, .{
        .listener = .{
            .address = .{ .ipv4 = .{
                .bytes = .{ 0, 0, 0, 0 },
                .port = 8080,
            } },
            .backlog = 16_384,
        },
        .worker_count = workers,
    });
}

test "TechEmpower JSON and plaintext responses" {
    var state = State{};
    const Client = ploof.__testingClient(App);
    var storage: Client.Storage = .{};
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch unreachable;

    const json_response = try client.get("/json");
    try std.testing.expectEqual(@as(u16, 200), json_response.status);
    try std.testing.expectEqualStrings(
        "{\"message\":\"Hello, World!\"}",
        json_response.body,
    );
    try std.testing.expectEqualStrings(
        "application/json; charset=utf-8",
        json_response.header("content-type").?,
    );
    try std.testing.expectEqualStrings("Ploof", json_response.header("server").?);
    try std.testing.expect(json_response.header("date") != null);

    const plaintext_response = try client.get("/plaintext");
    try std.testing.expectEqual(@as(u16, 200), plaintext_response.status);
    try std.testing.expectEqualStrings("Hello, World!", plaintext_response.body);
    try std.testing.expectEqualStrings(
        "text/plain; charset=utf-8",
        plaintext_response.header("content-type").?,
    );
}
