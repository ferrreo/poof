const headers = @import("part_headers.zig");
const plan = @import("plan.zig");

pub const Field = struct {
    entry_index: u16,
    occurrence: u16,
    kind: plan.PartKind,
    metadata: headers.Metadata,
    bytes: []const u8,
};

pub const FileStart = struct {
    entry_index: u16,
    occurrence: u16,
    metadata: headers.Metadata,
};

pub const FileChunk = struct {
    entry_index: u16,
    occurrence: u16,
    offset: u64,
    bytes: []const u8,
};

pub const FileEnd = struct {
    entry_index: u16,
    occurrence: u16,
    bytes: u64,
};
