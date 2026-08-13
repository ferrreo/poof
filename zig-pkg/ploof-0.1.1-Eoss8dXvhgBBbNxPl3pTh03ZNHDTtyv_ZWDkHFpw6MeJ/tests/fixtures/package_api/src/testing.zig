const std = @import("std");
const ploof = @import("ploof");
const ploof_testing = @import("ploof_testing");

const State = struct { calls: u16 = 0 };
const Context = ploof.Context(State, ploof.response.standard_head_limits);

fn ping(context: *Context) Context.ResponseType {
    context.state.calls += 1;
    return context.textStatic(.ok, "pong");
}

const App = ploof.Application(.{
    .State = State,
    .routes = .{ploof.get("/ping", ping)},
});

test "fixture drives a public application through the documented testing module" {
    try std.testing.expectEqual(@as(usize, 0), ploof_testing.version.major);
    try std.testing.expectEqual(@as(usize, 1), ploof_testing.version.minor);
    const Client = ploof_testing.Client(App);
    var state = State{};
    var storage: Client.Storage = .{};
    var client = try Client.init(&state, &storage);
    const result = try client.get("/ping");
    try std.testing.expectEqual(@as(u16, 200), result.status);
    try std.testing.expectEqualStrings("pong", result.body);
    try std.testing.expectEqual(@as(u16, 1), state.calls);
    try client.deinit();
}
