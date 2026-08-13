const std = @import("std");

const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const multipart = @import("../src/multipart.zig");

const fuzz_bytes_max = 4096;
const standard_key_bytes_max = 64;
const hard_key_bytes_max = multipart.storage_key_bytes_hard_max;

test "multipart StorageKey fuzz is canonical deterministic and bounded" {
    try std.testing.fuzz({}, fuzzStorageKey, .{ .corpus = &storage_key_corpus });
}

const storage_key_corpus = struct {
    const empty = fuzz_support.smithInput("");
    const plain = fuzz_support.smithInput("file.bin");
    const nested = fuzz_support.smithInput("tenant/2026/file.bin");
    const leading = fuzz_support.smithInput("/etc/passwd");
    const empty_component = fuzz_support.smithInput("a//b");
    const trailing = fuzz_support.smithInput("a/");
    const dot = fuzz_support.smithInput(".");
    const dot_dot = fuzz_support.smithInput("a/../b");
    const nul = fuzz_support.smithInput("a\x00b");
    const c0_upper = fuzz_support.smithInput("a\x1fb");
    const c0_after = fuzz_support.smithInput("a b");
    const delete_before = fuzz_support.smithInput("a~b");
    const delete = fuzz_support.smithInput("a\x7fb");
    const c1_lower = fuzz_support.smithInput("a\xc2\x80b");
    const c1_upper = fuzz_support.smithInput("a\xc2\x9fb");
    const c1_after = fuzz_support.smithInput("a\xc2\xa0b");
    const malformed = fuzz_support.smithInput("a\xc0\xafb");
    const surrogate = fuzz_support.smithInput("a\xed\xa0\x80b");
    const unicode = fuzz_support.smithInput("tenant/\xe2\x82\xac.bin");
    const well_known = fuzz_support.smithInput(".well-known/upload");
    const standard_below = fuzz_support.smithInput("a" ** (standard_key_bytes_max - 1));
    const standard_exact = fuzz_support.smithInput("a" ** standard_key_bytes_max);
    const standard_over = fuzz_support.smithInput("a" ** (standard_key_bytes_max + 1));
    const hard_below = fuzz_support.smithInput("a" ** (hard_key_bytes_max - 1));
    const hard_exact = fuzz_support.smithInput("a" ** hard_key_bytes_max);
    const hard_over = fuzz_support.smithInput("a" ** (hard_key_bytes_max + 1));

    const values = [_][]const u8{
        &empty,
        &plain,
        &nested,
        &leading,
        &empty_component,
        &trailing,
        &dot,
        &dot_dot,
        &nul,
        &c0_upper,
        &c0_after,
        &delete_before,
        &delete,
        &c1_lower,
        &c1_upper,
        &c1_after,
        &malformed,
        &surrogate,
        &unicode,
        &well_known,
        &standard_below,
        &standard_exact,
        &standard_over,
        &hard_below,
        &hard_exact,
        &hard_over,
    };
}.values;

fn fuzzStorageKey(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [fuzz_bytes_max]u8 = undefined;
    const input = input_storage[0..smith.slice(&input_storage)];
    var original: [fuzz_bytes_max]u8 = undefined;
    @memcpy(original[0..input.len], input);

    try checkKey(standard_key_bytes_max, input, smith);
    if (input.len >= hard_key_bytes_max - 1 or smith.value(u8) & 0x0f == 0) {
        try checkKey(hard_key_bytes_max, input, smith);
    }
    try std.testing.expectEqualSlices(u8, original[0..input.len], input);
}

fn checkKey(
    comptime maximum: usize,
    input: []const u8,
    smith: *std.testing.Smith,
) !void {
    const Key = multipart.StorageKey(maximum);
    const expected = expectedError(input, maximum);
    var first_error: ?multipart.StorageKeyError = null;
    var second_error: ?multipart.StorageKeyError = null;
    const first: ?Key = Key.init(input) catch |problem| failed: {
        first_error = problem;
        break :failed null;
    };
    const second: ?Key = Key.init(input) catch |problem| failed: {
        second_error = problem;
        break :failed null;
    };

    try std.testing.expectEqual(expected, first_error);
    try std.testing.expectEqual(first_error, second_error);
    if (first) |key| {
        const repeated = second orelse return error.FuzzOutcomeMismatch;
        try expectCanonical(maximum, input, key);
        try expectCanonical(maximum, input, repeated);
        try checkPublicMutation(maximum, key, smith);
    } else try std.testing.expect(second == null);
}

fn expectCanonical(
    comptime maximum: usize,
    input: []const u8,
    key: multipart.StorageKey(maximum),
) !void {
    try std.testing.expect(input.len > 0);
    try std.testing.expect(input.len <= maximum);
    try std.testing.expectEqualSlices(u8, input, key.bytes());
    try std.testing.expectEqualSlices(u8, input, key.sentinel());
    try std.testing.expectEqual(@as(u8, 0), key.sentinel()[input.len]);
    const slash = std.mem.lastIndexOfScalar(u8, input, '/');
    if (slash) |index| {
        try std.testing.expectEqualSlices(u8, input[0..index], key.parent().?);
        try std.testing.expectEqualSlices(u8, input[index + 1 ..], key.basename());
    } else {
        try std.testing.expect(key.parent() == null);
        try std.testing.expectEqualSlices(u8, input, key.basename());
    }
}

fn checkPublicMutation(
    comptime maximum: usize,
    canonical: multipart.StorageKey(maximum),
    smith: *std.testing.Smith,
) !void {
    var sentinel_corrupt = canonical;
    sentinel_corrupt.storage[canonical.bytes().len] = 0xa5;
    const restored = try sentinel_corrupt.validatedCopy();
    try expectCanonical(maximum, canonical.bytes(), restored);

    var content_corrupt = canonical;
    const index: usize = smith.valueRangeAtMost(
        u16,
        0,
        @intCast(content_corrupt.bytes().len - 1),
    );
    content_corrupt.storage[index] ^= smith.value(u8) | 1;
    try expectValidatedPublicValue(maximum, &content_corrupt);

    const Length = @FieldType(multipart.StorageKey(maximum), "length");
    if (comptime std.math.maxInt(Length) > maximum) {
        var length_corrupt = canonical;
        length_corrupt.length = @intCast(maximum + 1);
        try std.testing.expectError(error.TooLong, length_corrupt.validatedCopy());
    }
}

fn expectValidatedPublicValue(
    comptime maximum: usize,
    public: *const multipart.StorageKey(maximum),
) !void {
    const length: usize = @intCast(public.length);
    if (length > maximum) {
        try std.testing.expectError(error.TooLong, public.validatedCopy());
        return;
    }
    const bytes = public.storage[0..length];
    if (expectedError(bytes, maximum)) |problem| {
        try std.testing.expectError(problem, public.validatedCopy());
        return;
    }
    const restored = try public.validatedCopy();
    try expectCanonical(maximum, bytes, restored);
}

fn expectedError(
    input: []const u8,
    maximum: usize,
) ?multipart.StorageKeyError {
    if (input.len == 0) return error.Empty;
    if (input.len > maximum) return error.TooLong;
    if (input[0] == '/') return error.AbsolutePath;
    const view = std.unicode.Utf8View.init(input) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0x1f or (codepoint >= 0x7f and codepoint <= 0x9f)) {
            return error.ControlCharacter;
        }
    }
    var components = std.mem.splitScalar(u8, input, '/');
    while (components.next()) |component| {
        if (component.len == 0) return error.EmptyComponent;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.DotComponent;
        }
    }
    return null;
}

test "FileSink rejects corrupted StorageKey before issuing I/O" {
    const Sink = multipart.FileSink(.{
        .root = "root",
        .storage_key_bytes_max = standard_key_bytes_max,
        .durability = .buffered,
    });
    var runtime: Sink.Runtime = undefined;
    var state = Sink.initial_state;
    var input = try Sink.Key.init("ok");
    input.storage[0] = '/';
    try std.testing.expectError(
        error.AbsolutePath,
        Sink.begin(&runtime, &state, .{ .start = input }),
    );
    try std.testing.expect(!state.key_valid);
    try std.testing.expect(!state.parent_owned);
    try std.testing.expect(!state.named_stage_live);
    try std.testing.expect(!state.published);
}
