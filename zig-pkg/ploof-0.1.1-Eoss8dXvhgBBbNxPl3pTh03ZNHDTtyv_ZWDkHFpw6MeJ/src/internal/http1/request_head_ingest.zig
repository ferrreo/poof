const std = @import("std");
const Status = @import("status.zig").Status;

pub const ScanState = union(enum) {
    need_more,
    complete,
    rejected: Status,
};

pub fn scanInput(comptime limits: anytype, decoder: anytype, input: []const u8) ScanState {
    var cursor: usize = 0;
    if (decoder.bytes_count != 0 and
        decoder.bytes_storage[decoder.bytes_count - 1] == '\r')
    {
        if (consumeAfterCr(limits, decoder, input, &cursor)) |state| return state;
    }
    while (cursor < input.len) {
        const scan_end = cursor + @min(input.len - cursor, available(limits, decoder));
        const special = std.mem.indexOfAnyPos(
            u8,
            input[0..scan_end],
            cursor,
            "\r\n",
        ) orelse scan_end;
        if (special != cursor) {
            const plain_count = special - cursor;
            cursor += plain_count;
            if (appendPlain(limits, decoder, plain_count)) |status| {
                return .{ .rejected = status };
            }
            continue;
        }
        if (input[cursor] == '\n') {
            cursor += 1;
            decoder.bytes_count += 1;
            decoder.line_bytes += 1;
            return .{ .rejected = .bad_request };
        }
        cursor += 1;
        if (appendPlain(limits, decoder, 1)) |status| return .{ .rejected = status };
        if (consumeAfterCr(limits, decoder, input, &cursor)) |state| return state;
    }
    return .need_more;
}

fn available(comptime limits: anytype, decoder: anytype) usize {
    const line_max = if (decoder.request_line)
        limits.request_line_bytes_max
    else
        limits.field_line_bytes_max;
    const line_room = line_max - decoder.line_bytes;
    const head_room = limits.head_bytes_max - decoder.bytes_count;
    return @min(line_room, head_room);
}

fn appendPlain(comptime limits: anytype, decoder: anytype, count: usize) ?Status {
    std.debug.assert(count != 0);
    const line_max = if (decoder.request_line)
        limits.request_line_bytes_max
    else
        limits.field_line_bytes_max;
    const line_room = line_max - decoder.line_bytes;
    const head_room = limits.head_bytes_max - decoder.bytes_count;
    const until_rejection = @min(line_room, head_room);
    const appended = @min(count, until_rejection);
    decoder.bytes_count += appended;
    decoder.line_bytes += appended;
    if (count < until_rejection) return null;
    if (line_room <= head_room) {
        return if (decoder.request_line) .uri_too_long else .request_header_fields_too_large;
    }
    return .request_header_fields_too_large;
}

fn consumeAfterCr(
    comptime limits: anytype,
    decoder: anytype,
    input: []const u8,
    cursor: *usize,
) ?ScanState {
    if (cursor.* == input.len) return .need_more;
    const byte = input[cursor.*];
    cursor.* += 1;
    decoder.bytes_count += 1;
    decoder.line_bytes += 1;
    if (byte != '\n') return .{ .rejected = .bad_request };
    if (decoder.request_line) {
        decoder.request_line = false;
        decoder.line_bytes = 0;
    } else if (decoder.line_bytes == 2) {
        return .complete;
    } else {
        decoder.line_bytes = 0;
    }
    if (capacityStatus(limits, decoder)) |status| return .{ .rejected = status };
    return null;
}

fn capacityStatus(comptime limits: anytype, decoder: anytype) ?Status {
    const line_max = if (decoder.request_line)
        limits.request_line_bytes_max
    else
        limits.field_line_bytes_max;
    if (decoder.line_bytes >= line_max) {
        return if (decoder.request_line) .uri_too_long else .request_header_fields_too_large;
    }
    if (decoder.bytes_count >= limits.head_bytes_max) {
        return .request_header_fields_too_large;
    }
    return null;
}
