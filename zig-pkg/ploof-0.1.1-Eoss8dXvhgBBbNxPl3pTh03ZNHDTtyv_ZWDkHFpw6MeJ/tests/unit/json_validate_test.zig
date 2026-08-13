const std = @import("std");
const body = @import("../../src/body.zig");
const fuzz_support = @import("../../src/internal/http1/testing/smith.zig");
const token_source = @import("../../src/internal/json/token_source.zig");
const validate_json = @import("../../src/internal/json/validate.zig");

const hash_key = "ploof-json-test!".*;
const scratch_bytes_max: usize = 64 * 1024;

fn options(depth_max: u16) validate_json.Options {
    return .{ .depth_max = depth_max, .hash_key = hash_key };
}

fn input(chunks: []const body.Chunk) !body.Bytes {
    return body.Bytes.init(chunks);
}

fn validate(
    value: body.Bytes,
    scratch: []align(validate_json.scratch_alignment) u8,
    depth_max: u16,
) validate_json.Error!validate_json.Result {
    return validate_json.validate(value, scratch, options(depth_max));
}

test "strict JSON accepts every split boundary and byte-sized fragmentation" {
    const document =
        \\{"plain":"€","escaped":"a\\u20ac","pair":"\\uD834\\uDD1E",
        \\ "number":-12.30e+4,"array":[true,false,null,{}]}
    ;
    var scratch: [scratch_bytes_max]u8 align(validate_json.scratch_alignment) = undefined;
    var split_chunks: [2]body.Chunk = undefined;
    var split: usize = 0;
    while (split <= document.len) : (split += 1) {
        split_chunks = .{
            body.Chunk.init(document[0..split]),
            body.Chunk.init(document[split..]),
        };
        const result = try validate(try input(&split_chunks), &scratch, 64);
        try expectDocumentCounts(result);
    }

    var byte_chunks: [document.len]body.Chunk = undefined;
    for (&byte_chunks, 0..) |*chunk, index| {
        chunk.* = body.Chunk.init(document[index .. index + 1]);
    }
    const fragmented = try validate(try input(&byte_chunks), &scratch, 64);
    try expectDocumentCounts(fragmented);
}

fn expectDocumentCounts(result: validate_json.Result) !void {
    try std.testing.expectEqual(validate_json.RootKind.object, result.root_kind);
    try std.testing.expectEqual(@as(u32, 10), result.values);
    try std.testing.expectEqual(@as(u32, 2), result.objects);
    try std.testing.expectEqual(@as(u32, 1), result.arrays);
    try std.testing.expectEqual(@as(u32, 5), result.object_members);
    try std.testing.expectEqual(@as(u32, 4), result.array_items);
    try std.testing.expectEqual(@as(u32, 3), result.string_values);
    try std.testing.expectEqual(@as(u32, 1), result.number_values);
}

test "token source preserves decoded strings and exact number lexemes" {
    const chunks = [_]body.Chunk{
        body.Chunk.init("[\"a\\u2"),
        body.Chunk.init("0ac\",-12."),
        body.Chunk.init("30e+4]"),
    };
    var source: token_source.Source = undefined;
    try source.init(try input(&chunks), 64);
    defer source.deinit();
    var scratch: [32]u8 = undefined;

    try std.testing.expectEqual(token_source.Token.array_begin, (try source.next(&scratch)).?);
    const string = (try source.next(&scratch)).?.string;
    try std.testing.expectEqualStrings("a€", string.bytes);
    try std.testing.expect(string.copied);
    const number = (try source.next(&scratch)).?.number;
    try std.testing.expectEqualStrings("-12.30e+4", number.bytes);
    try std.testing.expect(number.copied);
    try std.testing.expectEqual(token_source.Token.array_end, (try source.next(&scratch)).?);
    try std.testing.expect((try source.next(&scratch)) == null);
}

test "decoded-equivalent and unknown nested duplicate names reject" {
    var scratch: [4096]u8 align(validate_json.scratch_alignment) = undefined;
    const duplicate_cases = [_][]const u8{
        "{\"a\":1,\"\\u0061\":2}",
        "{\"outer\":{\"unknown\":1,\"unknown\":2}}",
        "{\"\":1,\"\":2}",
    };
    for (duplicate_cases) |document| {
        const chunks = [_]body.Chunk{body.Chunk.init(document)};
        try std.testing.expectError(
            error.DuplicateName,
            validate(try input(&chunks), &scratch, 64),
        );
    }

    const separate = "[{\"same\":1},{\"same\":2}]";
    const separate_chunks = [_]body.Chunk{body.Chunk.init(separate)};
    const result = try validate(try input(&separate_chunks), &scratch, 64);
    try std.testing.expectEqual(@as(u32, 2), result.object_members);
}

test "depth ceilings are explicit through the hard maximum" {
    var document: [(token_source.depth_hard_max + 1) * 2 + 1]u8 = undefined;
    var scratch: [1]u8 align(validate_json.scratch_alignment) = undefined;

    try expectNested(&document, 64, 64, &scratch, null);
    try expectNested(&document, 65, 64, &scratch, error.DepthLimitExceeded);
    try expectNested(&document, 256, 256, &scratch, null);
    try expectNested(&document, 257, 256, &scratch, error.DepthLimitExceeded);
}

fn expectNested(
    storage: []u8,
    depth: usize,
    depth_max: u16,
    scratch: []align(validate_json.scratch_alignment) u8,
    expected: ?validate_json.Error,
) !void {
    for (storage[0..depth]) |*byte| byte.* = '[';
    storage[depth] = '0';
    for (storage[depth + 1 .. depth * 2 + 1]) |*byte| byte.* = ']';
    const chunks = [_]body.Chunk{body.Chunk.init(storage[0 .. depth * 2 + 1])};
    if (expected) |problem| {
        try std.testing.expectError(problem, validate(try input(&chunks), scratch, depth_max));
    } else {
        const result = try validate(try input(&chunks), scratch, depth_max);
        try std.testing.expectEqual(@as(u32, @intCast(depth)), result.arrays);
    }
}

test "document grammar rejects empty BOM invalid Unicode and second values" {
    var scratch: [4096]u8 align(validate_json.scratch_alignment) = undefined;
    const cases = [_]struct { bytes: []const u8, problem: validate_json.Error }{
        .{ .bytes = "", .problem = error.UnexpectedEnd },
        .{ .bytes = " \r\n\t", .problem = error.UnexpectedEnd },
        .{ .bytes = "\xef\xbb\xbf{}", .problem = error.Syntax },
        .{ .bytes = "\"\xff\"", .problem = error.Syntax },
        .{ .bytes = "\"\\uD800\"", .problem = error.Syntax },
        .{ .bytes = "{} {}", .problem = error.Syntax },
    };
    for (cases) |case| {
        const chunks = [_]body.Chunk{body.Chunk.init(case.bytes)};
        try std.testing.expectError(
            case.problem,
            validate(try input(&chunks), &scratch, 64),
        );
    }
}

test "duplicate scratch bound accepts N and rejects N minus one" {
    const document = "{\"plain\":1,\"\\u0062\":2,\"third\":3}";
    const chunks = [_]body.Chunk{body.Chunk.init(document)};
    const value = try input(&chunks);
    var large: [4096]u8 align(validate_json.scratch_alignment) = undefined;
    const planned = try validate(value, &large, 64);
    const required = planned.duplicate_scratch_bytes;
    try std.testing.expect(required > 1);

    var exact: [4096]u8 align(validate_json.scratch_alignment) = undefined;
    const exact_slice: []align(validate_json.scratch_alignment) u8 =
        @alignCast(exact[0..required]);
    const result = try validate(value, exact_slice, 64);
    try std.testing.expectEqual(required, result.duplicate_scratch_bytes);

    const short: []align(validate_json.scratch_alignment) u8 =
        @alignCast(exact[0 .. required - 1]);
    try std.testing.expectError(error.ScratchTooSmall, validate(value, short, 64));
}

test "strict JSON fragmentation fuzz has one semantic outcome" {
    try std.testing.fuzz({}, fuzzValidation, .{ .corpus = &fuzz_corpus });
}

const fuzz_corpus = struct {
    const object = fuzz_support.smithInput("{\"a\":1,\"b\":[true,null]}");
    const escaped_duplicate = fuzz_support.smithInput("{\"a\":1,\"\\u0061\":2}");
    const unicode = fuzz_support.smithInput("[\"€\",\"\\uD834\\uDD1E\"]");
    const malformed = fuzz_support.smithInput("{\"a\":");
    const values = [_][]const u8{ &object, &escaped_duplicate, &unicode, &malformed };
}.values;

fn fuzzValidation(_: void, smith: *std.testing.Smith) !void {
    var bytes: [512]u8 = undefined;
    const document = bytes[0..smith.slice(&bytes)];
    var single_chunks = [_]body.Chunk{body.Chunk.init(document)};
    var fragmented: [bytes.len]body.Chunk = undefined;
    for (document, 0..) |_, index| {
        fragmented[index] = body.Chunk.init(document[index .. index + 1]);
    }
    var single_scratch: [scratch_bytes_max]u8 align(validate_json.scratch_alignment) =
        undefined;
    var split_scratch: [scratch_bytes_max]u8 align(validate_json.scratch_alignment) =
        undefined;
    const single = classify(try input(&single_chunks), &single_scratch);
    const split = classify(try input(fragmented[0..document.len]), &split_scratch);
    try std.testing.expectEqual(single.class, split.class);
    if (single.result) |left| try expectSemanticEqual(left, split.result.?);
}

const Class = enum {
    ready,
    syntax,
    unexpected_end,
    depth,
    duplicate,
    capacity,
};

const Classified = struct {
    class: Class,
    result: ?validate_json.Result = null,
};

fn classify(
    value: body.Bytes,
    scratch: []align(validate_json.scratch_alignment) u8,
) Classified {
    const result = validate(value, scratch, 64) catch |problem| return .{
        .class = switch (problem) {
            error.Syntax => .syntax,
            error.UnexpectedEnd => .unexpected_end,
            error.DepthLimitExceeded => .depth,
            error.DuplicateName => .duplicate,
            error.CountOverflow,
            error.ScratchTooSmall,
            error.ScannerCapacity,
            error.InvalidDepthLimit,
            => .capacity,
        },
    };
    return .{ .class = .ready, .result = result };
}

fn expectSemanticEqual(left: validate_json.Result, right: validate_json.Result) !void {
    try std.testing.expectEqual(left.input_bytes, right.input_bytes);
    try std.testing.expectEqual(left.root_kind, right.root_kind);
    try std.testing.expectEqual(left.values, right.values);
    try std.testing.expectEqual(left.objects, right.objects);
    try std.testing.expectEqual(left.arrays, right.arrays);
    try std.testing.expectEqual(left.object_members, right.object_members);
    try std.testing.expectEqual(left.array_items, right.array_items);
    try std.testing.expectEqual(left.string_values, right.string_values);
    try std.testing.expectEqual(left.number_values, right.number_values);
}
