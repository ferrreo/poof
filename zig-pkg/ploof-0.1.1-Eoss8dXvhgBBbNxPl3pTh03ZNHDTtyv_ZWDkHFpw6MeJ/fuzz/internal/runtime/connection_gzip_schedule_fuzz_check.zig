const split = @import("connection_gzip_schedule_fuzz_support.zig");
pub const std = @import("std");
pub const builtin = @import("builtin");

pub const application = @import("../../../src/application.zig");
pub const body = @import("../../../src/body.zig");
pub const endpoint = @import("../../../src/endpoint.zig");
pub const multipart = @import("../../../src/multipart.zig");
pub const response = @import("../../../src/response.zig");
pub const route = @import("../../../src/route.zig");
pub const fuzz_support = @import("../../../src/internal/http1/testing/smith.zig");
pub const config = @import("../../../src/internal/runtime/config.zig");
pub const connection_driver = @import("../../../src/internal/runtime/connection/driver.zig");
pub const deterministic_reactor = @import(
    "../../../src/internal/runtime/deterministic_reactor.zig",
);
pub const reactor = @import("../../../src/internal/runtime/reactor.zig");
pub const worker_storage = @import("../../../src/internal/runtime/worker/storage.zig");

pub const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
pub const gzip_abcdef = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x4b, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x03, 0x00,
    0xef, 0x39, 0x8e, 0x4b, 0x06, 0x00, 0x00, 0x00,
};
pub const fixed_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: schedule.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Content-Length: 26\r\n\r\n";
pub const expect_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: schedule.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Content-Length: 26\r\n" ++
    "Expect: 100-continue\r\n\r\n";
pub const chunked_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: schedule.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Transfer-Encoding: chunked\r\n\r\n";
pub const malformed_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: schedule.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Content-Length: 4\r\n\r\n";
pub const pressure_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: schedule.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Encoding: gzip\r\n" ++
    "Content-Length: 160\r\n\r\n";
pub const pressure_body = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
    0x01, 0x91, 0x00, 0x6e, 0xff,
} ++ [_]u8{'p'} ** 145;

pub fn storedGzip(comptime payload: []const u8) [payload.len + 23]u8 {
    @setEvalBranchQuota(1_000_000);
    comptime std.debug.assert(payload.len <= std.math.maxInt(u16));
    var encoded = [_]u8{0} ** (payload.len + 23);
    @memcpy(encoded[0..10], &[_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
    });
    encoded[10] = 0x01;
    const length: u16 = @intCast(payload.len);
    std.mem.writeInt(u16, encoded[11..13], length, .little);
    std.mem.writeInt(u16, encoded[13..15], ~length, .little);
    @memcpy(encoded[15..][0..payload.len], payload);
    const trailer = 15 + payload.len;
    std.mem.writeInt(u32, encoded[trailer..][0..4], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, encoded[trailer + 4 ..][0..4], @intCast(payload.len), .little);
    return encoded;
}

pub const multipart_boundary = "schedule-boundary";
pub const multipart_valid_body =
    "--" ++ multipart_boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"count\"\r\n\r\n23\r\n" ++
    "--" ++ multipart_boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"upload\"; filename=\"a.bin\"\r\n" ++
    "Content-Type: application/octet-stream\r\n\r\n" ++
    [_]u8{'m'} ** 128 ++ "\r\n--" ++ multipart_boundary ++ "--\r\n";
pub const multipart_reject_body =
    "--" ++ multipart_boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"unknown\"\r\n\r\nx\r\n" ++
    "--" ++ multipart_boundary ++ "--\r\n";
pub const multipart_valid_gzip = storedGzip(multipart_valid_body);
pub const multipart_reject_gzip = storedGzip(multipart_reject_body);
pub const multipart_valid_head =
    "POST /multipart HTTP/1.1\r\nHost: schedule.test\r\n" ++
    "Content-Type: multipart/form-data; boundary=" ++ multipart_boundary ++ "\r\n" ++
    "Content-Encoding: gzip\r\nContent-Length: " ++
    std.fmt.comptimePrint("{d}", .{multipart_valid_gzip.len}) ++ "\r\n\r\n";
pub const multipart_reject_head =
    "POST /multipart HTTP/1.1\r\nHost: schedule.test\r\n" ++
    "Content-Type: multipart/form-data; boundary=" ++ multipart_boundary ++ "\r\n" ++
    "Content-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n";
pub const multipart_reject_wire = multipart_reject_head ++
    std.fmt.comptimePrint("{x}\r\n", .{multipart_reject_gzip.len}) ++
    multipart_reject_gzip ++ "\r\n0\r\n\r\n";

pub const TestState = struct {
    started: u16 = 0,
    body_calls: u16 = 0,
    invalid_body: bool = false,
    completed: u16 = 0,
    aborted: u16 = 0,
    multipart_calls: u16 = 0,
    multipart_count: u16 = 0,
    multipart_invalid: bool = false,
    gzip_terminal_dispatching: bool = false,
};

pub const TestContext = application.Context(TestState, response.standard_head_limits);

pub const Observe = struct {
    pub const State = void;

    pub fn init(_: Observe) void {}

    pub fn head(
        _: Observe,
        context: *TestContext,
        _: *void,
    ) ?TestContext.ResponseType {
        context.state.started += 1;
        return null;
    }

    pub fn after(
        _: Observe,
        context: *const TestContext,
        _: *void,
        outcome: application.Outcome,
    ) void {
        switch (outcome.transport) {
            .completed, .head_suppressed => context.state.completed += 1,
            else => context.state.aborted += 1,
        }
    }
};

pub fn echo(context: *TestContext, value: body.Bytes) TestContext.ResponseType {
    context.state.body_calls += 1;
    context.state.invalid_body = context.state.invalid_body or !value.eql("abcdef");
    return context.textStatic(.ok, "body-ok");
}

pub const MultipartBody = multipart.decode(.{
    .count = multipart.field(u16, multipart.required),
    .upload = multipart.file(multipart.DiscardSink, multipart.required),
}, .{ .limits = multipart.Limits.validate(.{
    .encoded_wire_bytes_max = 1024,
    .total_body_bytes_max = 512,
    .file_bytes_max = 192,
    .field_bytes_max = 16,
    .parts_max = 2,
    .files_max = 1,
    .part_headers_max = 2,
    .part_header_bytes_max = 192,
    .disposition_parameters_max = 3,
    .delimiter_transport_padding_bytes_max = 8,
    .name_bytes_max = 16,
    .filename_bytes_max = 32,
    .boundary_bytes_max = 32,
}) });
pub const MultipartEndpoint = endpoint.Endpoint(.{ .body = MultipartBody });
pub const MultipartSpec = @TypeOf(MultipartBody);

pub const MultipartConsumer = struct {
    pub const State = struct { count: u16 = 0 };

    pub fn init(_: MultipartConsumer, _: *TestContext) State {
        return .{};
    }

    pub fn field(
        _: MultipartConsumer,
        state: *State,
        value: @TypeOf(MultipartBody).Field,
    ) void {
        state.count = value.count;
    }

    pub fn fileStart(
        _: MultipartConsumer,
        _: *TestContext,
        _: *State,
        _: MultipartSpec.FileStart,
    ) MultipartSpec.FileAdmission(TestContext.ResponseType) {
        return .{ .accept = .{ .upload = {} } };
    }

    pub fn complete(
        _: MultipartConsumer,
        context: *TestContext,
        state: *State,
        _: MultipartEndpoint.InputType,
        _: MultipartSpec.Summaries,
    ) multipart.Decision(TestContext.ResponseType) {
        context.state.multipart_invalid = context.state.multipart_invalid or
            !context.state.gzip_terminal_dispatching or state.count != 23;
        context.state.multipart_calls += 1;
        context.state.multipart_count = state.count;
        return multipart.commit(context.textStatic(.ok, "multipart-ok"));
    }
};

pub const TestApp = application.Application(.{
    .State = TestState,
    .middleware = .{Observe{}},
    .routes = .{
        route.post("/echo", body.bytes(.{
            .encoded_wire_bytes_max = 512,
            .decoded_bytes_max = 512,
        }, echo)),
        route.post("/multipart", MultipartEndpoint.handle(MultipartConsumer{})),
    },
});

pub const test_limits = config.Limits.validate(.{
    .connection_slots = 2,
    .request_slots = 2,
    .body_workspace_slots = 2,
    .chunked_workspace_slots = 2,
    .receive_buffers = 4,
    .receive_buffer_bytes = 64,
    .pipeline_bytes_per_connection = 512,
    .response_bytes_per_request = 1024,
    .submission_entries = 64,
    .completion_entries = 128,
    .gzip = .{
        .decoder_slots = 2,
        .input_chunks_per_slot = 2,
        .members_max = 2,
        .thread_stack_bytes = 128 * 1024,
    },
    .timeouts = .{
        .first_head_ns = 100,
        .keepalive_idle_ns = 200,
        .reused_head_progress_ns = 100,
        .body_inactivity_ns = 200,
        .write_stall_ns = 100,
    },
});

pub const TestStorage = worker_storage.Storage(TestApp, test_limits);
pub const TestReactor = deterministic_reactor.DeterministicReactor(128);
pub const TestDriver = connection_driver.Driver(TestApp, TestStorage, TestReactor);
pub const TestPool = TestStorage.GzipDecoderPool;
pub const stack_size = if (builtin.sanitize_thread)
    std.Thread.SpawnConfig.default_stack_size
else
    test_limits.gzip.thread_stack_bytes;

pub const ScenarioKind = enum(u8) { echo, multipart_valid, multipart_reject };

pub const Scenario = struct {
    wire: []const u8,
    head_boundary: usize = 0,
    kind: ScenarioKind = .echo,
};

pub const scenarios = [_]Scenario{
    .{ .wire = fixed_head ++ gzip_abcdef },
    .{ .wire = expect_head ++ gzip_abcdef, .head_boundary = expect_head.len },
    .{ .wire = chunked_head ++ "1a\r\n" ++ gzip_abcdef ++ "\r\n0\r\n\r\n" },
    .{ .wire = malformed_head ++ "nope" },
    .{ .wire = pressure_head ++ pressure_body, .head_boundary = pressure_head.len },
    .{
        .wire = multipart_valid_head ++ multipart_valid_gzip,
        .head_boundary = multipart_valid_head.len,
        .kind = .multipart_valid,
    },
    .{
        .wire = multipart_reject_wire,
        .head_boundary = multipart_reject_head.len,
        .kind = .multipart_reject,
    },
};

pub const Client = struct {
    connection: u16 = 0,
    wire: []const u8 = &.{},
    head_boundary: usize = 0,
    cursor: usize = 0,
    scenario_index: u8 = 0,
    output_dispatches: u8 = 0,
};

pub const ActionKind = enum(u8) {
    receive,
    illegal_more,
    buffer_exhausted,
    eof,
    send,
    timeout,
    cancel,
    close,
    wake,
    stop,
    resume_receive,
    release_decode,
    arbitrary,
};

pub const action_kind_count = 13;
pub const fragment_lengths = [_]u8{ 1, 2, 7, 16, 32, 48, 63, 64 };

pub const Harness = split.Harness;

pub const consumeReady = split.consumeReady;

pub const fuzzSchedule = split.fuzzSchedule;

pub const encodedAction = split.encodedAction;

pub const fuzzCase = split.fuzzCase;

pub const fuzz_corpus = split.fuzz_corpus;

test {
    _ = @import("connection_gzip_schedule_fuzz_check_part_1.zig");
}
