const std = @import("std");
const reactor = @import("../reactor.zig");

pub fn validateCancel(completion: reactor.Completion) error{BackendFailure}!void {
    if (completion.more) return error.BackendFailure;
    switch (completion.result) {
        .failure => return error.BackendFailure,
        .success => |success| switch (success) {
            .cancel => |result| switch (result) {
                .canceled, .not_found => {},
            },
            else => return error.BackendFailure,
        },
    }
}

pub fn completeClose(
    connection: anytype,
    completion: reactor.Completion,
) error{BackendFailure}!void {
    if (completion.more) return error.BackendFailure;
    switch (completion.result) {
        .failure => return error.BackendFailure,
        .success => |success| switch (success) {
            .close => {
                connection.socket_closed = true;
                connection.close_token = null;
            },
            else => return error.BackendFailure,
        },
    }
}

test "cancel completion accepts both outcomes and rejects failures and wrong success" {
    const token = try reactor.OperationToken.init(.{
        .kind = .cancel,
        .worker_index = 0,
        .slot_index = 1,
        .slot_generation = 1,
        .sequence = 1,
    });
    try validateCancel(.{
        .token = token,
        .result = .{ .success = .{ .cancel = .canceled } },
        .more = false,
    });
    try validateCancel(.{
        .token = token,
        .result = .{ .success = .{ .cancel = .not_found } },
        .more = false,
    });
    try std.testing.expectError(error.BackendFailure, validateCancel(.{
        .token = token,
        .result = .{ .failure = .backend_failure },
        .more = false,
    }));
    try std.testing.expectError(error.BackendFailure, validateCancel(.{
        .token = token,
        .result = .{ .success = .{ .send = 1 } },
        .more = false,
    }));
}

test "close completion transfers descriptor ownership only on exact success" {
    const token = try reactor.OperationToken.init(.{
        .kind = .close,
        .worker_index = 0,
        .slot_index = 1,
        .slot_generation = 1,
        .sequence = 1,
    });
    var connection = struct {
        socket_closed: bool,
        close_token: ?reactor.OperationToken,
    }{ .socket_closed = false, .close_token = token };
    try completeClose(&connection, .{
        .token = token,
        .result = .{ .success = .{ .close = {} } },
        .more = false,
    });
    try std.testing.expect(connection.socket_closed);
    try std.testing.expect(connection.close_token == null);
}
