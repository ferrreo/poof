const std = @import("std");

pub const head_bytes_hard_max: u32 = 1024 * 1024;
pub const fields_hard_max: u16 = 1024;

pub const RequestHeadLimitIssue = enum(u8) {
    head_bytes_zero,
    head_bytes_above_hard_max,
    request_line_bytes_zero,
    request_line_bytes_above_hard_max,
    request_line_bytes_above_head_max,
    field_line_bytes_zero,
    field_line_bytes_above_hard_max,
    field_line_bytes_above_head_max,
    fields_zero,
    fields_above_hard_max,
};

pub const RequestHeadLimits = struct {
    head_bytes_max: u32 = 32 * 1024,
    request_line_bytes_max: u32 = 8 * 1024,
    field_line_bytes_max: u32 = 8 * 1024,
    fields_max: u16 = 128,

    pub fn issue(limits: RequestHeadLimits) ?RequestHeadLimitIssue {
        if (limits.head_bytes_max == 0) return .head_bytes_zero;
        if (limits.head_bytes_max > head_bytes_hard_max) return .head_bytes_above_hard_max;
        if (limits.request_line_bytes_max == 0) return .request_line_bytes_zero;
        if (limits.request_line_bytes_max > head_bytes_hard_max) {
            return .request_line_bytes_above_hard_max;
        }
        if (limits.request_line_bytes_max > limits.head_bytes_max) {
            return .request_line_bytes_above_head_max;
        }
        if (limits.field_line_bytes_max == 0) return .field_line_bytes_zero;
        if (limits.field_line_bytes_max > head_bytes_hard_max) {
            return .field_line_bytes_above_hard_max;
        }
        if (limits.field_line_bytes_max > limits.head_bytes_max) {
            return .field_line_bytes_above_head_max;
        }
        if (limits.fields_max == 0) return .fields_zero;
        if (limits.fields_max > fields_hard_max) return .fields_above_hard_max;
        return null;
    }

    pub fn validate(comptime limits: RequestHeadLimits) RequestHeadLimits {
        if (limits.issue()) |problem| @compileError(requestIssueMessage(problem));
        return limits;
    }
};

pub const ResponseHeadLimitIssue = enum(u8) {
    head_bytes_zero,
    head_bytes_above_hard_max,
    field_line_bytes_zero,
    field_line_bytes_above_hard_max,
    field_line_bytes_above_head_max,
    fields_zero,
    fields_above_hard_max,
};

pub const ResponseHeadLimits = struct {
    head_bytes_max: u32 = 16 * 1024,
    field_line_bytes_max: u32 = 8 * 1024,
    fields_max: u16 = 64,

    pub fn issue(limits: ResponseHeadLimits) ?ResponseHeadLimitIssue {
        if (limits.head_bytes_max == 0) return .head_bytes_zero;
        if (limits.head_bytes_max > head_bytes_hard_max) return .head_bytes_above_hard_max;
        if (limits.field_line_bytes_max == 0) return .field_line_bytes_zero;
        if (limits.field_line_bytes_max > head_bytes_hard_max) {
            return .field_line_bytes_above_hard_max;
        }
        if (limits.field_line_bytes_max > limits.head_bytes_max) {
            return .field_line_bytes_above_head_max;
        }
        if (limits.fields_max == 0) return .fields_zero;
        if (limits.fields_max > fields_hard_max) return .fields_above_hard_max;
        return null;
    }

    pub fn validate(comptime limits: ResponseHeadLimits) ResponseHeadLimits {
        if (limits.issue()) |problem| @compileError(responseIssueMessage(problem));
        return limits;
    }
};

pub const standard_request_head_limits = RequestHeadLimits.validate(.{});
pub const standard_response_head_limits = ResponseHeadLimits.validate(.{});

fn requestIssueMessage(problem: RequestHeadLimitIssue) []const u8 {
    return switch (problem) {
        .head_bytes_zero => "request head byte limit must be nonzero",
        .head_bytes_above_hard_max => "request head byte limit exceeds 1 MiB",
        .request_line_bytes_zero => "request-line byte limit must be nonzero",
        .request_line_bytes_above_hard_max => "request-line byte limit exceeds 1 MiB",
        .request_line_bytes_above_head_max => "request-line byte limit exceeds head limit",
        .field_line_bytes_zero => "request field-line byte limit must be nonzero",
        .field_line_bytes_above_hard_max => "request field-line byte limit exceeds 1 MiB",
        .field_line_bytes_above_head_max => "request field-line byte limit exceeds head limit",
        .fields_zero => "request field count limit must be nonzero",
        .fields_above_hard_max => "request field count limit exceeds 1024",
    };
}

fn responseIssueMessage(problem: ResponseHeadLimitIssue) []const u8 {
    return switch (problem) {
        .head_bytes_zero => "response head byte limit must be nonzero",
        .head_bytes_above_hard_max => "response head byte limit exceeds 1 MiB",
        .field_line_bytes_zero => "response field-line byte limit must be nonzero",
        .field_line_bytes_above_hard_max => "response field-line byte limit exceeds 1 MiB",
        .field_line_bytes_above_head_max => "response field-line byte limit exceeds head limit",
        .fields_zero => "response field count limit must be nonzero",
        .fields_above_hard_max => "response field count limit exceeds 1024",
    };
}

test "standard request profile matches the protocol contract" {
    const limits = standard_request_head_limits;
    try std.testing.expectEqual(@as(u32, 32 * 1024), limits.head_bytes_max);
    try std.testing.expectEqual(@as(u32, 8 * 1024), limits.request_line_bytes_max);
    try std.testing.expectEqual(@as(u32, 8 * 1024), limits.field_line_bytes_max);
    try std.testing.expectEqual(@as(u16, 128), limits.fields_max);
    try std.testing.expectEqual(@as(?RequestHeadLimitIssue, null), limits.issue());
}

test "request profile accepts inclusive boundaries" {
    const smallest = RequestHeadLimits{
        .head_bytes_max = 1,
        .request_line_bytes_max = 1,
        .field_line_bytes_max = 1,
        .fields_max = 1,
    };
    const largest = RequestHeadLimits{
        .head_bytes_max = head_bytes_hard_max,
        .request_line_bytes_max = head_bytes_hard_max,
        .field_line_bytes_max = head_bytes_hard_max,
        .fields_max = fields_hard_max,
    };
    try std.testing.expectEqual(@as(?RequestHeadLimitIssue, null), smallest.issue());
    try std.testing.expectEqual(@as(?RequestHeadLimitIssue, null), largest.issue());
}

test "request profile reports every invalid boundary" {
    const hard_plus_one = head_bytes_hard_max + 1;
    try expectRequestIssue(.head_bytes_zero, .{ .head_bytes_max = 0 });
    try expectRequestIssue(.head_bytes_above_hard_max, .{ .head_bytes_max = hard_plus_one });
    try expectRequestIssue(.request_line_bytes_zero, .{ .request_line_bytes_max = 0 });
    try expectRequestIssue(.request_line_bytes_above_hard_max, .{
        .head_bytes_max = head_bytes_hard_max,
        .request_line_bytes_max = hard_plus_one,
    });
    try expectRequestIssue(.request_line_bytes_above_head_max, .{
        .request_line_bytes_max = 9,
        .head_bytes_max = 8,
    });
    try expectRequestIssue(.field_line_bytes_zero, .{ .field_line_bytes_max = 0 });
    try expectRequestIssue(.field_line_bytes_above_hard_max, .{
        .head_bytes_max = head_bytes_hard_max,
        .field_line_bytes_max = hard_plus_one,
    });
    try expectRequestIssue(.field_line_bytes_above_head_max, .{
        .field_line_bytes_max = 9,
        .request_line_bytes_max = 8,
        .head_bytes_max = 8,
    });
    try expectRequestIssue(.fields_zero, .{ .fields_max = 0 });
    try expectRequestIssue(.fields_above_hard_max, .{ .fields_max = fields_hard_max + 1 });
}

test "standard response profile matches the protocol contract" {
    const limits = standard_response_head_limits;
    try std.testing.expectEqual(@as(u32, 16 * 1024), limits.head_bytes_max);
    try std.testing.expectEqual(@as(u32, 8 * 1024), limits.field_line_bytes_max);
    try std.testing.expectEqual(@as(u16, 64), limits.fields_max);
    try std.testing.expectEqual(@as(?ResponseHeadLimitIssue, null), limits.issue());
}

test "response profile accepts inclusive boundaries" {
    const smallest = ResponseHeadLimits{
        .head_bytes_max = 1,
        .field_line_bytes_max = 1,
        .fields_max = 1,
    };
    const largest = ResponseHeadLimits{
        .head_bytes_max = head_bytes_hard_max,
        .field_line_bytes_max = head_bytes_hard_max,
        .fields_max = fields_hard_max,
    };
    try std.testing.expectEqual(@as(?ResponseHeadLimitIssue, null), smallest.issue());
    try std.testing.expectEqual(@as(?ResponseHeadLimitIssue, null), largest.issue());
}

test "response profile reports every invalid boundary" {
    const hard_plus_one = head_bytes_hard_max + 1;
    try expectResponseIssue(.head_bytes_zero, .{ .head_bytes_max = 0 });
    try expectResponseIssue(.head_bytes_above_hard_max, .{ .head_bytes_max = hard_plus_one });
    try expectResponseIssue(.field_line_bytes_zero, .{ .field_line_bytes_max = 0 });
    try expectResponseIssue(.field_line_bytes_above_hard_max, .{
        .head_bytes_max = head_bytes_hard_max,
        .field_line_bytes_max = hard_plus_one,
    });
    try expectResponseIssue(.field_line_bytes_above_head_max, .{
        .field_line_bytes_max = 9,
        .head_bytes_max = 8,
    });
    try expectResponseIssue(.fields_zero, .{ .fields_max = 0 });
    try expectResponseIssue(.fields_above_hard_max, .{ .fields_max = fields_hard_max + 1 });
}

fn expectRequestIssue(
    expected: RequestHeadLimitIssue,
    limits: RequestHeadLimits,
) !void {
    try std.testing.expectEqual(@as(?RequestHeadLimitIssue, expected), limits.issue());
}

fn expectResponseIssue(
    expected: ResponseHeadLimitIssue,
    limits: ResponseHeadLimits,
) !void {
    try std.testing.expectEqual(@as(?ResponseHeadLimitIssue, expected), limits.issue());
}
