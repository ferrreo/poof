const std = @import("std");
const cors = @import("cors.zig");
const response = @import("response.zig");

pub const Method = enum(u8) {
    get,
    head,
    post,
    put,
    patch,
    delete,

    pub fn wire(method: Method) []const u8 {
        return switch (method) {
            .get => "GET",
            .head => "HEAD",
            .post => "POST",
            .put => "PUT",
            .patch => "PATCH",
            .delete => "DELETE",
        };
    }
};

pub const routes_hard_max: u16 = 4096;
pub const pattern_bytes_hard_max: u32 = 1024 * 1024;
pub const segments_hard_max: u16 = 4096;
pub const captures_hard_max: u16 = 1024;
pub const middleware_hard_max: u8 = 64;
pub const middleware_state_bytes_hard_max: u32 = 64 * 1024;
pub const route_segments_total_hard_max: u32 = 1024 * 1024;
pub const route_pattern_bytes_total_hard_max: u32 = 64 * 1024 * 1024;
pub const index_nodes_hard_max: u32 = 262_144;
pub const search_visits_hard_max: u32 = 16_384;
pub const search_compare_bytes_hard_max: u32 = 8 * 1024 * 1024;

const middleware_state_zero_diagnostic =
    "PLOOF-E3011 middleware state byte limit " ++
    "must be nonzero";
const middleware_state_hard_diagnostic =
    "PLOOF-E3012 middleware state byte limit " ++
    "exceeds 64 KiB";
const route_segments_total_zero_diagnostic =
    "PLOOF-E3110 aggregate route segment limit " ++
    "must be nonzero";
const route_segments_total_hard_diagnostic =
    "PLOOF-E3111 aggregate route segment limit " ++
    "exceeds 1048576";
const route_pattern_bytes_total_zero_diagnostic =
    "PLOOF-E3112 aggregate route pattern byte limit " ++
    "must be nonzero";
const route_pattern_bytes_total_hard_diagnostic =
    "PLOOF-E3113 aggregate route pattern byte limit " ++
    "exceeds 64 MiB";
const search_compare_bytes_zero_diagnostic =
    "PLOOF-E3118 route search compared-byte limit " ++
    "must be nonzero";
const search_compare_bytes_hard_diagnostic =
    "PLOOF-E3119 route search compared-byte limit " ++
    "exceeds 8 MiB";

pub const GraphLimitIssue = enum(u8) {
    routes_zero,
    routes_above_hard_max,
    pattern_bytes_zero,
    pattern_bytes_above_hard_max,
    segments_zero,
    segments_above_hard_max,
    captures_zero,
    captures_above_hard_max,
    middleware_zero,
    middleware_above_hard_max,
    middleware_state_bytes_zero,
    middleware_state_bytes_above_hard_max,
    route_segments_total_zero,
    route_segments_total_above_hard_max,
    route_pattern_bytes_total_zero,
    route_pattern_bytes_total_above_hard_max,
    index_nodes_zero,
    index_nodes_above_hard_max,
    search_visits_zero,
    search_visits_above_hard_max,
    search_compare_bytes_zero,
    search_compare_bytes_above_hard_max,

    pub fn diagnostic(issue: GraphLimitIssue) []const u8 {
        return graphLimitDiagnostic(issue);
    }
};

fn graphLimitDiagnostic(issue: GraphLimitIssue) []const u8 {
    return switch (issue) {
        .routes_zero => "PLOOF-E3001 route count limit must be nonzero",
        .routes_above_hard_max => "PLOOF-E3002 route count limit exceeds 4096",
        .pattern_bytes_zero => "PLOOF-E3003 route pattern byte limit must be nonzero",
        .pattern_bytes_above_hard_max => "PLOOF-E3004 route pattern byte limit exceeds 1 MiB",
        .segments_zero => "PLOOF-E3005 path segment limit must be nonzero",
        .segments_above_hard_max => "PLOOF-E3006 path segment limit exceeds 4096",
        .captures_zero => "PLOOF-E3007 capture limit must be nonzero",
        .captures_above_hard_max => "PLOOF-E3008 capture limit exceeds 1024",
        .middleware_zero => "PLOOF-E3009 middleware limit must be nonzero",
        .middleware_above_hard_max => "PLOOF-E3010 middleware limit exceeds 64",
        .middleware_state_bytes_zero => middleware_state_zero_diagnostic,
        .middleware_state_bytes_above_hard_max => middleware_state_hard_diagnostic,
        .route_segments_total_zero => route_segments_total_zero_diagnostic,
        .route_segments_total_above_hard_max => route_segments_total_hard_diagnostic,
        .route_pattern_bytes_total_zero => route_pattern_bytes_total_zero_diagnostic,
        .route_pattern_bytes_total_above_hard_max => route_pattern_bytes_total_hard_diagnostic,
        .index_nodes_zero => "PLOOF-E3114 route index node limit must be nonzero",
        .index_nodes_above_hard_max => "PLOOF-E3115 route index node limit exceeds 262144",
        .search_visits_zero => "PLOOF-E3116 route search visit limit must be nonzero",
        .search_visits_above_hard_max => "PLOOF-E3117 route search visit limit exceeds 16384",
        .search_compare_bytes_zero => search_compare_bytes_zero_diagnostic,
        .search_compare_bytes_above_hard_max => search_compare_bytes_hard_diagnostic,
    };
}

pub const GraphLimits = struct {
    routes_max: u16 = 512,
    pattern_bytes_max: u32 = 8 * 1024,
    segments_max: u16 = 256,
    captures_max: u16 = 64,
    middleware_max: u8 = 32,
    middleware_state_bytes_max: u32 = 4 * 1024,
    route_segments_total_max: u32 = 65_536,
    route_pattern_bytes_total_max: u32 = 4 * 1024 * 1024,
    index_nodes_max: u32 = 16_384,
    search_visits_max: u32 = 1024,
    search_compare_bytes_max: u32 = 256 * 1024,

    pub fn issue(limits: GraphLimits) ?GraphLimitIssue {
        if (limits.routes_max == 0) return .routes_zero;
        if (limits.routes_max > routes_hard_max) return .routes_above_hard_max;
        if (limits.pattern_bytes_max == 0) return .pattern_bytes_zero;
        if (limits.pattern_bytes_max > pattern_bytes_hard_max) {
            return .pattern_bytes_above_hard_max;
        }
        if (limits.segments_max == 0) return .segments_zero;
        if (limits.segments_max > segments_hard_max) return .segments_above_hard_max;
        if (limits.captures_max == 0) return .captures_zero;
        if (limits.captures_max > captures_hard_max) return .captures_above_hard_max;
        if (limits.middleware_max == 0) return .middleware_zero;
        if (limits.middleware_max > middleware_hard_max) return .middleware_above_hard_max;
        if (limits.middleware_state_bytes_max == 0) return .middleware_state_bytes_zero;
        if (limits.middleware_state_bytes_max > middleware_state_bytes_hard_max) {
            return .middleware_state_bytes_above_hard_max;
        }
        if (limits.route_segments_total_max == 0) return .route_segments_total_zero;
        if (limits.route_segments_total_max > route_segments_total_hard_max) {
            return .route_segments_total_above_hard_max;
        }
        if (limits.route_pattern_bytes_total_max == 0) {
            return .route_pattern_bytes_total_zero;
        }
        if (limits.route_pattern_bytes_total_max > route_pattern_bytes_total_hard_max) {
            return .route_pattern_bytes_total_above_hard_max;
        }
        if (limits.index_nodes_max == 0) return .index_nodes_zero;
        if (limits.index_nodes_max > index_nodes_hard_max) {
            return .index_nodes_above_hard_max;
        }
        if (limits.search_visits_max == 0) return .search_visits_zero;
        if (limits.search_visits_max > search_visits_hard_max) {
            return .search_visits_above_hard_max;
        }
        if (limits.search_compare_bytes_max == 0) return .search_compare_bytes_zero;
        if (limits.search_compare_bytes_max > search_compare_bytes_hard_max) {
            return .search_compare_bytes_above_hard_max;
        }
        return null;
    }

    pub fn validate(comptime limits: GraphLimits) GraphLimits {
        if (limits.issue()) |problem| @compileError(graphLimitDiagnostic(problem));
        return limits;
    }
};

pub const standard_graph_limits = GraphLimits.validate(.{});

pub const DescriptorKind = enum(u8) {
    route,
    static_dir,
    static_file,
    group,
};

pub const DescriptorIdentity = opaque {};

pub const OpenMetricsHandler = struct {
    pub const ploof_open_metrics_handler = true;
};

pub const open_metrics_handler = OpenMetricsHandler{};

pub fn isOpenMetricsHandler(comptime handler: anytype) bool {
    const Handler = @TypeOf(handler);
    return @typeInfo(Handler) == .@"struct" and
        @hasDecl(Handler, "ploof_open_metrics_handler") and
        Handler.ploof_open_metrics_handler;
}

/// Opaque capability for one descriptor at one position in a composed graph.
pub const RouteTarget = opaque {
    pub fn method(self: *const RouteTarget) Method {
        return targetValue(self).method;
    }

    pub fn path(self: *const RouteTarget) []const u8 {
        return targetValue(self).path;
    }

    pub fn routeId(self: *const RouteTarget) u16 {
        return targetValue(self).route_id;
    }

    pub fn matches(self: *const RouteTarget, comptime descriptor: anytype) bool {
        const Descriptor = @TypeOf(descriptor);
        if (@typeInfo(Descriptor) != .@"struct" or
            !@hasField(Descriptor, "descriptor_identity") or
            !@hasField(Descriptor, "method") or
            !@hasField(Descriptor, "path")) return false;
        const value = targetValue(self);
        return @TypeOf(descriptor.descriptor_identity) == *const DescriptorIdentity and
            @TypeOf(descriptor.method) == Method and
            @TypeOf(descriptor.path) == []const u8 and
            value.descriptor_identity == descriptor.descriptor_identity and
            value.method == descriptor.method and
            std.mem.eql(u8, value.declared_path, descriptor.path);
    }
};

const RouteTargetValue = struct {
    method: Method,
    path: []const u8,
    declared_path: []const u8,
    route_id: u16,
    descriptor_identity: *const DescriptorIdentity,
};

fn targetValue(target: *const RouteTarget) *const RouteTargetValue {
    return @ptrCast(@alignCast(target));
}

/// Internal seam for the closed application route composer.
pub fn __target(
    comptime method: Method,
    comptime path: []const u8,
    comptime declared_path: []const u8,
    comptime route_id: u16,
    comptime descriptor_identity: *const DescriptorIdentity,
) *const RouteTarget {
    const Holder = struct {
        const value = RouteTargetValue{
            .method = method,
            .path = path,
            .declared_path = declared_path,
            .route_id = route_id,
            .descriptor_identity = descriptor_identity,
        };
    };
    return @ptrCast(&Holder.value);
}

pub fn RouteDescriptor(comptime Handler: type, comptime Middleware: type) type {
    return struct {
        kind: DescriptorKind = .route,
        method: Method,
        path: []const u8,
        handler: Handler,
        middleware: Middleware,
        response_head_limits: ?response.HeadLimits,
        cors_policy: ?cors.Policy = null,
        descriptor_identity: *const DescriptorIdentity,

        pub fn withCors(
            self: @This(),
            comptime policy: cors.Policy,
        ) @This() {
            return .{
                .kind = self.kind,
                .method = self.method,
                .path = self.path,
                .handler = self.handler,
                .middleware = self.middleware,
                .response_head_limits = self.response_head_limits,
                .cors_policy = cors.validate(policy),
                .descriptor_identity = self.descriptor_identity,
            };
        }
    };
}

pub fn GroupDescriptor(comptime Middleware: type, comptime Children: type) type {
    return struct {
        kind: DescriptorKind = .group,
        prefix: []const u8,
        middleware: Middleware,
        children: Children,
        cors_policy: ?cors.Policy = null,

        pub fn withCors(
            self: @This(),
            comptime policy: cors.Policy,
        ) @This() {
            return .{
                .kind = self.kind,
                .prefix = self.prefix,
                .middleware = self.middleware,
                .children = self.children,
                .cors_policy = cors.validate(policy),
            };
        }
    };
}

pub fn route(
    comptime method: Method,
    comptime path: []const u8,
    comptime handler: anytype,
) RouteDescriptor(@TypeOf(handler), @TypeOf(.{})) {
    return configured(method, path, handler, .{}, null);
}

pub fn configured(
    comptime method: Method,
    comptime path: []const u8,
    comptime handler: anytype,
    comptime middleware: anytype,
    comptime response_head_limits: ?response.HeadLimits,
) RouteDescriptor(@TypeOf(handler), @TypeOf(middleware)) {
    return .{
        .method = method,
        .path = path,
        .handler = handler,
        .middleware = middleware,
        .response_head_limits = response_head_limits,
        .descriptor_identity = descriptorIdentity(
            method,
            path,
            handler,
            middleware,
            response_head_limits,
        ),
    };
}

fn descriptorIdentity(
    comptime method: Method,
    comptime path: []const u8,
    comptime handler: anytype,
    comptime middleware: anytype,
    comptime response_head_limits: ?response.HeadLimits,
) *const DescriptorIdentity {
    const Holder = struct {
        var token: u8 = 0;
        const signature = .{
            method,
            path,
            handler,
            middleware,
            response_head_limits,
        };
    };
    _ = Holder.signature;
    return @ptrCast(&Holder.token);
}

pub fn get(
    comptime path: []const u8,
    comptime handler: anytype,
) RouteDescriptor(@TypeOf(handler), @TypeOf(.{})) {
    return route(.get, path, handler);
}

pub fn openMetrics(
    comptime path: []const u8,
) RouteDescriptor(OpenMetricsHandler, @TypeOf(.{})) {
    return configured(.get, path, open_metrics_handler, .{}, null);
}

pub fn openMetricsConfigured(
    comptime path: []const u8,
    comptime middleware: anytype,
    comptime response_head_limits: ?response.HeadLimits,
) RouteDescriptor(OpenMetricsHandler, @TypeOf(middleware)) {
    return configured(
        .get,
        path,
        open_metrics_handler,
        middleware,
        response_head_limits,
    );
}

pub fn head(
    comptime path: []const u8,
    comptime handler: anytype,
) RouteDescriptor(@TypeOf(handler), @TypeOf(.{})) {
    return route(.head, path, handler);
}

pub fn post(
    comptime path: []const u8,
    comptime handler: anytype,
) RouteDescriptor(@TypeOf(handler), @TypeOf(.{})) {
    return route(.post, path, handler);
}

pub fn put(
    comptime path: []const u8,
    comptime handler: anytype,
) RouteDescriptor(@TypeOf(handler), @TypeOf(.{})) {
    return route(.put, path, handler);
}

pub fn patch(
    comptime path: []const u8,
    comptime handler: anytype,
) RouteDescriptor(@TypeOf(handler), @TypeOf(.{})) {
    return route(.patch, path, handler);
}

pub fn delete(
    comptime path: []const u8,
    comptime handler: anytype,
) RouteDescriptor(@TypeOf(handler), @TypeOf(.{})) {
    return route(.delete, path, handler);
}

pub fn group(
    comptime prefix: []const u8,
    comptime middleware: anytype,
    comptime children: anytype,
) GroupDescriptor(@TypeOf(middleware), @TypeOf(children)) {
    return .{
        .prefix = prefix,
        .middleware = middleware,
        .children = children,
    };
}

fn handlerOne() u8 {
    return 1;
}

fn handlerTwo() u16 {
    return 2;
}

fn middlewareOne() u8 {
    return 3;
}

test "methods expose exact HTTP wire names" {
    const methods = [_]Method{ .get, .head, .post, .put, .patch, .delete };
    const wire_names = [_][]const u8{ "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE" };
    for (methods, wire_names) |method, expected| {
        try std.testing.expectEqualStrings(expected, method.wire());
    }
}

test "standard graph limits match the route graph contract" {
    const limits = standard_graph_limits;
    try std.testing.expectEqual(@as(u16, 512), limits.routes_max);
    try std.testing.expectEqual(@as(u32, 8 * 1024), limits.pattern_bytes_max);
    try std.testing.expectEqual(@as(u16, 256), limits.segments_max);
    try std.testing.expectEqual(@as(u16, 64), limits.captures_max);
    try std.testing.expectEqual(@as(u8, 32), limits.middleware_max);
    try std.testing.expectEqual(@as(u32, 4 * 1024), limits.middleware_state_bytes_max);
    try std.testing.expectEqual(@as(u32, 65_536), limits.route_segments_total_max);
    try std.testing.expectEqual(@as(u32, 4 * 1024 * 1024), limits.route_pattern_bytes_total_max);
    try std.testing.expectEqual(@as(u32, 16_384), limits.index_nodes_max);
    try std.testing.expectEqual(@as(u32, 1024), limits.search_visits_max);
    try std.testing.expectEqual(@as(u32, 256 * 1024), limits.search_compare_bytes_max);
    try std.testing.expectEqual(@as(?GraphLimitIssue, null), limits.issue());
}

test "graph limits accept inclusive boundaries" {
    const smallest = comptime GraphLimits.validate(.{
        .routes_max = 1,
        .pattern_bytes_max = 1,
        .segments_max = 1,
        .captures_max = 1,
        .middleware_max = 1,
        .middleware_state_bytes_max = 1,
        .route_segments_total_max = 1,
        .route_pattern_bytes_total_max = 1,
        .index_nodes_max = 1,
        .search_visits_max = 1,
        .search_compare_bytes_max = 1,
    });
    const largest = comptime GraphLimits.validate(.{
        .routes_max = routes_hard_max,
        .pattern_bytes_max = pattern_bytes_hard_max,
        .segments_max = segments_hard_max,
        .captures_max = captures_hard_max,
        .middleware_max = middleware_hard_max,
        .middleware_state_bytes_max = middleware_state_bytes_hard_max,
        .route_segments_total_max = route_segments_total_hard_max,
        .route_pattern_bytes_total_max = route_pattern_bytes_total_hard_max,
        .index_nodes_max = index_nodes_hard_max,
        .search_visits_max = search_visits_hard_max,
        .search_compare_bytes_max = search_compare_bytes_hard_max,
    });
    try std.testing.expectEqual(@as(?GraphLimitIssue, null), smallest.issue());
    try std.testing.expectEqual(@as(?GraphLimitIssue, null), largest.issue());
}

test "graph limits report every invalid boundary with stable diagnostics" {
    try expectIssue(.routes_zero, .{ .routes_max = 0 }, "PLOOF-E3001");
    try expectIssue(.routes_above_hard_max, .{
        .routes_max = routes_hard_max + 1,
    }, "PLOOF-E3002");
    try expectIssue(.pattern_bytes_zero, .{ .pattern_bytes_max = 0 }, "PLOOF-E3003");
    try expectIssue(.pattern_bytes_above_hard_max, .{
        .pattern_bytes_max = pattern_bytes_hard_max + 1,
    }, "PLOOF-E3004");
    try expectIssue(.segments_zero, .{ .segments_max = 0 }, "PLOOF-E3005");
    try expectIssue(.segments_above_hard_max, .{
        .segments_max = segments_hard_max + 1,
    }, "PLOOF-E3006");
    try expectIssue(.captures_zero, .{ .captures_max = 0 }, "PLOOF-E3007");
    try expectIssue(.captures_above_hard_max, .{
        .captures_max = captures_hard_max + 1,
    }, "PLOOF-E3008");
    try expectIssue(.middleware_zero, .{ .middleware_max = 0 }, "PLOOF-E3009");
    try expectIssue(.middleware_above_hard_max, .{
        .middleware_max = middleware_hard_max + 1,
    }, "PLOOF-E3010");
    try expectIssue(.middleware_state_bytes_zero, .{
        .middleware_state_bytes_max = 0,
    }, "PLOOF-E3011");
    try expectIssue(.middleware_state_bytes_above_hard_max, .{
        .middleware_state_bytes_max = middleware_state_bytes_hard_max + 1,
    }, "PLOOF-E3012");
    try expectIssue(.route_segments_total_zero, .{
        .route_segments_total_max = 0,
    }, "PLOOF-E3110");
    try expectIssue(.route_segments_total_above_hard_max, .{
        .route_segments_total_max = route_segments_total_hard_max + 1,
    }, "PLOOF-E3111");
    try expectIssue(.route_pattern_bytes_total_zero, .{
        .route_pattern_bytes_total_max = 0,
    }, "PLOOF-E3112");
    try expectIssue(.route_pattern_bytes_total_above_hard_max, .{
        .route_pattern_bytes_total_max = route_pattern_bytes_total_hard_max + 1,
    }, "PLOOF-E3113");
    try expectIssue(.index_nodes_zero, .{
        .index_nodes_max = 0,
    }, "PLOOF-E3114");
    try expectIssue(.index_nodes_above_hard_max, .{
        .index_nodes_max = index_nodes_hard_max + 1,
    }, "PLOOF-E3115");
    try expectIssue(.search_visits_zero, .{
        .search_visits_max = 0,
    }, "PLOOF-E3116");
    try expectIssue(.search_visits_above_hard_max, .{
        .search_visits_max = search_visits_hard_max + 1,
    }, "PLOOF-E3117");
    try expectIssue(.search_compare_bytes_zero, .{
        .search_compare_bytes_max = 0,
    }, "PLOOF-E3118");
    try expectIssue(.search_compare_bytes_above_hard_max, .{
        .search_compare_bytes_max = search_compare_bytes_hard_max + 1,
    }, "PLOOF-E3119");
}

test "route builders preserve heterogeneous descriptor data" {
    const custom_limits = response.HeadLimits{
        .head_bytes_max = 32 * 1024,
        .field_line_bytes_max = 8 * 1024,
        .fields_max = 96,
    };
    const plain = get("/one", handlerOne);
    const custom = configured(
        .post,
        "/two",
        handlerTwo,
        .{middlewareOne},
        custom_limits,
    );

    try std.testing.expectEqual(DescriptorKind.route, plain.kind);
    try std.testing.expectEqual(Method.get, plain.method);
    try std.testing.expectEqualStrings("/one", plain.path);
    try std.testing.expectEqual(@as(u8, 1), plain.handler());
    try std.testing.expectEqual(@as(usize, 0), plain.middleware.len);
    try std.testing.expectEqual(@as(?response.HeadLimits, null), plain.response_head_limits);
    try std.testing.expectEqual(@as(?cors.Policy, null), plain.cors_policy);

    try std.testing.expectEqual(Method.post, custom.method);
    try std.testing.expectEqualStrings("/two", custom.path);
    try std.testing.expectEqual(@as(u16, 2), custom.handler());
    try std.testing.expectEqual(@as(u8, 3), custom.middleware[0]());
    try std.testing.expectEqual(custom_limits, custom.response_head_limits.?);
}

test "method conveniences and groups keep exact shapes" {
    const routes = .{
        head("/head", handlerOne),
        post("/post", handlerOne),
        put("/put", handlerOne),
        patch("/patch", handlerOne),
        delete("/delete", handlerOne),
    };
    const nested = group("/v1", .{middlewareOne}, routes);

    try std.testing.expectEqual(DescriptorKind.group, nested.kind);
    try std.testing.expectEqualStrings("/v1", nested.prefix);
    try std.testing.expectEqual(@as(u8, 3), nested.middleware[0]());
    try std.testing.expectEqual(@as(?cors.Policy, null), nested.cors_policy);
    inline for (routes, 0..) |entry, index| {
        try std.testing.expectEqual(entry.method, nested.children[index].method);
        try std.testing.expectEqualStrings(entry.path, nested.children[index].path);
    }
}

test "route and group CORS configuration preserves descriptor shapes" {
    const route_policy = comptime cors.exact(&.{"https://app.example"}, .{
        .credentials = true,
    });
    const selected_route = get("/one", handlerOne).withCors(route_policy);
    const plain_group = group("/v1", .{}, .{selected_route});
    const selected_group = plain_group.withCors(cors.allow_any);

    try std.testing.expect(selected_route.cors_policy.? == .allow_exact);
    try std.testing.expect(selected_route.cors_policy.?.sendsCredentials());
    try std.testing.expect(selected_group.cors_policy.? == .allow_any);
    try std.testing.expectEqualStrings("/one", selected_group.children[0].path);
}

fn expectIssue(
    expected: GraphLimitIssue,
    limits: GraphLimits,
    prefix: []const u8,
) !void {
    const actual = limits.issue() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected, actual);
    try std.testing.expect(std.mem.startsWith(u8, actual.diagnostic(), prefix));
}
