const std = @import("std");
const file_sink_config = @import("../../multipart/file_sink_config.zig");
const multipart_upload = @import("../../multipart/upload.zig");
const route = @import("../../route.zig");
const upload_io = @import("../../upload_io.zig");
const multipart_upload_layout = @import("../multipart/upload_layout.zig");
const upload_sink_driver = @import("../upload/sink_driver.zig");

pub const FileSinkConfiguration = struct {
    sink_registry_index: u16,
    report: file_sink_config.FileSinkReport,
};

pub const UploadRouteProfile = struct {
    route_id: u16,
    window: u8,
};

pub const MultipartRouteKind = enum(u8) {
    legacy,
    upload,
};

pub const MultipartRouteStorage = enum(u8) {
    sparse,
    dense,
};

const RouteClass = enum(u8) {
    none,
    legacy,
    upload,
};

const SparseRoute = struct {
    route_id: u16,
    class: RouteClass,
};

const DispatchCounts = struct {
    routes: usize = 0,
    multipart: usize = 0,
    file: usize = 0,

    fn include(self: *DispatchCounts, other: DispatchCounts) void {
        self.routes += other.routes;
        self.multipart += other.multipart;
        self.file += other.file;
    }
};

const dispatch_evaluation_branches_per_route: u32 = 256;
// Classification still scans the complete 4096-route graph even though typed
// multipart-file dispatch has its own lower specialization bound.
pub const route_evaluation_quota: u32 =
    @as(u32, route.routes_hard_max) * dispatch_evaluation_branches_per_route;
const multipart_file_route_count_diagnostic =
    "PLOOF-E3536 multipart file route count exceeds 512";

pub fn DispatchRoutes(comptime descriptors: anytype) type {
    @setEvalBranchQuota(route_evaluation_quota);
    const counts = comptime dispatchCounts(descriptors);
    comptime validateMultipartFileRouteCount(counts.file);
    const sparse_selected = comptime sparseStorageBytes(counts.multipart) < counts.routes;
    const sparse = comptime if (sparse_selected)
        sparseRoutes(descriptors, counts.multipart)
    else
        [_]SparseRoute{};
    const dense = comptime if (sparse_selected)
        [_]RouteClass{}
    else
        denseRoutes(descriptors, counts.routes);
    const file_ids = comptime fileRouteIds(descriptors, counts.file);
    const file_handlers = comptime fileHandlerTypes(descriptors, counts.file);

    return struct {
        pub const route_count = counts.routes;
        pub const multipart_route_count = counts.multipart;
        pub const file_route_count = counts.file;
        pub const storage: MultipartRouteStorage = if (sparse_selected) .sparse else .dense;
        pub const storage_bytes: usize = if (sparse_selected)
            @sizeOf(@TypeOf(sparse))
        else
            @sizeOf(@TypeOf(dense));
        pub const file_route_ids = file_ids;
        pub const file_handler_types = file_handlers;

        pub fn routeKind(route_id: u16) ?MultipartRouteKind {
            const class = if (sparse_selected)
                sparseRouteClass(&sparse, route_id)
            else if (route_id < dense.len)
                dense[route_id]
            else
                .none;
            return switch (class) {
                .none => null,
                .legacy => .legacy,
                .upload => .upload,
            };
        }

        pub fn hasFiles(route_id: u16) ?bool {
            const kind = routeKind(route_id) orelse return null;
            return kind == .upload;
        }
    };
}

pub fn Catalog(comptime descriptors: anytype) type {
    const dispatch_counts = comptime dispatchCounts(descriptors);
    comptime validateMultipartFileRouteCount(dispatch_counts.file);
    const sink_count = comptime uniqueSinkCount(descriptors);
    comptime validateSinkCount(sink_count);
    const sinks = comptime uniqueSinkTypes(descriptors, sink_count);
    const Drivers = driverStorage(sinks);
    const requirements = mergedRequirements(sinks);
    const file_sink_count = comptime fileSinkConfigurationCount(sinks);
    const upload_route_count = comptime uploadRouteProfileCount(descriptors);

    return struct {
        pub const sink_types = sinks;
        pub const unique_sink_count: usize = sinks.len;
        pub const io_requirements = requirements;
        pub const runtime_handles_max: u32 = runtimeHandlesMaximum(sinks);
        pub const request_handles_max: u32 = maximumRequestHandles(descriptors);
        pub const upload_window_max: u32 = maximumUploadWindow(descriptors);
        pub const upload_route_profiles = uploadRouteProfiles(
            descriptors,
            upload_route_count,
        );
        pub const finalization_instances_max: u16 = maximumFinalizationInstances(descriptors);
        pub const sink_present: bool = sinks.len != 0;
        pub const async_sink_present: bool = requirementBits(requirements) != 0;
        pub const file_sink_configurations = fileSinkConfigurations(
            sinks,
            file_sink_count,
        );

        pub fn indexOf(comptime Sink: type) u16 {
            return sinkIndex(sinks, Sink);
        }

        pub const Registry = struct {
            const Self = @This();

            pub const ploof_template_helper_capability = true;
            drivers: Drivers = initialDrivers(sinks, Drivers),

            pub fn indexOf(comptime Sink: type) u16 {
                return sinkIndex(sinks, Sink);
            }

            pub fn get(self: *Self, comptime Sink: type) ?*Sink.Runtime {
                return self.driver(Sink).runtimePointer();
            }

            pub fn driver(
                self: *Self,
                comptime Sink: type,
            ) *upload_sink_driver.Runtime(Sink) {
                return &self.drivers[comptime sinkIndex(sinks, Sink)];
            }
        };
    };
}

fn dispatchCounts(comptime descriptors: anytype) DispatchCounts {
    var result = DispatchCounts{};
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => {
            result.routes += 1;
            const Handler = @TypeOf(descriptor.handler);
            if (comptime isMultipartHandler(Handler)) {
                result.multipart += 1;
                result.file += @intFromBool(handlerHasFiles(Handler));
            }
        },
        .static_dir, .static_file => result.routes += 1,
        .group => result.include(dispatchCounts(descriptor.children)),
    };
    return result;
}

fn validateMultipartFileRouteCount(count: usize) void {
    if (count > multipart_upload.multipart_file_routes_hard_max) {
        @compileError(multipart_file_route_count_diagnostic);
    }
}

fn sparseStorageBytes(multipart_count: usize) usize {
    return multipart_count * @sizeOf(SparseRoute);
}

fn sparseRoutes(
    comptime descriptors: anytype,
    comptime count: usize,
) [count]SparseRoute {
    var result: [count]SparseRoute = undefined;
    var route_id: usize = 0;
    var used: usize = 0;
    fillSparseRoutes(descriptors, &result, &route_id, &used);
    return result;
}

fn fillSparseRoutes(
    comptime descriptors: anytype,
    result: anytype,
    route_id: *usize,
    used: *usize,
) void {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => {
            const Handler = @TypeOf(descriptor.handler);
            if (comptime isMultipartHandler(Handler)) {
                result[used.*] = .{
                    .route_id = @intCast(route_id.*),
                    .class = handlerRouteClass(Handler),
                };
                used.* += 1;
            }
            route_id.* += 1;
        },
        .static_dir, .static_file => route_id.* += 1,
        .group => fillSparseRoutes(descriptor.children, result, route_id, used),
    };
}

fn denseRoutes(
    comptime descriptors: anytype,
    comptime count: usize,
) [count]RouteClass {
    var result = [_]RouteClass{.none} ** count;
    var route_id: usize = 0;
    fillDenseRoutes(descriptors, &result, &route_id);
    return result;
}

fn fillDenseRoutes(
    comptime descriptors: anytype,
    result: anytype,
    route_id: *usize,
) void {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => {
            const Handler = @TypeOf(descriptor.handler);
            if (comptime isMultipartHandler(Handler)) {
                result[route_id.*] = handlerRouteClass(Handler);
            }
            route_id.* += 1;
        },
        .static_dir, .static_file => route_id.* += 1,
        .group => fillDenseRoutes(descriptor.children, result, route_id),
    };
}

fn sparseRouteClass(routes: []const SparseRoute, route_id: u16) RouteClass {
    var low: usize = 0;
    var high = routes.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const candidate = routes[middle];
        if (route_id < candidate.route_id) {
            high = middle;
        } else if (route_id > candidate.route_id) {
            low = middle + 1;
        } else {
            return candidate.class;
        }
    }
    return .none;
}

fn fileRouteIds(
    comptime descriptors: anytype,
    comptime count: usize,
) [count]u16 {
    var result: [count]u16 = undefined;
    var route_id: usize = 0;
    var used: usize = 0;
    fillFileRouteIds(descriptors, &result, &route_id, &used);
    return result;
}

fn fillFileRouteIds(
    comptime descriptors: anytype,
    result: anytype,
    route_id: *usize,
    used: *usize,
) void {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => {
            const Handler = @TypeOf(descriptor.handler);
            if (comptime handlerHasFiles(Handler)) {
                result[used.*] = @intCast(route_id.*);
                used.* += 1;
            }
            route_id.* += 1;
        },
        .static_dir, .static_file => route_id.* += 1,
        .group => fillFileRouteIds(descriptor.children, result, route_id, used),
    };
}

fn fileHandlerTypes(
    comptime descriptors: anytype,
    comptime count: usize,
) [count]type {
    var result: [count]type = undefined;
    var used: usize = 0;
    fillFileHandlerTypes(descriptors, &result, &used);
    return result;
}

fn fillFileHandlerTypes(
    comptime descriptors: anytype,
    result: anytype,
    used: *usize,
) void {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => {
            const Handler = @TypeOf(descriptor.handler);
            if (comptime handlerHasFiles(Handler)) {
                result[used.*] = Handler;
                used.* += 1;
            }
        },
        .static_dir, .static_file => {},
        .group => fillFileHandlerTypes(descriptor.children, result, used),
    };
}

fn handlerRouteClass(comptime Handler: type) RouteClass {
    return if (handlerHasFiles(Handler)) .upload else .legacy;
}

fn handlerHasFiles(comptime Handler: type) bool {
    if (!isMultipartHandler(Handler)) return false;
    return Handler.definition.MultipartBodySpec.File != void;
}

fn uploadRouteProfiles(
    comptime descriptors: anytype,
    comptime count: usize,
) [count]UploadRouteProfile {
    var result: [count]UploadRouteProfile = undefined;
    var route_id: usize = 0;
    var profile_index: usize = 0;
    fillUploadRouteProfiles(descriptors, &result, &route_id, &profile_index);
    return result;
}

fn fillUploadRouteProfiles(
    comptime descriptors: anytype,
    profiles: anytype,
    route_id: *usize,
    profile_index: *usize,
) void {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => {
            const window = handlerUploadWindow(@TypeOf(descriptor.handler));
            if (window != 0) {
                profiles[profile_index.*] = .{
                    .route_id = @intCast(route_id.*),
                    .window = @intCast(window),
                };
                profile_index.* += 1;
            }
            route_id.* += 1;
        },
        .static_dir, .static_file => route_id.* += 1,
        .group => fillUploadRouteProfiles(
            descriptor.children,
            profiles,
            route_id,
            profile_index,
        ),
    };
}

fn uploadRouteProfileCount(comptime descriptors: anytype) usize {
    var count: usize = 0;
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => count += @intFromBool(
            handlerUploadWindow(@TypeOf(descriptor.handler)) != 0,
        ),
        .static_dir, .static_file => {},
        .group => count += uploadRouteProfileCount(descriptor.children),
    };
    return count;
}

fn fileSinkConfigurations(
    comptime sinks: anytype,
    comptime count: usize,
) [count]FileSinkConfiguration {
    var result: [count]FileSinkConfiguration = undefined;
    var used: usize = 0;
    inline for (sinks, 0..) |Sink, index| {
        if (comptime !hasFileSinkReport(Sink)) continue;
        result[used] = .{
            .sink_registry_index = @intCast(index),
            .report = Sink.startup_report,
        };
        used += 1;
    }
    return result;
}

fn fileSinkConfigurationCount(comptime sinks: anytype) usize {
    var count: usize = 0;
    inline for (sinks) |Sink| count += @intFromBool(hasFileSinkReport(Sink));
    return count;
}

fn hasFileSinkReport(comptime Sink: type) bool {
    if (!@hasDecl(Sink, "startup_report")) return false;
    return @TypeOf(Sink.startup_report) == file_sink_config.FileSinkReport;
}

fn sinkIndex(comptime sinks: anytype, comptime Sink: type) u16 {
    inline for (sinks, 0..) |Candidate, index| {
        if (comptime Sink == Candidate) return @intCast(index);
    }
    @compileError("multipart sink is not configured by this application");
}

fn uniqueSinkTypes(
    comptime descriptors: anytype,
    comptime sink_count: usize,
) [sink_count]type {
    const capacity = sinkOccurrenceCount(descriptors);
    var scratch: [capacity]type = undefined;
    var used: usize = 0;
    collectUniqueSinks(descriptors, &scratch, &used);

    var result: [sink_count]type = undefined;
    inline for (0..result.len) |index| result[index] = scratch[index];
    return result;
}

fn validateSinkCount(comptime sink_count: usize) void {
    if (!sinkCountFitsId(sink_count)) {
        @compileError("PLOOF-E3520 multipart application sink count exceeds 65536");
    }
}

fn sinkCountFitsId(sink_count: usize) bool {
    const capacity = @as(usize, std.math.maxInt(u16)) + 1;
    return sink_count <= capacity;
}

fn uniqueSinkCount(comptime descriptors: anytype) usize {
    var scratch: [sinkOccurrenceCount(descriptors)]type = undefined;
    var used: usize = 0;
    collectUniqueSinks(descriptors, &scratch, &used);
    return used;
}

fn collectUniqueSinks(
    comptime descriptors: anytype,
    sinks: anytype,
    used: *usize,
) void {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => collectHandlerSinks(@TypeOf(descriptor.handler), sinks, used),
        .static_dir, .static_file => {},
        .group => collectUniqueSinks(descriptor.children, sinks, used),
    };
}

fn collectHandlerSinks(comptime Handler: type, sinks: anytype, used: *usize) void {
    if (comptime !isMultipartHandler(Handler)) return;
    const Spec = Handler.definition.MultipartBodySpec;
    inline for (@typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(Spec.configured_schema, field.name));
        if (comptime Part.kind != .file) continue;
        const Sink = Part.SinkType;
        if (comptime isDiscardSink(Sink) or containsSink(sinks, used.*, Sink)) continue;
        sinks[used.*] = Sink;
        used.* += 1;
    }
}

fn containsSink(sinks: anytype, used: usize, comptime Sink: type) bool {
    var index: usize = 0;
    while (index < used) : (index += 1) {
        if (sinks[index] == Sink) return true;
    }
    return false;
}

fn sinkOccurrenceCount(comptime descriptors: anytype) usize {
    var count: usize = 0;
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => count += handlerSinkOccurrenceCount(@TypeOf(descriptor.handler)),
        .static_dir, .static_file => {},
        .group => count += sinkOccurrenceCount(descriptor.children),
    };
    return count;
}

fn handlerSinkOccurrenceCount(comptime Handler: type) usize {
    if (!isMultipartHandler(Handler)) return 0;
    const Spec = Handler.definition.MultipartBodySpec;
    var count: usize = 0;
    inline for (@typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(Spec.configured_schema, field.name));
        if (Part.kind == .file and !isDiscardSink(Part.SinkType)) count += 1;
    }
    return count;
}

fn driverStorage(comptime sinks: anytype) type {
    var types: [sinks.len]type = undefined;
    inline for (sinks, 0..) |Sink, index| {
        types[index] = upload_sink_driver.Runtime(Sink);
    }
    return std.meta.Tuple(&types);
}

fn initialDrivers(comptime sinks: anytype, comptime Drivers: type) Drivers {
    var drivers: Drivers = undefined;
    inline for (sinks, 0..) |_, index| drivers[index] = .{};
    return drivers;
}

fn mergedRequirements(comptime sinks: anytype) upload_io.IoRequirements {
    var requirements = upload_io.IoRequirements.none;
    inline for (sinks) |Sink| requirements = requirements.merge(Sink.io_requirements);
    return requirements;
}

fn runtimeHandlesMaximum(comptime sinks: anytype) u32 {
    var total: u32 = 0;
    inline for (sinks) |Sink| total += Sink.runtime_handles_max;
    return total;
}

fn maximumRequestHandles(comptime descriptors: anytype) u32 {
    var maximum: u32 = 0;
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => maximum = @max(
            maximum,
            handlerRequestHandles(@TypeOf(descriptor.handler)),
        ),
        .static_dir, .static_file => {},
        .group => maximum = @max(
            maximum,
            maximumRequestHandles(descriptor.children),
        ),
    };
    return maximum;
}

fn handlerRequestHandles(comptime Handler: type) u32 {
    if (!isMultipartHandler(Handler)) return 0;
    const Spec = Handler.definition.MultipartBodySpec;
    if (!hasFilePart(Spec)) return 0;
    return multipart_upload_layout.Layout(Spec).request_handles_maximum;
}

fn maximumUploadWindow(comptime descriptors: anytype) u32 {
    var maximum: u32 = 0;
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => maximum = @max(
            maximum,
            handlerUploadWindow(@TypeOf(descriptor.handler)),
        ),
        .static_dir, .static_file => {},
        .group => maximum = @max(
            maximum,
            maximumUploadWindow(descriptor.children),
        ),
    };
    return maximum;
}

fn maximumFinalizationInstances(comptime descriptors: anytype) u16 {
    var maximum: usize = 0;
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => maximum = @max(
            maximum,
            handlerFinalizationInstances(@TypeOf(descriptor.handler)),
        ),
        .static_dir, .static_file => {},
        .group => maximum = @max(
            maximum,
            maximumFinalizationInstances(descriptor.children),
        ),
    };
    if (maximum > std.math.maxInt(u16)) {
        @compileError("PLOOF-E3521 multipart finalization instances exceed u16");
    }
    return @intCast(maximum);
}

fn handlerFinalizationInstances(comptime Handler: type) usize {
    if (!isMultipartHandler(Handler)) return 0;
    const Spec = Handler.definition.MultipartBodySpec;
    if (!hasFilePart(Spec)) return 0;
    return multipart_upload_layout.Layout(Spec).non_discard_total_maximum;
}

fn handlerUploadWindow(comptime Handler: type) u32 {
    if (!isMultipartHandler(Handler)) return 0;
    const Spec = Handler.definition.MultipartBodySpec;
    if (requirementBits(specRequirements(Spec)) == 0) return 0;
    return Spec.resolved_options.upload.window;
}

fn hasFilePart(comptime Spec: type) bool {
    inline for (@typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(Spec.configured_schema, field.name));
        if (Part.kind == .file) return true;
    }
    return false;
}

fn specRequirements(comptime Spec: type) upload_io.IoRequirements {
    var requirements = upload_io.IoRequirements.none;
    inline for (@typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(Spec.configured_schema, field.name));
        if (Part.kind != .file or isDiscardSink(Part.SinkType)) continue;
        requirements = requirements.merge(Part.SinkType.io_requirements);
    }
    return requirements;
}

fn requirementBits(requirements: upload_io.IoRequirements) u8 {
    return @bitCast(requirements);
}

fn isMultipartHandler(comptime Handler: type) bool {
    return @typeInfo(Handler) == .@"struct" and
        @hasDecl(Handler, "ploof_multipart_endpoint") and
        Handler.ploof_multipart_endpoint;
}

fn isDiscardSink(comptime Sink: type) bool {
    return Sink == multipart_upload.DiscardSink;
}

test {
    std.testing.refAllDecls(@This());
}

test "u16 sink ids cover exactly 65536 catalog entries" {
    comptime {
        validateSinkCount(65_536);
        std.debug.assert(sinkCountFitsId(65_536));
        std.debug.assert(!sinkCountFitsId(65_537));
    }

    try std.testing.expect(sinkCountFitsId(65_536));
    try std.testing.expect(!sinkCountFitsId(65_537));
}

test "dispatch evaluation quota derives from the hard route bound" {
    comptime {
        std.debug.assert(route.routes_hard_max == 4096);
        std.debug.assert(route_evaluation_quota == 1_048_576);
    }

    try std.testing.expectEqual(@as(u32, 1_048_576), route_evaluation_quota);
}

test "multipart file route count accepts its public hard boundary" {
    comptime {
        std.debug.assert(multipart_upload.multipart_file_routes_hard_max == 512);
        validateMultipartFileRouteCount(511);
        validateMultipartFileRouteCount(512);
    }

    try std.testing.expectEqual(
        @as(u16, 512),
        multipart_upload.multipart_file_routes_hard_max,
    );
}
