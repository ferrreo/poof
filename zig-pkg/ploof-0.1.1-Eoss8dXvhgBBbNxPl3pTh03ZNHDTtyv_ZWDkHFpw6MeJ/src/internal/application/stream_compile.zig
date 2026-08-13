const std = @import("std");
const response_stream = @import("../../response/stream.zig");
const response_stream_erasure = @import("../response/stream_erasure.zig");
const producer_compile = @import("../response/stream_producer_compile.zig");
const finite_output = @import("finite_output.zig");

pub const Layout = struct {
    stream_enabled: bool = false,
    producer_bytes_max: usize = 0,
    producer_alignment_max: usize = 0,
    output: finite_output.Plan = .contiguous,

    pub fn include(self: *Layout, other: Layout) void {
        self.stream_enabled = self.stream_enabled or other.stream_enabled;
        self.producer_bytes_max = @max(self.producer_bytes_max, other.producer_bytes_max);
        self.producer_alignment_max = @max(
            self.producer_alignment_max,
            other.producer_alignment_max,
        );
        self.output = finite_output.include(self.output, other.output);
    }
};

pub fn Storage(comptime layout: Layout) type {
    if (comptime !layout.stream_enabled) return struct {};
    return response_stream_erasure.Erased(
        @max(1, layout.producer_bytes_max),
        layout.producer_alignment_max,
    );
}

pub fn classifyPayload(
    comptime Payload: type,
    comptime Context: type,
    comptime Response: type,
) ?Layout {
    if (Payload == Response) return .{};
    if (comptime @import("../../html/response.zig").is(Payload)) {
        return .{ .output = finite_output.forPayload(Payload) };
    }
    if (@typeInfo(Payload) != .@"struct" or
        !@hasDecl(Payload, "ProducerType") or
        @TypeOf(Payload.ProducerType) != type)
    {
        return null;
    }
    const Producer = Payload.ProducerType;
    if (Payload != Context.StreamResponse(Producer)) return null;
    producer_compile.validate(Producer);
    return .{
        .stream_enabled = true,
        .producer_bytes_max = @sizeOf(Producer),
        .producer_alignment_max = @alignOf(Producer),
    };
}

const TestContext = struct {
    pub fn StreamResponse(comptime Producer: type) type {
        return struct {
            pub const ProducerType = Producer;
            producer: Producer,
        };
    }
};

const TestResponse = struct {};

fn TestProducer(comptime bytes: usize, comptime alignment: u29) type {
    return struct {
        storage: [bytes]u8 align(alignment),

        pub fn poll(
            _: *@This(),
            _: []u8,
            _: response_stream.Wake,
        ) response_stream.PollError!response_stream.PollResult {
            return .pending;
        }
    };
}

const SizedProducer = TestProducer(17, 16);
const ZeroProducer = TestProducer(0, 1);

test "payload classification requires exact owned stream type and reports actual layout" {
    const finite = classifyPayload(TestResponse, TestContext, TestResponse).?;
    try std.testing.expect(!finite.stream_enabled);
    try std.testing.expectEqual(@as(usize, 0), finite.producer_bytes_max);
    try std.testing.expectEqual(@as(usize, 0), finite.producer_alignment_max);

    const stream = classifyPayload(
        TestContext.StreamResponse(SizedProducer),
        TestContext,
        TestResponse,
    ).?;
    try std.testing.expect(stream.stream_enabled);
    try std.testing.expectEqual(@sizeOf(SizedProducer), stream.producer_bytes_max);
    try std.testing.expectEqual(@alignOf(SizedProducer), stream.producer_alignment_max);

    const RawDescriptor = response_stream.Response(SizedProducer);
    const Mimic = struct {
        pub const ProducerType = SizedProducer;
    };
    try std.testing.expect(classifyPayload(?TestResponse, TestContext, TestResponse) == null);
    try std.testing.expect(classifyPayload(RawDescriptor, TestContext, TestResponse) == null);
    try std.testing.expect(classifyPayload(Mimic, TestContext, TestResponse) == null);

    const zero = comptime classifyPayload(
        TestContext.StreamResponse(ZeroProducer),
        TestContext,
        TestResponse,
    ).?;
    try std.testing.expectEqual(@as(usize, 0), zero.producer_bytes_max);
    try std.testing.expectEqual(@as(usize, 1), zero.producer_alignment_max);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Storage(.{})));
    try std.testing.expect(@sizeOf(Storage(zero)) > 0);
}

test {
    std.testing.refAllDecls(@This());
}
