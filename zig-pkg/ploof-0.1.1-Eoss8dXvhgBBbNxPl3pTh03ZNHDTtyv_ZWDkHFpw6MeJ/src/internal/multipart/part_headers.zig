const std = @import("std");
const content_disposition = @import("content_disposition.zig");
const media_type = @import("media_type.zig");
const syntax = @import("wire_syntax.zig");
const types = @import("types.zig");

pub const disposition_parameters_hard_max = types.disposition_parameters_hard_max;
pub const Limits = types.Limits;
pub const standard_limits = types.standard_limits;
pub const Error = types.Error;
pub const FilenameSource = types.FilenameSource;
pub const ClientFilename = types.ClientFilename;
pub const Charset = types.Charset;
pub const MediaType = types.MediaType;
pub const Metadata = types.Metadata;
pub const MissingMedia = types.MissingMedia;
pub const MediaClaim = types.MediaClaim;
pub const MediaError = types.MediaError;

/// `section` contains exactly the part headers and their terminating empty CRLF line.
/// Every returned slice borrows `section`, which the caller must retain unchanged.
pub fn parse(comptime limits: Limits, section: []u8) Error!Metadata {
    comptime limits.validate();
    if (section.len > limits.header_bytes_max) return error.LimitExceeded;
    var cursor: usize = 0;
    var fields: usize = 0;
    var disposition: ?content_disposition.Parsed = null;
    var content_type: ?MediaType = null;
    while (true) {
        const line = try nextLine(section, &cursor);
        if (line.len == 0) {
            if (cursor != section.len) return error.Malformed;
            break;
        }
        if (line[0] == ' ' or line[0] == '\t') return error.Malformed;
        fields += 1;
        if (fields > limits.header_fields_max) return error.LimitExceeded;
        const field = try splitField(line);
        if (syntax.eqlIgnoreCase(field.name, "content-disposition")) {
            if (disposition != null) return error.Malformed;
            disposition = try content_disposition.parse(limits, field.value);
        } else if (syntax.eqlIgnoreCase(field.name, "content-type")) {
            if (content_type != null) return error.Malformed;
            content_type = try media_type.parse(field.value);
        } else if (syntax.eqlIgnoreCase(field.name, "content-transfer-encoding")) {
            return error.Malformed;
        }
    }
    const selected = disposition orelse return error.Malformed;
    return .{
        .name = selected.name,
        .filename = selected.filename,
        .content_type = content_type,
    };
}

pub fn validateText(metadata: Metadata) MediaError!void {
    return media_type.validateText(metadata.content_type);
}

pub fn claimedMediaAccepted(
    metadata: Metadata,
    comptime claims: []const MediaClaim,
    missing: MissingMedia,
) bool {
    return media_type.claimedMediaAccepted(metadata.content_type, claims, missing);
}

pub fn isMultipart(metadata: Metadata) bool {
    return media_type.isMultipart(metadata.content_type);
}

const Field = struct {
    name: []const u8,
    value: []u8,
};

fn splitField(line: []u8) Error!Field {
    if (!syntax.isFieldValue(line)) return error.Malformed;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.Malformed;
    const name = line[0..colon];
    if (!syntax.isToken(name)) return error.Malformed;
    return .{ .name = name, .value = trimOws(line[colon + 1 ..]) };
}

fn nextLine(section: []u8, cursor: *usize) Error![]u8 {
    if (cursor.* >= section.len) return error.Malformed;
    const start = cursor.*;
    while (cursor.* < section.len) {
        switch (section[cursor.*]) {
            '\n' => return error.Malformed,
            '\r' => {
                if (cursor.* + 1 >= section.len or section[cursor.* + 1] != '\n') {
                    return error.Malformed;
                }
                const line = section[start..cursor.*];
                cursor.* += 2;
                return line;
            },
            else => cursor.* += 1,
        }
    }
    return error.Malformed;
}

fn trimOws(value: []u8) []u8 {
    var start: usize = 0;
    while (start < value.len and (value[start] == ' ' or value[start] == '\t')) start += 1;
    var end = value.len;
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t')) end -= 1;
    return value[start..end];
}

test {
    std.testing.refAllDecls(@This());
}
