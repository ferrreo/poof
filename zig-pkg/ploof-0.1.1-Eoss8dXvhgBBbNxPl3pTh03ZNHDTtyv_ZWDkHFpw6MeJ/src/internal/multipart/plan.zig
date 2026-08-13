const std = @import("std");
const boundary = @import("boundary.zig");
const delimiter = @import("delimiter.zig");

pub const PartKind = enum(u8) {
    text,
    bytes,
    file,
};

pub const MissingMedia = enum(u8) {
    allow,
    reject,
};

pub const MediaClaim = struct {
    type: []const u8,
    subtype: []const u8,
};

pub const FileMediaPolicy = union(enum) {
    any: MissingMedia,
    claimed: struct {
        values: []const MediaClaim,
        missing: MissingMedia,
    },
};

pub const Entry = struct {
    name: []const u8,
    kind: PartKind,
    required: bool,
    maximum: u16,
    /// Zero inherits `Plan.limits.field_bytes_max`.
    bytes_max: usize = 0,
    csrf_field: bool = false,
    file_media: FileMediaPolicy = .{ .any = .allow },
};

pub const UnknownParts = union(enum) {
    reject,
    discard: u64,
};

pub const Limits = struct {
    total_body_bytes_max: u64 = 16 * 1024 * 1024,
    file_bytes_max: u64 = 8 * 1024 * 1024,
    field_bytes_max: usize = 64 * 1024,
    parts_max: u16 = 8,
    files_max: u16 = 4,
    part_headers_max: u16 = 16,
    part_header_bytes_max: usize = 8 * 1024,
    disposition_parameters_max: u8 = 16,
    delimiter_transport_padding_bytes_max: u16 = 64,
    name_bytes_max: usize = 128,
    filename_bytes_max: usize = 255,
    boundary_bytes_max: u8 = boundary.protocol_bytes_max,
};

pub const Plan = struct {
    entries: []const Entry,
    unknown_parts: UnknownParts = .reject,
    limits: Limits = .{},
};

pub fn validate(comptime selected: Plan) void {
    const limits = selected.limits;
    if (selected.entries.len == 0) @compileError("multipart parser plan is empty");
    if (limits.total_body_bytes_max == 0) @compileError("multipart total limit is zero");
    if (limits.parts_max == 0) @compileError("multipart part limit is zero");
    if (limits.part_headers_max == 0) @compileError("multipart header count is zero");
    if (limits.part_header_bytes_max < 2) @compileError("multipart header limit is below CRLF");
    if (limits.disposition_parameters_max == 0 or
        limits.disposition_parameters_max > 64)
    {
        @compileError("multipart disposition parameter limit is invalid");
    }
    if (limits.delimiter_transport_padding_bytes_max > delimiter.padding_hard_max) {
        @compileError("multipart delimiter padding limit exceeds hard maximum");
    }
    if (limits.name_bytes_max == 0) @compileError("multipart name limit is zero");
    if (limits.boundary_bytes_max == 0 or
        limits.boundary_bytes_max > boundary.protocol_bytes_max)
    {
        @compileError("multipart boundary limit is invalid");
    }
    validateEntries(selected);
    validateUnknown(selected);
}

fn validateEntries(comptime selected: Plan) void {
    var parts: u64 = 0;
    var files: u64 = 0;
    inline for (selected.entries, 0..) |entry, index| {
        if (entry.name.len == 0 or !std.unicode.utf8ValidateSlice(entry.name)) {
            @compileError("multipart parser entry name is invalid");
        }
        if (entry.name.len > selected.limits.name_bytes_max or entry.maximum == 0) {
            @compileError("multipart parser entry exceeds its plan");
        }
        inline for (selected.entries[index + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.name, other.name)) {
                @compileError("multipart parser entry names are duplicate");
            }
        }
        if (!entry.csrf_field) parts += entry.maximum;
        if (entry.kind == .file) files += entry.maximum;
        if (entry.csrf_field and
            (entry.kind != .bytes or entry.required or entry.bytes_max != 128))
        {
            @compileError("multipart CSRF entry is invalid");
        }
        if (entry.kind != .file and std.meta.activeTag(entry.file_media) != .any) {
            @compileError("multipart field has a file media policy");
        }
    }
    if (parts > selected.limits.parts_max or files > selected.limits.files_max) {
        @compileError("multipart parser cardinality exceeds route limits");
    }
}

fn validateUnknown(comptime selected: Plan) void {
    switch (selected.unknown_parts) {
        .reject => {},
        .discard => |bytes_max| {
            if (bytes_max == 0 or bytes_max > selected.limits.total_body_bytes_max) {
                @compileError("multipart unknown-part limit is invalid");
            }
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}
