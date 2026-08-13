const std = @import("std");

pub const RingInitError = error{
    RingConfigurationRejected,
    RingDescriptorLimit,
    RingResourceLimit,
    RingPermissionDenied,
    RingUnsupported,
    RingSetupUnexpected,
    RingShapeMismatch,
    RequiredFeatureMissing,
    RingInvariantViolated,
};

pub fn ringInitError(err: anyerror) RingInitError {
    return switch (err) {
        error.EntriesZero,
        error.EntriesNotPowerOfTwo,
        error.ParamsOutsideAccessibleAddressSpace,
        error.ArgumentsInvalid,
        error.BufferInvalid,
        => error.RingConfigurationRejected,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => error.RingDescriptorLimit,
        error.SystemResources,
        error.OutOfMemory,
        error.LockedMemoryLimitExceeded,
        => error.RingResourceLimit,
        error.PermissionDenied,
        error.AccessDenied,
        => error.RingPermissionDenied,
        error.SystemOutdated,
        error.MemoryMappingNotSupported,
        error.OpcodeNotSupported,
        => error.RingUnsupported,
        else => error.RingSetupUnexpected,
    };
}

pub fn retryableFlushError(err: anyerror) bool {
    return err == error.SignalInterrupt;
}

pub fn retryableWaitError(err: anyerror) bool {
    return err == error.SystemResources or err == error.CompletionQueueOvercommitted;
}

test "ring errors distinguish retryable submission from startup categories" {
    try std.testing.expect(retryableFlushError(error.SignalInterrupt));
    try std.testing.expect(!retryableFlushError(error.SystemResources));
    try std.testing.expect(!retryableFlushError(error.CompletionQueueOvercommitted));
    try std.testing.expect(!retryableFlushError(error.SubmissionQueueEntryInvalid));
    try std.testing.expect(retryableWaitError(error.SystemResources));
    try std.testing.expect(retryableWaitError(error.CompletionQueueOvercommitted));
    try std.testing.expect(!retryableWaitError(error.SignalInterrupt));
    try std.testing.expectEqual(
        error.RingDescriptorLimit,
        ringInitError(error.ProcessFdQuotaExceeded),
    );
    try std.testing.expectEqual(
        error.RingSetupUnexpected,
        ringInitError(error.Unexpected),
    );
}
