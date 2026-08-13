const std = @import("std");
const dsl = @import("../native/dsl.zig");

pub const magic = "ZHLB";
pub const version: u16 = 4;

const rule_flag_nested: u8 = 1 << 0;

pub const PackError = error{
    BadMagic,
    BufferTooSmall,
    StringTooLong,
    Truncated,
    InvalidRuleKind,
    TrailingData,
    UnsupportedVersion,
};

pub const Header = struct {
    rule_count: u32,
    grammar_scope_len: u16,
    name_len: u16,
    root_scope_len: u16,
};

pub fn packNative(spec: *const dsl.NativeSpec, out: []u8) PackError![]const u8 {
    var w = FixedWriter{ .buf = out };
    try w.writeAll(magic);
    try w.writeU16(version);
    try w.writeU16(0);
    try w.writeU32(@intCast(spec.rule_count));
    try w.writeString16(spec.slice(spec.grammar_scope));
    try w.writeString16(spec.slice(spec.name));
    try w.writeString16(spec.slice(spec.root_scope));
    for (spec.ruleSlice()) |rule| {
        try w.writeByte(@intFromEnum(rule.kind));
        try w.writeString16(spec.slice(rule.value));
        try w.writeString16(spec.slice(rule.escape));
        try w.writeString16(spec.slice(rule.scope));
        try w.writeByte(if (rule.nested) rule_flag_nested else 0);
    }
    return w.buf[0..w.pos];
}

pub fn inspect(bytes: []const u8) PackError!Header {
    var r = FixedReader{ .buf = bytes };
    if (!std.mem.eql(u8, try r.readBytes(4), magic)) return error.BadMagic;
    if (try r.readU16() != version) return error.UnsupportedVersion;
    _ = try r.readU16();
    const rule_count = try r.readU32();
    const grammar_scope_len = try r.readU16();
    _ = try r.readBytes(grammar_scope_len);
    const name_len = try r.readU16();
    _ = try r.readBytes(name_len);
    const root_scope_len = try r.readU16();
    _ = try r.readBytes(root_scope_len);
    var i: u32 = 0;
    while (i < rule_count) : (i += 1) {
        const kind = try r.readByte();
        if (!isRuleKind(kind)) return error.InvalidRuleKind;
        _ = try r.readString16();
        _ = try r.readString16();
        _ = try r.readString16();
        _ = try r.readByte();
    }
    if (r.pos != r.buf.len) return error.TrailingData;
    return .{
        .rule_count = rule_count,
        .grammar_scope_len = grammar_scope_len,
        .name_len = name_len,
        .root_scope_len = root_scope_len,
    };
}

fn isRuleKind(value: u8) bool {
    inline for (@typeInfo(dsl.RuleKind).@"enum".fields) |field| {
        if (value == field.value) return true;
    }
    return false;
}

const FixedWriter = struct {
    buf: []u8,
    pos: usize = 0,

    fn writeAll(self: *FixedWriter, bytes: []const u8) PackError!void {
        if (self.pos + bytes.len > self.buf.len) return error.BufferTooSmall;
        @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }

    fn writeByte(self: *FixedWriter, byte: u8) PackError!void {
        if (self.pos == self.buf.len) return error.BufferTooSmall;
        self.buf[self.pos] = byte;
        self.pos += 1;
    }

    fn writeU16(self: *FixedWriter, value: u16) PackError!void {
        try self.writeByte(@intCast(value & 0xff));
        try self.writeByte(@intCast(value >> 8));
    }

    fn writeU32(self: *FixedWriter, value: u32) PackError!void {
        try self.writeByte(@intCast(value & 0xff));
        try self.writeByte(@intCast((value >> 8) & 0xff));
        try self.writeByte(@intCast((value >> 16) & 0xff));
        try self.writeByte(@intCast(value >> 24));
    }

    fn writeString8(self: *FixedWriter, value: []const u8) PackError!void {
        if (value.len > std.math.maxInt(u8)) return error.StringTooLong;
        try self.writeByte(@intCast(value.len));
        try self.writeAll(value);
    }

    fn writeString16(self: *FixedWriter, value: []const u8) PackError!void {
        if (value.len > std.math.maxInt(u16)) return error.StringTooLong;
        try self.writeU16(@intCast(value.len));
        try self.writeAll(value);
    }
};

const FixedReader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn readByte(self: *FixedReader) PackError!u8 {
        return (try self.readBytes(1))[0];
    }

    fn readBytes(self: *FixedReader, len: usize) PackError![]const u8 {
        if (self.pos + len > self.buf.len) return error.Truncated;
        const out = self.buf[self.pos..][0..len];
        self.pos += len;
        return out;
    }

    fn readU16(self: *FixedReader) PackError!u16 {
        const bytes = try self.readBytes(2);
        return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
    }

    fn readU32(self: *FixedReader) PackError!u32 {
        const bytes = try self.readBytes(4);
        return @as(u32, bytes[0]) |
            (@as(u32, bytes[1]) << 8) |
            (@as(u32, bytes[2]) << 16) |
            (@as(u32, bytes[3]) << 24);
    }

    fn readString16(self: *FixedReader) PackError![]const u8 {
        return self.readBytes(try self.readU16());
    }
};

test "packs native grammar header" {
    const source =
        \\grammar "source.zig" {
        \\    name "Zig 0.16";
        \\    scope root = "source.zig";
        \\    context main {
        \\        line_comment "//" scope "comment.line.double-slash.zig";
        \\    }
        \\}
    ;

    const spec = try dsl.parse(source);
    var buf: [16 * 1024]u8 = undefined;
    const packed_bytes = try packNative(&spec, &buf);
    const header = try inspect(packed_bytes);
    try std.testing.expectEqual(@as(u32, 1), header.rule_count);
    try std.testing.expectEqual(@as(u16, 10), header.grammar_scope_len);
    try std.testing.expectEqual(@as(u16, 8), header.name_len);
    try std.testing.expectEqual(@as(u16, 10), header.root_scope_len);
}

test "inspect validates packed rule payload" {
    const source =
        \\grammar "source.zig" {
        \\    name "Zig 0.16";
        \\    scope root = "source.zig";
        \\    context main {
        \\        line_comment "//" scope "comment.line.double-slash.zig";
        \\    }
        \\}
    ;

    const spec = try dsl.parse(source);
    var buf: [16 * 1024]u8 = undefined;
    const packed_bytes = try packNative(&spec, &buf);
    const first_rule = 4 + 2 + 2 + 4 +
        2 + spec.grammar_scope.len +
        2 + spec.name.len +
        2 + spec.root_scope.len;

    try std.testing.expectError(error.Truncated, inspect(packed_bytes[0 .. packed_bytes.len - 1]));
    buf[first_rule] = 255;
    try std.testing.expectError(error.InvalidRuleKind, inspect(packed_bytes));
    buf[first_rule] = @intFromEnum(dsl.RuleKind.line_comment);
    buf[packed_bytes.len] = 0;
    try std.testing.expectError(error.TrailingData, inspect(buf[0 .. packed_bytes.len + 1]));
}

test "packs max-sized rule strings" {
    var value = [_]u8{'a'} ** dsl.max_string_bytes;
    var spec = dsl.NativeSpec{};
    try spec.setString(&spec.grammar_scope, "source.test");
    try spec.setString(&spec.name, "Test");
    try spec.setString(&spec.root_scope, "source.test");
    var rule = dsl.NativeRule{ .kind = .regex_vm };
    try spec.setString(&rule.value, &value);
    try spec.setString(&rule.scope, "source.test");
    try spec.addRule(rule);

    var buf: [16 * 1024]u8 = undefined;
    const packed_bytes = try packNative(&spec, &buf);

    try std.testing.expect((try inspect(packed_bytes)).rule_count == 1);
}
