const syntax = @import("syntax.zig");

/// Test-only scalar oracle kept independent of request admission parsing.
pub fn mediaTypeValid(value_raw: []const u8) bool {
    const value = syntax.trimOws(value_raw);
    var cursor: usize = 0;
    if (token(value, &cursor) == null) return false;
    if (!byte(value, &cursor, '/')) return false;
    if (token(value, &cursor) == null) return false;
    while (cursor < value.len) {
        skipOws(value, &cursor);
        if (!byte(value, &cursor, ';')) return false;
        skipOws(value, &cursor);
        if (cursor == value.len or value[cursor] == ';') continue;
        if (token(value, &cursor) == null) return false;
        if (!byte(value, &cursor, '=')) return false;
        if (!parameterValue(value, &cursor)) return false;
    }
    return true;
}

fn token(value: []const u8, cursor: *usize) ?[]const u8 {
    const start = cursor.*;
    while (cursor.* < value.len) : (cursor.* += 1) {
        if (!syntax.isTokenByte(value[cursor.*])) break;
    }
    if (cursor.* == start) return null;
    return value[start..cursor.*];
}

fn byte(value: []const u8, cursor: *usize, expected: u8) bool {
    if (cursor.* == value.len or value[cursor.*] != expected) return false;
    cursor.* += 1;
    return true;
}

fn parameterValue(value: []const u8, cursor: *usize) bool {
    if (cursor.* == value.len) return false;
    if (value[cursor.*] != '"') return token(value, cursor) != null;
    cursor.* += 1;
    while (cursor.* < value.len) {
        const current = value[cursor.*];
        cursor.* += 1;
        if (current == '"') return true;
        if (current == '\\') {
            if (cursor.* == value.len or !quotedPairByte(value[cursor.*])) return false;
            cursor.* += 1;
        } else if (!quotedTextByte(current)) return false;
    }
    return false;
}

fn quotedTextByte(value: u8) bool {
    return value == '\t' or value == ' ' or value == 0x21 or
        (value >= 0x23 and value <= 0x5b) or
        (value >= 0x5d and value <= 0x7e) or value >= 0x80;
}

fn quotedPairByte(value: u8) bool {
    return value == '\t' or (value >= 0x20 and value != 0x7f);
}

fn skipOws(value: []const u8, cursor: *usize) void {
    while (cursor.* < value.len and
        (value[cursor.*] == ' ' or value[cursor.*] == '\t'))
    {
        cursor.* += 1;
    }
}
