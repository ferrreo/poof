const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const application = @import("../../../../src/application.zig");
const response = @import("../../../../src/response.zig");
const static_file = @import("../../../../src/static_file.zig");
const buffer_ring = @import("../../../../src/internal/runtime/buffer_ring.zig");
const config = @import("../../../../src/internal/runtime/config.zig");
const io_uring_backend = @import("../../../../src/internal/runtime/io_uring/backend.zig");
const listener_runtime = @import("../../../../src/internal/runtime/listener.zig");
const reactor = @import("../../../../src/internal/runtime/reactor.zig");
const worker_runtime = @import("../../../../src/internal/runtime/worker.zig");
const worker_live_static_stage = @import(
    "../../../../src/internal/runtime/worker/live_static_stage.zig",
);
const worker_storage = @import("../../../../src/internal/runtime/worker/storage.zig");

const asset = "io_uring live static body\n";
const request = "GET /asset.txt HTTP/1.1\r\nHost: integration.test\r\n\r\n";
const epoch_second: i64 = 1_784_030_400;
const completion_limit: u16 = 128;

const State = struct {
    completed: u16 = 0,
    aborted: u16 = 0,
};
const Context = application.Context(State, response.standard_head_limits);
const Observe = struct {
    pub const State = void;

    pub fn init(_: Observe) void {}

    pub fn after(
        _: Observe,
        context: *const Context,
        _: *void,
        outcome: application.Outcome,
    ) void {
        switch (outcome.transport) {
            .completed, .head_suppressed => context.state.completed += 1,
            else => context.state.aborted += 1,
        }
    }
};

const App = application.Application(.{
    .State = State,
    .middleware = .{Observe{}},
    .live_static_slots_per_worker = 1,
    .live_static_read_bytes = 4096,
    .routes = .{static_file.StaticFile.configured(
        "/asset.txt",
        ".",
        "tests/fixtures/live_static_asset.txt",
        .{},
        .{},
        null,
    )},
});
const limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 512,
    .pipeline_bytes_per_connection = 1024,
    .response_bytes_per_request = 4096,
    .submission_entries = 32,
    .completion_entries = 64,
});
const ReceiveBuffers = buffer_ring.BufferRing(2, 512, 47);
const Backend = io_uring_backend.IoUringBackendWithFiles(
    limits,
    ReceiveBuffers,
    .{
        .connection_slots = limits.connection_slots,
        .body_workspace_slots = limits.body_workspace_slots,
        .upload_window_max = 0,
        .request_handles_max = 0,
        .runtime_handles_max = 0,
        .async_sink_present = false,
        .live_static_slots = 1,
        .live_static_roots = 1,
    },
);
const Storage = worker_storage.Storage(App, limits);
const Worker = worker_runtime.Worker(App, Storage, Backend);

const special_suffix = switch (builtin.mode) {
    .Debug => "debug",
    .ReleaseSafe => "safe",
    .ReleaseFast => "fast",
    .ReleaseSmall => "small",
};
const fifo_path: [:0]const u8 = "tests/fixtures/live_static_fifo_" ++ special_suffix;
const socket_path: [:0]const u8 = "tests/fixtures/live_static_socket_" ++ special_suffix;
const SpecialApp = application.Application(.{
    .State = State,
    .middleware = .{Observe{}},
    .live_static_slots_per_worker = 1,
    .routes = .{
        static_file.StaticFile.configured("/fifo", ".", fifo_path, .{}, .{}, null),
        static_file.StaticFile.configured("/socket", ".", socket_path, .{}, .{}, null),
        static_file.StaticFile.configured("/device", "/", "dev/null", .{}, .{}, null),
    },
});
const SpecialBackend = io_uring_backend.IoUringBackendWithFiles(
    limits,
    ReceiveBuffers,
    .{
        .connection_slots = limits.connection_slots,
        .body_workspace_slots = limits.body_workspace_slots,
        .upload_window_max = 0,
        .request_handles_max = 0,
        .runtime_handles_max = 0,
        .async_sink_present = false,
        .live_static_slots = 1,
        .live_static_roots = 2,
    },
);
const SpecialStorage = worker_storage.Storage(SpecialApp, limits);
const SpecialWorker = worker_runtime.Worker(SpecialApp, SpecialStorage, SpecialBackend);

test "real io_uring worker serves and drains a confined static file" {
    var listener = switch (listener_runtime.open(.{})) {
        .listener => |value| value,
        .failure => return error.ListenerOpenFailed,
    };
    defer _ = listener.close();
    const client = try connectClient(listener.bound_address);
    defer _ = linux.close(client);
    try sendAll(client, request);

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    var storage: Storage = undefined;
    var storage_ready = false;
    defer if (backend_live) abortBackend(
        &backend,
        if (storage_ready) &storage else null,
    );
    var slab: [Storage.required_bytes]u8 align(Storage.slab_alignment) = undefined;
    try storage.init(&slab);
    storage_ready = true;
    var state = State{};
    var worker: Worker = undefined;
    try worker.init(&state, &storage, &backend, 0, listener.socket, null);
    const sample = worker_runtime.ClockSample{
        .monotonic_ns = try monotonicNow(),
        .epoch_second = epoch_second,
    };
    _ = try worker.start(sample);
    try driveUntilCompleted(&worker, &backend, sample, &state);

    var wire: [4096]u8 = undefined;
    const received = try receiveResponse(client, &wire, asset.len);
    const marker = std.mem.indexOf(u8, received, "\r\n\r\n") orelse
        return error.InvalidResponse;
    const head = received[0..marker];
    try std.testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(
        head,
        "accept-ranges: bytes\r\n",
    ) != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(head, "etag: W/\"") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(head, "last-modified: ") != null);
    try std.testing.expectEqualStrings(asset, received[marker + 4 ..]);
    try std.testing.expectEqual(@as(u16, 0), state.aborted);

    _ = try worker.stop();
    try driveUntilStopped(&worker, &backend, sample);
    try std.testing.expect(worker.cleanupStatus().quiescent());
    try backend.deinit();
    backend_live = false;
}

test "real io_uring live static confinement rejects symlink escape and mount crossing" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "target.txt",
        .data = "not reachable through link",
    });
    try temporary.dir.symLink(std.testing.io, "target.txt", "link.txt", .{});

    const opened_root = linux.open("/", .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    if (linux.errno(opened_root) != .SUCCESS) return error.RootOpenFailed;
    const root: linux.fd_t = @intCast(opened_root);
    defer _ = linux.close(root);

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    defer if (backend_live) {
        _ = backend.abort() catch {};
    };

    try expectConfinedOpenFailure(
        &backend,
        temporary.dir.handle,
        "link.txt",
        1,
        .invalid_path,
    );
    try expectConfinedOpenFailure(
        &backend,
        temporary.dir.handle,
        "../",
        2,
        .cross_device,
    );
    try expectConfinedOpenFailure(&backend, root, "proc/version", 3, .cross_device);

    try backend.deinit();
    backend_live = false;
}

test "real special files return bounded 404 without descriptor growth" {
    unlinkIfPresent(fifo_path);
    unlinkIfPresent(socket_path);
    defer unlinkIfPresent(fifo_path);
    defer unlinkIfPresent(socket_path);

    const fifo_result = linux.mknod(
        fifo_path.ptr,
        linux.S.IFIFO | linux.S.IRUSR | linux.S.IWUSR,
        0,
    );
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fifo_result));
    const unix_socket = try bindUnixSocket(socket_path);
    defer _ = linux.close(unix_socket);
    const descriptor_plateau = try openFileDescriptorCount();

    try expectSpecialNotFound("GET /fifo HTTP/1.1\r\nHost: integration.test\r\n\r\n");
    try std.testing.expectEqual(descriptor_plateau, try openFileDescriptorCount());
    try expectSpecialNotFound("GET /socket HTTP/1.1\r\nHost: integration.test\r\n\r\n");
    try std.testing.expectEqual(descriptor_plateau, try openFileDescriptorCount());
    try expectSpecialNotFound("GET /device HTTP/1.1\r\nHost: integration.test\r\n\r\n");
    try std.testing.expectEqual(descriptor_plateau, try openFileDescriptorCount());
}

fn expectSpecialNotFound(wire_request: []const u8) !void {
    var listener = switch (listener_runtime.open(.{})) {
        .listener => |value| value,
        .failure => return error.ListenerOpenFailed,
    };
    defer _ = listener.close();
    const client = try connectClient(listener.bound_address);
    defer _ = linux.close(client);
    try sendAll(client, wire_request);

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: SpecialBackend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    var storage: SpecialStorage = undefined;
    var slab: [SpecialStorage.required_bytes]u8 align(SpecialStorage.slab_alignment) = undefined;
    try storage.init(&slab);
    defer if (backend_live) abortBackendStorage(&backend, &storage);
    var state = State{};
    var worker: SpecialWorker = undefined;
    try worker.init(&state, &storage, &backend, 0, listener.socket, null);
    const sample = worker_runtime.ClockSample{
        .monotonic_ns = try monotonicNow(),
        .epoch_second = epoch_second,
    };
    _ = try worker.start(sample);
    try driveUntilCompleted(&worker, &backend, sample, &state);

    var wire: [4096]u8 = undefined;
    const received = try receiveResponse(client, &wire, 0);
    try std.testing.expect(std.mem.startsWith(
        u8,
        received,
        "HTTP/1.1 404 Not Found\r\n",
    ));
    try std.testing.expectEqual(@as(u16, 0), state.aborted);

    _ = try worker.stop();
    try driveUntilStopped(&worker, &backend, sample);
    try std.testing.expect(worker.cleanupStatus().quiescent());
    try backend.deinit();
    backend_live = false;
}

fn expectConfinedOpenFailure(
    backend: *Backend,
    base: linux.fd_t,
    path: [:0]const u8,
    sequence: u16,
    expected: reactor.CompletionError,
) !void {
    const descriptors_before = try openFileDescriptorCount();
    const token = try testToken(.file_open, sequence);
    try backend.submit(.{ .token = token, .operation = .{ .file_open = .{
        .base = .{ .directory = .{ .value = base } },
        .path = path,
        .access = .read_only,
        .no_follow = true,
        .resolve = .{
            .beneath = true,
            .no_symlinks = true,
            .no_magic_links = true,
            .no_mount_crossing = true,
        },
    } } });
    try std.testing.expectEqual(@as(u32, 1), try backend.flush());
    const completion = try backend.wait();
    try std.testing.expect(completion.token.eql(token));
    const failure = switch (completion.result) {
        .failure => |problem| problem,
        .success => return error.ConfinementOpenSucceeded,
    };
    try std.testing.expectEqual(expected, failure);
    try std.testing.expectEqual(
        .not_found,
        std.meta.activeTag(worker_live_static_stage.resolutionForOpenFailure(failure)),
    );
    try std.testing.expectEqual(@as(u32, 0), backend.activeCount());
    try std.testing.expectEqual(@as(u32, 0), backend.trackedTokenCount());
    try std.testing.expectEqual(descriptors_before, try openFileDescriptorCount());
}

fn driveUntilCompleted(
    worker: anytype,
    backend: anytype,
    sample: worker_runtime.ClockSample,
    state: *const State,
) !void {
    var completions: u16 = 0;
    while (state.completed == 0) : (completions += 1) {
        if (completions == completion_limit) return error.CompletionLimitExceeded;
        try resolveStep(worker, try worker.handle(try waitCompletion(backend), sample));
    }
}

fn driveUntilStopped(
    worker: anytype,
    backend: anytype,
    sample: worker_runtime.ClockSample,
) !void {
    var completions: u16 = 0;
    while (!worker.cleanupStatus().quiescent()) : (completions += 1) {
        if (completions == completion_limit) return error.CompletionLimitExceeded;
        try resolveStep(worker, try worker.handle(try waitCompletion(backend), sample));
    }
}

fn resolveStep(worker: anytype, first: worker_runtime.Step) !void {
    var step = first;
    var retries: u8 = 0;
    while (step == .flush_retry) : (retries += 1) {
        if (retries == 8) return error.FlushRetryLimitExceeded;
        step = try worker.retryFlush();
    }
}

fn waitCompletion(backend: anytype) !reactor.Completion {
    const deadline = try std.math.add(u64, try monotonicNow(), 2 * std.time.ns_per_s);
    while (true) {
        const completion = backend.poll() catch |problem| switch (problem) {
            error.WaitInterrupted, error.WaitRetry => null,
            else => return problem,
        };
        if (completion) |ready| return ready;
        if (try monotonicNow() >= deadline) return error.CompletionWaitTimedOut;
        const pause = linux.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        const pause_error = linux.errno(linux.nanosleep(&pause, null));
        if (pause_error != .SUCCESS and pause_error != .INTR) return error.SleepFailed;
    }
}

fn bindUnixSocket(path: [:0]const u8) !linux.fd_t {
    const opened = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(opened) != .SUCCESS) return error.UnixSocketOpenFailed;
    const descriptor: linux.fd_t = @intCast(opened);
    errdefer _ = linux.close(descriptor);
    var address = std.mem.zeroes(linux.sockaddr.un);
    address.family = linux.AF.UNIX;
    if (path.len + 1 > address.path.len) return error.UnixSocketPathTooLong;
    @memcpy(address.path[0..path.len], path);
    const address_length: linux.socklen_t = @intCast(
        @offsetOf(linux.sockaddr.un, "path") + path.len + 1,
    );
    const bound = linux.bind(descriptor, @ptrCast(&address), address_length);
    if (linux.errno(bound) != .SUCCESS) return error.UnixSocketBindFailed;
    return descriptor;
}

fn unlinkIfPresent(path: [:0]const u8) void {
    const result = linux.unlink(path.ptr);
    const problem = linux.errno(result);
    if (problem != .SUCCESS and problem != .NOENT) unreachable;
}

fn connectClient(address: listener_runtime.Address) !linux.fd_t {
    const result = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(result) != .SUCCESS) return error.ClientSocketFailed;
    const fd: linux.fd_t = @intCast(result);
    errdefer _ = linux.close(fd);
    const ipv4 = switch (address) {
        .ipv4 => |value| value,
        .ipv6 => return error.UnexpectedAddressFamily,
    };
    const socket_address = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, ipv4.port),
        .addr = @bitCast(ipv4.bytes),
    };
    const connected = linux.connect(fd, @ptrCast(&socket_address), @sizeOf(linux.sockaddr.in));
    if (linux.errno(connected) != .SUCCESS) return error.ClientConnectFailed;
    return fd;
}

fn sendAll(fd: linux.fd_t, bytes: []const u8) !void {
    var used: usize = 0;
    while (used < bytes.len) {
        const result = linux.sendto(
            fd,
            bytes[used..].ptr,
            bytes.len - used,
            linux.MSG.NOSIGNAL,
            null,
            0,
        );
        if (linux.errno(result) != .SUCCESS or result == 0) return error.ClientSendFailed;
        used += result;
    }
}

fn receiveResponse(fd: linux.fd_t, output: []u8, body_length: usize) ![]const u8 {
    var used: usize = 0;
    while (used < output.len) {
        if (std.mem.indexOf(u8, output[0..used], "\r\n\r\n")) |marker| {
            if (used == marker + 4 + body_length) return output[0..used];
        }
        var descriptors = [1]linux.pollfd{.{
            .fd = fd,
            .events = linux.POLL.IN,
            .revents = 0,
        }};
        const polled = linux.poll(&descriptors, 1, 1_000);
        if (linux.errno(polled) != .SUCCESS or polled != 1) return error.ReceiveTimedOut;
        const result = linux.recvfrom(
            fd,
            output[used..].ptr,
            output.len - used,
            0,
            null,
            null,
        );
        if (linux.errno(result) != .SUCCESS or result == 0) return error.ReceiveFailed;
        used += result;
    }
    return error.ResponseTooLarge;
}

fn abortBackend(backend: *Backend, storage: ?*const Storage) void {
    _ = backend.abort() catch {};
    const initialized = storage orelse return;
    for (initialized.connections) |connection| {
        if (connection.phase == .free or connection.socket_closed or
            connection.close_token != null) continue;
        backend.discard(connection.socket) catch {};
    }
}

fn abortBackendStorage(backend: anytype, storage: anytype) void {
    _ = backend.abort() catch {};
    for (storage.connections) |connection| {
        if (connection.phase == .free or connection.socket_closed or
            connection.close_token != null) continue;
        backend.discard(connection.socket) catch {};
    }
}

fn monotonicNow() !u64 {
    var value: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &value)) != .SUCCESS) {
        return error.ClockUnavailable;
    }
    if (value.sec < 0 or value.nsec < 0) return error.ClockUnavailable;
    const seconds = try std.math.mul(u64, @intCast(value.sec), std.time.ns_per_s);
    return std.math.add(u64, seconds, @intCast(value.nsec));
}

fn testToken(kind: reactor.OperationKind, sequence: u16) !reactor.OperationToken {
    return reactor.OperationToken.init(.{
        .kind = kind,
        .worker_index = 0,
        .slot_index = reactor.live_static_request_slot_base,
        .slot_generation = 1,
        .sequence = sequence,
    });
}

fn openFileDescriptorCount() !u16 {
    const opened = linux.open(
        "/proc/self/fd",
        .{ .DIRECTORY = true, .CLOEXEC = true },
        0,
    );
    if (linux.errno(opened) != .SUCCESS) return error.FdDirectoryOpenFailed;
    const directory: linux.fd_t = @intCast(opened);
    defer _ = linux.close(directory);

    var entries: [4096]u8 align(@alignOf(u64)) = undefined;
    var count: u16 = 0;
    while (true) {
        const read_result = linux.getdents64(directory, &entries, entries.len);
        if (linux.errno(read_result) != .SUCCESS) return error.FdDirectoryReadFailed;
        if (read_result == 0) return count;
        var offset: usize = 0;
        while (offset < read_result) {
            if (read_result - offset < 19) return error.InvalidFdDirectoryEntry;
            const length = std.mem.readInt(u16, entries[offset + 16 ..][0..2], .little);
            if (length < 19 or length > read_result - offset) {
                return error.InvalidFdDirectoryEntry;
            }
            count = try std.math.add(u16, count, 1);
            offset += length;
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
