const std = @import("std");
const asset = @import("../../asset.zig");
const diagnostic = @import("template_diagnostic.zig");

pub fn validate(comptime Current: type, comptime index: usize) void {
    const Source = Current.SourceType;
    const directive = Source.directives[index];
    const name = directive.name.bytes(Source.source);
    const Assets = @TypeOf(Current.assets_value);
    if (!@hasField(Assets, name)) {
        diagnostic.fail(
            .invalid_inline_asset,
            Source,
            directive.name.start,
            "unknown inline asset '" ++ name ++ "'",
        );
    }
    const reference = @field(Current.assets_value, name);
    const expected: asset.MediaKind = switch (directive.kind) {
        .inline_css => .css,
        .inline_javascript => .javascript,
        else => unreachable,
    };
    if (asset.referenceKind(@TypeOf(reference)) != expected) {
        diagnostic.fail(
            .invalid_inline_asset,
            Source,
            directive.name.start,
            "inline asset '" ++ name ++ "' must have media kind " ++ @tagName(expected),
        );
    }
    const content = bytes(Current, index);
    if (!std.unicode.utf8ValidateSlice(content) or
        std.mem.indexOfScalar(u8, content, 0) != null)
    {
        diagnostic.fail(
            .invalid_inline_asset,
            Source,
            directive.name.start,
            "inline asset '" ++ name ++ "' must be NUL-free UTF-8",
        );
    }
    const closing = if (expected == .css) "</style" else "</script";
    if (containsAsciiIgnoreCase(content, closing)) {
        diagnostic.fail(
            .invalid_inline_asset,
            Source,
            directive.name.start,
            "inline asset '" ++ name ++ "' contains forbidden " ++ closing ++ " sequence",
        );
    }
}

pub fn bytes(comptime Current: type, comptime index: usize) []const u8 {
    const directive = comptime Current.SourceType.directives[index];
    const name = comptime directive.name.bytes(Current.SourceType.source);
    const reference = comptime @field(Current.assets_value, name);
    return comptime reference.identityBytes() catch unreachable;
}

fn containsAsciiIgnoreCase(content: []const u8, needle: []const u8) bool {
    if (needle.len > content.len) return false;
    for (0..content.len - needle.len + 1) |start| {
        var equal = true;
        for (needle, content[start..][0..needle.len]) |left, right| {
            if (asciiLower(left) != asciiLower(right)) {
                equal = false;
                break;
            }
        }
        if (equal) return true;
    }
    return false;
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}
