const std = @import("std");
const ploof = @import("ploof");
const s3 = @import("s3.zig");

pub const max_bytes = s3.max_object_bytes;

/// Buffers one admitted image in process memory, then frees after multipart commit/abort.
pub const ImageSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = struct {
        buffer: ?[]u8 = null,
        len: usize = 0,
    };
    pub const WriteState = void;
    pub const Summary = struct {
        bytes: []const u8,
    };
    pub const BeginInput = void;
    pub const Runtime = void;
    pub const StartupState = void;
    pub const Error = error{ OutOfMemory, TooLarge, MissingBuffer };
    pub const io_requirements = ploof.Multipart.IoRequirements.none;
    pub const request_handles_max: u8 = 0;
    pub const runtime_handles_max: u8 = 0;
    pub const initial_state: State = .{};
    pub const initial_write_state: WriteState = {};
    pub const initial_startup_state: StartupState = {};

    pub fn runtimeStart(
        _: *StartupState,
        event: ploof.Multipart.PollEvent(ploof.Multipart.RuntimeStartInput),
    ) Error!ploof.Multipart.Poll(Runtime) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.MissingBuffer,
        };
    }

    pub fn runtimeStop(
        _: *Runtime,
        event: ploof.Multipart.PollEvent(void),
    ) Error!ploof.Multipart.Poll(void) {
        return lifecycle(event);
    }

    pub fn begin(
        _: *Runtime,
        state: *State,
        event: ploof.Multipart.PollEvent(BeginInput),
    ) Error!ploof.Multipart.Poll(void) {
        return switch (event) {
            .start => {
                clear(state);
                state.buffer = std.heap.page_allocator.alloc(u8, max_bytes) catch
                    return error.OutOfMemory;
                state.len = 0;
                return .{ .done = {} };
            },
            .completion => error.MissingBuffer,
        };
    }

    pub fn write(
        _: *Runtime,
        state: *State,
        _: *WriteState,
        event: ploof.Multipart.PollEvent(ploof.Multipart.WriteInput),
    ) Error!ploof.Multipart.Poll(void) {
        return switch (event) {
            .start => |input| {
                const buffer = state.buffer orelse return error.MissingBuffer;
                if (state.len > max_bytes or input.bytes.len > max_bytes - state.len) {
                    return error.TooLarge;
                }
                @memcpy(buffer[state.len..][0..input.bytes.len], input.bytes);
                state.len += input.bytes.len;
                return .{ .done = {} };
            },
            .completion => error.MissingBuffer,
        };
    }

    pub fn finish(
        _: *Runtime,
        state: *State,
        event: ploof.Multipart.PollEvent(ploof.Multipart.FinishInput),
    ) Error!ploof.Multipart.Poll(Summary) {
        return switch (event) {
            .start => |input| {
                const buffer = state.buffer orelse return error.MissingBuffer;
                if (input.bytes != state.len) return error.TooLarge;
                return .{ .done = .{ .bytes = buffer[0..state.len] } };
            },
            .completion => error.MissingBuffer,
        };
    }

    pub fn commit(
        _: *Runtime,
        state: *State,
        event: ploof.Multipart.PollEvent(void),
    ) Error!ploof.Multipart.Poll(void) {
        return switch (event) {
            .start => {
                clear(state);
                return .{ .done = {} };
            },
            .completion => error.MissingBuffer,
        };
    }

    pub fn abort(
        _: *Runtime,
        state: *State,
        event: ploof.Multipart.PollEvent(void),
    ) Error!ploof.Multipart.Poll(void) {
        return switch (event) {
            .start => {
                clear(state);
                return .{ .done = {} };
            },
            .completion => error.MissingBuffer,
        };
    }

    fn lifecycle(event: ploof.Multipart.PollEvent(void)) Error!ploof.Multipart.Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.MissingBuffer,
        };
    }

    fn clear(state: *State) void {
        if (state.buffer) |buffer| {
            std.heap.page_allocator.free(buffer);
            state.buffer = null;
        }
        state.len = 0;
    }
};

comptime {
    ploof.Multipart.validateSink(ImageSink);
}
