const std = @import("std");

pub fn StateTuple(comptime middleware: anytype) type {
    var fields: [middleware.len]type = undefined;
    inline for (middleware, 0..) |item, index| fields[index] = @TypeOf(item).State;
    return std.meta.Tuple(&fields);
}

pub fn maximumStateBytes(
    comptime descriptors: anytype,
    comptime inherited: anytype,
    comptime app_middleware: anytype,
) usize {
    var maximum = @sizeOf(StateTuple(app_middleware));
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route, .static_dir, .static_file => {
            const States = StateTuple(app_middleware ++ inherited ++ descriptor.middleware);
            maximum = @max(maximum, @sizeOf(States));
        },
        .group => maximum = @max(maximum, maximumStateBytes(
            descriptor.children,
            inherited ++ descriptor.middleware,
            app_middleware,
        )),
    };
    return maximum;
}

pub fn maximumStateAlignment(
    comptime descriptors: anytype,
    comptime inherited: anytype,
    comptime app_middleware: anytype,
) usize {
    var maximum = @alignOf(StateTuple(app_middleware));
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route, .static_dir, .static_file => {
            const States = StateTuple(app_middleware ++ inherited ++ descriptor.middleware);
            maximum = @max(maximum, @alignOf(States));
        },
        .group => maximum = @max(maximum, maximumStateAlignment(
            descriptor.children,
            inherited ++ descriptor.middleware,
            app_middleware,
        )),
    };
    return maximum;
}
