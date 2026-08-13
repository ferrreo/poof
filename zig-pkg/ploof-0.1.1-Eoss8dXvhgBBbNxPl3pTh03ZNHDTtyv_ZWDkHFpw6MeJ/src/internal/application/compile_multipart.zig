const std = @import("std");
const application_compile_errors = @import("compile_errors.zig");
const application_stream_compile = @import("stream_compile.zig");
const html_response = @import("../../html/response.zig");
const multipart = @import("../../multipart.zig");

pub fn validateComplete(
    comptime function: anytype,
    comptime parameters: []const type,
    comptime Context: type,
    comptime Response: type,
    comptime AppError: type,
    comptime message: []const u8,
) application_stream_compile.Layout {
    const info = functionInfo(function, message);
    if (info.params.len != parameters.len) @compileError(message);
    inline for (parameters, 0..) |expected, index| {
        if (info.params[index].type == null or info.params[index].type.? != expected) {
            @compileError(message);
        }
    }
    const Return = info.return_type orelse @compileError(message);
    const Decision = switch (@typeInfo(Return)) {
        .error_union => |error_union| error_union.payload,
        else => Return,
    };
    if (@typeInfo(Decision) != .@"union" or !@hasField(Decision, "commit")) {
        @compileError(message);
    }
    const Payload = @FieldType(Decision, "commit");
    if (Decision != multipart.Decision(Payload)) @compileError(message);
    const layout = application_stream_compile.classifyPayload(
        Payload,
        Context,
        Response,
    ) orelse @compileError(message);
    if (comptime html_response.is(Payload)) {
        application_compile_errors.validateSubset(Payload.ApplicationError, AppError);
    }
    switch (@typeInfo(Return)) {
        .error_union => |error_union| application_compile_errors.validateSubset(
            error_union.error_set,
            AppError,
        ),
        else => {},
    }
    return layout;
}

fn functionInfo(comptime function: anytype, comptime message: []const u8) std.builtin.Type.Fn {
    return switch (@typeInfo(@TypeOf(function))) {
        .@"fn" => |info| info,
        else => @compileError(message),
    };
}
