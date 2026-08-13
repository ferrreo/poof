const std = @import("std");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const gzip_encoder = @import("../src/internal/runtime/gzip/encoder.zig");

const input_bytes_max: usize = 4096;
const output_bytes_max: usize = 4630;

test "finite gzip encoder bound and roundtrip fuzz" {
    try std.testing.fuzz({}, fuzzEncoder, .{ .corpus = &corpus });
}

fn fuzzEncoder(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [input_bytes_max]u8 = undefined;
    const input = input_storage[0..smith.slice(&input_storage)];
    const level: gzip_encoder.Level = switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => .fastest,
        1 => .default,
        2 => .best,
        else => unreachable,
    };
    const required = try gzip_encoder.bound(input.len);
    try std.testing.expect(required <= output_bytes_max);

    var workspace: gzip_encoder.Workspace = undefined;
    var output: [output_bytes_max + 1]u8 = @splat(0xa5);
    const encoded = switch (level) {
        .fastest => try gzip_encoder.compress(
            &workspace,
            input,
            output[0..required],
            .fastest,
        ),
        .default => try gzip_encoder.compress(
            &workspace,
            input,
            output[0..required],
            .default,
        ),
        .best => try gzip_encoder.compress(
            &workspace,
            input,
            output[0..required],
            .best,
        ),
    };
    try std.testing.expect(encoded.len <= required);
    try std.testing.expectEqual(@as(u8, 0xa5), output[required]);

    var reader = std.Io.Reader.fixed(encoded);
    var decoder = std.compress.flate.Decompress.init(&reader, .gzip, &.{});
    var decoded: [input_bytes_max]u8 = undefined;
    var writer = std.Io.Writer.fixed(decoded[0..input.len]);
    const written = try decoder.reader.streamRemaining(&writer);
    try std.testing.expectEqual(input.len, written);
    try std.testing.expectEqualSlices(u8, input, decoded[0..written]);
}

const empty = fuzz_support.smithInput("");
const tiny = fuzz_support.smithInput("abc");
const repeated = fuzz_support.smithInput("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
const mixed = fuzz_support.smithInput("gzip\x00\xff\x7f\x80boundary");
const corpus = [_][]const u8{ &empty, &tiny, &repeated, &mixed };
