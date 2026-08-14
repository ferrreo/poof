const std = @import("std");
const app_state = @import("../app_state.zig");
const cookie = @import("../auth/cookie.zig");
const session = @import("../auth/session.zig");
const store = @import("../store.zig");

pub const Workspace = struct {
    data_allocator: std.heap.FixedBufferAllocator,
    output: []u8,
    io: std.Io,
    started: std.Io.Timestamp,

    pub fn init(context: *app_state.Context) error{WorkspaceUnavailable}!Workspace {
        const io = context.state.io orelse return error.WorkspaceUnavailable;
        const buffer = context.response_body orelse return error.WorkspaceUnavailable;
        const data_bytes = @min(buffer.len / 3, 128 * 1024);
        return .{
            .data_allocator = std.heap.FixedBufferAllocator.init(buffer[0..data_bytes]),
            .output = buffer[data_bytes..],
            .io = io,
            .started = std.Io.Clock.awake.now(io),
        };
    }

    pub fn allocator(self: *Workspace) std.mem.Allocator {
        return self.data_allocator.allocator();
    }

    pub fn writer(self: *Workspace) std.Io.Writer {
        return .fixed(self.output);
    }

    pub fn rendered(self: *Workspace, output_writer: *const std.Io.Writer) []const u8 {
        return self.output[0..output_writer.end];
    }

    pub fn elapsedNs(self: *const Workspace) u64 {
        const now = std.Io.Clock.awake.now(self.io);
        const ns = self.started.durationTo(now).toNanoseconds();
        if (ns <= 0) return 0;
        return @intCast(ns);
    }
};

pub fn principal(
    context: *app_state.Context,
    allocator: std.mem.Allocator,
) store.Error!?store.SessionPrincipal {
    const database = app_state.database(context) orelse return null;
    var values: [8][]const u8 = undefined;
    var count: usize = 0;
    var iterator = context.request.headers.all("cookie").iterator();
    while (iterator.next()) |value| {
        if (count == values.len) return null;
        values[count] = value;
        count += 1;
    }
    const name = session.cookieName(app_state.isProduction(context));
    const encoded = (cookie.find(values[0..count], name) catch return null) orelse return null;
    var token = session.Token.parse(encoded) catch return null;
    defer token.clear();
    return database.sessionPrincipal(allocator, token.hash()) catch |problem| switch (problem) {
        error.NotFound => null,
        else => problem,
    };
}

pub fn parseIssueId(context: *const app_state.Context) ?i64 {
    const encoded = context.request.param("id") orelse return null;
    const value = std.fmt.parseInt(i64, encoded, 10) catch return null;
    return if (value > 0) value else null;
}

pub fn redirect(
    context: *app_state.Context,
    comptime status: @import("ploof").response.Status,
    location: []const u8,
) app_state.Context.ResponseType {
    var response = context.empty(status);
    response.setHeader("location", location) catch
        return context.empty(.internal_server_error);
    return response;
}
