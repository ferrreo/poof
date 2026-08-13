const syntax = @import("wire_syntax.zig");
const types = @import("types.zig");

const Value = struct {
    bytes: []u8,
    quoted: bool,
};

pub fn parse(raw_value: []u8) types.Error!types.MediaType {
    const value = trimOws(raw_value);
    var cursor: usize = 0;
    const media_type = consumeToken(value, &cursor) orelse return error.Malformed;
    if (!consumeByte(value, &cursor, '/')) return error.Malformed;
    const subtype = consumeToken(value, &cursor) orelse return error.Malformed;
    var charset: ?types.Charset = null;
    while (cursor < value.len) {
        skipOws(value, &cursor);
        if (!consumeByte(value, &cursor, ';')) return error.Malformed;
        skipOws(value, &cursor);
        const name = consumeToken(value, &cursor) orelse return error.Malformed;
        if (!consumeByte(value, &cursor, '=')) return error.Malformed;
        const parameter = try consumeValue(value, &cursor);
        if (syntax.eqlIgnoreCase(name, "charset")) {
            if (charset != null) return error.Malformed;
            charset = .{ .bytes = parameter.bytes, .quoted = parameter.quoted };
        }
        skipOws(value, &cursor);
    }
    return .{
        .raw = value,
        .type = media_type,
        .subtype = subtype,
        .charset = charset,
    };
}

pub fn validateText(content_type: ?types.MediaType) types.MediaError!void {
    const media = content_type orelse return;
    if (!syntax.eqlIgnoreCase(media.type, "text") or
        !syntax.eqlIgnoreCase(media.subtype, "plain"))
    {
        return error.UnsupportedMedia;
    }
    if (media.charset) |charset| {
        if (!valueEqlIgnoreCase(charset, "utf-8")) return error.UnsupportedMedia;
    }
}

pub fn claimedMediaAccepted(
    content_type: ?types.MediaType,
    comptime claims: []const types.MediaClaim,
    missing: types.MissingMedia,
) bool {
    const media = content_type orelse return missing == .allow;
    inline for (claims) |claim| {
        if (syntax.eqlIgnoreCase(media.type, claim.type) and
            syntax.eqlIgnoreCase(media.subtype, claim.subtype)) return true;
    }
    return false;
}

pub fn isMultipart(content_type: ?types.MediaType) bool {
    const media = content_type orelse return false;
    return syntax.eqlIgnoreCase(media.type, "multipart");
}

fn valueEqlIgnoreCase(value: types.Charset, expected: []const u8) bool {
    var source: usize = 0;
    var target: usize = 0;
    var difference: u8 = 0;
    while (source < value.bytes.len) {
        if (value.quoted and value.bytes[source] == '\\') source += 1;
        if (source == value.bytes.len or target == expected.len) return false;
        difference |= lower(value.bytes[source]) ^ lower(expected[target]);
        source += 1;
        target += 1;
    }
    return target == expected.len and difference == 0;
}

fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 0x20 else byte;
}

fn consumeValue(value: []u8, cursor: *usize) types.Error!Value {
    if (cursor.* == value.len) return error.Malformed;
    if (value[cursor.*] != '"') {
        const token = consumeToken(value, cursor) orelse return error.Malformed;
        return .{ .bytes = token, .quoted = false };
    }
    cursor.* += 1;
    const start = cursor.*;
    while (cursor.* < value.len) {
        const byte = value[cursor.*];
        cursor.* += 1;
        if (byte == '"') {
            return .{ .bytes = value[start .. cursor.* - 1], .quoted = true };
        }
        if (byte == '\\') {
            if (cursor.* == value.len or !validQuotedPair(value[cursor.*])) {
                return error.Malformed;
            }
            cursor.* += 1;
        } else if (!validQuotedText(byte)) return error.Malformed;
    }
    return error.Malformed;
}

fn consumeToken(value: []u8, cursor: *usize) ?[]u8 {
    const start = cursor.*;
    while (cursor.* < value.len and syntax.isTokenByte(value[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* == start) return null;
    return value[start..cursor.*];
}

fn consumeByte(value: []const u8, cursor: *usize, expected: u8) bool {
    if (cursor.* == value.len or value[cursor.*] != expected) return false;
    cursor.* += 1;
    return true;
}

fn skipOws(value: []const u8, cursor: *usize) void {
    while (cursor.* < value.len) : (cursor.* += 1) {
        if (value[cursor.*] != ' ' and value[cursor.*] != '\t') break;
    }
}

fn trimOws(value: []u8) []u8 {
    var start: usize = 0;
    while (start < value.len and (value[start] == ' ' or value[start] == '\t')) start += 1;
    var end = value.len;
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t')) end -= 1;
    return value[start..end];
}

fn validQuotedText(byte: u8) bool {
    return byte == ' ' or byte == '!' or
        (byte >= '#' and byte <= '[') or (byte >= ']' and byte <= '~') or byte >= 0x80;
}

fn validQuotedPair(byte: u8) bool {
    return byte >= 0x20 and byte != 0x7f;
}
