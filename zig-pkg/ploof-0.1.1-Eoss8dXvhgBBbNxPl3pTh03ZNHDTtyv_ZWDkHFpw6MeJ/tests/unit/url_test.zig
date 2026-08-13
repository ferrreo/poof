const std = @import("std");
const request_target = @import("../../src/internal/http1/request_target.zig");
const url = @import("../../src/url.zig");
const trusted = @import("../../src/trusted_resource_url.zig");

const any_web = url.WebPolicy{
    .https = .any,
    .http = .any,
};

test "local URLs accept complete strict same-origin references without rewriting" {
    const valid = [_][]const u8{
        "/",
        "/users/42",
        "/a//b/",
        "/a:!$&'()*+,;=@~_-.",
        "/caf%C3%A9",
        "/a%2Fb?x=%00/?:@#fragment/?",
        "?",
        "?q=a/b?c",
        "#",
        "#a/b?c",
    };
    for (valid) |input| {
        const parsed = try url.Url.local(input);
        try std.testing.expectEqual(url.Url.Kind.local, parsed.kind());
        try std.testing.expectEqualSlices(u8, input, parsed.bytes());
        const checked = try parsed.validatedCopy();
        try std.testing.expectEqualSlices(u8, input, checked.bytes());
    }
}

test "local URLs reject authorities schemes browser repair and malformed escapes" {
    const cases = [_]struct {
        input: []const u8,
        problem: url.ValidationError,
    }{
        .{ .input = "", .problem = error.Empty },
        .{ .input = "users", .problem = error.InvalidLocalReference },
        .{ .input = "//example.com/a", .problem = error.InvalidLocalReference },
        .{ .input = "https://example.com", .problem = error.InvalidLocalReference },
        .{ .input = "/a b", .problem = error.ForbiddenByte },
        .{ .input = "/a\\b", .problem = error.ForbiddenByte },
        .{ .input = "/a%5cb", .problem = error.EncodedBackslash },
        .{ .input = "/a%5Cb", .problem = error.EncodedBackslash },
        .{ .input = "/a%", .problem = error.MalformedPercentEscape },
        .{ .input = "/a%0", .problem = error.MalformedPercentEscape },
        .{ .input = "/a%0g", .problem = error.MalformedPercentEscape },
        .{ .input = "/a[0]", .problem = error.ForbiddenByte },
        .{ .input = "/a#b#c", .problem = error.ForbiddenByte },
        .{ .input = "/\x80", .problem = error.NonAscii },
    };
    for (cases) |case| {
        try std.testing.expectError(case.problem, url.Url.local(case.input));
    }
}

test "local URL ASCII and percent classifications are exhaustive" {
    var raw = [_]u8{ '/', 0 };
    var byte: u16 = 0;
    while (byte < 128) : (byte += 1) {
        raw[1] = @intCast(byte);
        const expected = expectedLocalByte(raw[1]);
        if (expected) |problem| {
            try std.testing.expectError(problem, url.Url.local(&raw));
        } else {
            _ = try url.Url.local(&raw);
        }
    }

    var escaped = [_]u8{ '/', '%', '0', '0' };
    byte = 0;
    while (byte < 256) : (byte += 1) {
        escaped[2] = upper_hex[byte >> 4];
        escaped[3] = upper_hex[byte & 0x0f];
        if (byte == '\\') {
            try std.testing.expectError(error.EncodedBackslash, url.Url.local(&escaped));
        } else {
            _ = try url.Url.local(&escaped);
        }
    }
}

test "web URLs validate exact schemes authorities hosts ports and tails" {
    const valid = [_][]const u8{
        "https://example.com",
        "https://EXAMPLE.com/a?b=c#d",
        "https://xn--bcher-kva.example/",
        "https://127.0.0.1:65535/a",
        "https://[2001:db8::1]/a",
        "https://[::ffff:192.0.2.1]:0",
        "http://localhost/path",
    };
    for (valid) |input| {
        const parsed = try url.Url.web(input, any_web);
        try std.testing.expectEqualSlices(u8, input, parsed.bytes());
        _ = try parsed.validatedCopy();
    }
}

test "web URLs reject repair-dependent and ambiguous authorities" {
    const invalid = [_][]const u8{
        "",
        "HTTPS://example.com",
        "https:example.com",
        "https:///path",
        "https://",
        "https://user@example.com",
        "https://user:pass@example.com",
        "https://example.com.",
        "https://exa_mple.com",
        "https://-example.com",
        "https://example-.com",
        "https://127.1",
        "https://2130706433",
        "https://0177.0.0.1",
        "https://0x7f.0.0.1",
        "https://256.0.0.1",
        "https://[127.0.0.1]",
        "https://[2001:db8::1",
        "https://[2001:db8::1]x",
        "https://[2001:db8::1%25eth0]",
        "https://example.com:",
        "https://example.com:01",
        "https://example.com:65536",
        "https://example.com:-1",
        "https://example.com/a b",
        "https://example.com/a\\b",
        "https://example.com/a%5Cb",
        "https://example.com/a%zz",
        "https://example.com/[x]",
        "javascript:alert(1)",
        "//example.com/path",
    };
    for (invalid) |input| {
        try expectAnyError(url.Url.web(input, any_web));
    }
}

test "web URLs accept bounded Punycode and reject malformed A-label payloads" {
    const valid = [_][]const u8{
        "https://xn--bcher-kva.example/",
        "https://XN--MAANA-PTA.example/",
        "https://xn--fiqs8s.example/",
    };
    for (valid) |input| _ = try url.Url.web(input, any_web);

    const invalid = [_][]const u8{
        "https://xn--a.example/",
        "https://xn--0.example/",
        "https://xn--abc-.example/",
        "https://xn---abc.example/",
        "https://xn--zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz.example/",
    };
    for (invalid) |input| try expectAnyError(url.Url.web(input, any_web));
}

test "web policies compare DNS and IP hosts semantically and gate HTTP separately" {
    const policy = url.WebPolicy{
        .https = .{ .allowlist = &.{
            "example.com",
            "127.0.0.1",
            "[2001:db8::1]",
        } },
        .http = .{ .allowlist = &.{"localhost"} },
    };
    _ = try url.Url.web("https://EXAMPLE.COM/a", policy);
    _ = try url.Url.web("https://127.0.0.1:8443/a", policy);
    _ = try url.Url.web("https://[2001:0db8:0:0:0:0:0:1]/a", policy);
    _ = try url.Url.web("http://LOCALHOST/a", policy);
    try std.testing.expectError(
        error.HostNotAllowed,
        url.Url.web("https://other.example/a", policy),
    );
    try std.testing.expectError(
        error.HostNotAllowed,
        url.Url.web("http://example.com/a", policy),
    );
    try std.testing.expectError(
        error.HostNotAllowed,
        url.Url.web("http://localhost/a", url.WebPolicy.anyHttps()),
    );
}

test "local builder owns path query and fragment delimiters" {
    var storage: [256]u8 = undefined;
    var builder = try url.LocalBuilder.init(&storage);
    try builder.segment("users");
    try builder.segment("caf\xc3\xa9 ?");
    try builder.query("next&", "/a b?c=d");
    try builder.query("emoji", "\xf0\x9f\xa6\x86");
    try builder.fragment("part#two");
    const result = try builder.finish();
    try std.testing.expectEqualStrings(
        "/users/caf%C3%A9%20%3F?next%26=%2Fa%20b%3Fc%3Dd&emoji=%F0%9F%A6%86#part%23two",
        result.bytes(),
    );
}

test "path builders reject decoded separators and browser dot segments" {
    const values = [_][]const u8{ "/", "a/b", ".", ".." };
    inline for (values) |value| {
        var local_storage: [32]u8 = undefined;
        var local = try url.LocalBuilder.init(&local_storage);
        try local.segment("safe");
        try std.testing.expectError(error.InvalidComponent, local.segment(value));
        try std.testing.expectEqualStrings("/safe", (try local.finish()).bytes());

        var web_storage: [64]u8 = undefined;
        var web = try url.WebBuilder.init(
            &web_storage,
            .{ .host = "example.com" },
            url.WebPolicy.anyHttps(),
        );
        try web.segment("safe");
        try std.testing.expectError(error.InvalidComponent, web.segment(value));
        try std.testing.expectEqualStrings(
            "https://example.com/safe",
            (try web.finish()).bytes(),
        );
    }
}

test "path builder output preserves one routing segment after request decoding" {
    var storage: [32]u8 = undefined;
    var builder = try url.LocalBuilder.init(&storage);
    try builder.segment("%2F");
    const built = try builder.finish();
    try std.testing.expectEqualStrings("/%252F", built.bytes());

    var decoded_storage: [32]u8 = undefined;
    const parsed = request_target.parse("GET", built.bytes(), &decoded_storage);
    const target = switch (parsed) {
        .ready => |target| target,
        .rejected => return error.TestUnexpectedResult,
    };
    const decoded = switch (target) {
        .origin => |origin| origin.decoded_path,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("/%2F", decoded);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, decoded, "/"));
}

test "builders reject invalid ordering backslashes and capacity without partial writes" {
    var storage: [14]u8 = undefined;
    var builder = try url.LocalBuilder.init(&storage);
    try builder.segment("ok");
    try std.testing.expectError(error.InvalidComponent, builder.query("x", "\\"));
    try std.testing.expectEqualStrings("/ok", (try builder.finish()).bytes());
    try std.testing.expectError(error.NoSpace, builder.query("large", "value"));
    try std.testing.expectEqualStrings("/ok", (try builder.finish()).bytes());
    try builder.fragment("");
    try std.testing.expectError(error.InvalidOrder, builder.segment("late"));
    try std.testing.expectError(error.InvalidOrder, builder.query("late", "value"));
    try std.testing.expectEqualStrings("/ok#", (try builder.finish()).bytes());
}

test "web builder validates origin policy and canonicalizes component escapes" {
    const policy = url.WebPolicy{
        .https = .{ .allowlist = &.{"example.com"} },
        .http = .deny,
    };
    var storage: [128]u8 = undefined;
    var builder = try url.WebBuilder.init(&storage, .{
        .host = "EXAMPLE.com",
        .port = 443,
    }, policy);
    try builder.segment("a b");
    try builder.query("q", "a&b");
    try std.testing.expectEqualStrings(
        "https://EXAMPLE.com/a%20b?q=a%26b",
        (try builder.finish()).bytes(),
    );

    var port_builder = try url.WebBuilder.init(&storage, .{
        .host = "example.com",
        .port = 8443,
    }, policy);
    try std.testing.expectEqualStrings(
        "https://example.com:8443",
        (try port_builder.finish()).bytes(),
    );
    try std.testing.expectError(
        error.HostNotAllowed,
        url.WebBuilder.init(&storage, .{ .host = "other.example" }, policy),
    );
}

test "contact builders encode data without exposing scheme or query structure" {
    var storage: [256]u8 = undefined;
    const mail = try url.Url.mailto("caf\xc3\xa9+tag@example.com", &storage);
    try std.testing.expectEqualStrings("mailto:caf%C3%A9%2Btag@example.com", mail.bytes());
    try std.testing.expectEqual(url.Url.Kind.mailto, mail.kind());
    _ = try mail.validatedCopy();

    const phone = try url.Url.tel("+44 20;ext=7?body=x", &storage);
    try std.testing.expectEqualStrings(
        "tel:%2B44%2020%3Bext%3D7%3Fbody%3Dx",
        phone.bytes(),
    );
    try std.testing.expectEqual(url.Url.Kind.tel, phone.kind());
    _ = try phone.validatedCopy();

    try std.testing.expectError(error.InvalidMailbox, url.Url.mailto("missing", &storage));
    try std.testing.expectError(error.InvalidMailbox, url.Url.mailto("a@@example.com", &storage));
    try std.testing.expectError(error.InvalidMailbox, url.Url.mailto("a@bad_host", &storage));
    try std.testing.expectError(error.EmptyComponent, url.Url.tel("", &storage));
    try std.testing.expectError(error.InvalidUtf8, url.Url.tel("\xff", &storage));
}

test "public URL values are revalidated before a renderer trusts their bytes" {
    var forged = try url.Url.local("/safe");
    forged.bytes_value = "javascript:alert(1)";
    try std.testing.expectError(error.InvalidLocalReference, forged.validatedCopy());

    forged = try url.Url.web("https://example.com", url.WebPolicy.anyHttps());
    forged.kind_value = .http;
    try std.testing.expectError(error.UnsupportedScheme, forged.validatedCopy());

    var storage: [16]u8 = undefined;
    forged = try url.Url.tel("123", &storage);
    forged.bytes_value = "tel:1?body=evil";
    try std.testing.expectError(error.ForbiddenByte, forged.validatedCopy());
}

test "URL limits include exact boundaries" {
    _ = try url.Url.localWith("/", .{ .bytes_max = 1 });
    try std.testing.expectError(error.TooLong, url.Url.localWith("/a", .{ .bytes_max = 1 }));
}

test "trusted resource literals accept only root-relative or HTTPS application input" {
    const local = trusted.TrustedResourceUrl.literal("/assets/app.js?v=1");
    try std.testing.expectEqual(trusted.TrustedResourceUrl.Kind.local, local.kind());
    try std.testing.expectEqualStrings("/assets/app.js?v=1", local.bytes());
    try local.validate();

    const external = trusted.TrustedResourceUrl.literal("https://cdn.example/app.js");
    try std.testing.expectEqual(trusted.TrustedResourceUrl.Kind.https, external.kind());
    try std.testing.expectEqualStrings("https://cdn.example/app.js", external.bytes());
    try external.validate();
}

test "startup trusted resources copy bounded configuration and require allowed origins" {
    const Resource = enum { script, stylesheet };
    const Table = trusted.ResourceTable(
        Resource,
        &.{ "https://cdn.example", "https://[2001:db8::1]:8443" },
        128,
    );
    const configuration: Table.Configuration = .{
        "https://CDN.EXAMPLE:443/app.js",
        "https://[2001:0db8:0:0:0:0:0:1]:8443/app.css",
    };
    var table: Table = undefined;
    try std.testing.expect(table.init(&configuration) == null);
    const script = try table.get(.script);
    const stylesheet = try table.get(.stylesheet);
    try std.testing.expectEqualStrings(configuration[0], script.bytes());
    try std.testing.expectEqualStrings(configuration[1], stylesheet.bytes());
    try std.testing.expectEqual(
        trusted.TrustedResourceUrl.Provenance.startup_table,
        script.provenance(),
    );

    table.clear();
    try std.testing.expect(!table.initialized);
    try std.testing.expect(allZero(std.mem.asBytes(&table.storage)));
    try std.testing.expect(allZero(std.mem.asBytes(&table.lengths)));
}

test "trusted resource tables remain move-safe and read-only after startup" {
    const Resource = enum { script, stylesheet };
    const Table = trusted.ResourceTable(Resource, &.{"https://cdn.example"}, 64);
    const configuration: Table.Configuration = .{
        "https://cdn.example/app.js",
        "https://cdn.example/app.css",
    };
    var initialized: Table = undefined;
    try std.testing.expect(initialized.init(&configuration) == null);
    var moved = initialized;
    initialized.clear();

    const before = moved;
    const immutable: *const Table = &moved;
    const script = try immutable.get(.script);
    const stylesheet = try immutable.get(.stylesheet);
    try std.testing.expectEqualStrings(configuration[0], script.bytes());
    try std.testing.expectEqualStrings(configuration[1], stylesheet.bytes());
    try std.testing.expectEqualDeep(before, moved);
}

test "builders reject direct-zero and forged public state without slicing or trapping" {
    var zero_local = std.mem.zeroes(url.LocalBuilder);
    try std.testing.expectError(error.Empty, zero_local.finish());

    var local_storage: [16]u8 = undefined;
    var local = try url.LocalBuilder.init(&local_storage);
    try local.segment("safe");
    local.components.buffer.length = local_storage.len + 1;
    try std.testing.expectError(error.NoSpace, local.finish());
    local.components.buffer.length = url.url_bytes_hard_max + 1;
    try std.testing.expectError(error.TooLong, local.finish());

    local = try url.LocalBuilder.init(&local_storage);
    local_storage[0] = 'x';
    try std.testing.expectError(error.InvalidLocalReference, local.finish());

    var zero_web = std.mem.zeroes(url.WebBuilder);
    try std.testing.expectError(error.Empty, zero_web.finish());
}

test "trusted resource access rejects direct-zero and forged table state" {
    const Resource = enum { script };
    const Table = trusted.ResourceTable(Resource, &.{"https://cdn.example"}, 48);
    const configuration: Table.Configuration = .{"https://cdn.example/a.js"};

    var table = std.mem.zeroes(Table);
    try std.testing.expectError(error.NotInitialized, table.get(.script));

    table.initialized = true;
    try std.testing.expectError(error.CorruptState, table.get(.script));

    try std.testing.expect(table.init(&configuration) == null);
    table.lengths[0] = 63;
    try std.testing.expectError(error.CorruptState, table.get(.script));

    try std.testing.expect(table.init(&configuration) == null);
    table.storage[0][0] = 'x';
    try std.testing.expectError(error.CorruptState, table.get(.script));

    try std.testing.expect(table.init(&configuration) == null);
    table.values[0].seal ^= 1;
    try std.testing.expectError(error.CorruptState, table.get(.script));

    try std.testing.expect(table.init(&configuration) == null);
    table.values[0].bytes_value.relative.?.offset += 1;
    try std.testing.expectError(error.CorruptState, table.get(.script));
}

test "trusted resource access rejects cross-origin mutation before and after issuance" {
    const Resource = enum { script };
    const Table = trusted.ResourceTable(Resource, &.{"https://cdn.example"}, 48);
    const configuration: Table.Configuration = .{"https://cdn.example/a.js"};
    const forged = "https://bad.example/a.js";
    comptime std.debug.assert(configuration[0].len == forged.len);

    var table: Table = undefined;
    try std.testing.expect(table.init(&configuration) == null);
    @memcpy(table.storage[0][0..forged.len], forged);
    try std.testing.expectError(error.CorruptState, table.get(.script));

    try std.testing.expect(table.init(&configuration) == null);
    const resource = try table.get(.script);
    @memcpy(table.storage[0][0..forged.len], forged);
    try std.testing.expectError(error.CorruptState, resource.validate());
}

test "trusted resource capabilities bind exact startup URL bytes" {
    const Resource = enum { script };
    const Table = trusted.ResourceTable(Resource, &.{"https://cdn.example"}, 48);
    const configured = "https://cdn.example/a.js";
    const replacement = "https://cdn.example/x.js";
    comptime std.debug.assert(configured.len == replacement.len);
    const configuration: Table.Configuration = .{configured};

    var table: Table = undefined;
    try std.testing.expect(table.init(&configuration) == null);
    @memcpy(table.storage[0][0..replacement.len], replacement);
    try std.testing.expectError(error.CorruptState, table.get(.script));

    try std.testing.expect(table.init(&configuration) == null);
    const resource = try table.get(.script);
    try std.testing.expectEqualStrings(configured, try resource.validatedBytes());
    @memcpy(table.storage[0][0..replacement.len], replacement);
    try std.testing.expectError(error.CorruptState, resource.validatedBytes());
    try std.testing.expectError(error.CorruptState, resource.validate());
    try std.testing.expectEqualStrings("", resource.bytes());
}

test "issued trusted resources authenticate metadata before pointer formation" {
    const Resource = enum { script };
    const Table = trusted.ResourceTable(Resource, &.{"https://cdn.example"}, 48);
    const configuration: Table.Configuration = .{"https://cdn.example/a.js"};
    const Corruption = enum {
        offset_min,
        offset_max,
        offset_positive_bound,
        offset_negative_bound,
        length_zero,
        length_above_capacity,
        capacity_zero,
        metadata_seal,
        content_seal,
    };

    inline for (std.enums.values(Corruption)) |corruption| {
        var table: Table = undefined;
        try std.testing.expect(table.init(&configuration) == null);
        const resource = try table.get(.script);
        switch (corruption) {
            .offset_min => table.values[0].bytes_value.relative.?.offset = std.math.minInt(i32),
            .offset_max => table.values[0].bytes_value.relative.?.offset = std.math.maxInt(i32),
            .offset_positive_bound => {
                table.values[0].bytes_value.relative.?.offset = 32 * 1024 * 1024;
            },
            .offset_negative_bound => {
                table.values[0].bytes_value.relative.?.offset = -(32 * 1024 * 1024);
            },
            .length_zero => table.values[0].bytes_value.relative.?.length = 0,
            .length_above_capacity => {
                table.values[0].bytes_value.relative.?.length = 49;
            },
            .capacity_zero => table.values[0].bytes_value.relative.?.capacity = 0,
            .metadata_seal => table.values[0].seal ^= 1,
            .content_seal => table.values[0].content_seal ^= 1,
        }
        try std.testing.expectError(error.CorruptState, resource.validatedBytes());
        try std.testing.expectEqualStrings("", resource.bytes());
    }
}

test "startup trusted resource failures identify key reason and clear partial state" {
    const Resource = enum { first, second };
    const Table = trusted.ResourceTable(Resource, &.{"https://cdn.example"}, 48);
    var table: Table = undefined;

    const wrong_origin: Table.Configuration = .{
        "https://cdn.example/ok.js",
        "https://evil.example/no.js",
    };
    const origin_failure = table.init(&wrong_origin).?;
    try std.testing.expectEqual(Resource.second, origin_failure.resource);
    try std.testing.expectEqualStrings("second", origin_failure.name());
    try std.testing.expect(origin_failure.issue == .origin_not_allowed);
    try expectCleared(&table);

    const invalid: Table.Configuration = .{
        "https://cdn.example/ok.js",
        "http://cdn.example/no.js",
    };
    const invalid_failure = table.init(&invalid).?;
    try std.testing.expectEqual(Resource.second, invalid_failure.resource);
    try std.testing.expect(invalid_failure.issue == .invalid_url);
    try std.testing.expectEqual(
        error.UnsupportedScheme,
        invalid_failure.issue.invalid_url,
    );
    try expectCleared(&table);

    const too_long: Table.Configuration = .{
        "https://cdn.example/ok.js",
        "https://cdn.example/" ++ "a" ** 40,
    };
    const length_failure = table.init(&too_long).?;
    try std.testing.expect(length_failure.issue == .too_long);
    try expectCleared(&table);
}

fn expectedLocalByte(byte: u8) ?url.ValidationError {
    if (byte == '%') return error.MalformedPercentEscape;
    if (byte == '/') return error.InvalidLocalReference;
    if (std.ascii.isAlphanumeric(byte)) return null;
    return switch (byte) {
        '-',
        '.',
        '_',
        '~',
        '!',
        '$',
        '&',
        '\'',
        '(',
        ')',
        '*',
        '+',
        ',',
        ';',
        '=',
        ':',
        '@',
        '?',
        '#',
        => null,
        else => error.ForbiddenByte,
    };
}

fn allZero(input: []const u8) bool {
    for (input) |byte| if (byte != 0) return false;
    return true;
}

fn expectCleared(table: anytype) !void {
    try std.testing.expect(!table.initialized);
    try std.testing.expect(allZero(std.mem.asBytes(&table.storage)));
    try std.testing.expect(allZero(std.mem.asBytes(&table.lengths)));
}

fn expectAnyError(result: anytype) !void {
    if (result) |_| return error.TestExpectedError else |_| {}
}

const upper_hex = "0123456789ABCDEF";
