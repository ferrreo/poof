const std = @import("std");
const config_module = @import("load_driver_config.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const ExpectedBody = config_module.ExpectedBody;

pub const response_head_bytes_max: usize = 16 * 1024;
const trailer_bytes_max: usize = 4 * 1024;
const chunk_line_bytes_max: usize = 128;

const Phase = enum {
    head,
    content,
    chunked,
    close_delimited,
    complete,
};

const ChunkPhase = enum {
    size,
    data,
    data_cr,
    data_lf,
    trailer,
};

pub const Parser = struct {
    expected_status: u16 = 200,
    expected_body: ExpectedBody = .{ .bytes = "" },
    hasher: Sha256 = Sha256.init(.{}),
    head: [response_head_bytes_max]u8 = undefined,
    head_len: usize = 0,
    body_offset: u64 = 0,
    content_remaining: u64 = 0,
    chunk_remaining: u64 = 0,
    chunk_line: [chunk_line_bytes_max]u8 = undefined,
    chunk_line_len: usize = 0,
    trailer_bytes: usize = 0,
    phase: Phase = .head,
    chunk_phase: ChunkPhase = .size,
    close_after: bool = false,

    pub fn init(expected_status: u16, expected_body: ExpectedBody) Parser {
        return .{
            .expected_status = expected_status,
            .expected_body = expected_body,
        };
    }

    pub fn reset(self: *Parser, expected_status: u16, expected_body: ExpectedBody) void {
        self.* = init(expected_status, expected_body);
    }

    pub fn complete(self: *const Parser) bool {
        return self.phase == .complete;
    }

    pub fn feed(self: *Parser, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len != 0) {
            remaining = switch (self.phase) {
                .head => try self.feedHead(remaining),
                .content => try self.feedContent(remaining),
                .chunked => try self.feedChunked(remaining),
                .close_delimited => try self.feedCloseDelimited(remaining),
                .complete => return error.BytesAfterResponse,
            };
        }
    }

    pub fn eof(self: *Parser) !void {
        switch (self.phase) {
            .close_delimited => {
                try self.finishBody();
                self.phase = .complete;
            },
            .complete => {},
            else => return error.TruncatedResponse,
        }
    }

    fn feedHead(self: *Parser, bytes: []const u8) ![]const u8 {
        var consumed: usize = 0;
        while (consumed < bytes.len) : (consumed += 1) {
            if (self.head_len == self.head.len) return error.ResponseHeadTooLarge;
            self.head[self.head_len] = bytes[consumed];
            self.head_len += 1;
            if (self.head_len >= 4 and
                std.mem.eql(u8, self.head[self.head_len - 4 .. self.head_len], "\r\n\r\n"))
            {
                try self.parseHead();
                return bytes[consumed + 1 ..];
            }
        }
        return bytes[consumed..];
    }

    fn parseHead(self: *Parser) !void {
        const status_end = std.mem.indexOf(u8, self.head[0..self.head_len], "\r\n") orelse {
            return error.InvalidStatusLine;
        };
        try self.parseStatus(self.head[0..status_end]);
        var cursor = status_end + 2;
        var content_length: ?u64 = null;
        var chunked = false;
        while (cursor < self.head_len - 2) {
            const remaining = self.head[cursor..self.head_len];
            const relative_end = std.mem.indexOf(u8, remaining, "\r\n") orelse {
                return error.InvalidHeaderLine;
            };
            const end = cursor + relative_end;
            if (end == cursor) break;
            try self.parseHeader(self.head[cursor..end], &content_length, &chunked);
            cursor = end + 2;
        }
        try self.selectFraming(content_length, chunked);
    }

    fn parseStatus(self: *Parser, line: []const u8) !void {
        if (line.len < 13 or !std.mem.eql(u8, line[0..9], "HTTP/1.1 ")) {
            return error.InvalidStatusLine;
        }
        if (line[12] != ' ') return error.InvalidStatusLine;
        for (line[13..]) |byte| {
            if (byte < 0x20 or byte > 0x7e) return error.InvalidStatusLine;
        }
        const status = std.fmt.parseUnsigned(u16, line[9..12], 10) catch {
            return error.InvalidStatusLine;
        };
        if (status != self.expected_status) return error.UnexpectedStatus;
    }

    fn parseHeader(
        self: *Parser,
        line: []const u8,
        content_length: *?u64,
        chunked: *bool,
    ) !void {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeaderLine;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (!headerNameValid(name) or !headerValueValid(value)) return error.InvalidHeaderLine;
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (content_length.* != null) return error.DuplicateContentLength;
            content_length.* = std.fmt.parseUnsigned(u64, value, 10) catch {
                return error.InvalidContentLength;
            };
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (chunked.* or !std.ascii.eqlIgnoreCase(value, "chunked")) {
                return error.InvalidTransferEncoding;
            }
            chunked.* = true;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            self.close_after = self.close_after or try connectionCloses(value);
        }
    }

    fn selectFraming(self: *Parser, content_length: ?u64, chunked: bool) !void {
        if (content_length != null and chunked) return error.AmbiguousFraming;
        if (bodyForbidden(self.expected_status)) {
            if ((self.expected_status == 204 and content_length != null) or
                chunked or (content_length orelse 0) != 0 or self.expectedLength() != 0)
            {
                return error.BodyForbidden;
            }
            try self.finishBody();
            self.phase = .complete;
        } else if (content_length) |length| {
            if (length != self.expectedLength()) return error.UnexpectedBodyLength;
            self.content_remaining = length;
            if (length == 0) {
                try self.finishBody();
                self.phase = .complete;
            } else {
                self.phase = .content;
            }
        } else if (chunked) {
            self.phase = .chunked;
            self.chunk_phase = .size;
        } else {
            self.close_after = true;
            self.phase = .close_delimited;
        }
    }

    fn feedContent(self: *Parser, bytes: []const u8) ![]const u8 {
        const used: usize = @intCast(@min(bytes.len, self.content_remaining));
        try self.compareBody(bytes[0..used]);
        self.content_remaining -= used;
        if (self.content_remaining == 0) {
            try self.finishBody();
            self.phase = .complete;
        }
        return bytes[used..];
    }

    fn feedCloseDelimited(self: *Parser, bytes: []const u8) ![]const u8 {
        try self.compareBody(bytes);
        return bytes[bytes.len..];
    }

    fn feedChunked(self: *Parser, bytes: []const u8) ![]const u8 {
        var remaining = bytes;
        while (remaining.len != 0 and self.phase == .chunked) {
            remaining = switch (self.chunk_phase) {
                .size => try self.feedChunkLine(remaining, false),
                .data => try self.feedChunkData(remaining),
                .data_cr => try self.expectChunkByte(remaining, '\r', .data_lf),
                .data_lf => try self.expectChunkByte(remaining, '\n', .size),
                .trailer => try self.feedChunkLine(remaining, true),
            };
        }
        return remaining;
    }

    fn feedChunkLine(self: *Parser, bytes: []const u8, trailer: bool) ![]const u8 {
        var consumed: usize = 0;
        while (consumed < bytes.len) : (consumed += 1) {
            if (self.chunk_line_len == self.chunk_line.len) return error.ChunkLineTooLarge;
            const byte = bytes[consumed];
            self.chunk_line[self.chunk_line_len] = byte;
            self.chunk_line_len += 1;
            if (self.chunk_line_len < 2 or byte != '\n') continue;
            if (self.chunk_line[self.chunk_line_len - 2] != '\r') {
                return error.InvalidChunkLine;
            }
            const line = self.chunk_line[0 .. self.chunk_line_len - 2];
            if (trailer) try self.finishTrailerLine(line) else try self.finishSizeLine(line);
            self.chunk_line_len = 0;
            return bytes[consumed + 1 ..];
        }
        return bytes[consumed..];
    }

    fn finishSizeLine(self: *Parser, line: []const u8) !void {
        if (line.len == 0 or std.mem.indexOfScalar(u8, line, ';') != null) {
            return error.InvalidChunkSize;
        }
        const size = std.fmt.parseUnsigned(u64, line, 16) catch return error.InvalidChunkSize;
        self.chunk_remaining = size;
        self.chunk_phase = if (size == 0) .trailer else .data;
    }

    fn finishTrailerLine(self: *Parser, line: []const u8) !void {
        self.trailer_bytes = std.math.add(usize, self.trailer_bytes, line.len + 2) catch {
            return error.TrailersTooLarge;
        };
        if (self.trailer_bytes > trailer_bytes_max) return error.TrailersTooLarge;
        if (line.len == 0) {
            try self.finishBody();
            self.phase = .complete;
            return;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidTrailer;
        if (!headerNameValid(line[0..colon]) or !headerValueValid(line[colon + 1 ..])) {
            return error.InvalidTrailer;
        }
    }

    fn feedChunkData(self: *Parser, bytes: []const u8) ![]const u8 {
        const used: usize = @intCast(@min(bytes.len, self.chunk_remaining));
        try self.compareBody(bytes[0..used]);
        self.chunk_remaining -= used;
        if (self.chunk_remaining == 0) self.chunk_phase = .data_cr;
        return bytes[used..];
    }

    fn expectChunkByte(
        self: *Parser,
        bytes: []const u8,
        expected: u8,
        next: ChunkPhase,
    ) ![]const u8 {
        if (bytes[0] != expected) return error.InvalidChunkDelimiter;
        self.chunk_phase = next;
        return bytes[1..];
    }

    fn compareBody(self: *Parser, bytes: []const u8) !void {
        const end = std.math.add(u64, self.body_offset, bytes.len) catch {
            return error.UnexpectedBodyLength;
        };
        if (end > self.expectedLength()) return error.UnexpectedBodyLength;
        switch (self.expected_body) {
            .bytes => |expected| {
                const start: usize = @intCast(self.body_offset);
                const finish: usize = @intCast(end);
                if (!std.mem.eql(u8, bytes, expected[start..finish])) {
                    return error.UnexpectedBody;
                }
            },
            .sha256 => self.hasher.update(bytes),
        }
        self.body_offset = end;
    }

    fn expectedLength(self: *const Parser) u64 {
        return switch (self.expected_body) {
            .bytes => |bytes| bytes.len,
            .sha256 => |hashed| hashed.bytes,
        };
    }

    fn finishBody(self: *Parser) !void {
        if (self.body_offset != self.expectedLength()) return error.UnexpectedBodyLength;
        switch (self.expected_body) {
            .bytes => {},
            .sha256 => |hashed| {
                var actual: [Sha256.digest_length]u8 = undefined;
                self.hasher.final(&actual);
                if (!std.mem.eql(u8, &actual, &hashed.digest)) return error.UnexpectedBody;
            },
        }
    }
};

fn bodyForbidden(status: u16) bool {
    return status / 100 == 1 or status == 204 or status == 205 or status == 304;
}

fn connectionCloses(value: []const u8) !bool {
    var parts = std.mem.splitScalar(u8, value, ',');
    var closes = false;
    while (parts.next()) |part| {
        const token = std.mem.trim(u8, part, " \t");
        if (!headerNameValid(token)) return error.InvalidConnection;
        closes = closes or std.ascii.eqlIgnoreCase(token, "close");
    }
    return closes;
}

fn headerNameValid(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| switch (byte) {
        'a'...'z',
        'A'...'Z',
        '0'...'9',
        '!',
        '#',
        '$',
        '%',
        '&',
        '\'',
        '*',
        '+',
        '-',
        '.',
        '^',
        '_',
        '`',
        '|',
        '~',
        => {},
        else => return false,
    };
    return true;
}

fn headerValueValid(value: []const u8) bool {
    for (value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    return true;
}

test "content-length response validates exact status and body" {
    var parser = Parser.init(200, .{ .bytes = "hello" });
    try parser.feed("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhe");
    try parser.feed("llo");
    try std.testing.expect(parser.complete());

    parser.reset(201, .{ .bytes = "hello" });
    try std.testing.expectError(
        error.UnexpectedStatus,
        parser.feed("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"),
    );
}

test "chunked response validates fragmented identity and trailers" {
    var parser = Parser.init(200, .{ .bytes = "Wikipedia" });
    try parser.feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWi");
    try parser.feed("ki\r\n5\r\npedia\r\n0\r\nX-Trace: yes\r\n");
    try parser.feed("\r\n");
    try std.testing.expect(parser.complete());
}

test "ambiguous framing and wrong body fail closed" {
    var parser = Parser.init(200, .{ .bytes = "a" });
    try std.testing.expectError(
        error.AmbiguousFraming,
        parser.feed(
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
        ),
    );
    parser.reset(200, .{ .bytes = "a" });
    try std.testing.expectError(
        error.UnexpectedBody,
        parser.feed("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nb"),
    );
}

test "close-delimited response completes only at eof" {
    var parser = Parser.init(200, .{ .bytes = "close-body" });
    try parser.feed("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nclose-body");
    try std.testing.expect(!parser.complete());
    try parser.eof();
    try std.testing.expect(parser.complete());
}

test "hashed identity validates streamed bodies without retention" {
    const body = "0123456789abcdef";
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(body, &digest, .{});
    var parser = Parser.init(200, .{ .sha256 = .{
        .bytes = body.len,
        .digest = digest,
    } });
    try parser.feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n");
    try parser.feed(body[0..7]);
    try parser.feed(body[7..]);
    try parser.feed("\r\n0\r\n\r\n");
    try std.testing.expect(parser.complete());
}

test "response grammar rejects excess duplicate overflow and premature eof" {
    var parser = Parser.init(200, .{ .bytes = "" });
    try std.testing.expectError(
        error.BytesAfterResponse,
        parser.feed("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nx"),
    );
    parser.reset(200, .{ .bytes = "" });
    try std.testing.expectError(
        error.DuplicateContentLength,
        parser.feed("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n"),
    );
    parser.reset(200, .{ .bytes = "" });
    try std.testing.expectError(
        error.InvalidContentLength,
        parser.feed("HTTP/1.1 200 OK\r\nContent-Length: 18446744073709551616\r\n\r\n"),
    );
    parser.reset(200, .{ .bytes = "a" });
    try parser.feed("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n");
    try std.testing.expectError(error.TruncatedResponse, parser.eof());
}

test "every response boundary may fragment and reset clears close state" {
    const response = "HTTP/1.1 200 OK\r\nConnection: close\r\n" ++
        "Connection: keep-alive\r\nContent-Length: 2\r\n\r\nok";
    var parser = Parser.init(200, .{ .bytes = "ok" });
    for (response) |byte| try parser.feed(&.{byte});
    try std.testing.expect(parser.complete());
    try std.testing.expect(parser.close_after);
    parser.reset(205, .{ .bytes = "" });
    try parser.feed("HTTP/1.1 205 Reset Content\r\nContent-Length: 0\r\n\r\n");
    try std.testing.expect(parser.complete());
    try std.testing.expect(!parser.close_after);
    parser.reset(200, .{ .bytes = "" });
    try std.testing.expectError(
        error.InvalidStatusLine,
        parser.feed("HTTP/1.1 200\r\nContent-Length: 0\r\n\r\n"),
    );
}

test "status reasons and connection token lists are strict" {
    var parser = Parser.init(200, .{ .bytes = "" });
    try std.testing.expectError(
        error.InvalidStatusLine,
        parser.feed("HTTP/1.1 200 bad\x00reason\r\nContent-Length: 0\r\n\r\n"),
    );
    parser.reset(200, .{ .bytes = "" });
    try std.testing.expectError(
        error.InvalidConnection,
        parser.feed("HTTP/1.1 200 OK\r\nConnection: close,,keep-alive\r\n" ++
            "Content-Length: 0\r\n\r\n"),
    );
}

test "bodyless statuses enforce framing and hashed empty identity" {
    var digest: [Sha256.digest_length]u8 = @splat(0);
    var parser = Parser.init(205, .{ .sha256 = .{ .bytes = 0, .digest = digest } });
    try std.testing.expectError(
        error.UnexpectedBody,
        parser.feed("HTTP/1.1 205 Reset Content\r\nContent-Length: 0\r\n\r\n"),
    );
    Sha256.hash("", &digest, .{});
    parser.reset(205, .{ .sha256 = .{ .bytes = 0, .digest = digest } });
    try parser.feed("HTTP/1.1 205 Reset Content\r\nContent-Length: 0\r\n\r\n");
    try std.testing.expect(parser.complete());
    parser.reset(204, .{ .bytes = "" });
    try std.testing.expectError(
        error.BodyForbidden,
        parser.feed("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"),
    );
}
