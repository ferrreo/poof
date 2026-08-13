const std = @import("std");
const status_module = @import("status.zig");

pub const Body = union(enum) {
    none,
    fixed: u64,
    stream_unknown,
    stream_exact: u64,
};

pub const Framing = union(enum) {
    none,
    fixed: u64,
    chunked,
};

pub const Input = struct {
    status: status_module.Status,
    request_is_head: bool,
    request_accepts_trailers: bool,
    body: Body,
    trailers_declared: bool,
};

pub const Plan = struct {
    framing: Framing,
    send_body: bool,
    invoke_stream: bool,
    emit_content_type: bool,
    emit_trailers: bool,
};

pub const PlanError = error{InvalidResponse};

pub fn plan(input: Input) PlanError!Plan {
    const code = @intFromEnum(input.status);
    if (code < 200 or code > 599) return error.InvalidResponse;

    if (code == 204 or code == 304) {
        switch (input.body) {
            .none => {},
            else => return error.InvalidResponse,
        }
        if (input.trailers_declared) return error.InvalidResponse;
        return .{
            .framing = .none,
            .send_body = false,
            .invoke_stream = false,
            .emit_content_type = false,
            .emit_trailers = false,
        };
    }
    if (code == 205) {
        switch (input.body) {
            .none => {},
            else => return error.InvalidResponse,
        }
        if (input.trailers_declared) return error.InvalidResponse;
        return .{
            .framing = .{ .fixed = 0 },
            .send_body = false,
            .invoke_stream = false,
            .emit_content_type = false,
            .emit_trailers = false,
        };
    }

    if (input.trailers_declared) switch (input.body) {
        .stream_unknown => {},
        else => return error.InvalidResponse,
    };
    if (input.request_is_head) return planHead(input.body);
    return planOrdinary(input);
}

fn planHead(body: Body) Plan {
    const framing: Framing = switch (body) {
        .none => .{ .fixed = 0 },
        .fixed => |length| .{ .fixed = length },
        .stream_unknown => .none,
        .stream_exact => |length| .{ .fixed = length },
    };
    const emit_content_type = switch (body) {
        .none => false,
        .fixed, .stream_exact => |length| length != 0,
        .stream_unknown => true,
    };
    return .{
        .framing = framing,
        .send_body = false,
        .invoke_stream = false,
        .emit_content_type = emit_content_type,
        .emit_trailers = false,
    };
}

fn planOrdinary(input: Input) Plan {
    return switch (input.body) {
        .none => .{
            .framing = .{ .fixed = 0 },
            .send_body = false,
            .invoke_stream = false,
            .emit_content_type = false,
            .emit_trailers = false,
        },
        .fixed => |length| .{
            .framing = .{ .fixed = length },
            .send_body = length != 0,
            .invoke_stream = false,
            .emit_content_type = length != 0,
            .emit_trailers = false,
        },
        .stream_unknown => .{
            .framing = .chunked,
            .send_body = true,
            .invoke_stream = true,
            .emit_content_type = true,
            .emit_trailers = input.trailers_declared and input.request_accepts_trailers,
        },
        .stream_exact => |length| .{
            .framing = .{ .fixed = length },
            .send_body = length != 0,
            .invoke_stream = true,
            .emit_content_type = length != 0,
            .emit_trailers = false,
        },
    };
}

const BodyCase = struct {
    body: Body,
    ordinary: Plan,
    head: Plan,
    permits_trailers: bool,
};

const body_cases = [_]BodyCase{
    bodyCase(.none, .{ .fixed = 0 }, false, false, false, .{ .fixed = 0 }, false, false),
    bodyCase(.{ .fixed = 0 }, .{ .fixed = 0 }, false, false, false, .{ .fixed = 0 }, false, false),
    bodyCase(.{ .fixed = 17 }, .{ .fixed = 17 }, true, false, true, .{ .fixed = 17 }, true, false),
    bodyCase(.stream_unknown, .chunked, true, true, true, .none, true, true),
    bodyCase(
        .{ .stream_exact = 0 },
        .{ .fixed = 0 },
        false,
        true,
        false,
        .{ .fixed = 0 },
        false,
        false,
    ),
    bodyCase(
        .{ .stream_exact = 17 },
        .{ .fixed = 17 },
        true,
        true,
        true,
        .{ .fixed = 17 },
        true,
        false,
    ),
};

fn bodyCase(
    body: Body,
    ordinary_framing: Framing,
    ordinary_send: bool,
    ordinary_invoke: bool,
    ordinary_content_type: bool,
    head_framing: Framing,
    head_content_type: bool,
    permits_trailers: bool,
) BodyCase {
    return .{
        .body = body,
        .ordinary = expectedPlan(
            ordinary_framing,
            ordinary_send,
            ordinary_invoke,
            ordinary_content_type,
        ),
        .head = expectedPlan(head_framing, false, false, head_content_type),
        .permits_trailers = permits_trailers,
    };
}

fn expectedPlan(framing: Framing, send: bool, invoke: bool, content_type: bool) Plan {
    return .{
        .framing = framing,
        .send_body = send,
        .invoke_stream = invoke,
        .emit_content_type = content_type,
        .emit_trailers = false,
    };
}

fn expected(input: Input, body_case: BodyCase) ?Plan {
    const code = @intFromEnum(input.status);
    if (code == 204 or code == 304) {
        if (input.trailers_declared) return null;
        return switch (input.body) {
            .none => expectedPlan(.none, false, false, false),
            else => null,
        };
    }
    if (code == 205) {
        if (input.trailers_declared) return null;
        return switch (input.body) {
            .none => expectedPlan(.{ .fixed = 0 }, false, false, false),
            else => null,
        };
    }
    if (input.trailers_declared and !body_case.permits_trailers) return null;
    var result = if (input.request_is_head) body_case.head else body_case.ordinary;
    result.emit_trailers = !input.request_is_head and
        input.trailers_declared and input.request_accepts_trailers;
    return result;
}

test "planner matches exhaustive independent cases" {
    const statuses = [_]status_module.Status{ .ok, .no_content, .reset_content, .not_modified };
    const booleans = [_]bool{ false, true };
    for (statuses) |response_status| {
        for (booleans) |head| {
            for (body_cases) |body_case| {
                for (booleans) |declared| {
                    for (booleans) |negotiated| {
                        const input = Input{
                            .status = response_status,
                            .request_is_head = head,
                            .request_accepts_trailers = negotiated,
                            .body = body_case.body,
                            .trailers_declared = declared,
                        };
                        if (expected(input, body_case)) |expected_plan| {
                            try std.testing.expectEqualDeep(expected_plan, try plan(input));
                        } else {
                            try std.testing.expectError(error.InvalidResponse, plan(input));
                        }
                    }
                }
            }
        }
    }
}

test "HEAD suppresses an unknown stream and its negotiated trailers" {
    const result = try plan(.{
        .status = .ok,
        .request_is_head = true,
        .request_accepts_trailers = true,
        .body = .stream_unknown,
        .trailers_declared = true,
    });
    try std.testing.expectEqualDeep(expectedPlan(.none, false, false, true), result);
}

test "zero exact stream runs without sending payload bytes" {
    const result = try plan(.{
        .status = .ok,
        .request_is_head = false,
        .request_accepts_trailers = false,
        .body = .{ .stream_exact = 0 },
        .trailers_declared = false,
    });
    try std.testing.expectEqualDeep(
        expectedPlan(.{ .fixed = 0 }, false, true, false),
        result,
    );
}

test "informational status cannot become a final response" {
    try std.testing.expectError(error.InvalidResponse, plan(.{
        .status = @enumFromInt(100),
        .request_is_head = false,
        .request_accepts_trailers = false,
        .body = .none,
        .trailers_declared = false,
    }));
}
