const std = @import("std");
const Static = @import("../../src/static_file.zig");
const static_http = @import("../../src/internal/static/http.zig");

const classic_second: i64 = 784_111_777;
const current_second: i64 = 1_784_032_496;

fn validatorsAt(second: i64, size: u64) !Static.Validators {
    return Static.buildValidators(.{
        .device_major = 8,
        .device_minor = 1,
        .inode = 0xabc,
        .size = size,
        .mtime_seconds = second,
        .mtime_nanoseconds = 42,
    }, current_second);
}

test "weak validator and Last-Modified use exact stat identity" {
    const validators = try validatorsAt(0, 123);
    try std.testing.expectEqualStrings("W/\"8-1-abc-7b-0-2a\"", validators.etag());
    try std.testing.expectEqualStrings(
        "Thu, 01 Jan 1970 00:00:00 GMT",
        validators.lastModified(),
    );
    try std.testing.expectError(error.InvalidNanoseconds, Static.buildValidators(.{
        .device_major = 0,
        .device_minor = 0,
        .inode = 0,
        .size = 0,
        .mtime_seconds = 0,
        .mtime_nanoseconds = std.time.ns_per_s,
    }, current_second));
    const pre_epoch = try Static.buildValidators(.{
        .device_major = 0,
        .device_minor = 0,
        .inode = 0,
        .size = 0,
        .mtime_seconds = -1,
        .mtime_nanoseconds = 0,
    }, current_second);
    try std.testing.expectEqualStrings("W/\"0-0-0-0--1-0\"", pre_epoch.etag());
    try std.testing.expectEqualStrings(
        "Thu, 01 Jan 1970 00:00:00 GMT",
        pre_epoch.lastModified(),
    );
    try expectPrecondition(.not_modified, &pre_epoch, .{
        .if_modified_since = "Thu, 01 Jan 1970 00:00:00 GMT",
    });
    try std.testing.expectError(error.TimestampOutOfRange, Static.buildValidators(.{
        .device_major = 0,
        .device_minor = 0,
        .inode = 0,
        .size = 0,
        .mtime_seconds = 0,
        .mtime_nanoseconds = 0,
    }, -1));
}

test "future filesystem time is clamped to response Date" {
    const validators = try Static.buildValidators(.{
        .device_major = 8,
        .device_minor = 1,
        .inode = 0xabc,
        .size = 100,
        .mtime_seconds = current_second + 10,
        .mtime_nanoseconds = 42,
    }, current_second);
    try std.testing.expectEqualStrings("Tue, 14 Jul 2026 12:34:56 GMT", validators.lastModified());
    try std.testing.expectEqualStrings("W/\"8-1-abc-64-6a562cfa-2a\"", validators.etag());
    try expectPrecondition(.not_modified, &validators, .{
        .if_modified_since = "Tue, 14 Jul 2026 12:34:56 GMT",
    });
}

test "GET and HEAD preconditions follow RFC ordering" {
    const validators = try validatorsAt(classic_second, 100);
    const etag = "W/\"8-1-abc-64-2ebc98a1-2a\"";
    try std.testing.expectEqualStrings(etag, validators.etag());

    try expectPrecondition(.proceed, &validators, .{ .if_match = "*" });
    try expectPrecondition(.precondition_failed, &validators, .{ .if_match = etag });
    try expectPrecondition(.precondition_failed, &validators, .{
        .if_match = "\"8-1-abc-64-2ebc98a1-2a\"",
    });
    try expectPrecondition(.precondition_failed, &validators, .{ .if_match = "malformed" });
    try expectPrecondition(.proceed, &validators, .{
        .if_match = "*",
        .if_unmodified_since = "Thu, 01 Jan 1970 00:00:00 GMT",
    });
    try expectPrecondition(.precondition_failed, &validators, .{
        .if_unmodified_since = "Thu, 01 Jan 1970 00:00:00 GMT",
    });

    try expectPrecondition(.not_modified, &validators, .{ .if_none_match = etag });
    try expectPrecondition(.not_modified, &validators, .{
        .if_none_match = "\"other,tag\", " ++ etag,
    });
    try expectPrecondition(.not_modified, &validators, .{ .if_none_match = "*" });
    try expectPrecondition(.not_modified, &validators, .{
        .if_none_match = "\"8-1-abc-64-2ebc98a1-2a\"",
    });
    try expectPrecondition(.proceed, &validators, .{ .if_none_match = "malformed" });
    try expectPrecondition(.proceed, &validators, .{
        .if_none_match = etag ++ ", malformed",
    });
    try expectPrecondition(.proceed, &validators, .{
        .if_none_match = "\"different\"",
        .if_modified_since = "Sun, 06 Nov 2094 08:49:37 GMT",
    });
    try expectPrecondition(.not_modified, &validators, .{
        .if_modified_since = "Sun, 06 Nov 1994 08:49:37 GMT",
    });
    try expectPrecondition(.proceed, &validators, .{
        .if_modified_since = "Thu, 01 Jan 1970 00:00:00 GMT",
    });
}

test "repeated conditional fields aggregate strictly and retain precedence" {
    const validators = try validatorsAt(classic_second, 100);
    const etag = "W/\"8-1-abc-64-2ebc98a1-2a\"";
    const future = "Sun, 06 Nov 2094 08:49:37 GMT";

    try expectRequestPrecondition(.precondition_failed, &validators, .{
        .if_match = &.{ "*", "\"other\"" },
    });
    try expectRequestPrecondition(.precondition_failed, &validators, .{
        .if_match = &.{ "*", "*" },
    });
    try expectRequestPrecondition(.not_modified, &validators, .{
        .if_none_match = &.{ "\"other\"", etag },
    });
    try expectRequestPrecondition(.proceed, &validators, .{
        .if_none_match = &.{ "*", "\"other\"" },
        .if_modified_since = &.{future},
    });
    try expectRequestPrecondition(.proceed, &validators, .{
        .if_none_match = &.{ "malformed", etag },
        .if_modified_since = &.{future},
    });
    try expectRequestPrecondition(.proceed, &validators, .{
        .if_none_match = &.{ "\"other\"", "\"different\"" },
        .if_modified_since = &.{future},
    });
}

test "all three HTTP-date forms have one exact epoch" {
    const dates = [_][]const u8{
        "Sun, 06 Nov 1994 08:49:37 GMT",
        "Sunday, 06-Nov-94 08:49:37 GMT",
        "Sun Nov  6 08:49:37 1994",
    };
    for (dates) |date| {
        try std.testing.expectEqual(classic_second, static_http.parseHttpDate(date, 2026).?);
    }
    try std.testing.expectEqual(
        @as(?i64, null),
        static_http.parseHttpDate("Sun, 31 Feb 1994 08:49:37 GMT", 2026),
    );
    try std.testing.expectEqual(
        @as(?i64, null),
        static_http.parseHttpDate("Sunday, 06-Nov-94 08:49:60 GMT", 2026),
    );
}

test "single byte ranges cover closed open suffix and clamped forms" {
    const validators = try validatorsAt(classic_second, 100);
    try expectComplete(&validators, .get, null, null, 0, 100, true);
    try expectComplete(&validators, .head, null, null, 0, 100, false);
    try expectPartial(&validators, .get, "bytes=0-9", null, 0, 10, true, "bytes 0-9/100");
    try expectPartial(&validators, .get, "bytes=90-", null, 90, 10, true, "bytes 90-99/100");
    try expectPartial(&validators, .get, "bytes=-10", null, 90, 10, true, "bytes 90-99/100");
    try expectPartial(&validators, .get, "bytes=-500", null, 0, 100, true, "bytes 0-99/100");
    try expectPartial(&validators, .get, "bytes=90-500", null, 90, 10, true, "bytes 90-99/100");
    try expectComplete(&validators, .head, "bytes=1-2", null, 0, 100, false);
    try expectComplete(&validators, .head, "bytes=100-", null, 0, 100, false);
}

test "unsatisfiable range emits exact 416 Content-Range" {
    const validators = try validatorsAt(classic_second, 100);
    const values = [_][]const u8{ "bytes=100-", "bytes=-0" };
    for (values) |value| {
        const decision = Static.evaluateRange(.get, &validators, value, null);
        var output: [Static.content_range_bytes_max]u8 = undefined;
        try std.testing.expectEqualStrings(
            "bytes */100",
            try decision.unsatisfiable.write(&output),
        );
    }
    const empty = try validatorsAt(classic_second, 0);
    try expectComplete(&empty, .get, null, null, 0, 0, false);
    const decision = Static.evaluateRange(.get, &empty, "bytes=0-", null);
    var output: [Static.content_range_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings("bytes */0", try decision.unsatisfiable.write(&output));
}

test "malformed unsupported and multiple ranges are ignored" {
    const validators = try validatorsAt(classic_second, 100);
    const values = [_][]const u8{
        "items=0-1",
        "bytes=",
        "bytes=0-1,2-3",
        "bytes=0--1",
        "bytes=9-8",
        "bytes=x-1",
        "bytes=18446744073709551616-",
        "bytes = 0-1",
        "bytes= 0-1",
        "bytes=\t0-1",
        "bytes=0 -1",
        "bytes=0- 1",
    };
    for (values) |value| {
        try expectComplete(&validators, .get, value, null, 0, 100, true);
    }
}

test "If-Range fails to full transfer without a provably strong validator" {
    const validators = try validatorsAt(classic_second, 100);
    try expectComplete(
        &validators,
        .get,
        "bytes=0-9",
        validators.etag(),
        0,
        100,
        true,
    );
    try expectComplete(
        &validators,
        .get,
        "bytes=0-9",
        "\"8-1-abc-64-2ebc98a1-2a\"",
        0,
        100,
        true,
    );
    try expectComplete(
        &validators,
        .get,
        "bytes=0-9",
        "Sun, 06 Nov 1994 08:49:37 GMT",
        0,
        100,
        true,
    );
    try expectComplete(
        &validators,
        .get,
        "bytes=0-9",
        "Thu, 01 Jan 1970 00:00:00 GMT",
        0,
        100,
        true,
    );
}

fn expectPrecondition(
    expected: Static.PreconditionDecision,
    validators: *const Static.Validators,
    fields: Static.Preconditions,
) !void {
    try std.testing.expectEqual(
        expected,
        Static.evaluatePreconditions(validators, fields, 2026),
    );
}

const TestHeaderValues = struct {
    values: []const []const u8,

    pub fn count(values: TestHeaderValues) usize {
        return values.values.len;
    }

    pub fn first(values: TestHeaderValues) ?[]const u8 {
        return if (values.values.len == 0) null else values.values[0];
    }

    pub fn one(values: TestHeaderValues) error{InvalidCardinality}![]const u8 {
        if (values.values.len != 1) return error.InvalidCardinality;
        return values.values[0];
    }

    pub fn iterator(values: TestHeaderValues) Iterator {
        return .{ .values = values.values };
    }

    const Iterator = struct {
        values: []const []const u8,
        index: usize = 0,

        pub fn next(self: *Iterator) ?[]const u8 {
            if (self.index == self.values.len) return null;
            defer self.index += 1;
            return self.values[self.index];
        }
    };
};

const TestHeaders = struct {
    if_match: []const []const u8 = &.{},
    if_unmodified_since: []const []const u8 = &.{},
    if_none_match: []const []const u8 = &.{},
    if_modified_since: []const []const u8 = &.{},

    pub fn all(headers: TestHeaders, name: []const u8) TestHeaderValues {
        if (std.mem.eql(u8, name, "If-Match")) return .{ .values = headers.if_match };
        if (std.mem.eql(u8, name, "If-Unmodified-Since")) {
            return .{ .values = headers.if_unmodified_since };
        }
        if (std.mem.eql(u8, name, "If-None-Match")) {
            return .{ .values = headers.if_none_match };
        }
        if (std.mem.eql(u8, name, "If-Modified-Since")) {
            return .{ .values = headers.if_modified_since };
        }
        return .{ .values = &.{} };
    }
};

fn expectRequestPrecondition(
    expected: Static.PreconditionDecision,
    validators: *const Static.Validators,
    headers: TestHeaders,
) !void {
    try std.testing.expectEqual(
        expected,
        Static.evaluateRequestPreconditions(validators, headers, 2026),
    );
}

fn expectComplete(
    validators: *const Static.Validators,
    method: Static.Method,
    range: ?[]const u8,
    if_range: ?[]const u8,
    offset: u64,
    length: u64,
    transfer_body: bool,
) !void {
    const decision = Static.evaluateRange(method, validators, range, if_range);
    try std.testing.expectEqual(offset, decision.complete.offset);
    try std.testing.expectEqual(length, decision.complete.length);
    try std.testing.expectEqual(transfer_body, decision.complete.transfer_body);
}

fn expectPartial(
    validators: *const Static.Validators,
    method: Static.Method,
    range: []const u8,
    if_range: ?[]const u8,
    offset: u64,
    length: u64,
    transfer_body: bool,
    content_range: []const u8,
) !void {
    const decision = Static.evaluateRange(method, validators, range, if_range);
    try std.testing.expectEqual(offset, decision.partial.span.offset);
    try std.testing.expectEqual(length, decision.partial.span.length);
    try std.testing.expectEqual(transfer_body, decision.partial.span.transfer_body);
    var output: [Static.content_range_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings(
        content_range,
        try decision.partial.content_range.write(&output),
    );
}
