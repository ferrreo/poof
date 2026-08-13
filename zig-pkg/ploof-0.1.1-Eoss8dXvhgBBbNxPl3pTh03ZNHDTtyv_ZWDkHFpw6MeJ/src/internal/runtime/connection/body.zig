const std = @import("std");

pub const LimitExceeded = enum(u8) {
    encoded,
    decoded,
    encoded_and_decoded,
};

pub const InitResult = union(enum) {
    accepted: FixedIdentity,
    over_limit: LimitExceeded,
};

pub const FeedError = error{
    AlreadyComplete,
    CounterOverflow,
};

pub const FeedResult = struct {
    body: []const u8,
    tail: []const u8,
    progress: u32,
    complete: bool,
};

pub const FixedIdentity = struct {
    expected_bytes: u32,
    progress_bytes: u32 = 0,

    pub fn init(
        declared_length: u64,
        encoded_limit: u64,
        decoded_limit: u64,
    ) InitResult {
        const encoded_exceeded = declared_length > encoded_limit;
        const decoded_exceeded = declared_length > decoded_limit;
        if (encoded_exceeded or decoded_exceeded) {
            return .{ .over_limit = exceeded(encoded_exceeded, decoded_exceeded) };
        }
        const narrowed = std.math.cast(u32, declared_length) orelse {
            return .{ .over_limit = .encoded_and_decoded };
        };
        return .{ .accepted = .{ .expected_bytes = narrowed } };
    }

    pub fn expected(self: *const FixedIdentity) u32 {
        return self.expected_bytes;
    }

    pub fn progress(self: *const FixedIdentity) u32 {
        return self.progress_bytes;
    }

    pub fn complete(self: *const FixedIdentity) bool {
        return self.progress_bytes == self.expected_bytes;
    }

    pub fn feed(self: *FixedIdentity, input: []const u8) FeedError!FeedResult {
        if (self.complete()) return error.AlreadyComplete;
        const remaining = std.math.sub(
            u32,
            self.expected_bytes,
            self.progress_bytes,
        ) catch return error.CounterOverflow;
        const input_length = std.math.cast(u64, input.len) orelse {
            return error.CounterOverflow;
        };
        const body_length_u64 = @min(@as(u64, remaining), input_length);
        const body_length = std.math.cast(usize, body_length_u64) orelse {
            return error.CounterOverflow;
        };
        const body_progress = std.math.cast(u32, body_length_u64) orelse {
            return error.CounterOverflow;
        };
        const progress_bytes = std.math.add(
            u32,
            self.progress_bytes,
            body_progress,
        ) catch return error.CounterOverflow;
        if (progress_bytes > self.expected_bytes) return error.CounterOverflow;
        self.progress_bytes = progress_bytes;
        return .{
            .body = input[0..body_length],
            .tail = input[body_length..],
            .progress = progress_bytes,
            .complete = progress_bytes == self.expected_bytes,
        };
    }
};

fn exceeded(encoded: bool, decoded: bool) LimitExceeded {
    if (encoded and decoded) return .encoded_and_decoded;
    if (encoded) return .encoded;
    return .decoded;
}

fn accepted(expected: u64, encoded_limit: u64, decoded_limit: u64) !FixedIdentity {
    return switch (FixedIdentity.init(expected, encoded_limit, decoded_limit)) {
        .accepted => |state| state,
        .over_limit => error.TestUnexpectedResult,
    };
}

test "fixed identity accepts inclusive limits and completes zero immediately" {
    var boundary = try accepted(9, 9, 9);
    try std.testing.expectEqual(@as(u32, 9), boundary.expected());
    try std.testing.expectEqual(@as(u32, 0), boundary.progress());
    try std.testing.expect(!boundary.complete());

    var empty = try accepted(0, 0, 0);
    try std.testing.expect(empty.complete());
    try std.testing.expectError(error.AlreadyComplete, empty.feed("tail"));
}

test "fixed identity classifies each limit before narrowing" {
    const Case = struct {
        expected: u64,
        encoded_limit: u64,
        decoded_limit: u64,
        issue: LimitExceeded,
    };
    const cases = [_]Case{
        .{ .expected = 6, .encoded_limit = 5, .decoded_limit = 6, .issue = .encoded },
        .{ .expected = 6, .encoded_limit = 6, .decoded_limit = 5, .issue = .decoded },
        .{
            .expected = 6,
            .encoded_limit = 5,
            .decoded_limit = 4,
            .issue = .encoded_and_decoded,
        },
        .{
            .expected = @as(u64, std.math.maxInt(u32)) + 1,
            .encoded_limit = std.math.maxInt(u32),
            .decoded_limit = std.math.maxInt(u64),
            .issue = .encoded,
        },
        .{
            .expected = @as(u64, std.math.maxInt(u32)) + 1,
            .encoded_limit = std.math.maxInt(u64),
            .decoded_limit = std.math.maxInt(u32),
            .issue = .decoded,
        },
        .{
            .expected = @as(u64, std.math.maxInt(u32)) + 1,
            .encoded_limit = std.math.maxInt(u32),
            .decoded_limit = std.math.maxInt(u32),
            .issue = .encoded_and_decoded,
        },
    };
    for (cases) |case| {
        const issue = switch (FixedIdentity.init(
            case.expected,
            case.encoded_limit,
            case.decoded_limit,
        )) {
            .accepted => return error.TestUnexpectedResult,
            .over_limit => |value| value,
        };
        try std.testing.expectEqual(case.issue, issue);
    }
}

test "fixed identity preserves fragmentation progress and exact over-read tail" {
    var state = try accepted(7, 10, 10);
    const first = try state.feed("ab");
    try std.testing.expectEqualStrings("ab", first.body);
    try std.testing.expectEqualStrings("", first.tail);
    try std.testing.expectEqual(@as(u32, 2), first.progress);
    try std.testing.expect(!first.complete);

    const second = try state.feed("cde");
    try std.testing.expectEqualStrings("cde", second.body);
    try std.testing.expectEqual(@as(u32, 5), second.progress);
    try std.testing.expect(!second.complete);

    const final = try state.feed("fgNEXT");
    try std.testing.expectEqualStrings("fg", final.body);
    try std.testing.expectEqualStrings("NEXT", final.tail);
    try std.testing.expectEqual(@as(u32, 7), final.progress);
    try std.testing.expect(final.complete);
    try std.testing.expect(state.complete());
    try std.testing.expectError(error.AlreadyComplete, state.feed("later"));
}

test "fixed identity accepts empty fragments only before completion" {
    var state = try accepted(1, 1, 1);
    const empty = try state.feed("");
    try std.testing.expectEqual(@as(u32, 0), empty.progress);
    try std.testing.expect(!empty.complete);
    try std.testing.expectEqualStrings("", empty.body);
    try std.testing.expectEqualStrings("", empty.tail);

    const final = try state.feed("x");
    try std.testing.expect(final.complete);
    try std.testing.expectError(error.AlreadyComplete, state.feed(""));
}

test "fixed identity retains full u32 expected count without overflow" {
    var state = try accepted(
        std.math.maxInt(u32),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
    );
    const result = try state.feed("zig");
    try std.testing.expectEqual(@as(u32, 3), result.progress);
    try std.testing.expect(!result.complete);
    try std.testing.expectEqual(std.math.maxInt(u32), state.expected());
}

test "fixed identity reports corrupted counters without relying on assertions" {
    var state = FixedIdentity{
        .expected_bytes = 1,
        .progress_bytes = 2,
    };
    try std.testing.expectError(error.CounterOverflow, state.feed("x"));
}

test "fixed identity fragmentation differential fuzz" {
    try std.testing.fuzz({}, fuzzFixedIdentity, .{ .corpus = &fixed_identity_fuzz_corpus });
}

const fixed_identity_fuzz_corpus = struct {
    const complete_tail = [_]u8{ 8, 0, 0, 0 } ++ "bodyNEXT";
    const fragmented = [_]u8{ 10, 0, 0, 0 } ++ "fragmented";
    const empty = [_]u8{ 0, 0, 0, 0 };
    const values = [_][]const u8{ complete_tail, fragmented, &empty };
}.values;

const FuzzSnapshot = struct {
    progress: u32,
    tail_offset: usize,
    complete: bool,
};

const FuzzCapture = struct {
    bytes: [512]u8 = undefined,
    length: usize = 0,

    fn append(self: *FuzzCapture, value: []const u8) !void {
        if (value.len > self.bytes.len - self.length) return error.TestUnexpectedResult;
        @memcpy(self.bytes[self.length..][0..value.len], value);
        self.length += value.len;
    }

    fn slice(self: *const FuzzCapture) []const u8 {
        return self.bytes[0..self.length];
    }
};

fn fuzzFixedIdentity(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [512]u8 = undefined;
    const input = input_storage[0..smith.slice(&input_storage)];
    try fuzzInitClassification(smith);
    const expected = smith.valueRangeAtMost(u16, 0, input_storage.len);

    var contiguous = try accepted(expected, expected, expected);
    var contiguous_capture = FuzzCapture{};
    const contiguous_snapshot = try fuzzDrive(
        &contiguous,
        input,
        false,
        &contiguous_capture,
    );
    var fragmented = try accepted(expected, expected, expected);
    var fragmented_capture = FuzzCapture{};
    const fragmented_snapshot = try fuzzDrive(
        &fragmented,
        input,
        true,
        &fragmented_capture,
    );

    try std.testing.expectEqualDeep(contiguous_snapshot, fragmented_snapshot);
    try std.testing.expectEqualSlices(u8, contiguous_capture.slice(), fragmented_capture.slice());
    try expectFuzzReference(input, expected, contiguous_snapshot, &contiguous_capture);
}

fn fuzzInitClassification(smith: *std.testing.Smith) !void {
    const declared = smith.value(u64);
    const encoded_limit = smith.value(u64);
    const decoded_limit: u64 = smith.value(u32);
    const encoded_exceeded = declared > encoded_limit;
    const decoded_exceeded = declared > decoded_limit;
    const result = FixedIdentity.init(declared, encoded_limit, decoded_limit);
    if (encoded_exceeded or decoded_exceeded) {
        const issue = switch (result) {
            .accepted => return error.TestUnexpectedResult,
            .over_limit => |value| value,
        };
        try std.testing.expectEqual(exceeded(encoded_exceeded, decoded_exceeded), issue);
        return;
    }
    const state = switch (result) {
        .accepted => |value| value,
        .over_limit => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u32, @intCast(declared)), state.expected());
}

fn fuzzDrive(
    state: *FixedIdentity,
    input: []const u8,
    one_byte: bool,
    capture: *FuzzCapture,
) !FuzzSnapshot {
    var offset: usize = 0;
    while (offset < input.len and !state.complete()) {
        const end = if (one_byte) offset + 1 else input.len;
        const result = try state.feed(input[offset..end]);
        try capture.append(result.body);
        offset += result.body.len;
        if (result.tail.len != end - offset) return error.TestUnexpectedResult;
        if (!result.complete and result.tail.len != 0) return error.TestUnexpectedResult;
    }
    return .{
        .progress = state.progress(),
        .tail_offset = offset,
        .complete = state.complete(),
    };
}

fn expectFuzzReference(
    input: []const u8,
    expected: u16,
    snapshot: FuzzSnapshot,
    capture: *const FuzzCapture,
) !void {
    const body_length = @min(input.len, @as(usize, expected));
    try std.testing.expectEqual(@as(u32, @intCast(body_length)), snapshot.progress);
    try std.testing.expectEqual(body_length == expected, snapshot.complete);
    try std.testing.expectEqual(body_length, snapshot.tail_offset);
    try std.testing.expectEqualSlices(u8, input[0..body_length], capture.slice());
}
