//! General-purpose C ABI export layer for zhl.
//!
//! Built as wasm32-freestanding (`zig build wasm-api`) and native shared library
//! (`zig build shared`). Language set is selected at build time via `-Dlangs=`
//! (see tools/select_grammars.sh). The API is single-threaded: results live in
//! module-level globals until the next highlight/render call or `zhl_result_free`.
//!
//! Error codes: 0 ok; 1 StackOverflow; 2 DynamicCaptureOverflow;
//! 3 RegexVmStackOverflow; 4 RegexCaptureOverflow; 5 RegexStepLimitExceeded;
//! 6 TokenOverflow; 7 LineTooLong; 8 MalformedGrammar; 100 OutOfMemory;
//! 101 unknown language id.

const std = @import("std");
const builtin = @import("builtin");
const zhl = @import("zhl");
const grammars = @import("zhl_grammars");
const selected = @import("zhl_grammars_selected");

const allocator: std.mem.Allocator = if (builtin.target.cpu.arch.isWasm())
    std.heap.wasm_allocator
else
    std.heap.smp_allocator;

const status_ok: u32 = 0;
const status_out_of_memory: u32 = 100;
const status_unknown_language: u32 = 101;

const ResultKind = enum { none, tokens, bytes };

var result_kind: ResultKind = .none;
var token_result: std.ArrayList(zhl.wasm.TokenAbi) = .empty;
var byte_result: std.ArrayList(u8) = .empty;

const AnyHighlighter = zhl.Engine(grammars.json.grammar, .{});
const Sink = zhl.sinks.TokenBuffer(8192);
var engine_scratch: AnyHighlighter.Scratch = .init();
var engine_sink: Sink = .init();

pub export fn zhl_api_version() u32 {
    return 1;
}

pub export fn zhl_language_count() u32 {
    return @intCast(selected.count());
}

pub export fn zhl_alloc(len: usize) usize {
    if (len == 0) return 0;
    const bytes = allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(bytes.ptr);
}

pub export fn zhl_free(ptr: usize, len: usize) void {
    if (ptr == 0 or len == 0) return;
    const bytes: [*]u8 = @ptrFromInt(ptr);
    allocator.free(bytes[0..len]);
}

pub export fn zhl_language_from_name(name_ptr: [*]const u8, name_len: usize) u32 {
    return selected.idFromName(name_ptr[0..name_len]);
}

pub export fn zhl_token_size() u32 {
    return @sizeOf(zhl.wasm.TokenAbi);
}

pub export fn zhl_highlight(lang: u32, src_ptr: [*]const u8, src_len: usize) u32 {
    token_result.clearRetainingCapacity();
    byte_result.clearRetainingCapacity();
    result_kind = .none;
    return selected.dispatchHighlight(lang, src_ptr[0..src_len], .tokens, run);
}

pub export fn zhl_render_html(lang: u32, src_ptr: [*]const u8, src_len: usize) u32 {
    token_result.clearRetainingCapacity();
    byte_result.clearRetainingCapacity();
    result_kind = .none;
    return selected.dispatchHighlight(lang, src_ptr[0..src_len], .html, run);
}

pub export fn zhl_result_ptr() usize {
    return switch (result_kind) {
        .none => 0,
        .tokens => @intFromPtr(token_result.items.ptr),
        .bytes => @intFromPtr(byte_result.items.ptr),
    };
}

/// Token COUNT for zhl_highlight results, BYTE length for zhl_render_html results.
pub export fn zhl_result_len() usize {
    return switch (result_kind) {
        .none => 0,
        .tokens => token_result.items.len,
        .bytes => byte_result.items.len,
    };
}

pub export fn zhl_result_free() void {
    token_result.clearAndFree(allocator);
    byte_result.clearAndFree(allocator);
    result_kind = .none;
}

const Mode = enum { tokens, html };

fn run(comptime grammar: anytype, src: []const u8, comptime mode: Mode) u32 {
    const Highlighter = zhl.Engine(grammar, .{});
    comptime std.debug.assert(Highlighter.Scratch == AnyHighlighter.Scratch);
    comptime std.debug.assert(Highlighter.State == AnyHighlighter.State);

    var highlighter = Highlighter.init(.{});
    var state = Highlighter.State.initial();
    var writer = ListWriter{ .list = &byte_result };

    var line_it = std.mem.splitScalar(u8, src, '\n');
    var line_start: usize = 0;
    while (line_it.next()) |line| {
        engine_sink.reset();
        const result = highlighter.highlightLine(line, state, &engine_scratch, &engine_sink) catch |err| return errorCode(err);
        state = result.end_state;
        switch (mode) {
            .tokens => for (engine_sink.slice()) |tok| {
                var abi = zhl.wasm.toAbi(tok);
                abi.start += @intCast(line_start);
                abi.end += @intCast(line_start);
                token_result.append(allocator, abi) catch return status_out_of_memory;
            },
            .html => {
                zhl.renderers.renderHtmlLine(&writer, line, engine_sink.slice()) catch |err| return errorCode(err);
                writer.writeByte('\n') catch return status_out_of_memory;
            },
        }
        line_start += line.len + 1;
    }

    result_kind = switch (mode) {
        .tokens => .tokens,
        .html => .bytes,
    };
    return status_ok;
}

const ListWriter = struct {
    list: *std.ArrayList(u8),

    pub fn writeAll(self: *ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(allocator, bytes);
    }

    pub fn writeByte(self: *ListWriter, byte: u8) !void {
        try self.list.append(allocator, byte);
    }

    pub fn print(self: *ListWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeAll(text);
    }
};

fn errorCode(err: anyerror) u32 {
    return switch (err) {
        error.StackOverflow => 1,
        error.DynamicCaptureOverflow => 2,
        error.RegexVmStackOverflow => 3,
        error.RegexCaptureOverflow => 4,
        error.RegexStepLimitExceeded => 5,
        error.TokenOverflow => 6,
        error.LineTooLong => 7,
        error.MalformedGrammar => 8,
        error.OutOfMemory => status_out_of_memory,
        else => status_out_of_memory,
    };
}
