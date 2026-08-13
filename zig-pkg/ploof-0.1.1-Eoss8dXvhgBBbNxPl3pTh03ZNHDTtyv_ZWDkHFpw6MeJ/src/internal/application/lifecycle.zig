const std = @import("std");
const application_compile = @import("compile.zig");

pub fn runAfter(
    comptime middleware: anytype,
    workspace: anytype,
    outcome: anytype,
) void {
    const States = application_compile.StateTuple(middleware);
    const states: *States = @ptrCast(&workspace.middleware_state);
    inline for (0..middleware.len) |reverse| {
        const index = middleware.len - 1 - reverse;
        if (workspace.initialized_middleware &
            (@as(u64, 1) << @intCast(index)) != 0)
        {
            const item = middleware[index];
            if (@hasDecl(@TypeOf(item), "after")) {
                item.after(&workspace.context, &states[index], outcome);
            }
        }
    }
    if (comptime @hasField(@TypeOf(workspace.context), "csrf_request")) {
        workspace.context.csrf_request = null;
    }
}

pub fn finishSelected(
    comptime descriptors: anytype,
    comptime inherited: anytype,
    comptime application_middleware: anytype,
    comptime first_route_id: usize,
    target_route_id: u16,
    workspace: anytype,
    outcome: anytype,
) bool {
    comptime var route_id = first_route_id;
    inline for (descriptors) |descriptor| {
        const first = comptime route_id;
        const count = comptime switch (descriptor.kind) {
            .route, .static_dir, .static_file => 1,
            .group => application_compile.countRoutes(descriptor.children),
        };
        comptime {
            route_id += count;
        }
        switch (descriptor.kind) {
            .route, .static_dir, .static_file => if (target_route_id == first) {
                runAfter(
                    application_middleware ++ inherited ++ descriptor.middleware,
                    workspace,
                    outcome,
                );
                return true;
            },
            .group => if (target_route_id >= first and target_route_id < first + count) {
                return finishSelected(
                    descriptor.children,
                    inherited ++ descriptor.middleware,
                    application_middleware,
                    first,
                    target_route_id,
                    workspace,
                    outcome,
                );
            },
        }
    }
    return false;
}

test {
    std.testing.refAllDecls(@This());
}
