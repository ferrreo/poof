const std = @import("std");
const fuzz_support = @import("../../../src/internal/http1/testing/smith.zig");
const limits = @import("../../../src/internal/http1/limits.zig");
const media_type = @import("../../../src/internal/http1/media_type.zig");
const response_framing = @import("../../../src/internal/http1/response_framing.zig");
const response_head = @import("../../../src/internal/http1/response_head.zig");
const response_headers = @import("../../../src/internal/http1/response_headers.zig");
const response_transfer = @import("../../../src/internal/http1/response_transfer.zig");
const status_module = @import("../../../src/internal/http1/status.zig");
const syntax = @import("../../../src/internal/http1/syntax.zig");

const input_bytes_max: usize = 512;
const output_bytes_max: usize = 768;
const sentinel: u8 = 0xa5;
const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";

const fuzz_head_limits = limits.ResponseHeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 8,
});
const fuzz_trailer_limits = response_transfer.TrailerLimits.validate(.{
    .section_bytes_max = 256,
    .field_line_bytes_max = 128,
    .declarations_max = 4,
    .fields_max = 4,
});
const FuzzHeaders = response_headers.Headers(fuzz_head_limits);

const Parts = struct {
    status: status_module.Status,
    mutation: u8,
    flags: u8,
    output_cap: u8,
    header_name: []const u8,
    header_value: []const u8,
    trailer_name: []const u8,
    trailer_value: []const u8,
};

test "response serialization invariants fuzz" {
    try std.testing.fuzz({}, fuzzResponse, .{ .corpus = &response_fuzz_corpus });
}

const response_fuzz_corpus = struct {
    const fixed = fuzz_support.smithInput(
        "\x64\x00\x00\x01\xffX-Test\x00value\x00X-One\x00digest",
    );
    const streamed = fuzz_support.smithInput(
        "\x64\x00\x01\x3a\xffSet-Cookie\x00a=1\x00x-one\x00complete",
    );
    const injected = fuzz_support.smithInput(
        "\x64\x00\x00\x01\xffX-Test\x00bad\r\nx: yes\x00X-One\x00bad\r\ny: yes",
    );
    const reserved = fuzz_support.smithInput(
        "\x64\x00\x01\x01\xffContent-Length\x007\x00Content-Length\x007",
    );
    const tiny_output = fuzz_support.smithInput(
        "\x64\x00\x02\x01\x00X-Test\x00value\x00X-Escape\x00value",
    );
    const invalid_status = fuzz_support.smithInput(
        "\x00\x00\x00\x01\xffX-Test\x00value\x00X-One\x00value",
    );
    const mismatched_trailers = fuzz_support.smithInput(
        "\x64\x00\x00\x12\xffX-Test\x00value\x00X-One\x00value",
    );

    const values = [_][]const u8{
        &fixed,
        &streamed,
        &injected,
        &reserved,
        &tiny_output,
        &invalid_status,
        &mismatched_trailers,
    };
}.values;

fn fuzzResponse(_: void, smith: *std.testing.Smith) !void {
    var storage: [input_bytes_max]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];
    const parts = splitInput(input);

    var headers = try checkHeaderTransactions(parts);
    try checkFuzzHead(parts, &headers);
    try checkTerminalPlan(parts);
    try checkTamperedPlan();
}

fn splitInput(input: []const u8) Parts {
    const raw_status = @as(u16, inputByte(input, 0, 100)) |
        (@as(u16, inputByte(input, 1, 0)) << 8);
    const status_value: u16 = 100 + raw_status % 600;
    const payload = if (input.len > 5) input[5..] else "";
    var segments = [_][]const u8{""} ** 4;
    var iterator = std.mem.splitScalar(u8, payload, 0);
    for (&segments) |*segment| segment.* = iterator.next() orelse "";
    return .{
        .status = @enumFromInt(status_value),
        .mutation = inputByte(input, 2, 0),
        .flags = inputByte(input, 3, 1),
        .output_cap = inputByte(input, 4, 0xff),
        .header_name = segments[0],
        .header_value = segments[1],
        .trailer_name = segments[2],
        .trailer_value = segments[3],
    };
}

fn inputByte(input: []const u8, index: usize, fallback: u8) u8 {
    return if (index < input.len) input[index] else fallback;
}

fn checkHeaderTransactions(parts: Parts) !FuzzHeaders {
    var headers = FuzzHeaders{};
    try headers.append("x-seed", "stable");

    const borrowed = headers.at(0).name;
    const before_alias = headers;
    try std.testing.expectError(error.AliasedInput, headers.remove(borrowed));
    try std.testing.expectEqualDeep(before_alias, headers);

    const before_mutation = headers;
    mutateHeaders(&headers, parts) catch {
        try std.testing.expectEqualDeep(before_mutation, headers);
    };
    return headers;
}

fn mutateHeaders(headers: *FuzzHeaders, parts: Parts) response_headers.MutationError!void {
    return switch (parts.mutation % 3) {
        0 => headers.set(parts.header_name, parts.header_value),
        1 => headers.append(parts.header_name, parts.header_value),
        2 => headers.remove(parts.header_name),
        else => unreachable,
    };
}

fn checkFuzzHead(parts: Parts, headers: *FuzzHeaders) !void {
    const names_storage = [_][]const u8{parts.trailer_name};
    const names: []const []const u8 = if (parts.flags & 0x20 != 0)
        &names_storage
    else
        &.{};
    const input = makeHeadInput(parts, names);
    var output = [_]u8{sentinel} ** output_bytes_max;
    const before = output;
    const capacity = outputCapacity(parts.output_cap);
    const result = response_head.write(
        fuzz_head_limits,
        fuzz_trailer_limits,
        output[0..capacity],
        input,
        headers,
    ) catch {
        try std.testing.expectEqualSlices(u8, &before, &output);
        return;
    };

    try checkReportedOutput(&output, &before, result.bytes);
    try checkHeadWire(result.bytes, input, headers, result.plan);
}

fn makeHeadInput(parts: Parts, names: []const []const u8) response_head.HeadInput {
    return .{
        .framing = .{
            .status = parts.status,
            .request_is_head = parts.flags & 0x04 != 0,
            .request_accepts_trailers = parts.flags & 0x08 != 0,
            .body = bodyFromFlags(parts.flags, parts.header_value.len),
            .trailers_declared = parts.flags & 0x10 != 0,
        },
        .default_content_type = media_type.text,
        .trailer_names = names,
        .date = fixed_date,
        .connection_close = parts.flags & 0x40 != 0,
    };
}

fn bodyFromFlags(flags: u8, length: usize) response_framing.Body {
    return switch (flags & 0x03) {
        0 => .none,
        1 => .{ .fixed = @intCast(length) },
        2 => .stream_unknown,
        3 => .{ .stream_exact = @intCast(length) },
        else => unreachable,
    };
}

fn outputCapacity(encoded: u8) usize {
    return if (encoded == 0xff) output_bytes_max else encoded;
}

fn checkHeadWire(
    wire: []const u8,
    input: response_head.HeadInput,
    headers: *const FuzzHeaders,
    plan: response_framing.Plan,
) !void {
    try std.testing.expect(std.mem.startsWith(u8, wire, "HTTP/1.1 "));
    try checkCrlfWire(wire);
    const expected = expectedHeadShape(input, headers, plan);
    try std.testing.expectEqual(expected.bytes, wire.len);
    try std.testing.expectEqual(expected.line_ends, std.mem.count(u8, wire, "\r\n"));
}

const WireShape = struct {
    bytes: usize = 0,
    line_ends: usize = 0,
};

fn expectedHeadShape(
    input: response_head.HeadInput,
    headers: *const FuzzHeaders,
    plan: response_framing.Plan,
) WireShape {
    var shape = WireShape{
        .bytes = "HTTP/1.1 ".len + 3 + 1 + input.framing.status.reasonPhrase().len + 2,
        .line_ends = 1,
    };
    var stored_content_type = false;
    var index: usize = 0;
    while (index < headers.len()) : (index += 1) {
        const field = headers.at(index);
        const is_type = syntax.eqlIgnoreCase(field.name, "content-type");
        stored_content_type = stored_content_type or is_type;
        if (!is_type or plan.emit_content_type) {
            addFieldShape(&shape, field.name.len, field.value.len);
        }
    }
    if (plan.emit_content_type and !stored_content_type) {
        addFieldShape(&shape, "content-type".len, input.default_content_type.bytes().len);
    }
    switch (plan.framing) {
        .none => {},
        .fixed => |length| addFieldShape(&shape, "content-length".len, decimalLength(length)),
        .chunked => addFieldShape(&shape, "transfer-encoding".len, "chunked".len),
    }
    if (plan.emit_trailers) {
        var names_bytes: usize = 0;
        for (input.trailer_names, 0..) |name, name_index| {
            names_bytes += name.len + @as(usize, if (name_index == 0) 0 else 2);
        }
        addFieldShape(&shape, "trailer".len, names_bytes);
    }
    addFieldShape(&shape, "date".len, input.date.len);
    if (input.server_identity) |identity| addFieldShape(&shape, "server".len, identity.value.len);
    if (input.connection_close) addFieldShape(&shape, "connection".len, "close".len);
    shape.bytes += 2;
    shape.line_ends += 1;
    return shape;
}

fn addFieldShape(shape: *WireShape, name_bytes: usize, value_bytes: usize) void {
    shape.bytes += name_bytes + ": ".len + value_bytes + "\r\n".len;
    shape.line_ends += 1;
}

fn decimalLength(value: u64) usize {
    var remaining = value;
    var digits: usize = 1;
    while (remaining >= 10) : (digits += 1) remaining /= 10;
    return digits;
}

fn checkTerminalPlan(parts: Parts) !void {
    const names = [_][]const u8{"X-One"};
    var headers = FuzzHeaders{};
    var head_output: [output_bytes_max]u8 = undefined;
    const committed = try response_head.write(
        fuzz_head_limits,
        fuzz_trailer_limits,
        &head_output,
        committedHeadInput(&names),
        &headers,
    );
    try std.testing.expect(committed.trailer_plan.emitted);

    const fields = [_]response_transfer.TrailerField{.{
        .name = parts.trailer_name,
        .value = parts.trailer_value,
    }};
    var output = [_]u8{sentinel} ** output_bytes_max;
    const before = output;
    const terminal = response_transfer.writeTerminal(
        fuzz_trailer_limits,
        &output,
        committed.trailer_plan,
        &fields,
    ) catch {
        try std.testing.expectEqualSlices(u8, &before, &output);
        return;
    };

    try std.testing.expect(syntax.eqlIgnoreCase(parts.trailer_name, "X-One"));
    try checkReportedOutput(&output, &before, terminal);
    try checkTerminalWire(terminal, &fields);
}

fn committedHeadInput(names: []const []const u8) response_head.HeadInput {
    return .{
        .framing = .{
            .status = .ok,
            .request_is_head = false,
            .request_accepts_trailers = true,
            .body = .stream_unknown,
            .trailers_declared = true,
        },
        .default_content_type = media_type.text,
        .trailer_names = names,
        .date = fixed_date,
    };
}

fn checkTamperedPlan() !void {
    var name = [_]u8{ 'X', '-', 'O', 'n', 'e' };
    const names = [_][]const u8{&name};
    var headers = FuzzHeaders{};
    var head_output: [output_bytes_max]u8 = undefined;
    const committed = try response_head.write(
        fuzz_head_limits,
        fuzz_trailer_limits,
        &head_output,
        committedHeadInput(&names),
        &headers,
    );
    name[0] = 'Y';
    const fields = [_]response_transfer.TrailerField{.{
        .name = "Y-One",
        .value = "escaped",
    }};
    var output = [_]u8{sentinel} ** output_bytes_max;
    const before = output;
    try std.testing.expectError(
        error.InvalidDeclaration,
        response_transfer.writeTerminal(
            fuzz_trailer_limits,
            &output,
            committed.trailer_plan,
            &fields,
        ),
    );
    try std.testing.expectEqualSlices(u8, &before, &output);
}

fn checkReportedOutput(output: []const u8, before: []const u8, written: []const u8) !void {
    try std.testing.expectEqual(@intFromPtr(output.ptr), @intFromPtr(written.ptr));
    try std.testing.expect(written.len <= output.len);
    try std.testing.expectEqualSlices(u8, before[written.len..], output[written.len..]);
}

fn checkTerminalWire(wire: []const u8, fields: []const response_transfer.TrailerField) !void {
    try std.testing.expect(std.mem.startsWith(u8, wire, "0\r\n"));
    try checkCrlfWire(wire);
    var expected_bytes: usize = "0\r\n\r\n".len;
    for (fields) |field| expected_bytes += field.name.len + 2 + field.value.len + 2;
    try std.testing.expectEqual(expected_bytes, wire.len);
    try std.testing.expectEqual(fields.len + 2, std.mem.count(u8, wire, "\r\n"));
}

fn checkCrlfWire(wire: []const u8) !void {
    try std.testing.expect(wire.len >= 4);
    try std.testing.expect(std.mem.endsWith(u8, wire, "\r\n\r\n"));
    const terminator = std.mem.indexOf(u8, wire, "\r\n\r\n") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(wire.len - 4, terminator);
    for (wire, 0..) |byte, index| {
        if (byte == '\r') {
            try std.testing.expect(index + 1 < wire.len);
            try std.testing.expect(wire[index + 1] == '\n');
        } else if (byte == '\n') {
            try std.testing.expect(index != 0);
            try std.testing.expect(wire[index - 1] == '\r');
        } else {
            try std.testing.expect(byte >= 0x20);
            try std.testing.expect(byte != 0x7f);
        }
    }
}
