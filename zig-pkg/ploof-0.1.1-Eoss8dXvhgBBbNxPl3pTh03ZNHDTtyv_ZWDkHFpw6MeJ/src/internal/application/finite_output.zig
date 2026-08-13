const html_response = @import("../../html/response.zig");

pub const ChunkPlan = struct {
    encoded_bytes_max: u32,
    json_scratch_bytes_max: u32,
};

pub const Plan = union(enum) {
    contiguous,
    chunks: ChunkPlan,
};

pub const contiguous = Plan.contiguous;

pub fn forPayload(comptime Payload: type) Plan {
    if (!html_response.is(Payload)) return .contiguous;
    return .{ .chunks = .{
        .encoded_bytes_max = Payload.encoded_bytes_max,
        .json_scratch_bytes_max = Payload.json_scratch_bytes_max,
    } };
}

pub fn include(left: Plan, right: Plan) Plan {
    return switch (left) {
        .contiguous => right,
        .chunks => |left_chunks| switch (right) {
            .contiguous => left,
            .chunks => |right_chunks| .{ .chunks = .{
                .encoded_bytes_max = @max(
                    left_chunks.encoded_bytes_max,
                    right_chunks.encoded_bytes_max,
                ),
                .json_scratch_bytes_max = @max(
                    left_chunks.json_scratch_bytes_max,
                    right_chunks.json_scratch_bytes_max,
                ),
            } },
        },
    };
}
