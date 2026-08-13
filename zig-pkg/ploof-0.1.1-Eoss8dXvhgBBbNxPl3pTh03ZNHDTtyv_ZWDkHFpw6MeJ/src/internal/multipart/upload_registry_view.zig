const std = @import("std");

const multipart_upload = @import("../../multipart/upload.zig");

pub const Error = error{RuntimeUnavailable};

pub fn RegistryView(comptime Spec: type) type {
    const sinks = comptime uniqueSinkTypes(Spec);
    const Pointers = pointerStorage(sinks);

    return struct {
        const Self = @This();

        pub const ploof_template_helper_capability = true;
        pub const sink_types = sinks;
        pub const sink_count: usize = sinks.len;

        pointers: Pointers,
        discard_runtime: multipart_upload.DiscardSink.Runtime = {},

        pub fn init(source: anytype) Error!Self {
            var pointers: Pointers = undefined;
            inline for (sinks, 0..) |Sink, index| {
                pointers[index] = try sourcePointer(source, Sink);
            }
            return .{ .pointers = pointers };
        }

        pub fn get(self: *Self, comptime Sink: type) *Sink.Runtime {
            if (comptime Sink == multipart_upload.DiscardSink) {
                return &self.discard_runtime;
            }
            inline for (sinks, 0..) |Candidate, index| {
                if (comptime Sink == Candidate) return self.pointers[index];
            }
            @compileError("multipart sink is not configured by this schema");
        }
    };
}

fn sourcePointer(source: anytype, comptime Sink: type) Error!*Sink.Runtime {
    const selected = source.get(Sink);
    return switch (@typeInfo(@TypeOf(selected))) {
        .optional => selected orelse error.RuntimeUnavailable,
        .pointer => selected,
        else => @compileError("multipart registry get must return a pointer or optional pointer"),
    };
}

fn uniqueSinkTypes(comptime Spec: type) [uniqueSinkCount(Spec)]type {
    const capacity = sinkOccurrenceCount(Spec);
    var scratch: [capacity]type = undefined;
    var used: usize = 0;
    collectUniqueSinks(Spec, &scratch, &used);

    var result: [uniqueSinkCount(Spec)]type = undefined;
    inline for (0..result.len) |index| result[index] = scratch[index];
    return result;
}

fn uniqueSinkCount(comptime Spec: type) usize {
    var scratch: [sinkOccurrenceCount(Spec)]type = undefined;
    var used: usize = 0;
    collectUniqueSinks(Spec, &scratch, &used);
    return used;
}

fn collectUniqueSinks(comptime Spec: type, sinks: anytype, used: *usize) void {
    inline for (@typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(Spec.configured_schema, field.name));
        if (comptime Part.kind != .file or Part.SinkType == multipart_upload.DiscardSink) {
            continue;
        }
        const Sink = Part.SinkType;
        if (containsSink(sinks, used.*, Sink)) continue;
        sinks[used.*] = Sink;
        used.* += 1;
    }
}

fn containsSink(sinks: anytype, used: usize, comptime Sink: type) bool {
    var index: usize = 0;
    while (index < used) : (index += 1) {
        if (sinks[index] == Sink) return true;
    }
    return false;
}

fn sinkOccurrenceCount(comptime Spec: type) usize {
    var count: usize = 0;
    inline for (@typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(Spec.configured_schema, field.name));
        if (Part.kind == .file and Part.SinkType != multipart_upload.DiscardSink) count += 1;
    }
    return count;
}

fn pointerStorage(comptime sinks: anytype) type {
    var types: [sinks.len]type = undefined;
    inline for (sinks, 0..) |Sink, index| types[index] = *Sink.Runtime;
    return std.meta.Tuple(&types);
}

test {
    std.testing.refAllDecls(@This());
}
