const std = @import("std");

pub const Error = error{
    Malformed,
    LimitExceeded,
};

pub const Step = struct {
    consumed: usize,
    complete: ?[]const u8,
};

pub fn Collector(comptime bytes_max: usize) type {
    if (bytes_max < 2) {
        @compileError("multipart part-header byte limit must include the blank CRLF");
    }
    return struct {
        const Self = @This();

        storage: [bytes_max]u8 = undefined,
        used: usize = 0,
        finished: bool = false,

        pub fn feed(self: *Self, input: []const u8) Error!Step {
            std.debug.assert(!self.finished);
            var consumed: usize = 0;
            while (consumed < input.len) {
                const byte = input[consumed];
                if (self.used == self.storage.len) return error.LimitExceeded;
                if (byte == '\n' and (self.used == 0 or self.storage[self.used - 1] != '\r')) {
                    return error.Malformed;
                }
                if (self.used != 0 and self.storage[self.used - 1] == '\r' and byte != '\n') {
                    return error.Malformed;
                }
                self.storage[self.used] = byte;
                self.used += 1;
                consumed += 1;
                if (!self.hasTerminator()) continue;
                self.finished = true;
                return .{
                    .consumed = consumed,
                    .complete = self.storage[0..self.used],
                };
            }
            return .{ .consumed = consumed, .complete = null };
        }

        pub fn reset(self: *Self) void {
            self.used = 0;
            self.finished = false;
        }

        fn hasTerminator(self: *const Self) bool {
            if (self.used == 2) return std.mem.eql(u8, self.storage[0..2], "\r\n");
            if (self.used < 4) return false;
            return std.mem.eql(u8, self.storage[self.used - 4 .. self.used], "\r\n\r\n");
        }
    };
}

test "collects one bounded section and preserves transport tail" {
    const input = "Content-Disposition: form-data; name=title\r\n" ++
        "Content-Type: text/plain\r\n\r\npayload";
    for (1..input.len + 1) |split| {
        var collector = Collector(256){};
        var offset: usize = 0;
        var complete: ?[]const u8 = null;
        while (offset < input.len and complete == null) {
            const end = @min(input.len, offset + split);
            const step = try collector.feed(input[offset..end]);
            offset += step.consumed;
            complete = step.complete;
        }
        try std.testing.expectEqualStrings(
            "Content-Disposition: form-data; name=title\r\n" ++
                "Content-Type: text/plain\r\n\r\n",
            complete.?,
        );
        try std.testing.expectEqualStrings("payload", input[offset..]);
    }
}

test "empty section and limits are exact" {
    var empty = Collector(2){};
    const done = try empty.feed("\r\ntail");
    try std.testing.expectEqual(@as(usize, 2), done.consumed);
    try std.testing.expectEqualStrings("\r\n", done.complete.?);

    var limited = Collector(5){};
    _ = try limited.feed("a:x\r\n");
    try std.testing.expectError(error.LimitExceeded, limited.feed("\r\n"));
}

test "bare LF and broken CR reject immediately" {
    var bare_lf = Collector(16){};
    try std.testing.expectError(error.Malformed, bare_lf.feed("a:x\n"));
    var broken_cr = Collector(16){};
    try std.testing.expectError(error.Malformed, broken_cr.feed("a:x\rX"));
}

test {
    std.testing.refAllDecls(@This());
}
