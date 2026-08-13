pub fn State(comptime Spec: type) type {
    return struct {
        pub const Phase = enum(u8) {
            collecting,
            abort_draining,
            finalizing,
            done,
            fatal,
        };

        pub const ActivePhase = enum(u8) {
            begin,
            body,
            end_draining,
            finish,
            failed,
        };

        pub const Active = struct {
            tag: Spec.File,
            entry_index: u16,
            occurrence: u16,
            bytes: u64 = 0,
            record_index: ?usize,
            discard: bool,
            phase: ActivePhase = .begin,
        };
    };
}

pub fn Submission(comptime File: type, comptime Lane: type, comptime Request: type) type {
    return struct {
        lane: Lane,
        request: Request,
        file: File,
        instance_index: u16,
    };
}
