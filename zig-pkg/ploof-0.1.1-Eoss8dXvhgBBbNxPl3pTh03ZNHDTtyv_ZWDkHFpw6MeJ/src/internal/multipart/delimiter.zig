const std = @import("std");
const boundary_module = @import("boundary.zig");

pub const padding_hard_max: usize = 1024;

pub const Error = error{
    Malformed,
    LimitExceeded,
};

pub const Event = union(enum) {
    need_more,
    data: []const u8,
    delimiter,
    close,
};

pub const Step = struct {
    consumed: usize,
    event: Event,
    /// When true, data borrows scanner storage and must be acknowledged first.
    data_retained: bool = false,
};

const Phase = enum(u8) {
    initial,
    search,
    suffix,
    after_hyphen,
    normal_padding,
    normal_cr,
    close_padding,
    close_cr,
    closed,
};

pub fn Scanner(comptime padding_bytes_max: usize) type {
    if (padding_bytes_max > padding_hard_max) {
        @compileError("multipart delimiter transport padding exceeds hard maximum 1024");
    }
    const marker_bytes_max = 4 + boundary_module.protocol_bytes_max;
    const pending_bytes_max = marker_bytes_max + 2 + padding_bytes_max + 2;

    return struct {
        const Self = @This();

        marker: [marker_bytes_max]u8 = undefined,
        marker_len: usize,
        pending: [pending_bytes_max]u8 = undefined,
        pending_len: usize = 0,
        emitted_len: usize = 0,
        match_len: usize = 0,
        padding_len: usize = 0,
        phase: Phase = .initial,

        pub fn init(boundary: []const u8) Self {
            std.debug.assert(boundary.len > 0);
            std.debug.assert(boundary.len <= boundary_module.protocol_bytes_max);
            var self = Self{ .marker_len = boundary.len + 4 };
            @memcpy(self.marker[0..4], "\r\n--");
            @memcpy(self.marker[4..self.marker_len], boundary);
            return self;
        }

        pub fn feed(self: *Self, input: []const u8) Error!Step {
            if (self.emitted_len != 0) return .{
                .consumed = 0,
                .event = .{ .data = self.pending[0..self.emitted_len] },
                .data_retained = true,
            };
            if (self.phase == .closed) {
                return .{ .consumed = input.len, .event = .need_more };
            }

            var consumed: usize = 0;
            while (consumed < input.len) {
                if (self.canBorrowDirect()) {
                    const tail = input[consumed..];
                    const offset = std.mem.indexOfScalar(u8, tail, '\r') orelse {
                        return .{ .consumed = input.len, .event = .{ .data = tail } };
                    };
                    if (offset != 0) {
                        return .{
                            .consumed = consumed + offset,
                            .event = .{ .data = tail[0..offset] },
                        };
                    }
                }

                const event = try self.consumeByte(input[consumed]);
                consumed += 1;
                if (event) |ready| return .{ .consumed = consumed, .event = ready };
                if (self.emitted_len != 0) {
                    return .{
                        .consumed = consumed,
                        .event = .{ .data = self.pending[0..self.emitted_len] },
                        .data_retained = true,
                    };
                }
            }
            return .{ .consumed = consumed, .event = .need_more };
        }

        pub fn finish(self: *Self) Error!?Event {
            if (self.emitted_len != 0) return error.Malformed;
            return switch (self.phase) {
                .closed => null,
                .close_padding => finish: {
                    self.pending_len = 0;
                    self.match_len = 0;
                    self.phase = .closed;
                    break :finish .close;
                },
                else => error.Malformed,
            };
        }

        /// Releases an accepted prefix from the current retained data event.
        pub fn acknowledgeData(self: *Self, count: usize) void {
            std.debug.assert(count <= self.emitted_len);
            if (count == 0) return;
            const retained = self.pending_len - count;
            std.mem.copyForwards(
                u8,
                self.pending[0..retained],
                self.pending[count..self.pending_len],
            );
            self.pending_len = retained;
            self.emitted_len -= count;
        }

        pub fn hasRetainedData(self: *const Self) bool {
            return self.emitted_len != 0;
        }

        fn consumeByte(self: *Self, byte: u8) Error!?Event {
            try self.append(byte);
            return switch (self.phase) {
                .initial, .search => self.consumeMarkerByte(byte),
                .suffix => self.consumeSuffix(byte),
                .after_hyphen => self.consumeSecondHyphen(byte),
                .normal_padding => self.consumePadding(byte, false),
                .normal_cr => self.consumeLf(byte, false),
                .close_padding => self.consumePadding(byte, true),
                .close_cr => self.consumeLf(byte, true),
                .closed => unreachable,
            };
        }

        fn consumeMarkerByte(self: *Self, byte: u8) ?Event {
            const marker_target = self.target();
            if (byte == marker_target[self.match_len]) {
                self.match_len += 1;
                if (self.match_len == marker_target.len) self.phase = .suffix;
                return null;
            }
            self.fallback();
            return null;
        }

        fn consumeSuffix(self: *Self, byte: u8) Error!?Event {
            if (byte == '-') {
                self.phase = .after_hyphen;
            } else if (isPadding(byte)) {
                try self.beginPadding(false);
            } else if (byte == '\r') {
                self.phase = .normal_cr;
            } else {
                self.fallback();
            }
            return null;
        }

        fn consumeSecondHyphen(self: *Self, byte: u8) ?Event {
            if (byte == '-') {
                self.phase = .close_padding;
                self.padding_len = 0;
            } else {
                self.fallback();
            }
            return null;
        }

        fn consumePadding(self: *Self, byte: u8, closing: bool) Error!?Event {
            if (isPadding(byte)) {
                if (self.padding_len == padding_bytes_max) return error.LimitExceeded;
                self.padding_len += 1;
            } else if (byte == '\r') {
                self.phase = if (closing) .close_cr else .normal_cr;
            } else {
                self.fallback();
            }
            return null;
        }

        fn consumeLf(self: *Self, byte: u8, closing: bool) ?Event {
            if (byte != '\n') {
                self.fallback();
                return null;
            }
            self.pending_len = 0;
            self.match_len = 0;
            self.padding_len = 0;
            self.phase = if (closing) .closed else .search;
            return if (closing) .close else .delimiter;
        }

        fn beginPadding(self: *Self, closing: bool) Error!void {
            if (padding_bytes_max == 0) return error.LimitExceeded;
            self.padding_len = 1;
            self.phase = if (closing) .close_padding else .normal_padding;
        }

        fn fallback(self: *Self) void {
            const suffix_len = longestMarkerPrefixSuffix(
                self.pending[0..self.pending_len],
                self.marker[0..self.marker_len],
            );
            self.emitted_len = self.pending_len - suffix_len;
            self.match_len = suffix_len;
            self.phase = if (suffix_len == self.marker_len) .suffix else .search;
            self.padding_len = 0;
        }

        fn target(self: *const Self) []const u8 {
            if (self.phase == .initial) return self.marker[2..self.marker_len];
            return self.marker[0..self.marker_len];
        }

        fn canBorrowDirect(self: *const Self) bool {
            return self.phase == .search and self.pending_len == 0;
        }

        fn append(self: *Self, byte: u8) Error!void {
            if (self.pending_len == self.pending.len) return error.LimitExceeded;
            self.pending[self.pending_len] = byte;
            self.pending_len += 1;
        }
    };
}

fn longestMarkerPrefixSuffix(bytes: []const u8, marker: []const u8) usize {
    const candidate_max = @min(bytes.len, marker.len);
    var candidate_len = candidate_max;
    while (candidate_len != 0) : (candidate_len -= 1) {
        const suffix = bytes[bytes.len - candidate_len ..];
        if (std.mem.eql(u8, suffix, marker[0..candidate_len])) return candidate_len;
    }
    return 0;
}

fn isPadding(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

const Trace = struct {
    data: [512]u8 = undefined,
    data_len: usize = 0,
    delimiters: usize = 0,
    closes: usize = 0,

    fn append(self: *Trace, bytes: []const u8) void {
        @memcpy(self.data[self.data_len .. self.data_len + bytes.len], bytes);
        self.data_len += bytes.len;
    }
};

fn traceInput(comptime padding_max: usize, input: []const u8, split: usize) Error!Trace {
    var scanner = Scanner(padding_max).init("AaB");
    var trace = Trace{};
    var input_offset: usize = 0;
    while (input_offset < input.len) {
        const chunk_end = @min(input.len, input_offset + split);
        var chunk_offset = input_offset;
        while (chunk_offset < chunk_end) {
            const step = try scanner.feed(input[chunk_offset..chunk_end]);
            chunk_offset += step.consumed;
            var progressed = step.consumed != 0;
            switch (step.event) {
                .need_more => {},
                .data => |bytes| {
                    trace.append(bytes);
                    if (step.data_retained) {
                        scanner.acknowledgeData(bytes.len);
                        progressed = true;
                    }
                },
                .delimiter => trace.delimiters += 1,
                .close => trace.closes += 1,
            }
            if (!progressed) return error.Malformed;
        }
        input_offset = chunk_end;
    }
    if (try scanner.finish()) |event| switch (event) {
        .close => trace.closes += 1,
        else => return error.Malformed,
    };
    return trace;
}

test "retained false delimiter data supports partial acknowledgement" {
    var scanner = Scanner(0).init("AaB");
    const first = try scanner.feed("--AaBX");
    try std.testing.expect(first.data_retained);
    try std.testing.expectEqualStrings("--AaBX", first.event.data);
    scanner.acknowledgeData(1);

    const second = try scanner.feed("");
    try std.testing.expectEqual(@as(usize, 0), second.consumed);
    try std.testing.expect(second.data_retained);
    try std.testing.expectEqualStrings("-AaBX", second.event.data);
    scanner.acknowledgeData(second.event.data.len);
    try std.testing.expect(!scanner.hasRetainedData());
}

test "recognizes strict delimiters across every fragmentation" {
    const input = "preamble\r\n--AaB\r\nalpha\r\n--AaB \t\r\nbeta\r\n--AaB--\r\nepilogue";
    for (1..input.len + 1) |split| {
        const trace = try traceInput(8, input, split);
        try std.testing.expectEqualStrings("preamblealphabeta", trace.data[0..trace.data_len]);
        try std.testing.expectEqual(@as(usize, 2), trace.delimiters);
        try std.testing.expectEqual(@as(usize, 1), trace.closes);
    }
}

test "invalid candidates remain byte-exact data" {
    const input = "--AaBX\r\n--AaB-X\r\n--AaB \tX\r\n--AaB--";
    const expected = "--AaBX\r\n--AaB-X\r\n--AaB \tX";
    for (1..input.len + 1) |split| {
        const trace = try traceInput(8, input, split);
        try std.testing.expectEqualStrings(expected, trace.data[0..trace.data_len]);
        try std.testing.expectEqual(@as(usize, 1), trace.closes);
    }
}

test "closing delimiter accepts exact body end and epilogue" {
    const eof_close = try traceInput(0, "--AaB--", 1);
    try std.testing.expectEqual(@as(usize, 1), eof_close.closes);
    const epilogue = try traceInput(0, "--AaB--\r\nignored", 2);
    try std.testing.expectEqual(@as(usize, 0), epilogue.data_len);
}

test "padding limits and truncation are distinct" {
    var scanner = Scanner(2).init("AaB");
    const over = "--AaB   ";
    var offset: usize = 0;
    while (offset < over.len) {
        const step = scanner.feed(over[offset..]) catch |problem| {
            try std.testing.expectEqual(error.LimitExceeded, problem);
            break;
        };
        offset += step.consumed;
    } else return error.TestExpectedError;

    var truncated = Scanner(8).init("AaB");
    _ = try truncated.feed("--AaB\r");
    try std.testing.expectError(error.Malformed, truncated.finish());
}

test {
    std.testing.refAllDecls(@This());
}
