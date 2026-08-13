const multipart = @import("../../../multipart/upload.zig");
const reactor = @import("../reactor.zig");
const upload_file_table = @import("../upload/file_table.zig");
const support = @import("upload_request_support.zig");
const upload_metrics = @import("upload_metrics.zig");
const metrics_record = @import("upload_metrics_record.zig");

pub fn Handler(
    comptime App: type,
    comptime Error: type,
    comptime TransportCookie: type,
    comptime RequestStore: type,
    comptime Event: type,
) type {
    return struct {
        const Route = union(enum) { application, event: Event };

        pub fn route(
            controller: anytype,
            transport: anytype,
            metrics: anytype,
            worker_index: u16,
            storage: anytype,
            io: anytype,
            cookie: support.Cookie,
            request: anytype,
            state: anytype,
            entry: RequestStore.Entry,
            completion: multipart.IoCompletion,
            now_ns: u64,
            failure_identity: *?upload_metrics.Identity,
        ) Error!Route {
            if (cookie.mode == .cleanup_close) return .{ .event = try complete(
                controller,
                transport,
                metrics,
                worker_index,
                storage,
                io,
                cookie,
                request,
                state,
                entry,
                completion,
                now_ns,
                failure_identity,
            ) };
            if (state.failure == .fatal) return .{ .event = try @This().continueFatal(
                transport,
                worker_index,
                io,
                cookie.request_index,
                request,
                state,
                now_ns,
                failure_identity,
            ) };
            return .application;
        }

        pub fn continueFatal(
            transport: anytype,
            worker_index: u16,
            io: anytype,
            request_index: u16,
            request: anytype,
            state: anytype,
            now_ns: u64,
            failure_identity: *?upload_metrics.Identity,
        ) Error!Event {
            return request_cleanup.continueFatal(
                Error,
                TransportCookie,
                RequestStore,
                Event,
                transport,
                worker_index,
                io,
                request_index,
                request,
                state,
                now_ns,
                failure_identity,
            );
        }

        pub fn sweepOwned(
            transport: anytype,
            worker_index: u16,
            io: anytype,
            request_index: u16,
            request: anytype,
            state: anytype,
            now_ns: u64,
            failure_identity: *?upload_metrics.Identity,
        ) Error!bool {
            try request_cleanup.submitOwned(
                Error,
                TransportCookie,
                RequestStore,
                transport,
                worker_index,
                io,
                request_index,
                request,
                state,
                now_ns,
                failure_identity,
            );
            return state.active == 0;
        }

        fn complete(
            controller: anytype,
            transport: anytype,
            metrics: anytype,
            worker_index: u16,
            storage: anytype,
            io: anytype,
            cookie: support.Cookie,
            request: anytype,
            state: anytype,
            entry: RequestStore.Entry,
            completion: multipart.IoCompletion,
            now_ns: u64,
            failure_identity: *?upload_metrics.Identity,
        ) Error!Event {
            try request_cleanup.acceptClose(
                Error,
                transport,
                worker_index,
                cookie.request_index,
                request,
                entry,
                completion,
            );
            if (state.failure == .fatal) return request_cleanup.continueFatal(
                Error,
                TransportCookie,
                RequestStore,
                Event,
                transport,
                worker_index,
                io,
                cookie.request_index,
                request,
                state,
                now_ns,
                failure_identity,
            );
            const workspace = try support.bodyWorkspace(storage, cookie.request_index);
            return controller.advanceFinalization(
                transport,
                metrics,
                worker_index,
                storage,
                io,
                cookie.request_index,
                workspace,
                request,
                state,
                null,
                now_ns,
            );
        }

        pub fn finishTerminal(
            metrics: anytype,
            request_index: u16,
            request: anytype,
            state: anytype,
            workspace: []u8,
        ) Error!Event {
            const report = (App.__multipartFinalizationReport(
                &request.workspace,
                workspace,
            ) catch return error.ApplicationFailure) orelse return error.StateInvariant;
            try metrics_record.recordReport(
                App,
                metrics,
                &request.workspace,
                workspace,
                report,
            );
            const response_failed = request.flags.upload_response_failed;
            request.flags.upload_parser_paused = false;
            request.flags.upload_finalizing = false;
            request.flags.upload_response_failed = false;
            request.flags.upload_cancel_requested = false;
            request.flags.upload_cancel_peer = false;
            state.finalized = true;
            return .{ .request_finalized = .{
                .connection_index = request.connection_index,
                .request_index = request_index,
                .report = report,
                .response_failed = response_failed,
            } };
        }
    };
}

const request_cleanup = @This();

pub fn submitOwned(
    comptime Error: type,
    comptime TransportCookie: type,
    comptime RequestStore: type,
    transport: anytype,
    worker_index: u16,
    io: anytype,
    request_index: u16,
    request: anytype,
    state: anytype,
    now_ns: u64,
    failure_identity: *?upload_metrics.Identity,
) Error!void {
    var cursor = upload_file_table.CleanupCursor{};
    while (state.active < state.route_window) {
        const cleanup = support.nextOwnedCleanup(
            transport,
            &cursor,
            worker_index,
            request_index,
            request.generation,
        ) orelse break;
        failure_identity.* = .{
            .registry_index = cleanup.owner.registry_index,
            .instance_index = cleanup.owner.instance_index,
        };
        if (cleanup.phase == .closing and
            RequestStore.cleanupActive(state, cleanup.handle)) continue;
        if (cleanup.phase != .open or cleanup.references != 0) {
            poison(transport, cleanup.handle, cleanup.owner) catch
                return error.TransportFailure;
            return error.TransportFailure;
        }
        submitClose(
            Error,
            TransportCookie,
            RequestStore,
            transport,
            worker_index,
            io,
            request_index,
            request,
            state,
            cleanup,
            now_ns,
        ) catch |problem| {
            poison(transport, cleanup.handle, cleanup.owner) catch
                return error.TransportFailure;
            return problem;
        };
        failure_identity.* = null;
    }
}

pub fn continueFatal(
    comptime Error: type,
    comptime TransportCookie: type,
    comptime RequestStore: type,
    comptime Event: type,
    transport: anytype,
    worker_index: u16,
    io: anytype,
    request_index: u16,
    request: anytype,
    state: anytype,
    now_ns: u64,
    failure_identity: *?upload_metrics.Identity,
) Error!Event {
    if (RequestStore.applicationActive(state)) return .none;
    try submitOwned(
        Error,
        TransportCookie,
        RequestStore,
        transport,
        worker_index,
        io,
        request_index,
        request,
        state,
        now_ns,
        failure_identity,
    );
    if (state.active != 0) return .none;
    request.flags.upload_inflight = false;
    request.flags.upload_parser_paused = false;
    request.flags.upload_cancel_requested = false;
    return error.ApplicationFailure;
}

pub fn acceptClose(
    comptime Error: type,
    transport: anytype,
    worker_index: u16,
    request_index: u16,
    request: anytype,
    entry: anytype,
    completion: multipart.IoCompletion,
) Error!void {
    if (completion == .success and completion.success == .close) return;
    const owner = support.exactRequestOwner(
        worker_index,
        request_index,
        request.generation,
        entry.registry_index,
        entry.instance_index,
    );
    poison(transport, entry.handle, owner) catch return error.TransportFailure;
    return error.TransportFailure;
}

fn poison(
    transport: anytype,
    handle: multipart.FileHandle,
    owner: upload_file_table.Owner,
) !void {
    try transport.table().abandon(handle, owner);
}

fn submitClose(
    comptime Error: type,
    comptime TransportCookie: type,
    comptime RequestStore: type,
    transport: anytype,
    worker_index: u16,
    io: anytype,
    request_index: u16,
    request: anytype,
    state: anytype,
    cleanup: upload_file_table.CleanupEntry,
    now_ns: u64,
) Error!void {
    const slot = RequestStore.vacant(state, .lifecycle) catch return error.StateInvariant;
    const token = support.requestToken(
        worker_index,
        request_index,
        request,
        .file_close,
    ) catch return error.StateInvariant;
    const cookie = support.Cookie{
        .lane = .lifecycle,
        .connection_index = request.connection_index,
        .request_index = request_index,
        .request_generation = request.generation,
        .registry_index = cleanup.owner.registry_index,
        .instance_index = cleanup.owner.instance_index,
        .target = token,
        .mode = .cleanup_close,
    };
    try support.submitTarget(
        transport,
        io,
        cleanup.owner,
        token,
        @as(TransportCookie, .{ .request = cookie }),
        .{ .close = .{ .file = cleanup.handle } },
    );
    request.sequence = reactor.nextSequence(request.sequence);
    state.entries[slot] = .{
        .target = token,
        .handle = cleanup.handle,
        .kind = .close,
        .submitted_ns = now_ns,
        .registry_index = cleanup.owner.registry_index,
        .instance_index = cleanup.owner.instance_index,
        .mode = .cleanup_close,
        .active = true,
    };
    state.active += 1;
    request.flags.upload_inflight = true;
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}
