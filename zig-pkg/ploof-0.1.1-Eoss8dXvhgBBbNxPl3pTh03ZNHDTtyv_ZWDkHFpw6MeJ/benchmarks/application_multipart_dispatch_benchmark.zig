const std = @import("std");
const sigbench = @import("sigbench");
const endpoint = @import("../src/endpoint.zig");
const multipart = @import("../src/multipart.zig");
const route = @import("../src/route.zig");
const catalog = @import("../src/internal/application/upload_catalog.zig");
const application_input = @import("../src/internal/application/input.zig");
const upload_dispatch = @import("../src/internal/application/multipart_upload_dispatch.zig");

const FileHandler = struct {
    pub const ploof_multipart_endpoint = true;
    pub const definition = struct {
        pub const MultipartBodySpec = struct {
            pub const File = u8;
        };
    };
};

const LegacyHandler = struct {
    pub const ploof_multipart_endpoint = true;
    pub const definition = struct {
        pub const MultipartBodySpec = struct {
            pub const File = void;
        };
    };
};

fn RouteTree(
    comptime first: usize,
    comptime count: usize,
    comptime file_count: usize,
) type {
    @setEvalBranchQuota(100_000);
    if (count == 1) {
        const handler = if (first < file_count) FileHandler{} else LegacyHandler{};
        return struct {
            const value = route.post("/upload-dispatch", handler);
        };
    }
    const left_count = count / 2;
    const Left = RouteTree(first, left_count, file_count);
    const Right = RouteTree(first + left_count, count - left_count, file_count);
    return struct {
        const value = route.group("", .{}, .{ Left.value, Right.value });
    };
}

fn Routes(comptime count: usize) type {
    return catalog.DispatchRoutes(.{RouteTree(0, count, @min(count, 512)).value});
}

fn Runner(comptime route_count: usize) type {
    const DispatchRoutes = Routes(route_count);
    return struct {
        fn bench(bencher: *sigbench.Bencher) void {
            bencher.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var route_id: u16 = 0;
            const runtime_route_id: *volatile u16 = &route_id;
            var file_routes: u64 = 0;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                const selected_route_id = runtime_route_id.*;
                const has_files = DispatchRoutes.hasFiles(selected_route_id) orelse
                    benchmarkFailure();
                file_routes +%= @intFromBool(has_files);
                runtime_route_id.* = (selected_route_id +% 257) &
                    @as(u16, route_count - 1);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            const expected = expectedFileRoutes(route_count, iterations);
            if (file_routes != expected) benchmarkFailure();
            std.mem.doNotOptimizeAway(&file_routes);
            return elapsed_ns;
        }
    };
}

fn expectedFileRoutes(comptime route_count: usize, iterations: u64) u64 {
    const file_count = @min(route_count, 512);
    const complete_cycles = iterations / route_count;
    const remainder: usize = @intCast(iterations % route_count);
    var expected = complete_cycles * @as(u64, file_count);
    var route_id: usize = 0;
    for (0..remainder) |_| {
        expected += @intFromBool(route_id < file_count);
        route_id = (route_id + 257) & (route_count - 1);
    }
    return expected;
}

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof multipart dispatch benchmark validity check failed");
}

comptime {
    for ([_]usize{ 1, 512, 4096 }) |route_count| {
        const DispatchRoutes = Routes(route_count);
        if (DispatchRoutes.storage != .dense or
            DispatchRoutes.storage_bytes != route_count or
            DispatchRoutes.file_route_count != @min(route_count, 512))
        {
            @compileError("multipart dispatch benchmark requires exact dense storage");
        }
    }
}

pub const classification_group = sigbench.groupWithId(
    "multipart-route-classification",
    "Multipart route classification",
    .{
        sigbench.benchWithThroughput(
            "dense-1",
            "dense classification across 1 route",
            .{ .elements = 1 },
            Runner(1).bench,
        ),
        sigbench.benchWithThroughput(
            "dense-512",
            "dense classification across 512 routes",
            .{ .elements = 1 },
            Runner(512).bench,
        ),
        sigbench.benchWithThroughput(
            "dense-4096",
            "dense classification across 4096 routes",
            .{ .elements = 1 },
            Runner(4096).bench,
        ),
    },
);

const OperationContext = struct {
    pub const ResponseType = u8;
};

const OperationSink = struct {
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

const operation_spec = multipart.decode(.{
    .file = multipart.file(OperationSink, multipart.required),
}, .{
    .limits = .{ .parts_max = 1, .files_max = 1 },
    .upload = .{ .window = 1, .chunk_bytes = 64 },
});
const OperationDefinition = endpoint.Endpoint(.{ .body = operation_spec });
const OperationConsumer = struct {
    pub const State = void;

    pub fn fileStart(
        _: @This(),
        _: *OperationContext,
        _: *State,
        _: @TypeOf(operation_spec).FileStart,
    ) @TypeOf(operation_spec).FileAdmission(OperationContext.ResponseType) {
        return .{ .accept = .{ .file = {} } };
    }

    pub fn complete(
        _: @This(),
        _: *OperationContext,
        _: *State,
        _: OperationDefinition.InputType,
        _: @TypeOf(operation_spec).Summaries,
    ) multipart.Decision(OperationContext.ResponseType) {
        return multipart.commit(0);
    }
};
const operation_handler = OperationDefinition.handle(OperationConsumer{});

fn OperationRouteTree(comptime count: usize) type {
    @setEvalBranchQuota(100_000);
    if (count == 1) {
        return struct {
            const value = route.post("/multipart-file-dispatch", operation_handler);
        };
    }
    const left_count = count / 2;
    const Left = OperationRouteTree(left_count);
    const Right = OperationRouteTree(count - left_count);
    return struct {
        const value = route.group("", .{}, .{ Left.value, Right.value });
    };
}

const operation_descriptors = .{OperationRouteTree(512).value};
const OperationRegistry = struct {
    runtime: OperationSink.Runtime = {},

    pub fn indexOf(comptime Sink: type) u16 {
        if (Sink == OperationSink) return 0;
        unreachable;
    }

    pub fn get(self: *@This(), comptime Sink: type) *Sink.Runtime {
        if (Sink == OperationSink) return &self.runtime;
        unreachable;
    }
};
const OperationDispatch = upload_dispatch.Configured(
    operation_descriptors,
    OperationContext,
    error{},
    OperationRegistry,
);
const operation_layout = application_input.workspaceLayout(@TypeOf(operation_handler));
const operation_bytes = operation_layout.total_bytes_max;
const operation_alignment = operation_layout.alignment;

fn OperationRunner(comptime initial_route_id: u16, comptime route_stride: u16) type {
    return struct {
        fn bench(bencher: *sigbench.Bencher) void {
            bencher.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var context = OperationContext{};
            var registry = OperationRegistry{};
            var workspace: [operation_bytes]u8 align(operation_alignment) = undefined;
            var route_id = initial_route_id;
            const runtime_route_id: *volatile u16 = &route_id;
            var route_sum: u64 = 0;
            OperationDispatch.begin(
                initial_route_id,
                0,
                "B",
                &context,
                &registry,
                &workspace,
            ) catch benchmarkFailure();
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                const selected_route_id = runtime_route_id.*;
                const submission = OperationDispatch.peekSubmission(
                    selected_route_id,
                    0,
                    &workspace,
                ) catch benchmarkFailure();
                if (submission != null) benchmarkFailure();
                route_sum +%= @as(u64, selected_route_id);
                if (comptime route_stride != 0) {
                    runtime_route_id.* = (selected_route_id +% route_stride) & 511;
                }
                std.mem.doNotOptimizeAway(&workspace);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (route_sum != expectedOperationRouteSum(
                initial_route_id,
                route_stride,
                iterations,
            )) benchmarkFailure();
            std.mem.doNotOptimizeAway(&route_sum);
            return elapsed_ns;
        }
    };
}

fn expectedOperationRouteSum(
    comptime initial_route_id: u16,
    comptime route_stride: u16,
    iterations: u64,
) u64 {
    if (route_stride == 0) return iterations * @as(u64, initial_route_id);
    const complete_cycles = iterations / 512;
    const remainder: usize = @intCast(iterations % 512);
    var expected = complete_cycles * (511 * 512 / 2);
    var route_id = initial_route_id;
    for (0..remainder) |_| {
        expected += @as(u64, route_id);
        route_id = (route_id +% route_stride) & 511;
    }
    return expected;
}

pub const operation_group = sigbench.groupWithId(
    "multipart-file-operation-dispatch",
    "Multipart file typed operation dispatch across 512 routes",
    .{
        sigbench.benchWithThroughput(
            "first",
            "peek submission at first route",
            .{ .elements = 1 },
            OperationRunner(0, 0).bench,
        ),
        sigbench.benchWithThroughput(
            "middle",
            "peek submission at middle route",
            .{ .elements = 1 },
            OperationRunner(256, 0).bench,
        ),
        sigbench.benchWithThroughput(
            "last",
            "peek submission at last route",
            .{ .elements = 1 },
            OperationRunner(511, 0).bench,
        ),
        sigbench.benchWithThroughput(
            "all-routes",
            "peek submission across all routes",
            .{ .elements = 1 },
            OperationRunner(0, 257).bench,
        ),
    },
);
