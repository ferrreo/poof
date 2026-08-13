const std = @import("std");
const sigbench = @import("sigbench");
const events = @import("../src/internal/multipart/events.zig");
const parser_module = @import("../src/internal/multipart/parser.zig");
const plan_module = @import("../src/internal/multipart/plan.zig");
const fixture = @import("../tests/unit/internal/runtime/connection_body_driver_test.zig");

const parser_entries = [_]plan_module.Entry{
    .{ .name = "count", .kind = .text, .required = true, .maximum = 1 },
    .{ .name = "upload", .kind = .file, .required = true, .maximum = 1 },
};
const parser_plan = plan_module.Plan{
    .entries = &parser_entries,
    .limits = .{
        .total_body_bytes_max = fixture.multipart_total_bytes_max,
        .file_bytes_max = 1024,
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
    },
};

const ParserTrace = struct {
    pub const Error = error{InvalidBenchmarkEvent};

    field_count: u8 = 0,
    file_starts: u8 = 0,
    file_ends: u8 = 0,
    file_bytes: u64 = 0,

    pub fn field(self: *ParserTrace, event: events.Field) Error!void {
        if (event.entry_index != 0 or event.occurrence != 1 or
            event.kind != .text or !std.mem.eql(u8, event.bytes, "23"))
        {
            return error.InvalidBenchmarkEvent;
        }
        self.field_count += 1;
    }

    pub fn fileStart(self: *ParserTrace, event: events.FileStart) Error!void {
        if (event.entry_index != 1 or event.occurrence != 1) {
            return error.InvalidBenchmarkEvent;
        }
        self.file_starts += 1;
    }

    pub fn fileChunk(self: *ParserTrace, event: events.FileChunk) Error!void {
        if (event.entry_index != 1 or event.occurrence != 1 or
            event.offset != self.file_bytes)
        {
            return error.InvalidBenchmarkEvent;
        }
        self.file_bytes += event.bytes.len;
    }

    pub fn fileEnd(self: *ParserTrace, event: events.FileEnd) Error!void {
        if (event.entry_index != 1 or event.occurrence != 1 or
            event.bytes != self.file_bytes)
        {
            return error.InvalidBenchmarkEvent;
        }
        self.file_ends += 1;
    }
};

const PureParser = parser_module.Parser(parser_plan, ParserTrace);
const parser_fragment_bytes: usize = 64;

const fixed_head = std.fmt.comptimePrint(
    "POST /multipart HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Content-Type: multipart/form-data; boundary={s}\r\n" ++
        "Content-Length: {d}\r\n\r\n",
    .{ fixture.multipart_boundary, fixture.multipart_body.len },
);
const fixed_wire = fixed_head ++ fixture.multipart_body;
const chunked_head =
    "POST /multipart HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: multipart/form-data; boundary=" ++ fixture.multipart_boundary ++ "\r\n" ++
    "Transfer-Encoding: chunked\r\n\r\n";
const chunked_wire = std.fmt.comptimePrint(
    "{x}\r\n{s}\r\n0\r\n\r\n",
    .{ fixture.multipart_body.len, fixture.multipart_body },
);
const chunked_request_wire = chunked_head ++ chunked_wire;
const large_head = std.fmt.comptimePrint(
    "POST /multipart HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Content-Type: multipart/form-data; boundary={s}\r\n" ++
        "Content-Length: {d}\r\n\r\n",
    .{ fixture.multipart_boundary, fixture.multipart_large_body.len },
);

const Case = enum { fixed, chunked, large_fragmented };
const DriverInput = struct {
    wire: []const u8,
    body: []const u8,
};

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof multipart benchmark validity check failed");
}

fn benchFixed(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runDriver(iterations, scope, .fixed);
        }
    }.run);
}

fn benchChunked(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runDriver(iterations, scope, .chunked);
        }
    }.run);
}

fn benchLargeFragmented(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runDriver(iterations, scope, .large_fragmented);
        }
    }.run);
}

fn benchParserContiguous(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runParser(iterations, scope, false);
        }
    }.run);
}

fn benchParserFragmented(b: *sigbench.Bencher) !void {
    try b.iterCustomScoped(struct {
        fn run(iterations: u64, scope: *sigbench.MeasurementScope) !void {
            try runParser(iterations, scope, true);
        }
    }.run);
}

fn runParser(
    iterations: u64,
    scope: *sigbench.MeasurementScope,
    comptime fragmented: bool,
) !void {
    var input: []const u8 = fixture.multipart_large_body;
    std.mem.doNotOptimizeAway(&input);
    const expected_file_bytes: u64 = 700;
    var checksum: u64 = 0;
    try scope.start();
    for (0..iterations) |_| {
        var parser = PureParser.init(fixture.multipart_boundary) catch benchmarkFailure();
        var trace = ParserTrace{};
        feedParser(&parser, &trace, input, fragmented);
        parser.finish(&trace) catch benchmarkFailure();
        validateTrace(parser, trace, expected_file_bytes);
        checksum +%= trace.file_bytes;
    }
    try scope.stop();
    std.mem.doNotOptimizeAway(checksum);
}

fn feedParser(
    parser: *PureParser,
    trace: *ParserTrace,
    input: []const u8,
    comptime fragmented: bool,
) void {
    if (!fragmented) {
        parser.feed(trace, input) catch benchmarkFailure();
        return;
    }
    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(offset + parser_fragment_bytes, input.len);
        parser.feed(trace, input[offset..end]) catch benchmarkFailure();
        offset = end;
    }
}

fn validateTrace(parser: PureParser, trace: ParserTrace, file_bytes: u64) void {
    if (!parser.isComplete() or trace.field_count != 1 or
        trace.file_starts != 1 or trace.file_ends != 1 or
        trace.file_bytes != file_bytes)
    {
        benchmarkFailure();
    }
}

fn runDriver(
    iterations: u64,
    scope: *sigbench.MeasurementScope,
    comptime case: Case,
) !void {
    var harness: fixture.Harness = undefined;
    harness.init() catch benchmarkFailure();
    const connection = harness.addConnection(300) catch benchmarkFailure();
    var input = driverInput(case);
    std.mem.doNotOptimizeAway(&input);
    driveRequest(&harness, connection, input, case);
    finishRequest(&harness, connection);

    try scope.start();
    for (0..iterations) |_| {
        driveRequest(&harness, connection, input, case);
        finishRequest(&harness, connection);
    }
    try scope.stop();
    std.mem.doNotOptimizeAway(&harness.state);
}

fn driverInput(comptime case: Case) DriverInput {
    return switch (case) {
        .fixed => .{ .wire = fixed_wire, .body = &.{} },
        .chunked => .{ .wire = chunked_request_wire, .body = &.{} },
        .large_fragmented => .{ .wire = large_head, .body = fixture.multipart_large_body },
    };
}

fn driveRequest(
    harness: *fixture.Harness,
    connection: u16,
    input: DriverInput,
    comptime case: Case,
) void {
    switch (case) {
        .fixed => {
            _ = harness.receive(connection, input.wire, false) catch benchmarkFailure();
        },
        .chunked => {
            _ = harness.receive(connection, input.wire, false) catch {
                benchmarkFailure();
            };
        },
        .large_fragmented => {
            _ = harness.receive(connection, input.wire, false) catch benchmarkFailure();
            var offset: usize = 0;
            while (offset < input.body.len) {
                const end = @min(
                    offset + fixture.test_limits.receive_buffer_bytes,
                    input.body.len,
                );
                _ = harness.receive(
                    connection,
                    input.body[offset..end],
                    false,
                ) catch benchmarkFailure();
                offset = end;
            }
        },
    }
}

fn finishRequest(harness: *fixture.Harness, connection: u16) void {
    if (harness.state.multipart_calls != 1 or harness.state.multipart_count != 23) {
        benchmarkFailure();
    }
    if (!std.mem.endsWith(
        u8,
        harness.sendBytes(connection),
        "\r\n\r\nmultipart-ok",
    )) benchmarkFailure();
    const active = harness.storage.connections[connection].active_request orelse {
        benchmarkFailure();
    };
    if (harness.storage.requests[active].body.used != 0) benchmarkFailure();
    harness.completeSendAll(connection) catch benchmarkFailure();
    harness.retireResponse(connection) catch benchmarkFailure();
    if (harness.state.after_calls != 1 or
        harness.state.completed != 1 or harness.state.aborted != 0)
    {
        benchmarkFailure();
    }
    const record = harness.storage.connections[connection];
    if (record.phase != .keepalive_idle or record.active_request != null) benchmarkFailure();
    if (harness.storage.bodyWorkspaceAvailable() != fixture.test_limits.body_workspace_slots) {
        benchmarkFailure();
    }
    harness.state = .{};
}

pub const group = sigbench.groupWithId(
    "m8-multipart-driver",
    "M8 production identity multipart driver",
    .{
        sigbench.benchWithThroughput(
            "fixed-contiguous",
            "keepalive typed multipart fixed body in one receive",
            .{ .bytes = fixed_wire.len },
            benchFixed,
        ),
        sigbench.benchWithThroughput(
            "chunked-contiguous",
            "keepalive typed multipart chunked framing in one receive",
            .{ .bytes = chunked_head.len + chunked_wire.len },
            benchChunked,
        ),
        sigbench.benchWithThroughput(
            "fixed-large-fragmented",
            "keepalive typed multipart crossing receive-buffer capacity",
            .{ .bytes = large_head.len + fixture.multipart_large_body.len },
            benchLargeFragmented,
        ),
    },
);

pub const parser_group = sigbench.groupWithId(
    "m8-multipart-parser",
    "M8 pure multipart parser",
    .{
        sigbench.benchWithThroughput(
            "valid-large-contiguous",
            "fresh typed parser with contiguous large body",
            .{ .bytes = fixture.multipart_large_body.len },
            benchParserContiguous,
        ),
        sigbench.benchWithThroughput(
            "valid-large-fragmented-64",
            "fresh typed parser with large body in 64-byte fragments",
            .{ .bytes = fixture.multipart_large_body.len },
            benchParserFragmented,
        ),
    },
);

pub fn writeMetricsReport(
    init: std.process.Init,
    default_output_root: []const u8,
) !void {
    const output_root = try selectedOutputRoot(init, default_output_root);
    if (output_root == null) return;
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try std.fmt.bufPrint(
        &directory_storage,
        "{s}/m8-multipart",
        .{output_root.?},
    );
    try std.Io.Dir.cwd().createDirPath(init.io, directory);

    var json_storage: [4096]u8 = undefined;
    var json = std.Io.Writer.fixed(&json_storage);
    try writeMetrics(&json);
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "{s}/metrics.json", .{directory});
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = path,
        .data = json.buffered(),
    });
}

fn selectedOutputRoot(
    init: std.process.Init,
    default_output_root: []const u8,
) !?[]const u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    var output_root = default_output_root;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sigbench-exact")) return null;
        if (std.mem.eql(u8, arg, "--output-dir")) {
            output_root = args.next() orelse return error.MissingArgument;
        }
    }
    return output_root;
}

fn writeMetrics(writer: *std.Io.Writer) !void {
    const Storage = fixture.TestStorage;
    try writer.print(
        "{{\n  \"format\":1,\n  \"worker_slab_bytes\":{},\n" ++
            "  \"multipart_parser_runtime_bytes\":{},\n" ++
            "  \"body_workspace_bytes_per_slot\":{},\n" ++
            "  \"body_workspace_alignment_bytes\":{},\n" ++
            "  \"body_workspace_slots\":{},\n" ++
            "  \"chunked_workspace_bytes_per_slot\":{},\n" ++
            "  \"chunked_workspace_slots\":{},\n" ++
            "  \"receive_buffer_bytes\":{},\n" ++
            "  \"gzip_decoder_slots\":{},\n" ++
            "  \"gzip_input_queue_bytes_per_slot\":{},\n" ++
            "  \"gzip_output_mailbox_capacity_bytes_per_slot\":{},\n" ++
            "  \"gzip_output_mailbox_bytes_per_slot\":{},\n" ++
            "  \"gzip_decoder_control_bytes\":{},\n" ++
            "  \"gzip_decoder_slot_bytes\":{},\n" ++
            "  \"gzip_decoder_slots_bytes\":{},\n" ++
            "  \"gzip_decoder_requested_stack_bytes\":{}\n}}\n",
        .{
            Storage.required_bytes,
            @sizeOf(PureParser),
            Storage.body_workspace_bytes_per_slot,
            Storage.body_workspace_alignment_bytes,
            fixture.test_limits.body_workspace_slots,
            Storage.chunked_workspace_bytes_per_slot,
            fixture.test_limits.chunked_workspace_slots,
            fixture.test_limits.receive_buffer_bytes,
            fixture.test_limits.gzip.decoder_slots,
            Storage.gzip_input_queue_bytes_per_slot,
            Storage.gzip_output_mailbox_capacity_bytes_per_slot,
            Storage.gzip_output_mailbox_bytes_per_slot,
            Storage.gzip_decoder_control_bytes,
            Storage.gzip_decoder_slot_bytes,
            Storage.gzip_decoder_slots_bytes,
            Storage.gzip_decoder_requested_stack_bytes,
        },
    );
}
