const connection_send = @import("send.zig");
const rejection_response = @import("../../http1/rejection_response.zig");
const request_head = @import("../../http1/request_head.zig");
const response_limits = @import("../../http1/limits.zig");
const response_transfer = @import("../../http1/response_transfer.zig");

pub fn Controller(comptime Error: type) type {
    return struct {
        pub fn start(
            driver: anytype,
            connection_index: u16,
            rejection: request_head.Rejection,
            now_ns: u64,
        ) Error!void {
            const connection = &driver.storage.connections[connection_index];
            const fallback = connection.receive_flags.response_fallback;
            if ((connection.active_request != null and !fallback) or
                (connection.active_request == null and fallback) or
                connection.continue_cursor != 0)
            {
                return error.StateInvariant;
            }
            if (fallback) {
                if (comptime @TypeOf(driver.observation).enabled) {
                    if (!driver.observation.latched(connection.active_request.?)) {
                        return error.StateInvariant;
                    }
                }
            }
            const output = driver.storage.pipeline(connection_index);
            const written = rejection_response.write(
                response_limits.standard_response_head_limits,
                response_transfer.standard_trailer_limits,
                output,
                rejection,
                driver.runtime_fields,
            ) catch {
                try driver.beginClose(connection_index);
                return error.ResponseSerializationFailed;
            };
            connection.pipeline_read = 0;
            connection.pipeline_write = @intCast(written.bytes.len);
            connection.pipeline_high_water = @max(
                connection.pipeline_high_water,
                connection.pipeline_write,
            );
            connection.close_after_response = true;
            connection.phase = .responding;
            try driver.operations.cancelReceive(driver.storage, connection_index);
            const runtime_limits = @TypeOf(driver.storage.*).runtime_limits;
            try driver.operations.replaceTimeout(
                driver.storage,
                connection_index,
                now_ns,
                runtime_limits.timeouts.write_stall_ns,
            );
            try driver.operations.submitSend(
                driver.storage,
                connection_index,
                try connection_send.bytes(driver.storage, connection_index),
            );
        }
    };
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}
