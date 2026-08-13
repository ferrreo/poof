pub const Error = error{
    ApplicationFailure,
    ResponseSerializationFailed,
    StateInvariant,
};

pub const Event = enum(u8) {
    need_more,
    upload_paused,
    prepared,
    invalid_utf8,
    invalid_input,
    input_too_large,
    unsupported_media,
};

pub const FeedResult = struct {
    consumed: usize,
    event: Event,
    close_connection: bool = false,
};

test {
    _ = @import("std").testing.refAllDecls(@This());
}
