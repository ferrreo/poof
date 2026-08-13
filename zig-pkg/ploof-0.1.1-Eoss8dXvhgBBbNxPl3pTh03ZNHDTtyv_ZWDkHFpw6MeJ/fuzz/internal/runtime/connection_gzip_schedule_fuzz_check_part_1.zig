const source = @import("connection_gzip_schedule_fuzz_check.zig");
const std = source.std;
const builtin = source.builtin;
const application = source.application;
const body = source.body;
const endpoint = source.endpoint;
const multipart = source.multipart;
const response = source.response;
const route = source.route;
const fuzz_support = source.fuzz_support;
const config = source.config;
const connection_driver = source.connection_driver;
const deterministic_reactor = source.deterministic_reactor;
const reactor = source.reactor;
const worker_storage = source.worker_storage;
const fixed_date = source.fixed_date;
const gzip_abcdef = source.gzip_abcdef;
const fixed_head = source.fixed_head;
const expect_head = source.expect_head;
const chunked_head = source.chunked_head;
const malformed_head = source.malformed_head;
const pressure_head = source.pressure_head;
const pressure_body = source.pressure_body;
const storedGzip = source.storedGzip;
const multipart_boundary = source.multipart_boundary;
const multipart_valid_body = source.multipart_valid_body;
const multipart_reject_body = source.multipart_reject_body;
const multipart_valid_gzip = source.multipart_valid_gzip;
const multipart_reject_gzip = source.multipart_reject_gzip;
const multipart_valid_head = source.multipart_valid_head;
const multipart_reject_head = source.multipart_reject_head;
const multipart_reject_wire = source.multipart_reject_wire;
const TestState = source.TestState;
const TestContext = source.TestContext;
const Observe = source.Observe;
const echo = source.echo;
const MultipartBody = source.MultipartBody;
const MultipartEndpoint = source.MultipartEndpoint;
const MultipartSpec = source.MultipartSpec;
const MultipartConsumer = source.MultipartConsumer;
const TestApp = source.TestApp;
const test_limits = source.test_limits;
const TestStorage = source.TestStorage;
const TestReactor = source.TestReactor;
const TestDriver = source.TestDriver;
const TestPool = source.TestPool;
const stack_size = source.stack_size;
const ScenarioKind = source.ScenarioKind;
const Scenario = source.Scenario;
const scenarios = source.scenarios;
const Client = source.Client;
const ActionKind = source.ActionKind;
const action_kind_count = source.action_kind_count;
const fragment_lengths = source.fragment_lengths;
const Harness = source.Harness;
const consumeReady = source.consumeReady;
const fuzzSchedule = source.fuzzSchedule;
const encodedAction = source.encodedAction;
const fuzzCase = source.fuzzCase;
const fuzz_corpus = source.fuzz_corpus;

test "gzip production driver bounded completion schedule fuzz" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try std.testing.fuzz(&harness, fuzzSchedule, .{ .corpus = &fuzz_corpus });
    try harness.expectQuiescent();
}

test "gzip multipart schedule corpus reaches both terminal oracles" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var valid = std.testing.Smith{ .in = fuzz_corpus[fuzz_corpus.len - 2] };
    try fuzzSchedule(&harness, &valid);
    try std.testing.expectEqual(@as(u8, 1), harness.multipart_valid_terminals);
    try std.testing.expectEqual(@as(u8, 0), harness.multipart_reject_terminals);

    var reject = std.testing.Smith{ .in = fuzz_corpus[fuzz_corpus.len - 1] };
    try fuzzSchedule(&harness, &reject);
    try std.testing.expectEqual(@as(u8, 0), harness.multipart_valid_terminals);
    try std.testing.expectEqual(@as(u8, 1), harness.multipart_reject_terminals);
}

test "delayed gzip close preserves synchronous multipart peer cause" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.prepare(.{ 5, 0 });

    while (harness.clients[0].cursor < harness.clients[0].head_boundary) {
        try harness.receiveNext(0, 7, false);
    }
    try harness.failReceive(0, .connection_reset);
    const connection = &harness.storage.connections[harness.clients[0].connection];
    const request_index = connection.active_request.?;
    try std.testing.expectEqual(
        .peer_disconnect,
        harness.storage.requests[request_index].workspace.multipart_abort_cause.?,
    );

    harness.releaseDecode();
    try harness.drain();
    try harness.expectQuiescent();
}

test "delayed gzip close preserves earlier body rejection cause" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.prepare(.{ 5, 0 });

    while (harness.clients[0].cursor < harness.clients[0].head_boundary) {
        try harness.receiveNext(0, 7, false);
    }
    const connection = &harness.storage.connections[harness.clients[0].connection];
    const request_index = connection.active_request.?;
    const request = &harness.storage.requests[request_index];
    try TestApp.__cancelMultipart(&request.workspace, .body);
    _ = try harness.driver.stop(harness.clients[0].connection);
    try std.testing.expectEqual(
        .body,
        request.workspace.multipart_abort_cause.?,
    );

    harness.releaseDecode();
    try harness.drain();
    try harness.expectQuiescent();
}
