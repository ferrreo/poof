const std = @import("std");
const flat_schema = @import("internal/flat/schema.zig");
const route = @import("route.zig");
const route_graph = @import("internal/route_graph.zig");
const syntax = @import("internal/url/syntax.zig");
const url = @import("url.zig");

pub const query_pairs_standard_max: u16 = 1000;
pub const query_pairs_hard_max: u16 = 4096;

pub const Error = syntax.BuildError || syntax.ValidationError || error{
    InvalidPathParameter,
    InvalidQueryValue,
    QueryPairLimit,
};

pub const Limits = struct {
    bytes_max: u32 = syntax.url_bytes_standard_max,
    query_pairs_max: u16 = query_pairs_standard_max,

    pub fn validate(comptime limits: Limits) Limits {
        if (limits.bytes_max == 0 or limits.bytes_max > syntax.url_bytes_hard_max) {
            @compileError("PLOOF-E3730 urlFor byte limit must be 1 to 65536 bytes");
        }
        if (limits.query_pairs_max == 0 or
            limits.query_pairs_max > query_pairs_hard_max)
        {
            @compileError("PLOOF-E3731 urlFor query pair limit must be 1 to 4096");
        }
        return limits;
    }
};

pub const standard_limits = Limits.validate(.{});

/// A standalone descriptor uses its declared path. Use `App.routeTarget` for a
/// descriptor mounted under one or more route groups.
pub fn urlFor(
    comptime descriptor: anytype,
    path_parameters: anytype,
    query: anytype,
    output: []u8,
) Error!url.Url {
    return urlForWith(descriptor, path_parameters, query, output, standard_limits);
}

pub fn urlForWith(
    comptime descriptor: anytype,
    path_parameters: anytype,
    query: anytype,
    output: []u8,
    comptime requested_limits: Limits,
) Error!url.Url {
    const limits = comptime requested_limits.validate();
    const pattern = comptime validateCall(
        descriptor,
        @TypeOf(path_parameters),
        @TypeOf(query),
    );

    var writer = Writer.init(output, limits.bytes_max);
    try writePath(pattern, path_parameters, &writer);
    try writeQuery(query, &writer, limits.query_pairs_max);
    return url.Url.localWith(writer.bytes(), .{ .bytes_max = limits.bytes_max });
}

const route_pattern_limits = route.GraphLimits{
    .pattern_bytes_max = syntax.url_bytes_hard_max,
    .segments_max = route.segments_hard_max,
    .captures_max = route.captures_hard_max,
};

fn validateCall(
    comptime descriptor: anytype,
    comptime Path: type,
    comptime Query: type,
) []const u8 {
    const pattern = targetPattern(descriptor);
    validatePathType(pattern, Path);
    validateQueryType(Query);
    return pattern;
}

fn targetPattern(comptime descriptor: anytype) []const u8 {
    if (@TypeOf(descriptor) == *const route.RouteTarget) {
        validatePattern(descriptor.path());
        return descriptor.path();
    }
    validateDescriptor(descriptor);
    return descriptor.path;
}

fn validateDescriptor(comptime descriptor: anytype) void {
    const Descriptor = @TypeOf(descriptor);
    if (@typeInfo(Descriptor) != .@"struct" or !@hasField(Descriptor, "kind")) {
        @compileError("PLOOF-E3720 urlFor requires a route descriptor");
    }
    if (@TypeOf(descriptor.kind) != route.DescriptorKind or descriptor.kind != .route) {
        @compileError("PLOOF-E3720 urlFor requires a route descriptor");
    }
    if (!@hasField(Descriptor, "path") or !@hasField(Descriptor, "method")) {
        @compileError("PLOOF-E3720 urlFor requires a route descriptor");
    }
    validatePattern(descriptor.path);
}

fn validatePattern(comptime pattern: []const u8) void {
    if (route_graph.patternIssue(pattern, route_pattern_limits)) |issue| {
        @compileError(issue.diagnostic());
    }
    validateBuildablePattern(pattern);
}

fn validateBuildablePattern(comptime pattern: []const u8) void {
    var start: usize = 1;
    while (true) {
        const end = std.mem.indexOfScalarPos(u8, pattern, start, '/') orelse pattern.len;
        const segment = pattern[start..end];
        if (segment.len > 0 and segment[0] == '*') {
            @compileError("PLOOF-E3722 urlFor catch-all needs an explicit segment-list type");
        }
        if (segment.len == 0 or segment[0] != ':') {
            if (!std.unicode.utf8ValidateSlice(segment) or
                std.mem.indexOfScalar(u8, segment, '\\') != null or
                std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
            {
                @compileError("PLOOF-E3732 route literal is unsafe for browser URL construction");
            }
        }
        if (end == pattern.len) return;
        start = end + 1;
    }
}

fn validatePathType(comptime pattern: []const u8, comptime Path: type) void {
    const capture_count = countCaptures(pattern);
    if (!isNamedValuesType(Path, capture_count == 0)) {
        @compileError("PLOOF-E3723 path parameters must be a named struct");
    }
    if (Path == void) return;
    const fields = @typeInfo(Path).@"struct".fields;
    inline for (fields) |field| {
        if (!hasCapture(pattern, field.name)) {
            @compileError("PLOOF-E3725 extra urlFor path parameter: " ++ field.name);
        }
        validatePathScalar(field.type, field.name);
    }
    var start: usize = 1;
    while (true) {
        const end = std.mem.indexOfScalarPos(u8, pattern, start, '/') orelse pattern.len;
        const segment = pattern[start..end];
        if (segment.len > 0 and segment[0] == ':' and !@hasField(Path, segment[1..])) {
            @compileError("PLOOF-E3724 missing urlFor path parameter: " ++ segment[1..]);
        }
        if (end == pattern.len) return;
        start = end + 1;
    }
}

fn validatePathScalar(comptime T: type, comptime name: []const u8) void {
    if (isPathText(T)) return;
    switch (@typeInfo(T)) {
        .comptime_int, .int, .bool, .@"enum" => {},
        else => @compileError("PLOOF-E3726 unsupported path parameter type: " ++ name),
    }
}

fn validateQueryType(comptime Query: type) void {
    if (Query == void) return;
    if (@typeInfo(Query) != .@"struct") {
        @compileError("PLOOF-E3727 urlFor query must be a named struct");
    }
    const info = @typeInfo(Query).@"struct";
    if (info.is_tuple and info.fields.len != 0) {
        @compileError("PLOOF-E3727 urlFor query must be a named struct");
    }
    validateQueryMetadata(Query);
    inline for (info.fields) |field| {
        validateQueryField(field.type, field.name);
        const name = flat_schema.wireName(Query, field.name);
        if (name.len == 0 or !std.unicode.utf8ValidateSlice(name) or
            std.mem.indexOfScalar(u8, name, '\\') != null)
        {
            @compileError("PLOOF-E3729 invalid urlFor query wire name");
        }
    }
    validateUniqueQueryNames(Query);
}

fn validateQueryField(comptime T: type, comptime name: []const u8) void {
    if (isQueryText(T)) return;
    switch (@typeInfo(T)) {
        .array => |array| validateQueryScalar(array.child, name),
        .pointer => |pointer| {
            if (pointer.size != .slice or pointer.sentinel_ptr != null or pointer.child == u8) {
                @compileError("PLOOF-E3728 unsupported query field type: " ++ name);
            }
            validateQueryScalar(pointer.child, name);
        },
        else => validateQueryScalar(T, name),
    }
}

fn validateQueryScalar(comptime T: type, comptime name: []const u8) void {
    if (isQueryText(T)) return;
    switch (@typeInfo(T)) {
        .optional => |optional| validateQueryScalar(optional.child, name),
        .comptime_int, .comptime_float, .int, .float, .bool, .@"enum" => {},
        else => @compileError("PLOOF-E3728 unsupported query field type: " ++ name),
    }
}

fn validateQueryMetadata(comptime Query: type) void {
    if (!@hasDecl(Query, "ploof_flat_fields")) return;
    const metadata = Query.ploof_flat_fields;
    if (@typeInfo(@TypeOf(metadata)) != .@"struct" or
        @typeInfo(@TypeOf(metadata)).@"struct".is_tuple)
    {
        @compileError("PLOOF-E3729 ploof_flat_fields must use named entries");
    }
    inline for (@typeInfo(@TypeOf(metadata)).@"struct".fields) |entry| {
        if (!@hasField(Query, entry.name)) {
            @compileError("PLOOF-E3729 ploof_flat_fields names an unknown field");
        }
        const name: []const u8 = @field(metadata, entry.name);
        _ = name;
    }
}

fn validateUniqueQueryNames(comptime Query: type) void {
    const fields = @typeInfo(Query).@"struct".fields;
    inline for (fields, 0..) |left, left_index| {
        inline for (fields[left_index + 1 ..]) |right| {
            if (std.mem.eql(
                u8,
                flat_schema.wireName(Query, left.name),
                flat_schema.wireName(Query, right.name),
            )) {
                @compileError("PLOOF-E3729 duplicate urlFor query wire name");
            }
        }
    }
}

fn writePath(comptime pattern: []const u8, parameters: anytype, writer: *Writer) Error!void {
    try writer.appendLiteral("/");
    comptime var start: usize = 1;
    inline while (true) {
        const end = comptime std.mem.indexOfScalarPos(u8, pattern, start, '/') orelse pattern.len;
        const segment = pattern[start..end];
        if (segment.len > 0 and segment[0] == ':') {
            try appendPathScalar(writer, @field(parameters, segment[1..]));
        } else {
            try writer.appendComponent(segment);
        }
        if (end == pattern.len) return;
        try writer.appendLiteral("/");
        start = end + 1;
    }
}

fn appendPathScalar(writer: *Writer, value: anytype) Error!void {
    const T = @TypeOf(value);
    if (comptime isPathText(T)) return appendPathText(writer, textBytes(value));
    switch (@typeInfo(T)) {
        .comptime_int, .int => try appendInteger(writer, value),
        .bool => try writer.appendLiteral(if (value) "true" else "false"),
        .@"enum" => try appendPathText(writer, @tagName(value)),
        else => unreachable,
    }
}

fn appendPathText(writer: *Writer, value: []const u8) Error!void {
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, '/') != null or
        std.mem.indexOfScalar(u8, value, '\\') != null or
        std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, ".."))
    {
        return error.InvalidPathParameter;
    }
    writer.appendComponent(value) catch |problem| return switch (problem) {
        error.InvalidUtf8, error.InvalidComponent => error.InvalidPathParameter,
        else => problem,
    };
}

fn writeQuery(query: anytype, writer: *Writer, pairs_max: u16) Error!void {
    const Query = @TypeOf(query);
    if (Query == void) return;
    var pair_count: u16 = 0;
    inline for (@typeInfo(Query).@"struct".fields) |field| {
        try appendQueryField(
            writer,
            flat_schema.wireName(Query, field.name),
            @field(query, field.name),
            &pair_count,
            pairs_max,
        );
    }
}

fn appendQueryField(
    writer: *Writer,
    comptime name: []const u8,
    value: anytype,
    pair_count: *u16,
    pairs_max: u16,
) Error!void {
    const T = @TypeOf(value);
    if (comptime isQueryText(T)) {
        return appendQueryPair(writer, name, value, pair_count, pairs_max);
    }
    switch (@typeInfo(T)) {
        .optional => if (value) |present| {
            try appendQueryPair(writer, name, present, pair_count, pairs_max);
        },
        .array => for (value) |item| {
            try appendQueryPair(writer, name, item, pair_count, pairs_max);
        },
        .pointer => for (value) |item| {
            try appendQueryPair(writer, name, item, pair_count, pairs_max);
        },
        else => try appendQueryPair(writer, name, value, pair_count, pairs_max),
    }
}

fn appendQueryPair(
    writer: *Writer,
    comptime name: []const u8,
    value: anytype,
    pair_count: *u16,
    pairs_max: u16,
) Error!void {
    if (pair_count.* >= pairs_max) return error.QueryPairLimit;
    const checkpoint = writer.length;
    errdefer writer.length = checkpoint;
    try writer.appendLiteral(if (pair_count.* == 0) "?" else "&");
    try writer.appendComponent(name);
    try writer.appendLiteral("=");
    try appendRequiredQueryScalar(writer, value);
    pair_count.* += 1;
}

fn appendRequiredQueryScalar(writer: *Writer, value: anytype) Error!void {
    const T = @TypeOf(value);
    if (comptime isQueryText(T)) return appendQueryText(writer, textBytes(value));
    switch (@typeInfo(T)) {
        .optional => if (value) |present| {
            try appendRequiredQueryScalar(writer, present);
        } else return error.InvalidQueryValue,
        .comptime_int, .int => try appendInteger(writer, value),
        .comptime_float => {
            const text = comptime std.fmt.comptimePrint("{d}", .{value});
            try appendQueryText(writer, text);
        },
        .float => {
            if (!std.math.isFinite(value)) return error.InvalidQueryValue;
            var storage: [128]u8 = undefined;
            var fixed = std.Io.Writer.fixed(&storage);
            fixed.print("{d}", .{value}) catch return error.InvalidQueryValue;
            try appendQueryText(writer, fixed.buffered());
        },
        .bool => try writer.appendLiteral(if (value) "true" else "false"),
        .@"enum" => try appendQueryText(writer, @tagName(value)),
        else => unreachable,
    }
}

fn appendQueryText(writer: *Writer, value: []const u8) Error!void {
    writer.appendComponent(value) catch |problem| return switch (problem) {
        error.InvalidUtf8, error.InvalidComponent => error.InvalidQueryValue,
        else => problem,
    };
}

fn appendInteger(writer: *Writer, value: anytype) Error!void {
    const T = @TypeOf(value);
    if (comptime @typeInfo(T) == .comptime_int) {
        const text = comptime std.fmt.comptimePrint("{d}", .{value});
        return writer.appendComponent(text);
    }
    var storage: [integerTextBytes(T)]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&storage);
    fixed.print("{d}", .{value}) catch return error.InvalidQueryValue;
    try writer.appendComponent(fixed.buffered());
}

fn integerTextBytes(comptime T: type) comptime_int {
    const integer = @typeInfo(T).int;
    const digits = (asComptimeInt(integer.bits) * 30103 + 99_999) / 100_000;
    return @max(@as(comptime_int, 1), digits) +
        (if (integer.signedness == .signed) 1 else 0);
}

fn asComptimeInt(comptime value: anytype) comptime_int {
    return value;
}

const Writer = struct {
    storage: []u8,
    length: u32 = 0,
    bytes_max: u32,

    fn init(storage: []u8, bytes_max: u32) Writer {
        return .{ .storage = storage, .bytes_max = bytes_max };
    }

    fn appendLiteral(writer: *Writer, value: []const u8) syntax.BuildError!void {
        if (value.len > syntax.url_bytes_hard_max) return error.TooLong;
        const addition: u32 = @intCast(value.len);
        const end = std.math.add(u32, writer.length, addition) catch return error.TooLong;
        if (end > writer.bytes_max) return error.TooLong;
        if (end > writer.storage.len) return error.NoSpace;
        @memcpy(writer.storage[writer.length..end], value);
        writer.length = end;
    }

    fn appendComponent(writer: *Writer, value: []const u8) syntax.BuildError!void {
        if (std.mem.indexOfScalar(u8, value, '\\') != null) return error.InvalidComponent;
        const encoded_length = try syntax.encodedLength(value);
        const end = std.math.add(u32, writer.length, encoded_length) catch {
            return error.TooLong;
        };
        if (end > writer.bytes_max) return error.TooLong;
        if (end > writer.storage.len) return error.NoSpace;
        _ = try syntax.writeEncoded(value, writer.storage[writer.length..end]);
        writer.length = end;
    }

    fn bytes(writer: *const Writer) []const u8 {
        std.debug.assert(writer.length <= writer.bytes_max);
        std.debug.assert(writer.length <= writer.storage.len);
        return writer.storage[0..writer.length];
    }
};

fn isNamedValuesType(comptime T: type, comptime empty_allowed: bool) bool {
    if (T == void) return empty_allowed;
    if (@typeInfo(T) != .@"struct") return false;
    const info = @typeInfo(T).@"struct";
    return !info.is_tuple or info.fields.len == 0;
}

fn isByteArray(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => |array| array.child == u8,
        else => false,
    };
}

fn isByteArrayPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .one and pointer.is_const and
            isByteArray(pointer.child),
        else => false,
    };
}

fn isPathText(comptime T: type) bool {
    return T == []const u8 or isByteArray(T) or isByteArrayPointer(T);
}

fn isQueryText(comptime T: type) bool {
    return T == []const u8 or isByteArrayPointer(T);
}

fn textBytes(value: anytype) []const u8 {
    const T = @TypeOf(value);
    if (T == []const u8) return value;
    if (comptime isByteArray(T)) return value[0..];
    if (comptime isByteArrayPointer(T)) return value[0..];
    unreachable;
}

fn countCaptures(comptime pattern: []const u8) usize {
    var count: usize = 0;
    var segments = std.mem.splitScalar(u8, pattern[1..], '/');
    while (segments.next()) |segment| if (segment.len > 0 and segment[0] == ':') {
        count += 1;
    };
    return count;
}

fn hasCapture(comptime pattern: []const u8, comptime name: []const u8) bool {
    var segments = std.mem.splitScalar(u8, pattern[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len > 1 and segment[0] == ':' and
            std.mem.eql(u8, segment[1..], name)) return true;
    }
    return false;
}

comptime {
    std.debug.assert(query_pairs_standard_max <= query_pairs_hard_max);
    std.debug.assert(@sizeOf(Writer) <= 32);
}
