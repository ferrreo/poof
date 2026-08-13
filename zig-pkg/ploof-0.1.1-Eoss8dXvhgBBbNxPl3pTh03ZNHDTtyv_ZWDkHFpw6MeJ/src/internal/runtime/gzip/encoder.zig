const std = @import("std");
const flate = std.compress.flate;

// Zig 0.16 Compress.init returns roughly 224 KiB by value. Debug materializes
// nested return temporaries that overflow the bounded runtime worker stack.
// Capture only its immutable vtable at comptime; begin reproduces the rest of
// that exact pinned-version state directly in caller-owned workspace.
const compressor_vtable = init: {
    var output_buffer: [16]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var history: [flate.max_window_len]u8 = undefined;
    const compressor = flate.Compress.init(
        &output,
        &history,
        .gzip,
        .fastest,
    ) catch unreachable;
    break :init compressor.writer.vtable;
};

pub const Error = error{
    CompressionFailed,
    LengthOverflow,
    OutputTooSmall,
};

pub const Level = enum(u8) {
    fastest,
    default,
    best,
};

pub const Workspace = struct {
    compressor: flate.Compress = undefined,
    history: [flate.max_window_len]u8 = undefined,
};

/// Worst-case gzip bytes emitted by Zig 0.16's finite compressor without flushes.
pub fn bound(input_length: usize) error{LengthOverflow}!usize {
    const blocks = if (input_length == 0)
        1
    else
        (input_length - 1) / 32_768 + 1;
    const input_bits = std.math.mul(usize, input_length, 9) catch {
        return error.LengthOverflow;
    };
    const block_bits = std.math.mul(usize, blocks, 10) catch {
        return error.LengthOverflow;
    };
    const bits = std.math.add(usize, input_bits, block_bits) catch {
        return error.LengthOverflow;
    };
    const rounded_bits = std.math.add(usize, bits, 7) catch {
        return error.LengthOverflow;
    };
    const deflate_bytes = rounded_bits / 8;
    return std.math.add(usize, deflate_bytes, 18) catch error.LengthOverflow;
}

pub fn compress(
    workspace: *Workspace,
    input: []const u8,
    output: []u8,
    comptime level: Level,
) Error![]u8 {
    const required = try bound(input.len);
    if (output.len < required) return error.OutputTooSmall;

    var writer = std.Io.Writer.fixed(output);
    begin(workspace, &writer, level) catch {
        return error.CompressionFailed;
    };
    workspace.compressor.writer.writeAll(input) catch {
        return error.CompressionFailed;
    };
    workspace.compressor.finish() catch return error.CompressionFailed;
    return output[0..writer.end];
}

pub fn begin(
    workspace: *Workspace,
    output: *std.Io.Writer,
    level: Level,
) std.Io.Writer.Error!void {
    try output.writeAll(flate.Container.gzip.header());
    const compressor = &workspace.compressor;
    compressor.writer = .{
        .buffer = &workspace.history,
        .vtable = compressor_vtable,
    };
    compressor.history_len = 0;
    compressor.history_end_unhashed = false;
    compressor.bit_writer.output = output;
    compressor.bit_writer.buffered = 0;
    compressor.bit_writer.buffered_n = 0;
    compressor.buffered_tokens.pos = 0;
    compressor.buffered_tokens.n = 0;
    @memset(&compressor.buffered_tokens.lit_freqs, 0);
    @memset(&compressor.buffered_tokens.dist_freqs, 0);
    @memset(std.mem.asBytes(&compressor.lookup.head), 0xff);
    compressor.lookup.chain_pos = std.math.maxInt(u15);
    compressor.container = .gzip;
    compressor.hasher = .init(.gzip);
    compressor.opts = options(level);
}

fn options(level: Level) flate.Compress.Options {
    return switch (level) {
        .fastest => .fastest,
        .default => .default,
        .best => .best,
    };
}

test "gzip bound rejects arithmetic overflow" {
    try std.testing.expectError(error.LengthOverflow, bound(std.math.maxInt(usize)));
}

test "gzip encoder reserves the proven bound and round trips every level" {
    var input: [65_537]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @truncate(index *% 131 +% index / 7);
    var output: [73_766]u8 = undefined;
    var decoded: [input.len]u8 = undefined;
    var workspace: Workspace = undefined;

    inline for ([_]Level{ .fastest, .default, .best }) |level| {
        std.crypto.secureZero(u8, std.mem.asBytes(&workspace));
        const encoded = try compress(&workspace, &input, &output, level);
        try expectRoundTrip(encoded, &input, &decoded);
    }
}

test "gzip encoder handles empty tiny and block-boundary inputs" {
    var input: [65_536]u8 = @splat('a');
    var output: [73_765]u8 = undefined;
    var decoded: [input.len]u8 = undefined;
    var workspace: Workspace = undefined;
    const lengths = [_]usize{ 0, 1, 2, 3, 32_767, 32_768, 32_769, input.len };

    for (lengths) |length| {
        const required = try bound(length);
        try std.testing.expectError(
            error.OutputTooSmall,
            compress(&workspace, input[0..length], output[0 .. required - 1], .fastest),
        );
        const encoded = try compress(
            &workspace,
            input[0..length],
            output[0..required],
            .fastest,
        );
        try expectRoundTrip(encoded, input[0..length], decoded[0..length]);
    }
}

test "in-place initialization is byte-identical to Zig 0.16 compressor" {
    var input: [4097]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @truncate(index *% 17 +% index / 11);
    var actual_output: [4630]u8 = undefined;
    var expected_output: [actual_output.len]u8 = undefined;
    var workspace: Workspace = undefined;

    inline for ([_]Level{ .fastest, .default, .best }) |level| {
        std.crypto.secureZero(u8, std.mem.asBytes(&workspace));
        const actual = try compress(&workspace, &input, &actual_output, level);
        const expected = try compressStandard(&input, &expected_output, level);
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
}

fn compressStandard(input: []const u8, output: []u8, comptime level: Level) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    var history: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(&writer, &history, .gzip, options(level));
    try compressor.writer.writeAll(input);
    try compressor.finish();
    return output[0..writer.end];
}

fn expectRoundTrip(encoded: []const u8, expected: []const u8, output: []u8) !void {
    var input_reader = std.Io.Reader.fixed(encoded);
    var decoder = std.compress.flate.Decompress.init(&input_reader, .gzip, &.{});
    var writer = std.Io.Writer.fixed(output);
    const written = try decoder.reader.streamRemaining(&writer);
    try std.testing.expectEqual(expected.len, written);
    try std.testing.expectEqualStrings(expected, output[0..written]);
}
