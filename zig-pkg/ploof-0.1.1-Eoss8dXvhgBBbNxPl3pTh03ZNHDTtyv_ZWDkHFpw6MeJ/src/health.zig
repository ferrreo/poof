const std = @import("std");

const lifecycle = @import("lifecycle.zig");

pub fn Liveness(comptime Context: type) type {
    validateContext(Context);
    return struct {
        pub fn handle(context: *Context) Context.ResponseType {
            return context.empty(.no_content);
        }
    };
}

pub fn Readiness(
    comptime Context: type,
    comptime readinessFor: anytype,
) type {
    validateContext(Context);
    return struct {
        pub fn handle(context: *Context) Context.ResponseType {
            const readiness = readinessFor(context.state);
            return if (readiness.isReady())
                context.empty(.no_content)
            else
                context.empty(.service_unavailable);
        }
    };
}

fn validateContext(comptime Context: type) void {
    if (@typeInfo(Context) != .@"struct" or
        !@hasDecl(Context, "ApplicationState") or
        !@hasDecl(Context, "ResponseType"))
    {
        @compileError("PLOOF-E6400 health handler requires a Ploof Context type");
    }
}

test "liveness is unconditional and readiness follows irreversible lifecycle" {
    const application = @import("application.zig");
    const response = @import("response.zig");
    const route = @import("route.zig");
    const State = struct { lifecycle: lifecycle.Controller = .{} };
    const Context = application.Context(State, response.standard_head_limits);
    const Access = struct {
        fn controller(state: *State) *const lifecycle.Controller {
            return &state.lifecycle;
        }
    };
    const Live = Liveness(Context);
    const Ready = Readiness(Context, Access.controller);
    const App = application.Application(.{
        .State = State,
        .routes = .{
            route.get("/live", Live.handle),
            route.get("/ready", Ready.handle),
        },
    });
    var state = State{};
    var workspace = response.Workspace(response.standard_head_limits){};
    var context = Context{
        .state = &state,
        .request = undefined,
        .response_workspace = &workspace,
    };

    try std.testing.expectEqual(.no_content, Live.handle(&context).status);
    try std.testing.expectEqual(.service_unavailable, Ready.handle(&context).status);
    _ = state.lifecycle.markReady();
    try std.testing.expectEqual(.no_content, Ready.handle(&context).status);
    _ = state.lifecycle.beginDrain();
    try std.testing.expectEqual(.service_unavailable, Ready.handle(&context).status);
    try std.testing.expectEqual(@as(usize, 2), App.route_definitions.len);
}
