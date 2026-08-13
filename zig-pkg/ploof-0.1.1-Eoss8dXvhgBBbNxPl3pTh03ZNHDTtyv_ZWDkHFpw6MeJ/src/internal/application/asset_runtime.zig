const std = @import("std");
const application_assets = @import("assets.zig");
const application_generated = @import("generated.zig");
const application_response_output = @import("response_output.zig");
const application_types = @import("types.zig");
const asset_response = @import("../asset/response.zig");
const route_graph = @import("../route_graph.zig");

pub fn Runtime(
    comptime config: anytype,
    comptime logical: anytype,
    comptime app_middleware: anytype,
    comptime application_route_count: usize,
    comptime asset_count: usize,
    comptime Context: type,
    comptime Workspace: type,
    comptime Input: type,
    comptime Pipeline: type,
    comptime Bodyless: type,
    comptime server_identity: anytype,
    comptime PrepareError: type,
) type {
    return struct {
        pub fn prepare(
            asset_index: usize,
            workspace: *Workspace,
            input: Input,
            output: []u8,
            close_if_prepared: bool,
        ) PrepareError!application_response_output.Prepared {
            if (comptime asset_count == 0) unreachable;
            const record = config.assets.generated.assets[asset_index];
            const built = asset_response.prepare(
                logical,
                output,
                record,
                .{
                    .method = if (std.mem.eql(u8, input.method, "HEAD")) .head else .get,
                    .accept_encoding = input.accept_encoding,
                    .date = input.date,
                    .connection_close = input.connection_close or close_if_prepared,
                },
                input.headers,
                server_identity,
            ) catch |err| {
                workspace.lifecycle = .idle;
                return err;
            };
            workspace.initialized_middleware = 0;
            workspace.pending = .{
                .route = .{ .asset = {} },
                .status = built.status,
                .mapped_error = false,
                .success_transport = .completed,
            };
            workspace.lifecycle = .pending;
            return .{
                .source = .{ .borrowed_static = .{ .head = built.head, .body = built.body } },
                .bytes = built.head,
                .status = built.status,
                .close_connection = built.close_connection,
                .coding_outcome = if (built.coding) |coding| switch (coding) {
                    .identity => .identity_negotiated,
                    .gzip => .gzip,
                } else .not_acceptable,
            };
        }

        pub fn materializeBorrowed(
            prepared: *application_response_output.Prepared,
            output: []u8,
        ) error{OutputTooSmall}!void {
            const borrowed = switch (prepared.source) {
                .borrowed_static => |value| value,
                else => return,
            };
            if (borrowed.body.len == 0) {
                prepared.source = .{ .contiguous_wire = borrowed.head };
                return;
            }
            if (@intFromPtr(borrowed.head.ptr) != @intFromPtr(output.ptr) or
                borrowed.head.len > output.len or
                borrowed.body.len > output.len - borrowed.head.len)
            {
                return error.OutputTooSmall;
            }
            @memcpy(output[borrowed.head.len..][0..borrowed.body.len], borrowed.body);
            const wire = output[0 .. borrowed.head.len + borrowed.body.len];
            prepared.source = .{ .contiguous_wire = wire };
            prepared.bytes = wire;
        }

        pub fn generatedResponse(selection: route_graph.Selection, path: []const u8) bool {
            if (comptime asset_count == 0) return false;
            return switch (selection) {
                .redirect => |redirect| if (redirect.route_id) |route_id|
                    application_assets.index(
                        route_id,
                        application_route_count,
                        asset_count,
                    ) != null
                else
                    false,
                .options, .method_not_allowed, .not_implemented => isPath(path),
                .selected, .not_found => false,
            };
        }

        pub fn prepareGenerated(
            comptime asset_route: bool,
            selection: route_graph.Selection,
            context: *Context,
            workspace: *Workspace,
            input: Input,
            output: []u8,
            close_if_prepared: bool,
        ) PrepareError!application_response_output.Prepared {
            const middleware = if (asset_route) .{} else app_middleware;
            const pending_route: application_types.PendingRoute = if (asset_route)
                .{ .asset = {} }
            else
                .{ .generated = {} };
            const Generated = application_generated.Runtime(
                config.routes,
                logical,
                middleware,
                Context,
                Workspace,
                Input,
                Pipeline,
                Bodyless,
                pending_route,
                server_identity,
            );
            var public_selection = selection;
            if (asset_route and public_selection == .redirect) {
                public_selection.redirect.route_id = null;
            }
            var response_input = input;
            response_input.connection_close = input.connection_close or close_if_prepared;
            return Generated.prepare(
                public_selection,
                context,
                workspace,
                response_input,
                output,
            );
        }

        fn isPath(path: []const u8) bool {
            if (comptime asset_count == 0) return false;
            inline for (config.assets.generated.assets) |record| {
                if (std.mem.eql(u8, path, record.path)) return true;
            }
            return false;
        }
    };
}
