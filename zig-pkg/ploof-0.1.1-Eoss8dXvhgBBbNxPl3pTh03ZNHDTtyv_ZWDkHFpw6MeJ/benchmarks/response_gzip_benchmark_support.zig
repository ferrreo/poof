const std = @import("std");
const gzip_encoder = @import("../src/internal/runtime/gzip/encoder.zig");

pub const Media = enum {
    html,
    json,
};

pub const Entropy = enum {
    compressible,
    realistic,
    seeded_incompressible,
    utf8_incompressible,
};

pub fn Fixture(comptime bytes: usize) type {
    return [bytes]u8;
}

pub fn fixture(
    comptime media: Media,
    comptime entropy: Entropy,
    comptime bytes: usize,
) Fixture(bytes) {
    @setEvalBranchQuota(5_000_000);
    const framing = switch (entropy) {
        .realistic => realisticFraming(media),
        else => basicFraming(media),
    };
    if (bytes < framing.prefix.len + framing.suffix.len) {
        @compileError("response-gzip benchmark fixture is too small");
    }

    var result: Fixture(bytes) = undefined;
    @memcpy(result[0..framing.prefix.len], framing.prefix);
    @memcpy(result[result.len - framing.suffix.len ..], framing.suffix);
    const middle = result[framing.prefix.len .. result.len - framing.suffix.len];
    switch (entropy) {
        .compressible => fillCompressible(media, middle),
        .realistic => fillRealistic(media, middle, bytes),
        .seeded_incompressible => fillSeededAscii(media, middle, bytes),
        .utf8_incompressible => fillSeededUtf8(media, middle, bytes),
    }
    if (!std.unicode.utf8ValidateSlice(&result)) {
        @compileError("response-gzip benchmark fixture must be valid UTF-8");
    }
    return result;
}

const Framing = struct {
    prefix: []const u8,
    suffix: []const u8,
};

fn basicFraming(comptime media: Media) Framing {
    return switch (media) {
        .html => .{ .prefix = "<main>", .suffix = "</main>" },
        .json => .{ .prefix = "{\"data\":\"", .suffix = "\"}" },
    };
}

fn realisticFraming(comptime media: Media) Framing {
    return switch (media) {
        .html => .{
            .prefix = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
                "<title>Recent activity</title><link rel=\"stylesheet\" href=\"/app.css\">" ++
                "</head><body><main><article><h1>Recent activity</h1><p>",
            .suffix = "</p></article></main><script src=\"/app.js\"></script></body></html>",
        },
        .json => .{
            .prefix = "{\"request_id\":\"req_01J2Y8Z6F4\",\"items\":[{" ++
                "\"id\":1042,\"summary\":\"",
            .suffix = "\",\"active\":true,\"tags\":[\"zig\",\"http\"]}],\"next\":null}",
        },
    };
}

fn fillCompressible(comptime media: Media, output: []u8) void {
    const pattern = switch (media) {
        .html => "ploof serves this fast response with predictable repeated text. ",
        .json => "ploof-fast-response-0123456789-",
    };
    for (output, 0..) |*byte, index| byte.* = pattern[index % pattern.len];
}

fn fillRealistic(
    comptime media: Media,
    output: []u8,
    comptime bytes: usize,
) void {
    const prose = switch (media) {
        .html => "User updated project settings and published a new release. ",
        .json => "User updated project settings and published release 2026-07-14. ",
    };
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_";
    var state = seed(media, bytes) ^ 0xa409_3822_299f_31d0;
    for (output, 0..) |*byte, index| {
        if (index % 96 < 58) {
            byte.* = prose[index % prose.len];
        } else {
            state = next(state);
            byte.* = alphabet[(state >> 32) % alphabet.len];
        }
    }
}

fn fillSeededAscii(
    comptime media: Media,
    output: []u8,
    comptime bytes: usize,
) void {
    var state = seed(media, bytes);
    for (output) |*byte| {
        state = next(state);
        var selected: u8 = @intCast(0x20 + state % 95);
        if (media == .json and (selected == '"' or selected == '\\')) selected = '~';
        if (media == .html and
            (selected == '<' or selected == '>' or selected == '&')) selected = '~';
        byte.* = selected;
    }
}

fn fillSeededUtf8(
    comptime media: Media,
    output: []u8,
    comptime bytes: usize,
) void {
    var state = seed(media, bytes) ^ 0x082e_fa98_ec4e_6c89;
    var index: usize = 0;
    while (index < output.len) {
        const remaining = output.len - index;
        if (remaining == 1) {
            output[index] = 'x';
            break;
        }
        state = next(state);
        const width: u3 = if (remaining == 2)
            2
        else
            @intCast(2 + state % @min(@as(usize, 3), remaining - 1));
        const codepoint: u21 = switch (width) {
            2 => @intCast(0x80 + state % (0x800 - 0x80)),
            3 => @intCast(0x800 + state % (0xd800 - 0x800)),
            4 => @intCast(0x10000 + state % (0x110000 - 0x10000)),
            else => unreachable,
        };
        const written = std.unicode.utf8Encode(codepoint, output[index..]) catch unreachable;
        if (written != width) unreachable;
        index += written;
    }
}

fn seed(comptime media: Media, comptime bytes: usize) u64 {
    return 0x9e37_79b9_7f4a_7c15 ^ bytes ^ switch (media) {
        .html => 0x243f_6a88_85a3_08d3,
        .json => 0x1319_8a2e_0370_7344,
    };
}

fn next(state: u64) u64 {
    return state *% 6_364_136_223_846_793_005 +% 1_442_695_040_888_963_407;
}

pub const Metric = struct {
    id: []const u8,
    input_bytes: usize,
    candidate_gzip_bytes: usize,
    content_length: usize,
    wire_body_bytes: usize,
    coding_outcome: []const u8,
};

pub fn writeMetrics(
    init: std.process.Init,
    output_root: []const u8,
    metrics: []const Metric,
) !void {
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try std.fmt.bufPrint(
        &directory_storage,
        "{s}/response-gzip-finite",
        .{output_root},
    );
    try std.Io.Dir.cwd().createDirPath(init.io, directory);

    var json_storage: [64 * 1024]u8 = undefined;
    var json = std.Io.Writer.fixed(&json_storage);
    try json.writeAll("{\n  \"format\": 1,\n  \"entries\": [\n");
    for (metrics, 0..) |metric, index| {
        if (index != 0) try json.writeAll(",\n");
        try json.print(
            "    {{\"id\":\"{s}\",\"input_bytes\":{}," ++
                "\"candidate_gzip_bytes\":{},\"gzip_ratio\":{{" ++
                "\"numerator\":{},\"denominator\":{}}}," ++
                "\"content_length\":{},\"wire_body_bytes\":{}," ++
                "\"coding_outcome\":\"{s}\"}}",
            .{
                metric.id,
                metric.input_bytes,
                metric.candidate_gzip_bytes,
                metric.candidate_gzip_bytes,
                metric.input_bytes,
                metric.content_length,
                metric.wire_body_bytes,
                metric.coding_outcome,
            },
        );
    }
    try json.writeAll("\n  ]\n}\n");

    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_storage,
        "{s}/metrics.json",
        .{directory},
    );
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = path,
        .data = json.buffered(),
    });
}

test "realistic and UTF-8 fixtures keep their intended compression profiles" {
    inline for (.{
        .{ Media.html, Entropy.realistic },
        .{ Media.json, Entropy.realistic },
        .{ Media.html, Entropy.utf8_incompressible },
        .{ Media.json, Entropy.utf8_incompressible },
    }) |case| {
        const input = comptime fixture(case[0], case[1], 16 * 1024);
        var workspace: gzip_encoder.Workspace = undefined;
        var output: [20 * 1024]u8 = undefined;
        const encoded = try gzip_encoder.compress(&workspace, &input, &output, .fastest);
        try std.testing.expect(std.unicode.utf8ValidateSlice(&input));
        if (case[1] == .realistic) {
            try std.testing.expect(encoded.len * 5 >= input.len);
            try std.testing.expect(encoded.len * 4 <= input.len * 3);
        } else {
            try std.testing.expect(encoded.len * 4 >= input.len * 3);
            try std.testing.expect(encoded.len <= input.len + input.len / 8);
        }
    }
}
