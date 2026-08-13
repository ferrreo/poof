const std = @import("std");
const linux = std.os.linux;

const application = @import("application.zig");
const metrics = @import("metrics.zig");
const response = @import("response.zig");

pub const max_record_bytes: usize = 384;
pub const unmatched_route_id = std.math.maxInt(u16);

pub const ByteCounts = struct {
    request_wire: u64 = 0,
    request_decoded: u64 = 0,
    response_wire: u64 = 0,
};

/// Default event intentionally contains no request-controlled text.
pub const AccessEvent = struct {
    method: metrics.MethodClass,
    route_id: u16,
    status: ?response.Status,
    mapped_error: bool,
    transport: application.TransportOutcome,
    duration_ns: u64,
    bytes: ByteCounts,

    pub fn init(
        method: metrics.MethodClass,
        route_id: ?u16,
        outcome: application.Outcome,
        duration_ns: u64,
        bytes: ByteCounts,
    ) AccessEvent {
        return .{
            .method = method,
            .route_id = route_id orelse unmatched_route_id,
            .status = outcome.status,
            .mapped_error = outcome.mapped_error,
            .transport = outcome.transport,
            .duration_ns = duration_ns,
            .bytes = bytes,
        };
    }

    pub fn matched(event: AccessEvent) bool {
        return event.route_id != unmatched_route_id;
    }
};

pub const FormatError = error{NoSpaceLeft};

pub fn formatNdjson(event: AccessEvent, output: []u8) FormatError![]const u8 {
    return if (event.matched())
        formatMatched(event, output)
    else
        formatUnmatched(event, output);
}

fn formatMatched(event: AccessEvent, output: []u8) FormatError![]const u8 {
    return if (event.status) |status|
        std.fmt.bufPrint(output, record_matched_status, .{
            event.method.wire(),
            event.route_id,
            @intFromEnum(status),
            event.mapped_error,
            @tagName(event.transport),
            event.duration_ns,
            event.bytes.request_wire,
            event.bytes.request_decoded,
            event.bytes.response_wire,
        }) catch error.NoSpaceLeft
    else
        std.fmt.bufPrint(output, record_matched_no_status, .{
            event.method.wire(),
            event.route_id,
            event.mapped_error,
            @tagName(event.transport),
            event.duration_ns,
            event.bytes.request_wire,
            event.bytes.request_decoded,
            event.bytes.response_wire,
        }) catch error.NoSpaceLeft;
}

fn formatUnmatched(event: AccessEvent, output: []u8) FormatError![]const u8 {
    return if (event.status) |status|
        std.fmt.bufPrint(output, record_unmatched_status, .{
            event.method.wire(),
            @intFromEnum(status),
            event.mapped_error,
            @tagName(event.transport),
            event.duration_ns,
            event.bytes.request_wire,
            event.bytes.request_decoded,
            event.bytes.response_wire,
        }) catch error.NoSpaceLeft
    else
        std.fmt.bufPrint(output, record_unmatched_no_status, .{
            event.method.wire(),
            event.mapped_error,
            @tagName(event.transport),
            event.duration_ns,
            event.bytes.request_wire,
            event.bytes.request_decoded,
            event.bytes.response_wire,
        }) catch error.NoSpaceLeft;
}

const record_prefix =
    "{{\"method\":\"{s}\",\"route_id\":";
const record_suffix =
    ",\"mapped_error\":{},\"transport\":\"{s}\",\"duration_ns\":{d}" ++
    ",\"request_wire_bytes\":{d},\"request_decoded_bytes\":{d}" ++
    ",\"response_wire_bytes\":{d}}}\n";
const record_matched_status = record_prefix ++ "{d},\"status\":{d}" ++ record_suffix;
const record_matched_no_status = record_prefix ++ "{d},\"status\":null" ++ record_suffix;
const record_unmatched_status = record_prefix ++ "null,\"status\":{d}" ++ record_suffix;
const record_unmatched_no_status = record_prefix ++ "null,\"status\":null" ++ record_suffix;

pub fn Ring(comptime requested_capacity: u16) type {
    if (requested_capacity == 0) @compileError("PLOOF-E6100 access log ring capacity is zero");
    const capacity: u64 = requested_capacity;

    return struct {
        const Self = @This();

        events: [requested_capacity]AccessEvent = undefined,
        write_position: std.atomic.Value(u64) align(64) = .init(0),
        read_position: std.atomic.Value(u64) align(64) = .init(0),
        dropped_events: std.atomic.Value(u64) align(64) = .init(0),

        /// Single-producer operation. Full queues drop without waiting.
        pub fn push(ring: *Self, event: AccessEvent) bool {
            const write_position = ring.write_position.load(.monotonic);
            const read_position = ring.read_position.load(.acquire);
            const used = write_position -% read_position;
            std.debug.assert(used <= capacity);
            if (used == capacity) {
                saturatingIncrement(&ring.dropped_events);
                return false;
            }
            const index: usize = @intCast(write_position % capacity);
            ring.events[index] = event;
            ring.write_position.store(write_position +% 1, .release);
            return true;
        }

        /// Single-consumer operation.
        pub fn pop(ring: *Self) ?AccessEvent {
            const read_position = ring.read_position.load(.monotonic);
            const write_position = ring.write_position.load(.acquire);
            if (read_position == write_position) return null;
            std.debug.assert(write_position -% read_position <= capacity);
            const index: usize = @intCast(read_position % capacity);
            const event = ring.events[index];
            ring.read_position.store(read_position +% 1, .release);
            return event;
        }

        /// Transfer one event while publishing ownership before removing it
        /// from the queue. The caller clears `in_flight` after consumption.
        pub fn popOwned(
            ring: *Self,
            in_flight: *std.atomic.Value(u32),
        ) ?AccessEvent {
            const read_position = ring.read_position.load(.monotonic);
            const write_position = ring.write_position.load(.acquire);
            if (read_position == write_position) return null;
            std.debug.assert(write_position -% read_position <= capacity);
            std.debug.assert(in_flight.load(.monotonic) == 0);
            const index: usize = @intCast(read_position % capacity);
            const event = ring.events[index];
            in_flight.store(1, .release);
            ring.read_position.store(read_position +% 1, .release);
            return event;
        }

        pub fn count(ring: *const Self) u16 {
            const read_position = ring.read_position.load(.acquire);
            const write_position = ring.write_position.load(.acquire);
            return @intCast(@min(write_position -% read_position, capacity));
        }

        pub fn dropped(ring: *const Self) u64 {
            return ring.dropped_events.load(.acquire);
        }
    };
}

fn saturatingIncrement(value: *std.atomic.Value(u64)) void {
    var current = value.load(.monotonic);
    while (current != std.math.maxInt(u64)) {
        if (value.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |actual| {
            current = actual;
            continue;
        }
        return;
    }
}

pub const SinkFailure = struct {
    errno: linux.E,
    bytes_written: u16,

    pub fn recordBoundaryPreserved(failure: SinkFailure) bool {
        return failure.bytes_written == 0 and
            (failure.errno == .AGAIN or failure.errno == .INTR);
    }
};

pub const SinkContractError = error{
    AccessLogSinkInvalidDescriptor,
    AccessLogSinkMustBeWritable,
    AccessLogSinkMustBeNonBlocking,
    AccessLogSinkMustBePipeOrSocket,
};

const sink_write_attempts_max: u8 = 4;

pub const FileDescriptorSink = struct {
    descriptor: linux.fd_t,

    pub fn validate(sink: FileDescriptorSink) SinkContractError!void {
        const result = linux.fcntl(sink.descriptor, linux.F.GETFL, 0);
        if (linux.errno(result) != .SUCCESS) {
            return error.AccessLogSinkInvalidDescriptor;
        }
        const flags: linux.O = @bitCast(@as(u32, @intCast(result)));
        if (flags.ACCMODE == .RDONLY) return error.AccessLogSinkMustBeWritable;
        if (!flags.NONBLOCK) return error.AccessLogSinkMustBeNonBlocking;

        var status: linux.Statx = undefined;
        const stat_result = linux.statx(
            sink.descriptor,
            "",
            linux.AT.EMPTY_PATH | linux.AT.STATX_DONT_SYNC,
            .{ .TYPE = true },
            &status,
        );
        if (linux.errno(stat_result) != .SUCCESS or !status.mask.TYPE) {
            return error.AccessLogSinkInvalidDescriptor;
        }
        const mode: linux.mode_t = status.mode;
        if (!linux.S.ISFIFO(mode) and !linux.S.ISSOCK(mode)) {
            return error.AccessLogSinkMustBePipeOrSocket;
        }
    }

    pub fn write(sink: FileDescriptorSink, event: AccessEvent) ?SinkFailure {
        var storage: [max_record_bytes]u8 = undefined;
        const record = formatNdjson(event, &storage) catch unreachable;
        var written: usize = 0;
        var attempts: u8 = 0;
        while (written < record.len and attempts < sink_write_attempts_max) {
            attempts += 1;
            const result = linux.write(
                sink.descriptor,
                record[written..].ptr,
                record.len - written,
            );
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result == 0) return sinkFailure(.IO, written);
                    written += result;
                },
                .INTR => continue,
                else => |errno_value| return sinkFailure(errno_value, written),
            }
        }
        return if (written == record.len) null else sinkFailure(.AGAIN, written);
    }
};

fn sinkFailure(errno_value: linux.E, written: usize) SinkFailure {
    return .{ .errno = errno_value, .bytes_written = @intCast(written) };
}

test "default access record has closed fields and no request-controlled bytes" {
    const event = AccessEvent.init(
        .post,
        7,
        .{ .status = .created, .mapped_error = false, .transport = .completed },
        99,
        .{ .request_wire = 11, .request_decoded = 8, .response_wire = 23 },
    );
    var output: [max_record_bytes]u8 = undefined;
    const actual = try formatNdjson(event, &output);
    try std.testing.expectEqualStrings(
        "{\"method\":\"POST\",\"route_id\":7,\"status\":201," ++
            "\"mapped_error\":false,\"transport\":\"completed\",\"duration_ns\":99," ++
            "\"request_wire_bytes\":11,\"request_decoded_bytes\":8," ++
            "\"response_wire_bytes\":23}\n",
        actual,
    );
    try std.testing.expect(std.mem.indexOf(u8, actual, "secret") == null);
}

test "absent route and status remain finite null identities" {
    const event = AccessEvent.init(
        .get,
        null,
        .{ .status = null, .mapped_error = true, .transport = .framework_canceled },
        1,
        .{},
    );
    var output: [max_record_bytes]u8 = undefined;
    const actual = try formatNdjson(event, &output);
    try std.testing.expect(std.mem.indexOf(u8, actual, "\"route_id\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "\"status\":null") != null);
    try std.testing.expectError(error.NoSpaceLeft, formatNdjson(event, output[0..8]));
}

test "access methods retain OPTIONS and collapse extension methods" {
    var output: [max_record_bytes]u8 = undefined;
    const options = AccessEvent.init(
        .options,
        null,
        .{ .status = .no_content, .mapped_error = false, .transport = .completed },
        1,
        .{},
    );
    const options_record = try formatNdjson(options, &output);
    try std.testing.expect(std.mem.indexOf(u8, options_record, "\"method\":\"OPTIONS\"") != null);
    const other = AccessEvent.init(
        .other,
        null,
        .{ .status = null, .mapped_error = false, .transport = .peer_aborted },
        1,
        .{},
    );
    const other_record = try formatNdjson(other, &output);
    try std.testing.expect(std.mem.indexOf(u8, other_record, "\"method\":\"OTHER\"") != null);
}

test "SPSC ring preserves order, drops on saturation, and reuses slots" {
    const EventRing = Ring(2);
    var ring = EventRing{};
    const first = sampleEvent(1);
    const second = sampleEvent(2);
    const third = sampleEvent(3);
    try std.testing.expect(ring.push(first));
    try std.testing.expect(ring.push(second));
    try std.testing.expect(!ring.push(third));
    try std.testing.expectEqual(@as(u16, 2), ring.count());
    try std.testing.expectEqual(@as(u64, 1), ring.dropped());
    try std.testing.expectEqualDeep(first, ring.pop().?);
    try std.testing.expect(ring.push(third));
    try std.testing.expectEqualDeep(second, ring.pop().?);
    try std.testing.expectEqualDeep(third, ring.pop().?);
    try std.testing.expectEqual(@as(?AccessEvent, null), ring.pop());
}

test "SPSC ring positions wrap without changing order or capacity" {
    const EventRing = Ring(2);
    var ring = EventRing{};
    ring.read_position.store(std.math.maxInt(u64), .monotonic);
    ring.write_position.store(std.math.maxInt(u64), .monotonic);
    const first = sampleEvent(1);
    const second = sampleEvent(2);
    try std.testing.expect(ring.push(first));
    try std.testing.expect(ring.push(second));
    try std.testing.expectEqual(@as(u16, 2), ring.count());
    try std.testing.expectEqualDeep(first, ring.pop().?);
    try std.testing.expectEqualDeep(second, ring.pop().?);
    try std.testing.expectEqual(@as(u16, 0), ring.count());
}

test "maximum default access event fits the advertised record bound" {
    var output: [max_record_bytes]u8 = undefined;
    inline for (std.enums.values(metrics.MethodClass)) |method| {
        inline for (std.enums.values(application.TransportOutcome)) |transport| {
            const event = AccessEvent.init(
                method,
                unmatched_route_id - 1,
                .{
                    .status = try response.Status.fromInt(599),
                    .mapped_error = false,
                    .transport = transport,
                },
                std.math.maxInt(u64),
                .{
                    .request_wire = std.math.maxInt(u64),
                    .request_decoded = std.math.maxInt(u64),
                    .response_wire = std.math.maxInt(u64),
                },
            );
            const record = try formatNdjson(event, &output);
            try std.testing.expect(record.len <= max_record_bytes);
        }
    }
}

test "file descriptor sink emits one complete record without allocation" {
    var descriptors: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.pipe2(&descriptors, linux.O{})),
    );
    defer _ = linux.close(descriptors[0]);
    defer _ = linux.close(descriptors[1]);

    const event = sampleEvent(42);
    try std.testing.expectEqual(@as(?SinkFailure, null), (FileDescriptorSink{
        .descriptor = descriptors[1],
    }).write(event));
    var expected_storage: [max_record_bytes]u8 = undefined;
    const expected = try formatNdjson(event, &expected_storage);
    var actual: [max_record_bytes]u8 = undefined;
    const result = linux.read(descriptors[0], &actual, actual.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(result));
    try std.testing.expectEqualStrings(expected, actual[0..result]);
}

fn sampleEvent(duration_ns: u64) AccessEvent {
    return AccessEvent.init(
        .get,
        0,
        .{ .status = .ok, .mapped_error = false, .transport = .completed },
        duration_ns,
        .{},
    );
}
