const std = @import("std");
const upload = @import("../../multipart/upload.zig");
const layout = @import("upload_layout.zig");

pub const DispatchError = error{
    MissingWriteState,
    VariantMismatch,
    InvalidRequest,
};

pub const FailureSource = enum(u1) {
    sink,
    invalid_request,
};

pub fn SinkMux(comptime Spec: type, comptime Registry: type) type {
    const Storage = layout.Layout(Spec);
    validateSinks(Spec);

    return struct {
        pub const ploof_multipart_request_sink = true;
        pub const State = Storage.State;
        pub const WritePayload = writePayloadType(Spec);
        pub const WriteState = struct {
            payload: WritePayload = undefined,
            initialized: bool = false,
            failure_source: FailureSource = .sink,
        };
        pub const Summary = layout.SummaryValue(Spec);
        pub const BeginInput = Spec.BeginInput;
        pub const Error = mergedSinkErrors(Spec) || DispatchError;
        pub const io_requirements = mergedIoRequirements(Spec);
        pub const Runtime = struct {
            registry: *Registry,
            failure_source: FailureSource = .sink,
        };
        pub const request_handles_max = maximumRequestHandles(Spec);
        pub const initial_write_state: WriteState = .{};

        pub fn lifecycleFailureSource(runtime: *const Runtime) FailureSource {
            return runtime.failure_source;
        }

        pub fn writeFailureSource(write_state: *const WriteState) FailureSource {
            return write_state.failure_source;
        }

        pub fn isDiscard(tag: Spec.File) bool {
            return switch (tag) {
                inline else => |selected| SinkFor(
                    Spec,
                    @tagName(selected),
                ) == upload.DiscardSink,
            };
        }

        pub fn begin(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(BeginInput),
        ) Error!upload.Poll(void) {
            return switch (state.*) {
                inline else => |state_pointer, tag| beginFor(
                    @tagName(tag),
                    runtime,
                    state_pointer,
                    event,
                ),
            };
        }

        pub fn write(
            runtime: *Runtime,
            state: *State,
            write_state: *WriteState,
            event: upload.PollEvent(upload.WriteInput),
        ) Error!upload.Poll(void) {
            return switch (state.*) {
                inline else => |state_pointer, tag| writeFor(
                    @tagName(tag),
                    runtime,
                    state_pointer,
                    write_state,
                    event,
                ),
            };
        }

        pub fn finish(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(upload.FinishInput),
        ) Error!upload.Poll(Summary) {
            return switch (state.*) {
                inline else => |state_pointer, tag| finishFor(
                    @tagName(tag),
                    runtime,
                    state_pointer,
                    event,
                ),
            };
        }

        pub fn commit(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            return switch (state.*) {
                inline else => |state_pointer, tag| lifecycleFor(
                    @tagName(tag),
                    .commit,
                    runtime,
                    state_pointer,
                    event,
                ),
            };
        }

        pub fn abort(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            return switch (state.*) {
                inline else => |state_pointer, tag| lifecycleFor(
                    @tagName(tag),
                    .abort,
                    runtime,
                    state_pointer,
                    event,
                ),
            };
        }

        fn beginFor(
            comptime name: []const u8,
            runtime: *Runtime,
            state: *SinkFor(Spec, name).State,
            event: upload.PollEvent(BeginInput),
        ) Error!upload.Poll(void) {
            const Sink = SinkFor(Spec, name);
            runtime.failure_source = .sink;
            const sink_event: upload.PollEvent(Sink.BeginInput) = switch (event) {
                .start => |input| start: {
                    if (std.meta.activeTag(input) != @field(Spec.File, name)) {
                        runtime.failure_source = .invalid_request;
                        return error.VariantMismatch;
                    }
                    break :start .{ .start = @field(input, name) };
                },
                .completion => |completion| .{ .completion = completion },
            };
            const sink_runtime: *Sink.Runtime = runtime.registry.get(Sink);
            const result = try Sink.begin(sink_runtime, state, sink_event);
            return validateResult(Sink, &runtime.failure_source, result);
        }

        fn writeFor(
            comptime name: []const u8,
            runtime: *Runtime,
            state: *SinkFor(Spec, name).State,
            write_state: *WriteState,
            event: upload.PollEvent(upload.WriteInput),
        ) Error!upload.Poll(void) {
            return switch (event) {
                .start => |input| writeStart(
                    name,
                    runtime,
                    state,
                    write_state,
                    input,
                ),
                .completion => |completion| writeActive(
                    name,
                    runtime,
                    state,
                    write_state,
                    .{ .completion = completion },
                ),
            };
        }

        fn writeStart(
            comptime name: []const u8,
            runtime: *Runtime,
            state: *SinkFor(Spec, name).State,
            write_state: *WriteState,
            input: upload.WriteInput,
        ) Error!upload.Poll(void) {
            const Sink = SinkFor(Spec, name);
            write_state.* = .{};
            write_state.payload = @unionInit(
                WritePayload,
                name,
                Sink.initial_write_state,
            );
            write_state.initialized = true;
            const sink_runtime: *Sink.Runtime = runtime.registry.get(Sink);
            const result = try Sink.write(
                sink_runtime,
                state,
                &@field(write_state.payload, name),
                .{ .start = input },
            );
            return validateResult(Sink, &write_state.failure_source, result);
        }

        fn writeActive(
            comptime name: []const u8,
            runtime: *Runtime,
            state: *SinkFor(Spec, name).State,
            write_state: *WriteState,
            event: upload.PollEvent(upload.WriteInput),
        ) Error!upload.Poll(void) {
            const Sink = SinkFor(Spec, name);
            if (!write_state.initialized) {
                write_state.failure_source = .invalid_request;
                return error.MissingWriteState;
            }
            if (std.meta.activeTag(write_state.payload) != @field(Spec.File, name)) {
                write_state.failure_source = .invalid_request;
                return error.VariantMismatch;
            }
            write_state.failure_source = .sink;
            const sink_runtime: *Sink.Runtime = runtime.registry.get(Sink);
            const result = try Sink.write(
                sink_runtime,
                state,
                &@field(write_state.payload, name),
                event,
            );
            return validateResult(Sink, &write_state.failure_source, result);
        }

        fn finishFor(
            comptime name: []const u8,
            runtime: *Runtime,
            state: *SinkFor(Spec, name).State,
            event: upload.PollEvent(upload.FinishInput),
        ) Error!upload.Poll(Summary) {
            const Sink = SinkFor(Spec, name);
            runtime.failure_source = .sink;
            const sink_runtime: *Sink.Runtime = runtime.registry.get(Sink);
            const result = try validateResult(
                Sink,
                &runtime.failure_source,
                try Sink.finish(sink_runtime, state, event),
            );
            return switch (result) {
                .request => |request| .{ .request = request },
                .done => |value| .{ .done = @unionInit(Summary, name, value) },
            };
        }

        const Lifecycle = enum(u1) { commit, abort };

        fn lifecycleFor(
            comptime name: []const u8,
            comptime operation: Lifecycle,
            runtime: *Runtime,
            state: *SinkFor(Spec, name).State,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            const Sink = SinkFor(Spec, name);
            runtime.failure_source = .sink;
            const sink_runtime: *Sink.Runtime = runtime.registry.get(Sink);
            const result = switch (operation) {
                .commit => Sink.commit(sink_runtime, state, event),
                .abort => Sink.abort(sink_runtime, state, event),
            } catch |problem| {
                runtime.failure_source = lifecycleStateFailureSource(Sink, state);
                return problem;
            };
            return validateResult(Sink, &runtime.failure_source, result);
        }
    };
}

fn lifecycleStateFailureSource(
    comptime Sink: type,
    state: *const Sink.State,
) FailureSource {
    if (comptime @hasDecl(Sink, "lifecycleStateFailureSource")) {
        return switch (Sink.lifecycleStateFailureSource(state)) {
            .sink => .sink,
            .invalid_request => .invalid_request,
        };
    }
    return .sink;
}

fn validateResult(
    comptime Sink: type,
    failure_source: *FailureSource,
    result: anytype,
) DispatchError!@TypeOf(result) {
    switch (result) {
        .request => |request| {
            if (!Sink.io_requirements.contains(std.meta.activeTag(request))) {
                failure_source.* = .invalid_request;
                return error.InvalidRequest;
            }
        },
        .done => {},
    }
    return result;
}

fn writePayloadType(comptime Spec: type) type {
    const schema = Spec.configured_schema;
    const count = fileFieldCount(schema);
    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    var index: usize = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(schema, field.name));
        if (Part.kind != .file) continue;
        names[index] = field.name;
        types[index] = Part.SinkType.WriteState;
        index += 1;
    }
    return @Union(.auto, Spec.File, &names, &types, &@splat(.{}));
}

fn mergedSinkErrors(comptime Spec: type) type {
    comptime var Error = error{};
    inline for (@typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(Spec.configured_schema, field.name));
        if (Part.kind == .file) Error = Error || Part.SinkType.Error;
    }
    return Error;
}

fn mergedIoRequirements(comptime Spec: type) upload.IoRequirements {
    var requirements = upload.IoRequirements.none;
    inline for (@typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(Spec.configured_schema, field.name));
        if (Part.kind == .file) {
            requirements = requirements.merge(Part.SinkType.io_requirements);
        }
    }
    return requirements;
}

fn maximumRequestHandles(comptime Spec: type) u8 {
    var maximum: u8 = 0;
    inline for (@typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(Spec.configured_schema, field.name));
        if (Part.kind == .file) {
            maximum = @max(maximum, Part.SinkType.request_handles_max);
        }
    }
    return maximum;
}

fn validateSinks(comptime Spec: type) void {
    inline for (@typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(Spec.configured_schema, field.name));
        if (Part.kind == .file) upload.validateSink(Part.SinkType);
    }
}

fn SinkFor(comptime Spec: type, comptime name: []const u8) type {
    return @TypeOf(@field(Spec.configured_schema, name)).SinkType;
}

fn fileFieldCount(comptime schema: anytype) usize {
    var count: usize = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(schema, field.name));
        count += @intFromBool(Part.kind == .file);
    }
    return count;
}

test {
    std.testing.refAllDecls(@This());
}
