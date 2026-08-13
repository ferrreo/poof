const std = @import("std");
const chunked_body = @import("../src/internal/runtime/connection/chunked_body.zig");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const request_head = @import("../src/internal/http1/request_head.zig");
const request_trailers = @import("../src/internal/http1/request_trailers.zig");
const State = chunked_body.State;

const declaration_head = "TrailerX-One";
const declaration_field = request_head.Field{
    .name = .{ .offset = 0, .length = "Trailer".len },
    .raw_value = .{ .offset = "Trailer".len, .length = "X-One".len },
    .value = .{ .offset = "Trailer".len, .length = "X-One".len },
};
const zero_span = request_head.Span{ .offset = 0, .length = 0 };
const zero_field = request_head.Field{
    .name = zero_span,
    .raw_value = zero_span,
    .value = zero_span,
};
const FuzzTerminal = enum(u8) { need_more, ready, rejected };

const FuzzSnapshot = struct {
    consumed: usize,
    wire_bytes: u64,
    decoded_bytes: u64,
    rejection_code: u16,
    terminal: FuzzTerminal,
    body: [256]u8,
    body_length: usize,
    trailer_bytes: [256]u8,
    trailer_length: usize,
    trailer_fields: [request_trailers.standard_limits.fields_max]request_head.Field,
    trailer_fields_length: usize,
};

test "chunked identity orchestration fragmentation differential fuzz" {
    try std.testing.fuzz({}, fuzzChunkedIdentity, .{
        .corpus = &chunked_identity_fuzz_corpus,
    });
}

test "tight encoded budgets reject at the same prefix for every split" {
    try expectEverySplit("1\r\na\r\n0\r\n\r\n", 10, 1, false, 3, 0);
    try expectEverySplit("0\r\nX-One: value\r\n\r\n", 7, 0, true, 4, 0);
}

const fuzz_valid_empty = "0\r\n\r\n";
const fuzz_valid_data = "4\r\nWiki\r\n0\r\n\r\n";
const fuzz_valid_trailer = "2\r\nhi\r\n0\r\nX-One:\t value \t\r\n\r\n";

const chunked_identity_fuzz_corpus = struct {
    const empty = fuzzCase(fuzz_valid_empty ++ "NEXT", "\x00", 5, 0, false);
    const data = fuzzCase(fuzz_valid_data ++ "NEXT", "\x01\x03", 14, 4, false);
    const decoded = fuzzCase(fuzz_valid_data, "\x00\x02", 14, 3, false);
    const trailer = fuzzCase(fuzz_valid_trailer ++ "NEXT", "\x00\x04\x01", 34, 2, true);
    const malformed = fuzzCase("z\r\n", "\x00", 64, 64, false);
    const tight_data = fuzzCase(fuzz_valid_data, "\x02\xff", 10, 4, false);
    const tight_trailer = fuzzCase(fuzz_valid_trailer, "\x03\xff", 7, 2, true);

    const values = [_][]const u8{
        &empty,
        &data,
        &decoded,
        &trailer,
        &malformed,
        &tight_data,
        &tight_trailer,
    };
}.values;

fn expectEverySplit(
    input: []const u8,
    wire_max: u64,
    decoded_max: u64,
    declared: bool,
    expected_consumed: usize,
    expected_body: usize,
) !void {
    const declarations: request_trailers.StandardDeclarations =
        if (declared) try testDeclarations() else .{};
    var contiguous = State.init(wire_max, decoded_max, declarations, declaration_head);
    const expected = try driveFuzz(&contiguous, input, null);
    try std.testing.expectEqual(FuzzTerminal.rejected, expected.terminal);
    try std.testing.expectEqual(expected_consumed, expected.consumed);
    try std.testing.expectEqual(expected_body, expected.body_length);

    var split: usize = 1;
    while (split < input.len) : (split += 1) {
        const plan = [_]u8{ @intCast(split - 1), std.math.maxInt(u8) };
        var fragmented = State.init(wire_max, decoded_max, declarations, declaration_head);
        const actual = try driveFuzz(&fragmented, input, &plan);
        try std.testing.expectEqualDeep(expected, actual);
    }
}

fn fuzzCase(
    comptime input: []const u8,
    comptime fragments: []const u8,
    comptime wire_max: u64,
    comptime decoded_max: u64,
    comptime declared: bool,
) [input.len + fragments.len + 32]u8 {
    const encoded_input = fuzz_support.smithInput(input);
    const encoded_fragments = fuzz_support.smithInput(fragments);
    var result: [input.len + fragments.len + 32]u8 = undefined;
    @memcpy(result[0..encoded_input.len], &encoded_input);
    @memcpy(result[encoded_input.len..][0..encoded_fragments.len], &encoded_fragments);
    const start = encoded_input.len + encoded_fragments.len;
    const values = [_]u64{ wire_max, decoded_max, @intFromBool(declared) };
    inline for (values, 0..) |value, index| {
        std.mem.writeInt(u64, result[start + index * 8 ..][0..8], value, .little);
    }
    return result;
}

fn fuzzChunkedIdentity(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [256]u8 = undefined;
    const input = input_storage[0..smith.slice(&input_storage)];
    var fragment_storage: [64]u8 = undefined;
    const fragments = fragment_storage[0..smith.slice(&fragment_storage)];
    const wire_max = smith.valueRangeAtMost(u16, 0, 300);
    const decoded_max = smith.valueRangeAtMost(u16, 0, input_storage.len);
    const declarations: request_trailers.StandardDeclarations =
        if (smith.value(bool)) try testDeclarations() else .{};

    var contiguous = State.init(wire_max, decoded_max, declarations, declaration_head);
    const contiguous_snapshot = try driveFuzz(&contiguous, input, null);
    var fragmented = State.init(wire_max, decoded_max, declarations, declaration_head);
    const fragmented_snapshot = try driveFuzz(&fragmented, input, fragments);
    try std.testing.expectEqualDeep(contiguous_snapshot, fragmented_snapshot);
}

fn driveFuzz(state: *State, input: []const u8, fragments: ?[]const u8) !FuzzSnapshot {
    var body: [256]u8 = @splat(0);
    var body_length: usize = 0;
    var offset: usize = 0;
    var step: usize = 0;
    while (offset < input.len) {
        const end = if (fragments) |plan|
            fuzzFragmentEnd(offset, input.len, plan, step)
        else
            input.len;
        const result = state.feed(input[offset..end]);
        if (result.consumed > end - offset) return error.TestUnexpectedResult;
        offset += result.consumed;
        step += 1;
        switch (result.event) {
            .need_more => if (offset != end) return error.TestUnexpectedResult,
            .data => |data| try appendFuzzBody(&body, &body_length, data),
            .ready => return fuzzTerminalSnapshot(
                state,
                input[offset..],
                &body,
                body_length,
                offset,
                .ready,
                0,
            ),
            .rejected => |rejection| return fuzzTerminalSnapshot(
                state,
                input[offset..],
                &body,
                body_length,
                offset,
                .rejected,
                @intFromEnum(rejection.status),
            ),
        }
        if (result.consumed == 0) return error.TestUnexpectedResult;
    }
    return try fuzzSnapshot(state, &body, body_length, offset, .need_more, 0);
}

fn fuzzFragmentEnd(offset: usize, input_len: usize, plan: []const u8, step: usize) usize {
    const width = if (plan.len == 0) 1 else @as(usize, plan[step % plan.len]) + 1;
    return offset + @min(width, input_len - offset);
}

fn appendFuzzBody(body: *[256]u8, length: *usize, data: []const u8) !void {
    if (data.len > body.len - length.*) return error.TestUnexpectedResult;
    @memcpy(body[length.*..][0..data.len], data);
    length.* += data.len;
}

fn fuzzTerminalSnapshot(
    state: *State,
    remainder: []const u8,
    body: *const [256]u8,
    body_length: usize,
    consumed: usize,
    terminal: FuzzTerminal,
    rejection_code: u16,
) !FuzzSnapshot {
    const sticky = state.feed(remainder);
    if (sticky.consumed != 0) return error.TestUnexpectedResult;
    switch (sticky.event) {
        .ready => if (terminal != .ready) return error.TestUnexpectedResult,
        .rejected => |rejection| {
            if (terminal != .rejected) return error.TestUnexpectedResult;
            if (@intFromEnum(rejection.status) != rejection_code) {
                return error.TestUnexpectedResult;
            }
        },
        .need_more, .data => return error.TestUnexpectedResult,
    }
    return fuzzSnapshot(
        state,
        body,
        body_length,
        consumed,
        terminal,
        rejection_code,
    );
}

fn fuzzSnapshot(
    state: *const State,
    body: *const [256]u8,
    body_length: usize,
    consumed: usize,
    terminal: FuzzTerminal,
    rejection_code: u16,
) !FuzzSnapshot {
    if (state.wireBytesConsumed() != consumed) return error.TestUnexpectedResult;
    if (state.wireBytesConsumed() > state.encoded_wire_bytes_max) {
        return error.TestUnexpectedResult;
    }
    if (state.decodedBytesProduced() != body_length) return error.TestUnexpectedResult;
    if (state.decodedBytesProduced() > state.decoded_bytes_max) {
        return error.TestUnexpectedResult;
    }
    const ready_trailers = state.trailers();
    if ((terminal == .ready) != (ready_trailers != null)) {
        return error.TestUnexpectedResult;
    }
    var trailer_bytes: [256]u8 = @splat(0);
    var trailer_length: usize = 0;
    var trailer_fields: [request_trailers.standard_limits.fields_max]request_head.Field =
        @splat(zero_field);
    var trailer_fields_length: usize = 0;
    if (ready_trailers) |trailers| {
        if (trailers.bytes.len > trailer_bytes.len) return error.TestUnexpectedResult;
        if (trailers.fields.len > trailer_fields.len) return error.TestUnexpectedResult;
        trailer_length = trailers.bytes.len;
        trailer_fields_length = trailers.fields.len;
        @memcpy(trailer_bytes[0..trailer_length], trailers.bytes);
        @memcpy(trailer_fields[0..trailer_fields_length], trailers.fields);
        for (trailers.fields) |field| {
            try validateFuzzSpan(field.name, trailers.bytes);
            try validateFuzzSpan(field.raw_value, trailers.bytes);
            try validateFuzzSpan(field.value, trailers.bytes);
        }
    }
    return .{
        .consumed = consumed,
        .wire_bytes = state.wireBytesConsumed(),
        .decoded_bytes = state.decodedBytesProduced(),
        .rejection_code = rejection_code,
        .terminal = terminal,
        .body = body.*,
        .body_length = body_length,
        .trailer_bytes = trailer_bytes,
        .trailer_length = trailer_length,
        .trailer_fields = trailer_fields,
        .trailer_fields_length = trailer_fields_length,
    };
}

fn validateFuzzSpan(span: request_head.Span, bytes: []const u8) !void {
    const offset: usize = span.offset;
    const length: usize = span.length;
    if (offset > bytes.len) return error.TestUnexpectedResult;
    if (length > bytes.len - offset) return error.TestUnexpectedResult;
}

fn testDeclarations() !request_trailers.StandardDeclarations {
    return request_trailers.StandardDeclarations.parse(
        &.{declaration_field},
        declaration_head,
    );
}
