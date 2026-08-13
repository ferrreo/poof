const std = @import("std");
const syntax = @import("../http1/syntax.zig");

pub const synchronizer_bytes: usize = 32;
pub const synchronizer_encoded_bytes: usize = 43;
pub const signed_bytes: usize = 66;
pub const signed_encoded_bytes: usize = 88;
pub const token_encoded_bytes_max: usize = 128;

pub const BodySource = enum(u2) {
    none,
    form,
    multipart,
};

pub const TokenSource = enum(u2) {
    none,
    header,
    form,
    multipart,
};

pub const Status = enum(u2) {
    pending,
    accepted,
    rejected,
    safe,
};

pub const Rejection = enum(u1) {
    forbidden,
    misdirected_request,
};

pub const Expected = union(enum) {
    none,
    synchronizer: [synchronizer_bytes]u8,
    signed: []const u8,
};

pub const State = struct {
    expected: Expected = .none,
    body_source: BodySource = .none,
    token_source: TokenSource = .none,
    status: Status = .pending,
    rejection: Rejection = .forbidden,
    token_exposed: bool = false,

    pub fn reset(state: *State, body_source: BodySource) void {
        state.* = .{ .body_source = body_source };
    }

    pub fn beginSafe(state: *State) void {
        state.expected = .none;
        state.token_source = .none;
        state.status = .safe;
    }

    pub fn beginSynchronizer(state: *State, expected: *const [synchronizer_bytes]u8) void {
        state.expected = .{ .synchronizer = expected.* };
        state.token_source = .none;
        state.status = .pending;
    }

    pub fn beginSigned(state: *State, expected: []const u8) bool {
        var decoded: [signed_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &decoded);
        if (!decodeSigned(expected, &decoded)) {
            state.reject();
            return false;
        }
        state.expected = .{ .signed = expected };
        state.token_source = .none;
        state.status = .pending;
        return true;
    }

    pub fn observe(state: *State, source: TokenSource, encoded: []const u8) bool {
        std.debug.assert(source != .none);
        if (state.status == .safe) return true;
        if (state.status == .rejected or state.token_source != .none) {
            state.reject();
            return false;
        }
        state.token_source = source;
        const valid = switch (state.expected) {
            .none => false,
            .synchronizer => |*expected| verifySynchronizer(expected, encoded),
            .signed => |expected| verifySignedEncoding(expected, encoded),
        };
        state.status = if (valid) .accepted else .rejected;
        return valid;
    }

    pub fn canDeferToBody(state: *const State) bool {
        return state.status == .pending and state.body_source != .none;
    }

    pub fn completeBody(state: *State) bool {
        if (state.status == .safe or state.status == .accepted) return true;
        state.reject();
        return false;
    }

    pub fn beforeFile(state: *State) bool {
        if (state.status == .safe or state.status == .accepted) return true;
        state.reject();
        return false;
    }

    pub fn exposeToken(state: *State) void {
        state.token_exposed = true;
    }

    pub fn reject(state: *State) void {
        state.status = .rejected;
        state.rejection = .forbidden;
    }

    pub fn rejectMisdirected(state: *State) void {
        state.status = .rejected;
        state.rejection = .misdirected_request;
    }

    pub fn clear(state: *State) void {
        std.crypto.secureZero(u8, std.mem.asBytes(state));
    }
};

pub fn encodeSynchronizer(raw: *const [synchronizer_bytes]u8) [synchronizer_encoded_bytes]u8 {
    var encoded: [synchronizer_encoded_bytes]u8 = undefined;
    const result = std.base64.url_safe_no_pad.Encoder.encode(&encoded, raw);
    std.debug.assert(result.len == encoded.len);
    return encoded;
}

pub fn decodeSynchronizer(
    encoded: []const u8,
    raw: *[synchronizer_bytes]u8,
) bool {
    return decodeCanonical(synchronizer_encoded_bytes, synchronizer_bytes, encoded, raw);
}

pub fn encodeSigned(raw: *const [signed_bytes]u8) [signed_encoded_bytes]u8 {
    var encoded: [signed_encoded_bytes]u8 = undefined;
    const result = std.base64.url_safe_no_pad.Encoder.encode(&encoded, raw);
    std.debug.assert(result.len == encoded.len);
    return encoded;
}

pub fn decodeSigned(encoded: []const u8, raw: *[signed_bytes]u8) bool {
    return decodeCanonical(signed_encoded_bytes, signed_bytes, encoded, raw);
}

pub fn verifySynchronizer(
    expected: *const [synchronizer_bytes]u8,
    submitted: []const u8,
) bool {
    var decoded: [synchronizer_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &decoded);
    if (!decodeSynchronizer(submitted, &decoded)) return false;
    return std.crypto.timing_safe.eql([synchronizer_bytes]u8, expected.*, decoded);
}

pub fn verifySignedEncoding(expected: []const u8, submitted: []const u8) bool {
    var decoded: [signed_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &decoded);
    if (!decodeSigned(submitted, &decoded)) return false;
    return timingSafeSliceEql(signed_encoded_bytes, expected, submitted);
}

pub const CookieResult = union(enum) {
    absent,
    invalid,
    duplicate,
    value: []const u8,
};

pub const CookieScanner = struct {
    name: []const u8,
    selected: ?[]const u8 = null,
    invalid: bool = false,
    duplicate: bool = false,

    pub fn init(name: []const u8) CookieScanner {
        std.debug.assert(cookieNameValid(name));
        return .{ .name = name };
    }

    pub fn feed(scanner: *CookieScanner, header: []const u8) void {
        if (scanner.invalid or header.len == 0) {
            scanner.invalid = true;
            return;
        }
        var remaining = header;
        while (true) {
            const semicolon = std.mem.indexOfScalar(u8, remaining, ';');
            const end = semicolon orelse remaining.len;
            const pair = syntax.trimOws(remaining[0..end]);
            if (!scanner.feedPair(pair)) return;
            if (semicolon == null) return;
            remaining = remaining[end + 1 ..];
            if (remaining.len == 0) {
                scanner.invalid = true;
                return;
            }
        }
    }

    pub fn finish(scanner: *const CookieScanner) CookieResult {
        if (scanner.invalid) return .invalid;
        if (scanner.duplicate) return .duplicate;
        return if (scanner.selected) |value| .{ .value = value } else .absent;
    }

    fn feedPair(scanner: *CookieScanner, pair: []const u8) bool {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse {
            scanner.invalid = true;
            return false;
        };
        const name = pair[0..equals];
        const value = pair[equals + 1 ..];
        if (!cookieNameValid(name) or !cookieValueValid(value)) {
            scanner.invalid = true;
            return false;
        }
        if (!std.mem.eql(u8, name, scanner.name)) return true;
        if (value.len >= 2 and value[0] == '"') {
            scanner.invalid = true;
            return false;
        }
        if (scanner.selected != null) scanner.duplicate = true else scanner.selected = value;
        return true;
    }
};

pub const SameSite = enum(u2) {
    strict,
    lax,
    none,
};

pub const CookieOptions = struct {
    path: []const u8 = "/",
    secure: bool = true,
    http_only: bool = true,
    same_site: SameSite = .lax,
};

pub const CookieWriteError = error{
    InvalidCookieOptions,
    NoSpaceLeft,
};

pub fn writeCookie(
    name: []const u8,
    value: []const u8,
    options: CookieOptions,
    output: []u8,
) CookieWriteError![]const u8 {
    if (!cookieNameValid(name) or !cookieValueValid(value) or !pathValid(options.path)) {
        return error.InvalidCookieOptions;
    }
    if (options.same_site == .none and !options.secure) return error.InvalidCookieOptions;
    if (startsWithIgnoreCase(name, "__Host-") and
        (!options.secure or !std.mem.eql(u8, options.path, "/")))
    {
        return error.InvalidCookieOptions;
    }
    if (startsWithIgnoreCase(name, "__Secure-") and !options.secure) {
        return error.InvalidCookieOptions;
    }

    var used: usize = 0;
    try append(output, &used, name);
    try append(output, &used, "=");
    try append(output, &used, value);
    try append(output, &used, "; Path=");
    try append(output, &used, options.path);
    if (options.secure) try append(output, &used, "; Secure");
    if (options.http_only) try append(output, &used, "; HttpOnly");
    try append(output, &used, "; SameSite=");
    try append(output, &used, switch (options.same_site) {
        .strict => "Strict",
        .lax => "Lax",
        .none => "None",
    });
    return output[0..used];
}

pub fn writeHiddenInput(
    name: []const u8,
    token: []const u8,
    output: []u8,
) error{ InvalidFieldName, NoSpaceLeft }![]const u8 {
    if (!syntax.isToken(name)) return error.InvalidFieldName;
    var used: usize = 0;
    try append(output, &used, "<input type=\"hidden\" name=\"");
    try appendHtmlAttribute(output, &used, name);
    try append(output, &used, "\" value=\"");
    try appendHtmlAttribute(output, &used, token);
    try append(output, &used, "\">");
    return output[0..used];
}

fn appendHtmlAttribute(output: []u8, used: *usize, value: []const u8) error{NoSpaceLeft}!void {
    var start: usize = 0;
    for (value, 0..) |byte, index| {
        const escaped = switch (byte) {
            '&' => "&amp;",
            '"' => "&quot;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => continue,
        };
        try append(output, used, value[start..index]);
        try append(output, used, escaped);
        start = index + 1;
    }
    try append(output, used, value[start..]);
}

pub fn cookieNameValid(name: []const u8) bool {
    return syntax.isToken(name);
}

fn decodeCanonical(
    comptime encoded_bytes: usize,
    comptime raw_bytes: usize,
    encoded: []const u8,
    raw: *[raw_bytes]u8,
) bool {
    if (encoded.len != encoded_bytes) return false;
    std.base64.url_safe_no_pad.Decoder.decode(raw, encoded) catch return false;
    var canonical: [encoded_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &canonical);
    const result = std.base64.url_safe_no_pad.Encoder.encode(&canonical, raw);
    std.debug.assert(result.len == encoded_bytes);
    return std.crypto.timing_safe.eql([encoded_bytes]u8, canonical, encoded[0..encoded_bytes].*);
}

fn timingSafeSliceEql(comptime bytes: usize, left: []const u8, right: []const u8) bool {
    if (left.len != bytes or right.len != bytes) return false;
    return std.crypto.timing_safe.eql([bytes]u8, left[0..bytes].*, right[0..bytes].*);
}

fn cookieValueValid(value: []const u8) bool {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        for (value[1 .. value.len - 1]) |byte| if (!cookieOctet(byte)) return false;
        return true;
    }
    for (value) |byte| if (!cookieOctet(byte)) return false;
    return true;
}

fn cookieOctet(byte: u8) bool {
    return byte == 0x21 or
        byte >= 0x23 and byte <= 0x2b or
        byte >= 0x2d and byte <= 0x3a or
        byte >= 0x3c and byte <= 0x5b or
        byte >= 0x5d and byte <= 0x7e;
}

fn pathValid(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    for (path) |byte| if (byte < 0x20 or byte > 0x7e or byte == ';') return false;
    return true;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn append(output: []u8, used: *usize, value: []const u8) error{NoSpaceLeft}!void {
    if (value.len > output.len -| used.*) return error.NoSpaceLeft;
    @memcpy(output[used.*..][0..value.len], value);
    used.* += value.len;
}

test {
    std.testing.refAllDecls(@This());
}
