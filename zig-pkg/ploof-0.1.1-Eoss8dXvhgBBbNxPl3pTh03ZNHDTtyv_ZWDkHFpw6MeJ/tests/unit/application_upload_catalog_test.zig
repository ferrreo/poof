const std = @import("std");
const application = @import("../../src/application.zig");
const endpoint = @import("../../src/endpoint.zig");
const multipart = @import("../../src/multipart.zig");
const multipart_file_sink = @import("../../src/multipart/file_sink.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const startup = @import("../../src/startup.zig");
const catalog = @import("../../src/internal/application/upload_catalog.zig");

const Context = application.Context(void, response.standard_head_limits);

const Anonymous = multipart_file_sink.FileSink(.{
    .root = "anonymous",
    .durability = .buffered,
});
const NamedDurable = multipart_file_sink.FileSink(.{
    .root = "named",
    .durability = .crash_durable,
    .staging = .{ .named_staging = ".stage" },
});

fn Consumer(comptime Spec: type, comptime BodyInput: type) type {
    return struct {
        pub const State = void;

        pub fn fileStart(
            _: @This(),
            _: *Context,
            _: *State,
            event: Spec.FileStart,
        ) Spec.FileAdmission(Context.ResponseType) {
            if (comptime @hasField(Spec.FileStart, "discard")) switch (event) {
                .discard => return .{ .accept = .{ .discard = {} } },
                inline else => {},
            };
            unreachable;
        }

        pub fn complete(
            _: @This(),
            context: *Context,
            _: *State,
            _: BodyInput,
            _: Spec.Summaries,
        ) multipart.Decision(Context.ResponseType) {
            return multipart.commit(context.empty(.no_content));
        }
    };
}

const Synchronous = struct {
    pub const ploof_multipart_sink = true;
    pub const State = multipart.DiscardSink.State;
    pub const WriteState = multipart.DiscardSink.WriteState;
    pub const Summary = multipart.DiscardSink.Summary;
    pub const BeginInput = multipart.DiscardSink.BeginInput;
    pub const Runtime = multipart.DiscardSink.Runtime;
    pub const StartupState = multipart.DiscardSink.StartupState;
    pub const io_requirements = multipart.DiscardSink.io_requirements;
    pub const request_handles_max = multipart.DiscardSink.request_handles_max;
    pub const runtime_handles_max = multipart.DiscardSink.runtime_handles_max;
    pub const Error = multipart.DiscardSink.Error;
    pub const initial_state = multipart.DiscardSink.initial_state;
    pub const initial_write_state = multipart.DiscardSink.initial_write_state;
    pub const initial_startup_state = multipart.DiscardSink.initial_startup_state;
    pub const runtimeStart = multipart.DiscardSink.runtimeStart;
    pub const runtimeStop = multipart.DiscardSink.runtimeStop;
    pub const begin = multipart.DiscardSink.begin;
    pub const write = multipart.DiscardSink.write;
    pub const finish = multipart.DiscardSink.finish;
    pub const commit = multipart.DiscardSink.commit;
    pub const abort = multipart.DiscardSink.abort;
};

const first_spec = multipart.decode(.{
    .first = multipart.file(Anonymous, multipart.oneTo(2)),
    .same_type = multipart.file(Anonymous, multipart.optional),
    .discard = multipart.file(multipart.DiscardSink, multipart.optional),
}, .{
    .limits = .{ .parts_max = 4, .files_max = 4 },
    .upload = .{ .window = 3, .chunk_bytes = 64 },
});
const FirstDefinition = endpoint.Endpoint(.{ .body = first_spec });
const first_handler = FirstDefinition.handle(
    Consumer(@TypeOf(first_spec), FirstDefinition.InputType){},
);

const second_spec = multipart.decode(.{
    .same_type = multipart.file(Anonymous, multipart.required),
    .second = multipart.file(NamedDurable, multipart.oneTo(3)),
}, .{
    .limits = .{ .parts_max = 4, .files_max = 4 },
    .upload = .{ .window = 7, .chunk_bytes = 128 },
});
const SecondDefinition = endpoint.Endpoint(.{ .body = second_spec });
const second_handler = SecondDefinition.handle(
    Consumer(@TypeOf(second_spec), SecondDefinition.InputType){},
);

const synchronous_spec = multipart.decode(.{
    .file = multipart.file(Synchronous, multipart.required),
}, .{
    .limits = .{ .parts_max = 1, .files_max = 1 },
    .upload = .{ .window = 13, .chunk_bytes = 32 },
});
const SynchronousDefinition = endpoint.Endpoint(.{ .body = synchronous_spec });
const synchronous_handler = SynchronousDefinition.handle(
    Consumer(@TypeOf(synchronous_spec), SynchronousDefinition.InputType){},
);

const configured_routes = .{
    route.post("/first", first_handler),
    route.group("/nested", .{}, .{
        route.post("/second", second_handler),
    }),
};
const UploadApplication = application.Application(.{
    .State = void,
    .routes = configured_routes,
});

const report_routes = .{
    route.post("/first", first_handler),
    route.post("/custom", synchronous_handler),
    route.post("/second", second_handler),
};
const ReportApplication = application.Application(.{
    .State = void,
    .routes = report_routes,
});

test "catalog deduplicates nested sinks and reports exact application maxima" {
    const Catalog = catalog.Catalog(configured_routes);

    try std.testing.expect(Anonymous != NamedDurable);
    try std.testing.expectEqual(@as(usize, 2), Catalog.unique_sink_count);
    try std.testing.expect(Catalog.sink_types[0] == Anonymous);
    try std.testing.expect(Catalog.sink_types[1] == NamedDurable);
    try std.testing.expectEqual(@as(u16, 0), Catalog.indexOf(Anonymous));
    try std.testing.expectEqual(@as(u16, 1), Catalog.indexOf(NamedDurable));
    try std.testing.expectEqual(@as(u16, 0), Catalog.Registry.indexOf(Anonymous));
    try std.testing.expectEqual(@as(u16, 1), Catalog.Registry.indexOf(NamedDurable));
    inline for (Catalog.sink_types, 0..) |Sink, index| {
        const expected: u16 = @intCast(index);
        try std.testing.expectEqual(expected, Catalog.indexOf(Sink));
        try std.testing.expectEqual(expected, Catalog.Registry.indexOf(Sink));
    }
    try std.testing.expectEqual(@as(u8, 0x7f), @as(u8, @bitCast(Catalog.io_requirements)));
    try std.testing.expectEqual(@as(u32, 5), Catalog.runtime_handles_max);
    try std.testing.expectEqual(@as(u32, 8), Catalog.request_handles_max);
    try std.testing.expectEqual(@as(u32, 7), Catalog.upload_window_max);
    try std.testing.expectEqualDeep(
        [_]catalog.UploadRouteProfile{
            .{ .route_id = 0, .window = 3 },
            .{ .route_id = 1, .window = 7 },
        },
        Catalog.upload_route_profiles,
    );
    try std.testing.expectEqual(@as(u16, 4), Catalog.finalization_instances_max);
    try std.testing.expect(Catalog.sink_present);
    try std.testing.expect(Catalog.async_sink_present);

    const configurations = Catalog.file_sink_configurations;
    try std.testing.expectEqual(@as(usize, 2), configurations.len);
    try std.testing.expectEqual(@as(u16, 0), configurations[0].sink_registry_index);
    try std.testing.expectEqualDeep(Anonymous.startup_report, configurations[0].report);
    try std.testing.expectEqual(@as(u16, 1), configurations[1].sink_registry_index);
    try std.testing.expectEqualDeep(NamedDurable.startup_report, configurations[1].report);
}

test "registry keeps typed runtime drivers in catalog declaration order" {
    const Catalog = catalog.Catalog(configured_routes);
    var registry = Catalog.Registry{};

    comptime {
        std.debug.assert(Catalog.indexOf(Anonymous) == 0);
        std.debug.assert(Catalog.indexOf(NamedDurable) == 1);
        std.debug.assert(Catalog.Registry.indexOf(Anonymous) == 0);
        std.debug.assert(Catalog.Registry.indexOf(NamedDurable) == 1);
    }

    const anonymous_driver = registry.driver(Anonymous);
    const named_driver = registry.driver(NamedDurable);
    try std.testing.expect(@TypeOf(anonymous_driver) ==
        *@import("../../src/internal/upload/sink_driver.zig").Runtime(Anonymous));
    try std.testing.expect(@TypeOf(named_driver) ==
        *@import("../../src/internal/upload/sink_driver.zig").Runtime(NamedDurable));
    try std.testing.expect(anonymous_driver == &registry.drivers[0]);
    try std.testing.expect(named_driver == &registry.drivers[1]);

    anonymous_driver.value = @as(Anonymous.Runtime, undefined);
    named_driver.value = @as(NamedDurable.Runtime, undefined);
    try std.testing.expect(registry.get(Anonymous) == &anonymous_driver.value.?);
    try std.testing.expect(registry.get(NamedDurable) == &named_driver.value.?);
}

test "Application exports exact catalog upload capacities and stable sink ids" {
    const App = UploadApplication;

    try std.testing.expect(App.UploadRegistry == App.UploadCatalog.Registry);
    try std.testing.expectEqual(
        @as(u8, @bitCast(App.UploadCatalog.io_requirements)),
        @as(u8, @bitCast(App.upload_io_requirements)),
    );
    try std.testing.expectEqual(App.UploadCatalog.upload_window_max, App.upload_window_max);
    try std.testing.expectEqual(
        App.UploadCatalog.request_handles_max,
        App.upload_request_handles_max,
    );
    try std.testing.expectEqual(
        App.UploadCatalog.runtime_handles_max,
        App.upload_runtime_handles_max,
    );
    try std.testing.expectEqual(
        App.UploadCatalog.finalization_instances_max,
        App.upload_finalization_instances_max,
    );
    try std.testing.expectEqual(
        App.UploadCatalog.async_sink_present,
        App.upload_async_sink_present,
    );
    try std.testing.expectEqual(App.UploadCatalog.sink_present, App.upload_sink_present);
    inline for (App.UploadCatalog.sink_types) |Sink| {
        try std.testing.expectEqual(
            App.UploadCatalog.indexOf(Sink),
            App.UploadRegistry.indexOf(Sink),
        );
    }
    try std.testing.expectEqualDeep(
        App.UploadCatalog.file_sink_configurations,
        App.upload_file_sink_configurations,
    );
    try std.testing.expectEqualDeep(
        App.UploadCatalog.upload_route_profiles,
        App.upload_route_profiles,
    );
}

test "startup configuration report views fixed application FileSink catalog" {
    const report = startup.configurationReport(UploadApplication);
    const configured = UploadApplication.upload_file_sink_configurations[0..];

    try std.testing.expectEqual(@as(usize, 2), report.file_sinks.len);
    try std.testing.expectEqualDeep(
        UploadApplication.upload_route_profiles[0..],
        report.upload_routes,
    );
    try std.testing.expectEqual(
        @sizeOf(@import("../../src/internal/runtime/worker/upload_route_metrics.zig").Cell),
        report.upload_route_metric_cell_bytes,
    );
    try std.testing.expectEqual(
        @as(u64, report.upload_route_metric_cell_bytes) * report.upload_routes.len,
        report.upload_route_metrics_per_worker_bytes,
    );
    try std.testing.expect(report.file_sinks.ptr == configured.ptr);
    try std.testing.expectEqual(@as(u16, 0), report.file_sinks[0].sink_registry_index);
    try std.testing.expectEqual(.anonymous_required, report.file_sinks[0].report.staging);
    try std.testing.expectEqual(.buffered, report.file_sinks[0].report.durability);
    try std.testing.expectEqual(@as(u16, 1), report.file_sinks[1].sink_registry_index);
    try std.testing.expectEqual(.named_staging, report.file_sinks[1].report.staging);
    try std.testing.expectEqual(.crash_durable, report.file_sinks[1].report.durability);
}

test "FileSink records keep registry indexes across an unreported custom sink" {
    const Catalog = ReportApplication.UploadCatalog;
    const report = startup.configurationReport(ReportApplication);

    try std.testing.expectEqual(@as(usize, 3), Catalog.unique_sink_count);
    try std.testing.expectEqual(@as(u16, 0), Catalog.indexOf(Anonymous));
    try std.testing.expectEqual(@as(u16, 1), Catalog.indexOf(Synchronous));
    try std.testing.expectEqual(@as(u16, 2), Catalog.indexOf(NamedDurable));
    try std.testing.expectEqual(@as(usize, 2), report.file_sinks.len);
    try std.testing.expectEqual(@as(u16, 0), report.file_sinks[0].sink_registry_index);
    try std.testing.expectEqualDeep(Anonymous.startup_report, report.file_sinks[0].report);
    try std.testing.expectEqual(@as(u16, 2), report.file_sinks[1].sink_registry_index);
    try std.testing.expectEqualDeep(NamedDurable.startup_report, report.file_sinks[1].report);
}

const discard_spec = multipart.decode(.{
    .discard = multipart.file(multipart.DiscardSink, multipart.required),
}, .{
    .limits = .{ .parts_max = 1, .files_max = 1 },
    .upload = .{ .window = 11, .chunk_bytes = 32 },
});
const DiscardDefinition = endpoint.Endpoint(.{ .body = discard_spec });
const discard_handler = DiscardDefinition.handle(
    Consumer(@TypeOf(discard_spec), DiscardDefinition.InputType){},
);

const legacy_spec = multipart.decode(.{
    .token = multipart.field(u8, multipart.required),
}, .{ .limits = .{
    .encoded_wire_bytes_max = 128,
    .total_body_bytes_max = 64,
    .file_bytes_max = 64,
    .field_bytes_max = 8,
    .parts_max = 1,
    .files_max = 0,
} });
const LegacyDefinition = endpoint.Endpoint(.{ .body = legacy_spec });
const LegacyConsumer = struct {
    pub const State = void;

    pub fn field(_: @This(), _: *State, _: @TypeOf(legacy_spec).Field) void {}

    pub fn complete(
        _: @This(),
        context: *Context,
        _: *State,
        _: LegacyDefinition.InputType,
        _: @TypeOf(legacy_spec).Summaries,
    ) multipart.Decision(Context.ResponseType) {
        return multipart.commit(context.empty(.no_content));
    }
};
const legacy_handler = LegacyDefinition.handle(LegacyConsumer{});

fn plainHandler() void {}

test "dispatch routes flatten upload ids and classify dense multipart routes" {
    const Routes = catalog.DispatchRoutes(.{
        route.get("/plain", plainHandler),
        route.group("/nested", .{}, .{
            route.post("/legacy", legacy_handler),
            route.post("/upload", first_handler),
        }),
    });

    try std.testing.expectEqual(@as(usize, 3), Routes.route_count);
    try std.testing.expectEqual(@as(usize, 2), Routes.multipart_route_count);
    try std.testing.expectEqual(@as(usize, 1), Routes.file_route_count);
    try std.testing.expectEqual(catalog.MultipartRouteStorage.dense, Routes.storage);
    try std.testing.expectEqual(@as(usize, 3), Routes.storage_bytes);
    try std.testing.expectEqual(@as(?catalog.MultipartRouteKind, null), Routes.routeKind(0));
    try std.testing.expectEqual(catalog.MultipartRouteKind.legacy, Routes.routeKind(1).?);
    try std.testing.expectEqual(catalog.MultipartRouteKind.upload, Routes.routeKind(2).?);
    try std.testing.expectEqual(@as(?catalog.MultipartRouteKind, null), Routes.routeKind(3));
    try std.testing.expectEqual(@as(?bool, null), Routes.hasFiles(0));
    try std.testing.expectEqual(false, Routes.hasFiles(1).?);
    try std.testing.expectEqual(true, Routes.hasFiles(2).?);
    try std.testing.expectEqualDeep([_]u16{2}, Routes.file_route_ids);
    try std.testing.expect(Routes.file_handler_types[0] == @TypeOf(first_handler));
}

test "dispatch routes choose bounded sparse multipart classification" {
    const Routes = catalog.DispatchRoutes(.{
        route.get("/0", plainHandler),
        route.get("/1", plainHandler),
        route.get("/2", plainHandler),
        route.get("/3", plainHandler),
        route.post("/4", first_handler),
        route.get("/5", plainHandler),
        route.get("/6", plainHandler),
        route.get("/7", plainHandler),
    });

    try std.testing.expectEqual(catalog.MultipartRouteStorage.sparse, Routes.storage);
    try std.testing.expectEqual(@as(usize, 4), Routes.storage_bytes);
    try std.testing.expectEqual(@as(?bool, null), Routes.hasFiles(3));
    try std.testing.expectEqual(true, Routes.hasFiles(4).?);
    try std.testing.expectEqual(@as(?bool, null), Routes.hasFiles(5));
    try std.testing.expectEqualDeep([_]u16{4}, Routes.file_route_ids);
}

const boundary_upload_1 = route.post("/upload", first_handler);
const boundary_upload_2 = route.group("", .{}, .{ boundary_upload_1, boundary_upload_1 });
const boundary_upload_4 = route.group("", .{}, .{ boundary_upload_2, boundary_upload_2 });
const boundary_upload_8 = route.group("", .{}, .{ boundary_upload_4, boundary_upload_4 });
const boundary_upload_16 = route.group("", .{}, .{ boundary_upload_8, boundary_upload_8 });
const boundary_upload_32 = route.group("", .{}, .{ boundary_upload_16, boundary_upload_16 });
const boundary_upload_64 = route.group("", .{}, .{ boundary_upload_32, boundary_upload_32 });
const boundary_upload_128 = route.group("", .{}, .{ boundary_upload_64, boundary_upload_64 });
const boundary_upload_256 = route.group("", .{}, .{ boundary_upload_128, boundary_upload_128 });
const boundary_upload_512 = route.group("", .{}, .{ boundary_upload_256, boundary_upload_256 });
const boundary_upload_511 = route.group("", .{}, .{
    boundary_upload_256,
    boundary_upload_128,
    boundary_upload_64,
    boundary_upload_32,
    boundary_upload_16,
    boundary_upload_8,
    boundary_upload_4,
    boundary_upload_2,
    boundary_upload_1,
});

test "dispatch accepts 511 and 512 multipart file routes" {
    const Routes511 = catalog.DispatchRoutes(.{boundary_upload_511});
    const Routes512 = catalog.DispatchRoutes(.{boundary_upload_512});

    try std.testing.expectEqual(@as(u16, 512), multipart.multipart_file_routes_hard_max);
    try std.testing.expectEqual(@as(usize, 511), Routes511.file_route_count);
    try std.testing.expectEqual(@as(usize, 512), Routes512.file_route_count);
    try std.testing.expectEqual(@as(u16, 510), Routes511.file_route_ids[510]);
    try std.testing.expectEqual(@as(u16, 511), Routes512.file_route_ids[511]);
}

test "bodyless and discard-only routes need no upload runtime capacity" {
    const Empty = catalog.Catalog(.{route.get("/plain", plainHandler)});
    try expectEmpty(Empty);

    const Discard = catalog.Catalog(.{route.post("/discard", discard_handler)});
    try expectEmpty(Discard);
}

test "synchronous custom sink retains runtime storage without reactor targets" {
    const Catalog = catalog.Catalog(.{route.post("/synchronous", synchronous_handler)});

    try std.testing.expectEqual(@as(usize, 1), Catalog.unique_sink_count);
    try std.testing.expect(Catalog.sink_types[0] == Synchronous);
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(Catalog.io_requirements)));
    try std.testing.expectEqual(@as(u32, 0), Catalog.upload_window_max);
    try std.testing.expect(Catalog.sink_present);
    try std.testing.expect(!Catalog.async_sink_present);
    try std.testing.expect(@sizeOf(Catalog.Registry) != 0);
    try std.testing.expectEqual(@as(usize, 0), Catalog.file_sink_configurations.len);
}

fn expectEmpty(comptime Catalog: type) !void {
    try std.testing.expectEqual(@as(usize, 0), Catalog.unique_sink_count);
    try std.testing.expectEqual(@as(u16, 0), Catalog.finalization_instances_max);
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(Catalog.io_requirements)));
    try std.testing.expectEqual(@as(u32, 0), Catalog.runtime_handles_max);
    try std.testing.expectEqual(@as(u32, 0), Catalog.request_handles_max);
    try std.testing.expectEqual(@as(u32, 0), Catalog.upload_window_max);
    try std.testing.expect(!Catalog.sink_present);
    try std.testing.expect(!Catalog.async_sink_present);
    try std.testing.expectEqual(@as(usize, 0), Catalog.file_sink_configurations.len);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Catalog.Registry));
}
