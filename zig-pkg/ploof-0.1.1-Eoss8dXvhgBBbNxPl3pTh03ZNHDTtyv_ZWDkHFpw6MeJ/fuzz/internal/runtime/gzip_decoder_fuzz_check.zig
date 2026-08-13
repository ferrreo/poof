const std = @import("std");
const gzip = @import("../../../src/internal/runtime/gzip/decoder.zig");
const fixture = @import("../../../tests/unit/internal/runtime/gzip_decoder_test.zig");

const output_max = 8192;
const raw_max = 1024;
const eight_empty = fixture.optional_gzip ++ fixture.optional_gzip ++
    fixture.optional_gzip ++ fixture.optional_gzip ++ fixture.optional_gzip ++
    fixture.optional_gzip ++ fixture.optional_gzip ++ fixture.optional_gzip;
const nine_empty = eight_empty ++ fixture.optional_gzip;

const stored_seed = smithSliceCorpus(&fixture.stored_gzip);
const fixed_seed = smithSliceCorpus(&fixture.fixed_gzip);
const dynamic_seed = smithSliceCorpus(&fixture.dynamic_gzip);
const optional_seed = smithSliceCorpus(&fixture.optional_gzip);
const concatenated_seed = smithSliceCorpus(&fixture.concatenated_gzip);
const bomb_seed = smithSliceCorpus(&fixture.bomb_gzip);
const eight_seed = smithSliceCorpus(&eight_empty);
const nine_seed = smithSliceCorpus(&nine_empty);

const corpus = [_][]const u8{
    &stored_seed,
    &fixed_seed,
    &dynamic_seed,
    &optional_seed,
    &concatenated_seed,
    &bomb_seed,
    &eight_seed,
    &nine_seed,
};

test "strict gzip framing differential and security fuzz" {
    try std.testing.fuzz({}, fuzzStrictGzip, .{ .corpus = &corpus });
}

fn fuzzStrictGzip(_: void, smith: *std.testing.Smith) !void {
    try fuzzRawInput(smith);
    try fuzzKnownValid(smith);
    try fuzzMemberBound(smith);
}

fn fuzzRawInput(smith: *std.testing.Smith) !void {
    var storage: [raw_max]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];
    const encoded_max = smith.valueRangeAtMost(u16, 0, raw_max);
    const decoded_max = smith.valueRangeAtMost(u16, 0, output_max);
    const output_length = smith.valueRangeAtMost(u16, 0, output_max);
    const decoder_choice = smith.valueRangeAtMost(u8, 0, 2);
    var first_output: [output_max]u8 = undefined;
    var second_output: [output_max]u8 = undefined;
    const first = decodeChoice(
        decoder_choice,
        input,
        first_output[0..output_length],
        encoded_max,
        decoded_max,
    );
    const second = decodeChoice(
        decoder_choice,
        input,
        second_output[0..output_length],
        encoded_max,
        decoded_max,
    );
    try expectSame(first, second);
    try checkBounds(first, input.len, encoded_max, decoded_max, output_length);

    const chunk_max = smith.valueRangeAtMost(u8, 1, 64);
    var byte_reader: fixture.FragmentReader = undefined;
    byte_reader.init(input, 1, null);
    var byte_output: [output_max]u8 = undefined;
    const byte_result = try decodeReaderChoice(
        decoder_choice,
        &byte_reader.interface,
        byte_output[0..output_length],
        encoded_max,
        decoded_max,
    );
    var chunk_reader: fixture.FragmentReader = undefined;
    chunk_reader.init(input, chunk_max, null);
    var chunk_output: [output_max]u8 = undefined;
    const chunk_result = try decodeReaderChoice(
        decoder_choice,
        &chunk_reader.interface,
        chunk_output[0..output_length],
        encoded_max,
        decoded_max,
    );
    try expectSame(byte_result, chunk_result);
    if (input.len <= encoded_max) try expectSame(first, chunk_result);
    if (first == .complete) try checkCompleteInput(input, first.complete);
}

fn fuzzKnownValid(smith: *std.testing.Smith) !void {
    var expected: [output_max]u8 = undefined;
    const known = knownCase(smith.valueRangeAtMost(u8, 0, 4), &expected);
    var output: [output_max]u8 = undefined;
    const complete = try requireComplete(gzip.Standard.decode(
        known.encoded,
        &output,
        known.encoded.len,
        known.decoded.len,
    ));
    try std.testing.expectEqualSlices(u8, known.decoded, complete.decoded);
    try std.testing.expectEqual(known.encoded.len, complete.encoded_consumed);
    try std.testing.expectEqual(@as(usize, 1), complete.member_count);
    try checkExactLimits(known.encoded, known.decoded.len);
    try compareStdGzip(known.encoded, known.decoded);
    try checkFragmentedAndFailed(smith, known.encoded, known.decoded);
    try checkValidMutation(smith, known.encoded);
}

fn fuzzMemberBound(smith: *std.testing.Smith) !void {
    const member_count = smith.valueRangeAtMost(u8, 1, 9);
    var encoded: [nine_empty.len]u8 = undefined;
    for (0..member_count) |index| {
        const start = index * fixture.optional_gzip.len;
        @memcpy(encoded[start..][0..fixture.optional_gzip.len], &fixture.optional_gzip);
    }
    const input = encoded[0 .. member_count * fixture.optional_gzip.len];
    var output: [1]u8 = undefined;
    const result = gzip.Standard.decode(input, &output, input.len, 0);
    if (member_count <= gzip.standard_members_max) {
        const complete = try requireComplete(result);
        try std.testing.expectEqual(@as(usize, member_count), complete.member_count);
    } else {
        try expectLimit(result, .members);
    }
    const selected_max = smith.valueRangeAtMost(u8, 1, 2);
    const selected = if (selected_max == 1)
        gzip.Decoder(1).decode(input, &output, input.len, 0)
    else
        gzip.Decoder(2).decode(input, &output, input.len, 0);
    if (member_count > selected_max) {
        try expectLimit(selected, .members);
    } else {
        _ = try requireComplete(selected);
    }
}

const Known = struct {
    encoded: []const u8,
    decoded: []const u8,
};

fn knownCase(choice: u8, output: *[output_max]u8) Known {
    return switch (choice) {
        0 => knownLiteral(&fixture.stored_gzip, "stored-block", output),
        1 => knownLiteral(
            &fixture.fixed_gzip,
            "fixed Huffman stream: zig zig zig zig",
            output,
        ),
        2 => dynamic: {
            var expected: [1000]u8 = undefined;
            fixture.dynamicPlain(&expected);
            @memcpy(output[0..expected.len], &expected);
            break :dynamic .{
                .encoded = &fixture.dynamic_gzip,
                .decoded = output[0..expected.len],
            };
        },
        3 => .{ .encoded = &fixture.optional_gzip, .decoded = output[0..0] },
        4 => bomb: {
            @memset(output, 'A');
            break :bomb .{ .encoded = &fixture.bomb_gzip, .decoded = output };
        },
        else => unreachable,
    };
}

fn knownLiteral(encoded: []const u8, decoded: []const u8, output: []u8) Known {
    @memcpy(output[0..decoded.len], decoded);
    return .{ .encoded = encoded, .decoded = output[0..decoded.len] };
}

fn checkExactLimits(input: []const u8, decoded_count: usize) !void {
    var output: [output_max]u8 = undefined;
    _ = try requireComplete(gzip.Standard.decode(
        input,
        output[0..decoded_count],
        input.len,
        decoded_count,
    ));
    try expectLimit(gzip.Standard.decode(input, &output, input.len - 1, output.len), .encoded);
    if (decoded_count == 0) return;
    try expectLimit(gzip.Standard.decode(
        input,
        &output,
        input.len,
        decoded_count - 1,
    ), .decoded);
    try expectLimit(gzip.Standard.decode(
        input,
        output[0 .. decoded_count - 1],
        input.len,
        decoded_count,
    ), .output);
}

fn checkFragmentedAndFailed(
    smith: *std.testing.Smith,
    input: []const u8,
    expected: []const u8,
) !void {
    const chunk_max = smith.valueRangeAtMost(u8, 1, 64);
    var fragmented: fixture.FragmentReader = undefined;
    fragmented.init(input, chunk_max, null);
    var output: [output_max]u8 = undefined;
    const complete = try requireComplete(try gzip.Standard.decodeReader(
        &fragmented.interface,
        output[0..expected.len],
        input.len,
        expected.len,
    ));
    try std.testing.expectEqualSlices(u8, expected, complete.decoded);

    const fail_at = smith.valueRangeAtMost(u16, 0, @intCast(input.len));
    var failed: fixture.FragmentReader = undefined;
    failed.init(input, chunk_max, fail_at);
    try std.testing.expectError(error.ReadFailed, gzip.Standard.decodeReader(
        &failed.interface,
        &output,
        input.len,
        output.len,
    ));
}

fn checkValidMutation(smith: *std.testing.Smith, input: []const u8) !void {
    var mutated: [raw_max]u8 = undefined;
    @memcpy(mutated[0..input.len], input);
    const index = smith.index(input.len);
    mutated[index] ^= smith.value(u8) | 1;
    const bytes = mutated[0..input.len];
    var direct_output: [output_max]u8 = undefined;
    const direct = gzip.Standard.decode(bytes, &direct_output, bytes.len, output_max);
    var byte_reader: fixture.FragmentReader = undefined;
    byte_reader.init(bytes, 1, null);
    var byte_output: [output_max]u8 = undefined;
    const byte_result = try gzip.Standard.decodeReader(
        &byte_reader.interface,
        &byte_output,
        bytes.len,
        output_max,
    );
    var chunk_reader: fixture.FragmentReader = undefined;
    chunk_reader.init(bytes, smith.valueRangeAtMost(u8, 1, 64), null);
    var chunk_output: [output_max]u8 = undefined;
    const chunk_result = try gzip.Standard.decodeReader(
        &chunk_reader.interface,
        &chunk_output,
        bytes.len,
        output_max,
    );
    try expectSame(byte_result, chunk_result);
    try expectSame(direct, chunk_result);
}

fn checkCompleteInput(input: []const u8, complete: gzip.Complete) !void {
    try std.testing.expectEqual(input.len, complete.encoded_consumed);
    try std.testing.expectEqual(complete.decoded.len, complete.decoded_count);
    try std.testing.expect(complete.member_count > 0);
    if (complete.member_count == 1) try compareStdGzip(input, complete.decoded);
}

fn checkBounds(
    result: gzip.Result,
    input_length: usize,
    encoded_max: usize,
    decoded_max: usize,
    output_length: usize,
) !void {
    if (input_length > encoded_max) return expectLimit(result, .encoded);
    switch (result) {
        .complete => |complete| {
            try std.testing.expectEqual(input_length, complete.encoded_consumed);
            try std.testing.expect(complete.decoded_count <= decoded_max);
            try std.testing.expect(complete.decoded_count <= output_length);
        },
        .malformed => {},
        .over_limit => |limit| try std.testing.expect(limit != .encoded),
    }
}

fn decodeChoice(
    choice: u8,
    input: []const u8,
    output: []u8,
    encoded_max: usize,
    decoded_max: usize,
) gzip.Result {
    return switch (choice) {
        0 => gzip.Decoder(1).decode(input, output, encoded_max, decoded_max),
        1 => gzip.Decoder(2).decode(input, output, encoded_max, decoded_max),
        2 => gzip.Standard.decode(input, output, encoded_max, decoded_max),
        else => unreachable,
    };
}

fn decodeReaderChoice(
    choice: u8,
    reader: *std.Io.Reader,
    output: []u8,
    encoded_max: usize,
    decoded_max: usize,
) gzip.DecodeError!gzip.Result {
    return switch (choice) {
        0 => gzip.Decoder(1).decodeReader(reader, output, encoded_max, decoded_max),
        1 => gzip.Decoder(2).decodeReader(reader, output, encoded_max, decoded_max),
        2 => gzip.Standard.decodeReader(reader, output, encoded_max, decoded_max),
        else => unreachable,
    };
}

fn expectSame(first: gzip.Result, second: gzip.Result) !void {
    switch (first) {
        .complete => |left| switch (second) {
            .complete => |right| {
                try std.testing.expectEqualSlices(u8, left.decoded, right.decoded);
                try std.testing.expectEqual(left.decoded_count, right.decoded_count);
                try std.testing.expectEqual(left.encoded_consumed, right.encoded_consumed);
                try std.testing.expectEqual(left.member_count, right.member_count);
            },
            else => return error.CompleteDifferentialMismatch,
        },
        .malformed => switch (second) {
            .malformed => {},
            else => return error.MalformedDifferentialMismatch,
        },
        .over_limit => |left| switch (second) {
            .over_limit => |right| try std.testing.expectEqual(left, right),
            else => return error.LimitDifferentialMismatch,
        },
    }
}

fn compareStdGzip(input: []const u8, expected: []const u8) !void {
    var reader = std.Io.Reader.fixed(input);
    var output: [output_max]u8 = undefined;
    var writer = std.Io.Writer.fixed(output[0..expected.len]);
    var decoder = std.compress.flate.Decompress.init(&reader, .gzip, &.{});
    const count = decoder.reader.streamRemaining(&writer) catch {
        return error.StdDifferentialMismatch;
    };
    try std.testing.expectEqual(expected.len, count);
    try std.testing.expectEqualSlices(u8, expected, output[0..writer.end]);
    try std.testing.expectEqual(input.len, reader.seek);
}

fn requireComplete(result: gzip.Result) !gzip.Complete {
    return switch (result) {
        .complete => |complete| complete,
        else => error.ExpectedComplete,
    };
}

fn expectLimit(result: gzip.Result, expected: gzip.Limit) !void {
    switch (result) {
        .over_limit => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.ExpectedLimit,
    }
}

fn smithSliceCorpus(comptime input: []const u8) [input.len + 4]u8 {
    var result: [input.len + 4]u8 = undefined;
    const length: u32 = input.len;
    result[0] = @truncate(length);
    result[1] = @truncate(length >> 8);
    result[2] = @truncate(length >> 16);
    result[3] = @truncate(length >> 24);
    @memcpy(result[4..], input);
    return result;
}
