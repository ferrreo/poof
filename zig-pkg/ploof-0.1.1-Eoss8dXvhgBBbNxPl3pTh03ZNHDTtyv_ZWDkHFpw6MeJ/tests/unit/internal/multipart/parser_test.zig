const std = @import("std");
const events = @import("../../../../src/internal/multipart/events.zig");
const parser = @import("../../../../src/internal/multipart/parser.zig");
const plan_module = @import("../../../../src/internal/multipart/plan.zig");

const claims = [_]plan_module.MediaClaim{
    .{ .type = "image", .subtype = "png" },
};

const entries = [_]plan_module.Entry{
    .{ .name = "title", .kind = .text, .required = true, .maximum = 1 },
    .{ .name = "raw", .kind = .bytes, .required = false, .maximum = 1 },
    .{
        .name = "upload",
        .kind = .file,
        .required = true,
        .maximum = 2,
        .file_media = .{ .claimed = .{ .values = &claims, .missing = .reject } },
    },
};

const test_plan = plan_module.Plan{ .entries = &entries };

const FieldRecord = struct {
    kind: plan_module.PartKind,
    occurrence: u16,
    name: [32]u8 = undefined,
    name_len: usize,
    bytes: [128]u8 = undefined,
    bytes_len: usize,
};

const Trace = struct {
    pub const Error = error{ NoSpace, BadOffset };

    fields: [8]FieldRecord = undefined,
    field_count: usize = 0,
    file_bytes: [256]u8 = undefined,
    file_len: usize = 0,
    file_starts: usize = 0,
    file_ends: usize = 0,
    filename: [64]u8 = undefined,
    filename_len: usize = 0,
    order: [32]u8 = undefined,
    order_len: usize = 0,

    pub fn field(self: *Trace, event: events.Field) Error!void {
        if (self.field_count == self.fields.len or event.metadata.name.len > 32 or
            event.bytes.len > 128)
        {
            return error.NoSpace;
        }
        var record = FieldRecord{
            .kind = event.kind,
            .occurrence = event.occurrence,
            .name_len = event.metadata.name.len,
            .bytes_len = event.bytes.len,
        };
        @memcpy(record.name[0..record.name_len], event.metadata.name);
        @memcpy(record.bytes[0..record.bytes_len], event.bytes);
        self.fields[self.field_count] = record;
        self.field_count += 1;
        try self.addOrder(if (event.kind == .text) 'T' else 'B');
    }

    pub fn fileStart(self: *Trace, event: events.FileStart) Error!void {
        self.file_starts += 1;
        const filename = event.metadata.filename orelse return;
        if (filename.bytes.len > self.filename.len) return error.NoSpace;
        @memcpy(self.filename[0..filename.bytes.len], filename.bytes);
        self.filename_len = filename.bytes.len;
        try self.addOrder('F');
    }

    pub fn fileChunk(self: *Trace, event: events.FileChunk) Error!void {
        if (event.offset != self.file_len) return error.BadOffset;
        if (event.bytes.len > self.file_bytes.len - self.file_len) return error.NoSpace;
        @memcpy(self.file_bytes[self.file_len..][0..event.bytes.len], event.bytes);
        self.file_len += event.bytes.len;
    }

    pub fn fileEnd(self: *Trace, event: events.FileEnd) Error!void {
        if (event.bytes != self.file_len) return error.BadOffset;
        self.file_ends += 1;
        try self.addOrder('E');
    }

    fn addOrder(self: *Trace, value: u8) Error!void {
        if (self.order_len == self.order.len) return error.NoSpace;
        self.order[self.order_len] = value;
        self.order_len += 1;
    }
};

fn run(comptime selected: plan_module.Plan, input: []const u8, split: usize) !Trace {
    const TestParser = parser.Parser(selected, Trace);
    var decoder = try TestParser.init("B");
    var trace = Trace{};
    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(input.len, offset + split);
        try decoder.feed(&trace, input[offset..end]);
        offset = end;
    }
    try decoder.finish(&trace);
    try std.testing.expect(decoder.isComplete());
    return trace;
}

test "fragmented fields and file drive one bounded transaction" {
    const input = "preamble\r\n--B\r\n" ++
        "Content-Disposition: form-data; name=title\r\n\r\n" ++
        "42\r\n--B\r\n" ++
        "Content-Disposition: form-data; name=raw\r\n" ++
        "Content-Type: multipart/mixed; boundary=opaque\r\n\r\n" ++
        "\xffinner\r\n--B\r\n" ++
        "Content-Disposition: form-data; name=upload; filename=\"../photo.png\"\r\n" ++
        "Content-Type: IMAGE/PNG; profile=untrusted\r\n\r\n" ++
        "abcdef\r\n--B-- \t\r\nepilogue";
    for (1..input.len + 1) |split| {
        const trace = try run(test_plan, input, split);
        try std.testing.expectEqual(@as(usize, 2), trace.field_count);
        try expectField(trace.fields[0], .text, "title", "42");
        try expectField(trace.fields[1], .bytes, "raw", "\xffinner");
        try std.testing.expectEqual(@as(usize, 1), trace.file_starts);
        try std.testing.expectEqual(@as(usize, 1), trace.file_ends);
        try std.testing.expectEqualStrings("../photo.png", trace.filename[0..trace.filename_len]);
        try std.testing.expectEqualStrings("abcdef", trace.file_bytes[0..trace.file_len]);
        try std.testing.expectEqualStrings("TBFE", trace.order[0..trace.order_len]);
    }
}

test "empty filename marker is provisional and never satisfies required file" {
    const marker = "--B\r\n" ++
        "Content-Disposition: form-data; name=upload; filename=\"\"\r\n\r\n" ++
        "\r\n--B--";
    const TestParser = parser.Parser(test_plan, Trace);
    var decoder = try TestParser.init("B");
    var trace = Trace{};
    try decoder.feed(&trace, marker);
    try std.testing.expectError(error.Malformed, decoder.finish(&trace));
    try std.testing.expectEqual(@as(usize, 0), trace.file_starts);

    const payload = "--B\r\n" ++
        "Content-Disposition: form-data; name=upload; filename=\"\"\r\n\r\n" ++
        "x\r\n--B--";
    var contradictory = try TestParser.init("B");
    var second_trace = Trace{};
    try std.testing.expectError(error.Malformed, contradictory.feed(&second_trace, payload));
}

test "absent filename and nonempty filename produce real empty files" {
    const file_entries = [_]plan_module.Entry{
        .{ .name = "file", .kind = .file, .required = true, .maximum = 2 },
    };
    const selected = plan_module.Plan{ .entries = &file_entries };
    const input = "--B\r\n" ++
        "Content-Disposition: form-data; name=file\r\n\r\n" ++
        "\r\n--B\r\n" ++
        "Content-Disposition: form-data; name=file; filename=x\r\n\r\n" ++
        "\r\n--B--";
    const trace = try run(selected, input, 1);
    try std.testing.expectEqual(@as(usize, 2), trace.file_starts);
    try std.testing.expectEqual(@as(usize, 2), trace.file_ends);
    try std.testing.expectEqual(@as(usize, 0), trace.file_len);
}

test "unknown policy cardinality media and byte limits map exactly" {
    const field_entries = [_]plan_module.Entry{
        .{ .name = "value", .kind = .text, .required = false, .maximum = 1 },
    };
    const unknown_input = "--B\r\n" ++
        "Content-Disposition: form-data; name=other\r\n\r\nabc\r\n--B--";
    try expectError(.{ .entries = &field_entries }, unknown_input, error.Malformed);
    try expectError(.{
        .entries = &field_entries,
        .unknown_parts = .{ .discard = 2 },
    }, unknown_input, error.LimitExceeded);
    _ = try run(.{
        .entries = &field_entries,
        .unknown_parts = .{ .discard = 3 },
    }, unknown_input, 1);

    const unsupported = "--B\r\n" ++
        "Content-Disposition: form-data; name=value\r\n" ++
        "Content-Type: text/html\r\n\r\nx\r\n--B--";
    try expectError(.{ .entries = &field_entries }, unsupported, error.UnsupportedMedia);

    const repeated = "--B\r\n" ++
        "Content-Disposition: form-data; name=value\r\n\r\na\r\n--B\r\n" ++
        "Content-Disposition: form-data; name=value\r\n\r\nb\r\n--B--";
    try expectError(.{ .entries = &field_entries }, repeated, error.Malformed);

    const field_limit = plan_module.Plan{
        .entries = &field_entries,
        .limits = .{ .field_bytes_max = 3 },
    };
    const too_large = "--B\r\n" ++
        "Content-Disposition: form-data; name=value\r\n\r\nabcd\r\n--B--";
    try expectError(field_limit, too_large, error.LimitExceeded);
}

test "file byte limit stops delivery at the configured maximum" {
    const file_entries = [_]plan_module.Entry{
        .{ .name = "upload", .kind = .file, .required = false, .maximum = 1 },
    };
    const FileParser = parser.Parser(.{
        .entries = &file_entries,
        .limits = .{ .file_bytes_max = 3 },
    }, Trace);
    const input = "--B\r\n" ++
        "Content-Disposition: form-data; name=upload; filename=x\r\n\r\n" ++
        "abcd\r\n--B--";
    var decoder = try FileParser.init("B");
    var trace = Trace{};
    try std.testing.expectError(error.LimitExceeded, decoder.feed(&trace, input));
    try std.testing.expectEqual(@as(usize, 1), trace.file_starts);
    try std.testing.expectEqual(@as(usize, 0), trace.file_ends);
    try std.testing.expectEqualStrings("abc", trace.file_bytes[0..trace.file_len]);
}

test "total body byte limit rejects before multipart parsing can continue" {
    const field_entries = [_]plan_module.Entry{
        .{ .name = "value", .kind = .text, .required = false, .maximum = 1 },
    };
    const TotalParser = parser.Parser(.{
        .entries = &field_entries,
        .limits = .{ .total_body_bytes_max = 8 },
    }, Trace);
    var decoder = try TotalParser.init("B");
    var trace = Trace{};
    try std.testing.expectError(error.LimitExceeded, decoder.feed(&trace, "123456789"));
    try std.testing.expectEqual(@as(u64, 8), decoder.total_bytes);
    try std.testing.expectEqual(@as(usize, 0), trace.field_count);
    try std.testing.expectEqual(@as(usize, 0), trace.file_starts);
}

test "missing close invalid UTF-8 and route boundary limit reject" {
    const field_entries = [_]plan_module.Entry{
        .{ .name = "value", .kind = .text, .required = false, .maximum = 1 },
    };
    const selected = plan_module.Plan{ .entries = &field_entries };
    const missing = "--B\r\nContent-Disposition: form-data; name=value\r\n\r\nx";
    try expectError(selected, missing, error.Malformed);
    const invalid_utf8 = "--B\r\n" ++
        "Content-Disposition: form-data; name=value\r\n\r\n\xff\r\n--B--";
    try expectError(selected, invalid_utf8, error.Malformed);

    const Narrow = parser.Parser(.{
        .entries = &field_entries,
        .limits = .{ .boundary_bytes_max = 1 },
    }, Trace);
    try std.testing.expectError(error.LimitExceeded, Narrow.init("BB"));
}

const progressive_entries = [_]plan_module.Entry{
    .{ .name = "upload", .kind = .file, .required = true, .maximum = 1 },
};
const progressive_plan = plan_module.Plan{ .entries = &progressive_entries };
const file_prefix = "--B\r\n" ++
    "Content-Disposition: form-data; name=upload; filename=x\r\n\r\n";

const InvalidProgress = enum(u8) {
    none,
    overshoot,
    ready_partial,
};

const ProgressTrace = struct {
    pub const Error = error{ NoSpace, BadOffset };

    bytes: [256]u8 = undefined,
    bytes_len: usize = 0,
    current_len: usize = 0,
    file_starts: usize = 0,
    file_ends: usize = 0,
    fields: usize = 0,
    resume_polls: usize = 0,
    last_wait: parser.Wait = .file_start,
    chunk_max: usize = std.math.maxInt(usize),
    invalid: InvalidProgress = .none,
    start_pause: bool = false,
    chunk_pause: bool = false,
    end_pause: bool = false,
    zero_next: bool = false,
    auto_resume: bool = false,
    resume_ready: bool = false,

    pub fn field(self: *ProgressTrace, _: events.Field) Error!void {
        self.fields += 1;
    }

    pub fn fileStartProgress(
        self: *ProgressTrace,
        _: events.FileStart,
    ) Error!parser.CallbackFlow {
        self.file_starts += 1;
        self.current_len = 0;
        return if (self.start_pause) .paused else .ready;
    }

    pub fn fileChunkProgress(
        self: *ProgressTrace,
        event: events.FileChunk,
    ) Error!parser.ChunkProgress {
        if (event.offset != self.current_len) return error.BadOffset;
        switch (self.invalid) {
            .overshoot => return .{ .consumed = event.bytes.len + 1, .flow = .paused },
            .ready_partial => return .{ .consumed = event.bytes.len - 1, .flow = .ready },
            .none => {},
        }
        if (self.zero_next) {
            self.zero_next = false;
            return .{ .consumed = 0, .flow = .paused };
        }
        const consumed = @min(event.bytes.len, self.chunk_max);
        try self.append(event.bytes[0..consumed]);
        const flow: parser.CallbackFlow = if (self.chunk_pause or consumed != event.bytes.len)
            .paused
        else
            .ready;
        return .{ .consumed = consumed, .flow = flow };
    }

    pub fn fileEndProgress(
        self: *ProgressTrace,
        event: events.FileEnd,
    ) Error!parser.CallbackFlow {
        if (event.bytes != self.current_len) return error.BadOffset;
        self.file_ends += 1;
        return if (self.end_pause) .paused else .ready;
    }

    pub fn multipartResume(
        self: *ProgressTrace,
        wait: parser.Wait,
    ) Error!parser.CallbackFlow {
        self.resume_polls += 1;
        self.last_wait = wait;
        if (self.auto_resume) return .ready;
        if (!self.resume_ready) return .paused;
        self.resume_ready = false;
        return .ready;
    }

    fn append(self: *ProgressTrace, bytes: []const u8) Error!void {
        if (bytes.len > self.bytes.len - self.bytes_len) return error.NoSpace;
        @memcpy(self.bytes[self.bytes_len..][0..bytes.len], bytes);
        self.bytes_len += bytes.len;
        self.current_len += bytes.len;
    }
};

const MissingResumeTrace = struct {
    pub const Error = error{};

    pub fn field(_: *MissingResumeTrace, _: events.Field) Error!void {}

    pub fn fileStartProgress(
        _: *MissingResumeTrace,
        _: events.FileStart,
    ) Error!parser.CallbackFlow {
        return .paused;
    }

    pub fn fileChunk(_: *MissingResumeTrace, _: events.FileChunk) Error!void {}

    pub fn fileEnd(_: *MissingResumeTrace, _: events.FileEnd) Error!void {}
};

fn drainResume(decoder: anytype, trace: *ProgressTrace) !parser.Flow {
    for (0..512) |_| {
        const progress = try decoder.@"resume"(trace);
        if (progress.flow != .paused) return progress.flow;
    }
    return error.TestUnexpectedResult;
}

test "borrowed file data reports only accepted source bytes" {
    const ProgressiveParser = parser.Parser(progressive_plan, ProgressTrace);
    var decoder = try ProgressiveParser.init("B");
    var trace = ProgressTrace{};
    const prefix = try decoder.feedProgress(&trace, file_prefix);
    try std.testing.expectEqual(file_prefix.len, prefix.consumed);

    trace.chunk_max = 2;
    trace.chunk_pause = true;
    const partial = try decoder.feedProgress(&trace, "abcdef");
    try expectProgress(partial, 2, .paused);
    try std.testing.expectEqual(@as(u64, 2), decoder.active_bytes);
    const total = decoder.total_bytes;
    try expectProgress(try decoder.feedProgress(&trace, "cdef"), 0, .paused);
    try expectProgress(try decoder.@"resume"(&trace), 0, .paused);
    trace.resume_ready = true;
    try expectProgress(try decoder.@"resume"(&trace), 0, .ready);
    try std.testing.expectEqual(total, decoder.total_bytes);

    trace.chunk_max = std.math.maxInt(usize);
    trace.chunk_pause = false;
    try expectProgress(try decoder.feedProgress(&trace, "cdef\r\n--B--"), 11, .ready);
    try expectProgress(try decoder.finishProgress(&trace), 0, .complete);
    try std.testing.expectEqualStrings("abcdef", trace.bytes[0..trace.bytes_len]);
}

test "retained false delimiter data resumes without source or byte recount" {
    const ProgressiveParser = parser.Parser(progressive_plan, ProgressTrace);
    var decoder = try ProgressiveParser.init("B");
    var trace = ProgressTrace{};
    _ = try decoder.feedProgress(&trace, file_prefix);
    _ = try decoder.feedProgress(&trace, "abc");
    trace.zero_next = true;
    const candidate = "\r\n--BX";
    try expectProgress(
        try decoder.feedProgress(&trace, candidate),
        candidate.len,
        .paused,
    );
    const total = decoder.total_bytes;
    try std.testing.expectEqualStrings("abc", trace.bytes[0..trace.bytes_len]);
    trace.resume_ready = true;
    try expectProgress(try decoder.@"resume"(&trace), 0, .ready);
    try std.testing.expectEqual(total, decoder.total_bytes);
    try std.testing.expectEqualStrings("abc" ++ candidate, trace.bytes[0..trace.bytes_len]);
}

test "retained candidate accepts every prefix length without source recount" {
    const ProgressiveParser = parser.Parser(progressive_plan, ProgressTrace);
    const candidate = "\r\n--BX";
    for (0..candidate.len + 1) |accepted| {
        var decoder = try ProgressiveParser.init("B");
        var trace = ProgressTrace{};
        _ = try decoder.feedProgress(&trace, file_prefix);
        _ = try decoder.feedProgress(&trace, "abc");
        trace.chunk_max = accepted;
        const progress = try decoder.feedProgress(&trace, candidate);
        try std.testing.expectEqual(candidate.len, progress.consumed);
        const expected_flow: parser.Flow = if (accepted == candidate.len) .ready else .paused;
        try std.testing.expectEqual(expected_flow, progress.flow);
        try std.testing.expectEqual(@as(u64, 3 + accepted), decoder.active_bytes);
        try std.testing.expectEqualStrings("abc", trace.bytes[0..3]);
        try std.testing.expectEqualStrings(candidate[0..accepted], trace.bytes[3..trace.bytes_len]);
    }
}

test "one-byte input and one-byte window drain false candidates losslessly" {
    const ProgressiveParser = parser.Parser(progressive_plan, ProgressTrace);
    const body = "a\r\n--BXb";
    const input = file_prefix ++ body ++ "\r\n--B--";
    var decoder = try ProgressiveParser.init("B");
    var trace = ProgressTrace{
        .chunk_max = 1,
        .chunk_pause = true,
        .auto_resume = true,
    };
    var offset: usize = 0;
    while (offset < input.len) {
        const progress = try decoder.feedProgress(&trace, input[offset..][0..1]);
        offset += progress.consumed;
        if (progress.flow == .paused) {
            try std.testing.expectEqual(parser.Flow.ready, try drainResume(&decoder, &trace));
        }
    }
    try expectProgress(try decoder.finishProgress(&trace), 0, .complete);
    try std.testing.expectEqualStrings(body, trace.bytes[0..trace.bytes_len]);
    try std.testing.expectEqual(@as(usize, 1), trace.file_starts);
    try std.testing.expectEqual(@as(usize, 1), trace.file_ends);
}

test "start and delimiter end pauses gate later parts without duplicate callbacks" {
    const transition_entries = [_]plan_module.Entry{
        .{ .name = "upload", .kind = .file, .required = true, .maximum = 1 },
        .{ .name = "value", .kind = .text, .required = true, .maximum = 1 },
    };
    const TransitionParser = parser.Parser(.{ .entries = &transition_entries }, ProgressTrace);
    const tail = "x\r\n--B\r\n" ++
        "Content-Disposition: form-data; name=value\r\n\r\n" ++
        "y\r\n--B--";
    const input = file_prefix ++ tail;
    var decoder = try TransitionParser.init("B");
    var trace = ProgressTrace{ .start_pause = true, .end_pause = true };

    const start = try decoder.feedProgress(&trace, input);
    try expectProgress(start, file_prefix.len, .paused);
    try std.testing.expectEqual(@as(usize, 1), trace.file_starts);
    try expectProgress(try decoder.feedProgress(&trace, input[start.consumed..]), 0, .paused);
    try expectProgress(try decoder.@"resume"(&trace), 0, .paused);
    try std.testing.expectEqual(parser.Wait.file_start, trace.last_wait);
    trace.resume_ready = true;
    try expectProgress(try decoder.@"resume"(&trace), 0, .ready);

    var offset = start.consumed;
    const ended = try decoder.feedProgress(&trace, input[offset..]);
    offset += ended.consumed;
    try std.testing.expectEqual(parser.Flow.paused, ended.flow);
    try std.testing.expectEqual(@as(usize, 1), trace.file_ends);
    try std.testing.expectEqual(@as(usize, 0), trace.fields);
    try expectProgress(try decoder.feedProgress(&trace, input[offset..]), 0, .paused);
    try expectProgress(try decoder.@"resume"(&trace), 0, .paused);
    try std.testing.expectEqual(parser.Wait.file_end, trace.last_wait);
    try std.testing.expectEqual(@as(usize, 1), trace.file_ends);
    trace.resume_ready = true;
    try expectProgress(try decoder.@"resume"(&trace), 0, .ready);

    const remainder = try decoder.feedProgress(&trace, input[offset..]);
    try std.testing.expectEqual(input.len - offset, remainder.consumed);
    try expectProgress(try decoder.finishProgress(&trace), 0, .complete);
    try std.testing.expectEqual(@as(usize, 1), trace.fields);
}

test "EOF file end pause completes only after readiness" {
    const ProgressiveParser = parser.Parser(progressive_plan, ProgressTrace);
    const input = file_prefix ++ "x\r\n--B--";
    var decoder = try ProgressiveParser.init("B");
    var trace = ProgressTrace{ .end_pause = true };
    try expectProgress(try decoder.feedProgress(&trace, input), input.len, .ready);
    try expectProgress(try decoder.finishProgress(&trace), 0, .paused);
    try std.testing.expect(!decoder.isComplete());
    try std.testing.expectEqual(@as(usize, 1), trace.file_ends);
    try expectProgress(try decoder.finishProgress(&trace), 0, .paused);
    try std.testing.expectEqual(@as(usize, 1), trace.file_ends);
    try expectProgress(try decoder.@"resume"(&trace), 0, .paused);
    try std.testing.expect(!decoder.isComplete());
    trace.resume_ready = true;
    try expectProgress(try decoder.@"resume"(&trace), 0, .complete);
    try std.testing.expect(decoder.isComplete());
    try std.testing.expectEqual(@as(usize, 1), trace.file_ends);
}

test "progressive file and total byte limits remain exact" {
    const FileLimited = parser.Parser(.{
        .entries = &progressive_entries,
        .limits = .{ .file_bytes_max = 3 },
    }, ProgressTrace);
    var file_decoder = try FileLimited.init("B");
    var file_trace = ProgressTrace{ .chunk_max = 1, .chunk_pause = true };
    _ = try file_decoder.feedProgress(&file_trace, file_prefix);
    var offset: usize = 0;
    while (offset < 3) {
        const progress = try file_decoder.feedProgress(&file_trace, "abcd"[offset..]);
        try std.testing.expectEqual(@as(usize, 1), progress.consumed);
        offset += progress.consumed;
        file_trace.resume_ready = true;
        try expectProgress(try file_decoder.@"resume"(&file_trace), 0, .ready);
    }
    try std.testing.expectError(
        error.LimitExceeded,
        file_decoder.feedProgress(&file_trace, "abcd"[offset..]),
    );
    try std.testing.expectEqual(@as(u64, 3), file_decoder.active_bytes);
    try std.testing.expectEqualStrings("abc", file_trace.bytes[0..file_trace.bytes_len]);

    const TotalLimited = parser.Parser(.{
        .entries = &progressive_entries,
        .limits = .{ .total_body_bytes_max = file_prefix.len + 2 },
    }, ProgressTrace);
    var total_decoder = try TotalLimited.init("B");
    var total_trace = ProgressTrace{ .chunk_max = 1, .chunk_pause = true };
    _ = try total_decoder.feedProgress(&total_trace, file_prefix);
    offset = 0;
    while (offset < 2) {
        const progress = try total_decoder.feedProgress(&total_trace, "abc"[offset..]);
        offset += progress.consumed;
        total_trace.resume_ready = true;
        _ = try total_decoder.@"resume"(&total_trace);
    }
    try std.testing.expectError(
        error.LimitExceeded,
        total_decoder.feedProgress(&total_trace, "abc"[offset..]),
    );
    try std.testing.expectEqual(
        @as(u64, file_prefix.len + 2),
        total_decoder.total_bytes,
    );
}

test "invalid consumer chunk progress fails closed" {
    const ProgressiveParser = parser.Parser(progressive_plan, ProgressTrace);
    for ([_]InvalidProgress{ .overshoot, .ready_partial }) |invalid| {
        var decoder = try ProgressiveParser.init("B");
        var trace = ProgressTrace{ .invalid = invalid };
        _ = try decoder.feedProgress(&trace, file_prefix);
        try std.testing.expectError(
            error.ConsumerInvariant,
            decoder.feedProgress(&trace, "ab"),
        );
    }
}

test "paused progressive callback requires explicit readiness poll" {
    const MissingParser = parser.Parser(progressive_plan, MissingResumeTrace);
    var decoder = try MissingParser.init("B");
    var trace = MissingResumeTrace{};
    try expectProgress(try decoder.feedProgress(&trace, file_prefix), file_prefix.len, .paused);
    try std.testing.expectError(error.ConsumerInvariant, decoder.@"resume"(&trace));
}

fn expectProgress(
    progress: parser.Progress,
    consumed: usize,
    flow: parser.Flow,
) !void {
    try std.testing.expectEqual(consumed, progress.consumed);
    try std.testing.expectEqual(flow, progress.flow);
}

fn expectError(
    comptime selected: plan_module.Plan,
    input: []const u8,
    expected: anyerror,
) !void {
    const TestParser = parser.Parser(selected, Trace);
    var decoder = try TestParser.init("B");
    var trace = Trace{};
    decoder.feed(&trace, input) catch |problem| {
        try std.testing.expectEqual(expected, problem);
        return;
    };
    try std.testing.expectError(expected, decoder.finish(&trace));
}

fn expectField(
    record: FieldRecord,
    kind: plan_module.PartKind,
    name: []const u8,
    value: []const u8,
) !void {
    try std.testing.expectEqual(kind, record.kind);
    try std.testing.expectEqual(@as(u16, 1), record.occurrence);
    try std.testing.expectEqualStrings(name, record.name[0..record.name_len]);
    try std.testing.expectEqualStrings(value, record.bytes[0..record.bytes_len]);
}
