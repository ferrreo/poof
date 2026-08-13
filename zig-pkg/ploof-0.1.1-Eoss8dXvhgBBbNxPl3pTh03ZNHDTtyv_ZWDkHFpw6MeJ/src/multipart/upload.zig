const std = @import("std");
const upload_io = @import("../upload_io.zig");
const initial_write_state_diagnostic =
    "PLOOF-E3475 multipart sink must declare initial_write_state";
const initial_startup_state_diagnostic =
    "PLOOF-E3483 multipart sink must declare initial_startup_state";
const request_handles_diagnostic =
    "PLOOF-E3486 multipart sink request_handles_max must be u8 at most 16";
const runtime_handles_diagnostic =
    "PLOOF-E3487 multipart sink runtime_handles_max must be u8 at most 16";

pub const Access = upload_io.Access;
pub const Create = upload_io.Create;
pub const FileHandle = upload_io.FileHandle;
pub const IoCompletion = upload_io.IoCompletion;
pub const IoError = upload_io.IoError;
pub const IoKind = upload_io.IoKind;
pub const IoRequest = upload_io.IoRequest;
pub const IoRequirements = upload_io.IoRequirements;
pub const IoSuccess = upload_io.IoSuccess;
pub const OpenBase = upload_io.OpenBase;
pub const OpenKind = upload_io.OpenKind;
pub const Poll = upload_io.Poll;
pub const PollEvent = upload_io.PollEvent;
pub const RequestIssue = upload_io.RequestIssue;
pub const Resolve = upload_io.Resolve;
pub const SuccessIssue = upload_io.SuccessIssue;

pub const WriteInput = struct {
    /// Stable until this write poller returns done or fails after quiescence.
    bytes: []const u8,
    offset: u64,
};

pub const FinishInput = struct {
    bytes: u64,
};

pub const RuntimeStartInput = struct {
    worker_index: u16,
    /// Borrowed only for this runtimeStart call. A sink must not retain this pointer.
    entropy: *const [32]u8,
};

pub const upload_window_hard_max: u8 = 16;
pub const upload_chunk_bytes_hard_max: u32 = 1024 * 1024;
pub const multipart_file_routes_hard_max: u16 = 512;
pub const sink_handles_hard_max: u8 = 16;

pub const SinkIssue = enum(u8) {
    not_struct,
    missing_marker,
    missing_state,
    missing_write_state,
    missing_summary,
    missing_begin_input,
    missing_error,
    missing_runtime,
    missing_startup_state,
    missing_io_requirements,
    invalid_io_requirements,
    invalid_request_handles_max,
    invalid_runtime_handles_max,
    open_error_set,
    missing_initial_state,
    missing_initial_write_state,
    missing_initial_startup_state,
    invalid_runtime_start,
    invalid_runtime_stop,
    invalid_begin,
    invalid_write,
    invalid_finish,
    invalid_commit,
    invalid_abort,

    pub fn diagnostic(problem: SinkIssue) []const u8 {
        return switch (problem) {
            .not_struct => "PLOOF-E3466 multipart sink must be a struct type",
            .missing_marker => "PLOOF-E3467 type is not a Ploof multipart sink",
            .missing_state => "PLOOF-E3468 multipart sink must declare State",
            .missing_write_state => "PLOOF-E3469 multipart sink must declare WriteState",
            .missing_summary => "PLOOF-E3470 multipart sink must declare Summary",
            .missing_begin_input => "PLOOF-E3471 multipart sink must declare BeginInput",
            .missing_error => "PLOOF-E3472 multipart sink must declare Error",
            .missing_runtime => "PLOOF-E3481 multipart sink must declare Runtime",
            .missing_startup_state => "PLOOF-E3482 multipart sink must declare StartupState",
            .missing_io_requirements => {
                return "PLOOF-E3502 multipart sink must declare io_requirements";
            },
            .invalid_io_requirements => {
                return "PLOOF-E3503 multipart sink io_requirements must be a valid " ++
                    "IoRequirements value";
            },
            .invalid_request_handles_max => request_handles_diagnostic,
            .invalid_runtime_handles_max => runtime_handles_diagnostic,
            .open_error_set => "PLOOF-E3473 multipart sink Error must be finite",
            .missing_initial_state => "PLOOF-E3474 multipart sink must declare initial_state",
            .missing_initial_write_state => initial_write_state_diagnostic,
            .missing_initial_startup_state => initial_startup_state_diagnostic,
            .invalid_runtime_start => "PLOOF-E3484 invalid multipart sink runtimeStart signature",
            .invalid_runtime_stop => "PLOOF-E3485 invalid multipart sink runtimeStop signature",
            .invalid_begin => "PLOOF-E3476 invalid multipart sink begin signature",
            .invalid_write => "PLOOF-E3477 invalid multipart sink write signature",
            .invalid_finish => "PLOOF-E3478 invalid multipart sink finish signature",
            .invalid_commit => "PLOOF-E3479 invalid multipart sink commit signature",
            .invalid_abort => "PLOOF-E3480 invalid multipart sink abort signature",
        };
    }
};

pub fn sinkIssue(comptime Sink: type) ?SinkIssue {
    if (comptime @typeInfo(Sink) != .@"struct") return .not_struct;
    if (comptime !@hasDecl(Sink, "ploof_multipart_sink") or
        @TypeOf(Sink.ploof_multipart_sink) != bool or
        !Sink.ploof_multipart_sink)
    {
        return .missing_marker;
    }
    if (comptime declarationIssue(Sink)) |problem| return problem;
    if (comptime initialValueIssue(Sink)) |problem| return problem;
    return methodIssue(Sink);
}

fn declarationIssue(comptime Sink: type) ?SinkIssue {
    if (comptime !typeDeclaration(Sink, "State")) return .missing_state;
    if (comptime !typeDeclaration(Sink, "WriteState")) return .missing_write_state;
    if (comptime !typeDeclaration(Sink, "Summary")) return .missing_summary;
    if (comptime !typeDeclaration(Sink, "BeginInput")) return .missing_begin_input;
    if (comptime !typeDeclaration(Sink, "Error")) return .missing_error;
    const error_info = @typeInfo(Sink.Error);
    if (comptime error_info != .error_set or error_info.error_set == null) {
        return .open_error_set;
    }
    if (comptime !typeDeclaration(Sink, "Runtime")) return .missing_runtime;
    if (comptime !typeDeclaration(Sink, "StartupState")) return .missing_startup_state;
    if (comptime ioRequirementsIssue(Sink)) |problem| return problem;
    if (comptime !validHandleMaximum(Sink, "request_handles_max")) {
        return .invalid_request_handles_max;
    }
    if (comptime !validHandleMaximum(Sink, "runtime_handles_max")) {
        return .invalid_runtime_handles_max;
    }
    return null;
}

fn initialValueIssue(comptime Sink: type) ?SinkIssue {
    if (comptime !@hasDecl(Sink, "initial_state") or
        @TypeOf(Sink.initial_state) != Sink.State)
    {
        return .missing_initial_state;
    }
    if (comptime !@hasDecl(Sink, "initial_write_state") or
        @TypeOf(Sink.initial_write_state) != Sink.WriteState)
    {
        return .missing_initial_write_state;
    }
    if (comptime !@hasDecl(Sink, "initial_startup_state") or
        @TypeOf(Sink.initial_startup_state) != Sink.StartupState)
    {
        return .missing_initial_startup_state;
    }
    return null;
}

fn methodIssue(comptime Sink: type) ?SinkIssue {
    if (comptime !method(Sink, "runtimeStart", fn (
        *Sink.StartupState,
        PollEvent(RuntimeStartInput),
    ) Sink.Error!Poll(Sink.Runtime))) return .invalid_runtime_start;
    if (comptime !method(Sink, "runtimeStop", fn (
        *Sink.Runtime,
        PollEvent(void),
    ) Sink.Error!Poll(void))) return .invalid_runtime_stop;
    const LifecycleEvent = PollEvent(void);
    if (comptime !method(Sink, "begin", fn (
        *Sink.Runtime,
        *Sink.State,
        PollEvent(Sink.BeginInput),
    ) Sink.Error!Poll(void))) return .invalid_begin;
    if (comptime !method(Sink, "write", fn (
        *Sink.Runtime,
        *Sink.State,
        *Sink.WriteState,
        PollEvent(WriteInput),
    ) Sink.Error!Poll(void))) return .invalid_write;
    if (comptime !method(Sink, "finish", fn (
        *Sink.Runtime,
        *Sink.State,
        PollEvent(FinishInput),
    ) Sink.Error!Poll(Sink.Summary))) return .invalid_finish;
    if (comptime !method(Sink, "commit", fn (
        *Sink.Runtime,
        *Sink.State,
        LifecycleEvent,
    ) Sink.Error!Poll(void))) return .invalid_commit;
    if (comptime !method(Sink, "abort", fn (
        *Sink.Runtime,
        *Sink.State,
        LifecycleEvent,
    ) Sink.Error!Poll(void))) return .invalid_abort;
    return null;
}

pub fn validateSink(comptime Sink: type) void {
    if (sinkIssue(Sink)) |problem| @compileError(problem.diagnostic());
}

/// Validates request-local operations without requiring worker runtime
/// construction. Generated closed-schema adapters use this contract after
/// every underlying public sink has passed validateSink.
pub fn validateRequestSink(comptime Sink: type) void {
    if (requestSinkIssue(Sink)) |problem| @compileError(problem.diagnostic());
}

pub fn requestSinkIssue(comptime Sink: type) ?SinkIssue {
    if (comptime @typeInfo(Sink) != .@"struct") return .not_struct;
    if (comptime !requestSinkMarker(Sink)) return .missing_marker;
    if (comptime !typeDeclaration(Sink, "State")) return .missing_state;
    if (comptime !typeDeclaration(Sink, "WriteState")) return .missing_write_state;
    if (comptime !typeDeclaration(Sink, "Summary")) return .missing_summary;
    if (comptime !typeDeclaration(Sink, "BeginInput")) return .missing_begin_input;
    if (comptime !typeDeclaration(Sink, "Error")) return .missing_error;
    const error_info = @typeInfo(Sink.Error);
    if (comptime error_info != .error_set or error_info.error_set == null) {
        return .open_error_set;
    }
    if (comptime !typeDeclaration(Sink, "Runtime")) return .missing_runtime;
    if (comptime ioRequirementsIssue(Sink)) |problem| return problem;
    if (comptime !@hasDecl(Sink, "initial_write_state") or
        @TypeOf(Sink.initial_write_state) != Sink.WriteState)
    {
        return .missing_initial_write_state;
    }
    return requestMethodIssue(Sink);
}

fn ioRequirementsIssue(comptime Sink: type) ?SinkIssue {
    if (comptime !@hasDecl(Sink, "io_requirements")) return .missing_io_requirements;
    if (comptime @TypeOf(Sink.io_requirements) != IoRequirements) {
        return .invalid_io_requirements;
    }
    if (comptime !Sink.io_requirements.valid()) {
        return .invalid_io_requirements;
    }
    return null;
}

fn requestSinkMarker(comptime Sink: type) bool {
    return booleanDeclaration(Sink, "ploof_multipart_sink") or
        booleanDeclaration(Sink, "ploof_multipart_request_sink");
}

fn booleanDeclaration(comptime Owner: type, comptime name: []const u8) bool {
    return @hasDecl(Owner, name) and @TypeOf(@field(Owner, name)) == bool and
        @field(Owner, name);
}

fn requestMethodIssue(comptime Sink: type) ?SinkIssue {
    const LifecycleEvent = PollEvent(void);
    if (comptime !method(Sink, "begin", fn (
        *Sink.Runtime,
        *Sink.State,
        PollEvent(Sink.BeginInput),
    ) Sink.Error!Poll(void))) return .invalid_begin;
    if (comptime !method(Sink, "write", fn (
        *Sink.Runtime,
        *Sink.State,
        *Sink.WriteState,
        PollEvent(WriteInput),
    ) Sink.Error!Poll(void))) return .invalid_write;
    if (comptime !method(Sink, "finish", fn (
        *Sink.Runtime,
        *Sink.State,
        PollEvent(FinishInput),
    ) Sink.Error!Poll(Sink.Summary))) return .invalid_finish;
    if (comptime !method(Sink, "commit", fn (
        *Sink.Runtime,
        *Sink.State,
        LifecycleEvent,
    ) Sink.Error!Poll(void))) return .invalid_commit;
    if (comptime !method(Sink, "abort", fn (
        *Sink.Runtime,
        *Sink.State,
        LifecycleEvent,
    ) Sink.Error!Poll(void))) return .invalid_abort;
    return null;
}

pub const DiscardSink = struct {
    pub const ploof_multipart_sink = true;
    pub const ploof_multipart_discard_sink = true;
    pub const State = void;
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const Runtime = void;
    pub const StartupState = void;
    pub const io_requirements = IoRequirements.none;
    pub const request_handles_max: u8 = 0;
    pub const runtime_handles_max: u8 = 0;
    pub const Error = error{};
    pub const initial_state: State = {};
    pub const initial_write_state: WriteState = {};
    pub const initial_startup_state: StartupState = {};

    pub fn runtimeStart(
        _: *StartupState,
        event: PollEvent(RuntimeStartInput),
    ) Error!Poll(Runtime) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => unreachable,
        };
    }

    pub fn runtimeStop(_: *Runtime, event: PollEvent(void)) Error!Poll(void) {
        return completeLifecycle(event);
    }

    pub fn begin(_: *Runtime, _: *State, event: PollEvent(BeginInput)) Error!Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => unreachable,
        };
    }

    pub fn write(
        _: *Runtime,
        _: *State,
        _: *WriteState,
        event: PollEvent(WriteInput),
    ) Error!Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => unreachable,
        };
    }

    pub fn finish(
        _: *Runtime,
        _: *State,
        event: PollEvent(FinishInput),
    ) Error!Poll(Summary) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => unreachable,
        };
    }

    pub fn commit(_: *Runtime, _: *State, event: PollEvent(void)) Error!Poll(void) {
        return completeLifecycle(event);
    }

    pub fn abort(_: *Runtime, _: *State, event: PollEvent(void)) Error!Poll(void) {
        return completeLifecycle(event);
    }

    fn completeLifecycle(event: PollEvent(void)) Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => unreachable,
        };
    }
};

pub const StorageKeyError = error{
    Empty,
    TooLong,
    InvalidUtf8,
    ControlCharacter,
    AbsolutePath,
    EmptyComponent,
    DotComponent,
};

pub fn Decision(comptime Response: type) type {
    return union(enum) {
        commit: Response,
        abort: Response,

        pub fn response(self: *const @This()) *const Response {
            return switch (self.*) {
                inline else => |*value| value,
            };
        }

        pub fn commits(self: @This()) bool {
            return self == .commit;
        }
    };
}

pub fn FileDecision(comptime Begin: type, comptime Response: type) type {
    return union(enum) {
        accept: Begin,
        reject: Response,
    };
}

pub fn commit(response: anytype) Decision(@TypeOf(response)) {
    return .{ .commit = response };
}

pub fn abort(response: anytype) Decision(@TypeOf(response)) {
    return .{ .abort = response };
}

pub fn StorageKey(comptime bytes_max: usize) type {
    if (bytes_max == 0) {
        @compileError("PLOOF-E3460 StorageKey byte maximum must be nonzero");
    }
    if (bytes_max == std.math.maxInt(usize)) {
        @compileError("PLOOF-E3461 StorageKey byte maximum exceeds address space");
    }
    const Length = std.math.IntFittingRange(0, bytes_max);

    return struct {
        const Self = @This();

        pub const Error = StorageKeyError;
        pub const bytes_maximum = bytes_max;

        storage: [bytes_max + 1]u8,
        length: Length,

        pub fn init(input: []const u8) Error!Self {
            try validateStorageKey(input, bytes_max);
            var result = Self{ .storage = undefined, .length = @intCast(input.len) };
            @memcpy(result.storage[0..input.len], input);
            result.storage[input.len] = 0;
            return result;
        }

        /// Revalidates public value storage and returns a canonical owned copy.
        pub fn validatedCopy(self: *const Self) Error!Self {
            const length: usize = @intCast(self.length);
            if (length > bytes_max) return error.TooLong;
            return init(self.storage[0..length]);
        }

        /// Requires a value returned by init or validatedCopy.
        pub fn bytes(self: *const Self) []const u8 {
            return self.storage[0..@intCast(self.length)];
        }

        /// Requires a value returned by init or validatedCopy.
        pub fn sentinel(self: *const Self) [:0]const u8 {
            const length: usize = @intCast(self.length);
            return self.storage[0..length :0];
        }

        /// Requires a value returned by init or validatedCopy.
        pub fn basename(self: *const Self) []const u8 {
            const value = self.bytes();
            const slash = std.mem.lastIndexOfScalar(u8, value, '/') orelse return value;
            return value[slash + 1 ..];
        }

        /// Requires a value returned by init or validatedCopy.
        pub fn parent(self: *const Self) ?[]const u8 {
            const value = self.bytes();
            const slash = std.mem.lastIndexOfScalar(u8, value, '/') orelse return null;
            return value[0..slash];
        }
    };
}

fn validateStorageKey(input: []const u8, bytes_max: usize) StorageKeyError!void {
    if (input.len == 0) return error.Empty;
    if (input.len > bytes_max) return error.TooLong;
    if (input[0] == '/') return error.AbsolutePath;
    const view = std.unicode.Utf8View.init(input) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0x1f or (codepoint >= 0x7f and codepoint <= 0x9f)) {
            return error.ControlCharacter;
        }
    }
    var components = std.mem.splitScalar(u8, input, '/');
    while (components.next()) |component| {
        if (component.len == 0) return error.EmptyComponent;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.DotComponent;
        }
    }
}

fn typeDeclaration(comptime Container: type, comptime name: []const u8) bool {
    return @hasDecl(Container, name) and @TypeOf(@field(Container, name)) == type;
}

fn method(comptime Container: type, comptime name: []const u8, comptime T: type) bool {
    return @hasDecl(Container, name) and @TypeOf(@field(Container, name)) == T;
}

fn validHandleMaximum(comptime Sink: type, comptime name: []const u8) bool {
    return @hasDecl(Sink, name) and
        @TypeOf(@field(Sink, name)) == u8 and
        @field(Sink, name) <= sink_handles_hard_max;
}

test {
    std.testing.refAllDecls(@This());
}
