pub const disposition_parameters_hard_max: u8 = 64;

pub const Limits = struct {
    header_fields_max: u16 = 16,
    header_bytes_max: usize = 8 * 1024,
    name_bytes_max: usize = 128,
    filename_bytes_max: usize = 255,
    disposition_parameters_max: u8 = 16,

    pub fn validate(comptime limits: Limits) void {
        if (limits.header_fields_max == 0) {
            @compileError("multipart part-header field limit must be nonzero");
        }
        if (limits.header_bytes_max < 2) {
            @compileError("multipart part-header byte limit must include the final CRLF");
        }
        if (limits.name_bytes_max == 0) {
            @compileError("multipart part-name byte limit must be nonzero");
        }
        if (limits.disposition_parameters_max == 0) {
            @compileError("multipart disposition parameter limit must be nonzero");
        }
        if (limits.disposition_parameters_max > disposition_parameters_hard_max) {
            @compileError("multipart disposition parameter limit exceeds 64");
        }
    }
};

pub const standard_limits = Limits{};

pub const Error = error{
    Malformed,
    LimitExceeded,
};

pub const FilenameSource = enum(u8) {
    filename,
    filename_star,
};

pub const ClientFilename = struct {
    bytes: []const u8,
    source: FilenameSource,
};

pub const Charset = struct {
    bytes: []const u8,
    quoted: bool,
};

pub const MediaType = struct {
    raw: []const u8,
    type: []const u8,
    subtype: []const u8,
    charset: ?Charset,
};

pub const Metadata = struct {
    name: []const u8,
    filename: ?ClientFilename,
    content_type: ?MediaType,
};

pub const MissingMedia = enum(u8) {
    allow,
    reject,
};

pub const MediaClaim = struct {
    type: []const u8,
    subtype: []const u8,
};

pub const MediaError = error{UnsupportedMedia};
