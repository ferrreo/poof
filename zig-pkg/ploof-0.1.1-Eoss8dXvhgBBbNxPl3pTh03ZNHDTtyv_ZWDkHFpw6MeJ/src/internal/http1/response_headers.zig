const std = @import("std");
const limits = @import("limits.zig");
const media_type = @import("media_type.zig");
const response_field_rules = @import("response_field_rules.zig");
const syntax = @import("syntax.zig");

const field_overhead_bytes: usize = ": \r\n".len;

pub const MutationError = error{
    AliasedInput,
    AppendNotAllowed,
    InvalidHeader,
    ReservedHeader,
    ResponseHeadTooLarge,
};

const Entry = struct {
    name_offset: u32 = 0,
    name_length: u32 = 0,
    value_offset: u32 = 0,
    value_length: u32 = 0,
};

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub fn validateStaticSet(comptime name: []const u8, comptime value: []const u8) void {
    validatePairSyntax(name, value) catch |problem| @compileError(staticMessage(problem));
}

pub fn validateStaticAppend(comptime name: []const u8, comptime value: []const u8) void {
    validatePairSyntax(name, value) catch |problem| @compileError(staticMessage(problem));
    if (response_field_rules.isSingletonName(name)) {
        @compileError("PLOOF-E3044 static response header cannot append a singleton field");
    }
}

pub fn validateStaticRemove(comptime name: []const u8) void {
    validateNameSyntax(name) catch |problem| @compileError(staticMessage(problem));
}

pub fn Headers(comptime requested: limits.ResponseHeadLimits) type {
    const profile = comptime requested.validate();
    return struct {
        const Self = @This();
        const entries_capacity: usize = profile.fields_max;
        const storage_capacity: usize = profile.head_bytes_max;

        entries: [entries_capacity]Entry = [_]Entry{.{}} ** entries_capacity,
        storage: [storage_capacity]u8 = [_]u8{0} ** storage_capacity,
        entries_count: usize = 0,
        storage_used: usize = 0,
        serialized_bytes: usize = 0,
        logical_limits: limits.ResponseHeadLimits = profile,

        pub fn reset(self: *Self, comptime requested_limits: limits.ResponseHeadLimits) void {
            const selected = comptime validateSelectedLimits(requested_limits);
            self.clear();
            self.logical_limits = selected;
        }

        pub fn clear(self: *Self) void {
            self.entries_count = 0;
            self.storage_used = 0;
            self.serialized_bytes = 0;
        }

        pub fn selectedLimits(self: *const Self) limits.ResponseHeadLimits {
            return self.logical_limits;
        }

        pub fn len(self: *const Self) usize {
            return self.entries_count;
        }

        pub fn bytesUsed(self: *const Self) usize {
            return self.storage_used;
        }

        pub fn serializedBytes(self: *const Self) usize {
            return self.serialized_bytes;
        }

        pub fn at(self: *const Self, index: usize) Field {
            std.debug.assert(index < self.entries_count);
            return .{
                .name = self.entryName(self.entries[index]),
                .value = self.entryValue(self.entries[index]),
            };
        }

        pub fn get(self: *const Self, name: []const u8) ?[]const u8 {
            if (name.len > self.logical_limits.field_line_bytes_max) return null;
            var index: usize = 0;
            while (index < self.entries_count) : (index += 1) {
                const entry = self.entries[index];
                if (syntax.eqlIgnoreCase(self.entryName(entry), name)) {
                    return self.entryValue(entry);
                }
            }
            return null;
        }

        pub fn set(self: *Self, name: []const u8, value: []const u8) MutationError!void {
            const line_bytes = try self.validatePair(name, value);
            if (self.aliasesStorage(name) or self.aliasesStorage(value)) {
                return error.AliasedInput;
            }
            var first_match: ?usize = null;
            var matches: usize = 0;
            var removed_storage: usize = 0;
            var removed_serialized: usize = 0;
            self.measureMatches(
                name,
                &first_match,
                &matches,
                &removed_storage,
                &removed_serialized,
            );

            const next_count = self.entries_count - matches + 1;
            const next_storage = self.storage_used - removed_storage + name.len + value.len;
            const next_serialized = self.serialized_bytes - removed_serialized + line_bytes;
            try self.ensureFits(next_count, next_storage, next_serialized);

            const position = first_match orelse self.entries_count;
            if (matches != 0) self.removeMatchingUnchecked(name);
            self.insertUnchecked(position, name, value, line_bytes);
        }

        pub fn append(self: *Self, name: []const u8, value: []const u8) MutationError!void {
            const line_bytes = try self.validatePair(name, value);
            if (response_field_rules.isSingletonName(name)) return error.AppendNotAllowed;

            const next_count = self.entries_count + 1;
            const next_storage = self.storage_used + name.len + value.len;
            const next_serialized = self.serialized_bytes + line_bytes;
            try self.ensureFits(next_count, next_storage, next_serialized);
            self.insertUnchecked(self.entries_count, name, value, line_bytes);
        }

        pub fn remove(self: *Self, name: []const u8) MutationError!void {
            try self.validateName(name);
            if (self.aliasesStorage(name)) return error.AliasedInput;
            self.removeMatchingUnchecked(name);
        }

        fn aliasesStorage(self: *const Self, bytes: []const u8) bool {
            if (bytes.len == 0) return false;
            const storage_start = @intFromPtr(self.storage[0..].ptr);
            const storage_end = storage_start + storage_capacity;
            const bytes_start = @intFromPtr(bytes.ptr);
            const bytes_end = std.math.add(usize, bytes_start, bytes.len) catch return true;
            return bytes_start < storage_end and bytes_end > storage_start;
        }

        fn validatePair(
            self: *const Self,
            name: []const u8,
            value: []const u8,
        ) MutationError!usize {
            const line_bytes = try self.fieldLineBytes(name.len, value.len);
            if (name.len > self.logical_limits.field_line_bytes_max) {
                return error.InvalidHeader;
            }
            try validatePairSyntax(name, value);
            return line_bytes;
        }

        fn validateName(self: *const Self, name: []const u8) MutationError!void {
            if (name.len > self.logical_limits.field_line_bytes_max) {
                return error.InvalidHeader;
            }
            try validateNameSyntax(name);
        }

        fn fieldLineBytes(
            self: *const Self,
            name_bytes: usize,
            value_bytes: usize,
        ) MutationError!usize {
            if (name_bytes > std.math.maxInt(usize) - value_bytes) {
                return error.ResponseHeadTooLarge;
            }
            const content_bytes = name_bytes + value_bytes;
            if (content_bytes > std.math.maxInt(usize) - field_overhead_bytes) {
                return error.ResponseHeadTooLarge;
            }
            const line_bytes = content_bytes + field_overhead_bytes;
            if (line_bytes > self.logical_limits.field_line_bytes_max) {
                return error.ResponseHeadTooLarge;
            }
            return line_bytes;
        }

        fn ensureFits(
            self: *const Self,
            count: usize,
            stored: usize,
            serialized: usize,
        ) MutationError!void {
            if (count > self.logical_limits.fields_max or
                stored > self.logical_limits.head_bytes_max or
                serialized > self.logical_limits.head_bytes_max)
            {
                return error.ResponseHeadTooLarge;
            }
        }

        fn measureMatches(
            self: *const Self,
            name: []const u8,
            first: *?usize,
            count: *usize,
            stored: *usize,
            serialized: *usize,
        ) void {
            var index: usize = 0;
            while (index < self.entries_count) : (index += 1) {
                const entry = self.entries[index];
                if (!syntax.eqlIgnoreCase(self.entryName(entry), name)) continue;
                if (first.* == null) first.* = index;
                count.* += 1;
                stored.* += entry.name_length + entry.value_length;
                serialized.* += entry.name_length + entry.value_length + field_overhead_bytes;
            }
        }

        fn removeMatchingUnchecked(self: *Self, name: []const u8) void {
            var read_index: usize = 0;
            var write_index: usize = 0;
            var write_offset: usize = 0;
            var next_serialized: usize = 0;
            while (read_index < self.entries_count) : (read_index += 1) {
                const entry = self.entries[read_index];
                if (syntax.eqlIgnoreCase(self.entryName(entry), name)) continue;
                const record_bytes: usize = entry.name_length + entry.value_length;
                const source: usize = entry.name_offset;
                std.mem.copyForwards(
                    u8,
                    self.storage[write_offset..][0..record_bytes],
                    self.storage[source..][0..record_bytes],
                );
                self.entries[write_index] = movedEntry(entry, write_offset);
                next_serialized += record_bytes + field_overhead_bytes;
                write_index += 1;
                write_offset += record_bytes;
            }
            self.entries_count = write_index;
            self.storage_used = write_offset;
            self.serialized_bytes = next_serialized;
        }

        fn insertUnchecked(
            self: *Self,
            index: usize,
            name: []const u8,
            value: []const u8,
            line_bytes: usize,
        ) void {
            std.debug.assert(index <= self.entries_count);
            const offset: usize = if (index == self.entries_count)
                self.storage_used
            else
                self.entries[index].name_offset;
            const record_bytes = name.len + value.len;
            self.shiftStorageRight(offset, record_bytes);
            self.shiftEntriesRight(index, record_bytes);

            for (name, 0..) |byte, byte_index| {
                self.storage[offset + byte_index] = syntax.asciiLower(byte);
            }
            @memcpy(self.storage[offset + name.len ..][0..value.len], value);
            self.entries[index] = makeEntry(offset, name.len, value.len);
            self.entries_count += 1;
            self.storage_used += record_bytes;
            self.serialized_bytes += line_bytes;
        }

        fn shiftStorageRight(self: *Self, offset: usize, amount: usize) void {
            std.debug.assert(self.storage_used + amount <= storage_capacity);
            std.mem.copyBackwards(
                u8,
                self.storage[offset + amount ..][0 .. self.storage_used - offset],
                self.storage[offset..self.storage_used],
            );
        }

        fn shiftEntriesRight(self: *Self, index: usize, storage_delta: usize) void {
            var source = self.entries_count;
            while (source > index) {
                source -= 1;
                const entry = self.entries[source];
                self.entries[source + 1] = movedEntry(entry, entry.name_offset + storage_delta);
            }
        }

        fn entryName(self: *const Self, entry: Entry) []const u8 {
            const start: usize = entry.name_offset;
            return self.storage[start..][0..entry.name_length];
        }

        fn entryValue(self: *const Self, entry: Entry) []const u8 {
            const start: usize = entry.value_offset;
            return self.storage[start..][0..entry.value_length];
        }

        fn validateSelectedLimits(
            comptime requested_limits: limits.ResponseHeadLimits,
        ) limits.ResponseHeadLimits {
            const selected = requested_limits.validate();
            if (selected.head_bytes_max > profile.head_bytes_max or
                selected.field_line_bytes_max > profile.field_line_bytes_max or
                selected.fields_max > profile.fields_max)
            {
                @compileError(
                    "PLOOF-E3045 logical response-head limits exceed workspace maximum",
                );
            }
            return selected;
        }
    };
}

fn validatePairSyntax(name: []const u8, value: []const u8) MutationError!void {
    try validateNameSyntax(name);
    if (!validValue(value)) return error.InvalidHeader;
    if (syntax.eqlIgnoreCase(name, "content-type")) {
        _ = media_type.parse(value) catch return error.InvalidHeader;
    }
}

fn validateNameSyntax(name: []const u8) MutationError!void {
    if (name.len == 0 or !syntax.isToken(name)) return error.InvalidHeader;
    if (response_field_rules.isOwnedName(name)) return error.ReservedHeader;
}

fn staticMessage(problem: MutationError) []const u8 {
    return switch (problem) {
        error.InvalidHeader => "PLOOF-E3042 invalid static response header",
        error.ReservedHeader => "PLOOF-E3043 static response header uses a reserved field",
        else => "PLOOF-E3046 invalid static response header operation",
    };
}

fn validValue(value: []const u8) bool {
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn makeEntry(offset: usize, name_length: usize, value_length: usize) Entry {
    return .{
        .name_offset = @intCast(offset),
        .name_length = @intCast(name_length),
        .value_offset = @intCast(offset + name_length),
        .value_length = @intCast(value_length),
    };
}

fn movedEntry(entry: Entry, new_offset: usize) Entry {
    return makeEntry(new_offset, entry.name_length, entry.value_length);
}

const StandardHeaders = Headers(limits.standard_response_head_limits);

test "normalizes copied names and preserves insertion order" {
    var headers = StandardHeaders{};
    var name = [_]u8{ 'X', '-', 'B' };
    var value = [_]u8{ 'o', 'n', 'e' };
    try headers.set(&name, &value);
    try headers.set("Content-Type", "text/plain");
    try headers.append("X-A", "two");
    name[0] = 'Q';
    value[0] = 'z';

    try expectField(&headers, 0, "x-b", "one");
    try expectField(&headers, 1, "content-type", "text/plain");
    try expectField(&headers, 2, "x-a", "two");
    try std.testing.expectEqualStrings("one", headers.get("X-B").?);
}

test "set replaces duplicates at their first position" {
    var headers = StandardHeaders{};
    try headers.append("x-a", "1");
    try headers.append("x-many", "old-a");
    try headers.append("x-b", "2");
    try headers.append("X-Many", "old-b");
    try headers.append("x-c", "3");

    try headers.set("X-MANY", "new");

    try std.testing.expectEqual(@as(usize, 4), headers.len());
    try expectField(&headers, 0, "x-a", "1");
    try expectField(&headers, 1, "x-many", "new");
    try expectField(&headers, 2, "x-b", "2");
    try expectField(&headers, 3, "x-c", "3");
}

test "append keeps Set-Cookie physical lines separate" {
    var headers = StandardHeaders{};
    try headers.append("Set-Cookie", "a=1; HttpOnly");
    try headers.append("set-cookie", "b=2; Secure");

    try expectField(&headers, 0, "set-cookie", "a=1; HttpOnly");
    try expectField(&headers, 1, "set-cookie", "b=2; Secure");
}

test "remove deletes every matching value and compacts storage" {
    var headers = StandardHeaders{};
    try headers.append("x-many", "a");
    try headers.append("x-keep", "b");
    try headers.append("X-MANY", "c");
    try headers.remove("x-MaNy");

    try std.testing.expectEqual(@as(usize, 1), headers.len());
    try expectField(&headers, 0, "x-keep", "b");
    try std.testing.expectEqual(@as(usize, "x-keep".len + 1), headers.bytesUsed());
}

test "reserved names reject every generic mutation transactionally" {
    for (response_field_rules.owned_names) |name| {
        var headers = StandardHeaders{};
        try headers.set("x-keep", "yes");
        const before = headers;
        try std.testing.expectError(error.ReservedHeader, headers.set(name, "x"));
        try std.testing.expectEqualDeep(before, headers);
        try std.testing.expectError(error.ReservedHeader, headers.append(name, "x"));
        try std.testing.expectEqualDeep(before, headers);
        try std.testing.expectError(error.ReservedHeader, headers.remove(name));
        try std.testing.expectEqualDeep(before, headers);
    }
}

test "singleton append and invalid input leave storage unchanged" {
    var headers = StandardHeaders{};
    try headers.set("x-keep", "yes");
    for (response_field_rules.singleton_names) |name| {
        const before = headers;
        const value = if (syntax.eqlIgnoreCase(name, "content-type"))
            media_type.text.bytes()
        else
            "x";
        try std.testing.expectError(error.AppendNotAllowed, headers.append(name, value));
        try std.testing.expectEqualDeep(before, headers);
    }

    const invalid_names = [_][]const u8{ "", "bad name", "bad:name", "bad\x80" };
    for (invalid_names) |name| {
        const before = headers;
        try std.testing.expectError(error.InvalidHeader, headers.set(name, "x"));
        try std.testing.expectEqualDeep(before, headers);
    }

    const invalid_values = [_][]const u8{ "bad\tvalue", "bad\r", "bad\n", "bad\x00", "bad\x7f" };
    for (invalid_values) |value| {
        const before = headers;
        try std.testing.expectError(error.InvalidHeader, headers.set("x-test", value));
        try std.testing.expectEqualDeep(before, headers);
    }
    try headers.set("x-empty", "");
}

test "Content-Type mutations require one valid media type" {
    var headers = StandardHeaders{};
    try headers.set("x-keep", "yes");
    const invalid = [_][]const u8{
        "",
        "text",
        "text/plain; charset=\"unterminated",
        "text/plain\r\nx-injected: yes",
    };
    for (invalid) |value| {
        const before = headers;
        try std.testing.expectError(error.InvalidHeader, headers.set("Content-Type", value));
        try std.testing.expectEqualDeep(before, headers);
        try std.testing.expectError(error.InvalidHeader, headers.append("Content-Type", value));
        try std.testing.expectEqualDeep(before, headers);
    }
    try headers.set("Content-Type", "application/problem+json; profile=\"v1\"");
    try std.testing.expectError(
        error.AppendNotAllowed,
        headers.append("Content-Type", "text/plain"),
    );
}

test "line count and storage bounds reject before mutation" {
    const LineHeaders = Headers(.{
        .head_bytes_max = 64,
        .field_line_bytes_max = 8,
        .fields_max = 4,
    });
    var line_headers = LineHeaders{};
    const line_before = line_headers;
    try std.testing.expectError(
        error.ResponseHeadTooLarge,
        line_headers.set("name", "x"),
    );
    try std.testing.expectEqualDeep(line_before, line_headers);

    const CountHeaders = Headers(.{
        .head_bytes_max = 64,
        .field_line_bytes_max = 16,
        .fields_max = 1,
    });
    var count_headers = CountHeaders{};
    try count_headers.append("x", "a");
    const count_before = count_headers;
    try std.testing.expectError(
        error.ResponseHeadTooLarge,
        count_headers.append("y", "b"),
    );
    try std.testing.expectEqualDeep(count_before, count_headers);

    const StorageHeaders = Headers(.{
        .head_bytes_max = 12,
        .field_line_bytes_max = 12,
        .fields_max = 4,
    });
    var storage_headers = StorageHeaders{};
    try storage_headers.append("x", "a");
    try storage_headers.append("y", "b");
    const storage_before = storage_headers;
    try std.testing.expectError(
        error.ResponseHeadTooLarge,
        storage_headers.append("z", ""),
    );
    try std.testing.expectEqualDeep(storage_before, storage_headers);
}

test "reset selects smaller logical line count and byte bounds transactionally" {
    const MaximumHeaders = Headers(.{
        .head_bytes_max = 128,
        .field_line_bytes_max = 64,
        .fields_max = 8,
    });
    var headers = MaximumHeaders{};

    const line_limits = comptime limits.ResponseHeadLimits{
        .head_bytes_max = 64,
        .field_line_bytes_max = 8,
        .fields_max = 4,
    };
    headers.reset(line_limits);
    try expectLogicalLimitFailure(&headers, "name", "x");

    const count_limits = comptime limits.ResponseHeadLimits{
        .head_bytes_max = 64,
        .field_line_bytes_max = 16,
        .fields_max = 1,
    };
    headers.reset(count_limits);
    try headers.append("x", "a");
    try expectLogicalLimitFailure(&headers, "y", "b");

    const head_limits = comptime limits.ResponseHeadLimits{
        .head_bytes_max = 12,
        .field_line_bytes_max = 12,
        .fields_max = 4,
    };
    headers.reset(head_limits);
    try headers.append("x", "a");
    try headers.append("y", "b");
    try expectLogicalLimitFailure(&headers, "z", "c");
    try std.testing.expectEqualDeep(head_limits, headers.selectedLimits());

    headers.reset(.{
        .head_bytes_max = 128,
        .field_line_bytes_max = 64,
        .fields_max = 8,
    });
    try std.testing.expectEqual(@as(usize, 0), headers.len());
    try headers.append("name", "x");
}

test "set and remove reject self aliases while append safely copies a borrowed value" {
    var headers = StandardHeaders{};
    try headers.append("x", "first");
    try headers.append("y", "middle");
    try headers.append("x", "last");

    const borrowed_name = headers.at(0).name;
    const before_remove = headers;
    try std.testing.expectError(error.AliasedInput, headers.remove(borrowed_name));
    try std.testing.expectEqualDeep(before_remove, headers);

    const borrowed_value = headers.get("y").?;
    const before_set = headers;
    try std.testing.expectError(error.AliasedInput, headers.set("z", borrowed_value));
    try std.testing.expectEqualDeep(before_set, headers);

    try headers.append("z", borrowed_value);
    try expectField(&headers, 3, "z", "middle");
}

fn expectField(
    headers: *const StandardHeaders,
    index: usize,
    expected_name: []const u8,
    expected_value: []const u8,
) !void {
    const field = headers.at(index);
    try std.testing.expectEqualStrings(expected_name, field.name);
    try std.testing.expectEqualStrings(expected_value, field.value);
}

fn expectLogicalLimitFailure(headers: anytype, name: []const u8, value: []const u8) !void {
    const before = headers.*;
    try std.testing.expectError(error.ResponseHeadTooLarge, headers.append(name, value));
    try std.testing.expectEqualDeep(before, headers.*);
}
