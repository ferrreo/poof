const std = @import("std");
const linux = std.os.linux;

const config_module = @import("load_driver_config.zig");
const histogram_module = @import("load_driver_histogram.zig");
const http = @import("load_driver_http.zig");
const system = @import("load_driver_linux.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const addTime = system.addTime;
const monotonicNow = system.monotonicNow;
const pollWait = system.pollWait;
const rate = system.rate;

pub const Config = config_module.Config;
pub const Histogram = histogram_module.Histogram;

const receive_bytes_max: usize = 16 * 1024;
const generated_chunk_bytes: usize = 16 * 1024;
const nanoseconds_per_millisecond: u64 = std.time.ns_per_ms;

const Phase = enum {
    closed,
    connecting,
    idle,
    sending,
    receiving,
};

const Connection = struct {
    parser: http.Parser = .{},
    receive: [receive_bytes_max]u8 = undefined,
    fd: linux.fd_t = -1,
    phase: Phase = .closed,
    send_offset: u64 = 0,
    scheduled_ns: u64 = 0,
    deadline_ns: u64 = 0,
    request_live: bool = false,
    send_started: bool = false,
};

pub const Storage = struct {
    connections: [config_module.concurrency_max]Connection =
        @splat(Connection{}),
    polls: [config_module.concurrency_max]linux.pollfd = undefined,
    request: [config_module.request_bytes_max]u8 = undefined,
    request_file: [config_module.request_file_bytes_max]u8 = undefined,
    generated_chunk: [generated_chunk_bytes]u8 = undefined,
    path: [std.fs.max_path_bytes + 1]u8 = undefined,
};

const RequestBody = union(enum) {
    bytes: []const u8,
    repeated: struct {
        bytes: u64,
        chunk: []const u8,
    },

    fn length(self: RequestBody) u64 {
        return switch (self) {
            .bytes => |bytes| bytes.len,
            .repeated => |repeated| repeated.bytes,
        };
    }

    fn slice(self: RequestBody, offset: u64) []const u8 {
        return switch (self) {
            .bytes => |bytes| bytes[@intCast(offset)..],
            .repeated => |repeated| {
                const remaining = repeated.bytes - offset;
                return repeated.chunk[0..@intCast(@min(remaining, repeated.chunk.len))];
            },
        };
    }
};

const PreparedRequest = struct {
    head: []const u8,
    body: RequestBody,
    body_sha256: [Sha256.digest_length]u8,

    fn length(self: PreparedRequest) u64 {
        return self.head.len + self.body.length();
    }

    fn slice(self: PreparedRequest, offset: u64) []const u8 {
        if (offset < self.head.len) return self.head[@intCast(offset)..];
        return self.body.slice(offset - self.head.len);
    }

    fn byte(self: PreparedRequest, offset: u64) u8 {
        return self.slice(offset)[0];
    }
};

pub const Result = struct {
    histogram: Histogram = .{},
    scheduled_requests: u64 = 0,
    successful_requests: u64 = 0,
    transport_failures: u64 = 0,
    connect_failures: u64 = 0,
    send_failures: u64 = 0,
    receive_failures: u64 = 0,
    timeout_failures: u64 = 0,
    application_failures: u64 = 0,
    status_failures: u64 = 0,
    identity_failures: u64 = 0,
    parser_failures: u64 = 0,
    late_starts: u64 = 0,
    missed_starts: u64 = 0,
    max_start_lateness_ns: u64 = 0,
    request_wire_bytes: u64 = 0,
    response_wire_bytes: u64 = 0,
    started_ns: u64 = 0,
    finished_ns: u64 = 0,
    calibration_checksum: u64 = 0,
    request_bytes_per_attempt: u64 = 0,
    request_body_bytes: u64 = 0,
    request_body_sha256: [Sha256.digest_length]u8 = @splat(0),

    pub fn outcomes(self: Result) u64 {
        return self.successful_requests + self.transport_failures +
            self.application_failures;
    }

    pub fn durationNs(self: Result) u64 {
        return self.finished_ns - self.started_ns;
    }

    pub fn requestsPerSecond(self: Result) u64 {
        return rate(self.successful_requests, self.durationNs());
    }

    pub fn bytesPerSecond(self: Result) u64 {
        return rate(self.request_wire_bytes + self.response_wire_bytes, self.durationNs());
    }
};

const Engine = struct {
    config: Config,
    storage: *Storage,
    request: PreparedRequest,
    result: Result = .{},
    next_request: u64 = 0,
    timeout_ns: u64,

    fn init(config: Config, storage: *Storage, request: PreparedRequest) Engine {
        return .{
            .config = config,
            .storage = storage,
            .request = request,
            .timeout_ns = @as(u64, config.timeout_ms) * nanoseconds_per_millisecond,
        };
    }

    fn execute(self: *Engine) !Result {
        try self.prepareConnections();
        self.result.request_bytes_per_attempt = self.request.length();
        self.result.request_body_bytes = self.request.body.length();
        self.result.request_body_sha256 = self.request.body_sha256;
        self.result.started_ns = try monotonicNow();
        while (self.result.outcomes() < self.config.requests) {
            const now = try monotonicNow();
            self.expirePending(now);
            self.expireActive(now);
            self.assign(now);
            self.driveImmediate();
            if (self.result.outcomes() == self.config.requests) break;
            try self.waitForEvents(try monotonicNow());
        }
        self.result.finished_ns = try monotonicNow();
        self.closeAll();
        return self.result;
    }

    fn prepareConnections(self: *Engine) !void {
        errdefer self.closeAll();
        for (self.storage.connections[0..self.config.concurrency]) |*connection| {
            connection.* = Connection{};
            if (self.config.connections == .churn) continue;
            try open(connection, self.config);
        }
        if (self.config.connections == .churn) return;
        const deadline = try addTime(try monotonicNow(), self.timeout_ns);
        while (self.idleCount() != self.config.concurrency) {
            const now = try monotonicNow();
            if (now >= deadline) return error.ConnectionWarmupTimedOut;
            self.buildPolls();
            try pollWait(self.storage.polls[0..self.config.concurrency], deadline - now);
            for (self.storage.connections[0..self.config.concurrency], 0..) |
                *connection,
                index,
            | {
                if (connection.phase != .connecting) continue;
                if (self.storage.polls[index].revents == 0) continue;
                if (!finishConnect(connection)) return error.ConnectionWarmupFailed;
            }
        }
    }

    fn expirePending(self: *Engine, now: u64) void {
        if (self.config.scheduling != .constant_rate) return;
        while (self.next_request < self.config.requests) {
            const scheduled = self.scheduledTime(self.next_request);
            const deadline = addTime(scheduled, self.timeout_ns) catch std.math.maxInt(u64);
            if (now < deadline) return;
            self.next_request += 1;
            self.result.scheduled_requests += 1;
            self.result.transport_failures += 1;
            self.result.timeout_failures += 1;
            self.result.missed_starts += 1;
        }
    }

    fn expireActive(self: *Engine, now: u64) void {
        for (self.storage.connections[0..self.config.concurrency]) |*connection| {
            if (!connection.request_live or now < connection.deadline_ns) continue;
            self.failTransport(connection, .timeout);
        }
    }

    fn assign(self: *Engine, now: u64) void {
        for (self.storage.connections[0..self.config.concurrency]) |*connection| {
            if (self.next_request == self.config.requests) return;
            if (connection.request_live or
                (connection.phase != .idle and connection.phase != .closed)) continue;
            const scheduled = self.scheduledTime(self.next_request);
            if (scheduled > now) return;
            self.next_request += 1;
            self.result.scheduled_requests += 1;
            connection.request_live = true;
            connection.send_started = false;
            connection.send_offset = 0;
            connection.scheduled_ns = if (self.config.scheduling == .closed_loop)
                now
            else
                scheduled;
            connection.deadline_ns = addTime(connection.scheduled_ns, self.timeout_ns) catch
                std.math.maxInt(u64);
            connection.parser.reset(self.config.expected_status, self.config.expectedBody());
            if (connection.phase == .closed) {
                open(connection, self.config) catch {
                    self.failTransport(connection, .connect);
                    continue;
                };
            }
            if (connection.phase == .idle) connection.phase = .sending;
        }
    }

    fn driveImmediate(self: *Engine) void {
        for (self.storage.connections[0..self.config.concurrency]) |*connection| {
            if (connection.phase == .sending) self.driveSend(connection);
        }
    }

    fn waitForEvents(self: *Engine, now: u64) !void {
        self.buildPolls();
        const wait_ns = self.nextWait(now);
        try pollWait(self.storage.polls[0..self.config.concurrency], wait_ns);
        const ready_now = try monotonicNow();
        for (self.storage.connections[0..self.config.concurrency], 0..) |
            *connection,
            index,
        | {
            const events = self.storage.polls[index].revents;
            if (events == 0) continue;
            if (events & linux.POLL.NVAL != 0) {
                self.failTransport(connection, .receive);
                continue;
            }
            const terminal = events & (linux.POLL.ERR | linux.POLL.HUP) != 0;
            switch (connection.phase) {
                .connecting => self.driveConnect(connection),
                .sending => {
                    self.driveSend(connection);
                    if (terminal and connection.phase == .sending) {
                        self.failTransport(connection, .send);
                    }
                },
                .receiving => {
                    self.driveReceive(connection, ready_now);
                    if (terminal and connection.phase == .receiving) {
                        self.failTransport(connection, .receive);
                    } else if (terminal and connection.phase == .idle) {
                        close(connection);
                    }
                },
                .closed => {},
                .idle => close(connection),
            }
        }
    }

    fn driveConnect(self: *Engine, connection: *Connection) void {
        if (!finishConnect(connection)) {
            self.failTransport(connection, .connect);
            return;
        }
        if (connection.request_live) {
            connection.phase = .sending;
            self.driveSend(connection);
        }
    }

    fn driveSend(self: *Engine, connection: *Connection) void {
        while (connection.send_offset < self.request.length()) {
            const remaining = self.request.slice(connection.send_offset);
            const raw = linux.sendto(
                connection.fd,
                remaining.ptr,
                remaining.len,
                linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL,
                null,
                0,
            );
            switch (linux.errno(raw)) {
                .SUCCESS => {
                    if (raw == 0) return self.failTransport(connection, .send);
                    if (!connection.send_started) self.recordStart(connection);
                    connection.send_started = true;
                    connection.send_offset += raw;
                    self.result.request_wire_bytes += raw;
                },
                .INTR => {},
                .AGAIN => return,
                else => return self.failTransport(connection, .send),
            }
        }
        connection.phase = .receiving;
    }

    fn driveReceive(self: *Engine, connection: *Connection, now: u64) void {
        while (true) {
            const raw = linux.recvfrom(
                connection.fd,
                connection.receive[0..].ptr,
                connection.receive.len,
                linux.MSG.DONTWAIT,
                null,
                null,
            );
            switch (linux.errno(raw)) {
                .SUCCESS => {
                    if (raw == 0) return self.finishEof(connection, now);
                    self.result.response_wire_bytes += raw;
                    connection.parser.feed(connection.receive[0..raw]) catch |problem| {
                        return self.failApplication(connection, problem);
                    };
                    if (connection.parser.complete()) return self.finishSuccess(
                        connection,
                        monotonicNow() catch now,
                    );
                },
                .INTR => {},
                .AGAIN => return,
                else => return self.failTransport(connection, .receive),
            }
        }
    }

    fn finishEof(self: *Engine, connection: *Connection, now: u64) void {
        connection.parser.eof() catch |problem| {
            return self.failApplication(connection, problem);
        };
        self.finishSuccess(connection, monotonicNow() catch now);
    }

    fn finishSuccess(self: *Engine, connection: *Connection, now: u64) void {
        self.result.successful_requests += 1;
        self.result.histogram.record(now - connection.scheduled_ns);
        const must_close = self.config.connections == .churn or connection.parser.close_after;
        connection.request_live = false;
        connection.send_offset = 0;
        if (must_close) close(connection) else connection.phase = .idle;
    }

    fn failTransport(self: *Engine, connection: *Connection, kind: TransportFailure) void {
        if (connection.request_live) {
            self.result.transport_failures += 1;
            switch (kind) {
                .connect => self.result.connect_failures += 1,
                .send => self.result.send_failures += 1,
                .receive => self.result.receive_failures += 1,
                .timeout => self.result.timeout_failures += 1,
            }
        }
        connection.request_live = false;
        close(connection);
    }

    fn failApplication(self: *Engine, connection: *Connection, problem: anyerror) void {
        self.result.application_failures += 1;
        switch (problem) {
            error.UnexpectedStatus => self.result.status_failures += 1,
            error.UnexpectedBody, error.UnexpectedBodyLength, error.BodyForbidden => {
                self.result.identity_failures += 1;
            },
            else => self.result.parser_failures += 1,
        }
        connection.request_live = false;
        close(connection);
    }

    fn recordStart(self: *Engine, connection: *const Connection) void {
        if (self.config.scheduling != .constant_rate) return;
        const now = monotonicNow() catch return;
        if (now <= connection.scheduled_ns) return;
        const late = now - connection.scheduled_ns;
        self.result.late_starts += 1;
        self.result.max_start_lateness_ns = @max(self.result.max_start_lateness_ns, late);
    }

    fn buildPolls(self: *Engine) void {
        for (self.storage.connections[0..self.config.concurrency], 0..) |
            connection,
            index,
        | {
            self.storage.polls[index] = .{
                .fd = connection.fd,
                .events = switch (connection.phase) {
                    .connecting, .sending => linux.POLL.OUT,
                    .receiving => linux.POLL.IN,
                    .closed, .idle => 0,
                },
                .revents = 0,
            };
        }
    }

    fn nextWait(self: *const Engine, now: u64) u64 {
        if (self.config.scheduling == .closed_loop and
            self.next_request < self.config.requests and self.hasAssignable()) return 0;
        var deadline: u64 = std.math.maxInt(u64);
        for (self.storage.connections[0..self.config.concurrency]) |connection| {
            if (connection.request_live) deadline = @min(deadline, connection.deadline_ns);
        }
        if (self.next_request < self.config.requests and self.config.scheduling == .constant_rate) {
            const scheduled = self.scheduledTime(self.next_request);
            if (scheduled > now) deadline = @min(deadline, scheduled);
            deadline = @min(
                deadline,
                addTime(scheduled, self.timeout_ns) catch std.math.maxInt(u64),
            );
        }
        if (deadline == std.math.maxInt(u64)) return self.timeout_ns;
        return if (deadline <= now) 0 else deadline - now;
    }

    fn scheduledTime(self: *const Engine, request_index: u64) u64 {
        if (self.config.scheduling == .closed_loop) return 0;
        const offset = request_index * std.time.ns_per_s / self.config.rate;
        return addTime(self.result.started_ns, offset) catch std.math.maxInt(u64);
    }

    fn idleCount(self: *const Engine) u16 {
        var count: u16 = 0;
        for (self.storage.connections[0..self.config.concurrency]) |connection| {
            if (connection.phase == .idle) count += 1;
        }
        return count;
    }

    fn hasAssignable(self: *const Engine) bool {
        for (self.storage.connections[0..self.config.concurrency]) |connection| {
            if (!connection.request_live and
                (connection.phase == .closed or connection.phase == .idle)) return true;
        }
        return false;
    }

    fn closeAll(self: *Engine) void {
        for (self.storage.connections[0..self.config.concurrency]) |*connection| {
            close(connection);
        }
    }
};

const TransportFailure = enum {
    connect,
    send,
    receive,
    timeout,
};

pub fn run(config: Config, storage: *Storage) !Result {
    const request = try prepareRequest(config, storage);
    if (config.calibration) return calibrate(config, request);
    var engine = Engine.init(config, storage, request);
    return engine.execute();
}

fn calibrate(config: Config, request: PreparedRequest) !Result {
    var result = Result{};
    result.started_ns = try monotonicNow();
    var checksum: u64 = 0xcbf29ce484222325;
    for (0..config.requests) |index| {
        checksum ^= index;
        checksum *%= 0x100000001b3;
        checksum ^= request.byte(index % request.length());
        checksum *%= 0x100000001b3;
    }
    result.finished_ns = try monotonicNow();
    result.scheduled_requests = config.requests;
    result.successful_requests = config.requests;
    result.request_wire_bytes = config.requests * request.length();
    result.calibration_checksum = checksum;
    result.request_bytes_per_attempt = request.length();
    result.request_body_bytes = request.body.length();
    result.request_body_sha256 = request.body_sha256;
    return result;
}

fn prepareRequest(config: Config, storage: *Storage) !PreparedRequest {
    const body = try prepareBody(config, storage);
    const connection = if (config.connections == .keepalive) "keep-alive" else "close";
    var used: usize = 0;
    try appendRequest(
        &storage.request,
        &used,
        "{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: {s}\r\n" ++
            "Content-Type: {s}\r\n",
        .{ config.method, config.path, config.host, connection, config.content_type },
    );
    for (config.headerSlice()) |header| {
        try appendRequest(&storage.request, &used, "{s}: {s}\r\n", .{
            header.name,
            header.value,
        });
    }
    try appendRequest(
        &storage.request,
        &used,
        "Content-Length: {d}\r\n\r\n",
        .{body.length()},
    );
    return .{
        .head = storage.request[0..used],
        .body = body,
        .body_sha256 = hashBody(body),
    };
}

fn appendRequest(
    buffer: []u8,
    used: *usize,
    comptime template: []const u8,
    args: anytype,
) !void {
    const rendered = std.fmt.bufPrint(buffer[used.*..], template, args) catch {
        return error.RequestTooLarge;
    };
    used.* += rendered.len;
}

fn prepareBody(config: Config, storage: *Storage) !RequestBody {
    if (config.request_body_file) |path| {
        const bytes = try readBodyFile(path, storage);
        return .{ .bytes = bytes };
    }
    if (config.request_body_bytes) |bytes| {
        @memset(&storage.generated_chunk, config.request_body_byte);
        return .{ .repeated = .{
            .bytes = bytes,
            .chunk = &storage.generated_chunk,
        } };
    }
    return .{ .bytes = config.request_body };
}

fn readBodyFile(path: []const u8, storage: *Storage) ![]const u8 {
    if (path.len >= storage.path.len) return error.InvalidBodyFile;
    @memcpy(storage.path[0..path.len], path);
    storage.path[path.len] = 0;
    const raw = linux.openat(
        linux.AT.FDCWD,
        @ptrCast(storage.path[0..path.len :0]),
        .{ .CLOEXEC = true },
        0,
    );
    if (linux.errno(raw) != .SUCCESS) return error.BodyFileOpenFailed;
    const fd: linux.fd_t = @intCast(raw);
    defer _ = linux.close(fd);
    var used: usize = 0;
    while (used < storage.request_file.len) {
        const read = linux.read(
            fd,
            storage.request_file[used..].ptr,
            storage.request_file.len - used,
        );
        switch (linux.errno(read)) {
            .SUCCESS => {
                if (read == 0) return storage.request_file[0..used];
                used += read;
            },
            .INTR => {},
            else => return error.BodyFileReadFailed,
        }
    }
    var extra: [1]u8 = undefined;
    while (true) {
        const read = linux.read(fd, &extra, 1);
        switch (linux.errno(read)) {
            .SUCCESS => if (read != 0) return error.BodyFileTooLarge else break,
            .INTR => {},
            else => return error.BodyFileReadFailed,
        }
    }
    return storage.request_file[0..used];
}

fn hashBody(body: RequestBody) [Sha256.digest_length]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    var hasher = Sha256.init(.{});
    var offset: u64 = 0;
    while (offset < body.length()) {
        const bytes = body.slice(offset);
        hasher.update(bytes);
        offset += bytes.len;
    }
    hasher.final(&digest);
    return digest;
}

fn open(connection: *Connection, config: Config) !void {
    const raw = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    );
    if (linux.errno(raw) != .SUCCESS) return error.SocketFailed;
    connection.fd = @intCast(raw);
    connection.phase = .connecting;
    const address = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, config.port),
        .addr = @bitCast(config.address),
    };
    const connected = linux.connect(
        connection.fd,
        @ptrCast(&address),
        @sizeOf(linux.sockaddr.in),
    );
    switch (linux.errno(connected)) {
        .SUCCESS => connection.phase = .idle,
        .INPROGRESS => {},
        else => {
            close(connection);
            return error.ConnectFailed;
        },
    }
}

fn finishConnect(connection: *Connection) bool {
    var socket_error: i32 = 0;
    var length: linux.socklen_t = @sizeOf(i32);
    const raw = linux.getsockopt(
        connection.fd,
        linux.SOL.SOCKET,
        linux.SO.ERROR,
        @ptrCast(&socket_error),
        &length,
    );
    if (linux.errno(raw) != .SUCCESS or length != @sizeOf(i32) or socket_error != 0) {
        return false;
    }
    connection.phase = .idle;
    return true;
}

fn close(connection: *Connection) void {
    if (connection.fd >= 0) _ = linux.close(connection.fd);
    connection.fd = -1;
    connection.phase = .closed;
    connection.send_offset = 0;
    connection.send_started = false;
}

test "request construction is exact and bounded" {
    var storage = Storage{};
    const request = try prepareRequest(.{
        .host = "app.test",
        .port = 9090,
        .path = "/ping?value=1",
        .method = "POST",
        .request_body = "abc",
    }, &storage);
    var actual: [512]u8 = undefined;
    @memcpy(actual[0..request.head.len], request.head);
    @memcpy(actual[request.head.len..request.length()], request.body.slice(0));
    try std.testing.expectEqualStrings(
        "POST /ping?value=1 HTTP/1.1\r\nHost: app.test\r\n" ++
            "Connection: keep-alive\r\nContent-Type: application/octet-stream\r\n" ++
            "Content-Length: 3\r\n\r\nabc",
        actual[0..request.length()],
    );
}

test "ordinal schedule does not depend on completions" {
    var storage = Storage{};
    var engine = Engine.init(.{
        .scheduling = .constant_rate,
        .rate = 4,
    }, &storage, .{
        .head = "request",
        .body = .{ .bytes = "" },
        .body_sha256 = hashBody(.{ .bytes = "" }),
    });
    engine.result.started_ns = 1_000;
    try std.testing.expectEqual(@as(u64, 1_000), engine.scheduledTime(0));
    try std.testing.expectEqual(@as(u64, 250_001_000), engine.scheduledTime(1));
    try std.testing.expectEqual(@as(u64, 750_001_000), engine.scheduledTime(3));
}

test "result rate includes request and response bytes" {
    const result = Result{
        .successful_requests = 10,
        .request_wire_bytes = 400,
        .response_wire_bytes = 600,
        .started_ns = 100,
        .finished_ns = std.time.ns_per_s + 100,
    };
    try std.testing.expectEqual(@as(u64, 10), result.requestsPerSecond());
    try std.testing.expectEqual(@as(u64, 1_000), result.bytesPerSecond());
}

test "closed-loop retry and ppoll timeout stay immediately schedulable" {
    var storage = Storage{};
    var engine = Engine.init(.{ .requests = 2 }, &storage, .{
        .head = "request",
        .body = .{ .bytes = "" },
        .body_sha256 = hashBody(.{ .bytes = "" }),
    });
    engine.result.started_ns = 1;
    engine.next_request = 1;
    engine.storage.connections[0].phase = .closed;
    try std.testing.expectEqual(@as(u64, 0), engine.nextWait(100));
    try std.testing.expectEqual(
        linux.timespec{ .sec = 2, .nsec = 3 },
        system.timeoutSpec(2 * std.time.ns_per_s + 3),
    );
}
