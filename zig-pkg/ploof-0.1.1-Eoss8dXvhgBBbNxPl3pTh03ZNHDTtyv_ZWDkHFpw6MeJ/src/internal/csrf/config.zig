const std = @import("std");
const csrf_request = @import("request.zig");
const syntax = @import("../http1/syntax.zig");

pub fn validateSynchronizer(
    comptime Context: type,
    comptime config: anytype,
    comptime SessionToken: type,
) void {
    validateCommon(config);
    validateFields(config, &.{
        "origins",
        "source_origins",
        "load",
        "store",
        "clear",
        "header_name",
        "form_name",
    }, "PLOOF-E3626 unknown CSRF synchronizer configuration field");
    const Config = @TypeOf(config);
    if (!@hasField(Config, "load")) @compileError("PLOOF-E3602 CSRF synchronizer requires load");
    if (!@hasField(Config, "store")) @compileError("PLOOF-E3603 CSRF synchronizer requires store");
    if (!@hasField(Config, "clear")) @compileError("PLOOF-E3604 CSRF synchronizer requires clear");
    validateOriginProvider(
        Context,
        config.origins,
        "PLOOF-E3617 CSRF origins must be fn " ++
            "(*const ApplicationState) *const OriginSet",
    );
    validateSourceOriginProvider(Context, config);
    validateCallback(
        config.load,
        &.{*Context},
        ?SessionToken,
        "PLOOF-E3612 CSRF load must be fn (*Context) ?SessionToken",
    );
    validateCallback(
        config.store,
        &.{ *Context, SessionToken },
        void,
        "PLOOF-E3613 CSRF store must be fn (*Context, SessionToken) void",
    );
    validateCallback(
        config.clear,
        &.{*Context},
        void,
        "PLOOF-E3614 CSRF clear must be fn (*Context) void",
    );
}

pub fn validateSigned(
    comptime Context: type,
    comptime config: anytype,
    comptime Keyring: type,
    comptime LoginBinding: type,
) void {
    validateCommon(config);
    validateFields(config, &.{
        "origins",
        "source_origins",
        "keys",
        "binding",
        "header_name",
        "form_name",
        "cookie_name",
    }, "PLOOF-E3627 unknown signed CSRF configuration field");
    const Config = @TypeOf(config);
    if (!@hasField(Config, "keys")) @compileError("PLOOF-E3605 signed CSRF requires keys");
    if (!@hasField(Config, "binding")) @compileError("PLOOF-E3606 signed CSRF requires binding");
    const cookie = selectedName(config, "cookie_name", "__Host-ploof-csrf");
    if (!csrf_request.cookieNameValid(cookie)) {
        @compileError("PLOOF-E3607 invalid CSRF cookie name");
    }
    validateOriginProvider(
        Context,
        config.origins,
        "PLOOF-E3617 CSRF origins must be fn " ++
            "(*const ApplicationState) *const OriginSet",
    );
    validateSourceOriginProvider(Context, config);
    validateCallback(
        config.keys,
        &.{*const Context.ApplicationState},
        *const Keyring,
        "PLOOF-E3615 signed CSRF keys must be fn (*const ApplicationState) *const Keyring",
    );
    validateCallback(
        config.binding,
        &.{*Context},
        ?LoginBinding,
        "PLOOF-E3616 signed CSRF binding must be fn (*Context) ?LoginBinding",
    );
}

pub fn selectedName(
    comptime config: anytype,
    comptime field: []const u8,
    comptime default: []const u8,
) []const u8 {
    if (!@hasField(@TypeOf(config), field)) return default;
    return stringValue(@field(config, field), nameTypeDiagnostic(field));
}

fn validateCommon(comptime config: anytype) void {
    const Config = @TypeOf(config);
    if (@typeInfo(Config) != .@"struct" or @typeInfo(Config).@"struct".is_tuple) {
        @compileError("PLOOF-E3608 CSRF configuration must be a named struct");
    }
    if (!@hasField(Config, "origins")) @compileError("PLOOF-E3609 CSRF requires origins");
    const header = selectedName(config, "header_name", "X-CSRF-Token");
    const form = selectedName(config, "form_name", "_csrf");
    if (!syntax.isToken(header)) @compileError("PLOOF-E3610 invalid CSRF header name");
    if (!syntax.isToken(form)) @compileError("PLOOF-E3611 invalid CSRF form field name");
}

fn validateFields(
    comptime config: anytype,
    comptime allowed: anytype,
    comptime message: []const u8,
) void {
    inline for (@typeInfo(@TypeOf(config)).@"struct".fields) |field| {
        var known = false;
        inline for (allowed) |name| known = known or std.mem.eql(u8, field.name, name);
        if (!known) @compileError(message);
    }
}

fn nameTypeDiagnostic(comptime field: []const u8) []const u8 {
    if (std.mem.eql(u8, field, "header_name")) {
        return "PLOOF-E3628 CSRF header_name must be a string";
    }
    if (std.mem.eql(u8, field, "form_name")) {
        return "PLOOF-E3629 CSRF form_name must be a string";
    }
    if (std.mem.eql(u8, field, "cookie_name")) {
        return "PLOOF-E3630 signed CSRF cookie_name must be a string";
    }
    unreachable;
}

fn stringValue(comptime value: anytype, comptime message: []const u8) []const u8 {
    const pointer = switch (@typeInfo(@TypeOf(value))) {
        .pointer => |info| info,
        else => @compileError(message),
    };
    if (!pointer.is_const) @compileError(message);
    if (pointer.size == .slice and pointer.child == u8) return value;
    if (pointer.size == .one) {
        const array = switch (@typeInfo(pointer.child)) {
            .array => |info| info,
            else => @compileError(message),
        };
        if (array.child == u8) return value[0..array.len];
    }
    @compileError(message);
}

fn validateSourceOriginProvider(comptime Context: type, comptime config: anytype) void {
    if (!@hasField(@TypeOf(config), "source_origins")) return;
    validateOriginProvider(
        Context,
        config.source_origins,
        "PLOOF-E3631 CSRF source_origins must be fn " ++
            "(*const ApplicationState) *const OriginSet",
    );
}

fn validateOriginProvider(
    comptime Context: type,
    comptime provider: anytype,
    comptime message: []const u8,
) void {
    const info = callbackInfo(provider, message);
    validateCallbackParameters(info, &.{*const Context.ApplicationState}, message);
    const Return = info.return_type orelse @compileError(message);
    const pointer = switch (@typeInfo(Return)) {
        .pointer => |value| value,
        else => @compileError(message),
    };
    if (pointer.size != .one or !pointer.is_const or
        !@hasDecl(pointer.child, "ploof_csrf_origin_set") or
        !pointer.child.ploof_csrf_origin_set)
    {
        @compileError(message);
    }
}

fn validateCallback(
    comptime callback: anytype,
    comptime parameters: []const type,
    comptime Return: type,
    comptime message: []const u8,
) void {
    const info = callbackInfo(callback, message);
    validateCallbackParameters(info, parameters, message);
    if (info.return_type == null or info.return_type.? != Return) @compileError(message);
}

fn validateCallbackParameters(
    comptime info: std.builtin.Type.Fn,
    comptime parameters: []const type,
    comptime message: []const u8,
) void {
    if (info.params.len != parameters.len) @compileError(message);
    inline for (parameters, 0..) |expected, index| {
        if (info.params[index].type == null or info.params[index].type.? != expected) {
            @compileError(message);
        }
    }
}

fn callbackInfo(comptime callback: anytype, comptime message: []const u8) std.builtin.Type.Fn {
    return switch (@typeInfo(@TypeOf(callback))) {
        .@"fn" => |info| info,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => |info| info,
            else => @compileError(message),
        },
        else => @compileError(message),
    };
}

test {
    std.testing.refAllDecls(@This());
}
