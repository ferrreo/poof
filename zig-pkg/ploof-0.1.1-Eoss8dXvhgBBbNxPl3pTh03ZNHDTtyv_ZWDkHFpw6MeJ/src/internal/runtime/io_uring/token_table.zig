const std = @import("std");

pub const VacantError = error{ DuplicateToken, Full };
pub const InsertError = error{ InvalidToken, DuplicateToken, Full };

pub fn Table(comptime Value: type, comptime capacity: u32) type {
    if (capacity == 0) @compileError("token table capacity must be positive");

    return struct {
        const Self = @This();

        pub const table_size = size(capacity);

        keys: [table_size]u64 = [_]u64{0} ** table_size,
        values: [table_size]Value = undefined,
        count: u32 = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn insert(self: *Self, token: u64, value: Value) InsertError!void {
            if (token == 0) return error.InvalidToken;
            const slot = vacant(&self.keys, token) catch |problem| return problem;
            if (self.count == capacity) return error.Full;
            self.keys[slot] = token;
            self.values[slot] = value;
            self.count += 1;
            self.assertInvariants();
        }

        pub fn contains(self: *const Self, token: u64) bool {
            return self.find(token) != null;
        }

        pub fn get(self: *const Self, token: u64) ?Value {
            const slot = self.find(token) orelse return null;
            return self.values[slot];
        }

        pub fn getPtr(self: *Self, token: u64) ?*Value {
            const slot = self.find(token) orelse return null;
            return &self.values[slot];
        }

        pub fn remove(self: *Self, token: u64) ?Value {
            var hole = self.find(token) orelse return null;
            const value = self.values[hole];
            var scan = next(hole, table_size);
            while (self.keys[scan] != 0) : (scan = next(scan, table_size)) {
                const home = index(self.keys[scan], table_size);
                if (distance(home, hole, table_size) >=
                    distance(home, scan, table_size)) continue;
                self.keys[hole] = self.keys[scan];
                self.values[hole] = self.values[scan];
                hole = scan;
            }
            self.keys[hole] = 0;
            self.values[hole] = undefined;
            self.count -= 1;
            self.assertInvariants();
            return value;
        }

        fn find(self: *const Self, token: u64) ?usize {
            if (token == 0) return null;
            var slot = index(token, table_size);
            for (0..table_size) |_| {
                if (self.keys[slot] == 0) return null;
                if (self.keys[slot] == token) return slot;
                slot = next(slot, table_size);
            }
            return null;
        }

        fn assertInvariants(self: *const Self) void {
            std.debug.assert(self.count <= capacity);
            var occupied: u32 = 0;
            for (self.keys) |token| occupied += @intFromBool(token != 0);
            std.debug.assert(occupied == self.count);
        }
    };
}

pub fn size(comptime capacity: u32) usize {
    const minimum: usize = @as(usize, capacity) * 2;
    return std.math.ceilPowerOfTwoAssert(usize, minimum);
}

pub fn index(token: u64, table_size: usize) usize {
    std.debug.assert(std.math.isPowerOfTwo(table_size));
    var hash = token;
    hash ^= hash >> 30;
    hash *%= 0xbf58_476d_1ce4_e5b9;
    hash ^= hash >> 27;
    hash *%= 0x94d0_49bb_1331_11eb;
    hash ^= hash >> 31;
    return @intCast(hash & (table_size - 1));
}

pub fn vacant(table: []const u64, token: u64) VacantError!usize {
    var slot = index(token, table.len);
    for (0..table.len) |_| {
        if (table[slot] == 0) return slot;
        if (table[slot] == token) return error.DuplicateToken;
        slot = next(slot, table.len);
    }
    return error.Full;
}

pub fn contains(table: []const u64, token: u64) bool {
    var slot = index(token, table.len);
    for (0..table.len) |_| {
        if (table[slot] == 0) return false;
        if (table[slot] == token) return true;
        slot = next(slot, table.len);
    }
    return false;
}

pub fn remove(table: []u64, token: u64) bool {
    var hole = index(token, table.len);
    for (0..table.len) |_| {
        if (table[hole] == token) break;
        if (table[hole] == 0) return false;
        hole = next(hole, table.len);
    } else return false;

    var scan = next(hole, table.len);
    for (0..table.len) |_| {
        if (table[scan] == 0) {
            table[hole] = 0;
            return true;
        }
        const home = index(table[scan], table.len);
        if (distance(home, hole, table.len) < distance(home, scan, table.len)) {
            table[hole] = table[scan];
            hole = scan;
        }
        scan = next(scan, table.len);
    }
    return false;
}

pub fn distance(home: usize, position: usize, table_size: usize) usize {
    return (position + table_size - home) & (table_size - 1);
}

fn next(position: usize, table_size: usize) usize {
    return (position + 1) & (table_size - 1);
}

test "token table shape and wrapped distance are bounded" {
    try std.testing.expectEqual(@as(usize, 8), size(4));
    try std.testing.expectEqual(@as(usize, 16), size(5));
    try std.testing.expect(index(7, 8) < 8);
    try std.testing.expectEqual(@as(usize, 2), distance(7, 1, 8));
}

test "token probes terminate for full and wrapped clusters" {
    var full = [_]u64{ 1, 2, 3, 4 };
    try std.testing.expectError(error.Full, vacant(&full, 5));
    try std.testing.expect(!contains(&full, 5));
    try std.testing.expect(!remove(&full, 5));

    var collision = [_]u64{0} ** 2;
    var collision_count: usize = 0;
    for (1..1_000) |candidate| {
        if (index(candidate, 8) != 7) continue;
        collision[collision_count] = candidate;
        collision_count += 1;
        if (collision_count == collision.len) break;
    }
    try std.testing.expectEqual(collision.len, collision_count);
    var wrapped = [_]u64{0} ** 8;
    wrapped[7] = collision[0];
    wrapped[0] = collision[1];
    try std.testing.expect(contains(&wrapped, collision[1]));
    try std.testing.expect(remove(&wrapped, collision[0]));
    try std.testing.expect(contains(&wrapped, collision[1]));
}

test "generic table repairs collision clusters without stale values" {
    const Value = struct { operation: u16 };
    const TestTable = Table(Value, 3);
    var tokens: [4]u64 = undefined;
    var token_count: usize = 0;
    for (1..10_000) |candidate| {
        if (index(candidate, TestTable.table_size) != TestTable.table_size - 1) continue;
        tokens[token_count] = candidate;
        token_count += 1;
        if (token_count == tokens.len) break;
    }
    try std.testing.expectEqual(tokens.len, token_count);

    var table = TestTable.init();
    try table.insert(tokens[0], .{ .operation = 10 });
    try table.insert(tokens[1], .{ .operation = 20 });
    try table.insert(tokens[2], .{ .operation = 30 });
    table.getPtr(tokens[1]).?.operation = 21;
    try std.testing.expectError(error.Full, table.insert(tokens[3], .{ .operation = 40 }));
    try std.testing.expectEqual(@as(u16, 10), table.remove(tokens[0]).?.operation);
    try std.testing.expect(!table.contains(tokens[0]));
    try std.testing.expectEqual(@as(?Value, null), table.get(tokens[0]));
    try std.testing.expectEqual(@as(u16, 21), table.get(tokens[1]).?.operation);
    try std.testing.expectEqual(@as(u16, 30), table.get(tokens[2]).?.operation);
    try table.insert(tokens[3], .{ .operation = 40 });
    try std.testing.expectEqual(@as(u16, 40), table.get(tokens[3]).?.operation);
}

test "generic table rejects invalid and duplicate tokens" {
    var table = Table(void, 1).init();
    try std.testing.expectError(error.InvalidToken, table.insert(0, {}));
    try table.insert(9, {});
    try std.testing.expectError(error.DuplicateToken, table.insert(9, {}));
    try std.testing.expect(table.contains(9));
    try std.testing.expect(table.remove(9) != null);
    try std.testing.expect(table.remove(9) == null);
}
