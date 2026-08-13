const std = @import("std");
const fuzz_support = @import("../../../src/internal/http1/testing/smith.zig");
const boundary = @import("../../../src/internal/multipart/boundary.zig");
const events = @import("../../../src/internal/multipart/events.zig");
const headers = @import("../../../src/internal/multipart/part_headers.zig");
const parser = @import("../../../src/internal/multipart/parser.zig");
const plan = @import("../../../src/internal/multipart/plan.zig");
const syntax = @import("../../../src/internal/multipart/wire_syntax.zig");

test "multipart boundary extraction is deterministic and bounded" {
    try std.testing.fuzz({}, fuzzBoundary, .{ .corpus = &boundary_corpus });
}

const boundary_corpus = struct {
    const plain = fuzz_support.smithInputThenU64(
        "multipart/form-data; boundary=AaB03x",
        70,
    );
    const quoted = fuzz_support.smithInputThenU64(
        "Multipart/Form-Data; note=x; boundary=\"a:b c\"",
        70,
    );
    const escaped = fuzz_support.smithInputThenU64(
        "multipart/form-data; boundary=\"a\\'b\"",
        70,
    );
    const duplicate = fuzz_support.smithInputThenU64(
        "multipart/form-data; boundary=a; BOUNDARY=b",
        70,
    );
    const route_limit = fuzz_support.smithInputThenU64(
        "multipart/form-data; boundary=12345",
        4,
    );
    const injected = fuzz_support.smithInputThenU64(
        "multipart/form-data; boundary=bad\r\nX-Evil: yes",
        70,
    );
    const values = [_][]const u8{
        &plain,
        &quoted,
        &escaped,
        &duplicate,
        &route_limit,
        &injected,
    };
}.values;

fn fuzzBoundary(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [512]u8 = undefined;
    const value = input_storage[0..smith.slice(&input_storage)];
    var original: [input_storage.len]u8 = undefined;
    @memcpy(original[0..value.len], value);
    const configured_max = smith.valueRangeAtMost(u8, 1, boundary.protocol_bytes_max);

    var first_storage: [boundary.protocol_bytes_max]u8 = undefined;
    var second_storage: [boundary.protocol_bytes_max]u8 = undefined;
    var first_error: ?boundary.Error = null;
    var second_error: ?boundary.Error = null;
    const first: ?[]const u8 = boundary.parse(
        value,
        configured_max,
        &first_storage,
    ) catch |problem| failed: {
        first_error = problem;
        break :failed null;
    };
    const second: ?[]const u8 = boundary.parse(
        value,
        configured_max,
        &second_storage,
    ) catch |problem| failed: {
        second_error = problem;
        break :failed null;
    };
    try std.testing.expectEqual(first_error, second_error);
    try std.testing.expectEqualSlices(u8, original[0..value.len], value);
    if (first) |accepted| {
        const repeated = second orelse return error.FuzzOutcomeMismatch;
        try std.testing.expectEqualStrings(accepted, repeated);
        try expectBoundaryInvariant(accepted, configured_max);
        try expectCanonicalBoundary(accepted);
    } else try std.testing.expect(second == null);
}

fn expectBoundaryInvariant(value: []const u8, configured_max: usize) !void {
    try std.testing.expect(value.len > 0);
    try std.testing.expect(value.len <= configured_max);
    try std.testing.expect(value.len <= boundary.protocol_bytes_max);
    try std.testing.expect(value[value.len - 1] != ' ');
    for (value) |byte| {
        const valid = std.ascii.isAlphanumeric(byte) or
            std.mem.indexOfScalar(u8, "'()+_,-./:=? ", byte) != null;
        try std.testing.expect(valid);
    }
}

fn expectCanonicalBoundary(value: []const u8) !void {
    const prefix = "multipart/form-data; boundary=\"";
    var canonical: [128]u8 = undefined;
    @memcpy(canonical[0..prefix.len], prefix);
    @memcpy(canonical[prefix.len..][0..value.len], value);
    canonical[prefix.len + value.len] = '"';
    const encoded = canonical[0 .. prefix.len + value.len + 1];
    var storage: [boundary.protocol_bytes_max]u8 = undefined;
    const reparsed = try boundary.parse(encoded, boundary.protocol_bytes_max, &storage);
    try std.testing.expectEqualStrings(value, reparsed);
}

test "multipart part-header parsing is deterministic and bounded" {
    try std.testing.fuzz({}, fuzzPartHeaders, .{ .corpus = &header_corpus });
}

const fuzz_header_limits = headers.Limits{
    .header_fields_max = 8,
    .header_bytes_max = 1024,
    .name_bytes_max = 64,
    .filename_bytes_max = 128,
    .disposition_parameters_max = 8,
};

const header_corpus = struct {
    const minimal = fuzz_support.smithInput(
        "Content-Disposition: form-data; name=token\r\n\r\n",
    );
    const extended = fuzz_support.smithInput(
        "Content-Disposition: form-data; name=file; " ++
            "filename*=UTF-8'zh-Hant'%E2%82%AC.txt\r\n\r\n",
    );
    const media = fuzz_support.smithInput(
        "Content-Disposition: form-data; name=value\r\n" ++
            "Content-Type: Text/Plain; charset=\"UT\\F-8\"\r\n\r\n",
    );
    const duplicate = fuzz_support.smithInput(
        "Content-Disposition: form-data; name=x; NAME=y\r\n\r\n",
    );
    const transfer = fuzz_support.smithInput(
        "Content-Disposition: form-data; name=x\r\n" ++
            "Content-Transfer-Encoding: base64\r\n\r\n",
    );
    const malformed = fuzz_support.smithInput(
        "Content-Disposition: form-data; name=\"unterminated\r\n\r\n",
    );
    const values = [_][]const u8{
        &minimal,
        &extended,
        &media,
        &duplicate,
        &transfer,
        &malformed,
    };
}.values;

fn fuzzPartHeaders(_: void, smith: *std.testing.Smith) !void {
    var generated: [fuzz_header_limits.header_bytes_max]u8 = undefined;
    const section = generated[0..smith.slice(&generated)];
    var first_storage: [generated.len]u8 = undefined;
    var second_storage: [generated.len]u8 = undefined;
    @memcpy(first_storage[0..section.len], section);
    @memcpy(second_storage[0..section.len], section);

    var first_error: ?headers.Error = null;
    var second_error: ?headers.Error = null;
    const first: ?headers.Metadata = headers.parse(
        fuzz_header_limits,
        first_storage[0..section.len],
    ) catch |problem| failed: {
        first_error = problem;
        break :failed null;
    };
    const second: ?headers.Metadata = headers.parse(
        fuzz_header_limits,
        second_storage[0..section.len],
    ) catch |problem| failed: {
        second_error = problem;
        break :failed null;
    };
    try std.testing.expectEqual(first_error, second_error);
    if (first) |metadata| {
        const repeated = second orelse return error.FuzzOutcomeMismatch;
        try expectMetadataEqual(metadata, repeated);
        try expectMetadataInvariant(first_storage[0..section.len], metadata);
        try expectMetadataInvariant(second_storage[0..section.len], repeated);
    } else try std.testing.expect(second == null);
}

fn expectMetadataEqual(left: headers.Metadata, right: headers.Metadata) !void {
    try std.testing.expectEqualStrings(left.name, right.name);
    if (left.filename) |a| {
        const b = right.filename orelse return error.FuzzOutcomeMismatch;
        try std.testing.expectEqual(a.source, b.source);
        try std.testing.expectEqualStrings(a.bytes, b.bytes);
    } else try std.testing.expect(right.filename == null);
    if (left.content_type) |a| {
        const b = right.content_type orelse return error.FuzzOutcomeMismatch;
        try std.testing.expectEqualStrings(a.raw, b.raw);
        try std.testing.expectEqualStrings(a.type, b.type);
        try std.testing.expectEqualStrings(a.subtype, b.subtype);
        if (a.charset) |a_charset| {
            const b_charset = b.charset orelse return error.FuzzOutcomeMismatch;
            try std.testing.expectEqual(a_charset.quoted, b_charset.quoted);
            try std.testing.expectEqualStrings(a_charset.bytes, b_charset.bytes);
        } else try std.testing.expect(b.charset == null);
    } else try std.testing.expect(right.content_type == null);
}

fn expectMetadataInvariant(storage: []const u8, metadata: headers.Metadata) !void {
    try std.testing.expect(metadata.name.len > 0);
    try std.testing.expect(metadata.name.len <= fuzz_header_limits.name_bytes_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(metadata.name));
    try expectNoControls(metadata.name);
    try expectBorrowed(storage, metadata.name);
    if (metadata.filename) |filename| {
        try std.testing.expect(filename.bytes.len <= fuzz_header_limits.filename_bytes_max);
        try std.testing.expect(std.unicode.utf8ValidateSlice(filename.bytes));
        try expectNoControls(filename.bytes);
        try expectBorrowed(storage, filename.bytes);
    }
    if (metadata.content_type) |media| {
        try std.testing.expect(syntax.isToken(media.type));
        try std.testing.expect(syntax.isToken(media.subtype));
        try expectBorrowed(storage, media.raw);
        try expectBorrowed(storage, media.type);
        try expectBorrowed(storage, media.subtype);
        if (media.charset) |charset| try expectBorrowed(storage, charset.bytes);
    }
}

fn expectNoControls(value: []const u8) !void {
    for (value) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
}

fn expectBorrowed(storage: []const u8, value: []const u8) !void {
    const base = @intFromPtr(storage.ptr);
    const address = @intFromPtr(value.ptr);
    try std.testing.expect(address >= base);
    if (address < base) return;
    const offset = address - base;
    try std.testing.expect(offset <= storage.len);
    if (offset > storage.len) return;
    try std.testing.expect(value.len <= storage.len - offset);
}

const stream_entries = [_]plan.Entry{
    .{ .name = "title", .kind = .text, .required = true, .maximum = 2 },
    .{ .name = "raw", .kind = .bytes, .required = false, .maximum = 1 },
    .{ .name = "upload", .kind = .file, .required = false, .maximum = 2 },
};

const stream_plan = plan.Plan{
    .entries = &stream_entries,
    .unknown_parts = .{ .discard = 64 },
    .limits = .{
        .total_body_bytes_max = 512,
        .file_bytes_max = 128,
        .field_bytes_max = 64,
        .parts_max = 8,
        .files_max = 2,
        .part_headers_max = 8,
        .part_header_bytes_max = 256,
        .disposition_parameters_max = 8,
        .delimiter_transport_padding_bytes_max = 8,
        .name_bytes_max = 32,
        .filename_bytes_max = 64,
        .boundary_bytes_max = 16,
    },
};

const FieldRecord = struct {
    entry_index: u16,
    occurrence: u16,
    kind: plan.PartKind,
    bytes: [stream_plan.limits.field_bytes_max]u8 = undefined,
    bytes_len: usize,
};

const FileRecord = struct {
    entry_index: u16,
    occurrence: u16,
    bytes: [stream_plan.limits.file_bytes_max]u8 = undefined,
    bytes_len: usize = 0,
    filename: [stream_plan.limits.filename_bytes_max]u8 = undefined,
    filename_len: usize = 0,
    filename_source: ?headers.FilenameSource = null,
    ended: bool = false,
};

const StreamTrace = struct {
    pub const Error = error{
        FuzzBadEntry,
        FuzzBadOccurrence,
        FuzzBadOrder,
        FuzzBadOffset,
        FuzzTraceOverflow,
    };

    fields: [3]FieldRecord = undefined,
    files: [2]FileRecord = undefined,
    seen: [stream_entries.len]u16 = @splat(0),
    order: [16]u8 = undefined,
    field_count: usize = 0,
    file_count: usize = 0,
    order_len: usize = 0,
    active_file: ?u8 = null,

    pub fn field(self: *StreamTrace, event: events.Field) Error!void {
        if (self.active_file != null) return error.FuzzBadOrder;
        const entry = try self.checkEvent(event.entry_index, event.occurrence);
        if (entry.kind != event.kind or entry.kind == .file) return error.FuzzBadEntry;
        if (!std.mem.eql(u8, entry.name, event.metadata.name) or
            event.metadata.filename != null)
        {
            return error.FuzzBadEntry;
        }
        if (self.field_count == self.fields.len or
            event.bytes.len > stream_plan.limits.field_bytes_max)
        {
            return error.FuzzTraceOverflow;
        }
        var record = FieldRecord{
            .entry_index = event.entry_index,
            .occurrence = event.occurrence,
            .kind = event.kind,
            .bytes_len = event.bytes.len,
        };
        @memcpy(record.bytes[0..event.bytes.len], event.bytes);
        self.fields[self.field_count] = record;
        self.field_count += 1;
        try self.addOrder(if (event.kind == .text) 'T' else 'B');
    }

    pub fn fileStart(self: *StreamTrace, event: events.FileStart) Error!void {
        if (self.active_file != null or self.file_count == self.files.len) {
            return error.FuzzBadOrder;
        }
        const entry = try self.checkEvent(event.entry_index, event.occurrence);
        if (entry.kind != .file) return error.FuzzBadEntry;
        if (!std.mem.eql(u8, entry.name, event.metadata.name)) return error.FuzzBadEntry;
        var record = FileRecord{
            .entry_index = event.entry_index,
            .occurrence = event.occurrence,
        };
        if (event.metadata.filename) |filename| {
            if (filename.bytes.len == 0) return error.FuzzBadEntry;
            if (filename.bytes.len > record.filename.len) return error.FuzzTraceOverflow;
            @memcpy(record.filename[0..filename.bytes.len], filename.bytes);
            record.filename_len = filename.bytes.len;
            record.filename_source = filename.source;
        }
        self.files[self.file_count] = record;
        self.active_file = @intCast(self.file_count);
        self.file_count += 1;
        try self.addOrder('S');
    }

    pub fn fileChunk(self: *StreamTrace, event: events.FileChunk) Error!void {
        const active = self.active_file orelse return error.FuzzBadOrder;
        const record = &self.files[active];
        if (event.entry_index != record.entry_index or
            event.occurrence != record.occurrence)
        {
            return error.FuzzBadOrder;
        }
        if (event.offset != record.bytes_len) return error.FuzzBadOffset;
        if (event.bytes.len == 0 or event.bytes.len > record.bytes.len - record.bytes_len) {
            return error.FuzzTraceOverflow;
        }
        @memcpy(record.bytes[record.bytes_len..][0..event.bytes.len], event.bytes);
        record.bytes_len += event.bytes.len;
    }

    pub fn fileEnd(self: *StreamTrace, event: events.FileEnd) Error!void {
        const active = self.active_file orelse return error.FuzzBadOrder;
        const record = &self.files[active];
        if (event.entry_index != record.entry_index or
            event.occurrence != record.occurrence)
        {
            return error.FuzzBadOrder;
        }
        if (event.bytes != record.bytes_len) return error.FuzzBadOffset;
        record.ended = true;
        self.active_file = null;
        try self.addOrder('E');
    }

    fn checkEvent(
        self: *StreamTrace,
        entry_index: u16,
        occurrence: u16,
    ) Error!plan.Entry {
        if (entry_index >= stream_entries.len) return error.FuzzBadEntry;
        const entry = stream_entries[entry_index];
        if (occurrence == 0 or occurrence > entry.maximum or
            occurrence != self.seen[entry_index] + 1)
        {
            return error.FuzzBadOccurrence;
        }
        self.seen[entry_index] = occurrence;
        return entry;
    }

    fn addOrder(self: *StreamTrace, value: u8) Error!void {
        if (self.order_len == self.order.len) return error.FuzzTraceOverflow;
        self.order[self.order_len] = value;
        self.order_len += 1;
    }

    fn validateComplete(self: *const StreamTrace) Error!void {
        if (self.active_file != null or self.seen[0] == 0) return error.FuzzBadOrder;
        if (self.field_count != @as(usize, self.seen[0]) + self.seen[1] or
            self.file_count != self.seen[2])
        {
            return error.FuzzBadOccurrence;
        }
        for (self.files[0..self.file_count]) |file| {
            if (!file.ended) return error.FuzzBadOrder;
        }
    }
};

const StreamParser = parser.Parser(stream_plan, StreamTrace);

const StreamStatus = enum(u8) {
    complete,
    malformed,
    limit_exceeded,
    unsupported_media,
};

const StreamResult = struct {
    status: StreamStatus,
    trace: StreamTrace,
};

test "multipart streaming parser fuzz preserves fragmentation and state invariants" {
    try std.testing.fuzz({}, fuzzStreamingParser, .{ .corpus = &stream_corpus });
}

const stream_corpus = struct {
    const valid = fuzz_support.smithInputThenU64(
        "preamble\r\n--B\r\n" ++
            "Content-Disposition: form-data; name=title\r\n\r\nhello\r\n--B\r\n" ++
            "Content-Disposition: form-data; name=raw\r\n\r\n\xffbytes\r\n--B\r\n" ++
            "Content-Disposition: form-data; name=upload; filename=x.bin\r\n" ++
            "Content-Type: application/octet-stream\r\n\r\n" ++
            "abc\r\n--BXdef\r\n--B-- \t\r\nepilogue",
        1,
    );
    const marker = fuzz_support.smithInputThenU64(
        "--B\r\nContent-Disposition: form-data; name=title\r\n\r\nx\r\n--B\r\n" ++
            "Content-Disposition: form-data; name=upload; filename=\"\"\r\n\r\n" ++
            "\r\n--B--",
        2,
    );
    const unknown = fuzz_support.smithInputThenU64(
        "--B\r\nContent-Disposition: form-data; name=title\r\n\r\nx\r\n--B\r\n" ++
            "Content-Disposition: form-data; name=other\r\n\r\ndiscarded\r\n--B--",
        3,
    );
    const repeated = fuzz_support.smithInputThenU64(
        "--B\r\nContent-Disposition: form-data; name=raw\r\n\r\na\r\n--B\r\n" ++
            "Content-Disposition: form-data; name=raw\r\n\r\nb\r\n--B--",
        7,
    );
    const unsupported = fuzz_support.smithInputThenU64(
        "--B\r\nContent-Disposition: form-data; name=title\r\n" ++
            "Content-Type: text/html\r\n\r\nx\r\n--B--",
        11,
    );
    const truncated = fuzz_support.smithInputThenU64(
        "--B\r\nContent-Disposition: form-data; name=title\r\n\r\nx",
        1,
    );
    const field_limit = fuzz_support.smithInputThenU64(
        "--B\r\nContent-Disposition: form-data; name=title\r\n\r\n" ++
            ("x" ** 65) ++ "\r\n--B--",
        16,
    );
    const file_limit = fuzz_support.smithInputThenU64(
        "--B\r\nContent-Disposition: form-data; name=upload; filename=x\r\n\r\n" ++
            ("x" ** 129) ++ "\r\n--B--",
        31,
    );
    const total_limit = fuzz_support.smithInputThenU64(
        "p" ** (stream_plan.limits.total_body_bytes_max + 1),
        64,
    );
    const values = [_][]const u8{
        &valid,
        &marker,
        &unknown,
        &repeated,
        &unsupported,
        &truncated,
        &field_limit,
        &file_limit,
        &total_limit,
    };
}.values;

fn fuzzStreamingParser(_: void, smith: *std.testing.Smith) !void {
    var storage: [768]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];
    const split = smith.valueRangeAtMost(u16, 1, 64);
    const contiguous = try driveStream(input, @max(input.len, 1));
    const fragmented = try driveStream(input, split);
    try expectStreamEqual(contiguous, fragmented);
}

fn driveStream(input: []const u8, split: usize) !StreamResult {
    var decoder = try StreamParser.init("B");
    var trace = StreamTrace{};
    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(input.len, offset + split);
        decoder.feed(&trace, input[offset..end]) catch |problem| {
            return failedStream(problem, trace);
        };
        offset = end;
    }
    decoder.finish(&trace) catch |problem| return failedStream(problem, trace);
    if (!decoder.isComplete()) return error.FuzzBadTerminalState;
    try trace.validateComplete();
    return .{ .status = .complete, .trace = trace };
}

fn failedStream(problem: anyerror, trace: StreamTrace) !StreamResult {
    const status: StreamStatus = switch (problem) {
        error.Malformed => .malformed,
        error.LimitExceeded => .limit_exceeded,
        error.UnsupportedMedia => .unsupported_media,
        else => return problem,
    };
    return .{ .status = status, .trace = trace };
}

fn expectStreamEqual(left: StreamResult, right: StreamResult) !void {
    try std.testing.expectEqual(left.status, right.status);
    try std.testing.expectEqual(left.trace.field_count, right.trace.field_count);
    try std.testing.expectEqual(left.trace.file_count, right.trace.file_count);
    try std.testing.expectEqual(left.trace.active_file, right.trace.active_file);
    try std.testing.expectEqualSlices(u16, &left.trace.seen, &right.trace.seen);
    try std.testing.expectEqualSlices(
        u8,
        left.trace.order[0..left.trace.order_len],
        right.trace.order[0..right.trace.order_len],
    );
    for (
        left.trace.fields[0..left.trace.field_count],
        right.trace.fields[0..right.trace.field_count],
    ) |a, b| {
        try expectFieldEqual(a, b);
    }
    for (
        left.trace.files[0..left.trace.file_count],
        right.trace.files[0..right.trace.file_count],
    ) |a, b| {
        try expectFileEqual(a, b);
    }
}

fn expectFieldEqual(left: FieldRecord, right: FieldRecord) !void {
    try std.testing.expectEqual(left.entry_index, right.entry_index);
    try std.testing.expectEqual(left.occurrence, right.occurrence);
    try std.testing.expectEqual(left.kind, right.kind);
    try std.testing.expectEqualSlices(
        u8,
        left.bytes[0..left.bytes_len],
        right.bytes[0..right.bytes_len],
    );
}

fn expectFileEqual(left: FileRecord, right: FileRecord) !void {
    try std.testing.expectEqual(left.entry_index, right.entry_index);
    try std.testing.expectEqual(left.occurrence, right.occurrence);
    try std.testing.expectEqual(left.ended, right.ended);
    try std.testing.expectEqual(left.filename_source, right.filename_source);
    try std.testing.expectEqualSlices(
        u8,
        left.filename[0..left.filename_len],
        right.filename[0..right.filename_len],
    );
    try std.testing.expectEqualSlices(
        u8,
        left.bytes[0..left.bytes_len],
        right.bytes[0..right.bytes_len],
    );
}
