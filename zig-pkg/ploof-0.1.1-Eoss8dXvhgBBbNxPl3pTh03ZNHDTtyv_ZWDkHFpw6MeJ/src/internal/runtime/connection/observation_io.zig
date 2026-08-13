const connection_send = @import("send.zig");
const reactor = @import("../reactor.zig");

pub fn Controller(comptime DriverError: type) type {
    return struct {
        pub fn recordResponseWire(
            driver: anytype,
            connection_index: u16,
            completion: reactor.Completion,
            result: connection_send.Result,
        ) DriverError!void {
            switch (result) {
                .stale, .failed => return,
                .partial, .continue_complete, .buffer_complete => {},
            }
            const request_index = driver.storage.connections[connection_index]
                .active_request orelse return;
            const count = switch (completion.result) {
                .success => |success| switch (success) {
                    .send => |sent| sent,
                    else => return error.InvalidCompletion,
                },
                .failure => return error.InvalidCompletion,
            };
            driver.observation.addResponseWire(request_index, count) catch
                return error.StateInvariant;
        }
    };
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}
