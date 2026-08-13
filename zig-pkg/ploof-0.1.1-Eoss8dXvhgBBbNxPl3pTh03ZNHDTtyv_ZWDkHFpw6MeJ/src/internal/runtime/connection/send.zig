const std = @import("std");
const reactor = @import("../reactor.zig");
const worker_response_storage = @import("../worker/response_storage.zig");

pub const continue_response = "HTTP/1.1 100 Continue\r\n\r\n";

pub const Error = error{
    InvalidCompletion,
    StateInvariant,
};

pub const Result = union(enum) {
    stale,
    failed: reactor.CompletionError,
    partial,
    continue_complete,
    buffer_complete,
};

const Progress = union(enum) {
    continue_cursor: u8,
    request: struct {
        index: u16,
        response: worker_response_storage.SendProgress,
    },
    pipeline: u32,
};

pub fn handle(
    storage: anytype,
    connection_index: u16,
    completion: reactor.Completion,
) Error!Result {
    const connection = &storage.connections[connection_index];
    const current = if (connection.send_token) |token|
        token.eql(completion.token)
    else
        false;
    if (!current) return .stale;
    const sent = switch (completion.result) {
        .failure => |problem| {
            abandon(storage, connection_index);
            return .{ .failed = problem };
        },
        .success => |success| switch (success) {
            .send => |value| @as(usize, value),
            else => return error.InvalidCompletion,
        },
    };
    const remaining = try bytes(storage, connection_index);
    if (sent > remaining.len) return error.InvalidCompletion;
    const interim = connection.continue_cursor != 0;
    const progress = try planProgress(storage, connection_index, sent, interim);
    connection.send_token = null;
    commitProgress(storage, connection_index, progress);
    if (sent < remaining.len) return .partial;
    if (interim) return .continue_complete;
    if (requestResponseIndex(connection)) |request_index| {
        const request = &storage.requests[request_index];
        if (request.response_sent < request.response_used) return .partial;
    }
    return .buffer_complete;
}

pub fn abandon(storage: anytype, connection_index: u16) void {
    const connection = &storage.connections[connection_index];
    connection.send_token = null;
    connection.continue_cursor = 0;
}

pub fn commitDirect(
    storage: anytype,
    connection_index: u16,
    sent: usize,
) Error!Result {
    const remaining = try bytes(storage, connection_index);
    if (sent == 0 or sent > remaining.len) return error.InvalidCompletion;
    const progress = try planProgress(storage, connection_index, sent, false);
    commitProgress(storage, connection_index, progress);
    if (sent < remaining.len) return .partial;
    if (requestResponseIndex(&storage.connections[connection_index])) |request_index| {
        const request = &storage.requests[request_index];
        if (request.response_sent < request.response_used) return .partial;
    }
    return .buffer_complete;
}

pub fn bytes(storage: anytype, connection_index: u16) Error![]const u8 {
    const connection = &storage.connections[connection_index];
    if (connection.continue_cursor != 0) {
        const cursor = connection.continue_cursor;
        if (cursor > continue_response.len) return error.StateInvariant;
        const offset: usize = cursor - 1;
        return continue_response[offset..];
    }
    if (requestResponseIndex(connection)) |request_index| {
        return storage.responseSendReadable(request_index) catch error.StateInvariant;
    }
    const pipeline = storage.pipeline(connection_index);
    if (connection.pipeline_read > connection.pipeline_write) return error.StateInvariant;
    if (connection.pipeline_write > pipeline.len) return error.StateInvariant;
    return pipeline[connection.pipeline_read..connection.pipeline_write];
}

fn planProgress(
    storage: anytype,
    connection_index: u16,
    sent: usize,
    interim: bool,
) Error!Progress {
    const connection = &storage.connections[connection_index];
    if (interim) {
        const before: usize = connection.continue_cursor - 1;
        const after = std.math.add(usize, before, sent) catch return error.StateInvariant;
        if (after > continue_response.len) return error.InvalidCompletion;
        const cursor: u8 = if (after == continue_response.len)
            0
        else
            std.math.cast(u8, after + 1) orelse return error.StateInvariant;
        return .{ .continue_cursor = cursor };
    }
    if (requestResponseIndex(connection)) |request_index| {
        const response = storage.planResponseProgress(request_index, sent) catch |problem| {
            return switch (problem) {
                error.InvalidCompletion => error.InvalidCompletion,
                else => error.StateInvariant,
            };
        };
        return .{ .request = .{ .index = request_index, .response = response } };
    }
    const added = std.math.cast(u32, sent) orelse return error.StateInvariant;
    const next = std.math.add(u32, connection.pipeline_read, added) catch {
        return error.StateInvariant;
    };
    if (next > connection.pipeline_write) return error.InvalidCompletion;
    return .{ .pipeline = next };
}

fn requestResponseIndex(connection: anytype) ?u16 {
    if (connection.receive_flags.response_fallback) return null;
    return connection.active_request;
}

fn commitProgress(storage: anytype, connection_index: u16, progress: Progress) void {
    switch (progress) {
        .continue_cursor => |cursor| {
            storage.connections[connection_index].continue_cursor = cursor;
        },
        .request => |request| {
            storage.commitResponseProgress(request.index, request.response);
        },
        .pipeline => |read| storage.connections[connection_index].pipeline_read = read,
    }
}
