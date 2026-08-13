const std = @import("std");
const poof = @import("poof");
const ploof_testing = @import("ploof_testing");

test "liveness endpoint is available" {
    const Client = ploof_testing.Client(poof.TestApp);
    var state = poof.State{};
    var storage: Client.Storage = .{};
    var client = try Client.init(&state, &storage);
    defer client.deinit() catch {};

    const response = try client.get("/live");
    try std.testing.expectEqual(@as(u16, 204), response.status);
    try std.testing.expectEqualStrings("", response.body);
}
