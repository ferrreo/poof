const std = @import("std");

const reactor = @import("../reactor.zig");
const slot_pool = @import("../slot_pool.zig");

pub const Status = struct {
    workspace_attempts: u16,
    workspace_failures: u16,
};

pub fn abortAll(
    comptime App: type,
    storage: anytype,
) Status {
    const status = abortLiveRequests(App, storage);
    clearSensitiveStorage(storage);
    return status;
}

pub fn abortAllObserved(
    comptime App: type,
    storage: anytype,
    observation: anytype,
) Status {
    var status = Status{ .workspace_attempts = 0, .workspace_failures = 0 };
    for (storage.requests, 0..) |*request, request_index| {
        if (request.phase != .live) continue;
        status.workspace_attempts += 1;
        if (observation.latched(@intCast(request_index)) or
            responseFallback(storage, request, @intCast(request_index)))
        {
            observation.finishLatched(@intCast(request_index)) catch {
                status.workspace_failures += 1;
            };
            std.crypto.secureZero(u8, std.mem.asBytes(&request.workspace));
            continue;
        }
        const outcome = App.abort(&request.workspace) catch {
            status.workspace_failures += 1;
            std.crypto.secureZero(u8, std.mem.asBytes(&request.workspace));
            continue;
        };
        observation.finish(@intCast(request_index), outcome) catch {
            status.workspace_failures += 1;
        };
        std.crypto.secureZero(u8, std.mem.asBytes(&request.workspace));
    }
    clearSensitiveStorage(storage);
    return status;
}

fn responseFallback(storage: anytype, request: anytype, request_index: u16) bool {
    if (request.connection_index >= storage.connections.len) return false;
    const connection = &storage.connections[request.connection_index];
    return connection.active_request == request_index and
        connection.receive_flags.response_fallback;
}

pub fn releaseAllRecords(storage: anytype) void {
    for (storage.requests) |*request| {
        request.* = .{ .generation = reactor.nextGeneration(request.generation) };
    }
    for (storage.connections) |*connection| {
        connection.* = .{ .generation = reactor.nextGeneration(connection.generation) };
    }
    storage.connection_pool = slot_pool.SlotPool.init(
        storage.connection_free_indices,
    ) catch unreachable;
    storage.request_pool = slot_pool.SlotPool.init(
        storage.request_free_indices,
    ) catch unreachable;
    storage.resetResponseChunks();
}

fn abortLiveRequests(comptime App: type, storage: anytype) Status {
    var status = Status{
        .workspace_attempts = 0,
        .workspace_failures = 0,
    };
    for (storage.requests) |*request| {
        if (request.phase != .live) continue;
        status.workspace_attempts += 1;
        _ = App.abort(&request.workspace) catch {
            status.workspace_failures += 1;
        };
        std.crypto.secureZero(u8, std.mem.asBytes(&request.workspace));
    }
    return status;
}

fn clearSensitiveStorage(storage: anytype) void {
    for (storage.connections) |*connection| {
        std.crypto.secureZero(
            u8,
            @constCast(connection.head_decoder.bytes()),
        );
    }
    std.crypto.secureZero(u8, storage.decoded_path_storage);
    std.crypto.secureZero(u8, storage.pipeline_storage);
    std.crypto.secureZero(u8, storage.response_storage);
    std.crypto.secureZero(u8, storage.response_chunks.storage);
    if (comptime @TypeOf(storage.html_json_scratch) == []u8) {
        std.crypto.secureZero(u8, storage.html_json_scratch);
    }
    storage.resetBodyWorkspaces();
}
