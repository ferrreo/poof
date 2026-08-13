const std = @import("std");
const application_body = @import("body.zig");
const application_input = @import("input.zig");
const gzip_encoder = @import("../runtime/gzip/encoder.zig");
const json_response = @import("json_response.zig");
const response = @import("../../response.zig");

pub const Error = error{InputInvariant};

pub fn maximumWorkspaceBytes(
    comptime descriptors: anytype,
    comptime maximum: response.HeadLimits,
    comptime gzip_enabled: bool,
) u64 {
    var result: u64 = 0;
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => result = @max(
            result,
            workspaceBytes(descriptor.handler, maximum, gzip_enabled),
        ),
        .static_dir, .static_file => {},
        .group => result = @max(
            result,
            maximumWorkspaceBytes(descriptor.children, maximum, gzip_enabled),
        ),
    };
    return result;
}

pub fn bind(
    comptime Handler: type,
    comptime maximum: response.HeadLimits,
    comptime gzip_enabled: bool,
    binding: *json_response.Binding,
    written: *bool,
    workspace: []u8,
) Error!void {
    if (comptime !isInputEndpoint(Handler)) return error.InputInvariant;
    const input_layout = comptime application_input.workspaceLayout(Handler);
    const source = input_layout.response_json;
    const output_bytes = comptime transportBytes(Handler, maximum, gzip_enabled);
    const output_offset = input_layout.total_bytes_max;
    binding.* = .{
        .bytes = try region(workspace, source.offset, source.bytes),
        .output = try region(workspace, output_offset, output_bytes),
        .written = written,
    };
}

fn workspaceBytes(
    comptime handler: anytype,
    comptime maximum: response.HeadLimits,
    comptime gzip_enabled: bool,
) u64 {
    const Handler = @TypeOf(handler);
    const base = application_body.plan(handler).workspace_bytes_max;
    if (comptime !isInputEndpoint(Handler)) return base;
    const output = transportBytes(Handler, maximum, gzip_enabled);
    return std.math.add(u64, base, output) catch {
        @compileError("PLOOF-E3268 endpoint response workspace size overflow");
    };
}

fn transportBytes(
    comptime Handler: type,
    comptime maximum: response.HeadLimits,
    comptime gzip_enabled: bool,
) usize {
    const encoded_max = Handler.definition.response_json_bytes_max;
    const payload_max = if (gzip_enabled)
        gzip_encoder.bound(encoded_max) catch {
            @compileError("PLOOF-E3268 endpoint response workspace size overflow");
        }
    else
        encoded_max;
    return std.math.add(usize, maximum.head_bytes_max, @max(encoded_max, payload_max)) catch {
        @compileError("PLOOF-E3268 endpoint response workspace size overflow");
    };
}

fn isInputEndpoint(comptime Handler: type) bool {
    if (@typeInfo(Handler) != .@"struct") return false;
    return @hasDecl(Handler, "ploof_input_endpoint") and Handler.ploof_input_endpoint;
}

fn region(workspace: []u8, offset: usize, bytes: usize) Error![]u8 {
    if (offset > workspace.len or bytes > workspace.len - offset) {
        return error.InputInvariant;
    }
    return workspace[offset..][0..bytes];
}

test "endpoint response source and transport regions are exact and disjoint" {
    const endpoint = @import("../../endpoint.zig");
    const Handler = @TypeOf(endpoint.Endpoint(.{
        .response_json_bytes_max = 73,
    }).handle(struct {
        fn call(_: anytype, _: anytype) void {}
    }.call));
    const limits = comptime response.HeadLimits.validate(.{
        .head_bytes_max = 128,
        .field_line_bytes_max = 64,
        .fields_max = 8,
    });
    const handler: Handler = .{};
    const required = comptime workspaceBytes(handler, limits, false);
    var workspace: [required]u8 = undefined;
    var binding: json_response.Binding = undefined;
    var written = false;
    try bind(Handler, limits, false, &binding, &written, &workspace);
    try std.testing.expectEqual(@as(usize, 73), binding.bytes.len);
    try std.testing.expectEqual(@as(usize, 201), binding.output.len);
    try std.testing.expect(
        @intFromPtr(binding.bytes.ptr) + binding.bytes.len <=
            @intFromPtr(binding.output.ptr),
    );
    try std.testing.expectError(
        error.InputInvariant,
        bind(
            Handler,
            limits,
            false,
            &binding,
            &written,
            workspace[0 .. workspace.len - 1],
        ),
    );
}
