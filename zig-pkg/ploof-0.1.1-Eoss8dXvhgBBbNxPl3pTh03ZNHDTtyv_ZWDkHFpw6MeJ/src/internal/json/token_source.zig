const std = @import("std");
const body = @import("../../body.zig");

pub const depth_standard_max: u16 = 64;
pub const depth_hard_max: u16 = 256;

const scanner_storage_bytes: usize = 256;
const Scanner = std.json.Scanner;

pub const RawToken = std.json.Token;

pub const InitError = error{
    InvalidDepthLimit,
    ScannerCapacity,
};

pub const Error = InitError || error{
    Syntax,
    UnexpectedEnd,
    DepthLimitExceeded,
    ScratchTooSmall,
};

pub const Text = struct {
    bytes: []const u8,
    copied: bool,
};

pub const Measure = struct {
    bytes: usize,
    copied: bool,
};

pub const Token = union(enum) {
    object_begin,
    object_end,
    array_begin,
    array_end,
    boolean: bool,
    null,
    number: Text,
    string: Text,
};

pub const Source = struct {
    scanner_storage: [scanner_storage_bytes]u8 align(8) = undefined,
    scanner_allocator: std.heap.FixedBufferAllocator = undefined,
    scanner: Scanner = undefined,
    chunks: body.Iterator = undefined,
    diagnostics: Scanner.Diagnostics = .{},
    depth_max: u16 = depth_standard_max,
    input_ended: bool = false,
    live: bool = false,

    pub fn init(self: *Source, input: body.Bytes, depth_max: u16) InitError!void {
        if (depth_max == 0 or depth_max > depth_hard_max) {
            return error.InvalidDepthLimit;
        }
        self.scanner_allocator = std.heap.FixedBufferAllocator.init(&self.scanner_storage);
        self.scanner = Scanner.initStreaming(self.scanner_allocator.allocator());
        self.live = true;
        errdefer self.deinit();
        self.scanner.ensureTotalStackCapacity(depth_hard_max + 1) catch {
            return error.ScannerCapacity;
        };
        self.chunks = input.iterator();
        self.diagnostics = .{};
        self.scanner.enableDiagnostics(&self.diagnostics);
        self.depth_max = depth_max;
        self.input_ended = false;
    }

    pub fn deinit(self: *Source) void {
        if (!self.live) return;
        self.scanner.deinit();
        self.live = false;
    }

    pub fn byteOffset(self: *const Source) u64 {
        return self.diagnostics.getByteOffset();
    }

    pub fn nextRaw(self: *Source) Error!RawToken {
        while (true) {
            const token = self.scanner.next() catch |problem| switch (problem) {
                error.BufferUnderrun => {
                    try self.feed();
                    continue;
                },
                error.SyntaxError => return error.Syntax,
                error.UnexpectedEndOfInput => return error.UnexpectedEnd,
                error.OutOfMemory => return error.ScannerCapacity,
            };
            switch (token) {
                .object_begin, .array_begin => {
                    if (self.scanner.stackHeight() > self.depth_max) {
                        return error.DepthLimitExceeded;
                    }
                },
                else => {},
            }
            return token;
        }
    }

    pub fn next(self: *Source, scratch: []u8) Error!?Token {
        const first = try self.nextRaw();
        return switch (first) {
            .object_begin => .object_begin,
            .object_end => .object_end,
            .array_begin => .array_begin,
            .array_end => .array_end,
            .true => .{ .boolean = true },
            .false => .{ .boolean = false },
            .null => .null,
            .number, .partial_number => .{
                .number = try self.completeNumber(first, scratch),
            },
            .string,
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            => .{ .string = try self.completeString(first, scratch) },
            .allocated_number, .allocated_string => unreachable,
            .end_of_document => null,
        };
    }

    pub fn completeString(
        self: *Source,
        first: RawToken,
        scratch: []u8,
    ) Error!Text {
        var token = first;
        var used: usize = 0;
        var copied = false;
        while (true) {
            switch (token) {
                .string => |bytes| {
                    if (!copied) return .{ .bytes = bytes, .copied = false };
                    try append(scratch, &used, bytes);
                    return .{ .bytes = scratch[0..used], .copied = true };
                },
                .partial_string => |bytes| try append(scratch, &used, bytes),
                .partial_string_escaped_1 => |bytes| {
                    try append(scratch, &used, &bytes);
                },
                .partial_string_escaped_2 => |bytes| {
                    try append(scratch, &used, &bytes);
                },
                .partial_string_escaped_3 => |bytes| {
                    try append(scratch, &used, &bytes);
                },
                .partial_string_escaped_4 => |bytes| {
                    try append(scratch, &used, &bytes);
                },
                else => return error.Syntax,
            }
            copied = true;
            token = try self.nextRaw();
        }
    }

    pub fn completeNumber(
        self: *Source,
        first: RawToken,
        scratch: []u8,
    ) Error!Text {
        var token = first;
        var used: usize = 0;
        var copied = false;
        while (true) {
            switch (token) {
                .number => |bytes| {
                    if (!copied) return .{ .bytes = bytes, .copied = false };
                    try append(scratch, &used, bytes);
                    return .{ .bytes = scratch[0..used], .copied = true };
                },
                .partial_number => |bytes| try append(scratch, &used, bytes),
                else => return error.Syntax,
            }
            copied = true;
            token = try self.nextRaw();
        }
    }

    pub fn measureString(self: *Source, first: RawToken) Error!Measure {
        var token = first;
        var total: usize = 0;
        var copied = false;
        while (true) {
            const bytes: usize = switch (token) {
                .string, .partial_string => |value| value.len,
                .partial_string_escaped_1 => 1,
                .partial_string_escaped_2 => 2,
                .partial_string_escaped_3 => 3,
                .partial_string_escaped_4 => 4,
                else => return error.Syntax,
            };
            total = std.math.add(usize, total, bytes) catch {
                return error.ScratchTooSmall;
            };
            if (token == .string) return .{ .bytes = total, .copied = copied };
            copied = true;
            token = try self.nextRaw();
        }
    }

    pub fn measureNumber(self: *Source, first: RawToken) Error!Measure {
        var token = first;
        var total: usize = 0;
        var copied = false;
        while (true) {
            const bytes: usize = switch (token) {
                .number, .partial_number => |value| value.len,
                else => return error.Syntax,
            };
            total = std.math.add(usize, total, bytes) catch {
                return error.ScratchTooSmall;
            };
            if (token == .number) return .{ .bytes = total, .copied = copied };
            copied = true;
            token = try self.nextRaw();
        }
    }

    pub fn discardString(self: *Source, first: RawToken) Error!void {
        var token = first;
        while (true) {
            switch (token) {
                .string => return,
                .partial_string,
                .partial_string_escaped_1,
                .partial_string_escaped_2,
                .partial_string_escaped_3,
                .partial_string_escaped_4,
                => token = try self.nextRaw(),
                else => return error.Syntax,
            }
        }
    }

    pub fn discardNumber(self: *Source, first: RawToken) Error!void {
        var token = first;
        while (true) {
            switch (token) {
                .number => return,
                .partial_number => token = try self.nextRaw(),
                else => return error.Syntax,
            }
        }
    }

    fn feed(self: *Source) Error!void {
        if (self.chunks.next()) |chunk| {
            self.scanner.feedInput(chunk);
            return;
        }
        if (self.input_ended) return error.UnexpectedEnd;
        self.scanner.endInput();
        self.input_ended = true;
    }
};

fn append(output: []u8, used: *usize, bytes: []const u8) Error!void {
    const end = std.math.add(usize, used.*, bytes.len) catch {
        return error.ScratchTooSmall;
    };
    if (end > output.len) return error.ScratchTooSmall;
    @memcpy(output[used.*..end], bytes);
    used.* = end;
}

test {
    std.testing.refAllDecls(@This());
}
