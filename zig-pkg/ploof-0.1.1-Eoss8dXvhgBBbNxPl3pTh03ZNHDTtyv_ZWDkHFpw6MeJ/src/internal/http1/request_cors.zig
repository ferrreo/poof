const std = @import("std");
const authority_parser = @import("authority.zig");
const fuzz_support = @import("testing/smith.zig");
const request_head = @import("request_head.zig");
const request_target = @import("request_target.zig");
const syntax = @import("syntax.zig");

pub const request_header_names_max: u8 = 64;
pub const request_header_value_bytes_max: u16 = 8 * 1024;

pub const Value = union(enum) {
    absent,
    invalid,
    value: []const u8,

    pub fn present(self: Value) bool {
        return self != .absent;
    }

    pub fn get(self: Value) ?[]const u8 {
        return switch (self) {
            .value => |value| value,
            .absent, .invalid => null,
        };
    }
};

pub const Request = struct {
    origin: Value = .absent,
    requested_method: Value = .absent,
    requested_headers: Value = .absent,
    parsed_origin: ?Origin = null,
    parsed_requested_headers: ?HeaderList = null,

    pub fn isPreflight(self: Request, method: []const u8) bool {
        return std.mem.eql(u8, method, "OPTIONS") and
            self.origin.present() and self.requested_method.present();
    }
};

pub const TupleOrigin = struct {
    raw: []const u8,
    scheme: []const u8,
    host: []const u8,
    port: ?u16,
    effective_port: ?u16,
    canonical_authority: ?authority_parser.Authority,
};

pub const Origin = union(enum) {
    opaque_null,
    tuple: TupleOrigin,
};

pub const HeaderList = struct {
    raw: []const u8,
    names_count: u8,

    pub fn iterator(self: HeaderList) HeaderIterator {
        return .{ .remaining = self.raw };
    }
};

pub const HeaderIterator = struct {
    remaining: []const u8,

    pub fn next(self: *HeaderIterator) ?[]const u8 {
        if (self.remaining.len == 0) return null;
        const comma = std.mem.indexOfScalar(u8, self.remaining, ',');
        const end = comma orelse self.remaining.len;
        const name = syntax.trimOws(self.remaining[0..end]);
        self.remaining = if (comma == null) "" else self.remaining[end + 1 ..];
        return name;
    }
};

pub fn analyze(fields: []const request_head.Field, bytes: []const u8) Request {
    var result = Request{};
    for (fields) |field| {
        insertField(&result, field.name.slice(bytes), field.value.slice(bytes));
    }
    return result;
}

pub fn analyzeHeaders(headers: anytype) Request {
    var result = Request{};
    var fields = headers.raw().iterator();
    while (fields.next()) |field| {
        insertField(&result, field.name, syntax.trimOws(field.value));
    }
    return result;
}

fn insertField(result: *Request, name: []const u8, value: []const u8) void {
    if (syntax.eqlIgnoreCase(name, "origin")) {
        insertOrigin(result, value);
    } else if (syntax.eqlIgnoreCase(name, "access-control-request-method")) {
        insert(&result.requested_method, value, methodValid);
    } else if (syntax.eqlIgnoreCase(name, "access-control-request-headers")) {
        insertHeaderList(result, value);
    }
}

fn insertOrigin(result: *Request, value: []const u8) void {
    if (result.origin != .absent) {
        result.origin = .invalid;
        result.parsed_origin = null;
        return;
    }
    const parsed = parseOrigin(value) orelse {
        result.origin = .invalid;
        return;
    };
    result.origin = .{ .value = value };
    result.parsed_origin = parsed;
}

fn insertHeaderList(result: *Request, value: []const u8) void {
    if (result.requested_headers != .absent) {
        result.requested_headers = .invalid;
        result.parsed_requested_headers = null;
        return;
    }
    const parsed = parseHeaderList(value) orelse {
        result.requested_headers = .invalid;
        return;
    };
    result.requested_headers = .{ .value = value };
    result.parsed_requested_headers = parsed;
}

fn insert(slot: *Value, value: []const u8, valid: fn ([]const u8) bool) void {
    if (slot.* != .absent) {
        slot.* = .invalid;
        return;
    }
    slot.* = if (valid(value)) .{ .value = value } else .invalid;
}

pub fn parseOrigin(value: []const u8) ?Origin {
    if (std.mem.eql(u8, value, "null")) return .opaque_null;
    const separator = std.mem.indexOf(u8, value, "://") orelse return null;
    const scheme = value[0..separator];
    if (!schemeValid(scheme)) return null;
    const authority = value[separator + 3 ..];
    if (!serializedAuthorityValid(authority)) return null;
    const split = splitAuthority(authority) orelse return null;
    const canonical_authority: ?authority_parser.Authority =
        if (authority_parser.parseScheme(scheme)) |known_scheme|
            authority_parser.parse(authority, known_scheme) catch return null
        else
            null;
    return .{ .tuple = .{
        .raw = value,
        .scheme = scheme,
        .host = split.host,
        .port = split.port,
        .effective_port = if (canonical_authority) |canonical|
            canonical.port
        else
            split.port orelse defaultPort(scheme),
        .canonical_authority = canonical_authority,
    } };
}

pub fn originValid(value: []const u8) bool {
    return parseOrigin(value) != null;
}

pub fn originEquivalent(left: []const u8, right: []const u8) bool {
    const parsed_left = parseOrigin(left) orelse return false;
    return originEquivalentParsed(parsed_left, right);
}

pub fn originEquivalentParsed(left: Origin, right: []const u8) bool {
    const parsed_right = parseOrigin(right) orelse return false;
    return originEquivalentOrigins(left, parsed_right);
}

pub fn originEquivalentOrigins(left: Origin, right: Origin) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .opaque_null => true,
        .tuple => |left_tuple| tupleEquivalent(left_tuple, right.tuple),
    };
}

fn tupleEquivalent(left: TupleOrigin, right: TupleOrigin) bool {
    if (!syntax.eqlIgnoreCase(left.scheme, right.scheme)) return false;
    if (left.canonical_authority) |left_authority| {
        const right_authority = right.canonical_authority orelse return false;
        return left_authority.eql(right_authority);
    }
    if (right.canonical_authority != null) return false;
    return syntax.eqlIgnoreCase(left.host, right.host) and
        left.effective_port == right.effective_port;
}

const Authority = struct {
    host: []const u8,
    port: ?u16,
};

fn splitAuthority(authority: []const u8) ?Authority {
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        const host = authority[0 .. close + 1];
        if (close + 1 == authority.len) return .{ .host = host, .port = null };
        if (authority[close + 1] != ':') return null;
        const port = parsePort(authority[close + 2 ..]) orelse return null;
        return .{ .host = host, .port = port };
    }
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse {
        return .{ .host = authority, .port = null };
    };
    const port = parsePort(authority[colon + 1 ..]) orelse return null;
    return .{ .host = authority[0..colon], .port = port };
}

fn serializedAuthorityValid(authority: []const u8) bool {
    if (authority.len == 0 or authority[authority.len - 1] == ':') return false;
    return request_target.validAuthoritySyntax(authority, .optional);
}

fn parsePort(bytes: []const u8) ?u16 {
    if (bytes.len == 0) return null;
    var value: u32 = 0;
    for (bytes) |byte| {
        if (byte < '0' or byte > '9') return null;
        value = value * 10 + byte - '0';
        if (value > std.math.maxInt(u16)) return null;
    }
    return @intCast(value);
}

fn defaultPort(scheme: []const u8) ?u16 {
    if (syntax.eqlIgnoreCase(scheme, "http") or syntax.eqlIgnoreCase(scheme, "ws")) {
        return 80;
    }
    if (syntax.eqlIgnoreCase(scheme, "https") or syntax.eqlIgnoreCase(scheme, "wss")) {
        return 443;
    }
    if (syntax.eqlIgnoreCase(scheme, "ftp")) return 21;
    return null;
}

fn schemeValid(scheme: []const u8) bool {
    if (scheme.len == 0 or !asciiAlpha(scheme[0])) return false;
    for (scheme[1..]) |byte| {
        if (!asciiAlpha(byte) and !asciiDigit(byte) and
            byte != '+' and byte != '-' and byte != '.') return false;
    }
    return true;
}

fn asciiAlpha(byte: u8) bool {
    return byte >= 'A' and byte <= 'Z' or byte >= 'a' and byte <= 'z';
}

fn asciiDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

pub fn methodValid(value: []const u8) bool {
    return syntax.isToken(value);
}

pub fn parseHeaderList(value: []const u8) ?HeaderList {
    if (value.len == 0 or value.len > request_header_value_bytes_max) return null;
    var remaining = value;
    var count: u8 = 0;
    while (true) {
        const comma = std.mem.indexOfScalar(u8, remaining, ',');
        const end = comma orelse remaining.len;
        const name = syntax.trimOws(remaining[0..end]);
        if (!syntax.isToken(name)) return null;
        if (count == request_header_names_max) return null;
        count += 1;
        if (comma == null) break;
        remaining = remaining[end + 1 ..];
    }
    return .{ .raw = value, .names_count = count };
}

pub fn headerListValid(value: []const u8) bool {
    return parseHeaderList(value) != null;
}

pub fn headersAllowed(value: []const u8, allowed: []const []const u8) bool {
    const list = parseHeaderList(value) orelse return false;
    return headersAllowedParsed(list, allowed);
}

pub fn headersAllowedParsed(list: HeaderList, allowed: []const []const u8) bool {
    var names = list.iterator();
    while (names.next()) |name| {
        if (!nameInSet(name, allowed)) return false;
    }
    return true;
}

pub fn nameInSet(name: []const u8, allowed: []const []const u8) bool {
    for (allowed) |candidate| {
        if (syntax.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

test "CORS field extraction records strict cardinality and syntax" {
    const wire =
        "OPTIONS /items HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Origin: https://app.example\r\n" ++
        "Access-Control-Request-Method: POST\r\n" ++
        "Access-Control-Request-Headers: X-Trace, Content-Type\r\n\r\n";
    const Decoder = request_head.Decoder(@import("limits.zig").standard_request_head_limits);
    var decoder = Decoder.init();
    const head = switch (decoder.feed(wire).state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    const result = analyze(decoder.fields(), decoder.bytes());
    try std.testing.expect(result.isPreflight(head.method.slice(decoder.bytes())));
    try std.testing.expectEqualStrings("https://app.example", result.origin.get().?);
    try std.testing.expectEqualStrings("POST", result.requested_method.get().?);
    try std.testing.expect(result.parsed_origin != null);
    try std.testing.expectEqual(@as(u8, 2), result.parsed_requested_headers.?.names_count);
    try std.testing.expectEqualStrings(
        "X-Trace, Content-Type",
        result.requested_headers.get().?,
    );
}

test "duplicate or malformed CORS fields remain present but invalid" {
    const wire =
        "OPTIONS / HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Origin: https://one.example\r\n" ++
        "Origin: https://two.example\r\n" ++
        "Access-Control-Request-Method: POST GET\r\n" ++
        "Access-Control-Request-Headers: X-One,,X-Two\r\n\r\n";
    const Decoder = request_head.Decoder(@import("limits.zig").standard_request_head_limits);
    var decoder = Decoder.init();
    const head = switch (decoder.feed(wire).state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    const result = analyze(decoder.fields(), decoder.bytes());
    try std.testing.expect(result.isPreflight(head.method.slice(decoder.bytes())));
    try std.testing.expect(result.origin == .invalid);
    try std.testing.expect(result.requested_method == .invalid);
    try std.testing.expect(result.requested_headers == .invalid);
    try std.testing.expect(result.parsed_origin == null);
    try std.testing.expect(result.parsed_requested_headers == null);
}

const FakeRawField = struct {
    name: []const u8,
    value: []const u8,
};

const FakeRequestHeaders = struct {
    fields: []const FakeRawField,

    pub fn raw(self: FakeRequestHeaders) FakeRequestHeaders {
        return self;
    }

    pub fn iterator(self: FakeRequestHeaders) Iterator {
        return .{ .fields = self.fields };
    }

    const Iterator = struct {
        fields: []const FakeRawField,
        index: usize = 0,

        pub fn next(self: *Iterator) ?FakeRawField {
            if (self.index == self.fields.len) return null;
            defer self.index += 1;
            return self.fields[self.index];
        }
    };
};

test "public header analysis applies cardinality and syntax checks" {
    const valid = analyzeHeaders(FakeRequestHeaders{ .fields = &.{
        .{ .name = "Origin", .value = " https://app.example\t" },
        .{ .name = "Access-Control-Request-Method", .value = "PATCH" },
    } });
    try std.testing.expectEqualStrings("https://app.example", valid.origin.get().?);
    try std.testing.expectEqualStrings("PATCH", valid.requested_method.get().?);
    try std.testing.expect(valid.requested_headers == .absent);

    const invalid = analyzeHeaders(FakeRequestHeaders{ .fields = &.{
        .{ .name = "Origin", .value = "https://one.example" },
        .{ .name = "origin", .value = "https://two.example" },
        .{ .name = "Access-Control-Request-Method", .value = "PATCH GET" },
        .{ .name = "Access-Control-Request-Headers", .value = "X-One,,X-Two" },
    } });
    try std.testing.expect(invalid.origin == .invalid);
    try std.testing.expect(invalid.requested_method == .invalid);
    try std.testing.expect(invalid.requested_headers == .invalid);
}

test "origins normalize case and default ports without widening null" {
    try std.testing.expect(originEquivalent(
        "HTTPS://Example.COM:443",
        "https://example.com",
    ));
    try std.testing.expect(originEquivalent(
        "http://[2001:DB8::1]:80",
        "HTTP://[2001:db8::1]",
    ));
    try std.testing.expect(originEquivalent(
        "https://[2001:db8::1]",
        "HTTPS://[2001:0db8:0:0:0:0:0:1]:443",
    ));
    try std.testing.expect(originEquivalent(
        "https://%65xample.com",
        "https://example.com:443",
    ));
    try std.testing.expect(originEquivalent("null", "null"));
    try std.testing.expect(!originEquivalent("null", "https://example.com"));
    for ([_][]const u8{
        "",
        "https://",
        "https://example.com/",
        "https://user@example.com",
        "https://example.com:",
        "1https://example.com",
        "NULL",
    }) |invalid| try std.testing.expect(!originValid(invalid));
}

test "parsed origin descriptors preserve raw equivalence" {
    const pairs = [_]struct { left: []const u8, right: []const u8 }{
        .{ .left = "HTTPS://Example.COM:443", .right = "https://example.com" },
        .{ .left = "http://[2001:DB8::1]", .right = "http://[2001:0db8::1]:80" },
        .{ .left = "https://%65xample.com", .right = "https://example.com:443" },
        .{ .left = "https://example.com", .right = "https://other.example" },
        .{ .left = "null", .right = "null" },
        .{ .left = "null", .right = "https://example.com" },
    };
    for (pairs) |pair| {
        const parsed_left = parseOrigin(pair.left).?;
        const parsed_right = parseOrigin(pair.right).?;
        try std.testing.expectEqual(
            originEquivalent(pair.left, pair.right),
            originEquivalentOrigins(parsed_left, parsed_right),
        );
    }
}

test "requested header grammar is bounded and allowlisted case insensitively" {
    const parsed = parseHeaderList(" X-Trace,content-type ").?;
    try std.testing.expectEqual(@as(u8, 2), parsed.names_count);
    try std.testing.expect(headersAllowed(
        parsed.raw,
        &.{ "Content-Type", "X-Trace" },
    ));
    try std.testing.expect(!headersAllowed(parsed.raw, &.{"X-Trace"}));
    for ([_][]const u8{ "", ",", "x,", "x,,y", "bad name" }) |invalid| {
        try std.testing.expect(!headerListValid(invalid));
    }
}

test "CORS origin and header grammar fuzz is deterministic and bounded" {
    try std.testing.fuzz({}, fuzzGrammar, .{ .corpus = &grammar_fuzz_corpus });
}

const grammar_fuzz_corpus = struct {
    const common = fuzzPair("https://app.example", "X-Trace, Content-Type");
    const null_origin = fuzzPair("null", "authorization");
    const injected = fuzzPair("https://a.example\r\nx:y", "x,,y");
    const values = [_][]const u8{ &common, &null_origin, &injected };
}.values;

fn fuzzPair(
    comptime origin: []const u8,
    comptime headers: []const u8,
) [origin.len + headers.len + 8]u8 {
    const first = fuzz_support.smithInput(origin);
    const second = fuzz_support.smithInput(headers);
    var result: [first.len + second.len]u8 = undefined;
    @memcpy(result[0..first.len], &first);
    @memcpy(result[first.len..], &second);
    return result;
}

fn fuzzGrammar(_: void, smith: *std.testing.Smith) !void {
    var origin_storage: [512]u8 = undefined;
    var header_storage: [512]u8 = undefined;
    const origin = origin_storage[0..smith.slice(&origin_storage)];
    const headers = header_storage[0..smith.slice(&header_storage)];
    const parsed_origin = parseOrigin(origin);
    const parsed_headers = parseHeaderList(headers);
    try std.testing.expectEqual(parsed_origin != null, originValid(origin));
    try std.testing.expectEqual(parsed_headers != null, headerListValid(headers));
    if (parsed_origin != null) try std.testing.expect(originEquivalent(origin, origin));
    if (parsed_headers) |list| {
        try std.testing.expect(list.names_count > 0);
        try std.testing.expect(list.names_count <= request_header_names_max);
    }
}
