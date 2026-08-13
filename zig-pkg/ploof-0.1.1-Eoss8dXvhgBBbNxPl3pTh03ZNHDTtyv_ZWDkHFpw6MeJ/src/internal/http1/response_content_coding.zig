const std = @import("std");
const request_accept_encoding = @import("request_accept_encoding.zig");

pub const Preferences = request_accept_encoding.Preferences;

pub const Eligibility = enum {
    eligible,
    ineligible,
    bodyless_status,
};

pub const Body = union(enum) {
    none,
    finite: u64,
    stream,
};

pub const SkipReason = enum {
    bodyless_status,
    bodyless,
    stream,
};

pub const IdentityReason = enum {
    ineligible,
    below_threshold,
    negotiated,
};

pub const GzipSelection = struct {
    identity_fallback_available: bool,
};

pub const Decision = union(enum) {
    application_content_encoding,
    skipped: SkipReason,
    identity: IdentityReason,
    gzip: GzipSelection,
    not_acceptable,

    pub fn variesAcceptEncoding(self: Decision) bool {
        return switch (self) {
            .application_content_encoding, .skipped => false,
            .identity, .gzip, .not_acceptable => true,
        };
    }

    pub fn closesConnection(self: Decision) bool {
        return switch (self) {
            .not_acceptable => true,
            else => false,
        };
    }
};

pub const Input = struct {
    body: Body,
    minimum_gzip_bytes: u64,
    preferences: Preferences,
    eligibility: Eligibility,
    has_application_content_encoding: bool,
};

pub fn select(input: Input) Decision {
    std.debug.assert(input.preferences.gzip <= request_accept_encoding.weight_max);
    std.debug.assert(input.preferences.identity <= request_accept_encoding.weight_max);

    if (input.has_application_content_encoding) return .application_content_encoding;
    if (input.eligibility == .bodyless_status) return .{ .skipped = .bodyless_status };
    return switch (input.body) {
        .none => .{ .skipped = .bodyless },
        .stream => .{ .skipped = .stream },
        .finite => |length| switch (input.eligibility) {
            .eligible => selectFinite(input, length),
            .ineligible => if (input.preferences.identity != 0)
                .{ .identity = .ineligible }
            else
                .not_acceptable,
            .bodyless_status => unreachable,
        },
    };
}

fn selectFinite(input: Input, length: u64) Decision {
    const preferences = input.preferences;
    if (length < input.minimum_gzip_bytes) {
        return if (preferences.identity != 0)
            .{ .identity = .below_threshold }
        else
            .not_acceptable;
    }
    if (preferences.gzip == 0 and preferences.identity == 0) return .not_acceptable;
    if (preferences.gzip != 0 and preferences.gzip >= preferences.identity) {
        return .{ .gzip = .{
            .identity_fallback_available = preferences.identity != 0,
        } };
    }
    return .{ .identity = .negotiated };
}

const Case = struct {
    name: []const u8,
    input: Input,
    expected: Decision,
};

const both = Preferences{ .gzip = 1000, .identity = 1000 };

const truth_cases = [_]Case{
    case(
        "application coding bypasses every automatic rule",
        both,
        .ineligible,
        .stream,
        8,
        true,
        .application_content_encoding,
    ),
    case(
        "ineligible representation selects acceptable identity",
        both,
        .ineligible,
        .{ .finite = 8 },
        8,
        false,
        .{ .identity = .ineligible },
    ),
    case(
        "ineligible representation rejects forbidden identity",
        .{ .gzip = 1000, .identity = 0 },
        .ineligible,
        .{ .finite = 8 },
        8,
        false,
        .not_acceptable,
    ),
    case(
        "bodyless status skips",
        both,
        .bodyless_status,
        .none,
        8,
        false,
        .{ .skipped = .bodyless_status },
    ),
    case(
        "absent body skips",
        both,
        .eligible,
        .none,
        8,
        false,
        .{ .skipped = .bodyless },
    ),
    case(
        "stream skips",
        both,
        .eligible,
        .stream,
        8,
        false,
        .{ .skipped = .stream },
    ),
    case(
        "zero-length present body is below positive threshold",
        both,
        .eligible,
        .{ .finite = 0 },
        1,
        false,
        .{ .identity = .below_threshold },
    ),
    case(
        "below threshold selects acceptable identity",
        both,
        .eligible,
        .{ .finite = 7 },
        8,
        false,
        .{ .identity = .below_threshold },
    ),
    case(
        "below threshold rejects forbidden identity",
        .{ .gzip = 1000, .identity = 0 },
        .eligible,
        .{ .finite = 7 },
        8,
        false,
        .not_acceptable,
    ),
    case(
        "zero weights reject",
        .{ .gzip = 0, .identity = 0 },
        .eligible,
        .{ .finite = 8 },
        8,
        false,
        .not_acceptable,
    ),
    case(
        "gzip wins positive tie",
        both,
        .eligible,
        .{ .finite = 8 },
        8,
        false,
        .{ .gzip = .{ .identity_fallback_available = true } },
    ),
    case(
        "gzip wins higher weight",
        .{ .gzip = 900, .identity = 400 },
        .eligible,
        .{ .finite = 9 },
        8,
        false,
        .{ .gzip = .{ .identity_fallback_available = true } },
    ),
    case(
        "gzip records forbidden identity fallback",
        .{ .gzip = 1, .identity = 0 },
        .eligible,
        .{ .finite = 8 },
        8,
        false,
        .{ .gzip = .{ .identity_fallback_available = false } },
    ),
    case(
        "identity wins higher weight",
        .{ .gzip = 400, .identity = 900 },
        .eligible,
        .{ .finite = 8 },
        8,
        false,
        .{ .identity = .negotiated },
    ),
    case(
        "identity wins when gzip is forbidden",
        .{ .gzip = 0, .identity = 1 },
        .eligible,
        .{ .finite = 8 },
        8,
        false,
        .{ .identity = .negotiated },
    ),
    case(
        "zero threshold permits empty gzip representation",
        both,
        .eligible,
        .{ .finite = 0 },
        0,
        false,
        .{ .gzip = .{ .identity_fallback_available = true } },
    ),
};

test "finite response coding selection matches exhaustive truth table" {
    for (truth_cases) |entry| {
        errdefer std.debug.print("failed truth-table case: {s}\n", .{entry.name});
        try std.testing.expectEqualDeep(entry.expected, select(entry.input));
        try expectMetadata(entry.expected);
    }
}

test "categorical response coding truth table is exhaustive" {
    const eligibilities = [_]Eligibility{ .eligible, .ineligible, .bodyless_status };
    const bodies = [_]Body{ .none, .stream, .{ .finite = 0 }, .{ .finite = 8 } };
    const preferences = [_]Preferences{
        .{ .gzip = 0, .identity = 0 },
        .{ .gzip = 0, .identity = 1000 },
        .{ .gzip = 1000, .identity = 0 },
        .{ .gzip = 500, .identity = 500 },
        .{ .gzip = 400, .identity = 900 },
        .{ .gzip = 900, .identity = 400 },
    };
    const booleans = [_]bool{ false, true };
    const thresholds = [_]u64{ 0, 8, 9 };
    for (eligibilities) |eligibility| {
        for (bodies) |body| {
            for (preferences) |accepted| {
                for (booleans) |application_encoded| {
                    for (thresholds) |minimum| {
                        const input = Input{
                            .body = body,
                            .minimum_gzip_bytes = minimum,
                            .preferences = accepted,
                            .eligibility = eligibility,
                            .has_application_content_encoding = application_encoded,
                        };
                        try std.testing.expectEqualDeep(referenceSelect(input), select(input));
                    }
                }
            }
        }
    }
}

test "all valid weight pairs select the maximum available finite coding" {
    for (0..request_accept_encoding.weight_max + 1) |gzip| {
        for (0..request_accept_encoding.weight_max + 1) |identity| {
            const input = finiteInput(@intCast(gzip), @intCast(identity), 32, 32);
            const expected = expectedFinite(input);
            const actual = select(input);
            if (!std.meta.eql(expected, actual)) {
                try std.testing.expectEqualDeep(expected, actual);
            }
        }
    }
}

test "finite threshold partitions every nearby body length" {
    const weights = [_]Preferences{
        .{ .gzip = 0, .identity = 0 },
        .{ .gzip = 0, .identity = 1 },
        .{ .gzip = 1, .identity = 0 },
        .{ .gzip = 1, .identity = 1 },
        .{ .gzip = 400, .identity = 900 },
        .{ .gzip = 900, .identity = 400 },
    };
    for (weights) |preferences| {
        for (0..33) |minimum| {
            for (0..33) |length| {
                const input = Input{
                    .preferences = preferences,
                    .eligibility = .eligible,
                    .body = .{ .finite = @intCast(length) },
                    .minimum_gzip_bytes = @intCast(minimum),
                    .has_application_content_encoding = false,
                };
                try std.testing.expectEqualDeep(expectedFinite(input), select(input));
            }
        }
    }
}

test "decision and input representations remain compact" {
    try std.testing.expect(@sizeOf(Decision) <= 2);
    try std.testing.expect(@sizeOf(Preferences) == 4);
    try std.testing.expect(@sizeOf(Input) <= 32);
}

test "finite response content coding decision fuzz" {
    try std.testing.fuzz({}, fuzzSelection, .{ .corpus = &fuzz_corpus });
}

fn case(
    name: []const u8,
    preferences: Preferences,
    eligibility: Eligibility,
    body: Body,
    minimum: u64,
    application_encoded: bool,
    expected: Decision,
) Case {
    return .{
        .name = name,
        .input = .{
            .preferences = preferences,
            .eligibility = eligibility,
            .body = body,
            .minimum_gzip_bytes = minimum,
            .has_application_content_encoding = application_encoded,
        },
        .expected = expected,
    };
}

fn finiteInput(gzip: u16, identity: u16, length: u64, minimum: u64) Input {
    return .{
        .preferences = .{ .gzip = gzip, .identity = identity },
        .eligibility = .eligible,
        .body = .{ .finite = length },
        .minimum_gzip_bytes = minimum,
        .has_application_content_encoding = false,
    };
}

fn expectedFinite(input: Input) Decision {
    const length = switch (input.body) {
        .finite => |value| value,
        else => unreachable,
    };
    const identity_available = input.preferences.identity != 0;
    const gzip_available = length >= input.minimum_gzip_bytes and
        input.preferences.gzip != 0;
    if (!identity_available and !gzip_available) return .not_acceptable;
    if (gzip_available and input.preferences.gzip >= input.preferences.identity) {
        return .{ .gzip = .{ .identity_fallback_available = identity_available } };
    }
    return .{ .identity = if (length < input.minimum_gzip_bytes)
        .below_threshold
    else
        .negotiated };
}

fn expectMetadata(decision: Decision) !void {
    const varies = switch (decision) {
        .identity, .gzip, .not_acceptable => true,
        .application_content_encoding, .skipped => false,
    };
    const closes = switch (decision) {
        .not_acceptable => true,
        else => false,
    };
    try std.testing.expectEqual(varies, decision.variesAcceptEncoding());
    try std.testing.expectEqual(closes, decision.closesConnection());
}

fn fuzzSelection(_: void, smith: *std.testing.Smith) !void {
    const input = Input{
        .preferences = .{
            .gzip = smith.valueRangeAtMost(u16, 0, request_accept_encoding.weight_max),
            .identity = smith.valueRangeAtMost(u16, 0, request_accept_encoding.weight_max),
        },
        .eligibility = @enumFromInt(smith.valueRangeAtMost(u8, 0, 2)),
        .body = fuzzBody(smith),
        .minimum_gzip_bytes = @intCast(smith.valueRangeAtMost(u16, 0, 4096)),
        .has_application_content_encoding = smith.value(bool),
    };
    const expected = referenceSelect(input);
    const actual = select(input);
    try std.testing.expectEqualDeep(expected, actual);
    try expectMetadata(actual);
}

fn fuzzBody(smith: *std.testing.Smith) Body {
    return switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => .none,
        1 => .{ .finite = @intCast(smith.valueRangeAtMost(u16, 0, 4096)) },
        2 => .stream,
        else => unreachable,
    };
}

fn referenceSelect(input: Input) Decision {
    if (input.has_application_content_encoding) return .application_content_encoding;
    if (input.eligibility == .bodyless_status) return .{ .skipped = .bodyless_status };
    return switch (input.body) {
        .none => .{ .skipped = .bodyless },
        .stream => .{ .skipped = .stream },
        .finite => if (input.eligibility == .ineligible)
            if (input.preferences.identity != 0)
                .{ .identity = .ineligible }
            else
                .not_acceptable
        else
            expectedFinite(input),
    };
}

const fuzz_zero = [_]u8{0} ** 32;
const fuzz_ones = [_]u8{0xff} ** 32;
const fuzz_mixed = [_]u8{
    0xe8, 0x03, 0x00, 0x00, 0xe8, 0x03, 0x00, 0x00,
    0x02, 0x01, 0x00, 0x10, 0x00, 0x08, 0x00, 0x01,
    0x7f, 0x80, 0xaa, 0x55, 0x01, 0x00, 0xfe, 0xff,
    0x00, 0x00, 0x20, 0x00, 0x10, 0x00, 0x00, 0x01,
};
const fuzz_corpus = [_][]const u8{ &fuzz_zero, &fuzz_ones, &fuzz_mixed };
