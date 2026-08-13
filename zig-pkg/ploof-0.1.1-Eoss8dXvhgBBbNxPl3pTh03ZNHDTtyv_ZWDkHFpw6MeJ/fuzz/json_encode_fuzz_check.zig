const std = @import("std");
const body = @import("../src/body.zig");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const json = @import("../src/json.zig");
const validate = @import("../src/internal/json/validate.zig");

test "JSON string encoder fuzz emits one strict document or invalid UTF-8" {
    try std.testing.fuzz({}, fuzzEncode, .{ .corpus = &fuzz_corpus });
}

const fuzz_corpus = struct {
    const empty = fuzz_support.smithInput("");
    const escapes = fuzz_support.smithInput("\"\\\x00\n</script>");
    const unicode = fuzz_support.smithInput("Ploof € 𝄞");
    const invalid = fuzz_support.smithInput("\xff\xc0\x80");
    const values = [_][]const u8{ &empty, &escapes, &unicode, &invalid };
}.values;

fn fuzzEncode(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [1024]u8 = undefined;
    const input = input_storage[0..smith.slice(&input_storage)];
    var output: [8 * 1024]u8 = undefined;
    const encoded = json.encode(.{ .value = input }, &output) catch |problem| {
        try std.testing.expect(!std.unicode.utf8ValidateSlice(input));
        try std.testing.expectEqual(error.InvalidUtf8, problem);
        return;
    };
    try std.testing.expect(std.unicode.utf8ValidateSlice(input));

    const chunks = [_]body.Chunk{body.Chunk.init(encoded)};
    const bytes = try body.Bytes.init(&chunks);
    var scratch: [32 * 1024]u8 align(validate.scratch_alignment) = undefined;
    _ = try validate.validate(bytes, &scratch, .{
        .hash_key = [_]u8{0x5a} ** 16,
        .depth_max = 64,
    });
}
