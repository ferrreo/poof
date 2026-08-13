const std = @import("std");
const builtin = @import("builtin");
const gzip = @import("../../../../src/internal/runtime/gzip/decoder.zig");

const decoder_test_stack_size = if (builtin.sanitize_thread)
    std.Thread.SpawnConfig.default_stack_size
else
    128 * 1024;

pub const stored_gzip = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03, 0x01, 0x0c,
    0x00, 0xf3, 0xff, 0x73, 0x74, 0x6f, 0x72, 0x65, 0x64, 0x2d, 0x62, 0x6c,
    0x6f, 0x63, 0x6b, 0x4a, 0xb0, 0xba, 0x81, 0x0c, 0x00, 0x00, 0x00,
};

pub const fixed_gzip = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03, 0x4b, 0xcb,
    0xac, 0x48, 0x4d, 0x51, 0xf0, 0x28, 0x4d, 0x4b, 0xcb, 0x4d, 0xcc, 0x53,
    0x28, 0x2e, 0x29, 0x4a, 0x4d, 0xcc, 0xb5, 0x52, 0xa8, 0xca, 0x4c, 0x47,
    0xc6, 0x00, 0x41, 0xe0, 0x84, 0x2a, 0x25, 0x00, 0x00, 0x00,
};

pub const optional_gzip = [_]u8{
    0x1f, 0x8b, 0x08, 0x1f, 0x78, 0x56, 0x34, 0x12, 0x00, 0xff, 0x03,
    0x00, 0x78, 0x79, 0x7a, 0x6e, 0x61, 0x6d, 0x65, 0x2e, 0x74, 0x78,
    0x74, 0x00, 0x63, 0x6f, 0x6d, 0x6d, 0x65, 0x6e, 0x74, 0x00, 0x0a,
    0xe0, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

pub const dynamic_gzip = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x25, 0x93,
    0x87, 0x11, 0xc0, 0x30, 0x08, 0xc4, 0x56, 0xc2, 0xb8, 0xe1, 0xfd, 0x17,
    0x8b, 0x44, 0xce, 0x97, 0xe6, 0xf2, 0x7c, 0x21, 0x31, 0xd7, 0xcb, 0x1b,
    0x73, 0xdd, 0x1a, 0xe7, 0xd5, 0x5b, 0x37, 0xf8, 0xca, 0x51, 0x7b, 0xbd,
    0x33, 0xe3, 0xc5, 0xae, 0x99, 0x37, 0xf9, 0x5a, 0x73, 0x8d, 0xe8, 0xf7,
    0xc3, 0x08, 0xde, 0xd7, 0x3e, 0x23, 0xdf, 0x1a, 0xae, 0x1c, 0xd6, 0x6b,
    0x14, 0x28, 0xec, 0xda, 0x31, 0x63, 0x33, 0xb7, 0x63, 0x9f, 0x7b, 0x66,
    0x71, 0x8f, 0x71, 0x6e, 0x81, 0x0c, 0xe6, 0xcd, 0x57, 0x77, 0xf1, 0xa4,
    0x06, 0x28, 0xd4, 0xa0, 0xe6, 0x19, 0xcc, 0x73, 0xf6, 0x8c, 0x7a, 0x54,
    0xf9, 0xd1, 0x18, 0xb2, 0x89, 0x27, 0x12, 0x67, 0xa9, 0x9b, 0x13, 0x9c,
    0x99, 0xd3, 0xf5, 0xbc, 0x30, 0x9e, 0x20, 0xc3, 0x20, 0x9c, 0x61, 0xbe,
    0x2e, 0xd7, 0x58, 0x1b, 0xc6, 0xdb, 0x4a, 0xa9, 0xb2, 0x27, 0x6a, 0xb3,
    0xdf, 0xa9, 0x5a, 0x54, 0xb1, 0x0e, 0x0e, 0xf3, 0x8d, 0x9c, 0xe8, 0x3a,
    0xbb, 0x7e, 0x27, 0x76, 0x6b, 0xda, 0x7a, 0x90, 0xe8, 0x02, 0x4f, 0x2d,
    0xfa, 0xb4, 0x45, 0xc6, 0x91, 0xb7, 0x9e, 0x75, 0xf2, 0x32, 0xdf, 0xdc,
    0x61, 0xc5, 0xa9, 0x80, 0x87, 0x38, 0xa0, 0xa0, 0x58, 0xfd, 0x70, 0xf4,
    0x64, 0xeb, 0xcc, 0xe6, 0xb8, 0x50, 0xa9, 0x02, 0xaa, 0xa2, 0x53, 0xf6,
    0x60, 0xca, 0x50, 0x47, 0x5e, 0x23, 0x8d, 0xfc, 0x13, 0xc0, 0x2f, 0x2a,
    0xe1, 0xbf, 0x6b, 0x47, 0x1f, 0xfe, 0x73, 0x20, 0xc2, 0xaa, 0xd3, 0x31,
    0xa3, 0x1e, 0x8f, 0xa1, 0x97, 0x9b, 0x77, 0x5c, 0x69, 0xa5, 0xcc, 0x46,
    0x67, 0x03, 0x53, 0xf0, 0xd1, 0xd1, 0x9e, 0x2d, 0xd9, 0xc1, 0x84, 0x3b,
    0xa7, 0xc0, 0x68, 0x15, 0x32, 0xe5, 0xfc, 0xd4, 0x05, 0x39, 0xa1, 0xc3,
    0x7a, 0x03, 0x1c, 0x13, 0xa4, 0x32, 0x69, 0x77, 0x76, 0x71, 0xd7, 0x6b,
    0x67, 0xe1, 0x66, 0x36, 0xa5, 0x26, 0xf9, 0x5f, 0x79, 0x84, 0x77, 0x1d,
    0xc5, 0x39, 0x13, 0x67, 0xcf, 0x70, 0x2f, 0x7d, 0x03, 0x0f, 0x7b, 0xa5,
    0x3d, 0x94, 0xbb, 0x88, 0x28, 0xe8, 0x9a, 0xec, 0x6a, 0x97, 0xb7, 0x79,
    0x25, 0xba, 0x51, 0xda, 0x78, 0xb0, 0xe2, 0x2a, 0x33, 0xd6, 0x27, 0xee,
    0xf4, 0xdf, 0x6c, 0xbf, 0xe8, 0x3e, 0xfa, 0x63, 0xfc, 0x9d, 0x24, 0x0b,
    0xf2, 0x7f, 0xa2, 0xd3, 0x67, 0xcc, 0xa4, 0xdf, 0xbb, 0x3d, 0xbd, 0x7a,
    0x1f, 0x76, 0x80, 0x4c, 0x44, 0xf2, 0x0d, 0x74, 0x39, 0x97, 0x3d, 0x09,
    0xaa, 0x57, 0x63, 0x99, 0x44, 0x3b, 0x55, 0xdd, 0x27, 0x74, 0x6f, 0x27,
    0x66, 0x72, 0x61, 0x07, 0xa2, 0x9f, 0x3a, 0xf8, 0xa4, 0xcf, 0x32, 0xb2,
    0x2f, 0xe9, 0x44, 0x9f, 0xfd, 0x77, 0xa0, 0x01, 0x75, 0xc7, 0xd4, 0xc7,
    0x8f, 0xb7, 0xfe, 0x0c, 0xa7, 0xf5, 0xe8, 0x02, 0x3d, 0x63, 0xe8, 0x5a,
    0x99, 0x8f, 0x7e, 0xb6, 0xce, 0x63, 0xa7, 0x77, 0xb5, 0x76, 0xcc, 0xb4,
    0xd1, 0xda, 0xcf, 0xab, 0x9f, 0x21, 0x77, 0x13, 0xea, 0x7e, 0xb1, 0x33,
    0xd0, 0x29, 0xdb, 0xeb, 0xff, 0xd6, 0x7a, 0x41, 0x0f, 0x3b, 0xd8, 0xff,
    0xd6, 0x14, 0x74, 0x9f, 0x64, 0x3f, 0x08, 0x33, 0x14, 0xcb, 0xe8, 0x03,
    0x00, 0x00,
};

pub const bomb_gzip = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xed,
    0xc1, 0x01, 0x0d, 0x00, 0x00, 0x00, 0xc2, 0xa0, 0x6c, 0xef, 0x5f,
    0xca, 0x1c, 0x6e, 0x40, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0xef, 0x06, 0xcc, 0x3b, 0x25, 0x32, 0x00, 0x20, 0x00, 0x00,
};

pub const concatenated_gzip = stored_gzip ++ fixed_gzip;
const eight_empty = optional_gzip ++ optional_gzip ++ optional_gzip ++ optional_gzip ++
    optional_gzip ++ optional_gzip ++ optional_gzip ++ optional_gzip;

test "strict gzip decodes stored fixed and dynamic DEFLATE blocks" {
    var output: [2048]u8 = undefined;
    try expectComplete(&stored_gzip, "stored-block", &output);
    try expectComplete(&fixed_gzip, "fixed Huffman stream: zig zig zig zig", &output);
    var expected: [1000]u8 = undefined;
    dynamicPlain(&expected);
    try expectComplete(&dynamic_gzip, &expected, &output);
}

test "strict gzip accepts optional fields text flag and verified FHCRC" {
    var output: [1]u8 = undefined;
    const complete = try requireComplete(gzip.Standard.decode(
        &optional_gzip,
        &output,
        optional_gzip.len,
        0,
    ));
    try std.testing.expectEqual(@as(usize, 0), complete.decoded_count);
    try std.testing.expectEqual(@as(usize, 1), complete.member_count);
    try std.testing.expectEqual(optional_gzip.len, complete.encoded_consumed);
}

test "strict gzip skips FHCRC when optional fields do not request it" {
    var no_hcrc = optional_gzip[0..32].* ++ optional_gzip[34..].*;
    no_hcrc[3] &= ~@as(u8, 0x02);
    var output: [1]u8 = undefined;
    _ = try requireComplete(gzip.Standard.decode(&no_hcrc, &output, no_hcrc.len, 0));
}

test "strict gzip resets history and reports exact concatenated counts" {
    var output: [128]u8 = undefined;
    const expected = "stored-blockfixed Huffman stream: zig zig zig zig";
    const complete = try requireComplete(gzip.Standard.decode(
        &concatenated_gzip,
        &output,
        concatenated_gzip.len,
        expected.len,
    ));
    try std.testing.expectEqualStrings(expected, complete.decoded);
    try std.testing.expectEqual(expected.len, complete.decoded_count);
    try std.testing.expectEqual(concatenated_gzip.len, complete.encoded_consumed);
    try std.testing.expectEqual(@as(usize, 2), complete.member_count);
}

test "strict gzip rejects every truncated block and optional stream" {
    for (0..stored_gzip.len) |end| try expectMalformed(stored_gzip[0..end]);
    for (0..fixed_gzip.len) |end| try expectMalformed(fixed_gzip[0..end]);
    for (0..dynamic_gzip.len) |end| try expectMalformed(dynamic_gzip[0..end]);
    for (0..optional_gzip.len) |end| try expectMalformed(optional_gzip[0..end]);
}

test "strict gzip rejects bad framing integrity and trailing garbage" {
    var bad_magic = stored_gzip;
    bad_magic[0] = 0;
    try expectMalformed(&bad_magic);
    var bad_method = stored_gzip;
    bad_method[2] = 9;
    try expectMalformed(&bad_method);
    var reserved = stored_gzip;
    reserved[3] = 0x20;
    try expectMalformed(&reserved);
    var bad_deflate = stored_gzip;
    bad_deflate[10] = 0x07;
    try expectMalformed(&bad_deflate);
    var bad_crc = stored_gzip;
    bad_crc[bad_crc.len - 8] ^= 1;
    try expectMalformed(&bad_crc);
    var bad_size = stored_gzip;
    bad_size[bad_size.len - 4] ^= 1;
    try expectMalformed(&bad_size);
    const trailing = stored_gzip ++ [_]u8{0};
    try expectMalformed(&trailing);
}

test "strict gzip rejects corrupt and unterminated optional fields" {
    var bad_hcrc = optional_gzip;
    bad_hcrc[32] ^= 1;
    try expectMalformed(&bad_hcrc);
    var bad_extra = optional_gzip;
    bad_extra[10] = 0xff;
    bad_extra[11] = 0xff;
    try expectMalformed(&bad_extra);
    var no_name_terminator = optional_gzip;
    no_name_terminator[23] = 'x';
    no_name_terminator[31] = 'x';
    try expectMalformed(no_name_terminator[0..32]);
}

test "strict gzip enforces exact encoded decoded and output boundaries" {
    var output: [64]u8 = undefined;
    try expectLimit(
        gzip.Standard.decode(&stored_gzip, &output, stored_gzip.len - 1, output.len),
        .encoded,
    );
    _ = try requireComplete(gzip.Standard.decode(
        &stored_gzip,
        output[0.."stored-block".len],
        stored_gzip.len,
        "stored-block".len,
    ));
    try expectLimit(
        gzip.Standard.decode(&stored_gzip, &output, stored_gzip.len, "stored-block".len - 1),
        .decoded,
    );
    try expectLimit(gzip.Standard.decode(
        &stored_gzip,
        output[0 .. "stored-block".len - 1],
        stored_gzip.len,
        output.len,
    ), .output);
}

test "strict gzip enforces configurable concatenated member bound" {
    const nine = eight_empty ++ optional_gzip;
    var output: [1]u8 = undefined;
    const complete = try requireComplete(gzip.Standard.decode(
        &eight_empty,
        &output,
        eight_empty.len,
        0,
    ));
    try std.testing.expectEqual(gzip.standard_members_max, complete.member_count);
    try expectLimit(gzip.Standard.decode(&nine, &output, nine.len, 0), .members);
    const garbage = eight_empty ++ [_]u8{0};
    try expectMalformed(&garbage);
    var body_output: [128]u8 = undefined;
    try expectLimit(gzip.Decoder(1).decode(
        &concatenated_gzip,
        &body_output,
        concatenated_gzip.len,
        body_output.len,
    ), .members);
}

test "member cap reads only valid ninth fixed header before rejection" {
    const ninth_prefix = [_]u8{ 0x1f, 0x8b, 8, 0x08, 0, 0, 0, 0, 0, 0 };
    const input = eight_empty ++ ninth_prefix ++ ([_]u8{'x'} ** 128);
    var source: FragmentReader = undefined;
    source.init(&input, 1, null);
    var output: [1]u8 = undefined;
    try expectLimit(try gzip.Standard.decodeReader(
        &source.interface,
        &output,
        input.len,
        0,
    ), .members);
    try std.testing.expectEqual(eight_empty.len + ninth_prefix.len, source.position);
}

test "member cap still classifies invalid trailing fixed header as malformed" {
    const invalid_prefix = [_]u8{ 0, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0 };
    const input = eight_empty ++ invalid_prefix;
    try expectMalformed(&input);
}

test "strict gzip generic reader handles fragments limits and I/O failure" {
    var fragmented: FragmentReader = undefined;
    fragmented.init(&concatenated_gzip, 1, null);
    var output: [128]u8 = undefined;
    const complete = try requireComplete(try gzip.Standard.decodeReader(
        &fragmented.interface,
        &output,
        concatenated_gzip.len,
        output.len,
    ));
    try std.testing.expectEqual(concatenated_gzip.len, complete.encoded_consumed);
    try std.testing.expectEqual(@as(usize, 2), complete.member_count);
    var limited: FragmentReader = undefined;
    limited.init(&stored_gzip, 1, null);
    try expectLimit(try gzip.Standard.decodeReader(
        &limited.interface,
        &output,
        stored_gzip.len - 1,
        output.len,
    ), .encoded);
    for ([_]usize{ 0, 10, stored_gzip.len - 8, stored_gzip.len }) |fail_at| {
        var failed: FragmentReader = undefined;
        failed.init(&stored_gzip, 3, fail_at);
        try std.testing.expectError(error.ReadFailed, gzip.Standard.decodeReader(
            &failed.interface,
            &output,
            stored_gzip.len,
            output.len,
        ));
    }
}

test "generic reader requires exact encoded body boundary" {
    var exact_source = std.Io.Reader.fixed(&stored_gzip);
    var output: [64]u8 = undefined;
    _ = try requireComplete(try gzip.Standard.decodeReader(
        &exact_source,
        &output,
        stored_gzip.len,
        output.len,
    ));
    const pipelined = stored_gzip ++ "GET /next HTTP/1.1\r\n\r\n";
    var bounded = std.Io.Reader.fixed(pipelined);
    try expectLimit(try gzip.Standard.decodeReader(
        &bounded,
        &output,
        stored_gzip.len,
        output.len,
    ), .encoded);
    var unbounded = std.Io.Reader.fixed(pipelined);
    switch (try gzip.Standard.decodeReader(
        &unbounded,
        &output,
        pipelined.len,
        output.len,
    )) {
        .malformed => {},
        else => return error.TestUnexpectedResult,
    }
}

test "strict gzip rejects compact high-expansion body at decoded limit" {
    var output: [8192]u8 = undefined;
    try expectLimit(gzip.Standard.decode(
        &bomb_gzip,
        &output,
        bomb_gzip.len,
        output.len - 1,
    ), .decoded);
    const complete = try requireComplete(gzip.Standard.decode(
        &bomb_gzip,
        &output,
        bomb_gzip.len,
        output.len,
    ));
    try std.testing.expectEqual(output.len, complete.decoded_count);
    for (complete.decoded) |byte| try std.testing.expectEqual(@as(u8, 'A'), byte);
}

test "standard decoder fits configured 128 KiB decoder thread stack" {
    var harness = StackHarness{};
    const thread = try std.Thread.spawn(
        .{ .stack_size = decoder_test_stack_size },
        StackHarness.decode,
        .{&harness},
    );
    thread.join();
    try std.testing.expect(harness.succeeded);
}

const StackHarness = struct {
    succeeded: bool = false,

    fn decode(self: *StackHarness) void {
        var output: [8192]u8 = undefined;
        self.succeeded = switch (gzip.Standard.decode(
            &bomb_gzip,
            &output,
            bomb_gzip.len,
            output.len,
        )) {
            .complete => |complete| complete.decoded_count == output.len,
            else => false,
        };
    }
};

pub const FragmentReader = struct {
    input: []const u8,
    position: usize,
    chunk_max: usize,
    fail_at: ?usize,
    interface: std.Io.Reader,

    pub fn init(
        self: *FragmentReader,
        input: []const u8,
        chunk_max: usize,
        fail_at: ?usize,
    ) void {
        self.input = input;
        self.position = 0;
        self.chunk_max = chunk_max;
        self.fail_at = fail_at;
        self.interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        };
    }

    fn stream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *FragmentReader = @alignCast(@fieldParentPtr("interface", reader));
        if (self.fail_at == self.position) return error.ReadFailed;
        if (self.position == self.input.len) return error.EndOfStream;
        const failure_left = if (self.fail_at) |at| at - self.position else self.input.len;
        const count = @min(@min(self.chunk_max, failure_left), self.input.len - self.position);
        if (count == 0 or limit == .nothing) return 0;
        const bytes = limit.sliceConst(self.input[self.position..][0..count]);
        const written = try writer.write(bytes);
        self.position += written;
        return written;
    }
};

pub fn dynamicPlain(output: *[1000]u8) void {
    var state: u32 = 1;
    for (output) |*byte| {
        state = state *% 1_103_515_245 +% 12_345;
        byte.* = @intCast('0' + state % 10);
    }
}

fn expectComplete(input: []const u8, expected: []const u8, output: []u8) !void {
    const complete = try requireComplete(gzip.Standard.decode(
        input,
        output,
        input.len,
        output.len,
    ));
    try std.testing.expectEqualStrings(expected, complete.decoded);
    try std.testing.expectEqual(expected.len, complete.decoded_count);
    try std.testing.expectEqual(input.len, complete.encoded_consumed);
    try std.testing.expectEqual(@as(usize, 1), complete.member_count);
}

fn requireComplete(result: gzip.Result) !gzip.Complete {
    return switch (result) {
        .complete => |complete| complete,
        .malformed => error.TestUnexpectedResult,
        .over_limit => error.TestUnexpectedResult,
    };
}

fn expectMalformed(input: []const u8) !void {
    var output: [8192]u8 = undefined;
    switch (gzip.Standard.decode(input, &output, input.len, output.len)) {
        .malformed => {},
        .complete => return error.TestUnexpectedResult,
        .over_limit => return error.TestUnexpectedResult,
    }
}

fn expectLimit(result: gzip.Result, expected: gzip.Limit) !void {
    switch (result) {
        .over_limit => |actual| try std.testing.expectEqual(expected, actual),
        .complete => return error.TestUnexpectedResult,
        .malformed => return error.TestUnexpectedResult,
    }
}
