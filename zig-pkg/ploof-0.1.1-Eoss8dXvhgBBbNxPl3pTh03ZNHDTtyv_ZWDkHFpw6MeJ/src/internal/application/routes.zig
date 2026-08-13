const std = @import("std");
const application_body = @import("body.zig");
const application_finite_output = @import("finite_output.zig");
const application_stream_pipeline = @import("stream_pipeline.zig");
const route = @import("../../route.zig");

pub const Definition = struct {
    method: route.Method,
    path: []const u8,
    route_id: u16,
};

const target_evaluation_branches_per_route: u32 = 256;
const target_evaluation_quota: u32 =
    @as(u32, route.routes_hard_max) * target_evaluation_branches_per_route;

pub fn count(comptime descriptors: anytype) usize {
    var result: usize = 0;
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route, .static_dir, .static_file => result += 1,
        .group => result += count(descriptor.children),
    };
    return result;
}

pub fn definitions(
    comptime descriptors: anytype,
    comptime definition_count: usize,
) [definition_count]Definition {
    var result: [definition_count]Definition = undefined;
    var index: usize = 0;
    fillDefinitions(descriptors, "", &result, &index);
    return result;
}

pub fn target(
    comptime descriptors: anytype,
    comptime descriptor: anytype,
) *const route.RouteTarget {
    @setEvalBranchQuota(target_evaluation_quota);
    validateTargetDescriptor(descriptor);
    var search = TargetSearch{};
    findTarget(
        descriptors,
        "",
        descriptor.descriptor_identity,
        descriptor.method,
        descriptor.path,
        &search,
    );
    if (search.matches == 0) {
        @compileError("PLOOF-E3734 routeTarget descriptor is not in Application routes");
    }
    if (search.matches != 1) {
        @compileError("PLOOF-E3735 routeTarget descriptor is mounted more than once");
    }
    const found = search.found.?;
    return route.__target(
        found.method,
        found.path,
        found.declared_path,
        found.route_id,
        found.descriptor_identity,
    );
}

const TargetCandidate = struct {
    method: route.Method,
    path: []const u8,
    declared_path: []const u8,
    route_id: u16,
    descriptor_identity: *const route.DescriptorIdentity,
};

const TargetSearch = struct {
    route_index: usize = 0,
    matches: usize = 0,
    found: ?TargetCandidate = null,
};

fn validateTargetDescriptor(comptime descriptor: anytype) void {
    const Descriptor = @TypeOf(descriptor);
    if (@typeInfo(Descriptor) != .@"struct" or
        !@hasField(Descriptor, "kind") or
        !@hasField(Descriptor, "descriptor_identity") or
        !@hasField(Descriptor, "method") or
        !@hasField(Descriptor, "path"))
    {
        @compileError("PLOOF-E3733 routeTarget requires a route descriptor");
    }
    if (@TypeOf(descriptor.kind) != route.DescriptorKind or descriptor.kind != .route or
        @TypeOf(descriptor.descriptor_identity) != *const route.DescriptorIdentity or
        @TypeOf(descriptor.method) != route.Method or
        @TypeOf(descriptor.path) != []const u8)
    {
        @compileError("PLOOF-E3733 routeTarget requires a route descriptor");
    }
}

fn findTarget(
    comptime descriptors: anytype,
    comptime prefix: []const u8,
    requested: *const route.DescriptorIdentity,
    requested_method: route.Method,
    requested_path: []const u8,
    search: *TargetSearch,
) void {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => {
            if (descriptor.descriptor_identity == requested and
                descriptor.method == requested_method and
                std.mem.eql(u8, descriptor.path, requested_path))
            {
                search.matches += 1;
                if (search.found == null) search.found = .{
                    .method = descriptor.method,
                    .path = prefix ++ descriptor.path,
                    .declared_path = descriptor.path,
                    .route_id = @intCast(search.route_index),
                    .descriptor_identity = descriptor.descriptor_identity,
                };
            }
            search.route_index += 1;
        },
        .static_dir, .static_file => search.route_index += 1,
        .group => findTarget(
            descriptor.children,
            prefix ++ descriptor.prefix,
            requested,
            requested_method,
            requested_path,
            search,
        ),
    };
}

pub fn bodyPlans(
    comptime descriptors: anytype,
    comptime route_count: usize,
) [route_count]application_body.Plan {
    var result: [route_count]application_body.Plan = undefined;
    var index: usize = 0;
    fillBodyPlans(descriptors, &result, &index);
    return result;
}

pub fn finiteOutputPlans(
    comptime descriptors: anytype,
    comptime route_count: usize,
) [route_count]application_finite_output.Plan {
    var result: [route_count]application_finite_output.Plan = undefined;
    var index: usize = 0;
    fillFiniteOutputPlans(descriptors, &result, &index);
    return result;
}

pub fn hasBodyEndpoint(comptime descriptors: anytype) bool {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => if (application_body.isEndpoint(descriptor.handler)) return true,
        .static_dir, .static_file => {},
        .group => if (hasBodyEndpoint(descriptor.children)) return true,
    };
    return false;
}

pub fn hasRequestBodyEndpoint(comptime descriptors: anytype) bool {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => if (application_body.acceptsRequestBody(descriptor.handler)) return true,
        .static_dir, .static_file => {},
        .group => if (hasRequestBodyEndpoint(descriptor.children)) return true,
    };
    return false;
}

pub fn hasMultipartEndpoint(comptime descriptors: anytype) bool {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => {
            const Handler = @TypeOf(descriptor.handler);
            if (@typeInfo(Handler) == .@"struct" and
                @hasDecl(Handler, "ploof_multipart_endpoint") and
                Handler.ploof_multipart_endpoint) return true;
        },
        .static_dir, .static_file => {},
        .group => if (hasMultipartEndpoint(descriptor.children)) return true,
    };
    return false;
}

pub fn countOpenMetrics(comptime descriptors: anytype) usize {
    var count_value: usize = 0;
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => if (route.isOpenMetricsHandler(descriptor.handler)) {
            count_value += 1;
        },
        .static_dir, .static_file => {},
        .group => count_value += countOpenMetrics(descriptor.children),
    };
    return count_value;
}

pub fn maximumDecodedBodyBytes(comptime descriptors: anytype) u64 {
    var maximum: u64 = 0;
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => maximum = @max(
            maximum,
            application_body.plan(descriptor.handler).workspace_bytes_max,
        ),
        .static_dir, .static_file => {},
        .group => maximum = @max(maximum, maximumDecodedBodyBytes(descriptor.children)),
    };
    return maximum;
}

pub fn maximumWorkspaceAlignment(comptime descriptors: anytype) u32 {
    var maximum: u32 = 1;
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => maximum = @max(
            maximum,
            application_body.plan(descriptor.handler).workspace_alignment,
        ),
        .static_dir, .static_file => {},
        .group => maximum = @max(
            maximum,
            maximumWorkspaceAlignment(descriptor.children),
        ),
    };
    return maximum;
}

fn fillBodyPlans(comptime descriptors: anytype, plans: anytype, index: *usize) void {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => {
            plans[index.*] = application_body.plan(descriptor.handler);
            index.* += 1;
        },
        .static_dir, .static_file => {
            plans[index.*] = application_body.none_plan;
            index.* += 1;
        },
        .group => fillBodyPlans(descriptor.children, plans, index),
    };
}

fn fillFiniteOutputPlans(comptime descriptors: anytype, plans: anytype, index: *usize) void {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => {
            plans[index.*] = if (route.isOpenMetricsHandler(descriptor.handler))
                .contiguous
            else blk: {
                const Payload = application_stream_pipeline.handlerPayload(descriptor.handler);
                break :blk application_finite_output.forPayload(Payload);
            };
            index.* += 1;
        },
        .static_dir, .static_file => {
            plans[index.*] = .contiguous;
            index.* += 1;
        },
        .group => fillFiniteOutputPlans(descriptor.children, plans, index),
    };
}

fn fillDefinitions(
    comptime descriptors: anytype,
    comptime prefix: []const u8,
    result: anytype,
    index: *usize,
) void {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => {
            result[index.*] = .{
                .method = descriptor.method,
                .path = prefix ++ descriptor.path,
                .route_id = @intCast(index.*),
            };
            index.* += 1;
        },
        .static_dir => {
            result[index.*] = .{
                .method = .get,
                .path = prefix ++ staticDirectoryPath(descriptor.mount_path),
                .route_id = @intCast(index.*),
            };
            index.* += 1;
        },
        .static_file => {
            result[index.*] = .{
                .method = .get,
                .path = prefix ++ descriptor.url_path,
                .route_id = @intCast(index.*),
            };
            index.* += 1;
        },
        .group => fillDefinitions(
            descriptor.children,
            prefix ++ descriptor.prefix,
            result,
            index,
        ),
    };
}

fn staticDirectoryPath(comptime mount_path: []const u8) []const u8 {
    return if (std.mem.eql(u8, mount_path, "/"))
        "/*__ploof_live_static_path"
    else
        mount_path ++ "/*__ploof_live_static_path";
}

const html_response = @import("../../html/response.zig");
const html_source = @import("../../html/source.zig");
const html_template = @import("../../html/template.zig");

const PlanTestPage = html_template.Template(.{
    .View = struct {},
    .source = html_source.SourceSpec{
        .kind = .fragment,
        .graph_name = "route-plan",
        .file_path = "route-plan.html",
        .bytes = "<p>route</p>",
    },
    .encoded_bytes_max = 777,
});

fn planTestContiguous(_: *u8) u8 {
    return 0;
}

fn planTestChunks(_: *u8) html_response.TemplateResponse(PlanTestPage) {
    unreachable;
}

test "finite output plans follow recursive route id order" {
    const descriptors = comptime .{
        route.get("/plain", planTestContiguous),
        route.group("/nested", .{}, .{
            route.get("/html", planTestChunks),
        }),
    };
    const plans = comptime finiteOutputPlans(descriptors, count(descriptors));

    try std.testing.expect(plans[0] == .contiguous);
    try std.testing.expectEqual(@as(u32, 777), plans[1].chunks.encoded_bytes_max);
    try std.testing.expectEqual(@as(u32, 0), plans[1].chunks.json_scratch_bytes_max);
}
