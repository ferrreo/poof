const std = @import("std");
const connection_admission = @import("admission.zig");

pub const Error = error{
    PipelineFull,
    StateInvariant,
};

pub fn validate(
    storage: anytype,
    connection_index: u16,
) error{StateInvariant}!void {
    const connection = &storage.connections[connection_index];
    const pipeline = storage.pipeline(connection_index);
    if (connection.pipeline_read > connection.pipeline_write) {
        return error.StateInvariant;
    }
    if (connection.pipeline_write > pipeline.len) return error.StateInvariant;
}

pub fn append(
    storage: anytype,
    connection_index: u16,
    bytes: []const u8,
) Error!void {
    if (bytes.len == 0) return;
    try validate(storage, connection_index);
    const connection = &storage.connections[connection_index];
    const pipeline = storage.pipeline(connection_index);
    const unread = connection.pipeline_write - connection.pipeline_read;
    if (bytes.len > pipeline.len - unread) return error.PipelineFull;
    if (connection.pipeline_read != 0 and bytes.len > pipeline.len - connection.pipeline_write) {
        std.mem.copyForwards(
            u8,
            pipeline[0..unread],
            pipeline[connection.pipeline_read..connection.pipeline_write],
        );
        connection.pipeline_read = 0;
        connection.pipeline_write = unread;
    }
    const write_start: usize = connection.pipeline_write;
    @memcpy(pipeline[write_start..][0..bytes.len], bytes);
    connection.pipeline_write += @intCast(bytes.len);
    connection.pipeline_high_water = @max(
        connection.pipeline_high_water,
        connection.pipeline_write,
    );
}

pub fn prepend(
    storage: anytype,
    connection_index: u16,
    bytes: []const u8,
) Error!void {
    if (bytes.len == 0) return;
    try validate(storage, connection_index);
    const connection = &storage.connections[connection_index];
    const pipeline = storage.pipeline(connection_index);
    const unread = connection.pipeline_write - connection.pipeline_read;
    if (bytes.len > pipeline.len - unread) return error.PipelineFull;
    std.mem.copyBackwards(
        u8,
        pipeline[bytes.len..][0..unread],
        pipeline[connection.pipeline_read..connection.pipeline_write],
    );
    @memcpy(pipeline[0..bytes.len], bytes);
    connection.pipeline_read = 0;
    connection.pipeline_write = @intCast(bytes.len + unread);
    connection.pipeline_high_water = @max(
        connection.pipeline_high_water,
        connection.pipeline_write,
    );
}

pub fn consume(
    comptime DriverError: type,
    driver: anytype,
    connection_index: u16,
    source: anytype,
    now_ns: u64,
) DriverError!void {
    try validate(driver.storage, connection_index);
    const connection = &driver.storage.connections[connection_index];
    const pipeline = driver.storage.pipeline(connection_index);
    if (connection.pipeline_read >= connection.pipeline_write) {
        return error.StateInvariant;
    }
    const bytes = pipeline[connection.pipeline_read..connection.pipeline_write];
    const result = connection.head_decoder.feed(bytes);
    const consumed = std.math.cast(u32, result.consumed) orelse {
        return error.StateInvariant;
    };
    connection.pipeline_read = std.math.add(
        u32,
        connection.pipeline_read,
        consumed,
    ) catch return error.StateInvariant;
    if (connection.pipeline_read > connection.pipeline_write) {
        return error.StateInvariant;
    }
    if (connection.pipeline_read == connection.pipeline_write) {
        connection.pipeline_read = 0;
        connection.pipeline_write = 0;
    }
    try connection_admission.finishHead(
        DriverError,
        driver,
        connection_index,
        result.state,
        bytes[result.consumed..],
        source,
        now_ns,
    );
}

pub fn continueAfterResponse(
    comptime DriverError: type,
    comptime GzipTransport: type,
    comptime runtime_limits: anytype,
    driver: anytype,
    connection_index: u16,
    pipeline_source: anytype,
    now_ns: u64,
) DriverError!void {
    const connection = &driver.storage.connections[connection_index];
    if (connection.phase != .responding or connection.active_request != null or
        connection.send_token != null)
    {
        return;
    }
    if (connection.close_after_response) {
        try driver.beginClose(connection_index);
        return;
    }
    const retained_operations = @as(u16, @intFromBool(connection.timeout_token != null)) +
        @as(u16, @intFromBool(connection.receive_token != null));
    if (connection.inflight_operations != retained_operations) {
        return;
    }
    try validate(driver.storage, connection_index);
    driver.storage.reuseConnection(connection_index);
    if (connection.pipeline_read < connection.pipeline_write) {
        connection.phase = .reused_head;
        try driver.operations.retargetTimeout(
            driver.storage,
            connection_index,
            now_ns,
            runtime_limits.timeouts.reused_head_progress_ns,
        );
        try consume(
            DriverError,
            driver,
            connection_index,
            pipeline_source,
            now_ns,
        );
        if (GzipTransport.pipelineMayReceive(connection) and connection.receive_token == null) {
            try driver.operations.submitReceiveForPhase(driver.storage, connection_index);
        }
    } else {
        connection.pipeline_read = 0;
        connection.pipeline_write = 0;
        if (connection.receive_token == null) {
            try driver.operations.submitReceiveForPhase(driver.storage, connection_index);
        }
        try driver.operations.retargetTimeout(
            driver.storage,
            connection_index,
            now_ns,
            runtime_limits.timeouts.keepalive_idle_ns,
        );
    }
}

const TestStorage = struct {
    const Connection = struct {
        pipeline_read: u32 = 0,
        pipeline_write: u32 = 0,
        pipeline_high_water: u32 = 0,
    };

    connections: [1]Connection = .{.{}},
    bytes: [8]u8 = @splat(0xaa),

    fn pipeline(self: *TestStorage, connection_index: u16) []u8 {
        std.debug.assert(connection_index == 0);
        return &self.bytes;
    }
};

test "pipeline append rejects invalid cursors before arithmetic" {
    const unchanged = [_]u8{0xaa} ** 8;
    var storage = TestStorage{};
    storage.connections[0].pipeline_read = 2;
    storage.connections[0].pipeline_write = 1;
    try std.testing.expectError(error.StateInvariant, append(&storage, 0, "x"));
    try std.testing.expectEqualSlices(u8, &unchanged, &storage.bytes);

    storage.connections[0].pipeline_read = 0;
    storage.connections[0].pipeline_write = 9;
    try std.testing.expectError(error.StateInvariant, append(&storage, 0, "x"));
    try std.testing.expectEqualSlices(u8, &unchanged, &storage.bytes);
}
