const std = @import("std");

/// Application body-length contract. Transport selects wire framing.
pub const Framing = union(enum) {
    unknown,
    exact: u64,

    pub fn permitsTrailers(framing: Framing) bool {
        return switch (framing) {
            .unknown => true,
            .exact => false,
        };
    }
};

/// Ordered borrowed trailer field returned by a completed unknown-length stream.
pub const TrailerField = struct {
    name: []const u8,
    value: []const u8,
};

/// Closed producer success protocol.
///
/// A producer must initialize exactly the reported progress prefix during that poll.
/// It must not retain or mutate the output slice after `poll` returns. A completed
/// trailer slice, its descriptors, names, and values remain immutable and race-free
/// until `join` returns.
pub const PollResult = union(enum) {
    progress: usize,
    done: []const TrailerField,
    pending,
};

/// Fixed producer failure. Transport maps this to connection abort.
pub const PollError = error{ProducerFailed};

/// Copyable notification capability for one runtime-managed stream generation.
/// Producers may copy this value, but must stop using every copy before `join` returns.
pub const Wake = struct {
    context: *anyopaque,
    generation_value: u64,
    notify_fn: *const fn (*anyopaque, u64) void,

    /// Runtime adapter seam. Application producers receive, but do not construct, wakes.
    pub fn init(
        context: *anyopaque,
        generation: u64,
        notify_fn: *const fn (*anyopaque, u64) void,
    ) Wake {
        std.debug.assert(generation != 0);
        return .{
            .context = context,
            .generation_value = generation,
            .notify_fn = notify_fn,
        };
    }

    /// Non-failing, allocation-free notification. Stale generations are ignored by runtime.
    pub fn notify(wake: Wake) void {
        wake.notify_fn(wake.context, wake.generation_value);
    }
};

/// Concrete stream retained until application composition copies its producer into workspace.
/// Producer values must remain safely relocatable until first poll; self-relative pointers are
/// unsupported. Every pointer reachable from a producer must target stable storage that remains
/// valid until `join` returns; handler-stack storage is invalid.
pub fn Response(comptime Producer: type) type {
    return struct {
        pub const ProducerType = Producer;

        framing: Framing,
        trailer_names: []const []const u8,
        producer: Producer,
    };
}

/// Producer type carried by a concrete public response descriptor.
pub fn producerType(comptime Descriptor: type) type {
    if (@typeInfo(Descriptor) != .@"struct" or !@hasDecl(Descriptor, "ProducerType")) {
        @compileError("PLOOF-E3102 invalid streaming response descriptor");
    }
    const Producer = Descriptor.ProducerType;
    if (Descriptor != Response(Producer)) {
        @compileError("PLOOF-E3102 invalid streaming response descriptor");
    }
    return Producer;
}

/// Unknown-length response. The declared trailer slice, its descriptors, and every name remain
/// stable, immutable, race-free, and valid until `join` returns; handler-stack storage is invalid.
pub fn unknown(producer: anytype, trailer_names: []const []const u8) Response(@TypeOf(producer)) {
    return .{
        .framing = .unknown,
        .trailer_names = trailer_names,
        .producer = producer,
    };
}

/// Exact-length response. Trailers are unavailable with an exact body length.
pub fn exact(length: u64, producer: anytype) Response(@TypeOf(producer)) {
    return .{
        .framing = .{ .exact = length },
        .trailer_names = &.{},
        .producer = producer,
    };
}

test "wake copies retain generation and notification callback" {
    const Counter = struct {
        value: u64 = 0,

        fn notify(context: *anyopaque, generation: u64) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.value += generation;
        }
    };

    var counter = Counter{};
    const wake = Wake.init(&counter, 7, Counter.notify);
    const copy = wake;
    wake.notify();
    copy.notify();
    try std.testing.expectEqual(@as(u64, 14), counter.value);
}

test "response constructors retain framing producer and declarations" {
    const Producer = struct { id: u32 };
    const declarations = [_][]const u8{ "digest", "x-stats" };

    const streamed = unknown(Producer{ .id = 17 }, &declarations);
    try std.testing.expect(producerType(@TypeOf(streamed)) == Producer);
    try std.testing.expect(streamed.framing == .unknown);
    try std.testing.expect(streamed.framing.permitsTrailers());
    try std.testing.expectEqual(@as(u32, 17), streamed.producer.id);
    try std.testing.expectEqualStrings("digest", streamed.trailer_names[0]);

    const counted = exact(42, Producer{ .id = 19 });
    try std.testing.expectEqual(@as(u64, 42), counted.framing.exact);
    try std.testing.expect(!counted.framing.permitsTrailers());
    try std.testing.expectEqual(@as(usize, 0), counted.trailer_names.len);
}

test {
    std.testing.refAllDecls(@This());
}
