const std = @import("std");
const application_routes = @import("../src/internal/application/routes.zig");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const route = @import("../src/route.zig");
const url_for = @import("../src/url_for.zig");

const input_bytes_max = 1024;
const output_bytes_max = input_bytes_max * 3 + 32;

fn handler() void {}

const path_descriptor = route.get("/path/:value", handler);
const path_routes = .{route.group("/:tenant", .{}, .{path_descriptor})};
const path_target = application_routes.target(path_routes, path_descriptor);

test "urlFor path and query encoding has deterministic bounded outcomes" {
    try std.testing.fuzz({}, fuzzUrlFor, .{ .corpus = &corpus });
}

const corpus = struct {
    const empty = fuzz_support.smithInput("");
    const ascii = fuzz_support.smithInput("users and files");
    const unicode = fuzz_support.smithInput("caf\xc3\xa9-\xf0\x9f\xa6\x86");
    const separators = fuzz_support.smithInput("a/b?c=d&e=f#part");
    const dots = fuzz_support.smithInput("..");
    const backslash = fuzz_support.smithInput("a\\b");
    const invalid_utf8 = fuzz_support.smithInput("\xff\xc0\x80");
    const controls = fuzz_support.smithInput("\x00\x1f\x7f");
    const values = [_][]const u8{
        &empty,
        &ascii,
        &unicode,
        &separators,
        &dots,
        &backslash,
        &invalid_utf8,
        &controls,
    };
}.values;

fn fuzzUrlFor(_: void, smith: *std.testing.Smith) !void {
    var storage: [input_bytes_max]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];
    var original: [input_bytes_max]u8 = undefined;
    @memcpy(original[0..input.len], input);

    try checkPath(input);
    try checkQuery(input);
    try std.testing.expectEqualSlices(u8, original[0..input.len], input);
}

fn checkPath(input: []const u8) !void {
    var first_output: [output_bytes_max]u8 = undefined;
    var second_output: [output_bytes_max]u8 = undefined;
    const parameters = .{ .tenant = "mounted", .value = input };
    const first = url_for.urlFor(path_target, parameters, .{}, &first_output);
    const second = url_for.urlFor(path_target, parameters, .{}, &second_output);
    const valid = validPathInput(input);
    if (!valid) {
        try expectAnyError(first);
        try expectAnyError(second);
        return;
    }
    const built = try first;
    const repeated = try second;
    try std.testing.expectEqualStrings(built.bytes(), repeated.bytes());
    _ = try built.validatedCopy();

    var decoded: [input_bytes_max]u8 = undefined;
    const encoded = built.bytes()["/mounted/path/".len..];
    const length = try decodeComponent(encoded, &decoded);
    try std.testing.expectEqualSlices(u8, input, decoded[0..length]);
}

fn checkQuery(input: []const u8) !void {
    const Query = struct { value: []const u8 };
    const descriptor = route.get("/query", handler);
    var output: [output_bytes_max]u8 = undefined;
    const result = url_for.urlFor(descriptor, .{}, Query{ .value = input }, &output);
    const valid = std.unicode.utf8ValidateSlice(input) and
        std.mem.indexOfScalar(u8, input, '\\') == null;
    if (!valid) return expectAnyError(result);

    const built = try result;
    _ = try built.validatedCopy();
    const prefix = "/query?value=";
    try std.testing.expect(std.mem.startsWith(u8, built.bytes(), prefix));
    var decoded: [input_bytes_max]u8 = undefined;
    const length = try decodeComponent(built.bytes()[prefix.len..], &decoded);
    try std.testing.expectEqualSlices(u8, input, decoded[0..length]);
}

fn validPathInput(input: []const u8) bool {
    return input.len > 0 and std.unicode.utf8ValidateSlice(input) and
        std.mem.indexOfAny(u8, input, "/\\") == null and
        !std.mem.eql(u8, input, ".") and !std.mem.eql(u8, input, "..");
}

fn decodeComponent(input: []const u8, output: []u8) !usize {
    var read: usize = 0;
    var written: usize = 0;
    while (read < input.len) : (read += 1) {
        if (input[read] == '%') {
            if (read + 2 >= input.len) return error.InvalidEncoding;
            const high = hexValue(input[read + 1]) orelse return error.InvalidEncoding;
            const low = hexValue(input[read + 2]) orelse return error.InvalidEncoding;
            output[written] = (high << 4) | low;
            read += 2;
        } else output[written] = input[read];
        written += 1;
    }
    return written;
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn expectAnyError(result: anytype) !void {
    if (result) |_| return error.TestExpectedError else |_| {}
}
