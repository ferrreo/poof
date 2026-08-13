const std = @import("std");
const ploof = @import("ploof");

const State = struct {};
const Context = ploof.Context(State, ploof.response.standard_head_limits);
const Handler = struct {
    fn ping(context: *Context) Context.ResponseType {
        return context.textStatic(.ok, "pong");
    }
};
const App = ploof.Application(.{
    .State = State,
    .routes = .{ploof.get("/ping", Handler.ping)},
});
const Concrete = ploof.Server(App, .{});

var server: Concrete = undefined;

pub const panic = std.debug.FullPanic(panicExit);

pub fn main() void {
    server.address_identity = @intFromPtr(&server) + @alignOf(Concrete);
    server.start_attempted.store(true, .release);
    _ = server.phase();
    std.process.exit(72);
}

fn panicExit(message: []const u8, _: ?usize) noreturn {
    if (!std.mem.eql(u8, message, "PLOOF Server moved after start")) {
        std.process.exit(71);
    }
    std.process.exit(73);
}
