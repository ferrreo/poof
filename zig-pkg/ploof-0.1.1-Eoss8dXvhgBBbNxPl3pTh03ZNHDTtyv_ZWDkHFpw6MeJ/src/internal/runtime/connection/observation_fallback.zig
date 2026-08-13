const application = @import("../../../application.zig");
const request_head = @import("../../http1/request_head.zig");

pub fn Controller(comptime DriverError: type) type {
    return struct {
        pub fn start(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            outcome: application.Outcome,
            rejection: request_head.Rejection,
            now_ns: u64,
        ) DriverError!void {
            const connection = &driver.storage.connections[connection_index];
            if (connection.active_request != request_index or
                connection.receive_flags.response_fallback)
            {
                return error.StateInvariant;
            }
            driver.observation.latch(request_index, outcome) catch
                return error.StateInvariant;
            connection.receive_flags.response_fallback = true;
            try driver.startRejection(connection_index, rejection, now_ns);
        }

        pub fn complete(driver: anytype, connection_index: u16) DriverError!bool {
            const connection = &driver.storage.connections[connection_index];
            if (!connection.receive_flags.response_fallback) return false;
            const request_index = connection.active_request orelse
                return error.StateInvariant;
            driver.observation.finishLatched(request_index) catch
                return error.StateInvariant;
            connection.receive_flags.response_fallback = false;
            try driver.releaseRequest(connection_index, request_index);
            return true;
        }
    };
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}
