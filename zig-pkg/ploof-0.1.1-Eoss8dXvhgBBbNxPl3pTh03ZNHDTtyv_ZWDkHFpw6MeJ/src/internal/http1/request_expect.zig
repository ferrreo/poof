const std = @import("std");
const fuzz_support = @import("testing/smith.zig");
const request_head = @import("request_head.zig");
const syntax = @import("syntax.zig");

pub const Error = error{ExpectationFailed};

/// Accepts only one physical `Expect: 100-continue` field.
pub fn analyze(
    fields: []const request_head.Field,
    bytes: []const u8,
) Error!bool {
    var found = false;
    for (fields) |field| {
        if (!syntax.eqlIgnoreCase(field.name.slice(bytes), "expect")) continue;
        if (found) return error.ExpectationFailed;
        found = true;
        const value = syntax.trimOws(field.value.slice(bytes));
        if (!syntax.eqlIgnoreCase(value, "100-continue")) {
            return error.ExpectationFailed;
        }
    }
    return found;
}

const Decoder = request_head.Decoder(@import("limits.zig").standard_request_head_limits);
const request_prefix = "POST / HTTP/1.1\r\nHost: example.test\r\n";

test "recognizes absent and one strict 100 continue expectation" {
    try expectValue(request_prefix ++ "\r\n", false);
    try expectValue(
        request_prefix ++ "eXpEcT:\t 100-CoNtInUe \t\r\n\r\n",
        true,
    );
}

test "rejects every other expectation shape" {
    const cases = [_][]const u8{
        request_prefix ++ "Expect:\r\n\r\n",
        request_prefix ++ "Expect: other\r\n\r\n",
        request_prefix ++ "Expect: 100-continue,other\r\n\r\n",
        request_prefix ++
            "Expect: 100-continue\r\nExpect: 100-continue\r\n\r\n",
    };
    for (cases) |case| try expectFailure(case);
}

test "Expect boundary fuzzes differentially against independent strict oracle" {
    try std.testing.fuzz({}, fuzzRequestExpect, .{ .corpus = &expect_fuzz_corpus });
}

const expect_fuzz_corpus = struct {
    const absent = fuzzCorpusInput("X-Test", "", 0);
    const valid = fuzzCorpusInput("Expect", "100-continue", 1);
    const mixed = fuzzCorpusInput("eXpEcT", "\t 100-CoNtInUe \t", 1);
    const duplicate = fuzzCorpusInput("Expect", "100-continue", 2);
    const list = fuzzCorpusInput("Expect", "100-continue, other", 1);
    const empty = fuzzCorpusInput("Expect", "", 1);
    const other_value = fuzzCorpusInput("Expect", "other", 1);
    const unrelated_first = fuzzCorpusInput("Expect", "100-continue", 3);
    const unrelated_last = fuzzCorpusInput("Expect", "100-continue", 4);
    const unrelated = fuzzCorpusInput("X-Expect", "100-continue", 5);
    const values = [_][]const u8{
        &absent,
        &valid,
        &mixed,
        &duplicate,
        &list,
        &empty,
        &other_value,
        &unrelated_first,
        &unrelated_last,
        &unrelated,
    };
}.values;

fn fuzzRequestExpect(_: void, smith: *std.testing.Smith) !void {
    var name_storage: [32]u8 = undefined;
    const name = name_storage[0..smith.slice(&name_storage)];
    var value_storage: [512]u8 = undefined;
    const value = value_storage[0..smith.slice(&value_storage)];
    const shape = smith.valueRangeAtMost(u8, 0, 5);

    var bytes_storage: [name_storage.len + value_storage.len + 1]u8 = undefined;
    @memcpy(bytes_storage[0..name.len], name);
    const value_offset = name.len;
    @memcpy(bytes_storage[value_offset..][0..value.len], value);
    const other_offset = value_offset + value.len;
    bytes_storage[other_offset] = 'x';
    const bytes = bytes_storage[0 .. other_offset + 1];

    const candidate = makeField(0, name.len, value_offset, value.len);
    const other = makeField(other_offset, 1, value_offset, value.len);
    var fields_storage: [2]request_head.Field = undefined;
    const fields = selectFields(shape, candidate, other, &fields_storage);

    const actual = analyze(fields, bytes);
    if (referenceAnalyze(fields, bytes)) |expected| {
        try std.testing.expectEqual(expected, try actual);
    } else |expected_error| {
        try std.testing.expectError(expected_error, actual);
    }
}

fn makeField(
    name_offset: usize,
    name_length: usize,
    value_offset: usize,
    value_length: usize,
) request_head.Field {
    const value = request_head.Span{
        .offset = @intCast(value_offset),
        .length = @intCast(value_length),
    };
    return .{
        .name = .{ .offset = @intCast(name_offset), .length = @intCast(name_length) },
        .raw_value = value,
        .value = value,
    };
}

fn selectFields(
    shape: u8,
    candidate: request_head.Field,
    other: request_head.Field,
    storage: *[2]request_head.Field,
) []const request_head.Field {
    switch (shape) {
        0 => return storage[0..0],
        1 => storage.* = .{ candidate, undefined },
        2 => storage.* = .{ candidate, candidate },
        3 => storage.* = .{ other, candidate },
        4 => storage.* = .{ candidate, other },
        5 => storage.* = .{ other, undefined },
        else => unreachable,
    }
    return storage[0..if (shape == 1 or shape == 5) 1 else 2];
}

fn referenceAnalyze(fields: []const request_head.Field, bytes: []const u8) Error!bool {
    var matching_fields: u8 = 0;
    var matching_value = false;
    for (fields) |field| {
        if (!referenceEqualIgnoreCase(field.name.slice(bytes), "expect")) continue;
        matching_fields += 1;
        const value = referenceTrimOws(field.value.slice(bytes));
        matching_value = referenceEqualIgnoreCase(value, "100-continue");
    }
    if (matching_fields == 0) return false;
    if (matching_fields == 1 and matching_value) return true;
    return error.ExpectationFailed;
}

fn referenceTrimOws(value: []const u8) []const u8 {
    var start: usize = 0;
    while (start < value.len and (value[start] == ' ' or value[start] == '\t')) start += 1;
    var end = value.len;
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t')) end -= 1;
    return value[start..end];
}

fn referenceEqualIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        const left_lower = if (left_byte >= 'A' and left_byte <= 'Z') left_byte + 32 else left_byte;
        const right_lower = if (right_byte >= 'A' and right_byte <= 'Z')
            right_byte + 32
        else
            right_byte;
        if (left_lower != right_lower) return false;
    }
    return true;
}

fn fuzzCorpusInput(
    comptime name: []const u8,
    comptime value: []const u8,
    comptime shape: u64,
) [name.len + value.len + 16]u8 {
    const name_input = fuzz_support.smithInput(name);
    const value_input = fuzz_support.smithInput(value);
    var input: [name.len + value.len + 16]u8 = undefined;
    @memcpy(input[0..name_input.len], &name_input);
    @memcpy(input[name_input.len..][0..value_input.len], &value_input);
    const shape_offset = name_input.len + value_input.len;
    inline for (0..8) |index| input[shape_offset + index] = @truncate(shape >> (index * 8));
    return input;
}

fn expectValue(input: []const u8, expected: bool) !void {
    var decoder = Decoder.init();
    _ = switch (decoder.feed(input).state) {
        .ready => |head| head,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(expected, try analyze(decoder.fields(), decoder.bytes()));
}

fn expectFailure(input: []const u8) !void {
    var decoder = Decoder.init();
    _ = switch (decoder.feed(input).state) {
        .ready => |head| head,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectError(
        error.ExpectationFailed,
        analyze(decoder.fields(), decoder.bytes()),
    );
}
