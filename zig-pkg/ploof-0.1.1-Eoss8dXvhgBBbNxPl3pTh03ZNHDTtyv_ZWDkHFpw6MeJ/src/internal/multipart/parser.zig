const std = @import("std");
const delimiter = @import("delimiter.zig");
const events = @import("events.zig");
const header_block = @import("header_block.zig");
const headers = @import("part_headers.zig");
const plan_module = @import("plan.zig");
const syntax = @import("wire_syntax.zig");

pub const Error = error{
    Malformed,
    LimitExceeded,
    UnsupportedMedia,
};

pub const ConsumerError = error{ConsumerInvariant};

pub const Flow = enum(u8) {
    ready,
    paused,
    complete,
};

/// `consumed` is the source prefix the caller may release. Retained scanner
/// bytes can make it larger than the file prefix accepted by the consumer.
pub const Progress = struct {
    consumed: usize,
    flow: Flow,
};

pub const CallbackFlow = enum(u8) {
    ready,
    paused,
};

pub const ChunkProgress = struct {
    /// Accepted event prefix. `ready` requires the whole event to be accepted.
    consumed: usize,
    flow: CallbackFlow,
};

/// Identifies previously issued consumer work. A progressive consumer which
/// returns `paused` must implement `multipartResume(Wait) Error!CallbackFlow`.
/// That method only polls readiness; it must not issue the logical event again.
pub const Wait = enum(u8) {
    file_start,
    file_chunk,
    file_end,
};

const Phase = enum(u8) {
    preamble,
    headers,
    part,
    epilogue,
    complete,
    failed,
};

const Active = enum(u8) {
    none,
    text,
    bytes,
    file,
    marker,
    discard,
};

const Blocked = enum(u8) {
    none,
    file_start,
    file_chunk,
    file_end_headers,
    file_end_epilogue,
};

pub fn Parser(comptime selected: plan_module.Plan, comptime Consumer: type) type {
    comptime plan_module.validate(selected);
    const limits = selected.limits;
    const HeaderCollector = header_block.Collector(limits.part_header_bytes_max);
    const DelimiterScanner = delimiter.Scanner(
        limits.delimiter_transport_padding_bytes_max,
    );
    const header_limits = headers.Limits{
        .header_fields_max = limits.part_headers_max,
        .header_bytes_max = limits.part_header_bytes_max,
        .name_bytes_max = limits.name_bytes_max,
        .filename_bytes_max = limits.filename_bytes_max,
        .disposition_parameters_max = limits.disposition_parameters_max,
    };
    const field_storage_bytes = comptime fieldStorageBytes(selected);

    return struct {
        const Self = @This();
        const progressive_consumer = @hasDecl(Consumer, "fileStartProgress") or
            @hasDecl(Consumer, "fileChunkProgress") or
            @hasDecl(Consumer, "fileEndProgress");
        const OptionalConsumerError = if (progressive_consumer) ConsumerError else error{};
        pub const FeedError = Error || Consumer.Error || OptionalConsumerError;
        pub const ProgressFeedError = Error || Consumer.Error || ConsumerError;

        scanner: DelimiterScanner,
        header_collector: HeaderCollector = .{},
        occurrences: [selected.entries.len]u16 = @splat(0),
        metadata: headers.Metadata = undefined,
        total_bytes: u64 = 0,
        active_bytes: u64 = 0,
        field_used: usize = 0,
        parts_used: u16 = 0,
        files_used: u16 = 0,
        active_entry: u16 = 0,
        active_occurrence: u16 = 0,
        active: Active = .none,
        phase: Phase = .preamble,
        blocked: Blocked = .none,
        finish_pending: bool = false,
        field_storage: [field_storage_bytes]u8 = undefined,

        pub fn init(boundary: []const u8) Error!Self {
            if (boundary.len == 0 or boundary.len > 70) return error.Malformed;
            if (boundary.len > limits.boundary_bytes_max) return error.LimitExceeded;
            return .{ .scanner = DelimiterScanner.init(boundary) };
        }

        pub fn feed(self: *Self, consumer: *Consumer, input: []const u8) FeedError!void {
            const progress = self.feedProgress(consumer, input) catch |problem| {
                return narrowProgressError(problem);
            };
            if (progress.consumed != input.len or progress.flow != .ready) {
                self.phase = .failed;
                return narrowProgressError(error.ConsumerInvariant);
            }
        }

        pub fn finish(self: *Self, consumer: *Consumer) FeedError!void {
            const progress = self.finishProgress(consumer) catch |problem| {
                return narrowProgressError(problem);
            };
            if (progress.flow != .complete) {
                self.phase = .failed;
                return narrowProgressError(error.ConsumerInvariant);
            }
        }

        pub fn feedProgress(
            self: *Self,
            consumer: *Consumer,
            input: []const u8,
        ) ProgressFeedError!Progress {
            std.debug.assert(self.phase != .complete and self.phase != .failed);
            return self.feedProgressInner(consumer, input) catch |problem| {
                self.phase = .failed;
                return problem;
            };
        }

        pub fn finishProgress(self: *Self, consumer: *Consumer) ProgressFeedError!Progress {
            std.debug.assert(self.phase != .complete and self.phase != .failed);
            if (self.blocked != .none) return .{ .consumed = 0, .flow = .paused };
            return self.finishProgressInner(consumer) catch |problem| {
                self.phase = .failed;
                return problem;
            };
        }

        /// Polls one blocked consumer operation and drains owned scanner bytes.
        /// Zig reserves `resume`, so callers spell this method `.@"resume"(...)`.
        pub fn @"resume"(self: *Self, consumer: *Consumer) ProgressFeedError!Progress {
            std.debug.assert(self.phase != .failed);
            if (self.phase == .complete) return .{ .consumed = 0, .flow = .complete };
            return self.resumeInner(consumer) catch |problem| {
                self.phase = .failed;
                return problem;
            };
        }

        pub fn isComplete(self: *const Self) bool {
            return self.phase == .complete;
        }

        fn feedProgressInner(
            self: *Self,
            consumer: *Consumer,
            input: []const u8,
        ) ProgressFeedError!Progress {
            if (self.blocked != .none) return .{ .consumed = 0, .flow = .paused };
            var offset: usize = 0;
            while (offset < input.len) {
                if (self.total_bytes == limits.total_body_bytes_max) {
                    return error.LimitExceeded;
                }
                const remaining = limits.total_body_bytes_max - self.total_bytes;
                const available = std.math.cast(usize, remaining) orelse std.math.maxInt(usize);
                const end = offset + @min(input.len - offset, available);
                const progress = try self.consume(consumer, input[offset..end]);
                if (progress.consumed > end - offset) return error.ConsumerInvariant;
                self.total_bytes += progress.consumed;
                offset += progress.consumed;
                if (progress.flow == .paused) {
                    return .{ .consumed = offset, .flow = .paused };
                }
                if (progress.consumed == 0) return error.ConsumerInvariant;
            }
            return .{ .consumed = offset, .flow = .ready };
        }

        fn consume(
            self: *Self,
            consumer: *Consumer,
            input: []const u8,
        ) ProgressFeedError!Progress {
            return switch (self.phase) {
                .preamble, .part, .epilogue => self.consumeDelimited(consumer, input),
                .headers => self.consumeHeaders(consumer, input),
                .complete, .failed => unreachable,
            };
        }

        fn consumeDelimited(
            self: *Self,
            consumer: *Consumer,
            input: []const u8,
        ) ProgressFeedError!Progress {
            const step = self.scanner.feed(input) catch |problem| return switch (problem) {
                error.Malformed => error.Malformed,
                error.LimitExceeded => error.LimitExceeded,
            };
            var consumed = step.consumed;
            const flow: CallbackFlow = switch (step.event) {
                .need_more => .ready,
                .data => |bytes| data: {
                    const part = if (self.phase == .part)
                        try self.consumePartData(consumer, bytes)
                    else
                        ChunkProgress{ .consumed = bytes.len, .flow = .ready };
                    if (step.data_retained) {
                        self.scanner.acknowledgeData(part.consumed);
                    } else {
                        consumed -= bytes.len - part.consumed;
                    }
                    break :data part.flow;
                },
                .delimiter => try self.openHeaders(consumer),
                .close => try self.closeParts(consumer),
            };
            return .{ .consumed = consumed, .flow = callbackToFlow(flow) };
        }

        fn consumeHeaders(
            self: *Self,
            consumer: *Consumer,
            input: []const u8,
        ) ProgressFeedError!Progress {
            const step = self.header_collector.feed(input) catch |problem| {
                return switch (problem) {
                    error.Malformed => error.Malformed,
                    error.LimitExceeded => error.LimitExceeded,
                };
            };
            if (step.complete) |section| {
                const metadata = headers.parse(header_limits, @constCast(section)) catch |problem| {
                    return switch (problem) {
                        error.Malformed => error.Malformed,
                        error.LimitExceeded => error.LimitExceeded,
                    };
                };
                const flow = try self.beginPart(consumer, metadata);
                return .{ .consumed = step.consumed, .flow = callbackToFlow(flow) };
            }
            return .{ .consumed = step.consumed, .flow = .ready };
        }

        fn openHeaders(self: *Self, consumer: *Consumer) ProgressFeedError!CallbackFlow {
            if (self.phase == .part) {
                const flow = try self.finishPart(consumer, .file_end_headers);
                if (flow == .paused) return .paused;
            }
            if (self.phase != .preamble and self.phase != .part) return error.Malformed;
            self.phase = .headers;
            return .ready;
        }

        fn closeParts(self: *Self, consumer: *Consumer) ProgressFeedError!CallbackFlow {
            if (self.phase == .part) {
                const flow = try self.finishPart(consumer, .file_end_epilogue);
                if (flow == .paused) return .paused;
            }
            if (self.phase != .preamble and self.phase != .part) return error.Malformed;
            self.phase = .epilogue;
            return .ready;
        }

        fn beginPart(
            self: *Self,
            consumer: *Consumer,
            metadata: headers.Metadata,
        ) ProgressFeedError!CallbackFlow {
            if (self.parts_used == limits.parts_max) return error.LimitExceeded;
            self.parts_used += 1;
            self.metadata = metadata;
            const entry_index = findEntry(selected, metadata.name) orelse {
                return self.beginUnknown();
            };
            const entry = selected.entries[entry_index];
            if (entry.kind != .file and metadata.filename != null) return error.Malformed;
            if (entry.kind == .file and isEmptyFilename(metadata)) {
                self.active = .marker;
                self.phase = .part;
                return .ready;
            }
            return self.beginKnown(consumer, entry_index, entry);
        }

        fn beginUnknown(self: *Self) Error!CallbackFlow {
            switch (selected.unknown_parts) {
                .reject => return error.Malformed,
                .discard => {
                    self.active = .discard;
                    self.active_bytes = 0;
                    self.phase = .part;
                    return .ready;
                },
            }
        }

        fn beginKnown(
            self: *Self,
            consumer: *Consumer,
            entry_index: usize,
            entry: plan_module.Entry,
        ) ProgressFeedError!CallbackFlow {
            if (self.occurrences[entry_index] == entry.maximum) return error.Malformed;
            if (entry.kind == .text) {
                headers.validateText(self.metadata) catch return error.UnsupportedMedia;
            }
            if (entry.kind == .file) {
                if (self.files_used == limits.files_max) return error.LimitExceeded;
                if (!mediaAccepted(entry.file_media, self.metadata)) {
                    return error.UnsupportedMedia;
                }
                self.files_used += 1;
            }
            self.occurrences[entry_index] += 1;
            self.active_entry = @intCast(entry_index);
            self.active_occurrence = self.occurrences[entry_index];
            self.active_bytes = 0;
            self.field_used = 0;
            self.active = activeKind(entry.kind);
            self.phase = .part;
            if (self.active != .file) return .ready;
            const flow = try fileStart(consumer, .{
                .entry_index = self.active_entry,
                .occurrence = self.active_occurrence,
                .metadata = self.metadata,
            });
            if (flow == .paused) self.blocked = .file_start;
            return flow;
        }

        fn consumePartData(
            self: *Self,
            consumer: *Consumer,
            bytes: []const u8,
        ) ProgressFeedError!ChunkProgress {
            if (bytes.len == 0) return .{ .consumed = 0, .flow = .ready };
            return switch (self.active) {
                .text, .bytes => copied: {
                    try self.copyField(bytes);
                    break :copied .{ .consumed = bytes.len, .flow = .ready };
                },
                .file => self.consumeFile(consumer, bytes),
                .marker => return error.Malformed,
                .discard => discarded: {
                    try self.consumeDiscard(bytes.len);
                    break :discarded .{ .consumed = bytes.len, .flow = .ready };
                },
                .none => return error.Malformed,
            };
        }

        fn copyField(self: *Self, bytes: []const u8) Error!void {
            const bytes_max = entryBytesMax(selected, selected.entries[self.active_entry]);
            if (self.field_used >= bytes_max and bytes.len != 0) {
                return error.LimitExceeded;
            }
            const available = @min(
                self.field_storage.len - self.field_used,
                bytes_max - self.field_used,
            );
            const copied = @min(bytes.len, available);
            @memcpy(self.field_storage[self.field_used..][0..copied], bytes[0..copied]);
            self.field_used += copied;
            if (copied != bytes.len) return error.LimitExceeded;
        }

        fn consumeFile(
            self: *Self,
            consumer: *Consumer,
            bytes: []const u8,
        ) ProgressFeedError!ChunkProgress {
            const remaining = limits.file_bytes_max - self.active_bytes;
            const available = std.math.cast(usize, remaining) orelse std.math.maxInt(usize);
            const delivered = @min(bytes.len, available);
            if (delivered == 0) return error.LimitExceeded;
            const progress = try fileChunk(consumer, .{
                .entry_index = self.active_entry,
                .occurrence = self.active_occurrence,
                .offset = self.active_bytes,
                .bytes = bytes[0..delivered],
            });
            if (progress.consumed > delivered or
                (progress.flow == .ready and progress.consumed != delivered))
            {
                return error.ConsumerInvariant;
            }
            self.active_bytes += progress.consumed;
            if (progress.flow == .paused) {
                self.blocked = .file_chunk;
                return progress;
            }
            if (delivered != bytes.len) return error.LimitExceeded;
            return progress;
        }

        fn consumeDiscard(self: *Self, byte_count: usize) Error!void {
            const maximum = switch (selected.unknown_parts) {
                .reject => unreachable,
                .discard => |value| value,
            };
            const count = std.math.add(u64, self.active_bytes, byte_count) catch {
                return error.LimitExceeded;
            };
            if (count > maximum) return error.LimitExceeded;
            self.active_bytes = count;
        }

        fn finishPart(
            self: *Self,
            consumer: *Consumer,
            blocked: Blocked,
        ) ProgressFeedError!CallbackFlow {
            switch (self.active) {
                .text => {
                    const bytes = self.field_storage[0..self.field_used];
                    if (!std.unicode.utf8ValidateSlice(bytes)) return error.Malformed;
                    try consumer.field(self.fieldEvent(bytes));
                },
                .bytes => try consumer.field(self.fieldEvent(
                    self.field_storage[0..self.field_used],
                )),
                .file => {
                    const flow = try fileEnd(consumer, .{
                        .entry_index = self.active_entry,
                        .occurrence = self.active_occurrence,
                        .bytes = self.active_bytes,
                    });
                    if (flow == .paused) {
                        self.blocked = blocked;
                        return .paused;
                    }
                },
                .marker, .discard => {},
                .none => return error.Malformed,
            }
            self.clearPart();
            return .ready;
        }

        fn clearPart(self: *Self) void {
            self.active = .none;
            self.active_bytes = 0;
            self.field_used = 0;
            self.header_collector.reset();
        }

        fn fieldEvent(self: *Self, bytes: []const u8) events.Field {
            return .{
                .entry_index = self.active_entry,
                .occurrence = self.active_occurrence,
                .kind = selected.entries[@as(usize, self.active_entry)].kind,
                .metadata = self.metadata,
                .bytes = bytes,
            };
        }

        fn resumeInner(self: *Self, consumer: *Consumer) ProgressFeedError!Progress {
            const blocked = self.blocked;
            if (blocked == .none) return .{ .consumed = 0, .flow = .ready };
            if (try fileResume(consumer, waitFor(blocked)) == .paused) {
                return .{ .consumed = 0, .flow = .paused };
            }
            self.blocked = .none;
            self.resolveBlocked(blocked);
            if (self.finish_pending) return self.completeFinish();
            while (self.scanner.hasRetainedData()) {
                const progress = try self.consumeDelimited(consumer, "");
                if (progress.consumed != 0) return error.ConsumerInvariant;
                if (progress.flow == .paused) return progress;
            }
            return .{ .consumed = 0, .flow = .ready };
        }

        fn resolveBlocked(self: *Self, blocked: Blocked) void {
            switch (blocked) {
                .file_start, .file_chunk => {},
                .file_end_headers => {
                    self.clearPart();
                    self.phase = .headers;
                },
                .file_end_epilogue => {
                    self.clearPart();
                    self.phase = .epilogue;
                },
                .none => unreachable,
            }
        }

        fn finishProgressInner(
            self: *Self,
            consumer: *Consumer,
        ) ProgressFeedError!Progress {
            switch (self.phase) {
                .headers => return error.Malformed,
                .preamble, .part => {
                    const event = self.scanner.finish() catch return error.Malformed;
                    if (event == null or event.? != .close) return error.Malformed;
                    self.finish_pending = true;
                    if (try self.closeParts(consumer) == .paused) {
                        return .{ .consumed = 0, .flow = .paused };
                    }
                    self.finish_pending = false;
                },
                .epilogue => {
                    if (try self.scanner.finish() != null) return error.Malformed;
                },
                .complete, .failed => unreachable,
            }
            return self.completeFinish();
        }

        fn completeFinish(self: *Self) Error!Progress {
            self.finish_pending = false;
            try self.validateRequired();
            self.phase = .complete;
            return .{ .consumed = 0, .flow = .complete };
        }

        fn fileStart(
            consumer: *Consumer,
            event: events.FileStart,
        ) ProgressFeedError!CallbackFlow {
            if (@hasDecl(Consumer, "fileStartProgress")) {
                return consumer.fileStartProgress(event);
            }
            try consumer.fileStart(event);
            return .ready;
        }

        fn fileChunk(
            consumer: *Consumer,
            event: events.FileChunk,
        ) ProgressFeedError!ChunkProgress {
            if (@hasDecl(Consumer, "fileChunkProgress")) {
                return consumer.fileChunkProgress(event);
            }
            try consumer.fileChunk(event);
            return .{ .consumed = event.bytes.len, .flow = .ready };
        }

        fn fileEnd(
            consumer: *Consumer,
            event: events.FileEnd,
        ) ProgressFeedError!CallbackFlow {
            if (@hasDecl(Consumer, "fileEndProgress")) {
                return consumer.fileEndProgress(event);
            }
            try consumer.fileEnd(event);
            return .ready;
        }

        fn fileResume(
            consumer: *Consumer,
            wait: Wait,
        ) ProgressFeedError!CallbackFlow {
            if (!@hasDecl(Consumer, "multipartResume")) return error.ConsumerInvariant;
            return consumer.multipartResume(wait);
        }

        fn narrowProgressError(problem: ProgressFeedError) FeedError {
            return switch (problem) {
                error.ConsumerInvariant => if (progressive_consumer)
                    error.ConsumerInvariant
                else
                    unreachable,
                else => |other| other,
            };
        }

        fn validateRequired(self: *const Self) Error!void {
            inline for (selected.entries, 0..) |entry, index| {
                if (entry.required and self.occurrences[index] == 0) {
                    return error.Malformed;
                }
            }
        }
    };
}

fn fieldStorageBytes(comptime selected: plan_module.Plan) usize {
    var maximum = selected.limits.field_bytes_max;
    inline for (selected.entries) |entry| {
        if (entry.kind != .file) maximum = @max(maximum, entryBytesMax(selected, entry));
    }
    return maximum;
}

fn entryBytesMax(comptime selected: plan_module.Plan, entry: plan_module.Entry) usize {
    return if (entry.bytes_max == 0) selected.limits.field_bytes_max else entry.bytes_max;
}

fn callbackToFlow(flow: CallbackFlow) Flow {
    return switch (flow) {
        .ready => .ready,
        .paused => .paused,
    };
}

fn waitFor(blocked: Blocked) Wait {
    return switch (blocked) {
        .file_start => .file_start,
        .file_chunk => .file_chunk,
        .file_end_headers, .file_end_epilogue => .file_end,
        .none => unreachable,
    };
}

fn findEntry(comptime selected: plan_module.Plan, name: []const u8) ?usize {
    inline for (selected.entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, name)) return index;
    }
    return null;
}

fn activeKind(kind: plan_module.PartKind) Active {
    return switch (kind) {
        .text => .text,
        .bytes => .bytes,
        .file => .file,
    };
}

fn isEmptyFilename(metadata: headers.Metadata) bool {
    const filename = metadata.filename orelse return false;
    return filename.bytes.len == 0;
}

fn mediaAccepted(policy: plan_module.FileMediaPolicy, metadata: headers.Metadata) bool {
    return switch (policy) {
        .any => |missing| metadata.content_type != null or missing == .allow,
        .claimed => |claimed| accepted: {
            const media = metadata.content_type orelse {
                break :accepted claimed.missing == .allow;
            };
            for (claimed.values) |value| {
                if (syntax.eqlIgnoreCase(value.type, media.type) and
                    syntax.eqlIgnoreCase(value.subtype, media.subtype))
                {
                    break :accepted true;
                }
            }
            break :accepted false;
        },
    };
}

test {
    std.testing.refAllDecls(@This());
}
