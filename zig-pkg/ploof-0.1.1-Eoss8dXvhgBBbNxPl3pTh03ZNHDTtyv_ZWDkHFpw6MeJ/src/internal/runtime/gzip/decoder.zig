const std = @import("std");

pub const standard_members_max: usize = 8;
pub const standard_reader_buffer_bytes: usize = 4096;
pub const standard_stream_buffer_bytes: usize =
    std.compress.flate.history_len + standard_reader_buffer_bytes;
pub const Limit = enum(u8) {
    encoded,
    decoded,
    output,
    members,
};

pub const Complete = struct {
    decoded: []u8,
    decoded_count: usize,
    encoded_consumed: usize,
    member_count: usize,
};

pub const Result = union(enum) {
    complete: Complete,
    malformed,
    over_limit: Limit,
};

pub const StreamComplete = struct {
    decoded_count: usize,
    encoded_consumed: usize,
    member_count: usize,
};

pub const StreamResult = union(enum) {
    complete: StreamComplete,
    malformed,
    over_limit: Limit,
};

pub const DecodeError = error{ReadFailed};
pub const StreamDecodeError = error{ ReadFailed, WriteFailed };
pub const Standard = Decoder(standard_members_max);
pub fn Decoder(comptime members_max: usize) type {
    if (members_max == 0) @compileError("gzip members_max must be positive");
    return struct {
        pub fn decode(
            encoded: []const u8,
            output: []u8,
            encoded_max: usize,
            decoded_max: usize,
        ) Result {
            if (encoded.len > encoded_max) return .{ .over_limit = .encoded };
            var source = std.Io.Reader.fixed(encoded);
            return decodeReaderCore(
                members_max,
                &source,
                output,
                encoded_max,
                decoded_max,
            ) catch .malformed;
        }

        pub fn decodeReader(
            bounded_source: *std.Io.Reader,
            output: []u8,
            encoded_max: usize,
            decoded_max: usize,
        ) DecodeError!Result {
            // EndOfStream must mean the exact end of this encoded body. A
            // connection reader containing pipelined bytes is not bounded.
            return decodeReaderCore(
                members_max,
                bounded_source,
                output,
                encoded_max,
                decoded_max,
            );
        }

        pub fn decodeToWriter(
            encoded: []const u8,
            output: *std.Io.Writer,
            encoded_max: usize,
            decoded_max: usize,
        ) std.Io.Writer.Error!StreamResult {
            if (encoded.len > encoded_max) return .{ .over_limit = .encoded };
            var source = std.Io.Reader.fixed(encoded);
            return decodeReaderToWriterCore(
                members_max,
                &source,
                output,
                encoded_max,
                decoded_max,
            ) catch |err| switch (err) {
                error.ReadFailed => .malformed,
                error.WriteFailed => error.WriteFailed,
            };
        }

        pub fn decodeReaderToWriter(
            bounded_source: *std.Io.Reader,
            output: *std.Io.Writer,
            encoded_max: usize,
            decoded_max: usize,
        ) StreamDecodeError!StreamResult {
            // EndOfStream must mean the exact end of this encoded body.
            return decodeReaderToWriterCore(
                members_max,
                bounded_source,
                output,
                encoded_max,
                decoded_max,
            );
        }
    };
}

fn decodeReaderToWriterCore(
    comptime members_max: usize,
    source: *std.Io.Reader,
    output: *std.Io.Writer,
    encoded_max: usize,
    decoded_max: usize,
) StreamDecodeError!StreamResult {
    var counted: CountedReader = undefined;
    counted.init(source, encoded_max);
    var decoded_count: usize = 0;
    var member_count: usize = 0;
    while (true) {
        const at_member_limit = member_count == members_max;
        const header = parseHeader(&counted.interface, at_member_limit) catch |err| {
            return framingStreamResult(err, &counted);
        };
        if (counted.overLimit()) return streamEncodedLimit();
        if (header == .end) {
            if (member_count == 0) return .malformed;
            return streamCompleted(&counted, decoded_count, member_count);
        }
        if (at_member_limit) return .{ .over_limit = .members };

        counted.beginRaw();
        const member = decodeRawToWriter(
            &counted.interface,
            output,
            decoded_max - decoded_count,
        );
        const raw_ended = counted.endRaw();
        if (counted.overLimit()) return streamEncodedLimit();
        const raw = switch (member) {
            .complete => |value| value,
            .malformed => return .malformed,
            .over_limit => return .{ .over_limit = .decoded },
            .write_failed => return error.WriteFailed,
            .read_failed => if (raw_ended) return .malformed else return error.ReadFailed,
        };
        const footer = readFooter(&counted.interface) catch |err| {
            return framingStreamResult(err, &counted);
        };
        if (counted.overLimit()) return streamEncodedLimit();
        if (!validStreamFooter(&footer, raw)) return .malformed;
        output.flush() catch return error.WriteFailed;
        decoded_count += raw.decoded_count;
        member_count += 1;
    }
}

fn framingStreamResult(
    err: FramingError,
    counted: *const CountedReader,
) StreamDecodeError!StreamResult {
    return switch (err) {
        error.Malformed => if (counted.overLimit()) streamEncodedLimit() else .malformed,
        error.ReadFailed => error.ReadFailed,
    };
}

fn streamCompleted(
    counted: *const CountedReader,
    decoded_count: usize,
    member_count: usize,
) StreamResult {
    return .{ .complete = .{
        .decoded_count = decoded_count,
        .encoded_consumed = counted.consumed(),
        .member_count = member_count,
    } };
}

fn streamEncodedLimit() StreamResult {
    return .{ .over_limit = .encoded };
}

fn decodeReaderCore(
    comptime members_max: usize,
    source: *std.Io.Reader,
    output: []u8,
    encoded_max: usize,
    decoded_max: usize,
) DecodeError!Result {
    var counted: CountedReader = undefined;
    counted.init(source, encoded_max);
    var decoded_count: usize = 0;
    var member_count: usize = 0;
    while (true) {
        const at_member_limit = member_count == members_max;
        const header = parseHeader(&counted.interface, at_member_limit) catch |err| switch (err) {
            error.Malformed => return if (counted.overLimit()) encodedLimit() else .malformed,
            error.ReadFailed => return error.ReadFailed,
        };
        if (counted.overLimit()) return encodedLimit();
        if (header == .end) {
            if (member_count == 0) return .malformed;
            return completed(output, counted.consumed(), decoded_count, member_count);
        }
        if (at_member_limit) return .{ .over_limit = .members };
        const output_left = output.len - decoded_count;
        const decoded_left = decoded_max - decoded_count;
        const capacity = @min(output_left, decoded_left);
        counted.beginRaw();
        const member = decodeRaw(
            &counted.interface,
            output[decoded_count..][0..capacity],
        );
        const raw_ended = counted.endRaw();
        if (counted.overLimit()) return encodedLimit();
        const raw = switch (member) {
            .complete => |value| value,
            .malformed => return .malformed,
            .over_limit => return .{ .over_limit = limitFor(output_left, decoded_left) },
            .read_failed => if (raw_ended) return .malformed else return error.ReadFailed,
        };
        const footer = readFooter(&counted.interface) catch |err| switch (err) {
            error.Malformed => return if (counted.overLimit()) encodedLimit() else .malformed,
            error.ReadFailed => return error.ReadFailed,
        };
        if (counted.overLimit()) return encodedLimit();
        const decoded = output[decoded_count..][0..raw.decoded_count];
        if (!validFooter(&footer, decoded)) return .malformed;
        decoded_count += raw.decoded_count;
        member_count += 1;
    }
}

fn completed(
    output: []u8,
    encoded_count: usize,
    decoded_count: usize,
    member_count: usize,
) Result {
    return .{ .complete = .{
        .decoded = output[0..decoded_count],
        .decoded_count = decoded_count,
        .encoded_consumed = encoded_count,
        .member_count = member_count,
    } };
}

fn encodedLimit() Result {
    return .{ .over_limit = .encoded };
}

const CountedReader = struct {
    source: *std.Io.Reader,
    encoded_max: usize,
    pull_max: usize,
    pulled: usize,
    raw_mode: bool,
    raw_ended: bool,
    buffer: [standard_reader_buffer_bytes]u8,
    interface: std.Io.Reader,

    fn init(self: *CountedReader, source: *std.Io.Reader, encoded_max: usize) void {
        self.source = source;
        self.encoded_max = encoded_max;
        self.pull_max = encoded_max +| @sizeOf(u32);
        self.pulled = 0;
        self.raw_mode = false;
        self.raw_ended = false;
        self.interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = &self.buffer,
            .seek = 0,
            .end = 0,
        };
    }

    fn stream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *CountedReader = @alignCast(@fieldParentPtr("interface", reader));
        if (self.pulled == self.pull_max) return self.ended();
        const remaining = self.pull_max - self.pulled;
        const count = self.source.stream(
            writer,
            limit.min(.limited(remaining)),
        ) catch |err| return switch (err) {
            error.EndOfStream => self.ended(),
            else => |other| other,
        };
        self.pulled += count;
        return count;
    }

    fn ended(self: *CountedReader) std.Io.Reader.StreamError!usize {
        if (!self.raw_mode) return error.EndOfStream;
        self.raw_ended = true;
        return error.ReadFailed;
    }

    fn beginRaw(self: *CountedReader) void {
        self.raw_mode = true;
        self.raw_ended = false;
    }

    fn endRaw(self: *CountedReader) bool {
        self.raw_mode = false;
        return self.raw_ended;
    }

    fn overLimit(self: *const CountedReader) bool {
        return self.consumed() > self.encoded_max;
    }

    fn consumed(self: *const CountedReader) usize {
        return self.pulled - self.interface.bufferedLen();
    }
};

const Header = enum(u8) { end, complete };
const HeaderPrefix = union(enum) { end, complete: [10]u8 };
const FramingError = error{ Malformed, ReadFailed };

fn parseHeader(reader: *std.Io.Reader, prefix_only: bool) FramingError!Header {
    const prefix = try parseHeaderPrefix(reader);
    const fixed = switch (prefix) {
        .end => return .end,
        .complete => |bytes| bytes,
    };
    if (prefix_only) return .complete;
    const flags = fixed[3];
    const has_header_crc = flags & 0x02 != 0;
    var crc: std.hash.Crc32 = undefined;
    if (has_header_crc) {
        crc = std.hash.Crc32.init();
        crc.update(&fixed);
    }
    const crc_ptr: ?*std.hash.Crc32 = if (has_header_crc) &crc else null;
    if (flags & 0x04 != 0) {
        var length_bytes: [2]u8 = undefined;
        try readOptional(reader, crc_ptr, &length_bytes);
        const extra_length = std.mem.readInt(u16, &length_bytes, .little);
        try readOptionalCount(reader, crc_ptr, extra_length);
    }
    if (flags & 0x08 != 0) try readOptionalTerminated(reader, crc_ptr);
    if (flags & 0x10 != 0) try readOptionalTerminated(reader, crc_ptr);
    if (has_header_crc) try verifyHeaderCrc(reader, &crc);
    return .complete;
}

fn parseHeaderPrefix(reader: *std.Io.Reader) FramingError!HeaderPrefix {
    var fixed: [10]u8 = undefined;
    fixed[0] = reader.takeByte() catch |err| return switch (err) {
        error.EndOfStream => .end,
        error.ReadFailed => error.ReadFailed,
    };
    try readExact(reader, fixed[1..]);
    if (fixed[0] != 0x1f) return error.Malformed;
    if (fixed[1] != 0x8b) return error.Malformed;
    if (fixed[2] != 8) return error.Malformed;
    const flags = fixed[3];
    if (flags & 0xe0 != 0) return error.Malformed;
    return .{ .complete = fixed };
}

fn verifyHeaderCrc(reader: *std.Io.Reader, crc: *std.hash.Crc32) FramingError!void {
    var expected_bytes: [2]u8 = undefined;
    try readExact(reader, &expected_bytes);
    const expected = std.mem.readInt(u16, &expected_bytes, .little);
    const actual: u16 = @truncate(crc.final());
    if (actual != expected) return error.Malformed;
}

fn readExact(reader: *std.Io.Reader, output: []u8) FramingError!void {
    reader.readSliceAll(output) catch |err| return switch (err) {
        error.EndOfStream => error.Malformed,
        error.ReadFailed => error.ReadFailed,
    };
}

fn readOptional(
    reader: *std.Io.Reader,
    crc: ?*std.hash.Crc32,
    output: []u8,
) FramingError!void {
    try readExact(reader, output);
    if (crc) |value| value.update(output);
}

fn readOptionalCount(
    reader: *std.Io.Reader,
    crc: ?*std.hash.Crc32,
    count: usize,
) FramingError!void {
    var buffer: [64]u8 = undefined;
    var remaining = count;
    while (remaining > 0) {
        const length = @min(remaining, buffer.len);
        try readOptional(reader, crc, buffer[0..length]);
        remaining -= length;
    }
}

fn readOptionalTerminated(
    reader: *std.Io.Reader,
    crc: ?*std.hash.Crc32,
) FramingError!void {
    while (true) {
        if (reader.bufferedLen() == 0) {
            _ = reader.peekByte() catch |err| return switch (err) {
                error.EndOfStream => error.Malformed,
                error.ReadFailed => error.ReadFailed,
            };
        }
        const bytes = reader.buffered();
        const terminator = std.mem.findScalar(u8, bytes, 0) orelse {
            if (crc) |value| value.update(bytes);
            reader.toss(bytes.len);
            continue;
        };
        const length = terminator + 1;
        if (crc) |value| value.update(bytes[0..length]);
        reader.toss(length);
        return;
    }
}
const RawComplete = struct { decoded_count: usize };
const RawResult = union(enum) {
    complete: RawComplete,
    malformed,
    over_limit,
    read_failed,
};

const StreamRawComplete = struct {
    decoded_count: usize,
    checksum: u32,
    size: u32,
};

const StreamRawResult = union(enum) {
    complete: StreamRawComplete,
    malformed,
    over_limit,
    write_failed,
    read_failed,
};

const StreamWriteFailure = enum(u8) {
    none,
    over_limit,
    output,
};

const StreamMemberWriter = struct {
    output: *std.Io.Writer,
    decoded_max: usize,
    decoded_count: usize = 0,
    size: u32 = 0,
    checksum: std.hash.Crc32 = std.hash.Crc32.init(),
    failure: StreamWriteFailure = .none,
    buffer: [standard_stream_buffer_bytes]u8,
    interface: std.Io.Writer,

    fn init(self: *StreamMemberWriter, output: *std.Io.Writer, decoded_max: usize) void {
        self.* = .{
            .output = output,
            .decoded_max = decoded_max,
            .buffer = undefined,
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                    .flush = flush,
                },
                .buffer = &self.buffer,
            },
        };
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *StreamMemberWriter = @alignCast(@fieldParentPtr("interface", writer));
        if (writer.end != 0) {
            _ = try self.write(writer.buffered());
            writer.end = 0;
        }
        var count: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| count += try self.write(bytes);
        const pattern = data[data.len - 1];
        for (0..splat) |_| count += try self.write(pattern);
        return count;
    }

    fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (writer.end == 0) return;
        const self: *StreamMemberWriter = @alignCast(@fieldParentPtr("interface", writer));
        _ = try self.write(writer.buffered());
        writer.end = 0;
    }

    fn write(self: *StreamMemberWriter, bytes: []const u8) std.Io.Writer.Error!usize {
        const remaining = self.decoded_max - self.decoded_count;
        const length = @min(bytes.len, remaining);
        if (length != 0) {
            self.output.writeAll(bytes[0..length]) catch {
                self.failure = .output;
                return error.WriteFailed;
            };
            self.checksum.update(bytes[0..length]);
            self.decoded_count += length;
            self.size +%= @intCast(length);
        }
        if (length != bytes.len) {
            self.failure = .over_limit;
            return error.WriteFailed;
        }
        return length;
    }
};

pub const standard_stream_writer_bytes: usize = @sizeOf(StreamMemberWriter);
comptime {
    if (standard_stream_writer_bytes > standard_stream_buffer_bytes + 128) {
        @compileError("gzip streaming writer state exceeds fixed stack budget");
    }
}

fn decodeRaw(input: *std.Io.Reader, output: []u8) RawResult {
    var writer = std.Io.Writer.fixed(output);
    var decoder = std.compress.flate.Decompress.init(input, .raw, &.{});
    _ = decoder.reader.streamRemaining(&writer) catch |err| return switch (err) {
        error.WriteFailed => .over_limit,
        error.ReadFailed => if (decoder.err) |cause| switch (cause) {
            error.ReadFailed => .read_failed,
            else => .malformed,
        } else .malformed,
    };
    return .{ .complete = .{
        .decoded_count = writer.end,
    } };
}

fn decodeRawToWriter(
    input: *std.Io.Reader,
    output: *std.Io.Writer,
    decoded_max: usize,
) StreamRawResult {
    var writer: StreamMemberWriter = undefined;
    writer.init(output, decoded_max);
    var decoder = std.compress.flate.Decompress.init(input, .raw, &.{});
    _ = decoder.reader.streamRemaining(&writer.interface) catch |err| return switch (err) {
        error.WriteFailed => switch (writer.failure) {
            .over_limit => .over_limit,
            .output => .write_failed,
            .none => .malformed,
        },
        error.ReadFailed => if (decoder.err) |cause| switch (cause) {
            error.ReadFailed => .read_failed,
            else => .malformed,
        } else .malformed,
    };
    writer.interface.flush() catch return switch (writer.failure) {
        .over_limit => .over_limit,
        .output => .write_failed,
        .none => .malformed,
    };
    return .{ .complete = .{
        .decoded_count = writer.decoded_count,
        .checksum = writer.checksum.final(),
        .size = writer.size,
    } };
}

fn readFooter(reader: *std.Io.Reader) FramingError![8]u8 {
    var footer: [8]u8 = undefined;
    try readExact(reader, &footer);
    return footer;
}

fn validFooter(footer: []const u8, decoded: []const u8) bool {
    const expected_crc = std.mem.readInt(u32, footer[0..4], .little);
    if (std.hash.Crc32.hash(decoded) != expected_crc) return false;
    const expected_size = std.mem.readInt(u32, footer[4..8], .little);
    const actual_size: u32 = @truncate(decoded.len);
    return actual_size == expected_size;
}

fn validStreamFooter(footer: []const u8, decoded: StreamRawComplete) bool {
    const expected_crc = std.mem.readInt(u32, footer[0..4], .little);
    if (decoded.checksum != expected_crc) return false;
    const expected_size = std.mem.readInt(u32, footer[4..8], .little);
    return decoded.size == expected_size;
}

fn limitFor(output_left: usize, decoded_left: usize) Limit {
    return if (decoded_left <= output_left) .decoded else .output;
}
