const upload_finalizer = @import("../upload/finalizer.zig");

pub const Outcome = upload_finalizer.Outcome;
pub const FailureClass = upload_finalizer.FailureClass;
pub const CleanupFailureClass = upload_finalizer.CleanupFailureClass;

pub const Identity = struct {
    /// Stable index in the application's upload sink registry.
    registry_index: u16,
    /// Request-local non-discard file index in file-start order.
    instance_index: u16,
};

pub const PrimaryFailure = struct {
    class: FailureClass,
    identity: ?Identity,
};

pub const CleanupFailure = struct {
    class: CleanupFailureClass,
    identity: Identity,
};

pub const Report = struct {
    outcome: Outcome,
    primary: ?PrimaryFailure,
    instance_count: u16,
    commit_attempted_count: u32,
    commit_completed_count: u32,
    abort_attempted_count: u32,
    abort_completed_count: u32,
    cleanup_failure_count: u32,

    pub fn responseAllowed(self: @This()) bool {
        return self.outcome != .failed;
    }
};
