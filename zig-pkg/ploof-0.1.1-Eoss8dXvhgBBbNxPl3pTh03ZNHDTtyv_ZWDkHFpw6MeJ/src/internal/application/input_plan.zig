const body = @import("../../body.zig");

pub const Kind = enum(u8) {
    none,
    input,
    bytes,
    text,
    structured,
};

pub const Decoder = struct {
    kind: body.DecoderKind,
    encoded_wire_bytes_max: u64,
    decoded_bytes_max: u64,
    multipart_boundary_bytes_max: u8 = 0,
    csrf_body_source: bool = false,
};

pub const Plan = struct {
    kind: Kind,
    encoded_wire_bytes_max: u64,
    decoded_bytes_max: u64,
    accepted_media: []const body.MediaPattern,
    media_decoder_indices: []const u8,
    decoders: []const Decoder,
    selected_decoder: ?u8,
    workspace_bytes_max: u64,
    workspace_alignment: u32,
    workspace_class: u16,

    pub fn selectMedia(plan: Plan, pattern_index: usize) ?Plan {
        if (plan.kind == .none or plan.kind == .input or
            pattern_index >= plan.media_decoder_indices.len)
        {
            return null;
        }
        const decoder_index = plan.media_decoder_indices[pattern_index];
        if (decoder_index >= plan.decoders.len) return null;
        const decoder = plan.decoders[decoder_index];
        var selected = plan;
        selected.encoded_wire_bytes_max = decoder.encoded_wire_bytes_max;
        selected.decoded_bytes_max = decoder.decoded_bytes_max;
        selected.selected_decoder = decoder_index;
        return selected;
    }

    pub fn decoderKind(plan: Plan) ?body.DecoderKind {
        const index = plan.selected_decoder orelse return null;
        if (index >= plan.decoders.len) return null;
        return plan.decoders[index].kind;
    }

    pub fn headWorkspaceClass(plan: Plan) u16 {
        return switch (plan.kind) {
            .input, .structured => plan.workspace_class,
            .none, .bytes, .text => 0,
        };
    }
};

pub const none = Plan{
    .kind = .none,
    .encoded_wire_bytes_max = 0,
    .decoded_bytes_max = 0,
    .accepted_media = &.{},
    .media_decoder_indices = &.{},
    .decoders = &.{},
    .selected_decoder = null,
    .workspace_bytes_max = 0,
    .workspace_alignment = 1,
    .workspace_class = 0,
};

test "media selection applies only the chosen decoder limits" {
    const media = [_]body.MediaPattern{
        .{ .exact = "application/json" },
        .{ .exact = "application/x-www-form-urlencoded" },
    };
    const decoders = [_]Decoder{
        .{ .kind = .json, .encoded_wire_bytes_max = 11, .decoded_bytes_max = 7 },
        .{ .kind = .form, .encoded_wire_bytes_max = 13, .decoded_bytes_max = 9 },
    };
    const indices = [_]u8{ 0, 1 };
    const plan = Plan{
        .kind = .structured,
        .encoded_wire_bytes_max = 13,
        .decoded_bytes_max = 9,
        .accepted_media = &media,
        .media_decoder_indices = &indices,
        .decoders = &decoders,
        .selected_decoder = null,
        .workspace_bytes_max = 64,
        .workspace_alignment = 8,
        .workspace_class = 1,
    };
    const selected = plan.selectMedia(0).?;
    try @import("std").testing.expectEqual(body.DecoderKind.json, selected.decoderKind().?);
    try @import("std").testing.expectEqual(@as(u64, 7), selected.decoded_bytes_max);
}
