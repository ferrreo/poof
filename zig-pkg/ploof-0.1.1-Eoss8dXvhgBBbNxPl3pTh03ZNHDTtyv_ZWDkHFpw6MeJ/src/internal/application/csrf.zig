const std = @import("std");
const body = @import("../../body.zig");
const pipeline_support = @import("pipeline_support.zig");
const csrf = @import("../../csrf.zig");
const flat_schema = @import("../flat/schema.zig");
const input_body = @import("../../input_body.zig");
const response = @import("../../response.zig");

const protected_cache_control = "no-store, no-transform";
const protected_field_line_bytes =
    "Cache-Control".len + protected_cache_control.len + ": \r\n".len;

pub const StartupFailure = struct {
    route_id: ?u16,
    issue: csrf.StartupIssue,
};

pub fn isPolicy(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "ploof_csrf_policy") and T.ploof_csrf_policy;
}

pub fn bodySource(plan: anytype) csrf.BodySource {
    const index = plan.selected_decoder orelse return .none;
    if (index >= plan.decoders.len) return .none;
    const decoder = plan.decoders[index];
    return switch (decoder.kind) {
        .form => .form,
        .multipart => if (decoder.csrf_body_source) .multipart else .none,
        .bytes, .text, .json => .none,
    };
}

pub fn bindBodySource(comptime item: anytype, state: anytype, source: csrf.BodySource) void {
    if (comptime isPolicy(@TypeOf(item))) item.__setBodySource(state, source);
}

pub fn forbidden(context: anytype) @TypeOf(context.empty(.forbidden)) {
    var value = context.empty(.forbidden);
    value.headers.clear();
    value.setHeaderStatic("Cache-Control", "no-store") catch unreachable;
    return value;
}

pub fn misdirected(context: anytype) @TypeOf(context.empty(.misdirected_request)) {
    var value = context.empty(.misdirected_request);
    value.headers.clear();
    value.setHeaderStatic("Cache-Control", "no-store") catch unreachable;
    return value;
}

pub fn internalFailure(context: anytype) @TypeOf(context.empty(.internal_server_error)) {
    var value = context.empty(.internal_server_error);
    value.headers.clear();
    value.setHeaderStatic("Cache-Control", "no-store") catch unreachable;
    return value;
}

pub fn finalizeFinite(context: anytype, value: anytype) bool {
    const state = context.csrf_request orelse return true;
    if (state.status == .rejected) {
        value.* = switch (state.rejection) {
            .forbidden => forbidden(context),
            .misdirected_request => misdirected(context),
        };
        return true;
    }
    return protectExposed(state, value);
}

pub fn finalizeStream(context: anytype, value: anytype) bool {
    const state = context.csrf_request orelse return true;
    std.debug.assert(state.status != .rejected);
    return protectExposed(state, value);
}

pub fn finalizeStreamResult(current: anytype, context: anytype, workspace: anytype) bool {
    switch (current.*) {
        .finite => |*finite| {
            if (finalizeFinite(context, finite)) return true;
            finite.* = internalFailure(context);
        },
        .stream => |*stream| {
            if (finalizeStream(context, stream)) return true;
            pipeline_support.abandonStream(workspace, stream);
            current.* = .{ .finite = internalFailure(context) };
        },
    }
    return false;
}

fn protectExposed(state: *csrf.RequestState, value: anytype) bool {
    if (!state.token_exposed) return true;
    value.setHeaderStatic("Cache-Control", protected_cache_control) catch return false;
    return true;
}

pub fn formName(comptime middleware: anytype) ?[]const u8 {
    inline for (middleware) |item| {
        if (comptime isPolicy(@TypeOf(item))) return @TypeOf(item).form_name;
    }
    return null;
}

pub fn validateApplication(
    comptime routes: anytype,
    comptime app_middleware: anytype,
    comptime logical: response.HeadLimits,
    comptime maximum: response.HeadLimits,
) void {
    validatePolicyCount(app_middleware);
    if (policyCount(app_middleware) != 0) validateCapacity(logical);
    validateRoutes(routes, .{}, app_middleware, logical);
    if (hasPolicy(routes, .{}, app_middleware)) validateCapacity(maximum);
}

fn validateRoutes(
    comptime routes: anytype,
    comptime inherited: anytype,
    comptime app_middleware: anytype,
    comptime logical: response.HeadLimits,
) void {
    inline for (routes) |descriptor| switch (descriptor.kind) {
        .route => {
            const middleware = app_middleware ++ inherited ++ descriptor.middleware;
            validatePolicyCount(middleware);
            validatePolicyPlacement(middleware);
            const name = formName(middleware);
            if (name != null) validateCapacity(descriptor.response_head_limits orelse logical);
            validateHandler(@TypeOf(descriptor.handler), name);
        },
        .static_dir, .static_file => {
            const middleware = app_middleware ++ inherited ++ descriptor.middleware;
            validatePolicyCount(middleware);
            validatePolicyPlacement(middleware);
            if (formName(middleware) != null) {
                validateCapacity(descriptor.response_head_limits orelse logical);
            }
        },
        .group => validateRoutes(
            descriptor.children,
            inherited ++ descriptor.middleware,
            app_middleware,
            logical,
        ),
    };
}

fn validateHandler(comptime Handler: type, comptime policy_name: ?[]const u8) void {
    if (@typeInfo(Handler) != .@"struct") return;
    if (!@hasDecl(Handler, "ploof_input_endpoint") or !Handler.ploof_input_endpoint) return;
    const Definition = Handler.definition;
    if (!Definition.body_enabled) return;
    const BodySpec = @TypeOf(Definition.body_spec);
    if (input_body.isDecoder(BodySpec)) {
        validateDecoder(BodySpec, policy_name);
        return;
    }
    inline for (@typeInfo(@TypeOf(BodySpec.configured_decoders)).@"struct".fields) |field| {
        validateDecoder(@TypeOf(@field(BodySpec.configured_decoders, field.name)), policy_name);
    }
}

fn validateDecoder(comptime Spec: type, comptime policy_name: ?[]const u8) void {
    switch (Spec.decoder_kind) {
        .form => if (policy_name) |name| validateFormTarget(Spec, name),
        .multipart => validateMultipartMarker(Spec, policy_name),
        .bytes, .text, .json => {},
    }
}

fn validateFormTarget(comptime Spec: type, comptime name: []const u8) void {
    if (Spec.is_raw) return;
    if (@typeInfo(Spec.Target) != .@"struct") return;
    inline for (@typeInfo(Spec.Target).@"struct".fields) |field| {
        if (std.mem.eql(u8, flat_schema.wireName(Spec.Target, field.name), name)) {
            @compileError("PLOOF-E3619 typed form target declares reserved CSRF field");
        }
    }
}

fn validateMultipartMarker(comptime Spec: type, comptime policy_name: ?[]const u8) void {
    if (!@hasDecl(Spec, "ploof_csrf_field_name")) return;
    if (@hasDecl(Spec, "ploof_csrf_field_count") and Spec.ploof_csrf_field_count > 1) {
        @compileError("PLOOF-E3623 multipart body declares more than one CSRF field");
    }
    const marker = Spec.ploof_csrf_field_name orelse return;
    const name = policy_name orelse {
        @compileError("PLOOF-E3620 multipart CSRF field requires an effective CSRF policy");
    };
    if (!std.mem.eql(u8, marker, name)) {
        @compileError("PLOOF-E3621 multipart CSRF field name must match CSRF policy form name");
    }
}

fn validatePolicyCount(comptime middleware: anytype) void {
    if (policyCount(middleware) > 1) {
        @compileError("PLOOF-E3618 route has more than one effective CSRF policy");
    }
}

fn validatePolicyPlacement(comptime middleware: anytype) void {
    var body_before_policy = false;
    inline for (middleware) |item| {
        const T = @TypeOf(item);
        if (isPolicy(T)) {
            if (body_before_policy) {
                @compileError(
                    "PLOOF-E3625 body middleware precedes CSRF policy; " ++
                        "move CSRF earlier or split head and body middleware",
                );
            }
            return;
        }
        body_before_policy = body_before_policy or
            (@typeInfo(T) == .@"struct" and @hasDecl(T, "body"));
    }
}

fn policyCount(comptime middleware: anytype) usize {
    var count: usize = 0;
    inline for (middleware) |item| count += @intFromBool(isPolicy(@TypeOf(item)));
    return count;
}

fn validateCapacity(comptime limits: response.HeadLimits) void {
    if (limits.field_line_bytes_max < protected_field_line_bytes or
        limits.head_bytes_max < protected_field_line_bytes)
    {
        @compileError("PLOOF-E3622 CSRF response head limit is below 39 bytes");
    }
}

fn hasPolicy(
    comptime routes: anytype,
    comptime inherited: anytype,
    comptime app_middleware: anytype,
) bool {
    if (policyCount(app_middleware) != 0) return true;
    inline for (routes) |descriptor| switch (descriptor.kind) {
        .route, .static_dir, .static_file => {
            if (policyCount(inherited ++ descriptor.middleware) != 0) return true;
        },
        .group => if (hasPolicy(
            descriptor.children,
            inherited ++ descriptor.middleware,
            app_middleware,
        )) return true,
    };
    return false;
}

pub fn startupFailure(
    comptime routes: anytype,
    comptime app_middleware: anytype,
    state: anytype,
) ?StartupFailure {
    if (startupIssue(app_middleware, state)) |issue| {
        return .{ .route_id = null, .issue = issue };
    }
    return startupRoutes(routes, .{}, app_middleware, 0, state);
}

fn startupRoutes(
    comptime routes: anytype,
    comptime inherited: anytype,
    comptime app_middleware: anytype,
    comptime first_route_id: usize,
    state: anytype,
) ?StartupFailure {
    comptime var route_id = first_route_id;
    inline for (routes) |descriptor| {
        const first = comptime route_id;
        const count = comptime routeCount(descriptor);
        comptime route_id += count;
        switch (descriptor.kind) {
            .route, .static_dir, .static_file => if (startupIssue(
                app_middleware ++ inherited ++ descriptor.middleware,
                state,
            )) |issue| return .{ .route_id = @intCast(first), .issue = issue },
            .group => if (startupRoutes(
                descriptor.children,
                inherited ++ descriptor.middleware,
                app_middleware,
                first,
                state,
            )) |failure| return failure,
        }
    }
    return null;
}

fn startupIssue(comptime middleware: anytype, state: anytype) ?csrf.StartupIssue {
    inline for (middleware) |item| {
        if (comptime isPolicy(@TypeOf(item))) return item.startupIssue(state);
    }
    return null;
}

fn routeCount(comptime descriptor: anytype) usize {
    return switch (descriptor.kind) {
        .route, .static_dir, .static_file => 1,
        .group => blk: {
            var total: usize = 0;
            inline for (descriptor.children) |child| total += routeCount(child);
            break :blk total;
        },
    };
}

test {
    std.testing.refAllDecls(@This());
    _ = body;
}
