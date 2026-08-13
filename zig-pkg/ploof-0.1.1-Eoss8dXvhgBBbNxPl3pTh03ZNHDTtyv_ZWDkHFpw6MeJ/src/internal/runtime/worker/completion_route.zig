const std = @import("std");

const reactor = @import("../reactor.zig");
const runtime_time = @import("../time.zig");
const worker_stream_runtime = @import("stream_runtime.zig");
const worker_time = @import("time.zig");

pub fn route(
    comptime Error: type,
    comptime listener_slot: u16,
    comptime GzipContext: type,
    comptime handle_gzip: anytype,
    comptime StreamContext: type,
    comptime handle_stream: anytype,
    worker: anytype,
    completion: reactor.Completion,
    fields: reactor.TokenFields,
    sample: anytype,
) Error!void {
    if (reactor.liveStaticRootIndex(fields.slot_index) != null or
        reactor.liveStaticRequestIndex(fields.slot_index) != null)
    {
        return liveStatic(Error, worker, completion, sample);
    }
    if (reactor.isUploadFileOperation(fields.kind) or fields.kind == .upload_cancel or
        (fields.slot_index == reactor.upload_runtime_control_slot and
            (fields.kind == .timeout or fields.kind == .cancel)))
    {
        return upload(Error, worker, completion, sample);
    }
    if (fields.slot_index == reactor.stream_wake_control_slot) {
        return stream(
            Error,
            StreamContext,
            handle_stream,
            worker,
            completion,
            sample.monotonic_ns,
        );
    }
    if (fields.slot_index == reactor.wake_control_slot) {
        const Storage = @TypeOf(worker.storage.*);
        if (comptime Storage.gzip_decoder_thread_count != 0 and
            Storage.body_workspace_bytes_per_slot != 0)
        {
            return gzip(
                Error,
                GzipContext,
                handle_gzip,
                worker,
                completion,
                sample,
            );
        }
        return worker.fail(error.InvalidCompletion);
    }
    if (fields.slot_index == listener_slot) {
        return listener(Error, worker, completion, sample);
    }
    if (fields.slot_index < worker.storage.connections.len) {
        return connection(Error, worker, fields.slot_index, completion, sample);
    }
    return worker.fail(error.InvalidCompletion);
}

fn liveStatic(
    comptime Error: type,
    worker: anytype,
    completion: reactor.Completion,
    sample: anytype,
) Error!void {
    try refreshDate(Error, worker, sample);
    const event = worker.driver.handleLiveStatic(
        completion,
        sample.epoch_second,
        sample.monotonic_ns,
    ) catch return worker.fail(error.StaticFailure);
    switch (event) {
        .roots_ready => if (worker.phase == .running) try worker.maybeStartServices(),
        .none, .stopped => {},
    }
}

fn upload(
    comptime Error: type,
    worker: anytype,
    completion: reactor.Completion,
    sample: anytype,
) Error!void {
    try refreshDate(Error, worker, sample);
    const event = worker.driver.handleUpload(
        completion,
        sample.monotonic_ns,
    ) catch return worker.fail(error.UploadFailure);
    switch (event) {
        .registry_ready => if (worker.phase == .running) try worker.maybeStartServices(),
        .request_resumed => |resumed| worker.syncPausedReceive(resumed.connection_index),
        .request_rejected => |rejected| worker.syncPausedReceive(rejected.connection_index),
        .request_finalized => |finalized| {
            worker.syncPausedReceive(finalized.connection_index);
        },
        .none, .registry_stopped => {},
    }
}

fn stream(
    comptime Error: type,
    comptime Context: type,
    comptime callback: anytype,
    worker: anytype,
    completion: reactor.Completion,
    now_ns: u64,
) Error!void {
    worker_stream_runtime.handle(
        Error,
        worker.storage,
        worker.io,
        completion,
        Context{ .worker = worker, .now_ns = now_ns },
        callback,
    ) catch |problem| return worker.fail(problem);
}

fn gzip(
    comptime Error: type,
    comptime Context: type,
    comptime callback: anytype,
    worker: anytype,
    completion: reactor.Completion,
    sample: anytype,
) Error!void {
    try refreshDate(Error, worker, sample);
    const available_before = worker.storage.connection_pool.available();
    worker.gzip.handle(
        worker.storage,
        worker.io,
        completion,
        Context{ .worker = worker, .now_ns = sample.monotonic_ns },
        callback,
    ) catch |problem| {
        _ = worker.recordGzipReleases(available_before) catch {};
        return worker.fail(if (problem == error.InvalidCompletion)
            error.InvalidCompletion
        else
            error.GzipFailure);
    };
    const released = worker.recordGzipReleases(available_before) catch {
        return worker.fail(error.DriverFailure);
    };
    if (released != 0) {
        worker.controller.capacityReturned(worker.storage, worker.io) catch {
            return worker.fail(error.ControllerFailure);
        };
    }
}

fn listener(
    comptime Error: type,
    worker: anytype,
    completion: reactor.Completion,
    sample: anytype,
) Error!void {
    const event = worker.handleListenerControl(
        completion,
        sample.monotonic_ns,
    ) catch |problem| {
        if (problem == error.CloseFailed) {
            return worker.failProcessExit(error.ControllerFailure);
        }
        return worker.fail(error.ControllerFailure);
    };
    try refreshDate(Error, worker, sample);
    worker.handleListenerEvent(event, sample.monotonic_ns) catch |problem| {
        return worker.fail(problem);
    };
}

fn connection(
    comptime Error: type,
    worker: anytype,
    connection_index: u16,
    completion: reactor.Completion,
    sample: anytype,
) Error!void {
    try refreshDate(Error, worker, sample);
    worker.handleConnection(
        connection_index,
        completion,
        sample.monotonic_ns,
    ) catch |problem| return worker.fail(problem);
}

fn refreshDate(comptime Error: type, worker: anytype, sample: anytype) Error!void {
    worker.refreshDate(sample) catch return worker.fail(error.InvalidClock);
    worker.bindDate();
}

const TestError = error{
    InvalidClock,
    UploadFailure,
    InvalidCompletion,
    GzipFailure,
    DriverFailure,
    ControllerFailure,
};
const TestSample = struct { monotonic_ns: u64, epoch_second: i64 };
const TestRequestEvent = struct { connection_index: u16 };
const TestUploadEvent = union(enum) {
    none,
    registry_ready,
    registry_stopped,
    request_resumed: TestRequestEvent,
    request_rejected: TestRequestEvent,
    request_finalized: TestRequestEvent,
};

const TestDriver = struct {
    runtime_fields: struct { date: []const u8 = "" } = .{},
    upload_date: [runtime_time.imf_fixdate_bytes]u8 = undefined,
    upload_now_ns: u64 = 0,

    fn handleUpload(
        self: *TestDriver,
        _: reactor.Completion,
        now_ns: u64,
    ) TestError!TestUploadEvent {
        if (self.runtime_fields.date.len != self.upload_date.len) {
            return error.UploadFailure;
        }
        @memcpy(&self.upload_date, self.runtime_fields.date);
        self.upload_now_ns = now_ns;
        return .none;
    }
};

const TestConnectionPool = struct {
    fn available(_: *const TestConnectionPool) u16 {
        return 1;
    }
};
const TestStorage = struct { connection_pool: TestConnectionPool = .{} };
const TestIo = struct {};
const TestController = struct {
    fn capacityReturned(_: *TestController, _: *TestStorage, _: *TestIo) TestError!void {}
};
const TestGzip = struct {
    fn handle(
        _: *TestGzip,
        _: *TestStorage,
        _: *TestIo,
        _: reactor.Completion,
        context: anytype,
        comptime callback: anytype,
    ) error{InvalidCompletion}!void {
        callback(context, 0, @as(u8, 0)) catch return error.InvalidCompletion;
    }
};

const TestWorker = struct {
    const Phase = enum { running };

    storage: *TestStorage,
    io: *TestIo,
    phase: Phase = .running,
    gzip: TestGzip = .{},
    controller: TestController = .{},
    driver: TestDriver = .{},
    date_cache: runtime_time.ImfFixdateCache = .{},
    last_date_refresh_ns: ?u64 = null,
    gzip_date: [runtime_time.imf_fixdate_bytes]u8 = undefined,
    gzip_now_ns: u64 = 0,

    fn refreshDate(self: *TestWorker, sample: TestSample) TestError!void {
        return worker_time.refresh(self, sample);
    }

    fn bindDate(self: *TestWorker) void {
        worker_time.bind(self);
    }

    fn fail(_: *TestWorker, problem: TestError) TestError {
        return problem;
    }

    fn maybeStartServices(_: *TestWorker) TestError!void {}

    fn syncPausedReceive(_: *TestWorker, _: u16) void {}

    fn recordGzipReleases(_: *TestWorker, _: u16) TestError!u16 {
        return 0;
    }
};

const TestGzipContext = struct {
    worker: *TestWorker,
    now_ns: u64,
};

fn observeGzipDate(context: TestGzipContext, _: u16, _: anytype) TestError!void {
    const date = context.worker.driver.runtime_fields.date;
    if (date.len != context.worker.gzip_date.len) return error.GzipFailure;
    @memcpy(&context.worker.gzip_date, date);
    context.worker.gzip_now_ns = context.now_ns;
}

fn primeTestDate(worker: *TestWorker) TestError!void {
    try worker.refreshDate(.{ .monotonic_ns = 1, .epoch_second = 1_784_030_400 });
    worker.bindDate();
}

test "upload completion refreshes a stale Date before its response callback" {
    var storage = TestStorage{};
    var io = TestIo{};
    var test_worker = TestWorker{ .storage = &storage, .io = &io };
    try primeTestDate(&test_worker);
    const sample = TestSample{
        .monotonic_ns = std.time.ns_per_s + 2,
        .epoch_second = 1_784_030_401,
    };

    try upload(TestError, &test_worker, undefined, sample);
    try std.testing.expectEqualStrings(
        "Tue, 14 Jul 2026 12:00:01 GMT",
        &test_worker.driver.upload_date,
    );
    try std.testing.expectEqual(sample.monotonic_ns, test_worker.driver.upload_now_ns);
}

test "gzip completion refreshes a stale Date before its response callback" {
    var storage = TestStorage{};
    var io = TestIo{};
    var test_worker = TestWorker{ .storage = &storage, .io = &io };
    try primeTestDate(&test_worker);
    const sample = TestSample{
        .monotonic_ns = std.time.ns_per_s + 2,
        .epoch_second = 1_784_030_401,
    };

    try gzip(
        TestError,
        TestGzipContext,
        observeGzipDate,
        &test_worker,
        undefined,
        sample,
    );
    try std.testing.expectEqualStrings(
        "Tue, 14 Jul 2026 12:00:01 GMT",
        &test_worker.gzip_date,
    );
    try std.testing.expectEqual(sample.monotonic_ns, test_worker.gzip_now_ns);
}

test {
    _ = std.testing.refAllDecls(@This());
}
