const std = @import("std");
const syntax = @import("../http1/syntax.zig");
const time = @import("../runtime/time.zig");

pub const etag_bytes_max: usize = 96;
pub const content_range_bytes_max: usize = 72;

pub const StatIdentity = struct {
    device_major: u32,
    device_minor: u32,
    inode: u64,
    size: u64,
    mtime_seconds: i64,
    mtime_nanoseconds: u32,
};

pub const ValidatorError = error{
    InvalidNanoseconds,
    TimestampOutOfRange,
};

pub const Validators = struct {
    identity: StatIdentity,
    last_modified_second: i64,
    etag_storage: [etag_bytes_max]u8,
    etag_length: u8,
    last_modified_storage: [time.imf_fixdate_bytes]u8,

    pub fn init(identity: StatIdentity, message_epoch_second: i64) ValidatorError!Validators {
        if (identity.mtime_nanoseconds >= std.time.ns_per_s) {
            return error.InvalidNanoseconds;
        }
        _ = time.formatImfFixdate(message_epoch_second) catch {
            return error.TimestampOutOfRange;
        };
        const last_modified_second = @max(
            @as(i64, 0),
            @min(identity.mtime_seconds, message_epoch_second),
        );
        const last_modified = time.formatImfFixdate(last_modified_second) catch {
            return error.TimestampOutOfRange;
        };
        var storage: [etag_bytes_max]u8 = undefined;
        const value = std.fmt.bufPrint(
            &storage,
            "W/\"{x}-{x}-{x}-{x}-{x}-{x}\"",
            .{
                identity.device_major,
                identity.device_minor,
                identity.inode,
                identity.size,
                identity.mtime_seconds,
                identity.mtime_nanoseconds,
            },
        ) catch unreachable;
        return .{
            .identity = identity,
            .last_modified_second = last_modified_second,
            .etag_storage = storage,
            .etag_length = @intCast(value.len),
            .last_modified_storage = last_modified,
        };
    }

    pub fn etag(validators: *const Validators) []const u8 {
        return validators.etag_storage[0..validators.etag_length];
    }

    pub fn lastModified(validators: *const Validators) []const u8 {
        return &validators.last_modified_storage;
    }
};

pub const Preconditions = struct {
    if_match: ?[]const u8 = null,
    if_unmodified_since: ?[]const u8 = null,
    if_none_match: ?[]const u8 = null,
    if_modified_since: ?[]const u8 = null,
};

pub const PreconditionDecision = enum(u8) {
    proceed,
    not_modified,
    precondition_failed,
};

pub fn evaluatePreconditions(
    validators: *const Validators,
    fields: Preconditions,
    reference_year: u16,
) PreconditionDecision {
    if (fields.if_match) |value| {
        if (!tagListMatches(value, validators.etag(), .strong)) {
            return .precondition_failed;
        }
    } else if (fields.if_unmodified_since) |value| {
        if (parseHttpDate(value, reference_year)) |second| {
            if (validators.last_modified_second > second) return .precondition_failed;
        }
    }

    if (fields.if_none_match) |value| {
        if (tagListMatches(value, validators.etag(), .weak)) return .not_modified;
    } else if (fields.if_modified_since) |value| {
        if (parseHttpDate(value, reference_year)) |second| {
            if (validators.last_modified_second <= second) return .not_modified;
        }
    }
    return .proceed;
}

pub fn evaluateRequestPreconditions(
    validators: *const Validators,
    headers: anytype,
    reference_year: u16,
) PreconditionDecision {
    const if_match = headers.all("If-Match");
    if (if_match.count() != 0) {
        var values = if_match.iterator();
        var aggregate = TagListAggregate{};
        while (values.next()) |value| aggregate.add(value, validators.etag(), .strong);
        if (!aggregate.valid or !aggregate.matched) return .precondition_failed;
    } else if (headers.all("If-Unmodified-Since").one() catch null) |value| {
        if (parseHttpDate(value, reference_year)) |second| {
            if (validators.last_modified_second > second) return .precondition_failed;
        }
    }

    const if_none_match = headers.all("If-None-Match");
    if (if_none_match.count() != 0) {
        var values = if_none_match.iterator();
        var aggregate = TagListAggregate{};
        while (values.next()) |value| aggregate.add(value, validators.etag(), .weak);
        return if (aggregate.valid and aggregate.matched) .not_modified else .proceed;
    }
    if (headers.all("If-Modified-Since").one() catch null) |value| {
        if (parseHttpDate(value, reference_year)) |second| {
            if (validators.last_modified_second <= second) return .not_modified;
        }
    }
    return .proceed;
}

pub const Method = enum(u1) {
    get,
    head,
};

pub const Span = struct {
    offset: u64,
    length: u64,
    transfer_body: bool,

    pub fn last(span: Span) u64 {
        std.debug.assert(span.length != 0);
        return span.offset + span.length - 1;
    }
};

pub const ContentRange = union(enum) {
    selected: struct { first: u64, last: u64, total: u64 },
    unsatisfied: u64,

    pub fn write(value: ContentRange, output: []u8) error{NoSpaceLeft}![]const u8 {
        return switch (value) {
            .selected => |selected| std.fmt.bufPrint(
                output,
                "bytes {d}-{d}/{d}",
                .{ selected.first, selected.last, selected.total },
            ),
            .unsatisfied => |total| std.fmt.bufPrint(output, "bytes */{d}", .{total}),
        };
    }
};

pub const Partial = struct {
    span: Span,
    content_range: ContentRange,
};

pub const RangeDecision = union(enum) {
    complete: Span,
    partial: Partial,
    unsatisfiable: ContentRange,
};

pub fn evaluateRange(
    method: Method,
    validators: *const Validators,
    range: ?[]const u8,
    if_range: ?[]const u8,
) RangeDecision {
    const complete = completeSpan(method, validators.identity.size);
    if (method == .head) return .{ .complete = complete };
    const value = range orelse return .{ .complete = complete };
    const parsed = parseRange(value, validators.identity.size);
    if (parsed == .ignored) return .{ .complete = complete };
    if (if_range) |condition| {
        if (!ifRangeMatches(condition, validators)) {
            return .{ .complete = complete };
        }
    }
    return switch (parsed) {
        .ignored => unreachable,
        .unsatisfiable => .{ .unsatisfiable = .{
            .unsatisfied = validators.identity.size,
        } },
        .selected => |selected| .{ .partial = .{
            .span = .{
                .offset = selected.first,
                .length = selected.last - selected.first + 1,
                .transfer_body = method == .get,
            },
            .content_range = .{ .selected = .{
                .first = selected.first,
                .last = selected.last,
                .total = validators.identity.size,
            } },
        } },
    };
}

pub fn evaluateRequestRange(
    method: Method,
    validators: *const Validators,
    headers: anytype,
) RangeDecision {
    const range_values = headers.all("Range");
    if (range_values.count() != 1) return evaluateRange(method, validators, null, null);
    const range = range_values.first().?;
    const if_range_values = headers.all("If-Range");
    if (if_range_values.count() > 1) return evaluateRange(method, validators, null, null);
    const if_range = if_range_values.first();
    return evaluateRange(method, validators, range, if_range);
}

pub fn referenceYear(epoch_second: i64) ?u16 {
    if (epoch_second < 0 or epoch_second > time.max_http_epoch_second) return null;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_second) };
    return epoch.getEpochDay().calculateYearDay().year;
}

fn completeSpan(method: Method, size: u64) Span {
    return .{ .offset = 0, .length = size, .transfer_body = method == .get and size != 0 };
}

const Comparison = enum(u1) { strong, weak };

const EntityTag = struct {
    weak: bool,
    token: []const u8,
};

fn tagListMatches(value: []const u8, current_value: []const u8, mode: Comparison) bool {
    return tagListResult(value, current_value, mode) == .match;
}

const TagListResult = enum(u2) { malformed, no_match, match };

const TagListAggregate = struct {
    seen: bool = false,
    wildcard: bool = false,
    matched: bool = false,
    valid: bool = true,

    fn add(
        aggregate: *TagListAggregate,
        value: []const u8,
        current_value: []const u8,
        mode: Comparison,
    ) void {
        if (!aggregate.valid) return;
        const trimmed = syntax.trimOws(value);
        if (std.mem.eql(u8, trimmed, "*")) {
            if (aggregate.seen) return aggregate.invalidate();
            aggregate.seen = true;
            aggregate.wildcard = true;
            aggregate.matched = true;
            return;
        }
        if (aggregate.wildcard) return aggregate.invalidate();
        aggregate.seen = true;
        switch (tagListResult(trimmed, current_value, mode)) {
            .malformed => aggregate.invalidate(),
            .no_match => {},
            .match => aggregate.matched = true,
        }
    }

    fn invalidate(aggregate: *TagListAggregate) void {
        aggregate.valid = false;
        aggregate.wildcard = false;
        aggregate.matched = false;
    }
};

fn tagListResult(
    value: []const u8,
    current_value: []const u8,
    mode: Comparison,
) TagListResult {
    const trimmed = syntax.trimOws(value);
    if (std.mem.eql(u8, trimmed, "*")) return .match;
    const current = parseEntityTag(current_value) orelse unreachable;
    var cursor: usize = 0;
    var matched = false;
    while (cursor < trimmed.len) {
        while (cursor < trimmed.len and isOws(trimmed[cursor])) cursor += 1;
        const end = entityTagEnd(trimmed, cursor) orelse return .malformed;
        const candidate = parseEntityTag(trimmed[cursor..end]) orelse unreachable;
        if (std.mem.eql(u8, candidate.token, current.token) and
            (mode == .weak or !candidate.weak and !current.weak)) matched = true;
        cursor = end;
        while (cursor < trimmed.len and isOws(trimmed[cursor])) cursor += 1;
        if (cursor == trimmed.len) return if (matched) .match else .no_match;
        if (trimmed[cursor] != ',') return .malformed;
        cursor += 1;
        if (cursor == trimmed.len) return .malformed;
    }
    return .malformed;
}

fn parseEntityTag(value: []const u8) ?EntityTag {
    const end = entityTagEnd(value, 0) orelse return null;
    if (end != value.len) return null;
    const weak = std.mem.startsWith(u8, value, "W/");
    const quote_index: usize = if (weak) 2 else 0;
    return .{ .weak = weak, .token = value[quote_index + 1 .. end - 1] };
}

fn entityTagEnd(value: []const u8, start: usize) ?usize {
    var cursor = start;
    if (value.len - cursor >= 2 and value[cursor] == 'W' and value[cursor + 1] == '/') {
        cursor += 2;
    }
    if (cursor == value.len or value[cursor] != '"') return null;
    cursor += 1;
    while (cursor < value.len and value[cursor] != '"') : (cursor += 1) {
        const byte = value[cursor];
        if (byte != 0x21 and !(byte >= 0x23 and byte <= 0x7e) and byte < 0x80) return null;
    }
    if (cursor == value.len) return null;
    return cursor + 1;
}

fn isOws(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

const ParsedRange = union(enum) {
    ignored,
    unsatisfiable,
    selected: struct { first: u64, last: u64 },
};

fn parseRange(value: []const u8, size: u64) ParsedRange {
    const trimmed = syntax.trimOws(value);
    const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse return .ignored;
    if (!syntax.eqlIgnoreCase(trimmed[0..equals], "bytes")) return .ignored;
    const specification = trimmed[equals + 1 ..];
    if (specification.len == 0 or std.mem.indexOfScalar(u8, specification, ',') != null) {
        return .ignored;
    }
    const dash = std.mem.indexOfScalar(u8, specification, '-') orelse return .ignored;
    if (std.mem.indexOfScalarPos(u8, specification, dash + 1, '-') != null) return .ignored;
    const first_text = specification[0..dash];
    const last_text = specification[dash + 1 ..];
    if (first_text.len == 0) return suffixRange(last_text, size);
    const first = syntax.parseDecimal(first_text) catch return .ignored;
    if (last_text.len == 0) return openRange(first, size);
    const requested_last = syntax.parseDecimal(last_text) catch return .ignored;
    if (first > requested_last) return .ignored;
    if (first >= size) return .unsatisfiable;
    return .{ .selected = .{ .first = first, .last = @min(requested_last, size - 1) } };
}

fn suffixRange(text: []const u8, size: u64) ParsedRange {
    const suffix = syntax.parseDecimal(text) catch return .ignored;
    if (suffix == 0 or size == 0) return .unsatisfiable;
    const length = @min(suffix, size);
    return .{ .selected = .{ .first = size - length, .last = size - 1 } };
}

fn openRange(first: u64, size: u64) ParsedRange {
    if (first >= size) return .unsatisfiable;
    return .{ .selected = .{ .first = first, .last = size - 1 } };
}

fn ifRangeMatches(value: []const u8, validators: *const Validators) bool {
    const trimmed = syntax.trimOws(value);
    if (parseEntityTag(trimmed)) |candidate| {
        const current = parseEntityTag(validators.etag()) orelse unreachable;
        return !candidate.weak and !current.weak and
            std.mem.eql(u8, candidate.token, current.token);
    }
    // Live filesystem metadata has no history proving Last-Modified is strong.
    return false;
}

pub fn parseHttpDate(value: []const u8, reference_year: u16) ?i64 {
    if (parseImfFixdate(value)) |parts| return parts.epochSecond();
    if (parseRfc850(value, reference_year)) |parts| return parts.epochSecond();
    if (parseAsctime(value)) |parts| return parts.epochSecond();
    return null;
}

const DateParts = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    fn epochSecond(parts: DateParts) ?i64 {
        if (!validDate(parts)) return null;
        const days = daysFromCivil(parts.year, parts.month, parts.day);
        if (days < 0) return null;
        return days * 86_400 + @as(i64, parts.hour) * 3600 +
            @as(i64, parts.minute) * 60 + parts.second;
    }
};

fn parseImfFixdate(value: []const u8) ?DateParts {
    if (value.len != 29 or value[3] != ',' or value[4] != ' ' or
        value[7] != ' ' or value[11] != ' ' or value[16] != ' ' or
        value[19] != ':' or value[22] != ':' or
        !std.mem.eql(u8, value[25..], " GMT") or !shortWeekday(value[0..3])) return null;
    return dateParts(
        decimal(value[12..16]),
        monthNumber(value[8..11]),
        decimal(value[5..7]),
        value[17..25],
    );
}

fn parseRfc850(value: []const u8, reference_year: u16) ?DateParts {
    const comma = std.mem.indexOfScalar(u8, value, ',') orelse return null;
    if (!longWeekday(value[0..comma]) or value.len - comma != 24 or value[comma + 1] != ' ') {
        return null;
    }
    const tail = value[comma + 2 ..];
    if (tail[2] != '-' or tail[6] != '-' or tail[9] != ' ' or
        tail[12] != ':' or tail[15] != ':' or !std.mem.eql(u8, tail[18..], " GMT")) return null;
    const short_year = decimal(tail[7..9]) orelse return null;
    const year = resolveShortYear(@intCast(short_year), reference_year) orelse return null;
    return dateParts(
        year,
        monthNumber(tail[3..6]),
        decimal(tail[0..2]),
        tail[10..18],
    );
}

fn parseAsctime(value: []const u8) ?DateParts {
    if (value.len != 24 or value[3] != ' ' or value[7] != ' ' or
        value[10] != ' ' or value[13] != ':' or value[16] != ':' or value[19] != ' ' or
        !shortWeekday(value[0..3])) return null;
    const day = if (value[8] == ' ')
        decimal(value[9..10])
    else
        decimal(value[8..10]);
    return dateParts(
        decimal(value[20..24]),
        monthNumber(value[4..7]),
        day,
        value[11..19],
    );
}

fn dateParts(year: ?u16, month: ?u8, day: ?u16, clock: []const u8) ?DateParts {
    if (clock.len != 8 or clock[2] != ':' or clock[5] != ':') return null;
    const year_value = year orelse return null;
    const month_value = month orelse return null;
    const day_value = day orelse return null;
    if (day_value > std.math.maxInt(u8)) return null;
    const hour = decimal(clock[0..2]) orelse return null;
    const minute = decimal(clock[3..5]) orelse return null;
    const second = decimal(clock[6..8]) orelse return null;
    return .{
        .year = year_value,
        .month = month_value,
        .day = @intCast(day_value),
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
    };
}

fn decimal(value: []const u8) ?u16 {
    const parsed = syntax.parseDecimal(value) catch return null;
    if (parsed > std.math.maxInt(u16)) return null;
    return @intCast(parsed);
}

fn monthNumber(value: []const u8) ?u8 {
    const names = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    for (names, 1..) |name, number| {
        if (std.mem.eql(u8, value, name)) return @intCast(number);
    }
    return null;
}

fn shortWeekday(value: []const u8) bool {
    const names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    for (names) |name| if (std.mem.eql(u8, value, name)) return true;
    return false;
}

fn longWeekday(value: []const u8) bool {
    const names = [_][]const u8{
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    };
    for (names) |name| if (std.mem.eql(u8, value, name)) return true;
    return false;
}

fn resolveShortYear(short: u8, reference: u16) ?u16 {
    if (reference < 1970 or reference > 9999) return null;
    var year: i32 = @as(i32, reference / 100) * 100 + short;
    if (year > @as(i32, reference) + 50) year -= 100;
    if (year < 1970 or year > 9999) return null;
    return @intCast(year);
}

fn validDate(parts: DateParts) bool {
    if (parts.year < 1970 or parts.year > 9999 or parts.month == 0 or parts.month > 12 or
        parts.day == 0 or parts.hour > 23 or parts.minute > 59 or parts.second > 59) return false;
    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var maximum = month_days[parts.month - 1];
    if (parts.month == 2 and leapYear(parts.year)) maximum = 29;
    return parts.day <= maximum;
}

fn leapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn daysFromCivil(year_value: u16, month_value: u8, day_value: u8) i64 {
    var year: i64 = year_value;
    const month: i64 = month_value;
    const day: i64 = day_value;
    year -= @intFromBool(month <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const adjusted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * adjusted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}
