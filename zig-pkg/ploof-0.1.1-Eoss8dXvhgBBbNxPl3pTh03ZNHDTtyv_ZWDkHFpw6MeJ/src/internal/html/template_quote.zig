const diagnostic = @import("template_diagnostic.zig");
const html_render = @import("../../html/render.zig");

const State = enum(u2) {
    data,
    tag,
    attribute_double,
    attribute_single,
};

const RawElement = enum(u3) {
    none,
    script,
    style,
    iframe,
    title,
    textarea,
};

const Scanner = struct {
    state: State = .data,
    raw: RawElement = .none,
    pending_raw: RawElement = .none,
    closing_raw: bool = false,
};

pub fn resolve(comptime Source: type, comptime index: usize) html_render.AttributeQuote {
    const target = Source.directives[index].source.start;
    var scanner = Scanner{};
    var cursor: usize = 0;
    var directive_index: usize = 0;
    while (cursor < target) {
        if (skipDirective(Source, &cursor, &directive_index)) continue;
        switch (scanner.state) {
            .data => scanData(Source.source, &scanner, &cursor),
            .tag => scanTag(Source.source, &scanner, &cursor),
            .attribute_double => scanAttribute(&scanner, &cursor, Source.source[cursor], '"'),
            .attribute_single => scanAttribute(&scanner, &cursor, Source.source[cursor], '\''),
        }
    }
    return switch (scanner.state) {
        .attribute_double => .double,
        .attribute_single => .single,
        else => diagnostic.fail(
            .invalid_attribute_quote,
            Source,
            target,
            "cannot recover quoted attribute delimiter",
        ),
    };
}

fn skipDirective(
    comptime Source: type,
    cursor: *usize,
    directive_index: *usize,
) bool {
    if (directive_index.* == Source.directives.len) return false;
    const directive = Source.directives[directive_index.*];
    if (cursor.* != directive.source.start) return false;
    cursor.* = directive.source.end;
    directive_index.* += 1;
    return true;
}

fn scanData(source: []const u8, scanner: *Scanner, cursor: *usize) void {
    if (scanner.raw != .none) {
        if (rawEndAt(source, cursor.*, scanner.raw)) {
            scanner.state = .tag;
            scanner.closing_raw = true;
            cursor.* += 2;
        } else {
            cursor.* += 1;
        }
        return;
    }
    if (startsWithAt(source, cursor.*, "<!--")) {
        const end = findAfter(source, cursor.* + 4, "-->");
        cursor.* = end;
        return;
    }
    if (source[cursor.*] != '<') {
        cursor.* += 1;
        return;
    }
    const tag = tagAt(source, cursor.*) orelse {
        cursor.* += 1;
        return;
    };
    scanner.state = .tag;
    scanner.closing_raw = tag.closing and scanner.raw != .none;
    scanner.pending_raw = if (tag.closing) .none else rawElement(tag.name);
    cursor.* = tag.after_name;
}

fn scanTag(source: []const u8, scanner: *Scanner, cursor: *usize) void {
    switch (source[cursor.*]) {
        '"' => scanner.state = .attribute_double,
        '\'' => scanner.state = .attribute_single,
        '>' => {
            scanner.state = .data;
            if (scanner.closing_raw) scanner.raw = .none else if (scanner.pending_raw != .none) {
                scanner.raw = scanner.pending_raw;
            }
            scanner.pending_raw = .none;
            scanner.closing_raw = false;
        },
        else => {},
    }
    cursor.* += 1;
}

fn scanAttribute(scanner: *Scanner, cursor: *usize, byte: u8, delimiter: u8) void {
    if (byte == delimiter) scanner.state = .tag;
    cursor.* += 1;
}

const Tag = struct {
    name: []const u8,
    after_name: usize,
    closing: bool,
};

fn tagAt(source: []const u8, start: usize) ?Tag {
    if (start + 1 >= source.len) return null;
    var cursor = start + 1;
    const closing = source[cursor] == '/';
    if (closing) cursor += 1;
    const name_start = cursor;
    while (cursor < source.len and tagNameByte(source[cursor])) cursor += 1;
    if (cursor == name_start) {
        if (!closing and source[start + 1] == '!') {
            return .{ .name = "", .after_name = start + 2, .closing = false };
        }
        return null;
    }
    return .{ .name = source[name_start..cursor], .after_name = cursor, .closing = closing };
}

fn rawEndAt(source: []const u8, start: usize, raw: RawElement) bool {
    if (!startsWithAt(source, start, "</")) return false;
    const name = @tagName(raw);
    if (start + 2 + name.len >= source.len) return false;
    if (!equalIgnoreCase(source[start + 2 ..][0..name.len], name)) return false;
    const next = source[start + 2 + name.len];
    return next == '>' or htmlSpace(next);
}

fn rawElement(name: []const u8) RawElement {
    inline for (.{ .script, .style, .iframe, .title, .textarea }) |candidate| {
        if (equalIgnoreCase(name, @tagName(candidate))) return candidate;
    }
    return .none;
}

fn findAfter(source: []const u8, start: usize, needle: []const u8) usize {
    var cursor = start;
    while (!startsWithAt(source, cursor, needle)) cursor += 1;
    return cursor + needle.len;
}

fn startsWithAt(source: []const u8, start: usize, needle: []const u8) bool {
    return start <= source.len and needle.len <= source.len - start and
        equal(source[start..][0..needle.len], needle);
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

fn equalIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (lower(a) != lower(b)) return false;
    return true;
}

fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn tagNameByte(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z') or
        (byte >= '0' and byte <= '9') or byte == '-';
}

fn htmlSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == '\x0c';
}
