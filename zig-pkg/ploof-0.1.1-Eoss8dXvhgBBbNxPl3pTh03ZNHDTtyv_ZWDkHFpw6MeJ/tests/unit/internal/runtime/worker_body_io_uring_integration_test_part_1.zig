const source = @import("worker_body_io_uring_integration_test.zig");
const std = source.std;
const linux = source.linux;
const application = source.application;
const body = source.body;
const endpoint = source.endpoint;
const json = source.json;
const query = source.query;
const response = source.response;
const route = source.route;
const allocation_guard = source.allocation_guard;
const buffer_ring = source.buffer_ring;
const config = source.config;
const io_uring_backend = source.io_uring_backend;
const listener_runtime = source.listener_runtime;
const reactor = source.reactor;
const worker_runtime = source.worker_runtime;
const worker_storage = source.worker_storage;
const epoch_second = source.epoch_second;
const completion_limit = source.completion_limit;
const completion_wait_ns = source.completion_wait_ns;
const guarded_request_count = source.guarded_request_count;
const continue_response = source.continue_response;
const echo_head = source.echo_head;
const expect_echo_head = source.expect_echo_head;
const chunked_echo_head = source.chunked_echo_head;
const expect_chunked_echo_head = source.expect_chunked_echo_head;
const undeclared_chunked_echo_head = source.undeclared_chunked_echo_head;
const chunked_echo_body = source.chunked_echo_body;
const ping_request = source.ping_request;
const typed_request = source.typed_request;
const body_response = source.body_response;
const ping_response = source.ping_response;
const typed_response = source.typed_response;
const bad_request_response = source.bad_request_response;
const State = source.State;
const Context = source.Context;
const Observe = source.Observe;
const echo = source.echo;
const ping = source.ping;
const TypedQuery = source.TypedQuery;
const TypedPayload = source.TypedPayload;
const TypedEndpoint = source.TypedEndpoint;
const typed = source.typed;
const App = source.App;
const limits = source.limits;
const ReceiveBuffers = source.ReceiveBuffers;
const Backend = source.Backend;
const Storage = source.Storage;
const Worker = source.Worker;
const Runtime = source.Runtime;
const expectChunkedBadRequest = source.expectChunkedBadRequest;
const expectGuardedChild = source.expectGuardedChild;
const runGuardedBodies = source.runGuardedBodies;
const runGuardedChunkedBodies = source.runGuardedChunkedBodies;
const runGuardedTypedEndpoint = source.runGuardedTypedEndpoint;
const expectBodyState = source.expectBodyState;
const resolveStep = source.resolveStep;
const waitCompletion = source.waitCompletion;
const connectClient = source.connectClient;
const sendAll = source.sendAll;
const receiveExact = source.receiveExact;
const monotonicNow = source.monotonicNow;

test "real io_uring fixed body preserves fragments" {
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendAll(runtime.client, echo_head ++ "ab");
    try runtime.driveUntilBodyProgress(2);
    try std.testing.expectEqual(@as(u16, 0), runtime.state.body_calls);
    try sendAll(runtime.client, "cdef");
    try runtime.driveUntilCompleted(1);

    var received: [body_response.len]u8 = undefined;
    try receiveExact(runtime.client, &received);
    try std.testing.expectEqualStrings(body_response, &received);
    try expectBodyState(&runtime.state, 1, 0, 1);
    try runtime.stop();
}

test "real io_uring typed Endpoint returns exact bounded JSON" {
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendAll(runtime.client, typed_request);
    try runtime.driveUntilCompleted(1);
    var received: [typed_response.len]u8 = undefined;
    try receiveExact(runtime.client, &received);
    try std.testing.expectEqualStrings(typed_response, &received);
    try std.testing.expectEqual(@as(u16, 1), runtime.state.typed_calls);
    try std.testing.expect(runtime.state.typed_valid);
    try runtime.stop();
}

test "real io_uring fixed body preserves coalesced pipeline order" {
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendAll(runtime.client, echo_head ++ "abcdef" ++ ping_request);
    try runtime.driveUntilCompleted(2);
    var received: [body_response.len + ping_response.len]u8 = undefined;
    try receiveExact(runtime.client, &received);
    try std.testing.expectEqualStrings(body_response ++ ping_response, &received);
    try expectBodyState(&runtime.state, 1, 1, 2);
    try runtime.stop();
}

test "real io_uring fixed body sends exact continue before response" {
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendAll(runtime.client, expect_echo_head);
    try runtime.driveUntilContinueDelivered();
    var interim: [continue_response.len]u8 = undefined;
    try receiveExact(runtime.client, &interim);
    try std.testing.expectEqualStrings(continue_response, &interim);
    try std.testing.expectEqual(@as(u16, 0), runtime.state.body_calls);

    try sendAll(runtime.client, "abcdef");
    try runtime.driveUntilCompleted(1);
    var final: [body_response.len]u8 = undefined;
    try receiveExact(runtime.client, &final);
    try std.testing.expectEqualStrings(body_response, &final);
    try expectBodyState(&runtime.state, 1, 0, 1);
    try runtime.stop();
}

test "real io_uring chunked body preserves every framing fragment" {
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendAll(runtime.client, chunked_echo_head ++ "2\r");
    try runtime.driveUntilChunkProgress(2, 0);
    const fragments = [_]struct { bytes: []const u8, wire: u64, decoded: u32 }{
        .{ .bytes = "\na", .wire = 4, .decoded = 1 },
        .{ .bytes = "b\r", .wire = 6, .decoded = 2 },
        .{ .bytes = "\n2\r\nc", .wire = 11, .decoded = 3 },
        .{ .bytes = "d\r", .wire = 13, .decoded = 4 },
        .{ .bytes = "\n2\r\ne", .wire = 18, .decoded = 5 },
        .{ .bytes = "f\r", .wire = 20, .decoded = 6 },
        .{ .bytes = "\n0\r\nX-Check: y", .wire = 34, .decoded = 6 },
        .{ .bytes = "es\r", .wire = 37, .decoded = 6 },
        .{ .bytes = "\n\r", .wire = 39, .decoded = 6 },
    };
    for (fragments) |fragment| {
        try sendAll(runtime.client, fragment.bytes);
        try runtime.driveUntilChunkProgress(fragment.wire, fragment.decoded);
    }
    try sendAll(runtime.client, "\n");
    try runtime.driveUntilCompleted(1);

    var received: [body_response.len]u8 = undefined;
    try receiveExact(runtime.client, &received);
    try std.testing.expectEqualStrings(body_response, &received);
    try expectBodyState(&runtime.state, 1, 0, 1);
    try std.testing.expectEqual(@as(u16, 1), runtime.state.trailer_calls);
    try runtime.stop();
}

test "real io_uring chunked body preserves coalesced pipeline order" {
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendAll(runtime.client, chunked_echo_head ++ chunked_echo_body ++ ping_request);
    try runtime.driveUntilCompleted(2);
    var received: [body_response.len + ping_response.len]u8 = undefined;
    try receiveExact(runtime.client, &received);
    try std.testing.expectEqualStrings(body_response ++ ping_response, &received);
    try expectBodyState(&runtime.state, 1, 1, 2);
    try std.testing.expectEqual(@as(u16, 1), runtime.state.trailer_calls);
    try runtime.stop();
}

test "real io_uring chunked body sends exact continue before response" {
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendAll(runtime.client, expect_chunked_echo_head);
    try runtime.driveUntilContinueDelivered();
    var interim: [continue_response.len]u8 = undefined;
    try receiveExact(runtime.client, &interim);
    try std.testing.expectEqualStrings(continue_response, &interim);
    try std.testing.expectEqual(@as(u16, 0), runtime.state.body_calls);

    try sendAll(runtime.client, chunked_echo_body);
    try runtime.driveUntilCompleted(1);
    var final: [body_response.len]u8 = undefined;
    try receiveExact(runtime.client, &final);
    try std.testing.expectEqualStrings(body_response, &final);
    try expectBodyState(&runtime.state, 1, 0, 1);
    try std.testing.expectEqual(@as(u16, 1), runtime.state.trailer_calls);
    try runtime.stop();
}

test "real io_uring complete optimistic chunked body skips continue" {
    var runtime = Runtime{};
    try runtime.init();
    defer runtime.abort();

    try sendAll(runtime.client, expect_chunked_echo_head ++ chunked_echo_body);
    try runtime.driveUntilCompleted(1);
    var received: [body_response.len]u8 = undefined;
    try receiveExact(runtime.client, &received);
    try std.testing.expectEqualStrings(body_response, &received);
    try expectBodyState(&runtime.state, 1, 0, 1);
    try std.testing.expectEqual(@as(u16, 1), runtime.state.trailer_calls);
    try runtime.stop();
}

test "real io_uring malformed and undeclared chunked bodies close with 400" {
    try expectChunkedBadRequest(chunked_echo_head, "g\r\n");
    try expectChunkedBadRequest(undeclared_chunked_echo_head, chunked_echo_body);
}

test "real io_uring fixed body stays allocation free after startup" {
    try expectGuardedChild(runGuardedBodies, 121);
}

test "real io_uring chunked body reuses pools without post-start allocation" {
    try expectGuardedChild(runGuardedChunkedBodies, 122);
}

test "typed Endpoint reuses bounded JSON storage without post-start allocation" {
    try expectGuardedChild(runGuardedTypedEndpoint, 123);
}
