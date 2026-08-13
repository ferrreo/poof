const application_compile = @import("compile.zig");
const application_input = @import("input.zig");
const multipart_runtime = @import("multipart_runtime.zig");

pub const Error = multipart_runtime.Error || error{InvariantViolation};
const InvariantError = error{InvariantViolation};

pub fn Configured(
    comptime descriptors: anytype,
    comptime Context: type,
) type {
    return struct {
        pub fn begin(
            route_id: u16,
            selected_decoder: ?u8,
            boundary: []const u8,
            context: *Context,
            request_workspace: []u8,
        ) Error!void {
            const dispatched = dispatch(
                .begin,
                descriptors,
                0,
                route_id,
                selected_decoder,
                boundary,
                context,
                request_workspace,
                "",
            ) orelse return error.InvariantViolation;
            return dispatched;
        }

        pub fn feed(
            route_id: u16,
            selected_decoder: ?u8,
            request_workspace: []u8,
            input: []const u8,
        ) Error!void {
            const dispatched = dispatch(
                .feed,
                descriptors,
                0,
                route_id,
                selected_decoder,
                "",
                {},
                request_workspace,
                input,
            ) orelse return error.InvariantViolation;
            return dispatched;
        }

        pub fn finish(
            route_id: u16,
            selected_decoder: ?u8,
            request_workspace: []u8,
        ) Error!void {
            const dispatched = dispatch(
                .finish,
                descriptors,
                0,
                route_id,
                selected_decoder,
                "",
                {},
                request_workspace,
                "",
            ) orelse return error.InvariantViolation;
            return dispatched;
        }

        pub fn terminalSourceForRoute(
            route_id: u16,
            selected_decoder: ?u8,
            request_workspace: []u8,
        ) Error!multipart_runtime.TerminalSource {
            const dispatched = dispatch(
                .terminal_source,
                descriptors,
                0,
                route_id,
                selected_decoder,
                "",
                {},
                request_workspace,
                "",
            ) orelse return error.InvariantViolation;
            return dispatched;
        }
    };
}

const Operation = enum(u8) {
    begin,
    feed,
    finish,
    terminal_source,
};

fn dispatch(
    comptime operation: Operation,
    comptime descriptors: anytype,
    comptime first_route_id: usize,
    route_id: u16,
    selected_decoder: ?u8,
    boundary: []const u8,
    context: anytype,
    request_workspace: []u8,
    input: []const u8,
) ?Error!Result(operation) {
    comptime var current_id = first_route_id;
    inline for (descriptors) |descriptor| {
        const first = comptime current_id;
        const count = comptime switch (descriptor.kind) {
            .route, .static_dir, .static_file => 1,
            .group => application_compile.countRoutes(descriptor.children),
        };
        comptime current_id += count;
        switch (descriptor.kind) {
            .route => if (route_id == first) {
                return dispatchRoute(
                    operation,
                    @TypeOf(descriptor.handler),
                    selected_decoder,
                    boundary,
                    context,
                    request_workspace,
                    input,
                );
            },
            .static_dir, .static_file => {},
            .group => if (route_id >= first and route_id < first + count) {
                return dispatch(
                    operation,
                    descriptor.children,
                    first,
                    route_id,
                    selected_decoder,
                    boundary,
                    context,
                    request_workspace,
                    input,
                );
            },
        }
    }
    return null;
}

fn dispatchRoute(
    comptime operation: Operation,
    comptime Handler: type,
    selected_decoder: ?u8,
    boundary: []const u8,
    context: anytype,
    request_workspace: []u8,
    input: []const u8,
) Error!Result(operation) {
    if (comptime !multipartHandler(Handler)) return error.InvariantViolation;
    if (comptime Handler.definition.MultipartBodySpec.File != void) {
        return error.InvariantViolation;
    }
    const decoder_index = multipart_runtime.decoderIndex(Handler);
    if (selected_decoder != decoder_index) return error.InvariantViolation;
    const Runtime = multipart_runtime.Runtime(Handler);
    const runtime = try runtimePointer(Handler, Runtime, decoder_index, request_workspace);
    switch (operation) {
        .begin => runtime.* = try Runtime.init(boundary, context),
        .feed => try runtime.feed(input),
        .finish => try runtime.finish(),
        .terminal_source => return runtime.terminalSource(),
    }
}

fn Result(comptime operation: Operation) type {
    return switch (operation) {
        .begin, .feed, .finish => void,
        .terminal_source => multipart_runtime.TerminalSource,
    };
}

pub fn statePointer(
    comptime Handler: type,
    selected_decoder: ?u8,
    request_workspace: []u8,
) InvariantError!*Handler.MultipartState {
    if (comptime !multipartHandler(Handler)) return error.InvariantViolation;
    const decoder_index = multipart_runtime.decoderIndex(Handler);
    if (selected_decoder != decoder_index) return error.InvariantViolation;
    const Runtime = multipart_runtime.Runtime(Handler);
    const runtime = try runtimePointer(
        Handler,
        Runtime,
        decoder_index,
        request_workspace,
    );
    return runtime.state();
}

fn runtimePointer(
    comptime Handler: type,
    comptime Runtime: type,
    decoder_index: u8,
    workspace: []u8,
) InvariantError!*Runtime {
    const layout = application_input.workspaceLayout(Handler);
    if (decoder_index >= layout.body_decoders.len) return error.InvariantViolation;
    const region = layout.body_decoders[decoder_index].parse;
    if (region.bytes != @sizeOf(Runtime) or region.alignment != @alignOf(Runtime)) {
        return error.InvariantViolation;
    }
    if (region.offset > workspace.len or region.bytes > workspace.len - region.offset) {
        return error.InvariantViolation;
    }
    const bytes = workspace[region.offset..][0..region.bytes];
    if (@intFromPtr(bytes.ptr) % @alignOf(Runtime) != 0) return error.InvariantViolation;
    return @ptrCast(@alignCast(bytes.ptr));
}

fn multipartHandler(comptime Handler: type) bool {
    return @typeInfo(Handler) == .@"struct" and
        @hasDecl(Handler, "ploof_multipart_endpoint") and
        Handler.ploof_multipart_endpoint;
}
