const std = @import("std");
const fuzz_support = @import("../../../src/internal/http1/testing/smith.zig");
const request_head = @import("../../../src/internal/http1/request_head.zig");
const request_trailers = @import("../../../src/internal/http1/request_trailers.zig");

const declaration_names_max: u16 = 8;
const fuzz_limits = request_trailers.Limits.validate(.{
    .section_bytes_max = 128,
    .field_line_bytes_max = 64,
    .fields_max = 8,
});
const DeclarationSet = request_trailers.Declarations(declaration_names_max);
const TrailerDecoder = request_trailers.Decoder(fuzz_limits, declaration_names_max);

const Terminal = enum(u8) {
    need_more,
    ready,
    rejected,
};

const Snapshot = struct {
    consumed: usize,
    bytes_count: usize,
    fields_count: usize,
    wire_bytes: u64,
    rejection_code: u16,
    terminal: Terminal,
};

const Parts = struct {
    declaration: []const u8,
    trailers: []const u8,
    wire_bytes_max: u64,
};

test "request trailer declaration and fragmentation fuzz" {
    try std.testing.fuzz({}, fuzzRequestTrailers, .{
        .corpus = &request_trailers_fuzz_corpus,
    });
}

const request_trailers_fuzz_corpus = struct {
    const valid = fuzz_support.smithInput("X-One\x00\x40X-One: value\r\n\r\nNEXT");
    const reordered = fuzz_support.smithInput(
        "X-One, X-Two\x00\x40X-Two: two\r\nX-One: one\r\n\r\n",
    );
    const forbidden = fuzz_support.smithInput("Host\x00\x40Host: value\r\n\r\n");
    const undeclared = fuzz_support.smithInput(
        "X-One\x00\x40X-Other: value\r\n\r\n",
    );
    const bare_lf = fuzz_support.smithInput("X-One\x00\x40X-One: value\n\n");
    const overflow = fuzz_support.smithInput(
        "X-One\x00\xffX-One: " ++
            "012345678901234567890123456789012345678901234567890123456789\r\n\r\n",
    );
    const budget = fuzz_support.smithInput("X-One\x00\x01\r\n");
    const empty_members = fuzz_support.smithInput(
        ",X-One,,\x00\x40X-One: value\r\n\r\n",
    );

    const values = [_][]const u8{
        &valid,
        &reordered,
        &forbidden,
        &undeclared,
        &bare_lf,
        &overflow,
        &budget,
        &empty_members,
    };
}.values;

test "trailer declarations bound ignored empty list members" {
    const accepted = "," ** (request_trailers.empty_declaration_members_max - 1);
    var accepted_storage: ["Trailer".len + accepted.len]u8 = undefined;
    const accepted_head = makeDeclarationHead(accepted, &accepted_storage);
    const declarations = try DeclarationSet.parse(&.{accepted_head.field}, accepted_head.bytes);
    try std.testing.expectEqual(@as(u16, 0), declarations.count());

    const rejected = "," ** request_trailers.empty_declaration_members_max;
    var rejected_storage: ["Trailer".len + rejected.len]u8 = undefined;
    const rejected_head = makeDeclarationHead(rejected, &rejected_storage);
    try std.testing.expectError(
        error.Invalid,
        DeclarationSet.parse(&.{rejected_head.field}, rejected_head.bytes),
    );
}

fn fuzzRequestTrailers(_: void, smith: *std.testing.Smith) !void {
    var storage: [512]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];
    const parts = splitInput(input);

    var head_storage: ["Trailer".len + storage.len]u8 = undefined;
    const head = makeDeclarationHead(parts.declaration, &head_storage);
    const declarations = DeclarationSet.parse(&.{head.field}, head.bytes) catch {
        const fallback = "TrailerX-Fuzz";
        const fallback_field = declarationField("X-Fuzz".len);
        const valid = try DeclarationSet.parse(&.{fallback_field}, fallback);
        try compareFeeds(valid, fallback, parts.trailers, parts.wire_bytes_max);
        return;
    };
    try compareFeeds(declarations, head.bytes, parts.trailers, parts.wire_bytes_max);
}

fn splitInput(input: []const u8) Parts {
    const separator = std.mem.indexOfScalar(u8, input, 0) orelse return .{
        .declaration = input,
        .trailers = input,
        .wire_bytes_max = @min(input.len, 255),
    };
    const encoded = input[separator + 1 ..];
    if (encoded.len == 0) return .{
        .declaration = input[0..separator],
        .trailers = "",
        .wire_bytes_max = 0,
    };
    return .{
        .declaration = input[0..separator],
        .trailers = encoded[1..],
        .wire_bytes_max = encoded[0],
    };
}

const DeclarationHead = struct {
    bytes: []const u8,
    field: request_head.Field,
};

fn makeDeclarationHead(raw: []const u8, storage: []u8) DeclarationHead {
    const prefix = "Trailer";
    std.debug.assert(storage.len >= prefix.len + raw.len);
    @memcpy(storage[0..prefix.len], prefix);
    @memcpy(storage[prefix.len..][0..raw.len], raw);
    return .{
        .bytes = storage[0 .. prefix.len + raw.len],
        .field = declarationField(raw.len),
    };
}

fn declarationField(value_length: usize) request_head.Field {
    const value = request_head.Span{
        .offset = "Trailer".len,
        .length = @intCast(value_length),
    };
    return .{
        .name = .{ .offset = 0, .length = "Trailer".len },
        .raw_value = value,
        .value = value,
    };
}

fn compareFeeds(
    declarations: DeclarationSet,
    head_bytes: []const u8,
    input: []const u8,
    wire_bytes_max: u64,
) !void {
    var contiguous = TrailerDecoder.init(declarations, head_bytes, wire_bytes_max);
    const contiguous_result = try drive(&contiguous, input, false);
    var fragmented = TrailerDecoder.init(declarations, head_bytes, wire_bytes_max);
    const fragmented_result = try drive(&fragmented, input, true);

    try std.testing.expectEqualDeep(contiguous_result, fragmented_result);
    try std.testing.expectEqualSlices(u8, contiguous.bytes(), fragmented.bytes());
    try std.testing.expectEqualDeep(contiguous.fields(), fragmented.fields());
    try checkSpans(&contiguous);
    try checkSpans(&fragmented);
    try checkTerminal(&contiguous, input, contiguous_result);
    try checkTerminal(&fragmented, input, fragmented_result);
}

fn drive(decoder: *TrailerDecoder, input: []const u8, one_byte: bool) !Snapshot {
    var offset: usize = 0;
    while (offset < input.len) {
        const end = if (one_byte) offset + 1 else input.len;
        const result = decoder.feed(input[offset..end]);
        if (result.consumed > end - offset) return error.TestUnexpectedResult;
        offset += result.consumed;
        switch (result.event) {
            .need_more => {
                if (offset != end) return error.TestUnexpectedResult;
                if (end == input.len) return snapshot(decoder, offset, .need_more, 0);
            },
            .ready => return snapshot(decoder, offset, .ready, 0),
            .rejected => |rejection| return snapshot(
                decoder,
                offset,
                .rejected,
                @intFromEnum(rejection.status),
            ),
        }
        if (result.consumed == 0) return error.TestUnexpectedResult;
    }
    return snapshot(decoder, offset, .need_more, 0);
}

fn snapshot(
    decoder: *const TrailerDecoder,
    consumed: usize,
    terminal: Terminal,
    rejection_code: u16,
) Snapshot {
    return .{
        .consumed = consumed,
        .bytes_count = decoder.bytes().len,
        .fields_count = decoder.fields().len,
        .wire_bytes = decoder.wireBytesConsumed(),
        .rejection_code = rejection_code,
        .terminal = terminal,
    };
}

fn checkSpans(decoder: *const TrailerDecoder) !void {
    const bytes = decoder.bytes();
    for (decoder.fields()) |field| {
        _ = field.name.slice(bytes);
        _ = field.raw_value.slice(bytes);
        _ = field.value.slice(bytes);
    }
}

fn checkTerminal(
    decoder: *TrailerDecoder,
    input: []const u8,
    result: Snapshot,
) !void {
    try std.testing.expectEqual(result.consumed, result.wire_bytes);
    try std.testing.expectEqualSlices(u8, input[0..result.consumed], decoder.bytes());
    if (result.terminal == .need_more) return;

    const sticky = decoder.feed(input[result.consumed..]);
    try std.testing.expectEqual(@as(usize, 0), sticky.consumed);
    try std.testing.expectEqual(result.consumed, decoder.bytes().len);
    switch (sticky.event) {
        .ready => try std.testing.expectEqual(Terminal.ready, result.terminal),
        .rejected => |rejection| {
            try std.testing.expectEqual(Terminal.rejected, result.terminal);
            try std.testing.expectEqual(
                result.rejection_code,
                @intFromEnum(rejection.status),
            );
            try std.testing.expect(rejection.close);
        },
        .need_more => return error.TestUnexpectedResult,
    }
}
