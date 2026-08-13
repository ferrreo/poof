const std = @import("std");
const fuzz_support = @import("../../src/internal/http1/testing/smith.zig");
const schema = @import("../../src/internal/flat/schema.zig");
const wire = @import("../../src/internal/flat/wire.zig");

test "fragmented flat parsing decodes complete ordered pairs" {
    const fragments = [_]wire.Fragment{
        wire.Fragment.init("na%"),
        wire.Fragment.init("6d"),
        wire.Fragment.init("e=one+two&&=x&name=three%3Dfour&"),
    };
    var pairs: [8]wire.Pair = undefined;
    var bytes: [64]u8 = undefined;
    const table = try wire.parse(8, .query, &fragments, &pairs, &bytes);

    try std.testing.expectEqual(wire.Source.query, table.source);
    try std.testing.expectEqual(@as(u16, 5), table.segments_count);
    try std.testing.expectEqual(@as(usize, 3), table.pairs.len);
    try expectPair(table.pairs[0], "name", "one two");
    try expectPair(table.pairs[1], "", "x");
    try expectPair(table.pairs[2], "name", "three=four");
}

test "empty segments count at inclusive limits without materializing" {
    var pairs: [3]wire.Pair = undefined;
    var bytes: [1]u8 = undefined;
    const empty = try wire.parse(3, .query, &.{}, &pairs, &bytes);
    try std.testing.expectEqual(@as(u16, 0), empty.segments_count);
    try std.testing.expectEqual(@as(usize, 0), empty.pairs.len);

    const exact = try wire.parse(
        3,
        .query,
        &.{wire.Fragment.init("&&")},
        &pairs,
        &bytes,
    );
    try std.testing.expectEqual(@as(u16, 3), exact.segments_count);
    try std.testing.expectEqual(@as(usize, 0), exact.pairs.len);
    try std.testing.expectError(
        error.TooManySegments,
        wire.parse(3, .query, &.{wire.Fragment.init("&&&")}, &pairs, &bytes),
    );
}

test "standard and hard segment ceilings are inclusive" {
    try std.testing.expectEqual(
        @as(?wire.SegmentLimitIssue, .zero),
        wire.segmentLimitIssue(0),
    );
    try std.testing.expectEqual(
        @as(?wire.SegmentLimitIssue, null),
        wire.segmentLimitIssue(wire.segments_hard_max),
    );
    try std.testing.expectEqual(
        @as(?wire.SegmentLimitIssue, .above_hard_max),
        wire.segmentLimitIssue(wire.segments_hard_max + 1),
    );
    var no_pairs: [0]wire.Pair = .{};
    var no_bytes: [0]u8 = .{};
    var standard = [_]u8{'&'} ** (wire.segments_standard_max - 1);
    const at_standard = try wire.parse(
        wire.segments_standard_max,
        .query,
        &.{wire.Fragment.init(&standard)},
        &no_pairs,
        &no_bytes,
    );
    try std.testing.expectEqual(
        @as(u16, wire.segments_standard_max),
        at_standard.segments_count,
    );
    var standard_over = [_]u8{'&'} ** wire.segments_standard_max;
    try std.testing.expectError(
        error.TooManySegments,
        wire.parse(
            wire.segments_standard_max,
            .form,
            &.{wire.Fragment.init(&standard_over)},
            &no_pairs,
            &no_bytes,
        ),
    );

    var hard = [_]u8{'&'} ** (wire.segments_hard_max - 1);
    const at_hard = try wire.parse(
        wire.segments_hard_max,
        .form,
        &.{wire.Fragment.init(&hard)},
        &no_pairs,
        &no_bytes,
    );
    try std.testing.expectEqual(@as(u16, wire.segments_hard_max), at_hard.segments_count);
}

test "wire failures are source neutral and never return partial tables" {
    var pairs: [4]wire.Pair = undefined;
    var bytes: [16]u8 = undefined;
    const bad = [_][]const u8{ "%", "%0", "%GG", "a%2x", "raw;semi" };
    for (bad) |input| {
        const expected: wire.ParseError = if (std.mem.indexOfScalar(u8, input, ';') != null)
            error.InvalidCharacter
        else
            error.MalformedEncoding;
        try std.testing.expectError(
            expected,
            wire.parse(8, .query, &.{wire.Fragment.init(input)}, &pairs, &bytes),
        );
    }
    try std.testing.expectError(
        error.InvalidCharacter,
        wire.parse(8, .query, &.{wire.Fragment.init("raw[bracket]")}, &pairs, &bytes),
    );
    const form = try wire.parse(
        8,
        .form,
        &.{wire.Fragment.init("raw[bracket]=ok")},
        &pairs,
        &bytes,
    );
    try expectPair(form.pairs[0], "raw[bracket]", "ok");
}

test "forms validate every decoded name and value as UTF-8" {
    var pairs: [4]wire.Pair = undefined;
    var bytes: [32]u8 = undefined;
    const euro = try wire.parse(
        4,
        .form,
        &.{ wire.Fragment.init("currency=%E2%"), wire.Fragment.init("82%AC") },
        &pairs,
        &bytes,
    );
    try expectPair(euro.pairs[0], "currency", "\xe2\x82\xac");

    try std.testing.expectError(
        error.InvalidUtf8,
        wire.parse(4, .form, &.{wire.Fragment.init("bad=%ff")}, &pairs, &bytes),
    );
    const query = try wire.parse(
        4,
        .query,
        &.{wire.Fragment.init("bad=%ff")},
        &pairs,
        &bytes,
    );
    try std.testing.expectEqualStrings("\xff", query.pairs[0].value);
}

test "caller storage bounds decoded bytes and materialized pairs" {
    var no_pairs: [0]wire.Pair = .{};
    var enough_bytes: [8]u8 = undefined;
    try std.testing.expectError(
        error.InsufficientPairStorage,
        wire.parse(
            2,
            .query,
            &.{wire.Fragment.init("a=b")},
            &no_pairs,
            &enough_bytes,
        ),
    );

    var one_pair: [1]wire.Pair = undefined;
    var one_byte: [1]u8 = undefined;
    try std.testing.expectError(
        error.InsufficientByteStorage,
        wire.parse(
            2,
            .query,
            &.{wire.Fragment.init("ab=c")},
            &one_pair,
            &one_byte,
        ),
    );
}

const Renamed = struct {
    name: []const u8,
    limit: u16 = 50,

    pub const ploof_flat_fields = .{ .name = "display-name" };
};

test "binding uses exact renamed names and ignores unknown fields by default" {
    const pairs = [_]wire.Pair{
        .{ .name = "display-name", .value = "Zoe" },
        .{ .name = "extra", .value = "ignored" },
    };
    const table = testTable(&pairs);
    var scratch: [1]u8 = undefined;
    var arena = schema.Arena.init(&scratch);

    const value = switch (schema.bind(Renamed, table, &arena, .{})) {
        .ready => |ready| ready,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Zoe", value.name);
    try std.testing.expectEqual(@as(u16, 50), value.limit);
    try std.testing.expectEqual(@as(usize, 0), arena.used);

    const issue = switch (schema.bind(
        Renamed,
        table,
        &arena,
        .{ .unknown_fields = .reject },
    )) {
        .rejected => |rejected| rejected,
        .ready => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(schema.IssueClass.unknown_field, issue.class);
    try std.testing.expectEqual(@as(?[]const u8, null), issue.field);
}

const Defaults = struct {
    maybe: ?u16 = null,
    values: []const u16 = &.{},
};

const RequiredOptional = struct {
    value: ?u16,
};

test "defaults apply only to missing fields including optionals and slices" {
    const table = testTable(&.{});
    var scratch: [8]u8 = undefined;
    var arena = schema.Arena.init(&scratch);
    const defaults = switch (schema.bind(Defaults, table, &arena, .{})) {
        .ready => |ready| ready,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(?u16, null), defaults.maybe);
    try std.testing.expectEqual(@as(usize, 0), defaults.values.len);

    const issue = switch (schema.bind(RequiredOptional, table, &arena, .{})) {
        .rejected => |rejected| rejected,
        .ready => return error.TestUnexpectedResult,
    };
    try expectIssue(issue, .missing_field, "value");

    const empty_value = [_]wire.Pair{.{ .name = "value", .value = "" }};
    const empty_issue = switch (schema.bind(
        RequiredOptional,
        testTable(&empty_value),
        &arena,
        .{},
    )) {
        .rejected => |rejected| rejected,
        .ready => return error.TestUnexpectedResult,
    };
    try expectIssue(empty_issue, .invalid_value, "value");

    const present = [_]wire.Pair{.{ .name = "value", .value = "42" }};
    const present_value = switch (schema.bind(
        RequiredOptional,
        testTable(&present),
        &arena,
        .{},
    )) {
        .ready => |ready| ready,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(?u16, 42), present_value.value);
}

const Collections = struct {
    scalar: u8,
    all: []const u16,
    exact: [2]i8,
};

test "field types declare scalar slice and fixed-array cardinality" {
    const pairs = [_]wire.Pair{
        .{ .name = "all", .value = "2" },
        .{ .name = "scalar", .value = "1" },
        .{ .name = "exact", .value = "-3" },
        .{ .name = "all", .value = "4" },
        .{ .name = "exact", .value = "5" },
    };
    var scratch: [32]u8 = undefined;
    var arena = schema.Arena.init(&scratch);
    const value = switch (schema.bind(Collections, testTable(&pairs), &arena, .{})) {
        .ready => |ready| ready,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u8, 1), value.scalar);
    try std.testing.expectEqualSlices(u16, &.{ 2, 4 }, value.all);
    try std.testing.expectEqualSlices(i8, &.{ -3, 5 }, &value.exact);

    const duplicate = [_]wire.Pair{
        .{ .name = "scalar", .value = "1" },
        .{ .name = "scalar", .value = "2" },
        .{ .name = "all", .value = "3" },
        .{ .name = "exact", .value = "4" },
        .{ .name = "exact", .value = "5" },
    };
    const issue = switch (schema.bind(Collections, testTable(&duplicate), &arena, .{})) {
        .rejected => |rejected| rejected,
        .ready => return error.TestUnexpectedResult,
    };
    try expectIssue(issue, .cardinality, "scalar");
}

test "fixed arrays require their exact declared occurrence count" {
    const pairs = [_]wire.Pair{
        .{ .name = "scalar", .value = "1" },
        .{ .name = "all", .value = "2" },
        .{ .name = "exact", .value = "3" },
    };
    var scratch: [16]u8 = undefined;
    var arena = schema.Arena.init(&scratch);
    const issue = switch (schema.bind(Collections, testTable(&pairs), &arena, .{})) {
        .rejected => |rejected| rejected,
        .ready => return error.TestUnexpectedResult,
    };
    try expectIssue(issue, .cardinality, "exact");
}

const ScalarTypes = struct {
    signed: i8,
    unsigned: u8,
    decimal: f64,
    yes: bool,
    no: bool,
    color: Color,
    text: []const u8,
};

const Color = enum {
    red,
    Blue,
};

test "strict scalar conversion accepts only documented spellings" {
    const pairs = [_]wire.Pair{
        .{ .name = "signed", .value = "-128" },
        .{ .name = "unsigned", .value = "0007" },
        .{ .name = "decimal", .value = "-.5e+2" },
        .{ .name = "yes", .value = "true" },
        .{ .name = "no", .value = "0" },
        .{ .name = "color", .value = "Blue" },
        .{ .name = "text", .value = "" },
    };
    var scratch: [1]u8 = undefined;
    var arena = schema.Arena.init(&scratch);
    const value = switch (schema.bind(ScalarTypes, testTable(&pairs), &arena, .{})) {
        .ready => |ready| ready,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(i8, -128), value.signed);
    try std.testing.expectEqual(@as(u8, 7), value.unsigned);
    try std.testing.expectEqual(@as(f64, -50), value.decimal);
    try std.testing.expect(value.yes);
    try std.testing.expect(!value.no);
    try std.testing.expectEqual(Color.Blue, value.color);
    try std.testing.expectEqualStrings("", value.text);
}

const IntValue = struct { value: i8 };
const UintValue = struct { value: u8 };
const FloatValue = struct { value: f32 };
const BoolValue = struct { value: bool };
const EnumValue = struct { value: Color };
const TextValue = struct { value: []const u8 };

test "strict scalar conversion rejects coercion overflow and non-finite values" {
    const bad_int = [_][]const u8{ "", "+1", " 1", "1 ", "1.0", "128", "--1" };
    for (bad_int) |input| try expectInvalid(IntValue, input);
    try expectInvalid(UintValue, "-1");

    const bad_float = [_][]const u8{
        "",
        "NaN",
        "inf",
        "+1",
        "0x1p2",
        "1e",
        "--1",
        " 1",
        "1e9999",
    };
    for (bad_float) |input| try expectInvalid(FloatValue, input);
    for ([_][]const u8{ "True", "yes", "" }) |input| try expectInvalid(BoolValue, input);
    for ([_][]const u8{ "RED", "0", "" }) |input| try expectInvalid(EnumValue, input);
}

test "typed text rejects invalid UTF-8 from byte-oriented queries" {
    const pair = [_]wire.Pair{.{ .name = "value", .value = "\xff" }};
    var scratch: [1]u8 = undefined;
    var arena = schema.Arena.init(&scratch);
    const issue = switch (schema.bind(TextValue, testTable(&pair), &arena, .{})) {
        .rejected => |rejected| rejected,
        .ready => return error.TestUnexpectedResult,
    };
    try expectIssue(issue, .invalid_text, "value");
}

const Code = struct {
    input: []const u8,

    pub fn parseText(input: []const u8) schema.TextDecodeError!Code {
        if (input.len != 3) return error.InvalidSyntax;
        for (input) |byte| {
            if (byte < 'A' or byte > 'Z') return error.InvalidRepresentation;
        }
        return .{ .input = input };
    }
};

const CustomValue = struct { value: Code };

const NonFunctionHook = struct {
    pub const parseText = 1;
};

const WrongSignatureHook = struct {
    pub fn parseText(_: []const u8) WrongSignatureHook {
        return .{};
    }
};

test "parseText issue helper rejects non-functions and wrong signatures" {
    try std.testing.expectEqual(
        @as(?schema.TextHookIssue, null),
        schema.textHookIssue(Code),
    );
    try std.testing.expectEqual(
        @as(?schema.TextHookIssue, .not_function),
        schema.textHookIssue(NonFunctionHook),
    );
    try std.testing.expectEqual(
        @as(?schema.TextHookIssue, .wrong_signature),
        schema.textHookIssue(WrongSignatureHook),
    );
}

test "custom parseText is UTF-8 checked allocation-free and borrow-preserving" {
    const accepted = [_]wire.Pair{.{ .name = "value", .value = "ABC" }};
    var scratch: [1]u8 = undefined;
    var arena = schema.Arena.init(&scratch);
    const value = switch (schema.bind(CustomValue, testTable(&accepted), &arena, .{})) {
        .ready => |ready| ready,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("ABC", value.value.input);
    try std.testing.expectEqual(@as(usize, 0), arena.used);

    const malformed = [_]wire.Pair{.{ .name = "value", .value = "AbC" }};
    const malformed_issue = switch (schema.bind(
        CustomValue,
        testTable(&malformed),
        &arena,
        .{},
    )) {
        .rejected => |rejected| rejected,
        .ready => return error.TestUnexpectedResult,
    };
    try expectIssue(malformed_issue, .invalid_value, "value");

    const invalid_text = [_]wire.Pair{.{ .name = "value", .value = "\xffAA" }};
    const text_issue = switch (schema.bind(
        CustomValue,
        testTable(&invalid_text),
        &arena,
        .{},
    )) {
        .rejected => |rejected| rejected,
        .ready => return error.TestUnexpectedResult,
    };
    try expectIssue(text_issue, .invalid_text, "value");
}

const RepeatedU32 = struct { value: []const u32 };

test "bounded arena exhaustion rejects and rolls back its cursor" {
    const pairs = [_]wire.Pair{
        .{ .name = "value", .value = "1" },
        .{ .name = "value", .value = "2" },
    };
    var scratch: [4]u8 = undefined;
    var arena = schema.Arena.init(&scratch);
    arena.used = 1;
    const issue = switch (schema.bind(RepeatedU32, testTable(&pairs), &arena, .{})) {
        .rejected => |rejected| rejected,
        .ready => return error.TestUnexpectedResult,
    };
    try expectIssue(issue, .insufficient_storage, "value");
    try std.testing.expectEqual(@as(usize, 1), arena.used);

    const malformed = [_]wire.Pair{
        .{ .name = "value", .value = "1" },
        .{ .name = "value", .value = "bad" },
    };
    var full_scratch: [32]u8 = undefined;
    var full_arena = schema.Arena.init(&full_scratch);
    full_arena.used = 3;
    const malformed_issue = switch (schema.bind(
        RepeatedU32,
        testTable(&malformed),
        &full_arena,
        .{},
    )) {
        .rejected => |rejected| rejected,
        .ready => return error.TestUnexpectedResult,
    };
    try expectIssue(malformed_issue, .invalid_value, "value");
    try std.testing.expectEqual(@as(usize, 3), full_arena.used);
}

test "flat parser fragmentation fuzz is result-equivalent" {
    try std.testing.fuzz({}, fuzzFragmentation, .{ .corpus = &flat_fuzz_corpus });
}

const flat_fuzz_corpus = struct {
    const empty = fuzz_support.smithInput("");
    const fields = fuzz_support.smithInput("a=b&a=%ff&&=x");
    const escapes = fuzz_support.smithInput("%3B=%E2%82%AC");
    const malformed = fuzz_support.smithInput("a=%");
    const limit = fuzz_support.smithInput("&&&&&&&&&&&&&&&&");

    const values = [_][]const u8{ &empty, &fields, &escapes, &malformed, &limit };
}.values;

fn fuzzFragmentation(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [128]u8 = undefined;
    const input = input_storage[0..smith.slice(&input_storage)];
    var fragments: [128]wire.Fragment = undefined;
    for (input, 0..) |_, index| fragments[index] = wire.Fragment.init(input[index..][0..1]);

    var contiguous_pairs: [16]wire.Pair = undefined;
    var fragmented_pairs: [16]wire.Pair = undefined;
    var contiguous_bytes: [128]u8 = undefined;
    var fragmented_bytes: [128]u8 = undefined;
    var contiguous_error: ?wire.ParseError = null;
    var fragmented_error: ?wire.ParseError = null;
    const contiguous = wire.parse(
        16,
        .query,
        &.{wire.Fragment.init(input)},
        &contiguous_pairs,
        &contiguous_bytes,
    ) catch |parse_error| failed: {
        contiguous_error = parse_error;
        break :failed null;
    };
    const fragmented = wire.parse(
        16,
        .query,
        fragments[0..input.len],
        &fragmented_pairs,
        &fragmented_bytes,
    ) catch |parse_error| failed: {
        fragmented_error = parse_error;
        break :failed null;
    };
    try std.testing.expectEqual(contiguous_error, fragmented_error);
    if (contiguous) |left| try expectTablesEqual(left, fragmented.?);
}

fn expectTablesEqual(left: wire.Table, right: wire.Table) !void {
    try std.testing.expectEqual(left.source, right.source);
    try std.testing.expectEqual(left.segments_count, right.segments_count);
    try std.testing.expectEqual(left.pairs.len, right.pairs.len);
    for (left.pairs, right.pairs) |left_pair, right_pair| {
        try std.testing.expectEqualStrings(left_pair.name, right_pair.name);
        try std.testing.expectEqualStrings(left_pair.value, right_pair.value);
    }
}

fn testTable(pairs: []const wire.Pair) wire.Table {
    return .{ .source = .query, .segments_count = @intCast(pairs.len), .pairs = pairs };
}

fn expectPair(pair: wire.Pair, name: []const u8, value: []const u8) !void {
    try std.testing.expectEqualStrings(name, pair.name);
    try std.testing.expectEqualStrings(value, pair.value);
}

fn expectIssue(issue: schema.Issue, class: schema.IssueClass, field: []const u8) !void {
    try std.testing.expectEqual(class, issue.class);
    try std.testing.expectEqualStrings(field, issue.field.?);
}

fn expectInvalid(comptime T: type, input: []const u8) !void {
    const pair = [_]wire.Pair{.{ .name = "value", .value = input }};
    var scratch: [1]u8 = undefined;
    var arena = schema.Arena.init(&scratch);
    const issue = switch (schema.bind(T, testTable(&pair), &arena, .{})) {
        .rejected => |rejected| rejected,
        .ready => return error.TestUnexpectedResult,
    };
    try expectIssue(issue, .invalid_value, "value");
}
