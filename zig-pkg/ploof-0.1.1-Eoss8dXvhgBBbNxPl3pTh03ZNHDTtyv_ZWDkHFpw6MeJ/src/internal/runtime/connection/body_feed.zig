const std = @import("std");
const application = @import("../../../application.zig");
const body = @import("../../../body.zig");
const connection_body = @import("body.zig");
const connection_body_runtime = @import("body_runtime.zig");
const connection_pipeline = @import("pipeline.zig");
const request_head = @import("../../http1/request_head.zig");

pub fn acquireBody(
    comptime App: type,
    comptime DriverError: type,
    driver: anytype,
    connection_index: u16,
    request_index: u16,
    plan: application.BodyPlan,
    requires_chunked: bool,
    now_ns: u64,
) DriverError!bool {
    switch (driver.storage.acquireBodyForPlan(request_index, plan, requires_chunked)) {
        .acquired => return true,
        .body_workspace_exhausted,
        .chunked_workspace_exhausted,
        => {
            const outcome = App.abort(
                &driver.storage.requests[request_index].workspace,
            ) catch {
                try driver.beginClose(connection_index);
                return error.StateInvariant;
            };
            try driver.startObservedFallback(
                connection_index,
                request_index,
                outcome,
                .{ .status = .service_unavailable },
                now_ns,
            );
            return false;
        },
        .invalid_request => {
            try driver.beginClose(connection_index);
            return error.StateInvariant;
        },
    }
}

pub fn startFixed(
    comptime App: type,
    comptime DriverError: type,
    driver: anytype,
    request_index: u16,
    plan: application.BodyPlan,
    multipart_boundary: ?[]const u8,
    length: u64,
    kind: body.Kind,
) DriverError!connection_body.FixedIdentity {
    const receiver = switch (connection_body.FixedIdentity.init(
        length,
        plan.encoded_wire_bytes_max,
        plan.decoded_bytes_max,
    )) {
        .accepted => |value| value,
        .over_limit => return error.StateInvariant,
    };
    if (plan.decoderKind() == .multipart) {
        connection_body_runtime.startMultipartFixed(
            App,
            driver.storage,
            request_index,
            receiver,
            multipart_boundary orelse return error.StateInvariant,
        ) catch return error.StateInvariant;
    } else {
        connection_body_runtime.startFixed(
            driver.storage,
            request_index,
            receiver,
            kind,
        ) catch return error.StateInvariant;
    }
    return receiver;
}

pub fn appendChunkData(
    comptime App: type,
    comptime DriverError: type,
    driver: anytype,
    request_index: u16,
    data: []const u8,
) DriverError!connection_body_runtime.FeedResult {
    const result = if (requestIsMultipart(driver.storage, request_index))
        connection_body_runtime.appendMultipartChunk(
            App,
            driver.storage,
            request_index,
            data,
        ) catch return error.StateInvariant
    else result: {
        connection_body_runtime.appendChunk(
            driver.storage,
            request_index,
            data,
        ) catch return error.StateInvariant;
        break :result connection_body_runtime.FeedResult{
            .consumed = data.len,
            .event = .need_more,
        };
    };
    return result;
}

pub fn preserveTail(
    comptime DriverError: type,
    driver: anytype,
    connection_index: u16,
    tail: []const u8,
    source: anytype,
) DriverError!bool {
    if (source == .pipeline or tail.len == 0) return true;
    connection_pipeline.append(
        driver.storage,
        connection_index,
        tail,
    ) catch |problem| switch (problem) {
        error.PipelineFull => {
            try driver.beginClose(connection_index);
            return false;
        },
        error.StateInvariant => return error.StateInvariant,
    };
    return true;
}

pub fn consumeSource(
    comptime DriverError: type,
    driver: anytype,
    connection_index: u16,
    consumed: usize,
    source: anytype,
) DriverError!void {
    const request_index = driver.storage.connections[connection_index]
        .active_request orelse return error.StateInvariant;
    const next = try nextPipelineRead(DriverError, driver, connection_index, consumed, source);
    driver.observation.addRequestWire(request_index, consumed) catch
        return error.StateInvariant;
    applyPipelineRead(driver, connection_index, next);
}

pub fn advanceSource(
    comptime DriverError: type,
    driver: anytype,
    connection_index: u16,
    consumed: usize,
    source: anytype,
) DriverError!void {
    const next = try nextPipelineRead(DriverError, driver, connection_index, consumed, source);
    applyPipelineRead(driver, connection_index, next);
}

fn nextPipelineRead(
    comptime DriverError: type,
    driver: anytype,
    connection_index: u16,
    consumed: usize,
    source: anytype,
) DriverError!?u32 {
    if (source == .borrowed) return null;
    const connection = &driver.storage.connections[connection_index];
    const added = std.math.cast(u32, consumed) orelse return error.StateInvariant;
    const next = std.math.add(
        u32,
        connection.pipeline_read,
        added,
    ) catch return error.StateInvariant;
    if (next > connection.pipeline_write) return error.StateInvariant;
    return next;
}

fn applyPipelineRead(driver: anytype, connection_index: u16, next: ?u32) void {
    const selected = next orelse return;
    const connection = &driver.storage.connections[connection_index];
    connection.pipeline_read = selected;
    if (selected == connection.pipeline_write) {
        connection.pipeline_read = 0;
        connection.pipeline_write = 0;
    }
}

pub fn requestIsMultipart(storage: anytype, request_index: u16) bool {
    const Body = @TypeOf(storage.requests[request_index].body);
    if (comptime @hasField(Body, "multipart")) {
        return storage.requests[request_index].body.multipart;
    }
    return false;
}

pub fn eventStatus(event: connection_body_runtime.Event) ?request_head.Status {
    return switch (event) {
        .invalid_utf8, .invalid_input => .bad_request,
        .input_too_large => .payload_too_large,
        .unsupported_media => .unsupported_media_type,
        .need_more, .upload_paused, .prepared => null,
    };
}
