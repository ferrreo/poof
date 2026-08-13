const std = @import("std");
const linux = std.os.linux;

const application = @import("../../src/application.zig");
const body_api = @import("../../src/body.zig");
const listener = @import("../../src/internal/runtime/listener.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const server_runtime = @import("../../src/server.zig");

const request_ping =
    "GET /ping HTTP/1.1\r\n" ++
    "Host: metrics.test\r\n" ++
    "Connection: close\r\n\r\n";
const request_metrics =
    "GET /metrics HTTP/1.1\r\n" ++
    "Host: metrics.test\r\n" ++
    "Connection: close\r\n\r\n";
const request_fixed =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: metrics.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Length: 4\r\n" ++
    "Connection: close\r\n\r\n" ++
    "test";
const request_chunked =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: metrics.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Connection: close\r\n\r\n" ++
    "2\r\nte\r\n2\r\nst\r\n0\r\n\r\n";
const receive_capacity = 256 * 1024;
const retry_max = 256;

const State = struct {};
const Context = application.Context(State, response.standard_head_limits);

fn ping(context: *Context) Context.ResponseType {
    return context.textStatic(.ok, "pong");
}

fn echo(context: *Context, bytes: body_api.Bytes) Context.ResponseType {
    if (!bytes.eql("test")) return context.empty(.bad_request);
    return context.textStatic(.ok, "echo");
}

const App = application.Application(.{
    .State = State,
    .routes = .{
        route.get("/ping", ping),
        route.post("/echo", body_api.bytes(.{
            .encoded_wire_bytes_max = 64,
            .decoded_bytes_max = 4,
        }, echo)),
        route.openMetrics("/metrics"),
    },
});

const TestServer = server_runtime.Server(App, .{
    .limits = .{
        .connection_slots = 2,
        .request_slots = 2,
        .body_workspace_slots = 1,
        .chunked_workspace_slots = 1,
        .receive_buffers = 4,
        .receive_buffer_bytes = 1024,
        .pipeline_bytes_per_connection = 1024,
        .response_bytes_per_request = receive_capacity,
        .response_chunk_count = 8,
        .submission_entries = 32,
        .completion_entries = 64,
    },
});

var metrics_server: TestServer align(@alignOf(TestServer)) = undefined;

test "public OpenMetrics route snapshots live workers over real io_uring" {
    metrics_server = TestServer.init();
    var state = State{};
    switch (metrics_server.start(&state, .{})) {
        .ready => {},
        .failure => return error.ServerStartupFailed,
    }
    var server_live = true;
    defer {
        if (server_live) _ = metrics_server.shutdown() catch {};
    }
    const address = metrics_server.address() orelse return error.ServerAddressMissing;

    var response_buffer: [receive_capacity]u8 = undefined;
    const ping_response = try exchange(address, request_ping, &response_buffer);
    try std.testing.expect(std.mem.startsWith(u8, ping_response, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, ping_response, "pong"));

    const fixed_response = try exchange(address, request_fixed, &response_buffer);
    try std.testing.expect(std.mem.startsWith(
        u8,
        fixed_response,
        "HTTP/1.1 200 OK\r\n",
    ));
    try std.testing.expect(std.mem.endsWith(u8, fixed_response, "echo"));
    const fixed_response_bytes = fixed_response.len;
    const chunked_response = try exchange(address, request_chunked, &response_buffer);
    try std.testing.expect(std.mem.startsWith(
        u8,
        chunked_response,
        "HTTP/1.1 200 OK\r\n",
    ));
    try std.testing.expect(std.mem.endsWith(u8, chunked_response, "echo"));
    const echo_response_wire = fixed_response_bytes + chunked_response.len;

    const metrics_response = try exchange(address, request_metrics, &response_buffer);
    try std.testing.expect(std.mem.startsWith(
        u8,
        metrics_response,
        "HTTP/1.1 200 OK\r\n",
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        metrics_response,
        "content-type: application/openmetrics-text; version=1.0.0; charset=utf-8\r\n",
    ) != null);
    const body_offset = (std.mem.indexOf(u8, metrics_response, "\r\n\r\n") orelse
        return error.ResponseHeadIncomplete) + 4;
    const body = metrics_response[body_offset..];
    try std.testing.expect(std.mem.endsWith(u8, body, "# EOF\n"));
    try expectMetric(body, "ploof_http_requests_admitted_total", "GET /ping", 1);
    try expectMetric(body, "ploof_http_requests_completed_total", "GET /ping", 1);
    try expectMetric(
        body,
        "ploof_http_request_wire_bytes_total",
        "GET /ping",
        request_ping.len,
    );
    try expectMetric(body, "ploof_http_requests_admitted_total", "POST /echo", 2);
    try expectMetric(body, "ploof_http_requests_completed_total", "POST /echo", 2);
    try expectMetric(
        body,
        "ploof_http_request_wire_bytes_total",
        "POST /echo",
        request_fixed.len + request_chunked.len,
    );
    try expectMetric(
        body,
        "ploof_http_request_decoded_bytes_total",
        "POST /echo",
        8,
    );
    try expectMetric(
        body,
        "ploof_http_response_wire_bytes_total",
        "POST /echo",
        echo_response_wire,
    );

    try std.testing.expectEqual(
        server_runtime.ShutdownResult.stopped,
        try metrics_server.shutdown(),
    );
    server_live = false;
}

fn expectMetric(body: []const u8, name: []const u8, label: []const u8, value: usize) !void {
    var expected: [160]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &expected,
        "{s}{{route=\"{s}\"}} {d}\n",
        .{ name, label, value },
    );
    try std.testing.expect(std.mem.indexOf(u8, body, line) != null);
}

fn exchange(address: listener.Address, request: []const u8, output: []u8) ![]const u8 {
    const client = try connectClient(address);
    defer _ = linux.close(client);
    try sendAll(client, request);
    return receiveToClose(client, output);
}

fn connectClient(address: listener.Address) !linux.fd_t {
    const result = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(result) != .SUCCESS) return error.ClientSocketFailed;
    const client: linux.fd_t = @intCast(result);
    errdefer _ = linux.close(client);
    const ipv4 = switch (address) {
        .ipv4 => |value| value,
        .ipv6 => return error.UnexpectedAddressFamily,
    };
    const socket_address = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, ipv4.port),
        .addr = @bitCast(ipv4.bytes),
    };
    const connected = linux.connect(
        client,
        @ptrCast(&socket_address),
        @sizeOf(linux.sockaddr.in),
    );
    if (linux.errno(connected) != .SUCCESS) return error.ClientConnectFailed;
    return client;
}

fn sendAll(client: linux.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    var attempts: u16 = 0;
    while (sent < bytes.len) : (attempts += 1) {
        if (attempts == retry_max) return error.ClientSendTimedOut;
        const result = linux.sendto(
            client,
            bytes[sent..].ptr,
            bytes.len - sent,
            linux.MSG.NOSIGNAL,
            null,
            0,
        );
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.ClientSendFailed;
                sent += result;
            },
            .AGAIN, .INTR => {},
            else => return error.ClientSendFailed,
        }
    }
}

fn receiveToClose(client: linux.fd_t, output: []u8) ![]const u8 {
    var used: usize = 0;
    var attempts: u16 = 0;
    while (attempts < retry_max) : (attempts += 1) {
        var descriptors = [1]linux.pollfd{.{
            .fd = client,
            .events = linux.POLL.IN,
            .revents = 0,
        }};
        const polled = linux.poll(&descriptors, descriptors.len, 20);
        if (linux.errno(polled) == .INTR) continue;
        if (linux.errno(polled) != .SUCCESS) return error.ClientReceiveFailed;
        if (polled == 0) continue;
        if (descriptors[0].revents & (linux.POLL.IN | linux.POLL.HUP) == 0) {
            return error.ClientReceiveFailed;
        }
        if (used == output.len) return error.ClientResponseTooLarge;
        const received = linux.recvfrom(
            client,
            output[used..].ptr,
            output.len - used,
            0,
            null,
            null,
        );
        switch (linux.errno(received)) {
            .SUCCESS => {
                if (received == 0) return output[0..used];
                used += received;
                attempts = 0;
            },
            .AGAIN, .INTR => {},
            else => return error.ClientReceiveFailed,
        }
    }
    return error.ClientReceiveTimedOut;
}
