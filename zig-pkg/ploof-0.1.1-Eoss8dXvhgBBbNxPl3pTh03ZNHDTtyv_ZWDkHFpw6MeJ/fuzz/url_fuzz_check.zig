const std = @import("std");
const url = @import("../src/url.zig");
const trusted = @import("../src/trusted_resource_url.zig");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");

const input_bytes_max = 4096;
const encoded_bytes_max = input_bytes_max * 3 + 32;
const any_web = url.WebPolicy{
    .https = .any,
    .http = .any,
};

test "URL parsing and trust tables have deterministic bounded outcomes" {
    try std.testing.fuzz({}, fuzzUrl, .{ .corpus = &corpus });
}

const corpus = struct {
    const empty = fuzz_support.smithInput("");
    const local = fuzz_support.smithInput("/users/caf%C3%A9?q=a%20b#part");
    const authority = fuzz_support.smithInput("//evil.example/path");
    const https = fuzz_support.smithInput("https://EXAMPLE.com:443/a?b=c#d");
    const credentials = fuzz_support.smithInput("https://user:pass@example.com/");
    const legacy_ip = fuzz_support.smithInput("https://0177.0.0.1/");
    const ipv6 = fuzz_support.smithInput("https://[2001:db8::1]/");
    const encoded_slash = fuzz_support.smithInput("/a%2Fb%5Cc");
    const malformed = fuzz_support.smithInput("/%0g\x00\xff");
    const unicode = fuzz_support.smithInput("caf\xc3\xa9/\xf0\x9f\xa6\x86");
    const punycode = fuzz_support.smithInput("https://xn--bcher-kva.example/");
    const malformed_punycode = fuzz_support.smithInput("https://xn--zzzzzzzzzzzz.example/");
    const values = [_][]const u8{
        &empty,
        &local,
        &authority,
        &https,
        &credentials,
        &legacy_ip,
        &ipv6,
        &encoded_slash,
        &malformed,
        &unicode,
        &punycode,
        &malformed_punycode,
    };
}.values;

fn fuzzUrl(_: void, smith: *std.testing.Smith) !void {
    var storage: [input_bytes_max]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];
    var original: [input_bytes_max]u8 = undefined;
    @memcpy(original[0..input.len], input);

    try checkLocal(input);
    try checkWeb(input);
    try checkBuilder(input);
    try checkContacts(input);
    try checkResourceTable(input);
    try std.testing.expectEqualSlices(u8, original[0..input.len], input);
}

fn checkLocal(input: []const u8) !void {
    var first_error: ?url.ValidationError = null;
    var second_error: ?url.ValidationError = null;
    const first: ?url.Url = url.Url.local(input) catch |problem| failed: {
        first_error = problem;
        break :failed null;
    };
    const second: ?url.Url = url.Url.local(input) catch |problem| failed: {
        second_error = problem;
        break :failed null;
    };
    try std.testing.expectEqual(first_error, second_error);
    if (first) |parsed| {
        const repeated = second orelse return error.FuzzOutcomeMismatch;
        try std.testing.expectEqualSlices(u8, input, parsed.bytes());
        try std.testing.expectEqualSlices(u8, parsed.bytes(), repeated.bytes());
        try checkLocalSuccess(parsed);
    } else try std.testing.expect(second == null);
}

fn checkLocalSuccess(parsed: url.Url) !void {
    const bytes = parsed.bytes();
    try std.testing.expect(bytes.len > 0);
    try std.testing.expect(bytes[0] == '/' or bytes[0] == '?' or bytes[0] == '#');
    if (bytes[0] == '/') try std.testing.expect(bytes.len == 1 or bytes[1] != '/');
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '\\') == null);
    _ = try parsed.validatedCopy();
}

fn checkWeb(input: []const u8) !void {
    var first_error: ?url.WebError = null;
    var second_error: ?url.WebError = null;
    const first: ?url.Url = url.Url.web(input, any_web) catch |problem| failed: {
        first_error = problem;
        break :failed null;
    };
    const second: ?url.Url = url.Url.web(input, any_web) catch |problem| failed: {
        second_error = problem;
        break :failed null;
    };
    try std.testing.expectEqual(first_error, second_error);
    if (first) |parsed| {
        const repeated = second orelse return error.FuzzOutcomeMismatch;
        try std.testing.expectEqualSlices(u8, input, parsed.bytes());
        try std.testing.expectEqualSlices(u8, parsed.bytes(), repeated.bytes());
        try checkWebSuccess(parsed);
    } else try std.testing.expect(second == null);
}

fn checkWebSuccess(parsed: url.Url) !void {
    const bytes = parsed.bytes();
    const prefix: []const u8 = switch (parsed.kind()) {
        .http => "http://",
        .https => "https://",
        else => return error.FuzzOutcomeMismatch,
    };
    try std.testing.expect(std.mem.startsWith(u8, bytes, prefix));
    const authority_end = authorityEnd(bytes, prefix.len);
    try std.testing.expect(authority_end > prefix.len);
    try std.testing.expect(
        std.mem.indexOfScalar(u8, bytes[prefix.len..authority_end], '@') == null,
    );
    _ = try parsed.validatedCopy();
}

fn checkBuilder(input: []const u8) !void {
    var output: [encoded_bytes_max]u8 = undefined;
    var builder = try url.LocalBuilder.init(&output);
    const result = builder.segment(input);
    const valid = input.len > 0 and std.unicode.utf8ValidateSlice(input) and
        std.mem.indexOfScalar(u8, input, '\\') == null and
        std.mem.indexOfScalar(u8, input, '/') == null and
        !std.mem.eql(u8, input, ".") and !std.mem.eql(u8, input, "..");
    if (!valid) {
        try expectAnyError(result);
        try std.testing.expectEqualStrings("/", (try builder.finish()).bytes());
        return;
    }
    try result;
    const built = try builder.finish();
    _ = try built.validatedCopy();
    var decoded: [input_bytes_max]u8 = undefined;
    const decoded_length = try decodeComponent(built.bytes()[1..], &decoded);
    try std.testing.expectEqualSlices(u8, input, decoded[0..decoded_length]);
}

fn checkContacts(input: []const u8) !void {
    var output: [encoded_bytes_max]u8 = undefined;
    const result = url.Url.tel(input, &output);
    if (input.len == 0 or !std.unicode.utf8ValidateSlice(input)) {
        try expectAnyError(result);
        return;
    }
    const built = try result;
    _ = try built.validatedCopy();
    var decoded: [input_bytes_max]u8 = undefined;
    const decoded_length = try decodeComponent(built.bytes()["tel:".len..], &decoded);
    try std.testing.expectEqualSlices(u8, input, decoded[0..decoded_length]);
}

fn checkResourceTable(input: []const u8) !void {
    const Resource = enum { script };
    const Table = trusted.ResourceTable(Resource, &.{"https://cdn.example"}, 128);
    const configuration: Table.Configuration = .{input};
    var first: Table = undefined;
    var second: Table = undefined;
    const first_failure = first.init(&configuration);
    const second_failure = second.init(&configuration);
    try expectSameFailure(first_failure, second_failure);
    if (first_failure == null) {
        const resource = try first.get(.script);
        try resource.validate();
        try std.testing.expectEqualSlices(u8, input, resource.bytes());
        const changed = input.len / 2;
        first.storage[0][changed] ^= 1;
        try std.testing.expectError(error.CorruptState, first.get(.script));
        try std.testing.expectError(error.CorruptState, resource.validatedBytes());
    } else {
        try std.testing.expect(!first.initialized);
        try std.testing.expect(allZero(std.mem.asBytes(&first.storage)));
        try std.testing.expect(allZero(std.mem.asBytes(&first.lengths)));
    }
}

fn expectSameFailure(first: anytype, second: @TypeOf(first)) !void {
    try std.testing.expectEqual(first == null, second == null);
    if (first) |left| {
        const right = second orelse return error.FuzzOutcomeMismatch;
        try std.testing.expectEqual(left.resource, right.resource);
        try std.testing.expectEqual(
            std.meta.activeTag(left.issue),
            std.meta.activeTag(right.issue),
        );
        if (left.issue == .invalid_url) {
            try std.testing.expectEqual(left.issue.invalid_url, right.issue.invalid_url);
        }
    }
}

fn decodeComponent(input: []const u8, output: []u8) !u32 {
    var read: u32 = 0;
    var written: u32 = 0;
    while (read < input.len) : (read += 1) {
        if (input[read] == '%') {
            if (read + 2 >= input.len) return error.InvalidEncoding;
            const high = hexValue(input[read + 1]) orelse return error.InvalidEncoding;
            const low = hexValue(input[read + 2]) orelse return error.InvalidEncoding;
            output[written] = (high << 4) | low;
            read += 2;
        } else {
            output[written] = input[read];
        }
        written += 1;
    }
    return written;
}

fn authorityEnd(input: []const u8, start: usize) usize {
    var index = start;
    while (index < input.len) : (index += 1) {
        switch (input[index]) {
            '/', '?', '#' => return index,
            else => {},
        }
    }
    return input.len;
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn allZero(input: []const u8) bool {
    for (input) |byte| if (byte != 0) return false;
    return true;
}

fn expectAnyError(result: anytype) !void {
    if (result) |_| return error.TestExpectedError else |_| {}
}
