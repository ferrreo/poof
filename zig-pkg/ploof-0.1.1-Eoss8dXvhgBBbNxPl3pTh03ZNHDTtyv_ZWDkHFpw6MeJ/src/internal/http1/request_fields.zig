const std = @import("std");
const limits = @import("limits.zig");
const request_head = @import("request_head.zig");
const syntax = @import("syntax.zig");

pub const OneError = error{
    Missing,
    Multiple,
};

pub const View = struct {
    bytes: []const u8,
    fields: []const request_head.Field,
    name: []const u8,
    matches_count: usize,

    pub fn count(self: View) usize {
        return self.matches_count;
    }

    pub fn first(self: View) ?[]const u8 {
        var values = self.iterator();
        return values.next();
    }

    pub fn one(self: View) OneError![]const u8 {
        return switch (self.matches_count) {
            0 => error.Missing,
            1 => self.first().?,
            else => error.Multiple,
        };
    }

    pub fn iterator(self: View) Iterator {
        return .{
            .bytes = self.bytes,
            .fields = self.fields,
            .name = self.name,
        };
    }
};

pub const Iterator = struct {
    bytes: []const u8,
    fields: []const request_head.Field,
    name: []const u8,
    index: usize = 0,

    pub fn next(self: *Iterator) ?[]const u8 {
        while (self.index < self.fields.len) {
            const field = self.fields[self.index];
            self.index += 1;
            if (syntax.eqlIgnoreCase(field.name.slice(self.bytes), self.name)) {
                return field.value.slice(self.bytes);
            }
        }
        return null;
    }
};

pub const RawField = struct {
    name: []const u8,
    value: []const u8,
};

pub const RawView = struct {
    bytes: []const u8,
    fields: []const request_head.Field,

    pub fn count(self: RawView) usize {
        return self.fields.len;
    }

    pub fn iterator(self: RawView) RawIterator {
        return .{ .bytes = self.bytes, .fields = self.fields };
    }
};

pub const RawIterator = struct {
    bytes: []const u8,
    fields: []const request_head.Field,
    index: usize = 0,

    pub fn next(self: *RawIterator) ?RawField {
        if (self.index == self.fields.len) return null;
        const field = self.fields[self.index];
        self.index += 1;
        return .{
            .name = field.name.slice(self.bytes),
            .value = field.raw_value.slice(self.bytes),
        };
    }
};

pub fn all(
    bytes: []const u8,
    fields: []const request_head.Field,
    name: []const u8,
) View {
    var matches: usize = 0;
    for (fields) |field| {
        if (syntax.eqlIgnoreCase(field.name.slice(bytes), name)) matches += 1;
    }
    return .{
        .bytes = bytes,
        .fields = fields,
        .name = name,
        .matches_count = matches,
    };
}

pub fn one(
    bytes: []const u8,
    fields: []const request_head.Field,
    name: []const u8,
) OneError![]const u8 {
    var found: ?[]const u8 = null;
    for (fields) |field| {
        if (!syntax.eqlIgnoreCase(field.name.slice(bytes), name)) continue;
        if (found != null) return error.Multiple;
        found = field.value.slice(bytes);
    }
    return found orelse error.Missing;
}

pub fn raw(bytes: []const u8, fields: []const request_head.Field) RawView {
    return .{ .bytes = bytes, .fields = fields };
}

const example_request =
    "GET / HTTP/1.1\r\n" ++
    "hOsT: example.test\r\n" ++
    "X-Test:  first \t\r\n" ++
    "x-TEST:\tsecond\r\n" ++
    "X-Other: \x80raw\xff\r\n" ++
    "X-Test:third\r\n" ++
    "\r\n";

test "multi-value view makes cardinality and order explicit" {
    const Parser = request_head.Decoder(limits.standard_request_head_limits);
    var parser = Parser.init();
    try expectReady(parser.feed(example_request));

    const tests = all(parser.bytes(), parser.fields(), "x-tEsT");
    try std.testing.expectEqual(@as(usize, 3), tests.count());
    try std.testing.expectEqualStrings("first", tests.first().?);
    try std.testing.expectError(error.Multiple, tests.one());

    var values = tests.iterator();
    try std.testing.expectEqualStrings("first", values.next().?);
    try std.testing.expectEqualStrings("second", values.next().?);
    try std.testing.expectEqualStrings("third", values.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), values.next());

    const one_value = all(parser.bytes(), parser.fields(), "X-OTHER");
    try std.testing.expectEqual(@as(usize, 1), one_value.count());
    try std.testing.expectEqualStrings("\x80raw\xff", try one_value.one());
    try std.testing.expectEqualStrings(
        "\x80raw\xff",
        try one(parser.bytes(), parser.fields(), "X-OTHER"),
    );
    try std.testing.expectError(
        error.Multiple,
        one(parser.bytes(), parser.fields(), "X-Test"),
    );
    try std.testing.expectError(
        error.Missing,
        one(parser.bytes(), parser.fields(), "X-Missing"),
    );

    const absent = all(parser.bytes(), parser.fields(), "x-absent");
    try std.testing.expectEqual(@as(usize, 0), absent.count());
    try std.testing.expectEqual(@as(?[]const u8, null), absent.first());
    try std.testing.expectError(error.Missing, absent.one());
}

test "raw view preserves casing whitespace obs-text and wire order" {
    const Parser = request_head.Decoder(limits.standard_request_head_limits);
    var parser = Parser.init();
    try expectReady(parser.feed(example_request));

    const expected = [_]RawField{
        .{ .name = "hOsT", .value = " example.test" },
        .{ .name = "X-Test", .value = "  first \t" },
        .{ .name = "x-TEST", .value = "\tsecond" },
        .{ .name = "X-Other", .value = " \x80raw\xff" },
        .{ .name = "X-Test", .value = "third" },
    };
    const raw_fields = raw(parser.bytes(), parser.fields());
    try std.testing.expectEqual(expected.len, raw_fields.count());

    var fields = raw_fields.iterator();
    for (expected) |wanted| {
        const field = fields.next().?;
        try std.testing.expectEqualStrings(wanted.name, field.name);
        try std.testing.expectEqualStrings(wanted.value, field.value);
    }
    try std.testing.expectEqual(@as(?RawField, null), fields.next());
}

fn expectReady(result: request_head.FeedResult) !void {
    switch (result.state) {
        .ready => {},
        else => return error.TestUnexpectedResult,
    }
}
