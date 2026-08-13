const std = @import("std");
const limits = @import("limits.zig");
const media_type = @import("media_type.zig");
const response_field_rules = @import("response_field_rules.zig");
const response_framing = @import("response_framing.zig");
const response_headers = @import("response_headers.zig");
const response_transfer = @import("response_transfer.zig");
const status_module = @import("status.zig");
const syntax = @import("syntax.zig");

const status_prefix = "HTTP/1.1 ";
const line_end = "\r\n";
const field_separator = ": ";
const content_type_name = "content-type";
const content_length_name = "content-length";
const transfer_encoding_name = "transfer-encoding";
const trailer_name = "trailer";
const date_name = "date";
const server_name = "server";
const connection_name = "connection";
const decimal_digits_max: usize = @sizeOf(u64) * 3;

pub const ServerIdentity = struct {
    value: []const u8,

    pub fn init(comptime value: []const u8) ServerIdentity {
        if (comptime value.len == 0 or !validFieldValue(value)) {
            @compileError("PLOOF-E3047 invalid static Server identity");
        }
        return .{ .value = value };
    }
};

pub const HeadInput = struct {
    framing: response_framing.Input,
    default_content_type: media_type.MediaType,
    trailer_names: []const []const u8 = &.{},
    date: []const u8,
    server_identity: ?ServerIdentity = null,
    connection_close: bool = false,
};

pub const WriteResult = struct {
    bytes: []u8,
    plan: response_framing.Plan,
    trailer_plan: response_transfer.TrailerPlan,
};

pub const WriteError = error{
    InvalidDate,
    InvalidHeader,
    InvalidResponse,
    InvalidTrailer,
    OutputTooSmall,
    ResponseHeadTooLarge,
    TrailerTooLarge,
};

const Layout = struct {
    head_bytes: usize = 0,
    fields_count: usize = 0,
    stored_content_type: bool = false,
};

pub fn write(
    comptime requested: limits.ResponseHeadLimits,
    comptime requested_trailers: response_transfer.TrailerLimits,
    output: []u8,
    input: HeadInput,
    headers: anytype,
) WriteError!WriteResult {
    const profile = comptime requested.validate();
    const trailer_profile = comptime requested_trailers.validate();
    const plan = response_framing.plan(input.framing) catch return error.InvalidResponse;
    const trailers_present = input.trailer_names.len != 0;
    if (input.framing.trailers_declared != trailers_present) return error.InvalidTrailer;
    const trailers = response_transfer.prepareTrailerPlan(
        trailer_profile,
        input.trailer_names,
        plan.emit_trailers,
    ) catch |err| switch (err) {
        error.TrailerTooLarge => return error.TrailerTooLarge,
        error.LengthOverflow => return error.ResponseHeadTooLarge,
        error.InvalidDeclaration,
        error.DuplicateDeclaration,
        error.ForbiddenTrailer,
        => return error.InvalidTrailer,
    };
    const layout = try preflight(
        profile,
        input,
        headers,
        plan,
        trailers.serialized_name_bytes,
    );
    if (output.len < layout.head_bytes) return error.OutputTooSmall;

    var cursor: usize = 0;
    emit(output, &cursor, input, headers, plan, layout);
    std.debug.assert(cursor == layout.head_bytes);
    return .{ .bytes = output[0..cursor], .plan = plan, .trailer_plan = trailers.plan };
}

fn preflight(
    profile: limits.ResponseHeadLimits,
    input: HeadInput,
    headers: anytype,
    plan: response_framing.Plan,
    trailer_value_bytes: usize,
) WriteError!Layout {
    var layout = Layout{};
    try addStatusLine(profile, &layout, input.framing.status);
    layout.stored_content_type = try addApplicationFields(profile, &layout, headers, plan);

    if (plan.emit_content_type and !layout.stored_content_type) {
        try validateField(
            profile,
            &layout,
            content_type_name,
            input.default_content_type.bytes(),
            true,
        );
    }
    switch (plan.framing) {
        .none => {},
        .fixed => |length| try addFieldBytes(
            profile,
            &layout,
            content_length_name.len,
            decimalLength(length),
        ),
        .chunked => try addFieldBytes(
            profile,
            &layout,
            transfer_encoding_name.len,
            "chunked".len,
        ),
    }

    if (input.trailer_names.len != 0) {
        _ = try fieldLineBytes(profile, trailer_name.len, trailer_value_bytes);
    }
    if (plan.emit_trailers) {
        try addFieldBytes(profile, &layout, trailer_name.len, trailer_value_bytes);
    }
    try validateDate(profile, &layout, input.date);
    if (input.server_identity) |identity| {
        try validateField(profile, &layout, server_name, identity.value, true);
    }
    if (input.connection_close) {
        try addFieldBytes(profile, &layout, connection_name.len, "close".len);
    }
    try addHeadBytes(profile, &layout, line_end.len);
    return layout;
}

fn addApplicationFields(
    profile: limits.ResponseHeadLimits,
    layout: *Layout,
    headers: anytype,
    plan: response_framing.Plan,
) WriteError!bool {
    if (headers.len() > limits.fields_hard_max) return error.ResponseHeadTooLarge;
    var stored_content_type = false;
    var index: usize = 0;
    while (index < headers.len()) : (index += 1) {
        const field = headers.at(index);
        if (field.name.len > profile.field_line_bytes_max) {
            return error.ResponseHeadTooLarge;
        }
        if (!syntax.isToken(field.name)) return error.InvalidHeader;
        if (response_field_rules.isOwnedName(field.name)) return error.InvalidHeader;
        const is_content_type = syntax.eqlIgnoreCase(field.name, content_type_name);
        if (is_content_type and stored_content_type) return error.InvalidHeader;
        if (is_content_type) {
            _ = media_type.parse(field.value) catch return error.InvalidHeader;
        }
        if (is_content_type) stored_content_type = true;
        if (is_content_type and !plan.emit_content_type) continue;
        try validateField(profile, layout, field.name, field.value, is_content_type);
    }
    return stored_content_type;
}

fn validateField(
    profile: limits.ResponseHeadLimits,
    layout: *Layout,
    name: []const u8,
    value: []const u8,
    require_value: bool,
) WriteError!void {
    try addFieldBytes(profile, layout, name.len, value.len);
    if (!validFieldValue(value)) return error.InvalidHeader;
    if (require_value and value.len == 0) return error.InvalidHeader;
}

fn validateDate(
    profile: limits.ResponseHeadLimits,
    layout: *Layout,
    date: []const u8,
) WriteError!void {
    try addFieldBytes(profile, layout, date_name.len, date.len);
    if (date.len == 0 or !validFieldValue(date)) return error.InvalidDate;
}

fn addStatusLine(
    profile: limits.ResponseHeadLimits,
    layout: *Layout,
    status: status_module.Status,
) WriteError!void {
    const phrase = status.reasonPhrase();
    var bytes: usize = status_prefix.len + 3 + 1;
    try addToLimit(&bytes, phrase.len, profile.head_bytes_max);
    try addToLimit(&bytes, line_end.len, profile.head_bytes_max);
    try addHeadBytes(profile, layout, bytes);
}

fn addFieldBytes(
    profile: limits.ResponseHeadLimits,
    layout: *Layout,
    name_bytes: usize,
    value_bytes: usize,
) WriteError!void {
    const bytes = try fieldLineBytes(profile, name_bytes, value_bytes);
    if (layout.fields_count == profile.fields_max) return error.ResponseHeadTooLarge;
    try addHeadBytes(profile, layout, bytes);
    layout.fields_count += 1;
}

fn fieldLineBytes(
    profile: limits.ResponseHeadLimits,
    name_bytes: usize,
    value_bytes: usize,
) WriteError!usize {
    var bytes: usize = 0;
    try addToLimit(&bytes, name_bytes, profile.field_line_bytes_max);
    try addToLimit(&bytes, field_separator.len, profile.field_line_bytes_max);
    try addToLimit(&bytes, value_bytes, profile.field_line_bytes_max);
    try addToLimit(&bytes, line_end.len, profile.field_line_bytes_max);
    return bytes;
}

fn addHeadBytes(
    profile: limits.ResponseHeadLimits,
    layout: *Layout,
    amount: usize,
) WriteError!void {
    try addToLimit(&layout.head_bytes, amount, profile.head_bytes_max);
}

fn addToLimit(total: *usize, amount: usize, maximum: u32) WriteError!void {
    if (amount > maximum or total.* > maximum - amount) {
        return error.ResponseHeadTooLarge;
    }
    total.* += amount;
}

pub fn validFieldValue(value: []const u8) bool {
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn emit(
    output: []u8,
    cursor: *usize,
    input: HeadInput,
    headers: anytype,
    plan: response_framing.Plan,
    layout: Layout,
) void {
    append(output, cursor, status_prefix);
    const code = input.framing.status.codeBytes();
    append(output, cursor, &code);
    append(output, cursor, " ");
    append(output, cursor, input.framing.status.reasonPhrase());
    append(output, cursor, line_end);

    emitApplication(output, cursor, headers, plan.emit_content_type);
    if (plan.emit_content_type and !layout.stored_content_type) {
        appendField(output, cursor, content_type_name, input.default_content_type.bytes());
    }
    emitFraming(output, cursor, plan.framing);
    if (plan.emit_trailers) emitTrailers(output, cursor, input.trailer_names);
    appendField(output, cursor, date_name, input.date);
    if (input.server_identity) |identity| {
        appendField(output, cursor, server_name, identity.value);
    }
    if (input.connection_close) appendField(output, cursor, connection_name, "close");
    append(output, cursor, line_end);
}

fn emitApplication(output: []u8, cursor: *usize, headers: anytype, emit_type: bool) void {
    var index: usize = 0;
    while (index < headers.len()) : (index += 1) {
        const field = headers.at(index);
        if (!emit_type and syntax.eqlIgnoreCase(field.name, content_type_name)) continue;
        appendField(output, cursor, field.name, field.value);
    }
}

fn emitFraming(output: []u8, cursor: *usize, framing: response_framing.Framing) void {
    switch (framing) {
        .none => {},
        .fixed => |length| {
            append(output, cursor, content_length_name);
            append(output, cursor, field_separator);
            const digits = decimalLength(length);
            writeDecimal(output[cursor.*..][0..digits], length);
            cursor.* += digits;
            append(output, cursor, line_end);
        },
        .chunked => appendField(output, cursor, transfer_encoding_name, "chunked"),
    }
}

fn emitTrailers(output: []u8, cursor: *usize, names: []const []const u8) void {
    append(output, cursor, trailer_name);
    append(output, cursor, field_separator);
    for (names, 0..) |name, index| {
        if (index != 0) append(output, cursor, ", ");
        appendLower(output, cursor, name);
    }
    append(output, cursor, line_end);
}

fn appendField(output: []u8, cursor: *usize, name: []const u8, value: []const u8) void {
    appendLower(output, cursor, name);
    append(output, cursor, field_separator);
    append(output, cursor, value);
    append(output, cursor, line_end);
}

fn appendLower(output: []u8, cursor: *usize, bytes: []const u8) void {
    std.debug.assert(bytes.len <= output.len - cursor.*);
    for (bytes) |byte| {
        output[cursor.*] = syntax.asciiLower(byte);
        cursor.* += 1;
    }
}

fn append(output: []u8, cursor: *usize, bytes: []const u8) void {
    std.debug.assert(bytes.len <= output.len - cursor.*);
    @memcpy(output[cursor.*..][0..bytes.len], bytes);
    cursor.* += bytes.len;
}

fn decimalLength(value: u64) usize {
    var remaining = value;
    var digits: usize = 1;
    while (remaining >= 10) : (digits += 1) {
        std.debug.assert(digits < decimal_digits_max);
        remaining /= 10;
    }
    return digits;
}

fn writeDecimal(output: []u8, value: u64) void {
    std.debug.assert(output.len == decimalLength(value));
    var remaining = value;
    var index = output.len;
    while (index > 0) {
        index -= 1;
        output[index] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
    }
    std.debug.assert(remaining == 0);
}

const StandardHeaders = response_headers.Headers(limits.standard_response_head_limits);
const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";

const FakeHeaders = struct {
    fields: []const response_headers.Field,

    pub fn len(self: *const FakeHeaders) usize {
        return self.fields.len;
    }

    pub fn at(self: *const FakeHeaders, index: usize) response_headers.Field {
        return self.fields[index];
    }
};

fn testInput(status: status_module.Status, body: response_framing.Body) HeadInput {
    return .{
        .framing = .{
            .status = status,
            .request_is_head = false,
            .request_accepts_trailers = false,
            .body = body,
            .trailers_declared = false,
        },
        .default_content_type = media_type.text,
        .date = fixed_date,
    };
}

test "writes exact ping head" {
    var headers = StandardHeaders{};
    var output: [256]u8 = undefined;
    const result = try write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        &output,
        testInput(.ok, .{ .fixed = 4 }),
        &headers,
    );
    const expected =
        "HTTP/1.1 200 OK\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 4\r\n" ++
        "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
        "\r\n";
    try std.testing.expectEqualStrings(expected, result.bytes);
    try std.testing.expectEqualDeep(
        try response_framing.plan(testInput(.ok, .{ .fixed = 4 }).framing),
        result.plan,
    );
}

test "preserves app order cookies and content type override" {
    var headers = StandardHeaders{};
    try headers.append("X-First", "one");
    try headers.set("Content-Type", "application/json");
    try headers.append("Set-Cookie", "a=1");
    try headers.append("set-cookie", "b=2");
    var output: [512]u8 = undefined;
    const result = try write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        &output,
        testInput(.ok, .{ .fixed = 2 }),
        &headers,
    );
    const expected =
        "HTTP/1.1 200 OK\r\n" ++
        "x-first: one\r\n" ++
        "content-type: application/json\r\n" ++
        "set-cookie: a=1\r\n" ++
        "set-cookie: b=2\r\n" ++
        "content-length: 2\r\n" ++
        "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
        "\r\n";
    try std.testing.expectEqualStrings(expected, result.bytes);
}

test "bodyless statuses select unambiguous framing" {
    const cases = [_]struct {
        status: status_module.Status,
        line: []const u8,
        content_length_zero: bool,
    }{
        .{
            .status = .no_content,
            .line = "HTTP/1.1 204 No Content\r\n",
            .content_length_zero = false,
        },
        .{
            .status = .reset_content,
            .line = "HTTP/1.1 205 Reset Content\r\n",
            .content_length_zero = true,
        },
        .{
            .status = .not_modified,
            .line = "HTTP/1.1 304 Not Modified\r\n",
            .content_length_zero = false,
        },
    };
    for (cases) |case| {
        var headers = StandardHeaders{};
        try headers.set("content-type", "text/plain");
        var output: [256]u8 = undefined;
        const result = try write(
            limits.standard_response_head_limits,
            response_transfer.standard_trailer_limits,
            &output,
            testInput(case.status, .none),
            &headers,
        );
        try std.testing.expect(std.mem.startsWith(u8, result.bytes, case.line));
        try std.testing.expect(std.mem.indexOf(u8, result.bytes, "content-type") == null);
        const content_length = std.mem.indexOf(u8, result.bytes, "content-length: 0\r\n");
        try std.testing.expectEqual(case.content_length_zero, content_length != null);
        try std.testing.expect(std.mem.indexOf(u8, result.bytes, "transfer-encoding") == null);
    }
}

test "HEAD emits only known hypothetical framing" {
    var headers = StandardHeaders{};
    var fixed_input = testInput(.ok, .{ .fixed = 17 });
    fixed_input.framing.request_is_head = true;
    var output: [512]u8 = undefined;
    const fixed = try write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        &output,
        fixed_input,
        &headers,
    );
    try std.testing.expect(std.mem.indexOf(u8, fixed.bytes, "content-length: 17") != null);

    const names = [_][]const u8{ "content-digest", "digest" };
    var unknown_input = testInput(.ok, .stream_unknown);
    unknown_input.framing.request_is_head = true;
    unknown_input.framing.request_accepts_trailers = true;
    unknown_input.framing.trailers_declared = true;
    unknown_input.trailer_names = &names;
    const unknown = try write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        &output,
        unknown_input,
        &headers,
    );
    try std.testing.expect(std.mem.indexOf(u8, unknown.bytes, "content-length") == null);
    try std.testing.expect(std.mem.indexOf(u8, unknown.bytes, "transfer-encoding") == null);
    try std.testing.expect(std.mem.indexOf(u8, unknown.bytes, "trailer:") == null);
    try std.testing.expect(std.mem.indexOf(u8, unknown.bytes, "content-type:") != null);
}

test "chunked trailers require negotiation and emit one declaration" {
    const names = [_][]const u8{ "Content-Digest", "Digest" };
    var headers = StandardHeaders{};
    var stream_input = testInput(.ok, .stream_unknown);
    stream_input.framing.trailers_declared = true;
    stream_input.trailer_names = &names;
    var output: [512]u8 = undefined;

    const unnegotiated = try write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        &output,
        stream_input,
        &headers,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, unnegotiated.bytes, "transfer-encoding: chunked") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, unnegotiated.bytes, "trailer:") == null);

    stream_input.framing.request_accepts_trailers = true;
    const negotiated = try write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        &output,
        stream_input,
        &headers,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, negotiated.bytes, "trailer: content-digest, digest\r\n") != null,
    );
}

test "connection close and unknown status serialize deterministically" {
    var headers = StandardHeaders{};
    var custom = testInput(@enumFromInt(299), .none);
    custom.connection_close = true;
    var output: [256]u8 = undefined;
    const result = try write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        &output,
        custom,
        &headers,
    );
    try std.testing.expect(std.mem.startsWith(u8, result.bytes, "HTTP/1.1 299 \r\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "connection: close\r\n") != null);
}

test "validation failures leave output unchanged" {
    var headers = StandardHeaders{};
    const bad_status = testInput(@enumFromInt(100), .none);
    try expectUnchanged(error.InvalidResponse, bad_status, &headers);

    var bad_date = testInput(.ok, .none);
    bad_date.date = "bad\r\ndate";
    try expectUnchanged(error.InvalidDate, bad_date, &headers);

    var missing_names = testInput(.ok, .stream_unknown);
    missing_names.framing.trailers_declared = true;
    try expectUnchanged(error.InvalidTrailer, missing_names, &headers);

    const bad_names = [_][]const u8{"bad name"};
    var bad_trailer = missing_names;
    bad_trailer.trailer_names = &bad_names;
    try expectUnchanged(error.InvalidTrailer, bad_trailer, &headers);

    const duplicate_names = [_][]const u8{ "Digest", "digest" };
    var duplicate_trailer = missing_names;
    duplicate_trailer.trailer_names = &duplicate_names;
    try expectUnchanged(error.InvalidTrailer, duplicate_trailer, &headers);

    const orphan_names = [_][]const u8{"digest"};
    var orphan_trailer = testInput(.ok, .stream_unknown);
    orphan_trailer.trailer_names = &orphan_names;
    try expectUnchanged(error.InvalidTrailer, orphan_trailer, &headers);

    const invalid_type_fields = [_]response_headers.Field{
        .{ .name = "Content-Type", .value = "text/plain; charset=\"unterminated" },
    };
    const invalid_type = FakeHeaders{ .fields = &invalid_type_fields };
    try expectUnchanged(error.InvalidHeader, testInput(.ok, .none), &invalid_type);

    const injected_fields = [_]response_headers.Field{
        .{ .name = "x-test", .value = "bad\nvalue" },
    };
    const injected = FakeHeaders{ .fields = &injected_fields };
    try expectUnchanged(error.InvalidHeader, testInput(.ok, .none), &injected);
}

test "capacity failures leave output unchanged" {
    var headers = StandardHeaders{};
    const reserved_fields = [_]response_headers.Field{
        .{ .name = "Content-Length", .value = "7" },
    };
    const reserved = FakeHeaders{ .fields = &reserved_fields };
    try expectUnchanged(error.InvalidHeader, testInput(.ok, .none), &reserved);

    const line_limit = limits.ResponseHeadLimits{
        .head_bytes_max = 128,
        .field_line_bytes_max = 16,
        .fields_max = 8,
    };
    try expectUnchangedWith(
        line_limit,
        error.ResponseHeadTooLarge,
        testInput(.ok, .none),
        &headers,
    );
    const count_limit = limits.ResponseHeadLimits{
        .head_bytes_max = 128,
        .field_line_bytes_max = 64,
        .fields_max = 1,
    };
    try expectUnchangedWith(
        count_limit,
        error.ResponseHeadTooLarge,
        testInput(.ok, .none),
        &headers,
    );
    const head_limit = limits.ResponseHeadLimits{
        .head_bytes_max = 64,
        .field_line_bytes_max = 64,
        .fields_max = 8,
    };
    try expectUnchangedWith(
        head_limit,
        error.ResponseHeadTooLarge,
        testInput(.ok, .none),
        &headers,
    );

    var small = [_]u8{0xa5} ** 1;
    const small_before = small;
    try std.testing.expectError(
        error.OutputTooSmall,
        write(
            limits.standard_response_head_limits,
            response_transfer.standard_trailer_limits,
            &small,
            testInput(.ok, .none),
            &headers,
        ),
    );
    try std.testing.expectEqualSlices(u8, &small_before, &small);
}

test "every forbidden trailer name rejects while digest names remain allowed" {
    var headers = StandardHeaders{};
    for (response_field_rules.forbidden_trailer_names) |name| {
        const names = [_][]const u8{name};
        var trailer_input = testInput(.ok, .stream_unknown);
        trailer_input.framing.trailers_declared = true;
        trailer_input.trailer_names = &names;
        try expectUnchanged(error.InvalidTrailer, trailer_input, &headers);
    }

    const allowed = [_][]const u8{ "content-digest", "digest" };
    var trailer_input = testInput(.ok, .stream_unknown);
    trailer_input.framing.trailers_declared = true;
    trailer_input.trailer_names = &allowed;
    var output: [512]u8 = undefined;
    _ = try write(
        limits.standard_response_head_limits,
        response_transfer.standard_trailer_limits,
        &output,
        trailer_input,
        &headers,
    );
}

test "trailer declaration limit rejects before response head mutation" {
    const names = [_][]const u8{ "digest", "content-digest" };
    var input = testInput(.ok, .stream_unknown);
    input.framing.trailers_declared = true;
    input.trailer_names = &names;
    var headers = StandardHeaders{};
    var output = [_]u8{0xa5} ** 256;
    const before = output;

    try std.testing.expectError(
        error.TrailerTooLarge,
        write(
            limits.standard_response_head_limits,
            comptime response_transfer.TrailerLimits.validate(.{ .declarations_max = 1 }),
            &output,
            input,
            &headers,
        ),
    );
    try std.testing.expectEqualSlices(u8, &before, &output);
}

fn expectUnchanged(expected: WriteError, head: HeadInput, headers: anytype) !void {
    return expectUnchangedWith(
        limits.standard_response_head_limits,
        expected,
        head,
        headers,
    );
}

fn expectUnchangedWith(
    comptime profile: limits.ResponseHeadLimits,
    expected: WriteError,
    head: HeadInput,
    headers: anytype,
) !void {
    var output = [_]u8{0xa5} ** 256;
    const before = output;
    try std.testing.expectError(
        expected,
        write(
            profile,
            response_transfer.standard_trailer_limits,
            &output,
            head,
            headers,
        ),
    );
    try std.testing.expectEqualSlices(u8, &before, &output);
}
