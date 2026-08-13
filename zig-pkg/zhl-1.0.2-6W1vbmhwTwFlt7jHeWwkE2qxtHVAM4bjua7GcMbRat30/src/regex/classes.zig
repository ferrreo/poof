const std = @import("std");

pub fn addPosix(mask: *[4]u64, name: []const u8) bool {
    if (asciiName(name, "alnum")) {
        addRange(mask, 'a', 'z');
        addRange(mask, 'A', 'Z');
        addRange(mask, '0', '9');
    } else if (asciiName(name, "alpha")) {
        addRange(mask, 'a', 'z');
        addRange(mask, 'A', 'Z');
    } else if (asciiName(name, "ascii")) {
        addRange(mask, 0x00, 0x7f);
    } else if (asciiName(name, "blank")) {
        addByte(mask, ' ');
        addByte(mask, '\t');
    } else if (asciiName(name, "cntrl")) {
        addRange(mask, 0x00, 0x1f);
        addByte(mask, 0x7f);
    } else if (asciiName(name, "digit")) addRange(mask, '0', '9') else if (asciiName(name, "graph")) addRange(mask, '!', '~') else if (asciiName(name, "lower")) addRange(mask, 'a', 'z') else if (asciiName(name, "print")) addRange(mask, ' ', '~') else if (asciiName(name, "punct")) {
        addRange(mask, '!', '#');
        addRange(mask, '%', '*');
        addRange(mask, ',', '/');
        addRange(mask, ':', ';');
        addByte(mask, '?');
        addByte(mask, '@');
        addRange(mask, '[', ']');
        addByte(mask, '_');
        addByte(mask, '{');
        addByte(mask, '}');
    } else if (asciiName(name, "space")) addEscape(mask, 's') else if (asciiName(name, "upper")) addRange(mask, 'A', 'Z') else if (asciiName(name, "word")) addEscape(mask, 'w') else if (asciiName(name, "xdigit")) {
        addRange(mask, '0', '9');
        addRange(mask, 'a', 'f');
        addRange(mask, 'A', 'F');
    } else return false;
    return true;
}

fn asciiName(actual: []const u8, expected: []const u8) bool {
    return actual.len == expected.len and std.ascii.eqlIgnoreCase(actual, expected);
}

fn unicodeName(actual: []const u8, expected: []const u8) bool {
    var ai: usize = 0;
    var ei: usize = 0;
    while (true) {
        while (ai < actual.len and isNameSeparator(actual[ai])) ai += 1;
        while (ei < expected.len and isNameSeparator(expected[ei])) ei += 1;
        if (ai == actual.len or ei == expected.len) return ai == actual.len and ei == expected.len;
        if (std.ascii.toLower(actual[ai]) != std.ascii.toLower(expected[ei])) return false;
        ai += 1;
        ei += 1;
    }
}

fn spaceName(name: []const u8) bool {
    return unicodeName(name, "Space") or unicodeName(name, "White_Space") or unicodeName(name, "Whitespace");
}

fn isNameSeparator(byte: u8) bool {
    return byte == '_' or byte == '-' or byte == ' ';
}

fn generalCategoryValue(name: []const u8) ?[]const u8 {
    const split = std.mem.indexOfScalar(u8, name, '=') orelse return null;
    const key = name[0..split];
    if (!unicodeName(key, "gc") and !unicodeName(key, "General_Category")) return null;
    return name[split + 1 ..];
}

pub fn isShortUnicodeProperty(byte: u8) bool {
    return std.mem.indexOfScalar(u8, "CLMNPSZ", byte) != null;
}

pub fn addUnicodePropertyToken(mask: *[4]u64, body: []const u8, negated: bool) ?usize {
    if (body.len == 0) return null;
    if (isShortUnicodeProperty(body[0])) {
        const ok = if (negated) addInverseUnicodeProperty(mask, body[0..1]) else addUnicodeProperty(mask, body[0..1]);
        return if (ok) 1 else null;
    }
    if (body[0] != '{') return null;
    const close = std.mem.indexOfScalar(u8, body[1..], '}') orelse return null;
    const name = body[1 .. close + 1];
    const ok = if (negated) addInverseUnicodeProperty(mask, name) else addUnicodeProperty(mask, name);
    return if (ok) close + 2 else null;
}

pub fn addUnicodePropertyTokenAsciiSpace(mask: *[4]u64, body: []const u8, negated: bool) ?usize {
    if (body.len != 0 and body[0] == '{') {
        const close = std.mem.indexOfScalar(u8, body[1..], '}') orelse return null;
        var name = body[1 .. close + 1];
        var inverse = negated;
        if (name.len != 0 and name[0] == '^') {
            inverse = !inverse;
            name = name[1..];
        }
        if (spaceName(name)) {
            if (inverse) addInverseAsciiSpace(mask) else addAsciiSpace(mask);
            return close + 2;
        }
    }
    return addUnicodePropertyToken(mask, body, negated);
}

pub fn addUnicodeProperty(mask: *[4]u64, name: []const u8) bool {
    if (name.len > 0 and name[0] == '^') return addInverseUnicodeProperty(mask, name[1..]);
    if (generalCategoryValue(name)) |value| {
        if (unicodeName(value, "LC") or unicodeName(value, "Cased_Letter")) return false;
        return addUnicodeProperty(mask, value);
    }
    if (addPosix(mask, name)) return true;
    if (asciiName(name, "Any") or asciiName(name, "Assigned")) {
        addRange(mask, 0x00, std.math.maxInt(u8));
        return true;
    }
    if (name.len == 1) switch (name[0]) {
        'L' => {
            addRange(mask, 'a', 'z');
            addRange(mask, 'A', 'Z');
            return true;
        },
        'N' => {
            addRange(mask, '0', '9');
            return true;
        },
        'P' => return addPosix(mask, "punct"),
        'S' => {
            addAsciiSymbols(mask);
            return true;
        },
        'Z' => {
            addByte(mask, ' ');
            return true;
        },
        'C' => return addPosix(mask, "cntrl"),
        'M' => return true,
        else => {},
    };
    if (unicodeName(name, "L") or unicodeName(name, "Letter") or unicodeName(name, "Alphabetic")) {
        addRange(mask, 'a', 'z');
        addRange(mask, 'A', 'Z');
    } else if (unicodeName(name, "LC") or unicodeName(name, "Cased_Letter")) {
        addRange(mask, 'a', 'z');
        addRange(mask, 'A', 'Z');
    } else if (unicodeName(name, "Ll") or unicodeName(name, "Lower") or unicodeName(name, "Lowercase") or unicodeName(name, "Lowercase_Letter")) {
        addRange(mask, 'a', 'z');
    } else if (unicodeName(name, "Lu") or unicodeName(name, "Upper") or unicodeName(name, "Uppercase") or unicodeName(name, "Uppercase_Letter") or unicodeName(name, "Lt") or unicodeName(name, "Titlecase_Letter")) {
        addRange(mask, 'A', 'Z');
    } else if (unicodeName(name, "Lm") or unicodeName(name, "Modifier_Letter") or unicodeName(name, "Lo") or unicodeName(name, "Other_Letter")) {
        addRange(mask, 'a', 'z');
        addRange(mask, 'A', 'Z');
    } else if (unicodeName(name, "N") or unicodeName(name, "Number") or unicodeName(name, "Nd") or unicodeName(name, "Decimal_Number")) {
        addRange(mask, '0', '9');
    } else if (unicodeName(name, "P") or unicodeName(name, "Punctuation")) {
        return addPosix(mask, "punct");
    } else if (unicodeName(name, "Sc") or unicodeName(name, "Currency_Symbol")) {
        addByte(mask, '$');
    } else if (unicodeName(name, "Sm") or unicodeName(name, "Math_Symbol")) {
        addAsciiMathSymbols(mask);
    } else if (unicodeName(name, "Sk") or unicodeName(name, "Modifier_Symbol") or unicodeName(name, "So") or unicodeName(name, "Other_Symbol")) {} else if (unicodeName(name, "S") or unicodeName(name, "Symbol")) {
        addAsciiSymbols(mask);
    } else if (spaceName(name)) {
        addAsciiSpace(mask);
    } else if (unicodeName(name, "Newline")) {
        addByte(mask, '\n');
    } else if (unicodeName(name, "Z") or unicodeName(name, "Separator")) {
        addByte(mask, ' ');
    } else if (unicodeName(name, "C") or unicodeName(name, "Other")) {
        return addPosix(mask, "cntrl");
    } else if (unicodeName(name, "M") or unicodeName(name, "Mark") or unicodeName(name, "Me") or unicodeName(name, "Enclosing_Mark")) {} else if (unicodeName(name, "Cc") or unicodeName(name, "Control")) {
        return addPosix(mask, "cntrl");
    } else if (unicodeName(name, "Zs") or unicodeName(name, "Space_Separator")) {
        addByte(mask, ' ');
    } else if (unicodeName(name, "Word")) {
        addEscape(mask, 'w');
    } else if (unicodeName(name, "Nl") or unicodeName(name, "No") or unicodeName(name, "Other_Number") or unicodeName(name, "Mn") or unicodeName(name, "Mc")) {} else if (unicodeName(name, "Pc") or unicodeName(name, "Connector_Punctuation")) {
        addByte(mask, '_');
    } else return false;
    return true;
}

pub fn addInverseUnicodeProperty(mask: *[4]u64, name: []const u8) bool {
    if (name.len > 0 and name[0] == '^') return addUnicodeProperty(mask, name[1..]);
    var inverse = [_]u64{0} ** 4;
    if (!addUnicodeProperty(&inverse, name)) return false;
    for (mask, inverse) |*word, inverted| word.* |= ~inverted;
    return true;
}

pub fn addInversePosix(mask: *[4]u64, name: []const u8) bool {
    var inverse = [_]u64{0} ** 4;
    if (!addPosix(&inverse, name)) return false;
    for (mask, inverse) |*word, inverted| word.* |= ~inverted;
    return true;
}

pub fn addPosixClass(mask: *[4]u64, name: []const u8) bool {
    return if (name.len > 0 and name[0] == '^') addInversePosix(mask, name[1..]) else addPosix(mask, name);
}

pub fn addEscape(mask: *[4]u64, byte: u8) void {
    switch (byte) {
        'd' => addRange(mask, '0', '9'),
        'h' => {
            addRange(mask, '0', '9');
            addRange(mask, 'a', 'f');
            addRange(mask, 'A', 'F');
        },
        'w' => {
            addRange(mask, 'a', 'z');
            addRange(mask, 'A', 'Z');
            addRange(mask, '0', '9');
            addByte(mask, '_');
        },
        's' => {
            addByte(mask, ' ');
            addByte(mask, '\t');
            addByte(mask, 0x0b);
            addByte(mask, 0x0c);
            addByte(mask, '\r');
            addByte(mask, '\n');
            addByte(mask, 0x85);
        },
        else => unreachable,
    }
}

pub fn addAsciiSpace(mask: *[4]u64) void {
    addByte(mask, ' ');
    addByte(mask, '\t');
    addByte(mask, 0x0b);
    addByte(mask, 0x0c);
    addByte(mask, '\r');
    addByte(mask, '\n');
}

pub fn addInverseAsciiSpace(mask: *[4]u64) void {
    var inverse = [_]u64{0} ** 4;
    addAsciiSpace(&inverse);
    for (mask, inverse) |*word, inverted| word.* |= ~inverted;
}

fn addAsciiSymbols(mask: *[4]u64) void {
    for ("$+<=>^`|~") |byte| addByte(mask, byte);
}

fn addAsciiMathSymbols(mask: *[4]u64) void {
    for ("+<=>|~") |byte| addByte(mask, byte);
}

pub fn addInverseEscape(mask: *[4]u64, byte: u8) void {
    var inverse = [_]u64{0} ** 4;
    addEscape(&inverse, byte + 32);
    for (mask, inverse) |*word, inverted| word.* |= ~inverted;
}

pub fn clearHighBytes(mask: *[4]u64) void {
    var byte: u16 = 0x80;
    while (byte <= 0xff) : (byte += 1) {
        const word: usize = @intCast(byte >> 6);
        const shift: u6 = @intCast(byte & 63);
        mask[word] &= ~(@as(u64, 1) << shift);
    }
}

pub fn addRange(mask: *[4]u64, lo: u8, hi: u8) void {
    var byte = lo;
    while (true) : (byte += 1) {
        addByte(mask, byte);
        if (byte == hi) break;
    }
}

pub fn addByte(mask: *[4]u64, byte: u8) void {
    const word: usize = @intCast(byte >> 6);
    const shift: u6 = @intCast(byte & 63);
    mask[word] |= @as(u64, 1) << shift;
}

pub fn contains(mask: [4]u64, byte: u8) bool {
    const word: usize = @intCast(byte >> 6);
    const shift: u6 = @intCast(byte & 63);
    return (mask[word] & (@as(u64, 1) << shift)) != 0;
}

test "Unicode category aliases used by broad TextMate classes" {
    var mask = [_]u64{0} ** 4;
    try std.testing.expect(addUnicodeProperty(&mask, "Sc"));
    try std.testing.expect(contains(mask, '$'));
    try std.testing.expect(addUnicodeProperty(&mask, "Currency_Symbol"));
    try std.testing.expect(addUnicodeProperty(&mask, "Sk"));
    try std.testing.expect(addUnicodeProperty(&mask, "Modifier_Symbol"));
    try std.testing.expect(addUnicodeProperty(&mask, "Me"));
    try std.testing.expect(addUnicodeProperty(&mask, "Enclosing_Mark"));
    try std.testing.expect(addUnicodeProperty(&mask, "No"));
    try std.testing.expect(addUnicodeProperty(&mask, "Other_Number"));
    try std.testing.expect(addUnicodeProperty(&mask, "White_Space"));
    try std.testing.expect(addUnicodeProperty(&mask, "Whitespace"));
    try std.testing.expect(contains(mask, '\n'));
    try std.testing.expect(contains(mask, ' '));
    var cased = [_]u64{0} ** 4;
    try std.testing.expect(addUnicodeProperty(&cased, "LC"));
    try std.testing.expect(addUnicodeProperty(&cased, "Cased_Letter"));
    try std.testing.expect(contains(cased, 'A'));
    try std.testing.expect(contains(cased, 'a'));
    try std.testing.expect(!addUnicodeProperty(&cased, "gc=LC"));
    var newline = [_]u64{0} ** 4;
    try std.testing.expect(addUnicodeProperty(&newline, "Newline"));
    try std.testing.expect(contains(newline, '\n'));
    try std.testing.expect(!contains(newline, '\r'));
}
