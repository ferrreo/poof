const std = @import("std");
const application = @import("application.zig");
const public_body = @import("body.zig");
const public_response = @import("response.zig");
const public_route = @import("route.zig");
const forwarding = @import("forwarding.zig");
const config = @import("internal/runtime/config.zig");
const deterministic_reactor = @import("internal/runtime/deterministic_reactor.zig");
const reactor = @import("internal/runtime/reactor.zig");
const syntax = @import("internal/http1/syntax.zig");
const test_async = @import("internal/testing/async.zig");
const testing_wire = @import("internal/testing/wire.zig");
const worker_runtime = @import("internal/runtime/worker.zig");
const worker_storage = @import("internal/runtime/worker/storage.zig");
const ploof = struct {
    const Application = application.Application;
    const body = public_body;
    const Context = application.Context;
    const get = public_route.get;
    const post = public_route.post;
    const response = public_response;
};

pub const Options = struct {
    request_bytes_max: u32 = 16 * 1024,
    response_bytes_max: u32 = 72 * 1024,
    response_capture_bytes_max: ?u32 = null,
    forwarding: forwarding.Config = .{},
};

pub const Request = struct {
    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    method: []const u8,
    target: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    chunked: bool = false,
};

pub const ClientError = error{
    InvalidMethod,
    InvalidTarget,
    InvalidHeader,
    ReservedHeader,
    RequestTooLarge,
    ResponseTooLarge,
    InvalidResponse,
    InternalInvariant,
    CompletionLimitExceeded,
    NotQuiescent,
};

/// Response views remain valid until the client's next request attempt begins or deinit.
/// Request inputs must not alias a response view from the same client.
pub const Response = struct {
    status: u16,
    bytes: []const u8,
    head: []const u8,
    body: []const u8,

    pub fn header(self: Response, name: []const u8) ?[]const u8 {
        if (!syntax.isToken(name)) return null;
        const first_line_end = std.mem.indexOf(u8, self.head, "\r\n") orelse return null;
        var remaining = self.head[first_line_end + 2 ..];
        while (remaining.len != 0) {
            const line_end = std.mem.indexOf(u8, remaining, "\r\n") orelse return null;
            const line = remaining[0..line_end];
            if (line.len == 0) return null;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
            if (syntax.eqlIgnoreCase(line[0..colon], name)) {
                return syntax.trimOws(line[colon + 1 ..]);
            }
            remaining = remaining[line_end + 2 ..];
        }
        return null;
    }
};

pub fn Client(comptime App: type) type {
    return ConfiguredClient(App, .{});
}
/// Allocation-free high-level client backed by the production worker state machine.
pub fn ConfiguredClient(comptime App: type, comptime options: Options) type {
    const response_capture_bytes_max =
        options.response_capture_bytes_max orelse options.response_bytes_max;
    const limits = config.Limits.validate(.{
        .connection_slots = 1,
        .request_slots = 1,
        .receive_buffers = 2,
        .receive_buffer_bytes = options.request_bytes_max,
        .pipeline_bytes_per_connection = options.request_bytes_max,
        .response_bytes_per_request = options.response_bytes_max,
        .submission_entries = 32,
        .completion_entries = 64,
    });
    const RuntimeStorage = worker_storage.Storage(App, limits);
    const TestReactor = deterministic_reactor.DeterministicReactor(64);
    const ForwardingProfile = forwarding.Profile(forwarding.standard_limits);
    const forwarding_profile = ForwardingProfile.init(options.forwarding) catch |problem| {
        @compileError("invalid testing forwarding profile: " ++ @errorName(problem));
    };
    const TestWorker = worker_runtime.ConfiguredWorker(
        App,
        RuntimeStorage,
        TestReactor,
        forwarding.standard_limits,
    );
    const runtime_storage_alignment = RuntimeStorage.slab_alignment;
    const wire_capacity: usize = @max(
        options.request_bytes_max,
        response_capture_bytes_max,
    );

    return struct {
        const Self = @This();
        const listener_slot = std.math.maxInt(u16);
        const completion_limit: u16 = 256;

        const Implementation = struct {
            slab: [RuntimeStorage.required_bytes]u8 align(runtime_storage_alignment) = undefined,
            wire: [wire_capacity]u8 = undefined,
            runtime_storage: RuntimeStorage = undefined,
            io: TestReactor = .{},
            worker: TestWorker = undefined,
            wire_used: usize = 0,
            wire_high_water: usize = 0,
            next_socket: u64 = 2,
            buffer_cursor: u16 = 0,
            buffer_generations: [limits.receive_buffers]u16 =
                [_]u16{1} ** limits.receive_buffers,
            sample: worker_runtime.ClockSample = .{
                .monotonic_ns = 1,
                .epoch_second = 0,
            },
            initialized: bool = false,

            fn init(self: *Implementation, state: *App.StateType) ClientError!void {
                self.runtime_storage.init(&self.slab) catch {
                    return error.InternalInvariant;
                };
                self.worker.initForwarding(
                    state,
                    &self.runtime_storage,
                    &self.io,
                    0,
                    .{ .value = 1 },
                    null,
                    &forwarding_profile,
                ) catch return error.InternalInvariant;
                const step = self.worker.start(self.sample) catch {
                    return error.InternalInvariant;
                };
                try self.resolveStep(step);
                self.initialized = true;
            }

            fn deinit(self: *Implementation) ClientError!void {
                if (!self.initialized) return;
                defer self.clearWire();
                const first = self.worker.stop() catch return error.InternalInvariant;
                try self.resolveStep(first);

                var completions: u16 = 0;
                while (!self.worker.cleanupStatus().quiescent()) : (completions += 1) {
                    if (completions == completion_limit) {
                        return error.CompletionLimitExceeded;
                    }
                    const submission = self.io.activeSubmission(0) orelse {
                        return error.NotQuiescent;
                    };
                    try self.finish(submission);
                }
                self.initialized = false;
            }

            fn request(self: *Implementation, request_value: Request) ClientError!Response {
                if (!self.initialized) return error.InternalInvariant;

                self.clearWire();
                errdefer self.clearWire();
                const request_bytes = try testing_wire.writeRequest(
                    self.wire[0..options.request_bytes_max],
                    request_value,
                );
                self.wire_high_water = request_bytes.len;
                const socket = self.next_socket;
                self.next_socket = std.math.add(u64, socket, 1) catch {
                    return error.InternalInvariant;
                };
                const connection_index = try self.accept(socket);
                try self.receive(connection_index, request_bytes);
                test_async.drive(
                    &self.io,
                    &self.worker,
                    self.sample,
                    connection_index,
                ) catch return error.InternalInvariant;
                const send_token = self.runtime_storage.connections[connection_index]
                    .send_token orelse return error.InternalInvariant;
                const send = switch (self.io.operation(send_token) orelse {
                    return error.InternalInvariant;
                }) {
                    .send => |value| value,
                    else => return error.InternalInvariant,
                };
                if (send.bytes.len > response_capture_bytes_max) {
                    try self.complete(
                        send_token,
                        .{ .success = .{ .send = @intCast(send.bytes.len) } },
                        false,
                    );
                    try self.drainConnection(connection_index);
                    return error.ResponseTooLarge;
                }
                self.clearWire();
                @memcpy(self.wire[0..send.bytes.len], send.bytes);
                self.wire_used = send.bytes.len;
                self.wire_high_water = send.bytes.len;
                try self.complete(
                    send_token,
                    .{ .success = .{ .send = @intCast(send.bytes.len) } },
                    false,
                );
                try self.drainConnection(connection_index);
                return parseResponse(self.wire[0..self.wire_used]);
            }

            fn clearWire(self: *Implementation) void {
                std.debug.assert(self.wire_used <= self.wire_high_water);
                std.crypto.secureZero(u8, self.wire[0..self.wire_high_water]);
                self.wire_used = 0;
                self.wire_high_water = 0;
            }

            fn accept(self: *Implementation, socket: u64) ClientError!u16 {
                const token = self.findToken(.accept, listener_slot) orelse {
                    return error.InternalInvariant;
                };
                try self.complete(token, .{ .success = .{
                    .accept = reactor.Accepted.loopback(.{ .value = socket }),
                } }, false);
                for (self.runtime_storage.connections, 0..) |connection, index| {
                    if (connection.phase != .free and connection.socket.value == socket) {
                        return @intCast(index);
                    }
                }
                return error.InternalInvariant;
            }

            fn receive(
                self: *Implementation,
                connection_index: u16,
                bytes: []const u8,
            ) ClientError!void {
                if (bytes.len < 2) return error.InternalInvariant;
                const first_length = @min(@as(usize, 17), bytes.len - 1);
                try self.receiveChunk(connection_index, bytes[0..first_length]);
                try self.receiveChunk(connection_index, bytes[first_length..]);
            }

            fn receiveChunk(
                self: *Implementation,
                connection_index: u16,
                bytes: []const u8,
            ) ClientError!void {
                const token = self.runtime_storage.connections[connection_index]
                    .receive_token orelse return error.InternalInvariant;
                const buffer_index = self.buffer_cursor;
                self.buffer_cursor = (buffer_index + 1) % limits.receive_buffers;
                const generation = self.buffer_generations[buffer_index];
                self.buffer_generations[buffer_index] = reactor.nextGeneration(generation);
                try self.complete(token, .{ .success = .{ .receive = .{ .bytes = .{
                    .identity = .{
                        .owner = token.slot() catch return error.InternalInvariant,
                        .buffer_index = buffer_index,
                        .buffer_generation = generation,
                    },
                    .bytes = bytes,
                } } } }, false);
                if (self.io.borrowedCount() != 0) return error.InternalInvariant;
            }

            fn drainConnection(self: *Implementation, connection_index: u16) ClientError!void {
                var completions: u16 = 0;
                const connection = &self.runtime_storage.connections[connection_index];
                while (connection.phase != .free) : (completions += 1) {
                    if (completions == completion_limit) {
                        return error.CompletionLimitExceeded;
                    }
                    const submission = self.findConnectionSubmission(connection_index) orelse {
                        return error.NotQuiescent;
                    };
                    try self.finish(submission);
                }
            }

            fn findConnectionSubmission(
                self: *const Implementation,
                connection_index: u16,
            ) ?reactor.Submission {
                const priorities = [_]reactor.OperationKind{
                    .cancel,
                    .close,
                    .timeout,
                    .receive,
                    .send,
                };
                for (priorities) |kind| {
                    const token = self.findToken(kind, connection_index) orelse continue;
                    const operation = self.io.operation(token) orelse continue;
                    return .{ .token = token, .operation = operation };
                }
                return null;
            }

            fn finish(self: *Implementation, submission: reactor.Submission) ClientError!void {
                const result: reactor.CompletionResult = switch (submission.operation) {
                    .cancel => .{ .success = .{ .cancel = .canceled } },
                    .close => .{ .success = .{ .close = {} } },
                    else => .{ .failure = .canceled },
                };
                try self.complete(submission.token, result, false);
            }

            fn complete(
                self: *Implementation,
                token: reactor.OperationToken,
                result: reactor.CompletionResult,
                more: bool,
            ) ClientError!void {
                self.io.complete(token, result, more) catch return error.InternalInvariant;
                const completion = self.io.nextCompletion() orelse return error.InternalInvariant;
                const step = self.worker.handle(completion, self.sample) catch {
                    return error.InternalInvariant;
                };
                try self.resolveStep(step);
            }

            fn resolveStep(self: *Implementation, first: worker_runtime.Step) ClientError!void {
                var step = first;
                var retries: u8 = 0;
                while (step == .flush_retry) : (retries += 1) {
                    if (retries == 8) return error.CompletionLimitExceeded;
                    step = self.worker.retryFlush() catch return error.InternalInvariant;
                }
            }

            fn findToken(
                self: *const Implementation,
                kind: reactor.OperationKind,
                slot_index: u16,
            ) ?reactor.OperationToken {
                var index: u16 = 0;
                while (index < self.io.activeCount()) : (index += 1) {
                    const submission = self.io.activeSubmission(index).?;
                    const fields = submission.token.fields() catch continue;
                    if (fields.kind == kind and fields.slot_index == slot_index) {
                        return submission.token;
                    }
                }
                return null;
            }
        };

        /// Caller-owned, fixed-capacity storage. Contents are intentionally opaque.
        pub const Storage = struct {
            bytes: [@sizeOf(Implementation)]u8 align(@alignOf(Implementation)) = undefined,
        };

        storage: *Storage,

        pub fn init(state: *App.StateType, storage: *Storage) ClientError!Self {
            const self = Self{ .storage = storage };
            const impl = self.implementation();
            impl.* = .{};
            try impl.init(state);
            return self;
        }

        pub fn deinit(self: *Self) ClientError!void {
            return self.implementation().deinit();
        }

        pub fn get(self: *Self, target: []const u8) ClientError!Response {
            return self.request(.{ .method = "GET", .target = target });
        }

        pub fn request(self: *Self, request_value: Request) ClientError!Response {
            return self.implementation().request(request_value);
        }
        fn implementation(self: Self) *Implementation {
            return @ptrCast(&self.storage.bytes);
        }
    };
}

fn parseResponse(bytes: []const u8) ClientError!Response {
    if (bytes.len < 16 or !std.mem.startsWith(u8, bytes, "HTTP/1.1 ")) {
        return error.InvalidResponse;
    }
    const status_bytes = bytes[9..12];
    for (status_bytes) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidResponse;
    }
    const status = @as(u16, status_bytes[0] - '0') * 100 +
        @as(u16, status_bytes[1] - '0') * 10 +
        @as(u16, status_bytes[2] - '0');
    const head_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse {
        return error.InvalidResponse;
    };
    const body_start = head_end + 4;
    return .{
        .status = status,
        .bytes = bytes,
        .head = bytes[0..body_start],
        .body = bytes[body_start..],
    };
}

test "request wire distinguishes absent and empty fixed bodies" {
    var output: [128]u8 = undefined;
    const absent = try testing_wire.writeRequest(
        &output,
        Request{ .method = "GET", .target = "/" },
    );
    try std.testing.expect(std.mem.indexOf(u8, absent, "Content-Length") == null);
    const empty = try testing_wire.writeRequest(&output, Request{
        .method = "POST",
        .target = "/",
        .body = "",
    });
    try std.testing.expect(std.mem.indexOf(u8, empty, "Content-Length: 0\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, empty, "\r\n\r\n"));
}

test "request wire frames one bounded chunk and an empty terminator" {
    var output: [128]u8 = undefined;
    const chunked = try testing_wire.writeRequest(&output, Request{
        .method = "POST",
        .target = "/",
        .body = "zig",
        .chunked = true,
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        chunked,
        "Transfer-Encoding: chunked\r\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, chunked, "Content-Length") == null);
    try std.testing.expect(std.mem.endsWith(u8, chunked, "\r\n\r\n3\r\nzig\r\n0\r\n\r\n"));
}

test "high-level client drives repeated production requests without reactor access" {
    const State = struct { calls: u16 = 0 };
    const Context = ploof.Context(State, ploof.response.standard_head_limits);
    const Handler = struct {
        fn ping(context: *Context) Context.ResponseType {
            context.state.calls += 1;
            return context.textStatic(.ok, "pong");
        }
    };
    const App = ploof.Application(.{
        .State = State,
        .routes = .{ploof.get("/ping", Handler.ping)},
    });
    const TestClient = Client(App);

    var state = State{};
    var client_storage: TestClient.Storage = .{};
    var client = try TestClient.init(&state, &client_storage);
    try std.testing.expect(!@hasField(TestClient, "io"));
    try std.testing.expect(!@hasField(TestClient, "worker"));
    try std.testing.expect(!@hasField(TestClient, "runtime_storage"));
    const ping_response = try client.get("/ping");
    try std.testing.expectEqual(@as(u16, 200), ping_response.status);
    try std.testing.expectEqualStrings("pong", ping_response.body);
    try std.testing.expectEqualStrings("4", ping_response.header("Content-Length").?);
    try std.testing.expectEqualStrings(
        "text/plain; charset=utf-8",
        ping_response.header("content-type").?,
    );

    const missing_response = try client.get("/missing?x=1");
    try std.testing.expectEqual(@as(u16, 404), missing_response.status);
    try std.testing.expectEqual(@as(usize, 0), missing_response.body.len);
    try std.testing.expectEqual(@as(u16, 1), state.calls);
    try client.deinit();
}

test "high-level client rejects builder injection and capacity overflow" {
    const oversized_canary = "rejected-oversized-target-canary-9b7e";
    const State = struct {};
    const Context = ploof.Context(State, ploof.response.standard_head_limits);
    const Handler = struct {
        fn ping(context: *Context) Context.ResponseType {
            return context.textStatic(.ok, "pong");
        }
    };
    const App = ploof.Application(.{
        .State = State,
        .routes = .{ploof.get("/ping", Handler.ping)},
    });
    const SmallClient = ConfiguredClient(App, .{
        .request_bytes_max = 256,
        .response_bytes_max = 256,
    });

    var state = State{};
    var client_storage: SmallClient.Storage = .{};
    var client = try SmallClient.init(&state, &client_storage);
    try std.testing.expectError(
        error.InvalidMethod,
        client.request(.{ .method = "GET\r\nX: y", .target = "/ping" }),
    );
    try std.testing.expectError(error.InvalidTarget, client.get("/ping\r\nX: y"));
    const invalid = [_]Request.Header{
        .{ .name = "Bad:Name", .value = "x" },
        .{ .name = "X-Test", .value = "x\r\ny" },
    };
    for (invalid) |header| {
        const headers = [_]Request.Header{header};
        try std.testing.expectError(error.InvalidHeader, client.request(.{
            .method = "GET",
            .target = "/ping",
            .headers = &headers,
        }));
    }
    for ([_][]const u8{ "Host", "content-length", "Connection", "TRANSFER-ENCODING" }) |name| {
        const headers = [_]Request.Header{.{ .name = name, .value = "x" }};
        try std.testing.expectError(error.ReservedHeader, client.request(.{
            .method = "GET",
            .target = "/ping",
            .headers = &headers,
        }));
    }
    var oversized_target = [_]u8{'x'} ** 256;
    oversized_target[0] = '/';
    @memcpy(
        oversized_target[1..][0..oversized_canary.len],
        oversized_canary,
    );
    try std.testing.expectError(error.RequestTooLarge, client.get(&oversized_target));
    try std.testing.expect(std.mem.indexOf(
        u8,
        std.mem.asBytes(&client_storage),
        oversized_canary,
    ) == null);
    try client.deinit();
    try std.testing.expect(std.mem.indexOf(
        u8,
        std.mem.asBytes(&client_storage),
        oversized_canary,
    ) == null);
}

test "high-level client drains response capacity errors and remains reusable" {
    const canary = "oversized-response-target-canary-6c4e";
    const State = struct { calls: u8 = 0 };
    const Context = ploof.Context(State, ploof.response.standard_head_limits);
    const Handler = struct {
        fn secret(context: *Context) Context.ResponseType {
            context.state.calls += 1;
            return context.textStatic(.ok, "payload");
        }
    };
    const App = ploof.Application(.{
        .State = State,
        .routes = .{ploof.get("/secret", Handler.secret)},
    });
    const TinyResponseClient = ConfiguredClient(App, .{
        .request_bytes_max = 256,
        .response_bytes_max = 256,
        .response_capture_bytes_max = 1,
    });

    var state = State{};
    var client_storage: TinyResponseClient.Storage = .{};
    var client = try TinyResponseClient.init(&state, &client_storage);
    try std.testing.expectError(
        error.ResponseTooLarge,
        client.get("/secret?bad;value=" ++ canary),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        std.mem.asBytes(&client_storage),
        canary,
    ) == null);
    try std.testing.expectError(error.ResponseTooLarge, client.get("/secret"));
    try std.testing.expectEqual(@as(u8, 1), state.calls);
    try client.deinit();
}

test "high-level client fragments requests and preserves HTTP method behavior" {
    const State = struct {};
    const Context = ploof.Context(State, ploof.response.standard_head_limits);
    const Handler = struct {
        fn resource(context: *Context) Context.ResponseType {
            return context.textStatic(.ok, "payload");
        }

        fn echo(context: *Context, value: ploof.body.Bytes) Context.ResponseType {
            return context.bytesBorrowed(.ok, value.single().?);
        }
    };
    const App = ploof.Application(.{
        .State = State,
        .routes = .{
            ploof.get("/resource", Handler.resource),
            ploof.post("/echo", ploof.body.bytes(.{}, Handler.echo)),
        },
    });
    const TestClient = Client(App);

    var state = State{};
    var client_storage: TestClient.Storage = .{};
    var client = try TestClient.init(&state, &client_storage);

    const head = try client.request(.{ .method = "HEAD", .target = "/resource" });
    try std.testing.expectEqual(@as(u16, 200), head.status);
    try std.testing.expectEqual(@as(usize, 0), head.body.len);
    try std.testing.expectEqualStrings("7", head.header("content-length").?);

    const headers = [_]Request.Header{.{
        .name = "Content-Type",
        .value = "application/octet-stream",
    }};
    const echo = try client.request(.{
        .method = "POST",
        .target = "/echo",
        .headers = &headers,
        .body = "fixed-body",
    });
    try std.testing.expectEqualStrings("fixed-body", echo.body);

    const unsupported = try client.request(.{
        .method = "TRACE",
        .target = "/resource",
    });
    try std.testing.expectEqual(@as(u16, 501), unsupported.status);
    try std.testing.expectEqual(@as(usize, 0), unsupported.body.len);
    try client.deinit();
}

test "high-level client clears stale response bytes and deinit is idempotent" {
    const canary = "private-response-canary-47d3";
    const target_canary = "private-target-canary-c852";
    const State = struct {};
    const Context = ploof.Context(State, ploof.response.standard_head_limits);
    const Handler = struct {
        fn secret(context: *Context) Context.ResponseType {
            return context.textStatic(.ok, canary);
        }

        fn short(context: *Context) Context.ResponseType {
            return context.textStatic(.ok, "x");
        }
    };
    const App = ploof.Application(.{
        .State = State,
        .routes = .{
            ploof.get("/secret", Handler.secret),
            ploof.get("/short", Handler.short),
        },
    });
    const TestClient = Client(App);

    var state = State{};
    var client_storage: TestClient.Storage = .{};
    var client = try TestClient.init(&state, &client_storage);
    var long_target = [_]u8{'x'} ** 512;
    const target_prefix = "/short?secret=";
    @memcpy(long_target[0..target_prefix.len], target_prefix);
    @memcpy(
        long_target[long_target.len - target_canary.len ..],
        target_canary,
    );
    const target_response = try client.get(&long_target);
    try std.testing.expectEqualStrings("x", target_response.body);
    try std.testing.expect(std.mem.indexOf(
        u8,
        std.mem.asBytes(&client_storage),
        target_canary,
    ) == null);

    var stale = (try client.get("/secret")).bytes;
    try std.testing.expect(std.mem.indexOf(u8, stale, canary) != null);
    try std.testing.expectError(
        error.InvalidMethod,
        client.request(.{ .method = "GET\r\nX: y", .target = "/secret" }),
    );
    try std.testing.expect(std.mem.indexOf(u8, stale, canary) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        std.mem.asBytes(&client_storage),
        canary,
    ) == null);

    stale = (try client.get("/secret")).bytes;
    try std.testing.expect(std.mem.indexOf(u8, stale, canary) != null);
    try std.testing.expectError(error.InvalidTarget, client.get("/secret\r\nX: y"));
    try std.testing.expect(std.mem.indexOf(u8, stale, canary) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        std.mem.asBytes(&client_storage),
        canary,
    ) == null);

    stale = (try client.get("/secret")).bytes;
    const short = try client.get("/short");
    try std.testing.expectEqualStrings("x", short.body);
    try std.testing.expect(std.mem.indexOf(u8, stale, canary) == null);

    try client.deinit();
    try client.deinit();
    try std.testing.expect(std.mem.indexOf(
        u8,
        std.mem.asBytes(&client_storage),
        canary,
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        std.mem.asBytes(&client_storage),
        target_canary,
    ) == null);
}
