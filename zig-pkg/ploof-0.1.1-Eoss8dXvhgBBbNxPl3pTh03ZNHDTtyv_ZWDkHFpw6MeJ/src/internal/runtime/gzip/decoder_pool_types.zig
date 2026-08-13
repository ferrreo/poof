const gzip_decoder = @import("decoder.zig");

pub const Owner = struct {
    connection_index: u16,
    request_index: u16,
    generation: u32,
};

pub const Limits = struct {
    encoded_max: usize,
    decoded_max: usize,
};

pub const Counts = struct {
    encoded: usize,
    decoded: usize,
    members: usize,
};

pub const Result = union(enum) {
    complete: Counts,
    malformed,
    over_limit: gzip_decoder.Limit,
    read_failed,
    canceled,
};

pub const Lease = struct {
    index: u16,
    generation: u64,
};

pub const OutputRejection = enum(u8) {
    invalid_input,
    input_too_large,
    unsupported_media,
};

pub const Signals = packed struct(u8) {
    space: bool = false,
    output: bool = false,
    terminal: bool = false,
    padding: u5 = 0,
};
