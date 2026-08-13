const std = @import("std");

const multipart = @import("../../../multipart/upload.zig");
const upload_dispatch = @import("../../application/multipart_upload_dispatch.zig");
const upload_finalizer = @import("../../upload/finalizer.zig");
const upload_file_table = @import("../upload/file_table.zig");
const upload_transport = @import("../upload/transport.zig");
const reactor = @import("../reactor.zig");

pub const DeliveryMode = enum(u1) {
    application,
    cleanup_close,
};

pub const Cookie = struct {
    lane: upload_dispatch.Lane,
    connection_index: u16,
    request_index: u16,
    request_generation: u16,
    registry_index: u16,
    instance_index: u16,
    target: reactor.OperationToken,
    mode: DeliveryMode = .application,
};

pub fn completeSubmission(
    comptime App: type,
    workspace: anytype,
    request_workspace: []u8,
    lane: anytype,
    entry: anytype,
    completion: multipart.IoCompletion,
) anyerror!void {
    const canceled = completion == .failure and completion.failure == .canceled;
    if (comptime @hasDecl(App, "__completeCanceledUploadSubmission")) {
        if (entry.cancel_submitted and canceled) {
            return App.__completeCanceledUploadSubmission(
                workspace,
                request_workspace,
                lane,
            );
        }
    }
    return App.__completeUploadSubmission(
        workspace,
        request_workspace,
        lane,
        completion,
    );
}

pub const Failure = enum(u2) {
    none,
    sink,
    fatal,
};

pub fn Store(comptime request_capacity: usize, comptime window: usize) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            lane: upload_dispatch.Lane = .lifecycle,
            target: reactor.OperationToken = .{ .raw_value = 0 },
            handle: multipart.FileHandle = .{ .token = 0 },
            kind: multipart.IoKind = .open,
            submitted_ns: u64 = 0,
            completion_ns: ?u64 = null,
            registry_index: u16 = 0,
            instance_index: u16 = 0,
            mode: DeliveryMode = .application,
            active: bool = false,
            cancel_submitted: bool = false,
        };
        pub const Request = struct {
            entries: [window]Entry = @splat(.{}),
            generation: u16 = 0,
            route_id: u16 = 0,
            route_profile_index: u32 = 0,
            active: u8 = 0,
            route_window: u8 = 0,
            route_captured: bool = false,
            failure: Failure = .none,
            abort_cause: ?upload_finalizer.UpstreamFailure = null,
            window_full_since_ns: ?u64 = null,
            last_now_ns: u64 = 0,
            cancellation_decided: bool = false,
            finalized: bool = false,
        };

        states: [request_capacity]Request = @splat(.{}),

        pub fn request(self: *Self, index: u16, generation: u16) !*Request {
            if (index >= self.states.len) return error.InvalidRequest;
            const value = &self.states[index];
            if (value.generation == generation) return value;
            if (value.active != 0) return error.StateInvariant;
            value.* = .{ .generation = generation };
            return value;
        }

        pub fn retire(self: *Self, index: u16) !void {
            if (index >= self.states.len) return error.InvalidRequest;
            const value = &self.states[index];
            if (value.active != 0) return error.StateInvariant;
            for (value.entries) |entry| {
                if (entry.active) return error.StateInvariant;
            }
            value.* = .{};
        }

        pub fn vacant(state: *Request, lane: upload_dispatch.Lane) !usize {
            var available: ?usize = null;
            for (&state.entries, 0..) |*entry, index| {
                if (!entry.active) {
                    if (available == null) available = index;
                    continue;
                }
                if (entry.mode == .application and std.meta.eql(entry.lane, lane)) {
                    return error.StateInvariant;
                }
            }
            return available orelse error.StateInvariant;
        }

        pub fn take(state: *Request, cookie: Cookie) !Entry {
            for (&state.entries) |*entry| {
                if (!entry.active or !entry.target.eql(cookie.target)) continue;
                if (entry.mode != cookie.mode or
                    entry.registry_index != cookie.registry_index or
                    entry.instance_index != cookie.instance_index or
                    (entry.mode == .application and !std.meta.eql(entry.lane, cookie.lane)))
                {
                    return error.StateInvariant;
                }
                const value = entry.*;
                entry.* = .{};
                state.active -= 1;
                return value;
            }
            return error.StateInvariant;
        }

        pub fn applicationActive(state: *const Request) bool {
            for (state.entries) |entry| {
                if (entry.active and entry.mode == .application) return true;
            }
            return false;
        }

        pub fn cleanupActive(state: *const Request, handle: multipart.FileHandle) bool {
            for (state.entries) |entry| {
                if (entry.active and entry.mode == .cleanup_close and
                    entry.handle.eql(handle)) return true;
            }
            return false;
        }

        pub fn observeTargetCompletion(
            self: *Self,
            token: reactor.OperationToken,
            now_ns: u64,
        ) !void {
            const fields = token.fields() catch return error.StateInvariant;
            if (fields.slot_index >= self.states.len) return error.StateInvariant;
            const state = &self.states[fields.slot_index];
            if (state.generation != fields.slot_generation) return error.StateInvariant;
            for (&state.entries) |*entry| {
                if (!entry.active or !entry.target.eql(token)) continue;
                if (entry.completion_ns != null) return error.StateInvariant;
                entry.completion_ns = now_ns;
                return;
            }
            return error.StateInvariant;
        }
    };
}

pub fn liveRequest(storage: anytype, request_index: u16) !*@TypeOf(storage.requests[0]) {
    if (request_index >= storage.requests.len) return error.InvalidRequest;
    const request = &storage.requests[request_index];
    if (request.phase != .live or request.generation == 0 or request.sequence == 0) {
        return error.InvalidRequest;
    }
    if (request.connection_index >= storage.connections.len or
        storage.connections[request.connection_index].active_request != request_index)
    {
        return error.InvalidRequest;
    }
    return request;
}

pub fn bodyWorkspace(storage: anytype, request_index: u16) ![]u8 {
    return storage.bodyWorkspace(request_index) catch error.StateInvariant;
}

pub fn latchSinkFailure(request: anytype, state: anytype) void {
    state.failure = .sink;
    state.abort_cause = .framework_canceled;
    request.flags.upload_cancel_requested = true;
    request.flags.upload_response_failed = true;
}

pub fn requestOwner(
    worker_index: u16,
    request_index: u16,
    request: anytype,
    submission: upload_dispatch.Submission,
) upload_transport.Owner {
    return exactRequestOwner(
        worker_index,
        request_index,
        request.generation,
        submission.registry_index,
        submission.instance_index,
    );
}

pub fn exactRequestOwner(
    worker_index: u16,
    request_index: u16,
    generation: u16,
    registry_index: u16,
    instance_index: u16,
) upload_transport.Owner {
    return .{
        .scope = .request,
        .registry_index = registry_index,
        .instance_index = instance_index,
        .slot = .{
            .worker_index = worker_index,
            .index = request_index,
            .generation = generation,
        },
    };
}

pub fn requestToken(
    worker_index: u16,
    request_index: u16,
    request: anytype,
    kind: reactor.OperationKind,
) !reactor.OperationToken {
    return reactor.OperationToken.init(.{
        .kind = kind,
        .worker_index = worker_index,
        .slot_index = request_index,
        .slot_generation = request.generation,
        .sequence = request.sequence,
    }) catch error.StateInvariant;
}

pub fn submitTarget(
    transport: anytype,
    io: anytype,
    owner: upload_transport.Owner,
    token: reactor.OperationToken,
    cookie: anytype,
    request: multipart.IoRequest,
) !void {
    const prepared = transport.prepareTarget(owner, token, cookie, request) catch {
        return error.TransportFailure;
    };
    io.submit(prepared) catch {
        const delivery = transport.rollback(token) catch return error.TransportFailure;
        if (delivery != null) return error.TransportFailure;
        return error.BackendFailure;
    };
    transport.markSubmitted(token) catch return error.TransportFailure;
}

pub fn nextOwnedCleanup(
    transport: anytype,
    cursor: *upload_file_table.CleanupCursor,
    worker_index: u16,
    request_index: u16,
    generation: u16,
) ?upload_file_table.CleanupEntry {
    while (transport.nextCleanup(cursor)) |entry| {
        if (entry.owner.scope == .request and
            entry.owner.slot.worker_index == worker_index and
            entry.owner.slot.index == request_index and
            entry.owner.slot.generation == generation)
        {
            return entry;
        }
    }
    return null;
}

test {
    std.testing.refAllDecls(@This());
}

test "request store retirement rejects activity and clears a repeated generation" {
    const RequestStore = Store(1, 2);
    var store = RequestStore{};
    const state = try store.request(0, 7);
    state.finalized = true;
    state.entries[0].active = true;
    state.active = 1;
    try std.testing.expectError(error.StateInvariant, store.retire(0));

    state.entries[0] = .{};
    state.active = 0;
    try store.retire(0);
    const reused = try store.request(0, 7);
    try std.testing.expect(!reused.finalized);
    try std.testing.expectEqual(@as(u16, 7), reused.generation);
}
