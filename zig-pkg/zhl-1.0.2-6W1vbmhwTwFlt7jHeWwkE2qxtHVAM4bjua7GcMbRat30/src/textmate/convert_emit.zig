const std = @import("std");
const dsl_emit = @import("../native/dsl_emit.zig");

const writeDslString = dsl_emit.writeString;

pub fn keywordChunk(writer: anytype, words: []const u8, scope: []const u8) !void {
    try writer.writeAll("        keywords ");
    try writeDslString(writer, words);
    try writer.writeAll(" scope ");
    try writeDslString(writer, scope);
    try writer.writeAll(";\n");
}

pub fn delimited(writer: anytype, kind: []const u8, value: []const u8, scope: []const u8) !void {
    try writer.writeAll("        ");
    try writer.writeAll(kind);
    try writer.writeByte(' ');
    try writeDslString(writer, value);
    try writer.writeAll(" escape ");
    try writeDslString(writer, "\\");
    try writer.writeAll(" scope ");
    try writeDslString(writer, scope);
    try writer.writeAll(";\n");
}

pub fn asymmetricDelimited(writer: anytype, open: []const u8, close: []const u8, scope: []const u8) !void {
    try writer.writeAll("        delimited ");
    try writeDslString(writer, open);
    try writer.writeByte(' ');
    try writeDslString(writer, close);
    try writer.writeAll(" escape ");
    try writeDslString(writer, "\\");
    try writer.writeAll(" scope ");
    try writeDslString(writer, scope);
    try writer.writeAll(";\n");
}

pub fn rule1(writer: anytype, kind: []const u8, value: []const u8, scope: []const u8) !void {
    try writer.writeAll("        ");
    try writer.writeAll(kind);
    try writer.writeByte(' ');
    try writeDslString(writer, value);
    try writer.writeAll(" scope ");
    try writeDslString(writer, scope);
    try writer.writeAll(";\n");
}

pub fn rule2(writer: anytype, kind: []const u8, first: []const u8, second: []const u8, scope: []const u8) !void {
    try writer.writeAll("        ");
    try writer.writeAll(kind);
    try writer.writeByte(' ');
    try writeDslString(writer, first);
    try writer.writeByte(' ');
    try writeDslString(writer, second);
    try writer.writeAll(" scope ");
    try writeDslString(writer, scope);
    try writer.writeAll(";\n");
}

pub fn nameRule(writer: anytype, kind: []const u8, value: []const u8, scope: []const u8) !void {
    try writer.writeAll("        ");
    try writer.writeAll(kind);
    try writer.writeByte(' ');
    try writer.writeAll(value);
    try writer.writeAll(" scope ");
    try writeDslString(writer, scope);
    try writer.writeAll(";\n");
}

pub fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}
