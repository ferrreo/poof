const std = @import("std");
const fuzz_support = @import("testing/smith.zig");
const limits = @import("limits.zig");
const media_type = @import("media_type.zig");
const response_head = @import("response_head.zig");
const response_headers = @import("response_headers.zig");
const response_transfer = @import("response_transfer.zig");
const syntax = @import("syntax.zig");

pub const list_members_max: u8 = 64;
pub const empty_members_max: u8 = 32;

const content_encoding_name = "content-encoding";
const vary_name = "vary";
const accept_encoding_name = "Accept-Encoding";

pub const Error = error{InvalidHeader};

pub const Selection = packed struct(u8) {
    framework_gzip: bool = false,
    negotiation_varies: bool = false,
    _padding: u6 = 0,
};

pub const Plan = packed struct(u8) {
    append_gzip: bool = false,
    append_vary_accept_encoding: bool = false,
    _padding: u6 = 0,

    fn addedFields(self: Plan) usize {
        var count: usize = 0;
        count += @intFromBool(self.append_gzip);
        count += @intFromBool(self.append_vary_accept_encoding);
        return count;
    }
};

pub const Analysis = packed struct(u8) {
    has_application_content_encoding: bool = false,
    vary_star: bool = false,
    vary_accept_encoding: bool = false,
    _padding: u5 = 0,

    pub fn plan(self: Analysis, selection: Selection) Plan {
        return .{
            .append_gzip = selection.framework_gzip and
                !self.has_application_content_encoding,
            .append_vary_accept_encoding = selection.negotiation_varies and
                !self.vary_star and !self.vary_accept_encoding,
        };
    }
};

const ListScan = struct {
    members: u8 = 0,
    empty_members: u8 = 0,
    star: bool = false,
    accept_encoding: bool = false,
};

/// Presence with no coding is rejected as invalid sender metadata, beyond list syntax.
pub fn analyze(headers: anytype) Error!Analysis {
    if (headers.len() > limits.fields_hard_max) return error.InvalidHeader;

    var coding = ListScan{};
    var vary = ListScan{};
    var has_content_encoding = false;
    var index: usize = 0;
    while (index < headers.len()) : (index += 1) {
        const field = headers.at(index);
        if (syntax.eqlIgnoreCase(field.name, content_encoding_name)) {
            has_content_encoding = true;
            try scanListValue(&coding, field.value);
        } else if (syntax.eqlIgnoreCase(field.name, vary_name)) {
            try scanListValue(&vary, field.value);
        }
    }
    if (has_content_encoding and coding.members == 0) return error.InvalidHeader;
    return .{
        .has_application_content_encoding = has_content_encoding,
        .vary_star = vary.star,
        .vary_accept_encoding = vary.accept_encoding,
    };
}

pub fn Overlay(comptime HeaderStore: type) type {
    return struct {
        const Self = @This();

        headers: *const HeaderStore,
        plan: Plan,

        pub fn len(self: *const Self) usize {
            return self.headers.len() + self.plan.addedFields();
        }

        pub fn at(self: *const Self, index: usize) response_headers.Field {
            const stored = self.headers.len();
            std.debug.assert(index < self.len());
            if (index < stored) return self.headers.at(index);

            var synthetic = index - stored;
            if (self.plan.append_gzip) {
                if (synthetic == 0) return gzip_field;
                synthetic -= 1;
            }
            std.debug.assert(self.plan.append_vary_accept_encoding and synthetic == 0);
            return vary_accept_encoding_field;
        }
    };
}

pub fn overlay(headers: anytype, plan: Plan) Overlay(@TypeOf(headers.*)) {
    return .{ .headers = headers, .plan = plan };
}

fn scanListValue(scan: *ListScan, value: []const u8) Error!void {
    var cursor: usize = 0;
    while (true) {
        skipOws(value, &cursor);
        const start = cursor;
        while (cursor < value.len and syntax.isTokenByte(value[cursor])) cursor += 1;
        if (cursor == start) {
            scan.empty_members = std.math.add(u8, scan.empty_members, 1) catch {
                return error.InvalidHeader;
            };
            if (scan.empty_members > empty_members_max) return error.InvalidHeader;
        } else {
            scan.members = std.math.add(u8, scan.members, 1) catch {
                return error.InvalidHeader;
            };
            if (scan.members > list_members_max) return error.InvalidHeader;
            const member = value[start..cursor];
            scan.star = scan.star or std.mem.eql(u8, member, "*");
            scan.accept_encoding = scan.accept_encoding or
                syntax.eqlIgnoreCase(member, accept_encoding_name);
        }
        skipOws(value, &cursor);
        if (cursor == value.len) return;
        if (value[cursor] != ',') return error.InvalidHeader;
        cursor += 1;
    }
}

fn skipOws(value: []const u8, cursor: *usize) void {
    while (cursor.* < value.len and
        (value[cursor.*] == ' ' or value[cursor.*] == '\t'))
    {
        cursor.* += 1;
    }
}

const gzip_field = response_headers.Field{
    .name = content_encoding_name,
    .value = "gzip",
};

const vary_accept_encoding_field = response_headers.Field{
    .name = vary_name,
    .value = accept_encoding_name,
};

const FakeHeaders = struct {
    fields: []const response_headers.Field,

    pub fn len(self: *const FakeHeaders) usize {
        return self.fields.len;
    }

    pub fn at(self: *const FakeHeaders, index: usize) response_headers.Field {
        return self.fields[index];
    }
};

const StandardHeaders = response_headers.Headers(limits.standard_response_head_limits);
const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";

test "analyzes combined application coding and Vary fields" {
    const fields = [_]response_headers.Field{
        .{ .name = "Content-Encoding", .value = "gzip," },
        .{ .name = "content-encoding", .value = " br" },
        .{ .name = "VARY", .value = "Accept-Language, ACCEPT-ENCODING" },
        .{ .name = "vary", .value = "accept-encoding" },
    };
    const headers = FakeHeaders{ .fields = &fields };
    const result = try analyze(&headers);

    try std.testing.expect(result.has_application_content_encoding);
    try std.testing.expect(!result.vary_star);
    try std.testing.expect(result.vary_accept_encoding);
    const plan = result.plan(.{ .framework_gzip = true, .negotiation_varies = true });
    try std.testing.expect(!plan.append_gzip);
    try std.testing.expect(!plan.append_vary_accept_encoding);
}

test "overlay appends synthetic fields without changing header storage" {
    var headers = StandardHeaders{};
    try headers.append("X-First", "one");
    try headers.append("Vary", "Accept-Language");
    const before = headers;
    const result = try analyze(&headers);
    const plan = result.plan(.{ .framework_gzip = true, .negotiation_varies = true });
    const view = overlay(&headers, plan);

    try std.testing.expectEqual(@as(usize, 4), view.len());
    try expectField(view.at(0), "x-first", "one");
    try expectField(view.at(1), "vary", "Accept-Language");
    try expectField(view.at(2), "content-encoding", "gzip");
    try expectField(view.at(3), "vary", "Accept-Encoding");
    try std.testing.expectEqualDeep(before, headers);
}

test "Vary wildcard and duplicates suppress only the synthetic Vary field" {
    const fields = [_]response_headers.Field{
        .{ .name = "vary", .value = "*, Accept-Language" },
        .{ .name = "VaRy", .value = "*, accept-language" },
    };
    const headers = FakeHeaders{ .fields = &fields };
    const result = try analyze(&headers);
    const plan = result.plan(.{ .framework_gzip = true, .negotiation_varies = true });
    const view = overlay(&headers, plan);

    try std.testing.expect(result.vary_star);
    try std.testing.expect(!result.vary_accept_encoding);
    try std.testing.expect(plan.append_gzip);
    try std.testing.expect(!plan.append_vary_accept_encoding);
    try std.testing.expectEqual(fields.len + 1, view.len());
    try expectField(view.at(fields.len), "content-encoding", "gzip");
}

test "empty Vary is valid and application Content-Encoding is nonempty" {
    const empty_vary_fields = [_]response_headers.Field{
        .{ .name = "vary", .value = "\t , , " },
    };
    const empty_vary = FakeHeaders{ .fields = &empty_vary_fields };
    const vary_result = try analyze(&empty_vary);
    try std.testing.expect(!vary_result.vary_star);
    try std.testing.expect(!vary_result.vary_accept_encoding);

    const empty_coding_fields = [_]response_headers.Field{
        .{ .name = "content-encoding", .value = " ,\t," },
    };
    const empty_coding = FakeHeaders{ .fields = &empty_coding_fields };
    try std.testing.expectError(error.InvalidHeader, analyze(&empty_coding));
}

test "rejects malformed coding and Vary list syntax" {
    const cases = [_]response_headers.Field{
        .{ .name = "content-encoding", .value = "gzip;q=1" },
        .{ .name = "content-encoding", .value = "gzip br" },
        .{ .name = "content-encoding", .value = "gzip\r\nx: injected" },
        .{ .name = "vary", .value = "Accept Encoding" },
        .{ .name = "vary", .value = "Accept-Encoding; q=1" },
        .{ .name = "vary", .value = "Accept-Encoding\x7f" },
    };
    for (cases) |field| {
        const fields = [_]response_headers.Field{field};
        const headers = FakeHeaders{ .fields = &fields };
        try std.testing.expectError(error.InvalidHeader, analyze(&headers));
    }
}

test "list member and empty member limits are inclusive" {
    const members_at_limit = "x," ** (list_members_max - 1) ++ "x";
    const members_over_limit = members_at_limit ++ ",x";
    const empties_at_limit = "," ** (empty_members_max - 1);
    const empties_over_limit = empties_at_limit ++ ",";

    try expectAcceptedVary(members_at_limit);
    try expectRejectedVary(members_over_limit);
    try expectAcceptedVary(empties_at_limit);
    try expectRejectedVary(empties_over_limit);

    const coding_at_limit = "gzip" ++ ("," ** empty_members_max);
    const coding_over_limit = coding_at_limit ++ ",";
    try expectAcceptedCoding(coding_at_limit);
    try expectRejectedCoding(coding_over_limit);
}

const exact_wire =
    "HTTP/1.1 200 OK\r\n" ++
    "content-encoding: gzip\r\n" ++
    "vary: Accept-Encoding\r\n" ++
    "content-type: text/plain; charset=utf-8\r\n" ++
    "content-length: 4\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "\r\n";

const exact_head_limits = limits.ResponseHeadLimits.validate(.{
    .head_bytes_max = exact_wire.len,
    .field_line_bytes_max = 64,
    .fields_max = 5,
});

const one_byte_short_limits = limits.ResponseHeadLimits.validate(.{
    .head_bytes_max = exact_wire.len - 1,
    .field_line_bytes_max = 64,
    .fields_max = 5,
});

const one_field_short_limits = limits.ResponseHeadLimits.validate(.{
    .head_bytes_max = exact_wire.len,
    .field_line_bytes_max = 64,
    .fields_max = 4,
});

test "downstream head writer enforces exact bytes and field counts transactionally" {
    const fields = [_]response_headers.Field{};
    const headers = FakeHeaders{ .fields = &fields };
    const result = try analyze(&headers);
    const plan = result.plan(.{ .framework_gzip = true, .negotiation_varies = true });
    const view = overlay(&headers, plan);
    var exact_output: [exact_wire.len]u8 = undefined;
    const written = try response_head.write(
        exact_head_limits,
        response_transfer.standard_trailer_limits,
        &exact_output,
        finiteHeadInput(),
        &view,
    );
    try std.testing.expectEqualStrings(exact_wire, written.bytes);

    var byte_output = [_]u8{0xa5} ** exact_wire.len;
    const byte_before = byte_output;
    try std.testing.expectError(error.ResponseHeadTooLarge, response_head.write(
        one_byte_short_limits,
        response_transfer.standard_trailer_limits,
        &byte_output,
        finiteHeadInput(),
        &view,
    ));
    try std.testing.expectEqualSlices(u8, &byte_before, &byte_output);

    var field_output = [_]u8{0x5a} ** exact_wire.len;
    const field_before = field_output;
    try std.testing.expectError(error.ResponseHeadTooLarge, response_head.write(
        one_field_short_limits,
        response_transfer.standard_trailer_limits,
        &field_output,
        finiteHeadInput(),
        &view,
    ));
    try std.testing.expectEqualSlices(u8, &field_before, &field_output);
}

test "analysis and plan remain one-byte values" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Analysis));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Plan));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Selection));
}

test "response coding field overlay fuzz preserves source and tail invariants" {
    try std.testing.fuzz({}, fuzzOverlay, .{ .corpus = &fuzz_corpus });
}

fn finiteHeadInput() response_head.HeadInput {
    return .{
        .framing = .{
            .status = .ok,
            .request_is_head = false,
            .request_accepts_trailers = false,
            .body = .{ .fixed = 4 },
            .trailers_declared = false,
        },
        .default_content_type = media_type.text,
        .date = fixed_date,
    };
}

fn expectField(field: response_headers.Field, name: []const u8, value: []const u8) !void {
    try std.testing.expectEqualStrings(name, field.name);
    try std.testing.expectEqualStrings(value, field.value);
}

fn expectAcceptedVary(value: []const u8) !void {
    const fields = [_]response_headers.Field{.{ .name = "vary", .value = value }};
    const headers = FakeHeaders{ .fields = &fields };
    _ = try analyze(&headers);
}

fn expectRejectedVary(value: []const u8) !void {
    const fields = [_]response_headers.Field{.{ .name = "vary", .value = value }};
    const headers = FakeHeaders{ .fields = &fields };
    try std.testing.expectError(error.InvalidHeader, analyze(&headers));
}

fn expectAcceptedCoding(value: []const u8) !void {
    const fields = [_]response_headers.Field{.{
        .name = "content-encoding",
        .value = value,
    }};
    const headers = FakeHeaders{ .fields = &fields };
    _ = try analyze(&headers);
}

fn expectRejectedCoding(value: []const u8) !void {
    const fields = [_]response_headers.Field{.{
        .name = "content-encoding",
        .value = value,
    }};
    const headers = FakeHeaders{ .fields = &fields };
    try std.testing.expectError(error.InvalidHeader, analyze(&headers));
}

const fuzz_corpus = struct {
    const absent = fuzz_support.smithInput("\x00plain\x00value\x00other\x00value");
    const gzip = fuzz_support.smithInput("\x55gzip\x00*, Accept-Language\x00br\x00accept-encoding");
    const malformed = fuzz_support.smithInput("\xffgzip;q=1\x00Accept Encoding\x00\r\n\x00,");
    const empty = fuzz_support.smithInput("\xaa,\x00\x00,,\x00\t");

    const values = [_][]const u8{ &absent, &gzip, &malformed, &empty };
}.values;

fn fuzzOverlay(_: void, smith: *std.testing.Smith) !void {
    var storage: [512]u8 = undefined;
    const bytes = storage[0..smith.slice(&storage)];
    const flags = if (bytes.len == 0) 0 else bytes[0];
    const payload = if (bytes.len > 1) bytes[1..] else "";
    var values = [_][]const u8{""} ** 4;
    var iterator = std.mem.splitScalar(u8, payload, 0);
    for (&values) |*value| value.* = iterator.next() orelse "";

    var fields: [4]response_headers.Field = undefined;
    for (&fields, 0..) |*field, index| {
        field.* = .{
            .name = fuzzFieldName(flags, index),
            .value = values[index],
        };
    }
    const count: usize = (flags >> 4) % (fields.len + 1);
    const headers = FakeHeaders{ .fields = fields[0..count] };
    const fields_before = fields;
    const result = analyze(&headers);
    const repeated = analyze(&headers);
    try expectSameAnalysis(result, repeated);
    try std.testing.expectEqualDeep(fields_before, fields);

    const analysis = result catch return;
    const selection = Selection{
        .framework_gzip = flags & 0x01 != 0,
        .negotiation_varies = flags & 0x02 != 0,
    };
    const plan = analysis.plan(selection);
    const view = overlay(&headers, plan);
    try std.testing.expectEqual(count + plan.addedFields(), view.len());
    for (0..count) |index| {
        try std.testing.expectEqualDeep(fields[index], view.at(index));
    }
    var index = count;
    if (plan.append_gzip) {
        try std.testing.expectEqualDeep(gzip_field, view.at(index));
        index += 1;
    }
    if (plan.append_vary_accept_encoding) {
        try std.testing.expectEqualDeep(vary_accept_encoding_field, view.at(index));
        index += 1;
    }
    try std.testing.expectEqual(view.len(), index);
}

fn fuzzFieldName(flags: u8, index: usize) []const u8 {
    const shift: u3 = @intCast((index * 2) % 8);
    return switch ((flags >> shift) & 0x03) {
        0 => "content-encoding",
        1 => "Vary",
        2 => "x-test",
        3 => "CONTENT-ENCODING",
        else => unreachable,
    };
}

fn expectSameAnalysis(first: Error!Analysis, second: Error!Analysis) !void {
    if (first) |left| {
        try std.testing.expectEqualDeep(left, try second);
    } else |left_error| {
        try std.testing.expectError(left_error, second);
    }
}
