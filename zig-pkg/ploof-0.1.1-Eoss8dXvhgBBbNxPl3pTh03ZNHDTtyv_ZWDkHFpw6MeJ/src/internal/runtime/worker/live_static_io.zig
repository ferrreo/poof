const std = @import("std");
const reactor = @import("../reactor.zig");

pub fn Operations(comptime Reactor: type, comptime Error: type) type {
    return struct {
        pub fn copyInitialPath(storage: anytype, slot: anytype, slot_index: u16) bool {
            const selected = switch (slot.intent.path) {
                .directory => |directory| directory.relative_path,
                .file => |file| file,
            };
            const path = if (selected.len == 0) "." else selected;
            if (path.len + 1 > storage.liveStaticPath(slot_index).len) return false;
            const output = storage.liveStaticPath(slot_index);
            @memcpy(output[0..path.len], path);
            output[path.len] = 0;
            slot.path_length = @intCast(path.len);
            return true;
        }

        pub fn submitIndex(
            self: anytype,
            driver: anytype,
            index: u16,
        ) Error!void {
            const slot = &self.slots[index];
            const directory = switch (slot.intent.path) {
                .directory => |value| value,
                .file => return error.StateInvariant,
            };
            const index_name = directory.index_name orelse return error.StateInvariant;
            const output = driver.storage.liveStaticPath(index);
            if (index_name.len + 1 > output.len) return error.StateInvariant;
            @memcpy(output[0..index_name.len], index_name);
            output[index_name.len] = 0;
            slot.path_length = @intCast(index_name.len);
            slot.index_lookup = true;
            const token = try nextToken(self, driver.operations.io, index, .file_open);
            driver.operations.io.submit(.{ .token = token, .operation = .{ .file_open = .{
                .base = .{ .directory = slot.file.? },
                .path = output[0..slot.path_length :0],
                .access = .read_only,
                .no_follow = true,
                .non_blocking = true,
                .resolve = .{
                    .beneath = true,
                    .no_symlinks = true,
                    .no_magic_links = true,
                    .no_mount_crossing = true,
                },
            } } }) catch return error.BackendFailure;
            slot.phase = .opening;
            slot.token = token;
        }

        pub fn submitOpen(self: anytype, driver: anytype, index: u16) Error!void {
            const slot = &self.slots[index];
            const root = self.roots[slot.intent.root_index].file orelse
                return error.StateInvariant;
            const path = driver.storage.liveStaticPath(index);
            const token = try nextToken(self, driver.operations.io, index, .file_open);
            driver.operations.io.submit(.{ .token = token, .operation = .{ .file_open = .{
                .base = .{ .directory = root },
                .path = path[0..slot.path_length :0],
                .access = .read_only,
                .no_follow = true,
                .non_blocking = true,
                .resolve = .{
                    .beneath = true,
                    .no_symlinks = true,
                    .no_magic_links = true,
                    .no_mount_crossing = true,
                },
            } } }) catch return error.BackendFailure;
            slot.phase = .opening;
            slot.token = token;
        }

        pub fn submitStat(self: anytype, driver: anytype, index: u16) Error!void {
            return submitStatForPhase(self, driver, index, .stating);
        }

        pub fn submitVerify(self: anytype, driver: anytype, index: u16) Error!void {
            return submitStatForPhase(self, driver, index, .verifying);
        }

        fn submitStatForPhase(
            self: anytype,
            driver: anytype,
            index: u16,
            phase: anytype,
        ) Error!void {
            const slot = &self.slots[index];
            slot.statx = std.mem.zeroes(@TypeOf(slot.statx));
            const token = try nextToken(self, driver.operations.io, index, .file_stat);
            driver.operations.io.submit(.{ .token = token, .operation = .{ .file_stat = .{
                .file = slot.file.?,
                .output = &slot.statx,
            } } }) catch return error.BackendFailure;
            slot.phase = phase;
            slot.token = token;
        }

        pub fn submitRead(self: anytype, driver: anytype, index: u16) Error!void {
            const slot = &self.slots[index];
            const buffer = driver.storage.liveStaticRead(index);
            const length: usize = @intCast(@min(slot.remaining, buffer.len));
            if (length == 0) return error.StateInvariant;
            const token = try nextToken(self, driver.operations.io, index, .file_read);
            driver.operations.io.submit(.{ .token = token, .operation = .{ .file_read = .{
                .file = slot.file.?,
                .bytes = buffer[0..length],
                .offset = slot.next_offset,
            } } }) catch return error.BackendFailure;
            slot.read_requested = @intCast(length);
            slot.phase = .reading;
            slot.token = token;
        }

        pub fn submitClose(self: anytype, driver: anytype, index: u16) Error!void {
            return submitCloseDescriptor(self, driver, index, self.slots[index].file.?);
        }

        pub fn submitDirectoryClose(
            self: anytype,
            driver: anytype,
            index: u16,
        ) Error!void {
            return submitCloseDescriptor(
                self,
                driver,
                index,
                self.slots[index].directory_file.?,
            );
        }

        fn submitCloseDescriptor(
            self: anytype,
            driver: anytype,
            index: u16,
            file: reactor.FileDescriptor,
        ) Error!void {
            const slot = &self.slots[index];
            const token = try nextToken(self, driver.operations.io, index, .file_close);
            driver.operations.io.submit(.{ .token = token, .operation = .{ .file_close = .{
                .file = file,
            } } }) catch return error.BackendFailure;
            slot.token = token;
        }

        pub fn submitCancel(
            self: anytype,
            io: *Reactor,
            index: u16,
            target: reactor.OperationToken,
        ) Error!void {
            const slot = &self.slots[index];
            const token = try nextToken(self, io, index, .file_cancel);
            io.submit(.{ .token = token, .operation = .{ .file_cancel = .{
                .target = target,
            } } }) catch return error.BackendFailure;
            slot.cancel_token = token;
        }

        fn nextToken(
            self: anytype,
            io: *Reactor,
            index: u16,
            kind: reactor.OperationKind,
        ) Error!reactor.OperationToken {
            const slot = &self.slots[index];
            var sequence = slot.sequence;
            for (0..4) |_| {
                const token = reactor.OperationToken.init(.{
                    .kind = kind,
                    .worker_index = self.worker_index,
                    .slot_index = reactor.live_static_request_slot_base + index,
                    .slot_generation = slot.generation,
                    .sequence = sequence,
                }) catch return error.StateInvariant;
                const next = reactor.nextSequence(sequence);
                if (!io.tokenActive(token)) {
                    slot.sequence = next;
                    return token;
                }
                sequence = next;
            }
            return error.StateInvariant;
        }
    };
}
