const std = @import("std");
const response_field_rules = @import("response_field_rules.zig");
const syntax = @import("syntax.zig");

const chunk_line_end = "\r\n";
const terminal_prefix = "0\r\n";
const field_separator = ": ";
const declaration_separator = ", ";
const trailer_section_end = "\r\n";
const trailer_fingerprint_seed: u64 = 0xd4c6_f7a1_829b_305e;

pub const WriteError = error{
    EmptyChunk,
    OutputTooSmall,
    LengthOverflow,
    InvalidDeclaration,
    DuplicateDeclaration,
    ForbiddenTrailer,
    InvalidFieldName,
    InvalidFieldValue,
    DuplicateField,
    UndeclaredField,
    TrailerTooLarge,
};

pub const LimitIssue = enum(u8) {
    section_bytes_zero,
    section_bytes_above_hard_max,
    field_line_bytes_zero,
    field_line_bytes_above_hard_max,
    field_line_bytes_above_section_max,
    declarations_zero,
    declarations_above_hard_max,
    fields_zero,
    fields_above_hard_max,
};

pub const TrailerLimits = struct {
    section_bytes_max: u32 = 8 * 1024,
    field_line_bytes_max: u32 = 4 * 1024,
    declarations_max: u16 = 32,
    fields_max: u16 = 32,

    pub fn issue(limits: TrailerLimits) ?LimitIssue {
        if (limits.section_bytes_max == 0) return .section_bytes_zero;
        if (limits.section_bytes_max > 1024 * 1024) return .section_bytes_above_hard_max;
        if (limits.field_line_bytes_max == 0) return .field_line_bytes_zero;
        if (limits.field_line_bytes_max > 1024 * 1024) {
            return .field_line_bytes_above_hard_max;
        }
        if (limits.field_line_bytes_max > limits.section_bytes_max) {
            return .field_line_bytes_above_section_max;
        }
        if (limits.declarations_max == 0) return .declarations_zero;
        if (limits.declarations_max > 1024) return .declarations_above_hard_max;
        if (limits.fields_max == 0) return .fields_zero;
        if (limits.fields_max > 1024) return .fields_above_hard_max;
        return null;
    }

    pub fn validate(comptime limits: TrailerLimits) TrailerLimits {
        if (limits.issue()) |problem| @compileError(limitIssueMessage(problem));
        return limits;
    }
};

pub const standard_trailer_limits = TrailerLimits.validate(.{});

pub const TrailerPlan = struct {
    emitted: bool,
    declarations: []const []const u8,
    fingerprint: u64,
};

pub const PreparedTrailerPlan = struct {
    plan: TrailerPlan,
    serialized_name_bytes: usize,
};

pub const TrailerPlanError = error{
    LengthOverflow,
    InvalidDeclaration,
    DuplicateDeclaration,
    ForbiddenTrailer,
    TrailerTooLarge,
};

pub const TrailerField = struct {
    name: []const u8,
    value: []const u8,
};

pub const ExactBodyError = error{
    Overrun,
    Underrun,
};

pub const ExactBody = struct {
    expected: u64,
    produced: u64 = 0,

    pub fn init(expected: u64) ExactBody {
        return .{ .expected = expected };
    }

    pub fn accept(body: *ExactBody, byte_count: u64) ExactBodyError!void {
        if (body.produced > body.expected) return error.Overrun;
        if (byte_count > body.expected - body.produced) return error.Overrun;
        body.produced += byte_count;
    }

    pub fn finish(body: *const ExactBody) ExactBodyError!void {
        if (body.produced != body.expected) return error.Underrun;
    }
};

pub fn writeChunk(output: []u8, data: []const u8) WriteError![]u8 {
    if (data.len == 0) return error.EmptyChunk;
    const layout = try chunkLayout(data.len);
    if (output.len < layout.total_bytes) return error.OutputTooSmall;

    const body_start = layout.hex_digits + chunk_line_end.len;
    copyBytes(output[body_start..][0..data.len], data);
    writeHex(output[0..layout.hex_digits], data.len);
    @memcpy(output[layout.hex_digits..body_start], chunk_line_end);
    @memcpy(output[body_start + data.len .. layout.total_bytes], chunk_line_end);
    return output[0..layout.total_bytes];
}

/// Returns the largest in-place producer window that can become one chunk.
pub fn chunkWritable(output: []u8) WriteError![]u8 {
    if (output.len < 6) return error.OutputTooSmall;
    var capacity = output.len - 5;
    while ((try chunkLayout(capacity)).total_bytes > output.len) capacity -= 1;
    const body_start = hexLength(capacity) + chunk_line_end.len;
    return output[body_start..][0..capacity];
}

pub fn prepareTrailerPlan(
    comptime limits: TrailerLimits,
    declarations: []const []const u8,
    emitted: bool,
) TrailerPlanError!PreparedTrailerPlan {
    const validated = comptime limits.validate();
    const serialized_name_bytes = try validateDeclarations(validated, declarations);
    if (emitted and declarations.len == 0) return error.InvalidDeclaration;
    return .{
        .plan = if (emitted) .{
            .emitted = true,
            .declarations = declarations,
            .fingerprint = declarationFingerprint(declarations),
        } else .{
            .emitted = false,
            .declarations = &.{},
            .fingerprint = 0,
        },
        .serialized_name_bytes = serialized_name_bytes,
    };
}

pub fn writeTerminal(
    comptime limits: TrailerLimits,
    output: []u8,
    plan: TrailerPlan,
    fields: []const TrailerField,
) WriteError![]u8 {
    const validated = comptime limits.validate();
    const layout = try terminalLayout(validated, plan, fields);
    if (output.len < layout.total_bytes) return error.OutputTooSmall;

    var cursor: usize = 0;
    append(output, &cursor, terminal_prefix);
    for (fields) |field| {
        appendLower(output, &cursor, field.name);
        append(output, &cursor, field_separator);
        append(output, &cursor, field.value);
        append(output, &cursor, chunk_line_end);
    }
    append(output, &cursor, trailer_section_end);
    std.debug.assert(cursor == layout.total_bytes);
    return output[0..layout.total_bytes];
}

const ChunkLayout = struct {
    hex_digits: usize,
    total_bytes: usize,
};

const TerminalLayout = struct {
    section_bytes: usize,
    total_bytes: usize,
};

fn chunkLayout(data_bytes: usize) WriteError!ChunkLayout {
    const digits = hexLength(data_bytes);
    var total = digits;
    try addLength(&total, chunk_line_end.len);
    try addLength(&total, data_bytes);
    try addLength(&total, chunk_line_end.len);
    return .{ .hex_digits = digits, .total_bytes = total };
}

fn terminalLayout(
    limits: TrailerLimits,
    plan: TrailerPlan,
    fields: []const TrailerField,
) WriteError!TerminalLayout {
    if (fields.len > limits.fields_max) return error.TrailerTooLarge;
    const declarations = try validateTrailerPlan(limits, plan);

    var section_bytes: usize = trailer_section_end.len;
    if (section_bytes > limits.section_bytes_max) return error.TrailerTooLarge;
    for (fields, 0..) |field, index| {
        try validateField(field, declarations);
        try validateFieldMultiplicity(field, fields[0..index]);
        const line_bytes = try fieldLineBytes(field);
        if (line_bytes > limits.field_line_bytes_max) return error.TrailerTooLarge;
        try addTrailerBytes(&section_bytes, line_bytes, limits.section_bytes_max);
    }

    var total_bytes = terminal_prefix.len;
    try addLength(&total_bytes, section_bytes);
    return .{ .section_bytes = section_bytes, .total_bytes = total_bytes };
}

fn validateDeclarations(
    limits: TrailerLimits,
    declarations: []const []const u8,
) TrailerPlanError!usize {
    if (declarations.len > limits.declarations_max) return error.TrailerTooLarge;
    var serialized_name_bytes: usize = 0;
    for (declarations, 0..) |name, index| {
        if (index != 0) {
            addLength(&serialized_name_bytes, declaration_separator.len) catch {
                return error.LengthOverflow;
            };
        }
        addLength(&serialized_name_bytes, name.len) catch return error.LengthOverflow;
        if (!syntax.isToken(name)) return error.InvalidDeclaration;
        if (response_field_rules.isForbiddenTrailerName(name)) return error.ForbiddenTrailer;
        for (declarations[0..index]) |previous| {
            if (syntax.eqlIgnoreCase(name, previous)) return error.DuplicateDeclaration;
        }
    }
    return serialized_name_bytes;
}

fn validateTrailerPlan(limits: TrailerLimits, plan: TrailerPlan) WriteError![]const []const u8 {
    if (!plan.emitted) {
        if (plan.declarations.len != 0 or plan.fingerprint != 0) {
            return error.InvalidDeclaration;
        }
        return &.{};
    }
    if (plan.declarations.len == 0) return error.InvalidDeclaration;
    _ = validateDeclarations(limits, plan.declarations) catch |err| return err;
    if (declarationFingerprint(plan.declarations) != plan.fingerprint) {
        return error.InvalidDeclaration;
    }
    return plan.declarations;
}

fn declarationFingerprint(declarations: []const []const u8) u64 {
    var hash = std.hash.Wyhash.init(trailer_fingerprint_seed);
    const separator = [_]u8{0};
    for (declarations) |name| {
        for (name) |byte| {
            const lowered = [_]u8{syntax.asciiLower(byte)};
            hash.update(&lowered);
        }
        hash.update(&separator);
    }
    return hash.final();
}

fn validateField(field: TrailerField, declarations: []const []const u8) WriteError!void {
    if (!syntax.isToken(field.name)) return error.InvalidFieldName;
    if (response_field_rules.isForbiddenTrailerName(field.name)) {
        return error.ForbiddenTrailer;
    }
    if (!validResponseValue(field.value)) return error.InvalidFieldValue;
    for (declarations) |declaration| {
        if (syntax.eqlIgnoreCase(field.name, declaration)) return;
    }
    return error.UndeclaredField;
}

fn validateFieldMultiplicity(field: TrailerField, previous: []const TrailerField) WriteError!void {
    if (!response_field_rules.isSingletonName(field.name)) return;
    for (previous) |prior| {
        if (syntax.eqlIgnoreCase(field.name, prior.name)) return error.DuplicateField;
    }
}

fn validResponseValue(value: []const u8) bool {
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn fieldLineBytes(field: TrailerField) WriteError!usize {
    var bytes = field.name.len;
    try addLength(&bytes, field_separator.len);
    try addLength(&bytes, field.value.len);
    try addLength(&bytes, chunk_line_end.len);
    return bytes;
}

fn addTrailerBytes(total: *usize, amount: usize, maximum: u32) WriteError!void {
    try addLength(total, amount);
    if (total.* > maximum) return error.TrailerTooLarge;
}

fn addLength(total: *usize, amount: usize) WriteError!void {
    if (amount > std.math.maxInt(usize) - total.*) return error.LengthOverflow;
    total.* += amount;
}

fn hexLength(value: usize) usize {
    var remaining = value;
    var digits: usize = 1;
    while (remaining >= 16) : (digits += 1) remaining /= 16;
    return digits;
}

fn writeHex(output: []u8, value: usize) void {
    std.debug.assert(value != 0);
    std.debug.assert(output.len == hexLength(value));
    const alphabet = "0123456789abcdef";
    var remaining = value;
    var index = output.len;
    while (index > 0) {
        index -= 1;
        output[index] = alphabet[remaining & 0xf];
        remaining >>= 4;
    }
    std.debug.assert(remaining == 0);
}

fn copyBytes(destination: []u8, source: []const u8) void {
    std.debug.assert(destination.len == source.len);
    if (destination.ptr == source.ptr or destination.len == 0) return;
    const destination_start = @intFromPtr(destination.ptr);
    const source_start = @intFromPtr(source.ptr);
    const destination_end = destination_start + destination.len;
    const source_end = source_start + source.len;
    if (destination_end <= source_start or source_end <= destination_start) {
        @memcpy(destination, source);
    } else if (destination_start < source_start) {
        std.mem.copyForwards(u8, destination, source);
    } else {
        std.mem.copyBackwards(u8, destination, source);
    }
}

fn append(output: []u8, cursor: *usize, bytes: []const u8) void {
    std.debug.assert(bytes.len <= output.len - cursor.*);
    @memcpy(output[cursor.*..][0..bytes.len], bytes);
    cursor.* += bytes.len;
}

fn appendLower(output: []u8, cursor: *usize, bytes: []const u8) void {
    std.debug.assert(bytes.len <= output.len - cursor.*);
    for (bytes) |byte| {
        output[cursor.*] = syntax.asciiLower(byte);
        cursor.* += 1;
    }
}

fn limitIssueMessage(problem: LimitIssue) []const u8 {
    return switch (problem) {
        .section_bytes_zero => "response trailer section limit must be nonzero",
        .section_bytes_above_hard_max => "response trailer section limit exceeds 1 MiB",
        .field_line_bytes_zero => "response trailer field-line limit must be nonzero",
        .field_line_bytes_above_hard_max => "response trailer field-line limit exceeds 1 MiB",
        .field_line_bytes_above_section_max => "response trailer line limit exceeds section limit",
        .declarations_zero => "response trailer declaration limit must be nonzero",
        .declarations_above_hard_max => "response trailer declaration limit exceeds 1024",
        .fields_zero => "response trailer field limit must be nonzero",
        .fields_above_hard_max => "response trailer field limit exceeds 1024",
    };
}

test "writes exact lowercase chunk framing including binary data" {
    const cases = [_]struct { data: []const u8, expected: []const u8 }{
        .{ .data = "a", .expected = "1\r\na\r\n" },
        .{ .data = "hello", .expected = "5\r\nhello\r\n" },
        .{ .data = "aaaaaaaaaaaaaaa", .expected = "f\r\naaaaaaaaaaaaaaa\r\n" },
        .{ .data = "aaaaaaaaaaaaaaaa", .expected = "10\r\naaaaaaaaaaaaaaaa\r\n" },
        .{ .data = "\x00\xff", .expected = "2\r\n\x00\xff\r\n" },
    };
    for (cases) |case| {
        var output: [64]u8 = undefined;
        const written = try writeChunk(&output, case.data);
        try std.testing.expectEqualSlices(u8, case.expected, written);
    }
}

test "writes chunk size boundaries without leading zeroes" {
    var data_255 = [_]u8{'x'} ** 255;
    var output_255: [261]u8 = undefined;
    const written_255 = try writeChunk(&output_255, &data_255);
    try std.testing.expectEqualStrings("ff\r\n", written_255[0..4]);
    try std.testing.expectEqualSlices(u8, &data_255, written_255[4..259]);
    try std.testing.expectEqualStrings("\r\n", written_255[259..]);

    var data_256 = [_]u8{'y'} ** 256;
    var output_256: [263]u8 = undefined;
    const written_256 = try writeChunk(&output_256, &data_256);
    try std.testing.expectEqualStrings("100\r\n", written_256[0..5]);
    try std.testing.expectEqualSlices(u8, &data_256, written_256[5..261]);
    try std.testing.expectEqualStrings("\r\n", written_256[261..]);
}

test "chunk preflight failures leave output unchanged" {
    var output = [_]u8{0xa5} ** 8;
    const before = output;
    try std.testing.expectError(error.EmptyChunk, writeChunk(&output, ""));
    try std.testing.expectEqualSlices(u8, &before, &output);
    try std.testing.expectError(error.OutputTooSmall, writeChunk(&output, "hello"));
    try std.testing.expectEqualSlices(u8, &before, &output);
    try std.testing.expectError(error.LengthOverflow, chunkLayout(std.math.maxInt(usize)));
    try std.testing.expectEqualSlices(u8, &before, &output);
}

test "chunk writer supports overlapping in-buffer data" {
    const expected = "5\r\nhello\r\n";
    const source_starts = [_]usize{ 0, 1, 3, 5, 8 };
    for (source_starts) |source_start| {
        var output = [_]u8{0xa5} ** 16;
        @memcpy(output[source_start..][0.."hello".len], "hello");
        const data = output[source_start..][0.."hello".len];
        const written = try writeChunk(&output, data);
        try std.testing.expectEqualStrings(expected, written);
    }
}

test "chunk writable window is the largest exact in-place payload" {
    var storage: [1024]u8 = undefined;
    for (0..storage.len + 1) |output_len| {
        const output = storage[0..output_len];
        if (output_len < 6) {
            try std.testing.expectError(error.OutputTooSmall, chunkWritable(output));
            continue;
        }
        const writable = try chunkWritable(output);
        try std.testing.expect(writable.len != 0);
        try std.testing.expect((try chunkLayout(writable.len)).total_bytes <= output_len);
        try std.testing.expect((try chunkLayout(writable.len + 1)).total_bytes > output_len);
        @memset(writable, 0xa5);
        const written = try writeChunk(output, writable);
        try std.testing.expectEqual((try chunkLayout(writable.len)).total_bytes, written.len);
    }
}

test "writes empty terminal section" {
    var output: [5]u8 = undefined;
    try std.testing.expectError(
        error.InvalidDeclaration,
        prepareTrailerPlan(standard_trailer_limits, &.{}, true),
    );
    const prepared = try prepareTrailerPlan(standard_trailer_limits, &.{}, false);
    const written = try writeTerminal(standard_trailer_limits, &output, prepared.plan, &.{});
    try std.testing.expectEqualStrings("0\r\n\r\n", written);
}

test "writes ordered lowercase fields and permits duplicate actual names" {
    const declarations = [_][]const u8{ "X-One", "X-Two", "X-Obs" };
    const fields = [_]TrailerField{
        .{ .name = "X-One", .value = "first" },
        .{ .name = "x-ONE", .value = "second" },
        .{ .name = "X-Two", .value = "" },
        .{ .name = "X-Obs", .value = "\x80" },
    };
    const expected = "0\r\n" ++
        "x-one: first\r\n" ++
        "x-one: second\r\n" ++
        "x-two: \r\n" ++
        "x-obs: \x80\r\n\r\n";
    var output: [expected.len]u8 = undefined;
    const prepared = try prepareTrailerPlan(standard_trailer_limits, &declarations, true);
    const written = try writeTerminal(standard_trailer_limits, &output, prepared.plan, &fields);
    try std.testing.expectEqualSlices(u8, expected, written);
}

test "unnegotiated plan rejects fields without output mutation" {
    const declarations = [_][]const u8{"X-One"};
    const prepared = try prepareTrailerPlan(standard_trailer_limits, &declarations, false);
    const fields = [_]TrailerField{.{ .name = "X-One", .value = "value" }};
    var output = [_]u8{0xa5} ** 64;
    const before = output;
    try std.testing.expectError(
        error.UndeclaredField,
        writeTerminal(standard_trailer_limits, &output, prepared.plan, &fields),
    );
    try std.testing.expectEqualSlices(u8, &before, &output);
}

test "mutated borrowed declarations invalidate frozen plan" {
    var name = [_]u8{ 'X', '-', 'O', 'n', 'e' };
    const declarations = [_][]const u8{&name};
    const prepared = try prepareTrailerPlan(standard_trailer_limits, &declarations, true);
    name[2] = 'T';
    var output = [_]u8{0xa5} ** 64;
    const before = output;
    try std.testing.expectError(
        error.InvalidDeclaration,
        writeTerminal(standard_trailer_limits, &output, prepared.plan, &.{}),
    );
    try std.testing.expectEqualSlices(u8, &before, &output);
}

test "rejects invalid duplicate and forbidden declarations without mutation" {
    const duplicate = [_][]const u8{ "X-One", "x-one" };
    try expectTerminalErrorUnchanged(
        standard_trailer_limits,
        &duplicate,
        &.{},
        error.DuplicateDeclaration,
    );
    try expectTerminalErrorUnchanged(
        standard_trailer_limits,
        &.{""},
        &.{},
        error.InvalidDeclaration,
    );
    try expectTerminalErrorUnchanged(
        standard_trailer_limits,
        &.{"bad name"},
        &.{},
        error.InvalidDeclaration,
    );
    try expectTerminalErrorUnchanged(
        standard_trailer_limits,
        &.{"Content-Length"},
        &.{},
        error.ForbiddenTrailer,
    );
}

test "rejects invalid undeclared forbidden and injected fields without mutation" {
    const declarations = [_][]const u8{"X-One"};
    const cases = [_]struct { field: TrailerField, expected: WriteError }{
        .{ .field = .{ .name = "bad name", .value = "x" }, .expected = error.InvalidFieldName },
        .{ .field = .{ .name = "X-Other", .value = "x" }, .expected = error.UndeclaredField },
        .{ .field = .{ .name = "Date", .value = "x" }, .expected = error.ForbiddenTrailer },
        .{
            .field = .{ .name = "X-One", .value = "x\r\ny: z" },
            .expected = error.InvalidFieldValue,
        },
        .{ .field = .{ .name = "X-One", .value = "x\t" }, .expected = error.InvalidFieldValue },
        .{ .field = .{ .name = "X-One", .value = "x\x7f" }, .expected = error.InvalidFieldValue },
    };
    for (cases) |case| {
        try expectTerminalErrorUnchanged(
            standard_trailer_limits,
            &declarations,
            &.{case.field},
            case.expected,
        );
    }
}

test "rejects duplicate known singleton trailer fields without mutation" {
    const declarations = [_][]const u8{ "ETag", "Last-Modified" };
    const etags = [_]TrailerField{
        .{ .name = "ETag", .value = "\"one\"" },
        .{ .name = "etag", .value = "\"two\"" },
    };
    try expectTerminalErrorUnchanged(
        standard_trailer_limits,
        &declarations,
        &etags,
        error.DuplicateField,
    );

    const modified = [_]TrailerField{
        .{ .name = "Last-Modified", .value = "Tue, 14 Jul 2026 12:00:00 GMT" },
        .{ .name = "last-modified", .value = "Tue, 14 Jul 2026 12:00:01 GMT" },
    };
    try expectTerminalErrorUnchanged(
        standard_trailer_limits,
        &declarations,
        &modified,
        error.DuplicateField,
    );
}

test "enforces declaration field line section and output limits without mutation" {
    const declarations = [_][]const u8{ "X", "Y" };
    const fields = [_]TrailerField{
        .{ .name = "X", .value = "1234" },
        .{ .name = "Y", .value = "5678" },
    };
    try expectTerminalErrorUnchanged(
        comptime TrailerLimits.validate(.{ .declarations_max = 1 }),
        &declarations,
        &.{},
        error.TrailerTooLarge,
    );
    try expectTerminalErrorUnchanged(
        comptime TrailerLimits.validate(.{ .fields_max = 1 }),
        &declarations,
        &fields,
        error.TrailerTooLarge,
    );
    try expectTerminalErrorUnchanged(
        comptime TrailerLimits.validate(.{
            .section_bytes_max = 32,
            .field_line_bytes_max = 8,
        }),
        &declarations,
        fields[0..1],
        error.TrailerTooLarge,
    );
    try expectTerminalErrorUnchanged(
        comptime TrailerLimits.validate(.{
            .section_bytes_max = 15,
            .field_line_bytes_max = 15,
        }),
        &declarations,
        &fields,
        error.TrailerTooLarge,
    );

    var output = [_]u8{0xa5} ** 4;
    const before = output;
    try std.testing.expectError(
        error.OutputTooSmall,
        writeTerminal(
            standard_trailer_limits,
            &output,
            (try prepareTrailerPlan(standard_trailer_limits, &.{}, false)).plan,
            &.{},
        ),
    );
    try std.testing.expectEqualSlices(u8, &before, &output);
}

test "response forbidden trailer table is complete and case insensitive" {
    try std.testing.expectEqual(
        @as(usize, 24),
        response_field_rules.forbidden_trailer_names.len,
    );
    for (response_field_rules.forbidden_trailer_names) |name| {
        try std.testing.expect(response_field_rules.isForbiddenTrailerName(name));
    }
    try std.testing.expect(response_field_rules.isForbiddenTrailerName("CONTENT-LENGTH"));
    try std.testing.expect(!response_field_rules.isForbiddenTrailerName("x-checksum"));
}

test "exact body accepts exact zero and segmented production" {
    var zero = ExactBody.init(0);
    try zero.accept(0);
    try zero.finish();

    var body = ExactBody.init(5);
    try body.accept(2);
    try body.accept(3);
    try body.finish();
    try std.testing.expectEqual(@as(u64, 5), body.produced);
}

test "exact body rejects overrun before increment and underrun at finish" {
    var body = ExactBody.init(5);
    try body.accept(3);
    try std.testing.expectError(error.Overrun, body.accept(3));
    try std.testing.expectEqual(@as(u64, 3), body.produced);
    try std.testing.expectError(error.Underrun, body.finish());
}

fn expectTerminalErrorUnchanged(
    comptime limits: TrailerLimits,
    declarations: []const []const u8,
    fields: []const TrailerField,
    expected: WriteError,
) !void {
    var output = [_]u8{0xa5} ** 256;
    const before = output;
    const plan = TrailerPlan{
        .emitted = declarations.len != 0,
        .declarations = declarations,
        .fingerprint = declarationFingerprint(declarations),
    };
    try std.testing.expectError(
        expected,
        writeTerminal(limits, &output, plan, fields),
    );
    try std.testing.expectEqualSlices(u8, &before, &output);
}
