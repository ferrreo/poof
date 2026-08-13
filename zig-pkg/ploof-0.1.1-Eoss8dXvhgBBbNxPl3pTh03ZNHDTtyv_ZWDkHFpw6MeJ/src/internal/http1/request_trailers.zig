const std = @import("std");
const request_head = @import("request_head.zig");
const status_module = @import("status.zig");
const syntax = @import("syntax.zig");
pub const names_hard_max: u16 = 1024;
pub const standard_names_max: u16 = 32;
pub const empty_declaration_members_max: u8 = 32;
pub const section_bytes_hard_max: u32 = 1024 * 1024;
pub const fields_hard_max: u16 = 1024;
const empty_lookup_slot = std.math.maxInt(u16);
pub const DeclarationError = error{
    Invalid,
    TooMany,
    Duplicate,
    Forbidden,
};
pub const LimitIssue = enum(u8) {
    section_bytes_zero,
    section_bytes_above_hard_max,
    field_line_bytes_zero,
    field_line_bytes_above_hard_max,
    field_line_bytes_above_section_max,
    fields_zero,
    fields_above_hard_max,
};
pub const Limits = struct {
    section_bytes_max: u32 = 8 * 1024,
    field_line_bytes_max: u32 = 4 * 1024,
    fields_max: u16 = 32,
    pub fn issue(limits: Limits) ?LimitIssue {
        const section_max = limits.section_bytes_max;
        const field_max = limits.field_line_bytes_max;
        if (section_max == 0) return .section_bytes_zero;
        if (section_max > section_bytes_hard_max) return .section_bytes_above_hard_max;
        if (field_max == 0) return .field_line_bytes_zero;
        if (field_max > section_bytes_hard_max) return .field_line_bytes_above_hard_max;
        if (field_max > section_max) return .field_line_bytes_above_section_max;
        if (limits.fields_max == 0) return .fields_zero;
        if (limits.fields_max > fields_hard_max) return .fields_above_hard_max;
        return null;
    }
    pub fn validate(comptime limits: Limits) Limits {
        if (limits.issue()) |problem| @compileError(limitIssueMessage(problem));
        return limits;
    }
};
pub const standard_limits = Limits.validate(.{});
pub fn Declarations(comptime names_max: u16) type {
    validateNamesMax(names_max);
    return struct {
        const Self = @This();
        const lookup_capacity = std.math.ceilPowerOfTwoAssert(usize, @as(usize, names_max) * 2);
        names_storage: [names_max]request_head.Span = undefined,
        fingerprints_storage: [names_max]u64 = undefined,
        lookup_storage: [lookup_capacity]u16 = @splat(empty_lookup_slot),
        names_count: u16 = 0,
        pub fn parse(
            fields: []const request_head.Field,
            head_bytes: []const u8,
        ) DeclarationError!Self {
            var declarations = Self{};
            try parseDeclarations(&declarations, fields, head_bytes);
            return declarations;
        }

        pub fn contains(
            self: *const Self,
            head_bytes: []const u8,
            name: []const u8,
        ) bool {
            return findDeclaration(self, head_bytes, nameFingerprint(name), name).found;
        }

        pub fn names(self: *const Self) []const request_head.Span {
            return self.names_storage[0..self.names_count];
        }

        pub fn count(self: *const Self) u16 {
            return self.names_count;
        }
    };
}

pub const StandardDeclarations = Declarations(standard_names_max);
pub const Status = status_module.Status;
pub const Rejection = struct {
    status: Status,
    close: bool = true,
};
pub const Event = union(enum) {
    need_more,
    ready,
    rejected: Rejection,
};

pub const FeedResult = struct {
    consumed: usize,
    event: Event,
};

const Terminal = enum(u8) {
    receiving,
    ready,
    rejected,
};

const LineStep = enum(u8) {
    progress,
    field_complete,
    ready,
    bad_request,
};

pub fn Decoder(comptime limits: Limits, comptime names_max: u16) type {
    _ = limits.validate();
    validateNamesMax(names_max);
    const DeclarationSet = Declarations(names_max);

    return struct {
        const Self = @This();

        declarations: DeclarationSet,
        head_bytes: []const u8,
        bytes_storage: [limits.section_bytes_max]u8 = undefined,
        fields_storage: [limits.fields_max]request_head.Field = undefined,
        bytes_count: usize = 0,
        fields_count: usize = 0,
        line_start: usize = 0,
        line_bytes: usize = 0,
        wire_bytes: u64 = 0,
        wire_bytes_max: u64,
        terminal: Terminal = .receiving,
        rejection_status: Status = .bad_request,

        pub fn init(
            declarations: DeclarationSet,
            head_bytes: []const u8,
            encoded_wire_bytes_remaining: u64,
        ) Self {
            return .{
                .declarations = declarations,
                .head_bytes = head_bytes,
                .wire_bytes_max = encoded_wire_bytes_remaining,
            };
        }

        pub fn feed(self: *Self, input: []const u8) FeedResult {
            return decoderFeed(self, input, limits);
        }

        pub fn wireBytesConsumed(self: *const Self) u64 {
            return self.wire_bytes;
        }

        pub fn bytes(self: *const Self) []const u8 {
            return self.bytes_storage[0..self.bytes_count];
        }

        pub fn fields(self: *const Self) []const request_head.Field {
            return self.fields_storage[0..self.fields_count];
        }
    };
}

pub const StandardDecoder = Decoder(standard_limits, standard_names_max);

const forbidden_names = [_][]const u8{
    "host",
    "content-length",
    "transfer-encoding",
    "trailer",
    "connection",
    "keep-alive",
    "proxy-connection",
    "te",
    "upgrade",
    "expect",
    "authorization",
    "proxy-authorization",
    "cookie",
    "content-encoding",
    "content-type",
    "content-range",
    "forwarded",
    "x-forwarded-for",
    "x-forwarded-host",
    "x-forwarded-proto",
    "via",
    "origin",
    "referer",
    "accept",
    "accept-encoding",
    "accept-language",
    "cache-control",
    "pragma",
    "range",
    "if-match",
    "if-none-match",
    "if-modified-since",
    "if-unmodified-since",
    "if-range",
    "max-forwards",
};
fn parseDeclarations(
    declarations: anytype,
    fields: []const request_head.Field,
    head_bytes: []const u8,
) DeclarationError!void {
    var empty_members: u8 = 0;
    for (fields) |field| {
        if (!syntax.eqlIgnoreCase(field.name.slice(head_bytes), "trailer")) continue;
        try parseDeclarationValue(declarations, field.value, head_bytes, &empty_members);
    }
}
fn parseDeclarationValue(
    declarations: anytype,
    value_span: request_head.Span,
    head_bytes: []const u8,
    empty_members: *u8,
) DeclarationError!void {
    const value = value_span.slice(head_bytes);
    var index: usize = 0;
    while (true) {
        skipOws(value, &index);
        const start = index;
        while (index < value.len and syntax.isTokenByte(value[index])) : (index += 1) {}
        if (index != start) {
            const end = index;
            skipOws(value, &index);
            try addDeclaration(declarations, value_span, start, end, head_bytes);
        } else {
            if (empty_members.* == empty_declaration_members_max) return error.Invalid;
            empty_members.* += 1;
        }
        skipOws(value, &index);
        if (index < value.len and value[index] != ',') return error.Invalid;
        if (index == value.len) return;
        index += 1;
    }
}
fn addDeclaration(
    declarations: anytype,
    value_span: request_head.Span,
    start: usize,
    end: usize,
    head_bytes: []const u8,
) DeclarationError!void {
    const offset: usize = value_span.offset;
    const span = makeSpan(offset + start, end - start);
    const name = span.slice(head_bytes);
    if (isForbiddenName(name)) return error.Forbidden;
    const fingerprint = nameFingerprint(name);
    const lookup = findDeclaration(declarations, head_bytes, fingerprint, name);
    if (lookup.found) return error.Duplicate;
    if (declarations.names_count == declarations.names_storage.len) return error.TooMany;
    const name_index = declarations.names_count;
    declarations.names_storage[name_index] = span;
    declarations.fingerprints_storage[name_index] = fingerprint;
    declarations.lookup_storage[lookup.slot] = name_index;
    declarations.names_count += 1;
}

const DeclarationLookup = struct { slot: usize, found: bool };

fn findDeclaration(
    declarations: anytype,
    head_bytes: []const u8,
    fingerprint: u64,
    name: []const u8,
) DeclarationLookup {
    const mask: u64 = declarations.lookup_storage.len - 1;
    var slot: usize = @intCast(fingerprint & mask);
    var probes: usize = 0;
    while (probes < declarations.lookup_storage.len) : (probes += 1) {
        const name_index = declarations.lookup_storage[slot];
        if (name_index == empty_lookup_slot) return .{ .slot = slot, .found = false };
        if (declarations.fingerprints_storage[name_index] == fingerprint and
            syntax.eqlIgnoreCase(declarations.names_storage[name_index].slice(head_bytes), name))
        {
            return .{ .slot = slot, .found = true };
        }
        slot = (slot + 1) & (declarations.lookup_storage.len - 1);
    }
    unreachable;
}

fn nameFingerprint(name: []const u8) u64 {
    var fingerprint: u64 = 0xcbf29ce484222325;
    for (name) |byte| {
        fingerprint ^= syntax.asciiLower(byte);
        fingerprint *%= 0x100000001b3;
    }
    return fingerprint;
}

fn isForbiddenName(name: []const u8) bool {
    for (forbidden_names) |forbidden| if (syntax.eqlIgnoreCase(name, forbidden)) return true;
    return false;
}

fn decoderFeed(self: anytype, input: []const u8, comptime limits: Limits) FeedResult {
    switch (self.terminal) {
        .ready => return .{ .consumed = 0, .event = .ready },
        .rejected => return rejectedResult(self, 0),
        .receiving => {},
    }
    if (!completionFits(self)) return rejectDecoder(self, 0, .payload_too_large);

    var consumed: usize = 0;
    while (consumed < input.len) {
        if (self.wire_bytes == self.wire_bytes_max) {
            return rejectDecoder(self, consumed, .payload_too_large);
        }
        if (self.bytes_count == self.bytes_storage.len or
            self.line_bytes == limits.field_line_bytes_max)
        {
            return rejectDecoder(self, consumed, .bad_request);
        }

        const byte = input[consumed];
        self.bytes_storage[self.bytes_count] = byte;
        self.bytes_count += 1;
        self.line_bytes += 1;
        self.wire_bytes += 1;
        consumed += 1;

        switch (consumeTrailerByte(self, byte)) {
            .ready => return .{ .consumed = consumed, .event = .ready },
            .bad_request => return rejectDecoder(self, consumed, .bad_request),
            .progress, .field_complete => {},
        }
        if (!completionFits(self)) {
            return rejectDecoder(self, consumed, .payload_too_large);
        }
        if (self.bytes_count == self.bytes_storage.len or
            self.line_bytes == limits.field_line_bytes_max)
        {
            return rejectDecoder(self, consumed, .bad_request);
        }
    }
    return .{ .consumed = consumed, .event = .need_more };
}

fn completionFits(self: anytype) bool {
    if (self.wire_bytes > self.wire_bytes_max) return false;
    return minimumCompletionBytes(self) <= self.wire_bytes_max - self.wire_bytes;
}

fn minimumCompletionBytes(self: anytype) u64 {
    if (self.line_bytes == 0) return 2;
    const last = self.bytes_storage[self.bytes_count - 1];
    if (self.line_bytes == 1 and last == '\r') return 1;
    return if (last == '\r') 3 else 4;
}

fn consumeTrailerByte(self: anytype, byte: u8) LineStep {
    if (byte == '\n') {
        if (self.line_bytes < 2 or self.bytes_storage[self.bytes_count - 2] != '\r') {
            return .bad_request;
        }
        return finishTrailerLine(self);
    }
    if (self.line_bytes >= 2 and self.bytes_storage[self.bytes_count - 2] == '\r') {
        return .bad_request;
    }
    return .progress;
}

fn finishTrailerLine(self: anytype) LineStep {
    const content_end = self.bytes_count - 2;
    if (content_end == self.line_start) {
        self.terminal = .ready;
        return .ready;
    }
    if (self.fields_count == self.fields_storage.len) return .bad_request;
    const field = parseTrailerField(self, self.line_start, content_end) orelse {
        return .bad_request;
    };
    self.fields_storage[self.fields_count] = field;
    self.fields_count += 1;
    self.line_start = self.bytes_count;
    self.line_bytes = 0;
    return .field_complete;
}

fn parseTrailerField(self: anytype, start: usize, end: usize) ?request_head.Field {
    const line = self.bytes_storage[start..end];
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const name = line[0..colon];
    const raw_value = line[colon + 1 ..];
    if (!syntax.isToken(name) or !syntax.isFieldValue(raw_value)) return null;
    if (isForbiddenName(name)) return null;
    if (!self.declarations.contains(self.head_bytes, name)) return null;

    const value = syntax.trimOws(raw_value);
    const raw_start = start + colon + 1;
    var leading_ows: usize = 0;
    while (leading_ows < raw_value.len and
        (raw_value[leading_ows] == ' ' or raw_value[leading_ows] == '\t'))
    {
        leading_ows += 1;
    }
    return .{
        .name = makeSpan(start, name.len),
        .raw_value = makeSpan(raw_start, raw_value.len),
        .value = makeSpan(raw_start + leading_ows, value.len),
    };
}

fn rejectDecoder(self: anytype, consumed: usize, status: Status) FeedResult {
    self.terminal = .rejected;
    self.rejection_status = status;
    return rejectedResult(self, consumed);
}

fn rejectedResult(self: anytype, consumed: usize) FeedResult {
    return .{
        .consumed = consumed,
        .event = .{ .rejected = .{ .status = self.rejection_status } },
    };
}

fn makeSpan(offset: usize, length: usize) request_head.Span {
    return .{ .offset = @intCast(offset), .length = @intCast(length) };
}

fn skipOws(bytes: []const u8, index: *usize) void {
    while (index.* < bytes.len and
        (bytes[index.*] == ' ' or bytes[index.*] == '\t'))
    {
        index.* += 1;
    }
}

fn validateNamesMax(comptime names_max: u16) void {
    if (names_max == 0) @compileError("trailer declaration name limit must be nonzero");
    if (names_max > names_hard_max) @compileError("trailer declaration name limit exceeds 1024");
}

fn limitIssueMessage(problem: LimitIssue) []const u8 {
    return switch (problem) {
        .section_bytes_zero => "trailer section byte limit must be nonzero",
        .section_bytes_above_hard_max => "trailer section byte limit exceeds 1 MiB",
        .field_line_bytes_zero => "trailer field-line byte limit must be nonzero",
        .field_line_bytes_above_hard_max => "trailer field-line byte limit exceeds 1 MiB",
        .field_line_bytes_above_section_max => "trailer field-line limit exceeds section limit",
        .fields_zero => "trailer field count limit must be nonzero",
        .fields_above_hard_max => "trailer field count limit exceeds 1024",
    };
}

const declarations_head = "GET / HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Trailer: X-One, X-Obs\r\n\r\n";
const valid_section = "X-One: first\r\nX-One:\tsecond \t\r\nX-Obs: \x80\xff\r\n\r\n";

test "parses all declaration fields and compares names without case" {
    const head = "GET / HTTP/1.1\r\nHost: x\r\n" ++
        "Trailer: ,Foo,,\tBar,\r\nTrailer: ,Baz,,\r\nTrailer:\r\n\r\n";
    const Parser = request_head.Decoder(@import("limits.zig").standard_request_head_limits);
    var parser = Parser.init();
    try expectHeadReady(&parser, head);

    const declarations = try StandardDeclarations.parse(parser.fields(), parser.bytes());
    try std.testing.expectEqual(@as(u16, 3), declarations.count());
    try std.testing.expect(declarations.contains(parser.bytes(), "foo"));
    try std.testing.expect(declarations.contains(parser.bytes(), "BAR"));
    try std.testing.expect(declarations.contains(parser.bytes(), "Baz"));
    try std.testing.expect(!declarations.contains(parser.bytes(), "other"));

    var collision = StandardDeclarations{ .names_count = 1 };
    collision.names_storage[0] = makeSpan(0, 3);
    const fingerprint = nameFingerprint("bar");
    collision.fingerprints_storage[0] = fingerprint;
    const slot: usize = @intCast(fingerprint & (collision.lookup_storage.len - 1));
    collision.lookup_storage[slot] = 0;
    try std.testing.expect(!collision.contains("foo", "bar"));
}

test "rejects invalid duplicate excessive and forbidden declarations" {
    const prefix = "GET / HTTP/1.1\r\nHost: x\r\n";
    const cases = [_]struct { input: []const u8, expected: DeclarationError }{
        .{ .input = prefix ++ "Trailer: Bad Name\r\n\r\n", .expected = error.Invalid },
        .{ .input = prefix ++ "Trailer: Foo,foo\r\n\r\n", .expected = error.Duplicate },
        .{
            .input = prefix ++ "Trailer: Foo\r\nTrailer: fOo\r\n\r\n",
            .expected = error.Duplicate,
        },
        .{ .input = prefix ++ "Trailer: Host\r\n\r\n", .expected = error.Forbidden },
    };
    for (cases) |case| {
        try expectDeclarationError(standard_names_max, case.input, case.expected);
    }
    try expectDeclarationError(
        1,
        prefix ++ "Trailer: Foo,Bar\r\n\r\n",
        error.TooMany,
    );
}

test "indexes the hard maximum declaration set" {
    const alphabet = "abcdefghijklmnopqrstuvwxyz012345";
    var bytes: [8 + @as(usize, names_hard_max) * 4 - 1]u8 = undefined;
    @memcpy(bytes[0..8], "Trailer:");
    for (0..names_hard_max) |index| {
        const offset = 8 + index * 4;
        bytes[offset..][0..3].* = .{
            'x', alphabet[index / alphabet.len], alphabet[index % alphabet.len],
        };
        if (index + 1 < names_hard_max) bytes[offset + 3] = ',';
    }
    const value = makeSpan(8, bytes.len - 8);
    const field = request_head.Field{ .name = makeSpan(0, 7), .raw_value = value, .value = value };
    const declarations = try Declarations(names_hard_max).parse(&.{field}, &bytes);
    try std.testing.expectEqual(names_hard_max, declarations.count());
    try std.testing.expectEqual(@as(usize, names_hard_max) * 2, declarations.lookup_storage.len);
    for (0..names_hard_max) |index| {
        const offset = 8 + index * 4;
        try std.testing.expect(declarations.contains(&bytes, bytes[offset..][0..3]));
    }
}

test "forbidden declaration table contains the complete policy" {
    try std.testing.expectEqual(@as(usize, 35), forbidden_names.len);
    for (forbidden_names) |name| {
        try std.testing.expect(isForbiddenName(name));
        var upper: [32]u8 = undefined;
        if (name.len > upper.len) return error.TestUnexpectedResult;
        for (name, 0..) |byte, index| {
            upper[index] = if (byte >= 'a' and byte <= 'z') byte - 0x20 else byte;
        }
        try std.testing.expect(isForbiddenName(upper[0..name.len]));
    }
    try std.testing.expect(!isForbiddenName("x-application-trailer"));
}

test "decodes every split and one-byte fragments identically" {
    const Parser = request_head.Decoder(@import("limits.zig").standard_request_head_limits);
    var parser = Parser.init();
    try expectHeadReady(&parser, declarations_head);
    const declarations = try StandardDeclarations.parse(parser.fields(), parser.bytes());

    var split: usize = 0;
    while (split <= valid_section.len) : (split += 1) {
        var decoder = StandardDecoder.init(declarations, parser.bytes(), valid_section.len);
        if (split != 0) {
            try expectTrailerProgress(
                &decoder,
                valid_section[0..split],
                split == valid_section.len,
            );
        }
        if (split != valid_section.len) {
            try expectTrailerProgress(&decoder, valid_section[split..], true);
        }
        try expectValidFields(&decoder);
    }

    var decoder = StandardDecoder.init(declarations, parser.bytes(), valid_section.len);
    for (valid_section, 0..) |_, index| {
        try expectTrailerProgress(
            &decoder,
            valid_section[index .. index + 1],
            index + 1 == valid_section.len,
        );
    }
    try expectValidFields(&decoder);
}

test "accepts empty section and preserves pipeline remainder" {
    const Parser = request_head.Decoder(@import("limits.zig").standard_request_head_limits);
    var parser = Parser.init();
    try expectHeadReady(&parser, declarations_head);
    const declarations = try StandardDeclarations.parse(parser.fields(), parser.bytes());
    var decoder = StandardDecoder.init(declarations, parser.bytes(), 64);

    const input = "\r\nNEXT";
    const result = decoder.feed(input);
    try std.testing.expectEqual(@as(usize, 2), result.consumed);
    try std.testing.expect(result.event == .ready);
    try std.testing.expectEqualStrings("NEXT", input[result.consumed..]);
    try std.testing.expectEqual(@as(usize, 0), decoder.fields().len);
    try std.testing.expectEqualStrings("\r\n", decoder.bytes());

    const sticky = decoder.feed(input[result.consumed..]);
    try std.testing.expectEqual(@as(usize, 0), sticky.consumed);
    try std.testing.expect(sticky.event == .ready);
}

test "rejects undeclared forbidden and malformed trailer fields" {
    const Parser = request_head.Decoder(@import("limits.zig").standard_request_head_limits);
    var parser = Parser.init();
    try expectHeadReady(&parser, declarations_head);
    const declarations = try StandardDeclarations.parse(parser.fields(), parser.bytes());
    const cases = [_][]const u8{
        "X-Other: value\r\n\r\n",
        "Host: value\r\n\r\n",
        "Bad Name: value\r\n\r\n",
        "X-One : value\r\n\r\n",
        "X-One: bad\x00value\r\n\r\n",
        " folded\r\n\r\n",
        "X-One: value\n\n",
        "X-One: value\rx",
    };
    for (cases) |case| {
        try expectTrailerRejected(
            standard_limits,
            standard_names_max,
            declarations,
            parser.bytes(),
            4096,
            case,
            .bad_request,
        );
    }
}

test "enforces trailer line section and field count limits" {
    const Parser = request_head.Decoder(@import("limits.zig").standard_request_head_limits);
    var parser = Parser.init();
    try expectHeadReady(&parser, declarations_head);
    const declarations = try StandardDeclarations.parse(parser.fields(), parser.bytes());

    const line_limits = comptime Limits.validate(.{
        .section_bytes_max = 64,
        .field_line_bytes_max = 8,
        .fields_max = 4,
    });
    try expectTrailerRejected(
        line_limits,
        standard_names_max,
        declarations,
        parser.bytes(),
        64,
        "X-One: a\r\n\r\n",
        .bad_request,
    );

    const section_limits = comptime Limits.validate(.{
        .section_bytes_max = 9,
        .field_line_bytes_max = 8,
        .fields_max = 2,
    });
    try expectTrailerRejected(
        section_limits,
        standard_names_max,
        declarations,
        parser.bytes(),
        64,
        "X-One:\r\n\r\n",
        .bad_request,
    );

    const count_limits = comptime Limits.validate(.{
        .section_bytes_max = 64,
        .field_line_bytes_max = 32,
        .fields_max = 1,
    });
    try expectTrailerRejected(
        count_limits,
        standard_names_max,
        declarations,
        parser.bytes(),
        64,
        "X-One: a\r\nX-One: b\r\n\r\n",
        .bad_request,
    );
}

test "enforces remaining encoded-wire budget" {
    const Parser = request_head.Decoder(@import("limits.zig").standard_request_head_limits);
    var parser = Parser.init();
    try expectHeadReady(&parser, declarations_head);
    const declarations = try StandardDeclarations.parse(parser.fields(), parser.bytes());
    try expectTrailerRejected(
        standard_limits,
        standard_names_max,
        declarations,
        parser.bytes(),
        1,
        "\r\n",
        .payload_too_large,
    );
}

fn expectHeadReady(parser: anytype, input: []const u8) !void {
    const result = parser.feed(input);
    if (result.consumed != input.len) return error.TestUnexpectedResult;
    if (result.state != .ready) return error.TestUnexpectedResult;
}

fn expectDeclarationError(
    comptime names_max: u16,
    input: []const u8,
    expected: DeclarationError,
) !void {
    const Parser = request_head.Decoder(@import("limits.zig").standard_request_head_limits);
    var parser = Parser.init();
    try expectHeadReady(&parser, input);
    const DeclarationSet = Declarations(names_max);
    try std.testing.expectError(
        expected,
        DeclarationSet.parse(parser.fields(), parser.bytes()),
    );
}

fn expectTrailerProgress(decoder: anytype, input: []const u8, ready: bool) !void {
    const result = decoder.feed(input);
    try std.testing.expectEqual(input.len, result.consumed);
    try std.testing.expect(if (ready) result.event == .ready else result.event == .need_more);
}

fn expectValidFields(decoder: anytype) !void {
    const fields = decoder.fields();
    const bytes = decoder.bytes();
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("X-One", fields[0].name.slice(bytes));
    try std.testing.expectEqualStrings("first", fields[0].value.slice(bytes));
    try std.testing.expectEqualStrings("X-One", fields[1].name.slice(bytes));
    try std.testing.expectEqualStrings("second", fields[1].value.slice(bytes));
    try std.testing.expectEqualStrings("X-Obs", fields[2].name.slice(bytes));
    try std.testing.expectEqualStrings("\x80\xff", fields[2].value.slice(bytes));
    try std.testing.expectEqualStrings(valid_section, bytes);
    try std.testing.expectEqual(@as(u64, valid_section.len), decoder.wireBytesConsumed());
}

fn expectTrailerRejected(
    comptime limits: Limits,
    comptime names_max: u16,
    declarations: Declarations(names_max),
    head_bytes: []const u8,
    wire_bytes_remaining: u64,
    input: []const u8,
    status: Status,
) !void {
    const TrailerDecoder = Decoder(limits, names_max);
    var decoder = TrailerDecoder.init(declarations, head_bytes, wire_bytes_remaining);
    const result = decoder.feed(input);
    try expectRejection(result, status);
    const sticky = decoder.feed("ignored");
    try expectRejection(sticky, status);
    try std.testing.expectEqual(@as(usize, 0), sticky.consumed);
}

fn expectRejection(result: FeedResult, status: Status) !void {
    if (result.event != .rejected) return error.TestUnexpectedResult;
    const rejection = result.event.rejected;
    try std.testing.expectEqual(status, rejection.status);
    try std.testing.expect(rejection.close);
}
