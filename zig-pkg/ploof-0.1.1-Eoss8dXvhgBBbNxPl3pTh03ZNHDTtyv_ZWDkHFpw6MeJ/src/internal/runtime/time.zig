const std = @import("std");

pub const timeout_ns_max: u64 = @intCast(std.math.maxInt(i64));

pub const TimeoutProfileIssue = enum(u8) {
    startup_io_zero,
    startup_io_overflow,
    first_head_zero,
    first_head_overflow,
    keepalive_idle_zero,
    keepalive_idle_overflow,
    reused_head_progress_zero,
    reused_head_progress_overflow,
    body_inactivity_zero,
    body_inactivity_overflow,
    write_stall_zero,
    write_stall_overflow,
};

pub const TimeoutProfile = struct {
    /// Per-operation deadline for configured filesystem checks before readiness.
    startup_io_ns: u64 = 10 * std.time.ns_per_s,
    first_head_ns: u64 = 10 * std.time.ns_per_s,
    keepalive_idle_ns: u64 = 60 * std.time.ns_per_s,
    reused_head_progress_ns: u64 = 10 * std.time.ns_per_s,
    body_inactivity_ns: u64 = 60 * std.time.ns_per_s,
    write_stall_ns: u64 = 60 * std.time.ns_per_s,

    pub fn issue(profile: TimeoutProfile) ?TimeoutProfileIssue {
        if (profile.startup_io_ns == 0) return .startup_io_zero;
        if (profile.startup_io_ns > timeout_ns_max) return .startup_io_overflow;
        if (profile.first_head_ns == 0) return .first_head_zero;
        if (profile.first_head_ns > timeout_ns_max) return .first_head_overflow;
        if (profile.keepalive_idle_ns == 0) return .keepalive_idle_zero;
        if (profile.keepalive_idle_ns > timeout_ns_max) return .keepalive_idle_overflow;
        if (profile.reused_head_progress_ns == 0) return .reused_head_progress_zero;
        if (profile.reused_head_progress_ns > timeout_ns_max) {
            return .reused_head_progress_overflow;
        }
        if (profile.body_inactivity_ns == 0) return .body_inactivity_zero;
        if (profile.body_inactivity_ns > timeout_ns_max) return .body_inactivity_overflow;
        if (profile.write_stall_ns == 0) return .write_stall_zero;
        if (profile.write_stall_ns > timeout_ns_max) return .write_stall_overflow;
        return null;
    }

    pub fn validate(comptime profile: TimeoutProfile) TimeoutProfile {
        if (profile.issue()) |problem| @compileError(timeoutIssueMessage(problem));
        return profile;
    }
};

pub const standard_timeout_profile = TimeoutProfile.validate(.{});

pub const imf_fixdate_bytes = 29;
pub const max_http_epoch_second: i64 = 253_402_300_799;

pub const DateError = error{
    BeforeUnixEpoch,
    AfterYear9999,
};

const weekday_names = [_][3]u8{
    "Sun".*,
    "Mon".*,
    "Tue".*,
    "Wed".*,
    "Thu".*,
    "Fri".*,
    "Sat".*,
};

const month_names = [_][3]u8{
    "Jan".*,
    "Feb".*,
    "Mar".*,
    "Apr".*,
    "May".*,
    "Jun".*,
    "Jul".*,
    "Aug".*,
    "Sep".*,
    "Oct".*,
    "Nov".*,
    "Dec".*,
};

pub const ImfFixdateCache = struct {
    value: [imf_fixdate_bytes]u8 = "Thu, 01 Jan 1970 00:00:00 GMT".*,
    epoch_second: i64 = 0,

    /// Returns true only when value was rewritten.
    pub fn update(cache: *ImfFixdateCache, epoch_second: i64) DateError!bool {
        if (epoch_second < 0) return error.BeforeUnixEpoch;
        if (epoch_second > max_http_epoch_second) return error.AfterYear9999;
        if (cache.epoch_second == epoch_second) return false;

        cache.value = formatImfFixdateValid(@intCast(epoch_second));
        cache.epoch_second = epoch_second;
        return true;
    }

    pub fn slice(cache: *const ImfFixdateCache) []const u8 {
        return cache.value[0..];
    }
};

pub fn formatImfFixdate(epoch_second: i64) DateError![imf_fixdate_bytes]u8 {
    if (epoch_second < 0) return error.BeforeUnixEpoch;
    if (epoch_second > max_http_epoch_second) return error.AfterYear9999;
    return formatImfFixdateValid(@intCast(epoch_second));
}

fn formatImfFixdateValid(epoch_second: u64) [imf_fixdate_bytes]u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_second };
    const epoch_day = epoch.getEpochDay();
    const day_seconds = epoch.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const weekday: usize = @intCast((epoch_day.day + 4) % 7);
    const month: usize = @intFromEnum(month_day.month) - 1;

    var value: [imf_fixdate_bytes]u8 = undefined;
    @memcpy(value[0..3], &weekday_names[weekday]);
    value[3] = ',';
    value[4] = ' ';
    writeTwo(value[5..7], @as(u8, month_day.day_index) + 1);
    value[7] = ' ';
    @memcpy(value[8..11], &month_names[month]);
    value[11] = ' ';
    writeFour(value[12..16], year_day.year);
    value[16] = ' ';
    writeTwo(value[17..19], day_seconds.getHoursIntoDay());
    value[19] = ':';
    writeTwo(value[20..22], day_seconds.getMinutesIntoHour());
    value[22] = ':';
    writeTwo(value[23..25], day_seconds.getSecondsIntoMinute());
    value[25] = ' ';
    @memcpy(value[26..29], "GMT");
    return value;
}

fn writeTwo(destination: *[2]u8, value: u8) void {
    std.debug.assert(value < 100);
    destination.* = .{
        '0' + value / 10,
        '0' + value % 10,
    };
}

fn writeFour(destination: *[4]u8, value: u16) void {
    std.debug.assert(value < 10_000);
    destination.* = .{
        '0' + @as(u8, @intCast(value / 1_000)),
        '0' + @as(u8, @intCast(value / 100 % 10)),
        '0' + @as(u8, @intCast(value / 10 % 10)),
        '0' + @as(u8, @intCast(value % 10)),
    };
}

fn timeoutIssueMessage(problem: TimeoutProfileIssue) []const u8 {
    return switch (problem) {
        .startup_io_zero => "startup I/O timeout must be nonzero",
        .startup_io_overflow => "startup I/O timeout exceeds i64 nanoseconds",
        .first_head_zero => "first request-head timeout must be nonzero",
        .first_head_overflow => "first request-head timeout exceeds i64 nanoseconds",
        .keepalive_idle_zero => "keep-alive idle timeout must be nonzero",
        .keepalive_idle_overflow => "keep-alive idle timeout exceeds i64 nanoseconds",
        .reused_head_progress_zero => "reused request-head timeout must be nonzero",
        .reused_head_progress_overflow => {
            return "reused request-head timeout exceeds i64 nanoseconds";
        },
        .body_inactivity_zero => "request-body inactivity timeout must be nonzero",
        .body_inactivity_overflow => "request-body inactivity timeout exceeds i64 nanoseconds",
        .write_stall_zero => "response-write stall timeout must be nonzero",
        .write_stall_overflow => "response-write stall timeout exceeds i64 nanoseconds",
    };
}

test "standard timeout profile matches progress timeout contract" {
    const profile = standard_timeout_profile;
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_s), profile.startup_io_ns);
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_s), profile.first_head_ns);
    try std.testing.expectEqual(@as(u64, 60 * std.time.ns_per_s), profile.keepalive_idle_ns);
    try std.testing.expectEqual(
        @as(u64, 10 * std.time.ns_per_s),
        profile.reused_head_progress_ns,
    );
    try std.testing.expectEqual(@as(u64, 60 * std.time.ns_per_s), profile.body_inactivity_ns);
    try std.testing.expectEqual(@as(u64, 60 * std.time.ns_per_s), profile.write_stall_ns);
    try std.testing.expectEqual(@as(?TimeoutProfileIssue, null), profile.issue());
}

test "timeout profile accepts inclusive representation boundaries" {
    const smallest = TimeoutProfile{
        .startup_io_ns = 1,
        .first_head_ns = 1,
        .keepalive_idle_ns = 1,
        .reused_head_progress_ns = 1,
        .body_inactivity_ns = 1,
        .write_stall_ns = 1,
    };
    const largest = TimeoutProfile{
        .startup_io_ns = timeout_ns_max,
        .first_head_ns = timeout_ns_max,
        .keepalive_idle_ns = timeout_ns_max,
        .reused_head_progress_ns = timeout_ns_max,
        .body_inactivity_ns = timeout_ns_max,
        .write_stall_ns = timeout_ns_max,
    };
    try std.testing.expectEqual(@as(?TimeoutProfileIssue, null), smallest.issue());
    try std.testing.expectEqual(@as(?TimeoutProfileIssue, null), largest.issue());
}

test "timeout profile reports every zero and overflow boundary" {
    const overflow = timeout_ns_max + 1;
    try expectTimeoutIssue(.startup_io_zero, .{ .startup_io_ns = 0 });
    try expectTimeoutIssue(.startup_io_overflow, .{ .startup_io_ns = overflow });
    try expectTimeoutIssue(.first_head_zero, .{ .first_head_ns = 0 });
    try expectTimeoutIssue(.first_head_overflow, .{ .first_head_ns = overflow });
    try expectTimeoutIssue(.keepalive_idle_zero, .{ .keepalive_idle_ns = 0 });
    try expectTimeoutIssue(.keepalive_idle_overflow, .{ .keepalive_idle_ns = overflow });
    try expectTimeoutIssue(.reused_head_progress_zero, .{ .reused_head_progress_ns = 0 });
    try expectTimeoutIssue(.reused_head_progress_overflow, .{
        .reused_head_progress_ns = overflow,
    });
    try expectTimeoutIssue(.body_inactivity_zero, .{ .body_inactivity_ns = 0 });
    try expectTimeoutIssue(.body_inactivity_overflow, .{ .body_inactivity_ns = overflow });
    try expectTimeoutIssue(.write_stall_zero, .{ .write_stall_ns = 0 });
    try expectTimeoutIssue(.write_stall_overflow, .{ .write_stall_ns = overflow });
}

test "IMF-fixdate formats epoch leap dates and current 2026 date" {
    try expectDate(0, "Thu, 01 Jan 1970 00:00:00 GMT");
    try expectDate(951_827_696, "Tue, 29 Feb 2000 12:34:56 GMT");
    try expectDate(1_709_251_199, "Thu, 29 Feb 2024 23:59:59 GMT");
    try expectDate(1_784_032_496, "Tue, 14 Jul 2026 12:34:56 GMT");
}

test "IMF-fixdate accepts last four-digit year second" {
    try expectDate(max_http_epoch_second, "Fri, 31 Dec 9999 23:59:59 GMT");
}

test "IMF-fixdate rejects dates outside representable HTTP years" {
    try std.testing.expectError(error.BeforeUnixEpoch, formatImfFixdate(-1));
    try std.testing.expectError(
        error.AfterYear9999,
        formatImfFixdate(max_http_epoch_second + 1),
    );
    try std.testing.expectError(error.AfterYear9999, formatImfFixdate(std.math.maxInt(i64)));
}

test "IMF-fixdate cache rewrites only when epoch second changes" {
    var cache = ImfFixdateCache{};
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", cache.slice());
    try std.testing.expect(!(try cache.update(0)));
    try std.testing.expect(try cache.update(1_784_032_496));
    try std.testing.expectEqualStrings("Tue, 14 Jul 2026 12:34:56 GMT", cache.slice());
    try std.testing.expect(!(try cache.update(1_784_032_496)));
}

test "invalid cache update preserves previous value and second" {
    var cache = ImfFixdateCache{};
    try std.testing.expect(try cache.update(951_827_696));
    const before = cache.value;
    try std.testing.expectError(error.BeforeUnixEpoch, cache.update(-1));
    try std.testing.expectEqual(@as(i64, 951_827_696), cache.epoch_second);
    try std.testing.expectEqualSlices(u8, &before, cache.slice());
    try std.testing.expectError(
        error.AfterYear9999,
        cache.update(max_http_epoch_second + 1),
    );
    try std.testing.expectEqual(@as(i64, 951_827_696), cache.epoch_second);
    try std.testing.expectEqualSlices(u8, &before, cache.slice());
}

fn expectTimeoutIssue(expected: TimeoutProfileIssue, profile: TimeoutProfile) !void {
    try std.testing.expectEqual(@as(?TimeoutProfileIssue, expected), profile.issue());
}

fn expectDate(epoch_second: i64, expected: []const u8) !void {
    const actual = try formatImfFixdate(epoch_second);
    try std.testing.expectEqualStrings(expected, &actual);
}
