const forwarding = @import("../../../forwarding.zig");
const lifecycle = @import("../../../lifecycle.zig");
const response_head = @import("../../http1/response_head.zig");
const reactor = @import("../reactor.zig");
const server_metrics_request = @import("../server/metrics_request.zig");
const worker_init = @import("init.zig");
const worker_invariants = @import("invariants.zig");

pub fn Controller(
    comptime App: type,
    comptime Storage: type,
    comptime Reactor: type,
    comptime Error: type,
    comptime Observation: type,
    comptime forwarding_limits: forwarding.Limits,
    comptime upload_registry_present: bool,
) type {
    const ForwardingProfile = forwarding.Profile(forwarding_limits);
    const default_forwarding_profile = ForwardingProfile.init(.{}) catch unreachable;
    const MetricsRuntime = server_metrics_request.Runtime(App);
    const metrics_enabled = @hasDecl(App, "open_metrics_enabled") and
        App.open_metrics_enabled;
    return struct {
        pub fn init(
            worker: anytype,
            state: *App.StateType,
            storage: *Storage,
            io: *Reactor,
            worker_index: u16,
            listener: reactor.Socket,
            server_identity: ?response_head.ServerIdentity,
        ) Error!void {
            return initForwarding(
                worker,
                state,
                storage,
                io,
                worker_index,
                listener,
                server_identity,
                &default_forwarding_profile,
            );
        }

        pub fn initForwarding(
            worker: anytype,
            state: *App.StateType,
            storage: *Storage,
            io: *Reactor,
            worker_index: u16,
            listener: reactor.Socket,
            server_identity: ?response_head.ServerIdentity,
            forwarding_profile: *const ForwardingProfile,
        ) Error!void {
            if (comptime metrics_enabled) {
                @compileError("OpenMetrics worker initialization requires a server runtime");
            }
            return initForwardingControlled(
                worker,
                state,
                storage,
                io,
                worker_index,
                listener,
                server_identity,
                forwarding_profile,
                .init(),
                .init(),
                null,
            );
        }

        pub fn initForwardingControlled(
            worker: anytype,
            state: *App.StateType,
            storage: *Storage,
            io: *Reactor,
            worker_index: u16,
            listener: reactor.Socket,
            server_identity: ?response_head.ServerIdentity,
            forwarding_profile: *const ForwardingProfile,
            metrics_runtime: MetricsRuntime,
            observation: Observation,
            admission_controller: ?*const lifecycle.Controller,
        ) Error!void {
            try worker_init.initialize(
                App,
                upload_registry_present,
                Error,
                worker,
                state,
                storage,
                io,
                worker_index,
                listener,
                server_identity,
                forwarding_profile,
                metrics_runtime,
                observation,
                admission_controller,
            );
            worker_invariants.check(worker, Storage);
        }
    };
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}
