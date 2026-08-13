const upload_metrics = @import("upload_metrics.zig");
const route_metrics = @import("upload_route_metrics.zig");
const support = @import("upload_request_support.zig");

pub fn finalizationRequired(workspace: anytype) bool {
    const Workspace = @TypeOf(workspace.*);
    if (comptime !@hasField(Workspace, "multipart_finalization")) return true;
    return workspace.multipart_finalization != .not_required;
}

pub fn bypassFinalization(context: anytype, workspace: anytype) bool {
    if (finalizationRequired(workspace)) return false;
    context.succeed();
    return true;
}

pub fn requireAsyncWindow(state: anytype) !void {
    if (!state.route_captured or state.route_window == 0) return error.StateInvariant;
}

pub fn Context(
    comptime App: type,
    comptime Storage: type,
    comptime RequestStore: type,
) type {
    const RouteTable = route_metrics.Table(App);

    return struct {
        const Self = @This();

        pub const Recorder = RouteTable.Recorder;
        pub const Snapshot = route_metrics.Snapshot;

        table: RouteTable = .{},
        failure_profile_index: ?u32 = null,
        failure_route_id: ?u16 = null,

        pub fn resetFailure(self: *Self) void {
            self.failure_profile_index = null;
            self.failure_route_id = null;
        }

        pub fn recorder(
            self: *Self,
            aggregate: *upload_metrics.Metrics,
            workspace: anytype,
            state: anytype,
        ) !Recorder {
            try self.table.captureRequest(workspace, state);
            self.failure_profile_index = state.route_profile_index;
            self.failure_route_id = state.route_id;
            return self.table.recorderForRoute(
                aggregate,
                state.route_profile_index,
                state.route_id,
            );
        }

        pub fn recorderForRequest(
            self: *Self,
            aggregate: *upload_metrics.Metrics,
            store: *RequestStore,
            storage: *Storage,
            request_index: u16,
        ) !Recorder {
            const request = try support.liveRequest(storage, request_index);
            const state = try store.request(request_index, request.generation);
            return self.recorder(aggregate, &request.workspace, state);
        }

        pub fn succeed(self: *Self) void {
            self.failure_profile_index = null;
            self.failure_route_id = null;
        }

        pub fn recordPendingFatal(
            self: *Self,
            aggregate: *upload_metrics.Metrics,
            class: upload_metrics.FatalFailureClass,
            identity: ?upload_metrics.Identity,
        ) void {
            const index = self.failure_profile_index orelse {
                aggregate.recordFatalFailure(class, identity);
                return;
            };
            const route_id = self.failure_route_id orelse {
                aggregate.recordFatalFailure(class, identity);
                self.resetFailure();
                return;
            };
            var value = self.table.recorderForRoute(aggregate, index, route_id) catch {
                aggregate.recordFatalFailure(class, identity);
                self.resetFailure();
                return;
            };
            value.recordFatalFailure(class, identity);
            self.resetFailure();
        }

        pub fn recordFatalForSlot(
            self: *Self,
            store: *const RequestStore,
            aggregate: *upload_metrics.Metrics,
            request_index: u16,
            generation: u16,
            class: upload_metrics.FatalFailureClass,
            identity: ?upload_metrics.Identity,
        ) void {
            var value = self.recorderForSlot(
                store,
                aggregate,
                request_index,
                generation,
            ) orelse {
                aggregate.recordFatalFailure(class, identity);
                return;
            };
            value.recordFatalFailure(class, identity);
        }

        pub fn recordCancellationForSlot(
            self: *Self,
            store: *const RequestStore,
            aggregate: *upload_metrics.Metrics,
            request_index: u16,
            generation: u16,
            outcome: upload_metrics.CancellationOutcome,
        ) void {
            var value = self.recorderForSlot(
                store,
                aggregate,
                request_index,
                generation,
            ) orelse {
                aggregate.recordCancellation(outcome);
                return;
            };
            value.recordCancellation(outcome);
        }

        pub fn snapshot(
            self: *const Self,
            worker_index: u16,
            route_id: u16,
        ) ?Snapshot {
            return self.table.snapshot(worker_index, route_id);
        }

        fn recorderForSlot(
            self: *Self,
            store: *const RequestStore,
            aggregate: *upload_metrics.Metrics,
            request_index: u16,
            generation: u16,
        ) ?Recorder {
            if (request_index >= store.states.len) return null;
            const state = &store.states[request_index];
            if (state.generation != generation or !state.route_captured) return null;
            return self.table.recorderForRoute(
                aggregate,
                state.route_profile_index,
                state.route_id,
            ) catch null;
        }
    };
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}
