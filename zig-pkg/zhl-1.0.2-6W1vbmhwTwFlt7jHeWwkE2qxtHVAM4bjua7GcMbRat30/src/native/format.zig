const std = @import("std");

const zhl = struct {
    const scan = @import("../runtime/scan.zig");
    const style = @import("../theme/style.zig");
    const HighlightError = @import("../runtime/engine.zig").HighlightError;
    const StyleId = style.StyleId;
};

pub fn emitDelimited(
    line: []const u8,
    start: usize,
    end: usize,
    open: []const u8,
    close: []const u8,
    escape: []const u8,
    comptime formats: bool,
    base_style: zhl.StyleId,
    sink: anytype,
    emitted: *usize,
) zhl.HighlightError!void {
    const content_end = if (end >= close.len and std.mem.eql(u8, line[end - close.len .. end], close)) end - close.len else end;
    var segment = start;
    var i = start + open.len;
    while (i < content_end) {
        if (escape.len != 0 and std.mem.startsWith(u8, line[i..], escape) and i + escape.len < content_end) {
            try emit(sink, segment, i, base_style, emitted);
            const escape_end = @min(i + escape.len + 1, content_end);
            try emit(sink, i, escape_end, .escape, emitted);
            i = escape_end;
            segment = i;
        } else if (formats) {
            if (printfPlaceholderEnd(line, i, content_end) orelse bracePlaceholderEnd(line, i, content_end)) |format_end| {
                try emit(sink, segment, i, base_style, emitted);
                try emit(sink, i, format_end, .format_placeholder, emitted);
                i = format_end;
                segment = i;
            } else {
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    try emit(sink, segment, end, base_style, emitted);
}

fn emit(sink: anytype, start: usize, end: usize, style_id: zhl.StyleId, emitted: *usize) zhl.HighlightError!void {
    if (end <= start) return;
    try sink.emit(.{
        .start = @intCast(start),
        .end = @intCast(end),
        .style_id = style_id,
        .scope_stack_id = zhl.style.scopeStackForStyle(style_id),
    });
    emitted.* += 1;
}

fn printfPlaceholderEnd(line: []const u8, start: usize, limit: usize) ?usize {
    if (line[start] != '%' or start + 1 >= limit) return null;
    var i = start + 1;
    if (line[i] == '%') return i + 1;
    while (i < limit and zhl.scan.isAnyOf(line[i], "#0- +'")) : (i += 1) {}
    if (i < limit and line[i] == '*') {
        i += 1;
    } else {
        while (i < limit and zhl.scan.isDigit(line[i])) : (i += 1) {}
    }
    if (i < limit and line[i] == '.') {
        i += 1;
        if (i < limit and line[i] == '*') {
            i += 1;
        } else {
            while (i < limit and zhl.scan.isDigit(line[i])) : (i += 1) {}
        }
    }
    while (i < limit and zhl.scan.isAnyOf(line[i], "hljztL")) : (i += 1) {}
    return if (i < limit and zhl.scan.isAnyOf(line[i], "diuoxXfFeEgGaAcspn")) i + 1 else null;
}

fn bracePlaceholderEnd(line: []const u8, start: usize, limit: usize) ?usize {
    if (line[start] != '{' or start + 1 >= limit or line[start + 1] == '{') return null;
    var i = start + 1;
    while (i < limit and line[i] != '}') : (i += 1) {}
    return if (i < limit) i + 1 else null;
}
