pub const Error = error{
    InvalidWorkerIndex,
    InvalidConnectionIndex,
    InvalidConnectionState,
    InvalidCompletion,
    BackendFailure,
    ResponseSerializationFailed,
    RejectionBufferTooSmall,
    InvalidRuntimeFields,
    ClockOverflow,
    StateInvariant,
    UploadFailure,
};

pub const Disposition = enum(u8) {
    retained,
    released,
    ignored_stale,
};
