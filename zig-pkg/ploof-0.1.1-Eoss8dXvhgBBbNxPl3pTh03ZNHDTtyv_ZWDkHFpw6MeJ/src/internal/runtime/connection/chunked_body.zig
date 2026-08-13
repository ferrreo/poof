const std = @import("std");
const chunked = @import("../../http1/chunked.zig");
const request_head = @import("../../http1/request_head.zig");
const request_trailers = @import("../../http1/request_trailers.zig");

pub const Status = chunked.Status;

pub const Rejection = struct {
    status: Status,
    close: bool = true,
};

pub const Event = union(enum) {
    need_more,
    data: []const u8,
    ready,
    rejected: Rejection,
};

pub const FeedResult = struct {
    consumed: usize,
    event: Event,
};

pub const ReadyTrailers = struct {
    bytes: []const u8,
    fields: []const request_head.Field,
};

pub const ProfileIssue = enum(u8) {
    chunks_zero,
    trailer_section_bytes_zero,
    trailer_section_bytes_above_hard_max,
    trailer_field_line_bytes_zero,
    trailer_field_line_bytes_above_hard_max,
    trailer_field_line_bytes_above_section_max,
    trailer_names_zero,
    trailer_names_above_hard_max,
    trailer_fields_zero,
    trailer_fields_above_hard_max,
};

pub const Profile = struct {
    chunks_max: u32 = chunked.standard_chunks_max,
    trailer_section_bytes_max: u32 =
        request_trailers.standard_limits.section_bytes_max,
    trailer_field_line_bytes_max: u32 =
        request_trailers.standard_limits.field_line_bytes_max,
    trailer_names_max: u16 = request_trailers.standard_names_max,
    trailer_fields_max: u16 = request_trailers.standard_limits.fields_max,

    pub fn issue(profile: Profile) ?ProfileIssue {
        if (profile.chunks_max == 0) return .chunks_zero;
        if (profile.trailer_names_max == 0) return .trailer_names_zero;
        if (profile.trailer_names_max > request_trailers.names_hard_max) {
            return .trailer_names_above_hard_max;
        }
        const trailer_issue = profile.trailerLimits().issue() orelse return null;
        return switch (trailer_issue) {
            .section_bytes_zero => .trailer_section_bytes_zero,
            .section_bytes_above_hard_max => .trailer_section_bytes_above_hard_max,
            .field_line_bytes_zero => .trailer_field_line_bytes_zero,
            .field_line_bytes_above_hard_max => .trailer_field_line_bytes_above_hard_max,
            .field_line_bytes_above_section_max => {
                return .trailer_field_line_bytes_above_section_max;
            },
            .fields_zero => .trailer_fields_zero,
            .fields_above_hard_max => .trailer_fields_above_hard_max,
        };
    }

    pub fn validate(comptime profile: Profile) Profile {
        if (profile.issue()) |problem| @compileError(profileIssueMessage(problem));
        return profile;
    }

    pub fn trailerLimits(profile: Profile) request_trailers.Limits {
        return .{
            .section_bytes_max = profile.trailer_section_bytes_max,
            .field_line_bytes_max = profile.trailer_field_line_bytes_max,
            .fields_max = profile.trailer_fields_max,
        };
    }
};

pub const standard_profile = Profile.validate(.{});

const Terminal = enum(u8) {
    receiving,
    ready,
    rejected,
};

pub fn Receiver(comptime requested_profile: Profile) type {
    const profile = Profile.validate(requested_profile);
    const ChunkDecoder = chunked.Decoder(profile.chunks_max);
    const DeclarationSet = request_trailers.Declarations(profile.trailer_names_max);
    const TrailerDecoder = request_trailers.Decoder(
        profile.trailerLimits(),
        profile.trailer_names_max,
    );
    const ChunkPhase = struct {
        decoder: ChunkDecoder,
        declarations: DeclarationSet,
        head_bytes: []const u8,
    };
    const Phase = union(enum) {
        chunks: ChunkPhase,
        trailers: TrailerDecoder,
    };
    const TrailerContext = struct {
        declarations: DeclarationSet,
        head_bytes: []const u8,
    };

    return struct {
        const Self = @This();

        pub const TrailerDeclarations = DeclarationSet;

        phase: Phase,
        encoded_wire_bytes_max: u64,
        decoded_bytes_max: u64,
        wire_bytes: u64 = 0,
        decoded_bytes: u64 = 0,
        trailer_wire_base: u64 = 0,
        terminal: Terminal = .receiving,
        rejection_status: Status = .bad_request,

        pub fn init(
            encoded_wire_bytes_max: u64,
            decoded_bytes_max: u64,
            declarations: DeclarationSet,
            stable_head_bytes: []const u8,
        ) Self {
            return .{
                .phase = .{ .chunks = .{
                    .decoder = ChunkDecoder.init(encoded_wire_bytes_max),
                    .declarations = declarations,
                    .head_bytes = stable_head_bytes,
                } },
                .encoded_wire_bytes_max = encoded_wire_bytes_max,
                .decoded_bytes_max = decoded_bytes_max,
            };
        }

        pub fn feed(self: *Self, input: []const u8) FeedResult {
            switch (self.terminal) {
                .ready => return readyResult(0),
                .rejected => return self.rejectedResult(0),
                .receiving => {},
            }
            return switch (self.phase) {
                .chunks => self.feedChunks(input),
                .trailers => self.feedTrailers(input, 0),
            };
        }

        pub fn wireBytesConsumed(self: *const Self) u64 {
            return self.wire_bytes;
        }

        pub fn decodedBytesProduced(self: *const Self) u64 {
            return self.decoded_bytes;
        }

        pub fn trailers(self: *const Self) ?ReadyTrailers {
            if (self.terminal != .ready) return null;
            return switch (self.phase) {
                .chunks => null,
                .trailers => |*decoder| .{
                    .bytes = decoder.bytes(),
                    .fields = decoder.fields(),
                },
            };
        }

        pub fn rejectionStatus(self: *const Self) ?Status {
            return if (self.terminal == .rejected) self.rejection_status else null;
        }

        fn feedChunks(self: *Self, input: []const u8) FeedResult {
            if (self.decoded_bytes > self.decoded_bytes_max) {
                return self.reject(0, .bad_request);
            }
            const decoded_remaining = self.decoded_bytes_max - self.decoded_bytes;
            const result = switch (self.phase) {
                .chunks => |*active| active.decoder.feedDecodedBounded(
                    input,
                    decoded_remaining,
                    2,
                ),
                .trailers => return self.reject(0, .bad_request),
            };
            if (result.consumed > input.len) return self.reject(0, .bad_request);
            if (!self.recordChunkWire()) return self.reject(result.consumed, .bad_request);

            switch (result.event) {
                .need_more => {
                    return needMoreResult(result.consumed);
                },
                .data => |data| return self.emitData(result.consumed, data),
                .trailers_begin => {
                    const remaining = self.encoded_wire_bytes_max - self.wire_bytes;
                    if (remaining < 2) {
                        return self.reject(result.consumed, .payload_too_large);
                    }
                    if (!self.beginTrailers()) {
                        return self.reject(result.consumed, .bad_request);
                    }
                    return self.feedTrailers(input, result.consumed);
                },
                .rejected => |rejection| return self.reject(
                    result.consumed,
                    rejection.status,
                ),
            }
        }

        fn feedTrailers(self: *Self, input: []const u8, start: usize) FeedResult {
            if (start > input.len) return self.reject(0, .bad_request);
            const result = switch (self.phase) {
                .chunks => return self.reject(start, .bad_request),
                .trailers => |*active| active.feed(input[start..]),
            };
            const remaining = input.len - start;
            if (result.consumed > remaining) return self.reject(start, .bad_request);
            const consumed = start + result.consumed;
            if (!self.recordTrailerWire()) return self.reject(consumed, .bad_request);

            switch (result.event) {
                .need_more => return needMoreResult(consumed),
                .ready => {
                    self.terminal = .ready;
                    return readyResult(consumed);
                },
                .rejected => |rejection| return self.reject(consumed, rejection.status),
            }
        }

        fn emitData(self: *Self, consumed: usize, data: []const u8) FeedResult {
            if (self.decoded_bytes > self.decoded_bytes_max) {
                return self.reject(consumed, .bad_request);
            }
            const length: u64 = std.math.cast(u64, data.len) orelse {
                return self.reject(consumed, .payload_too_large);
            };
            const remaining = self.decoded_bytes_max - self.decoded_bytes;
            if (length > remaining) return self.reject(consumed, .payload_too_large);
            self.decoded_bytes += length;
            return .{ .consumed = consumed, .event = .{ .data = data } };
        }

        fn beginTrailers(self: *Self) bool {
            if (self.wire_bytes > self.encoded_wire_bytes_max) return false;
            const remaining = self.encoded_wire_bytes_max - self.wire_bytes;
            const context = switch (self.phase) {
                .chunks => |*active| TrailerContext{
                    .declarations = active.declarations,
                    .head_bytes = active.head_bytes,
                },
                .trailers => return false,
            };
            self.trailer_wire_base = self.wire_bytes;
            self.phase = .{ .trailers = TrailerDecoder.init(
                context.declarations,
                context.head_bytes,
                remaining,
            ) };
            return true;
        }

        fn recordChunkWire(self: *Self) bool {
            const consumed = switch (self.phase) {
                .chunks => |*active| active.decoder.wireBytesConsumed(),
                .trailers => return false,
            };
            if (consumed > self.encoded_wire_bytes_max) return false;
            self.wire_bytes = consumed;
            return true;
        }

        fn recordTrailerWire(self: *Self) bool {
            if (self.trailer_wire_base > self.encoded_wire_bytes_max) return false;
            const remaining = self.encoded_wire_bytes_max - self.trailer_wire_base;
            const consumed = switch (self.phase) {
                .chunks => return false,
                .trailers => |*active| active.wireBytesConsumed(),
            };
            if (consumed > remaining) return false;
            self.wire_bytes = self.trailer_wire_base + consumed;
            return true;
        }

        fn reject(self: *Self, consumed: usize, status: Status) FeedResult {
            self.terminal = .rejected;
            self.rejection_status = status;
            return self.rejectedResult(consumed);
        }

        fn rejectedResult(self: *const Self, consumed: usize) FeedResult {
            return .{
                .consumed = consumed,
                .event = .{ .rejected = .{ .status = self.rejection_status } },
            };
        }
    };
}

pub const StandardReceiver = Receiver(standard_profile);

pub const State = StandardReceiver;

pub const state_bytes_max: usize = 10 * 1024;
pub const state_bytes: usize = @sizeOf(StandardReceiver);

comptime {
    if (state_bytes > state_bytes_max) {
        @compileError("standard chunked body receiver exceeds 10 KiB");
    }
}

fn profileIssueMessage(problem: ProfileIssue) []const u8 {
    return switch (problem) {
        .chunks_zero => "chunk count limit must be nonzero",
        .trailer_section_bytes_zero => "trailer section size must be nonzero",
        .trailer_section_bytes_above_hard_max => "trailer section exceeds 1 MiB",
        .trailer_field_line_bytes_zero => "trailer field-line size must be nonzero",
        .trailer_field_line_bytes_above_hard_max => "trailer field line exceeds 1 MiB",
        .trailer_field_line_bytes_above_section_max => {
            return "trailer field-line size exceeds trailer section size";
        },
        .trailer_names_zero => "trailer declaration-name count must be nonzero",
        .trailer_names_above_hard_max => "trailer declaration-name count exceeds 1024",
        .trailer_fields_zero => "trailer field count must be nonzero",
        .trailer_fields_above_hard_max => "trailer field count exceeds 1024",
    };
}

fn needMoreResult(consumed: usize) FeedResult {
    return .{ .consumed = consumed, .event = .need_more };
}

fn readyResult(consumed: usize) FeedResult {
    return .{ .consumed = consumed, .event = .ready };
}

const declaration_head = "TrailerX-One";
const declaration_field = request_head.Field{
    .name = .{ .offset = 0, .length = "Trailer".len },
    .raw_value = .{ .offset = "Trailer".len, .length = "X-One".len },
    .value = .{ .offset = "Trailer".len, .length = "X-One".len },
};
const duplicate_trailer_section =
    "X-One: first\r\n" ++
    "X-One:\tsecond \t\r\n" ++
    "\r\n";
const fragmented_body_wire =
    "2; x=y\r\nda\r\n" ++
    "2\r\nta\r\n" ++
    "0\r\n" ++
    duplicate_trailer_section;
const pipeline_tail = "NEXT";
const fragmented_input = fragmented_body_wire ++ pipeline_tail;

const Fragmentation = union(enum) {
    contiguous,
    split: usize,
    one_byte,
};

const zero_span = request_head.Span{ .offset = 0, .length = 0 };
const zero_field = request_head.Field{
    .name = zero_span,
    .raw_value = zero_span,
    .value = zero_span,
};

const AcceptedSnapshot = struct {
    consumed: usize = 0,
    wire_bytes: u64 = 0,
    decoded_bytes: u64 = 0,
    body: [4]u8 = @splat(0),
    body_length: usize = 0,
    trailer_bytes: [64]u8 = @splat(0),
    trailer_length: usize = 0,
    fields: [4]request_head.Field = @splat(zero_field),
    fields_length: usize = 0,
};

test "chunked identity is invariant across every split and one-byte feeds" {
    const expected = try driveAccepted(.contiguous);
    try expectAcceptedSnapshot(&expected);

    var split: usize = 0;
    while (split <= fragmented_input.len) : (split += 1) {
        const actual = try driveAccepted(.{ .split = split });
        try std.testing.expectEqualDeep(expected, actual);
    }
    const one_byte = try driveAccepted(.one_byte);
    try std.testing.expectEqualDeep(expected, one_byte);
}

test "zero chunk begins empty trailers in the same feed and preserves tail" {
    var state = State.init(
        "0\r\n\r\n".len,
        0,
        .{},
        "",
    );
    const input = "0\r\n\r\nNEXT";
    const result = state.feed(input);
    try std.testing.expectEqual(@as(usize, 5), result.consumed);
    try std.testing.expect(result.event == .ready);
    try std.testing.expectEqualStrings("NEXT", input[result.consumed..]);
    try std.testing.expectEqual(@as(u64, 5), state.wireBytesConsumed());
    try std.testing.expectEqual(@as(u64, 0), state.decodedBytesProduced());

    const trailers = state.trailers() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("\r\n", trailers.bytes);
    try std.testing.expectEqual(@as(usize, 0), trailers.fields.len);
    const sticky = state.feed(input[result.consumed..]);
    try std.testing.expectEqual(@as(usize, 0), sticky.consumed);
    try std.testing.expect(sticky.event == .ready);
}

test "framing and trailer policy rejections are sticky bad requests" {
    var malformed = State.init(64, 64, .{}, "");
    try expectRejected(&malformed, "z\r\n", .bad_request);

    const declarations = try testDeclarations();
    var undeclared = State.init(64, 64, declarations, declaration_head);
    try expectRejected(
        &undeclared,
        "0\r\nX-Other: value\r\n\r\n",
        .bad_request,
    );

    var forbidden = State.init(64, 64, declarations, declaration_head);
    try expectRejected(
        &forbidden,
        "0\r\nHost: example.test\r\n\r\n",
        .bad_request,
    );
}

test "forbidden trailer declaration remains a declaration parser error" {
    const bytes = "TrailerHost";
    const field = request_head.Field{
        .name = .{ .offset = 0, .length = "Trailer".len },
        .raw_value = .{ .offset = "Trailer".len, .length = "Host".len },
        .value = .{ .offset = "Trailer".len, .length = "Host".len },
    };
    try std.testing.expectError(
        error.Forbidden,
        request_trailers.StandardDeclarations.parse(&.{field}, bytes),
    );
}

test "encoded budget includes trailers" {
    const declarations = try testDeclarations();
    const wire = "1\r\na\r\n0\r\nX-One: value\r\n\r\n";
    var state = State.init(wire.len - 1, 1, declarations, declaration_head);
    try expectRejected(&state, wire, .payload_too_large);
    try std.testing.expectEqual(@as(u64, 21), state.wireBytesConsumed());
    try std.testing.expectEqual(@as(u64, 1), state.decodedBytesProduced());
}

test "exhausted encoded budget rejects before waiting for impossible completion" {
    const cases = [_]struct { limit: u64, input: []const u8, consumed: u64 }{
        .{ .limit = 2, .input = "1", .consumed = 0 },
        .{ .limit = 3, .input = "0\r\n", .consumed = 0 },
        .{ .limit = 4, .input = "0\r\n", .consumed = 0 },
        .{ .limit = 5, .input = "0\r\nX", .consumed = 4 },
        .{ .limit = 6, .input = "1\r\na\r\n", .consumed = 3 },
    };
    for (cases) |case| {
        var state = State.init(case.limit, 1, .{}, "");
        try expectRejected(&state, case.input, .payload_too_large);
        try std.testing.expectEqual(case.consumed, state.wireBytesConsumed());
    }
}

test "decoded identity budget rejects an oversized data event" {
    const wire = "4\r\nWiki\r\n0\r\n\r\n";
    const expected = try driveDecodedLimit(wire, .contiguous);
    try std.testing.expectEqual(@as(usize, 3), expected.consumed);
    try std.testing.expectEqual(@as(u64, 3), expected.wire_bytes);
    try std.testing.expectEqual(@as(u64, 0), expected.decoded_bytes);

    var split: usize = 0;
    while (split <= wire.len) : (split += 1) {
        const actual = try driveDecodedLimit(wire, .{ .split = split });
        try std.testing.expectEqualDeep(expected, actual);
    }
    const one_byte = try driveDecodedLimit(wire, .one_byte);
    try std.testing.expectEqualDeep(expected, one_byte);
}

test "standard chunked receiver layout stays within the pooled-state budget" {
    try std.testing.expectEqual(state_bytes, @sizeOf(State));
    try std.testing.expect(state_bytes <= state_bytes_max);
}

test "chunked profile reports every invalid bound" {
    const Case = struct { expected: ProfileIssue, profile: Profile };
    const cases = [_]Case{
        .{ .expected = .chunks_zero, .profile = .{ .chunks_max = 0 } },
        .{ .expected = .trailer_section_bytes_zero, .profile = .{
            .trailer_section_bytes_max = 0,
        } },
        .{ .expected = .trailer_section_bytes_above_hard_max, .profile = .{
            .trailer_section_bytes_max = request_trailers.section_bytes_hard_max + 1,
        } },
        .{ .expected = .trailer_field_line_bytes_zero, .profile = .{
            .trailer_field_line_bytes_max = 0,
        } },
        .{ .expected = .trailer_field_line_bytes_above_hard_max, .profile = .{
            .trailer_section_bytes_max = request_trailers.section_bytes_hard_max,
            .trailer_field_line_bytes_max = request_trailers.section_bytes_hard_max + 1,
        } },
        .{ .expected = .trailer_field_line_bytes_above_section_max, .profile = .{
            .trailer_section_bytes_max = 1,
            .trailer_field_line_bytes_max = 2,
        } },
        .{ .expected = .trailer_names_zero, .profile = .{ .trailer_names_max = 0 } },
        .{ .expected = .trailer_names_above_hard_max, .profile = .{
            .trailer_names_max = request_trailers.names_hard_max + 1,
        } },
        .{ .expected = .trailer_fields_zero, .profile = .{ .trailer_fields_max = 0 } },
        .{ .expected = .trailer_fields_above_hard_max, .profile = .{
            .trailer_fields_max = request_trailers.fields_hard_max + 1,
        } },
    };
    for (cases) |case| {
        try std.testing.expectEqual(@as(?ProfileIssue, case.expected), case.profile.issue());
    }
}

test "nonstandard profile specializes all chunk and trailer bounds" {
    const constrained = comptime Profile.validate(.{
        .chunks_max = 1,
        .trailer_section_bytes_max = 64,
        .trailer_field_line_bytes_max = 32,
        .trailer_names_max = 1,
        .trailer_fields_max = 1,
    });
    const Constrained = Receiver(constrained);
    const declarations = try Constrained.TrailerDeclarations.parse(
        &.{declaration_field},
        declaration_head,
    );
    try std.testing.expect(@sizeOf(Constrained) < @sizeOf(StandardReceiver));

    var chunks = Constrained.init(64, 64, declarations, declaration_head);
    try expectRejected(&chunks, "1\r\na\r\n1\r\nb\r\n", .bad_request);

    var fields = Constrained.init(64, 64, declarations, declaration_head);
    try expectRejected(
        &fields,
        "0\r\nX-One:a\r\nX-One:b\r\n\r\n",
        .bad_request,
    );

    const declaration_bytes = "TrailerX-One, X-Two";
    const two_names = request_head.Field{
        .name = .{ .offset = 0, .length = "Trailer".len },
        .raw_value = .{ .offset = "Trailer".len, .length = "X-One, X-Two".len },
        .value = .{ .offset = "Trailer".len, .length = "X-One, X-Two".len },
    };
    try std.testing.expectError(
        error.TooMany,
        Constrained.TrailerDeclarations.parse(&.{two_names}, declaration_bytes),
    );

    const LineBound = Receiver(Profile.validate(.{
        .chunks_max = 1,
        .trailer_section_bytes_max = 64,
        .trailer_field_line_bytes_max = 8,
        .trailer_names_max = 1,
        .trailer_fields_max = 2,
    }));
    var line = LineBound.init(64, 64, declarations, declaration_head);
    try expectRejected(&line, "0\r\nX-One:a\r\n\r\n", .bad_request);

    const SectionBound = Receiver(Profile.validate(.{
        .chunks_max = 1,
        .trailer_section_bytes_max = 12,
        .trailer_field_line_bytes_max = 12,
        .trailer_names_max = 1,
        .trailer_fields_max = 2,
    }));
    var section = SectionBound.init(64, 64, declarations, declaration_head);
    try expectRejected(
        &section,
        "0\r\nX-One:a\r\nX-One:b\r\n\r\n",
        .bad_request,
    );
}

fn driveAccepted(mode: Fragmentation) !AcceptedSnapshot {
    const declarations = try testDeclarations();
    var state = State.init(
        fragmented_body_wire.len,
        4,
        declarations,
        declaration_head,
    );
    var snapshot = AcceptedSnapshot{};
    var offset: usize = 0;
    while (offset < fragmented_input.len) {
        const end = fragmentEnd(mode, offset, fragmented_input.len);
        const result = state.feed(fragmented_input[offset..end]);
        if (result.consumed > end - offset) return error.TestUnexpectedResult;
        offset += result.consumed;
        switch (result.event) {
            .need_more => if (offset != end) return error.TestUnexpectedResult,
            .data => |data| try appendBody(&snapshot, data),
            .ready => return finishAccepted(&state, snapshot, offset),
            .rejected => return error.TestUnexpectedResult,
        }
        if (result.consumed == 0) return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

fn fragmentEnd(mode: Fragmentation, offset: usize, input_length: usize) usize {
    return switch (mode) {
        .contiguous => input_length,
        .split => |split| if (offset < split) split else input_length,
        .one_byte => @min(offset + 1, input_length),
    };
}

const RejectedSnapshot = struct {
    consumed: usize,
    wire_bytes: u64,
    decoded_bytes: u64,
};

fn driveDecodedLimit(input: []const u8, mode: Fragmentation) !RejectedSnapshot {
    var state = State.init(input.len, 3, .{}, "");
    var offset: usize = 0;
    while (offset < input.len) {
        const end = fragmentEnd(mode, offset, input.len);
        const result = state.feed(input[offset..end]);
        if (result.consumed > end - offset) return error.TestUnexpectedResult;
        offset += result.consumed;
        switch (result.event) {
            .need_more => if (offset != end) return error.TestUnexpectedResult,
            .data, .ready => return error.TestUnexpectedResult,
            .rejected => |rejection| {
                try std.testing.expectEqual(Status.payload_too_large, rejection.status);
                try std.testing.expect(state.trailers() == null);
                const sticky = state.feed(input[offset..]);
                try std.testing.expectEqual(@as(usize, 0), sticky.consumed);
                try expectRejectedResult(sticky, .payload_too_large);
                return .{
                    .consumed = offset,
                    .wire_bytes = state.wireBytesConsumed(),
                    .decoded_bytes = state.decodedBytesProduced(),
                };
            },
        }
        if (result.consumed == 0) return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

fn appendBody(snapshot: *AcceptedSnapshot, data: []const u8) !void {
    if (data.len > snapshot.body.len - snapshot.body_length) {
        return error.TestUnexpectedResult;
    }
    @memcpy(snapshot.body[snapshot.body_length..][0..data.len], data);
    snapshot.body_length += data.len;
}

fn finishAccepted(
    state: *const State,
    snapshot_value: AcceptedSnapshot,
    consumed: usize,
) !AcceptedSnapshot {
    var snapshot = snapshot_value;
    const trailers = state.trailers() orelse return error.TestUnexpectedResult;
    if (trailers.bytes.len > snapshot.trailer_bytes.len) {
        return error.TestUnexpectedResult;
    }
    if (trailers.fields.len > snapshot.fields.len) return error.TestUnexpectedResult;
    @memcpy(snapshot.trailer_bytes[0..trailers.bytes.len], trailers.bytes);
    @memcpy(snapshot.fields[0..trailers.fields.len], trailers.fields);
    snapshot.consumed = consumed;
    snapshot.wire_bytes = state.wireBytesConsumed();
    snapshot.decoded_bytes = state.decodedBytesProduced();
    snapshot.trailer_length = trailers.bytes.len;
    snapshot.fields_length = trailers.fields.len;
    return snapshot;
}

fn expectAcceptedSnapshot(snapshot: *const AcceptedSnapshot) !void {
    try std.testing.expectEqual(fragmented_body_wire.len, snapshot.consumed);
    try std.testing.expectEqualStrings("data", snapshot.body[0..snapshot.body_length]);
    try std.testing.expectEqual(fragmented_body_wire.len, snapshot.wire_bytes);
    try std.testing.expectEqual(@as(u64, 4), snapshot.decoded_bytes);
    const bytes = snapshot.trailer_bytes[0..snapshot.trailer_length];
    try std.testing.expectEqualStrings(duplicate_trailer_section, bytes);
    try std.testing.expectEqual(@as(usize, 2), snapshot.fields_length);
    try std.testing.expectEqualStrings("X-One", snapshot.fields[0].name.slice(bytes));
    try std.testing.expectEqualStrings("first", snapshot.fields[0].value.slice(bytes));
    try std.testing.expectEqualStrings("X-One", snapshot.fields[1].name.slice(bytes));
    try std.testing.expectEqualStrings("second", snapshot.fields[1].value.slice(bytes));
}

fn testDeclarations() !request_trailers.StandardDeclarations {
    return request_trailers.StandardDeclarations.parse(
        &.{declaration_field},
        declaration_head,
    );
}

fn expectRejected(state: anytype, input: []const u8, status: Status) !void {
    var offset: usize = 0;
    while (offset < input.len) {
        const result = state.feed(input[offset..]);
        if (result.consumed > input.len - offset) return error.TestUnexpectedResult;
        offset += result.consumed;
        switch (result.event) {
            .rejected => {
                try std.testing.expectEqual(status, result.event.rejected.status);
                try std.testing.expect(result.event.rejected.close);
                const sticky = state.feed(input[offset..]);
                try std.testing.expectEqual(@as(usize, 0), sticky.consumed);
                try expectRejectedResult(sticky, status);
                return;
            },
            .need_more, .data => {},
            .ready => return error.TestUnexpectedResult,
        }
        if (result.consumed == 0) return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

fn expectRejectedResult(result: FeedResult, status: Status) !void {
    if (result.event != .rejected) return error.TestUnexpectedResult;
    try std.testing.expectEqual(status, result.event.rejected.status);
    try std.testing.expect(result.event.rejected.close);
}
