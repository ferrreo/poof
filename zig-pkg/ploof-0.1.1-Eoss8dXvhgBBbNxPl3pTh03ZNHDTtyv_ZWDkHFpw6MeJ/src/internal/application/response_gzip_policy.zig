const std = @import("std");
const media_type = @import("../http1/media_type.zig");
const response_content_coding = @import("../http1/response_content_coding.zig");
const syntax = @import("../http1/syntax.zig");

const cache_control_bytes_max: usize = 16 * 1024;
const cache_control_members_max: u8 = 64;

pub const Representation = struct {
    media: ?media_type.MediaType,
    forbids_compression: bool,
};

const Field = enum(u8) {
    other,
    content_type,
    entity_tag,
    metadata,
    cache_control,
};

pub fn analyze(value: anytype) error{InvalidHeader}!Representation {
    var selected_media: ?media_type.MediaType = null;
    var cache_control_bytes: usize = 0;
    var cache_control_members: u8 = 0;
    var metadata_forbids = false;
    var cache_control_forbids = false;
    var index: usize = 0;
    while (index < value.headers.len()) : (index += 1) {
        const field = value.headers.at(index);
        switch (classify(field.name)) {
            .other => {},
            .content_type => {
                if (selected_media != null) return error.InvalidHeader;
                selected_media = media_type.parse(field.value) catch {
                    return error.InvalidHeader;
                };
            },
            .entity_tag => metadata_forbids = metadata_forbids or
                !isWeakEntityTag(field.value),
            .metadata => metadata_forbids = true,
            .cache_control => {
                if (cache_control_forbids) continue;
                if (field.value.len > cache_control_bytes_max - cache_control_bytes) {
                    cache_control_forbids = true;
                    continue;
                }
                cache_control_bytes += field.value.len;
                cache_control_forbids = cacheControlValueForbids(
                    field.value,
                    &cache_control_members,
                );
            },
        }
    }
    return .{
        .media = selected_media orelse value.media_type,
        .forbids_compression = metadata_forbids or cache_control_forbids,
    };
}

pub fn eligibility(
    value: anytype,
    representation: Representation,
) response_content_coding.Eligibility {
    const status = @intFromEnum(value.status);
    if (status == 204 or status == 205 or status == 304) return .bodyless_status;
    if (value.body.isNone()) return .eligible;
    if (status == 206 or representation.forbids_compression) return .ineligible;
    const media = representation.media orelse return .ineligible;
    return if (compressibleParsed(media.bytes())) .eligible else .ineligible;
}

pub fn isCompressibleMediaType(value: []const u8) bool {
    const parsed = media_type.parse(value) catch return false;
    return compressibleParsed(parsed.bytes());
}

fn classify(name: []const u8) Field {
    return switch (name.len) {
        4 => if (syntax.eqlIgnoreCase(name, "etag")) .entity_tag else .other,
        6 => if (syntax.eqlIgnoreCase(name, "digest")) .metadata else .other,
        11 => if (syntax.eqlIgnoreCase(name, "repr-digest") or
            syntax.eqlIgnoreCase(name, "content-md5")) .metadata else .other,
        12 => if (syntax.eqlIgnoreCase(name, "content-type")) .content_type else .other,
        13 => if (syntax.eqlIgnoreCase(name, "cache-control"))
            .cache_control
        else if (syntax.eqlIgnoreCase(name, "content-range"))
            .metadata
        else
            .other,
        14 => if (syntax.eqlIgnoreCase(name, "content-digest")) .metadata else .other,
        else => .other,
    };
}

fn isWeakEntityTag(value: []const u8) bool {
    const tag = syntax.trimOws(value);
    if (tag.len < 4 or tag[0] != 'W' or tag[1] != '/' or
        tag[2] != '"' or tag[tag.len - 1] != '"') return false;
    for (tag[3 .. tag.len - 1]) |byte| {
        if (byte != 0x21 and (byte < 0x23 or byte == 0x7f)) return false;
    }
    return true;
}

fn cacheControlValueForbids(value: []const u8, members: *u8) bool {
    var start: usize = 0;
    var quoted = false;
    var escaped = false;
    for (value, 0..) |byte, index| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                quoted = false;
            }
        } else if (byte == '"') {
            quoted = true;
        } else if (byte == ',') {
            if (cacheControlMemberForbids(value[start..index], members)) return true;
            start = index + 1;
        }
    }
    if (quoted or escaped) return true;
    return cacheControlMemberForbids(value[start..], members);
}

fn cacheControlMemberForbids(member: []const u8, members: *u8) bool {
    if (members.* == cache_control_members_max) return true;
    members.* += 1;
    return syntax.eqlIgnoreCase(syntax.trimOws(member), "no-transform");
}

fn compressibleParsed(value: []const u8) bool {
    const semicolon = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const base = syntax.trimOws(value[0..semicolon]);
    const slash = std.mem.indexOfScalar(u8, base, '/') orelse return false;
    const type_name = base[0..slash];
    const subtype = base[slash + 1 ..];
    if (syntax.eqlIgnoreCase(type_name, "text")) return true;
    if (syntax.eqlIgnoreCase(type_name, "application")) {
        return syntax.eqlIgnoreCase(subtype, "json") or
            endsWithIgnoreCase(subtype, "+json") or
            syntax.eqlIgnoreCase(subtype, "javascript") or
            syntax.eqlIgnoreCase(subtype, "xml") or
            endsWithIgnoreCase(subtype, "+xml");
    }
    return syntax.eqlIgnoreCase(type_name, "image") and
        syntax.eqlIgnoreCase(subtype, "svg+xml");
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (suffix.len > value.len) return false;
    return syntax.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}
