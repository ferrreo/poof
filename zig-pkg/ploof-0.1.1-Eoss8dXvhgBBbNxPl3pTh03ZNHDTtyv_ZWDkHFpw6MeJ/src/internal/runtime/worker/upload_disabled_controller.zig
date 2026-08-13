const std = @import("std");

const metrics_record = @import("upload_metrics_record.zig");
const reactor = @import("../reactor.zig");
const registry_support = @import("upload_runtime_registry_support.zig");
const worker_metrics = @import("metrics.zig");
const StartupDiagnostic = @import("../../multipart/file_sink_startup_diagnostic.zig").Diagnostic;
const RouteMetricsSnapshot = @import("upload_route_metrics.zig").Snapshot;

pub fn Controller(
    comptime App: type,
    comptime Storage: type,
    comptime ControllerError: type,
    comptime Event: type,
) type {
    const registry_present = @hasDecl(App, "upload_sink_present") and
        App.upload_sink_present;
    const finalization_enabled = @hasDecl(App, "upload_finalization_instances_max") and
        App.upload_finalization_instances_max != 0;
    const request_capacity = switch (@typeInfo(Storage)) {
        .@"struct" => if (@hasDecl(Storage, "runtime_limits"))
            Storage.runtime_limits.request_slots
        else
            0,
        else => 0,
    };
    const FinalizationGenerations = if (finalization_enabled)
        [request_capacity]u16
    else
        struct {};
    const MetricsStorage = if (finalization_enabled)
        worker_metrics.UploadMetrics
    else
        struct {};
    const RegistryPhase = enum(u8) { idle, starting, ready, stopping, stopped, failed };
    const RegistryState = if (registry_present) struct {
        phase: RegistryPhase = .idle,
        worker_index: u16,
        startup_diagnostic: ?StartupDiagnostic = null,
    } else struct {};

    return struct {
        const Self = @This();

        finalization_generations: FinalizationGenerations = if (finalization_enabled)
            @splat(0)
        else
            .{},
        upload_metrics: MetricsStorage = .{},
        registry: RegistryState,

        pub fn init(worker_index: u16) ControllerError!Self {
            if (worker_index > reactor.max_worker_index) return error.InvalidWorkerIndex;
            return .{ .registry = if (registry_present)
                .{ .worker_index = worker_index }
            else
                .{} };
        }

        pub fn beginRegistryStartAt(
            self: *Self,
            storage: *Storage,
            _: anytype,
            entropy: *const [32]u8,
            _: u64,
        ) ControllerError!Event {
            if (comptime !registry_present) return .registry_ready;
            if (self.registry.phase != .idle) return error.StateInvariant;
            self.registry.phase = .starting;
            self.registry.startup_diagnostic = null;
            var started: usize = 0;
            inline for (App.UploadCatalog.sink_types, 0..) |Sink, index| {
                self.startSink(storage, Sink, index, entropy) catch |problem| {
                    const clean = self.stopConstructed(storage, started);
                    self.registry.phase = if (clean) .stopped else .failed;
                    return problem;
                };
                started += 1;
            }
            self.registry.phase = .ready;
            return .registry_ready;
        }

        pub fn beginRegistryStopAt(
            self: *Self,
            storage: *Storage,
            _: anytype,
            _: u64,
        ) ControllerError!Event {
            if (comptime !registry_present) return .registry_stopped;
            if (self.registry.phase != .ready) return error.StateInvariant;
            self.registry.phase = .stopping;
            const clean = self.stopConstructed(
                storage,
                App.UploadCatalog.sink_types.len,
            );
            self.registry.phase = if (clean) .stopped else .failed;
            if (!clean) return error.ApplicationFailure;
            return .registry_stopped;
        }

        pub fn pending(_: *const Self) u32 {
            return 0;
        }

        pub fn ownershipProven(self: *const Self) bool {
            if (comptime !registry_present) return true;
            return self.registry.phase == .idle or self.registry.phase == .stopped;
        }

        pub fn activeHandles(_: *const Self) u32 {
            return 0;
        }

        pub fn registryReady(self: *const Self) bool {
            if (comptime !registry_present) return true;
            return self.registry.phase == .ready;
        }

        pub fn registryStopped(self: *const Self) bool {
            if (comptime !registry_present) return true;
            return self.registry.phase == .idle or self.registry.phase == .stopped;
        }

        pub fn metricsSnapshot(self: *const Self) worker_metrics.UploadMetricsSnapshot {
            if (comptime finalization_enabled) return self.upload_metrics.snapshot();
            var metrics = worker_metrics.UploadMetrics{};
            return metrics.snapshot();
        }

        pub fn routeMetricsSnapshot(_: *const Self, _: u16) ?RouteMetricsSnapshot {
            return null;
        }

        pub fn startupDiagnostic(self: *const Self) ?*const StartupDiagnostic {
            if (comptime !registry_present) return null;
            return if (self.registry.startup_diagnostic) |*diagnostic| diagnostic else null;
        }

        pub fn recordFinalizationIfTerminal(
            self: *Self,
            storage: *Storage,
            request_index: u16,
        ) ControllerError!void {
            if (comptime !finalization_enabled) return;
            if (request_index >= storage.requests.len) return error.InvalidRequest;
            const request = &storage.requests[request_index];
            if (request.generation == 0 or
                self.finalization_generations[request_index] == request.generation or
                !metrics_record.terminal(&request.workspace)) return;
            const workspace = storage.bodyWorkspace(request_index) catch {
                return error.StateInvariant;
            };
            const report = (App.__multipartFinalizationReport(
                &request.workspace,
                workspace,
            ) catch return error.ApplicationFailure) orelse return error.StateInvariant;
            metrics_record.recordReport(
                App,
                &self.upload_metrics,
                &request.workspace,
                workspace,
                report,
            ) catch |problem| return problem;
            self.finalization_generations[request_index] = request.generation;
        }

        pub fn retireRequest(
            self: *Self,
            storage: *Storage,
            request_index: u16,
        ) ControllerError!void {
            if (request_index >= storage.requests.len or
                storage.requests[request_index].generation == 0)
            {
                return error.InvalidRequest;
            }
            if (comptime finalization_enabled) {
                self.finalization_generations[request_index] = 0;
            }
        }

        pub fn retireAllRequests(self: *Self) ControllerError!void {
            if (comptime finalization_enabled) {
                self.finalization_generations = @splat(0);
            }
        }

        fn startSink(
            self: *Self,
            storage: *Storage,
            comptime Sink: type,
            comptime index: usize,
            entropy: *const [32]u8,
        ) ControllerError!void {
            var derived: [32]u8 = undefined;
            defer std.crypto.secureZero(u8, &derived);
            registry_support.deriveEntropy(entropy, @intCast(index), &derived);
            const driver = storage.upload_registry.driver(Sink);
            const result = driver.startRuntime(.{
                .worker_index = self.registry.worker_index,
                .entropy = &derived,
            }) catch {
                if (driver.startupFailure()) |failure| {
                    self.registry.startup_diagnostic = .{
                        .sink_registry_index = @intCast(index),
                        .failure = failure,
                    };
                }
                return error.ApplicationFailure;
            };
            switch (result) {
                .done => {},
                .request => return error.StateInvariant,
            }
        }

        fn stopConstructed(self: *Self, storage: *Storage, count: usize) bool {
            var clean = true;
            inline for (0..App.UploadCatalog.sink_types.len) |offset| {
                const index = App.UploadCatalog.sink_types.len - 1 - offset;
                if (index < count) {
                    const Sink = App.UploadCatalog.sink_types[index];
                    if (!stopSink(storage, Sink)) clean = false;
                }
            }
            _ = self;
            return clean;
        }

        fn stopSink(storage: *Storage, comptime Sink: type) bool {
            const result = storage.upload_registry.driver(Sink).startStop() catch return false;
            return switch (result) {
                .done => true,
                .request => false,
            };
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

const multipart = @import("../../../multipart/upload.zig");
const upload_sink_driver = @import("../../upload/sink_driver.zig");

fn TestSink(comptime identity: u8, comptime fail_start: bool, comptime fail_stop: bool) type {
    return struct {
        pub const ploof_multipart_sink = true;
        pub const test_identity = identity;
        pub const State = void;
        pub const WriteState = void;
        pub const Summary = u64;
        pub const BeginInput = void;
        pub const Runtime = struct { worker_index: u16, entropy: [32]u8 };
        pub const StartupState = void;
        pub const Error = error{ StartFailed, StopFailed, UnexpectedCompletion };
        pub const io_requirements = multipart.IoRequirements.none;
        pub const request_handles_max: u8 = 0;
        pub const runtime_handles_max: u8 = 0;
        pub const initial_state: State = {};
        pub const initial_write_state: WriteState = {};
        pub const initial_startup_state: StartupState = {};

        pub fn runtimeStart(
            _: *StartupState,
            event: multipart.PollEvent(multipart.RuntimeStartInput),
        ) Error!multipart.Poll(Runtime) {
            return switch (event) {
                .start => |input| if (fail_start)
                    error.StartFailed
                else
                    .{ .done = .{
                        .worker_index = input.worker_index,
                        .entropy = input.entropy.*,
                    } },
                .completion => error.UnexpectedCompletion,
            };
        }

        pub fn runtimeStop(
            _: *Runtime,
            event: multipart.PollEvent(void),
        ) Error!multipart.Poll(void) {
            if (event == .completion) return error.UnexpectedCompletion;
            if (fail_stop) return error.StopFailed;
            return .{ .done = {} };
        }

        pub fn begin(
            _: *Runtime,
            _: *State,
            event: multipart.PollEvent(BeginInput),
        ) Error!multipart.Poll(void) {
            return done(event);
        }

        pub fn write(
            _: *Runtime,
            _: *State,
            _: *WriteState,
            event: multipart.PollEvent(multipart.WriteInput),
        ) Error!multipart.Poll(void) {
            return switch (event) {
                .start => .{ .done = {} },
                .completion => error.UnexpectedCompletion,
            };
        }

        pub fn finish(
            _: *Runtime,
            _: *State,
            event: multipart.PollEvent(multipart.FinishInput),
        ) Error!multipart.Poll(Summary) {
            return switch (event) {
                .start => |input| .{ .done = input.bytes },
                .completion => error.UnexpectedCompletion,
            };
        }

        pub fn commit(
            _: *Runtime,
            _: *State,
            event: multipart.PollEvent(void),
        ) Error!multipart.Poll(void) {
            return done(event);
        }

        pub fn abort(
            _: *Runtime,
            _: *State,
            event: multipart.PollEvent(void),
        ) Error!multipart.Poll(void) {
            return done(event);
        }

        fn done(event: multipart.PollEvent(void)) Error!multipart.Poll(void) {
            return switch (event) {
                .start => .{ .done = {} },
                .completion => error.UnexpectedCompletion,
            };
        }
    };
}

fn TestRegistry(comptime sinks: anytype) type {
    var driver_types: [sinks.len]type = undefined;
    inline for (sinks, 0..) |Sink, index| {
        driver_types[index] = upload_sink_driver.Runtime(Sink);
    }
    const Drivers = std.meta.Tuple(&driver_types);
    return struct {
        const Self = @This();
        drivers: Drivers = initial: {
            var value: Drivers = undefined;
            for (sinks, 0..) |_, index| value[index] = .{};
            break :initial value;
        },

        pub fn driver(self: *Self, comptime Sink: type) *upload_sink_driver.Runtime(Sink) {
            inline for (sinks, 0..) |Candidate, index| {
                if (Sink == Candidate) return &self.drivers[index];
            }
            @compileError("test sink is absent from registry");
        }
    };
}

fn TestApp(comptime sinks: anytype) type {
    return struct {
        pub const upload_sink_present = sinks.len != 0;
        pub const upload_finalization_instances_max: u16 = 0;
        pub const UploadCatalog = struct {
            pub const sink_types = sinks;
        };
    };
}

fn TestStorage(comptime App: type) type {
    return struct {
        upload_registry: TestRegistry(App.UploadCatalog.sink_types) = .{},
    };
}

const TestEvent = enum { registry_ready, registry_stopped };

test "synchronous sink registry starts with derived entropy and stops" {
    const Sink = TestSink(1, false, false);
    const App = TestApp(.{Sink});
    const Storage = TestStorage(App);
    const TestController = Controller(App, Storage, ControllerErrorForTest, TestEvent);
    var controller = try TestController.init(7);
    var storage = Storage{};
    var io = struct {}{};
    const entropy = [_]u8{0x5a} ** 32;

    try std.testing.expectEqual(
        TestEvent.registry_ready,
        try controller.beginRegistryStartAt(&storage, &io, &entropy, 1),
    );
    const runtime = storage.upload_registry.driver(Sink).runtimePointer().?;
    var expected: [32]u8 = undefined;
    registry_support.deriveEntropy(&entropy, 0, &expected);
    try std.testing.expectEqual(@as(u16, 7), runtime.worker_index);
    try std.testing.expectEqualSlices(u8, &expected, &runtime.entropy);
    try std.testing.expect(controller.registryReady());
    try std.testing.expect(!controller.ownershipProven());
    try std.testing.expectEqual(
        TestEvent.registry_stopped,
        try controller.beginRegistryStopAt(&storage, &io, 2),
    );
    try std.testing.expect(storage.upload_registry.driver(Sink).runtimePointer() == null);
    try std.testing.expect(controller.registryStopped());
    try std.testing.expect(controller.ownershipProven());
}

test "synchronous registry rolls back earlier runtimes after startup failure" {
    const First = TestSink(2, false, false);
    const Failing = TestSink(3, true, false);
    const App = TestApp(.{ First, Failing });
    const Storage = TestStorage(App);
    const TestController = Controller(App, Storage, ControllerErrorForTest, TestEvent);
    var controller = try TestController.init(0);
    var storage = Storage{};
    var io = struct {}{};
    const entropy = [_]u8{0xa5} ** 32;

    try std.testing.expectError(
        error.ApplicationFailure,
        controller.beginRegistryStartAt(&storage, &io, &entropy, 1),
    );
    try std.testing.expect(storage.upload_registry.driver(First).runtimePointer() == null);
    try std.testing.expect(storage.upload_registry.driver(Failing).runtimePointer() == null);
    try std.testing.expect(controller.registryStopped());
    try std.testing.expect(controller.ownershipProven());
}

test "synchronous registry stop failure is not reported quiescent" {
    const Failing = TestSink(4, false, true);
    const App = TestApp(.{Failing});
    const Storage = TestStorage(App);
    const TestController = Controller(App, Storage, ControllerErrorForTest, TestEvent);
    var controller = try TestController.init(0);
    var storage = Storage{};
    var io = struct {}{};
    const entropy = [_]u8{0x3c} ** 32;
    _ = try controller.beginRegistryStartAt(&storage, &io, &entropy, 1);

    try std.testing.expectError(
        error.ApplicationFailure,
        controller.beginRegistryStopAt(&storage, &io, 2),
    );
    try std.testing.expect(!controller.registryStopped());
    try std.testing.expect(!controller.ownershipProven());
}

const ControllerErrorForTest = error{
    ApplicationFailure,
    InvalidRequest,
    InvalidWorkerIndex,
    StateInvariant,
};
