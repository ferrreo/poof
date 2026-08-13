const gzip_encoder = @import("../internal/runtime/gzip/encoder.zig");

pub const ResponseGzip = struct {
    pub const Level = gzip_encoder.Level;

    minimum_bytes: u64 = 1024,
    level: Level = .fastest,
};
