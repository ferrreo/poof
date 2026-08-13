pub fn isTokenByte(byte: u8) bool {
    return switch (byte) {
        '0'...'9',
        'A'...'Z',
        'a'...'z',
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
        => true,
        else => false,
    };
}

pub fn isToken(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| if (!isTokenByte(byte)) return false;
    return true;
}

pub fn isFieldValue(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != '\t' and (byte < 0x20 or byte == 0x7f)) return false;
    }
    return true;
}

pub fn eqlIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    var difference: u8 = 0;
    for (left, right) |a, b| difference |= lower(a) ^ lower(b);
    return difference == 0;
}

fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 0x20 else byte;
}
