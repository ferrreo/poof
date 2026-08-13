const std = @import("std");
const application = @import("../../../application.zig");
const reactor = @import("../reactor.zig");
const connection_send = @import("../connection/send.zig");
const stage = @import("live_static_stage.zig");

pub fn Handler(
    comptime App: type,
    comptime Storage: type,
    comptime Error: type,
    comptime BodyTransport: type,
    comptime ResponseTransport: type,
    comptime RequestIo: type,
) type {
    return struct {
        pub fn handle(
            self: anytype,
            driver: anytype,
            index: u16,
            completion: reactor.Completion,
            epoch_second: i64,
            now_ns: u64,
        ) Error!void {
            const slot = &self.slots[index];
            if (slot.cancel_token) |token| {
                if (token.eql(completion.token)) {
                    slot.cancel_token = null;
                    try stage.validateCancel(completion);
                    if (slot.abort_outcome == null) return error.StateInvariant;
                    if (slot.token == null) {
                        try settleClosing(self, driver, index, now_ns);
                    }
                    return;
                }
            }
            if (slot.token == null or !slot.token.?.eql(completion.token)) {
                return error.InvalidCompletion;
            }
            slot.token = null;
            if (slot.abort_outcome != null) {
                return completeAbortedOperation(self, driver, index, completion, now_ns);
            }
            return switch (slot.phase) {
                .opening => completeOpen(
                    self,
                    driver,
                    index,
                    completion,
                    epoch_second,
                    now_ns,
                ),
                .stating => completeStat(
                    self,
                    driver,
                    index,
                    completion,
                    epoch_second,
                    now_ns,
                ),
                .reading => completeRead(self, driver, index, completion, now_ns),
                .verifying => completeVerification(
                    self,
                    driver,
                    index,
                    completion,
                    now_ns,
                ),
                .closing_index_directory => completeIndexDirectoryClose(
                    self,
                    driver,
                    index,
                    completion,
                ),
                .closing_before_prepared => completePreparedClose(
                    self,
                    driver,
                    index,
                    completion,
                    now_ns,
                ),
                .closing_complete => completeFinalClose(
                    self,
                    driver,
                    index,
                    completion,
                    now_ns,
                ),
                .closing_abort, .closing_abort_directory => error.InvalidCompletion,
                .free, .sending_head, .sending_chunk => error.InvalidCompletion,
            };
        }

        fn completeOpen(
            self: anytype,
            driver: anytype,
            index: u16,
            completion: reactor.Completion,
            epoch_second: i64,
            now_ns: u64,
        ) Error!void {
            const slot = &self.slots[index];
            switch (completion.result) {
                .success => |success| switch (success) {
                    .file_open => |file| if (slot.index_lookup) {
                        slot.directory_file = slot.file orelse return error.StateInvariant;
                        slot.file = file;
                        slot.phase = .closing_index_directory;
                        try RequestIo.submitDirectoryClose(self, driver, index);
                        return;
                    } else {
                        slot.file = file;
                    },
                    else => return error.InvalidCompletion,
                },
                .failure => |problem| {
                    const resolution = stage.resolutionForOpenFailure(problem);
                    if (slot.index_lookup and slot.file != null) {
                        return prepareThenClose(self, driver, index, resolution);
                    }
                    return resolveAndStage(self, driver, index, resolution, now_ns);
                },
            }
            _ = epoch_second;
            try RequestIo.submitStat(self, driver, index);
        }

        fn completeStat(
            self: anytype,
            driver: anytype,
            index: u16,
            completion: reactor.Completion,
            epoch_second: i64,
            now_ns: u64,
        ) Error!void {
            switch (completion.result) {
                .failure => return prepareThenClose(self, driver, index, .internal_error),
                .success => |success| if (success != .file_stat) {
                    return error.InvalidCompletion;
                },
            }
            const slot = &self.slots[index];
            if (!slot.statx.mask.TYPE or !slot.statx.mask.SIZE or !slot.statx.mask.MTIME or
                !slot.statx.mask.INO)
            {
                return prepareThenClose(self, driver, index, .internal_error);
            }
            const mode = slot.statx.mode & 0o170000;
            if (mode == 0o040000) return handleDirectory(self, driver, index);
            if (mode != 0o100000) return prepareThenClose(self, driver, index, .not_found);
            if (!slot.index_lookup and slot.intent.path == .directory and
                slot.intent.path.directory.trailing_slash)
            {
                return prepareThenClose(self, driver, index, .not_found);
            }
            try prepareFile(self, driver, index, epoch_second, now_ns);
        }

        fn handleDirectory(self: anytype, driver: anytype, index: u16) Error!void {
            const slot = &self.slots[index];
            const directory = switch (slot.intent.path) {
                .file => return prepareThenClose(self, driver, index, .not_found),
                .directory => |value| value,
            };
            if (!directory.trailing_slash) {
                return prepareThenClose(self, driver, index, .redirect_directory);
            }
            if (directory.index_name == null) {
                return prepareThenClose(self, driver, index, .not_found);
            }
            try RequestIo.submitIndex(self, driver, index);
        }

        fn prepareFile(
            self: anytype,
            driver: anytype,
            index: u16,
            epoch_second: i64,
            now_ns: u64,
        ) Error!void {
            const slot = &self.slots[index];
            slot.identity = @TypeOf(slot.identity).from(&slot.statx);
            const resolution = application.LiveStaticResolution{ .file = .{
                .identity = .{
                    .device_major = slot.statx.dev_major,
                    .device_minor = slot.statx.dev_minor,
                    .inode = slot.statx.ino,
                    .size = slot.statx.size,
                    .mtime_seconds = slot.statx.mtime.sec,
                    .mtime_nanoseconds = slot.statx.mtime.nsec,
                },
                .message_epoch_second = epoch_second,
                .filename = driver.storage.liveStaticPath(index)[0..slot.path_length],
            } };
            const prepared = prepareApplication(self, driver, index, resolution) orelse return;
            switch (prepared.source) {
                .live_static_file => |file| {
                    slot.prepared = prepared;
                    slot.next_offset = file.offset;
                    slot.remaining = if (file.transfer_body) file.length else 0;
                    try stage.fileHead(App, driver, slot.request_index, prepared);
                    slot.phase = .sending_head;
                    try BodyTransport.beginFinal(
                        driver,
                        slot.connection_index,
                        prepared.close_connection,
                        now_ns,
                    );
                    if (driver.storage.connections[slot.connection_index].send_token == null) {
                        return error.StateInvariant;
                    }
                    slot.send_pending = true;
                },
                else => {
                    slot.prepared = prepared;
                    slot.prepared_valid = true;
                    slot.phase = .closing_before_prepared;
                    try RequestIo.submitClose(self, driver, index);
                },
            }
        }

        fn prepareThenClose(
            self: anytype,
            driver: anytype,
            index: u16,
            resolution: application.LiveStaticResolution,
        ) Error!void {
            const prepared = prepareApplication(self, driver, index, resolution) orelse return;
            const slot = &self.slots[index];
            slot.prepared = prepared;
            slot.prepared_valid = true;
            slot.phase = .closing_before_prepared;
            try RequestIo.submitClose(self, driver, index);
        }

        fn prepareApplication(
            self: anytype,
            driver: anytype,
            index: u16,
            resolution: application.LiveStaticResolution,
        ) ?application.Prepared {
            const slot = &self.slots[index];
            const request = &driver.storage.requests[slot.request_index];
            return App.__prepareLiveStatic(
                &request.workspace,
                slot.intent,
                resolution,
                driver.storage.responseWritable(slot.request_index),
            ) catch {
                driver.beginClose(slot.connection_index) catch {};
                return null;
            };
        }

        fn resolveAndStage(
            self: anytype,
            driver: anytype,
            index: u16,
            resolution: application.LiveStaticResolution,
            now_ns: u64,
        ) Error!void {
            const slot = &self.slots[index];
            const prepared = prepareApplication(self, driver, index, resolution) orelse return;
            const connection_index = slot.connection_index;
            const request_index = slot.request_index;
            driver.storage.requests[request_index].live_static_slot = null;
            self.release(driver.storage, index);
            try stage.normal(
                App,
                BodyTransport,
                driver,
                connection_index,
                request_index,
                prepared,
                now_ns,
            );
        }

        fn completeRead(
            self: anytype,
            driver: anytype,
            index: u16,
            completion: reactor.Completion,
            now_ns: u64,
        ) Error!void {
            const slot = &self.slots[index];
            const read = switch (completion.result) {
                .failure => {
                    try driver.beginCloseWithOutcome(slot.connection_index, .aborted);
                    return;
                },
                .success => |success| switch (success) {
                    .file_read => |value| value,
                    else => return error.InvalidCompletion,
                },
            };
            if (read == 0 or read > slot.read_requested or read > slot.remaining) {
                try driver.beginCloseWithOutcome(slot.connection_index, .exact_underrun);
                return;
            }
            slot.read_used = read;
            slot.next_offset += read;
            slot.remaining -= read;
            if (slot.remaining == 0) return RequestIo.submitVerify(self, driver, index);
            try sendRead(self, driver, index, now_ns);
        }

        fn completeVerification(
            self: anytype,
            driver: anytype,
            index: u16,
            completion: reactor.Completion,
            now_ns: u64,
        ) Error!void {
            const slot = &self.slots[index];
            switch (completion.result) {
                .failure => {
                    try driver.beginCloseWithOutcome(slot.connection_index, .exact_underrun);
                    return;
                },
                .success => |success| if (success != .file_stat) {
                    return error.InvalidCompletion;
                },
            }
            if (!slot.identity.matches(&slot.statx)) {
                try driver.beginCloseWithOutcome(slot.connection_index, .exact_underrun);
                return;
            }
            try sendRead(self, driver, index, now_ns);
        }

        fn sendRead(
            self: anytype,
            driver: anytype,
            index: u16,
            now_ns: u64,
        ) Error!void {
            const slot = &self.slots[index];
            const bytes = driver.storage.liveStaticRead(index)[0..slot.read_used];
            if (!driver.storage.commitBorrowedResponseBody(slot.request_index, bytes)) {
                return error.StateInvariant;
            }
            slot.phase = .sending_chunk;
            try driver.operations.retargetTimeout(
                driver.storage,
                slot.connection_index,
                now_ns,
                Storage.runtime_limits.timeouts.write_stall_ns,
            );
            try driver.operations.submitSend(
                driver.storage,
                slot.connection_index,
                try connection_send.bytes(driver.storage, slot.connection_index),
            );
            if (driver.storage.connections[slot.connection_index].send_token == null) {
                return error.StateInvariant;
            }
            slot.send_pending = true;
        }

        fn completeIndexDirectoryClose(
            self: anytype,
            driver: anytype,
            index: u16,
            completion: reactor.Completion,
        ) Error!void {
            try stage.validateClose(completion);
            self.slots[index].directory_file = null;
            try RequestIo.submitStat(self, driver, index);
        }

        fn completePreparedClose(
            self: anytype,
            driver: anytype,
            index: u16,
            completion: reactor.Completion,
            now_ns: u64,
        ) Error!void {
            try stage.validateClose(completion);
            const slot = &self.slots[index];
            slot.file = null;
            const prepared = slot.prepared;
            const connection_index = slot.connection_index;
            const request_index = slot.request_index;
            slot.prepared_valid = false;
            driver.storage.requests[request_index].live_static_slot = null;
            self.release(driver.storage, index);
            try stage.normal(
                App,
                BodyTransport,
                driver,
                connection_index,
                request_index,
                prepared,
                now_ns,
            );
        }

        fn completeFinalClose(
            self: anytype,
            driver: anytype,
            index: u16,
            completion: reactor.Completion,
            now_ns: u64,
        ) Error!void {
            try stage.validateClose(completion);
            const slot = &self.slots[index];
            slot.file = null;
            try finishCompleted(self, driver, index, now_ns);
        }

        fn completeAbortedOperation(
            self: anytype,
            driver: anytype,
            index: u16,
            completion: reactor.Completion,
            now_ns: u64,
        ) Error!void {
            const slot = &self.slots[index];
            switch (completion.result) {
                .failure => |problem| if ((slot.phase == .closing_abort or
                    slot.phase == .closing_abort_directory) and problem != .canceled)
                {
                    return error.BackendFailure;
                },
                .success => |success| switch (success) {
                    .file_open => |file| if (slot.index_lookup) {
                        slot.directory_file = slot.file orelse return error.StateInvariant;
                        slot.file = file;
                    } else {
                        slot.file = file;
                    },
                    .file_stat, .file_read => {},
                    .file_close => if (slot.phase == .closing_index_directory or
                        slot.phase == .closing_abort_directory)
                    {
                        slot.directory_file = null;
                    } else {
                        slot.file = null;
                    },
                    else => return error.InvalidCompletion,
                },
            }
            if (slot.cancel_token != null) return;
            try settleClosing(self, driver, index, now_ns);
        }

        pub fn settleClosing(
            self: anytype,
            driver: anytype,
            index: u16,
            now_ns: u64,
        ) Error!void {
            const slot = &self.slots[index];
            if (!slot.completion_won) return settleAbort(self, driver, index);
            if (slot.token != null or slot.cancel_token != null or slot.send_pending) return;
            if (slot.directory_file != null) {
                slot.phase = .closing_abort_directory;
                try RequestIo.submitDirectoryClose(self, driver, index);
                return;
            }
            if (slot.file != null) {
                slot.phase = .closing_complete;
                try RequestIo.submitClose(self, driver, index);
                return;
            }
            slot.abort_outcome = null;
            try finishCompleted(self, driver, index, now_ns);
        }

        pub fn settleAbort(self: anytype, driver: anytype, index: u16) Error!void {
            const slot = &self.slots[index];
            if (slot.token != null or slot.cancel_token != null or slot.send_pending) return;
            if (slot.directory_file != null) {
                slot.phase = .closing_abort_directory;
                try RequestIo.submitDirectoryClose(self, driver, index);
                return;
            }
            if (slot.file != null) {
                slot.phase = .closing_abort;
                try RequestIo.submitClose(self, driver, index);
                return;
            }
            finishAbort(self, driver, index);
        }

        pub fn finishCompleted(
            self: anytype,
            driver: anytype,
            index: u16,
            now_ns: u64,
        ) Error!void {
            const slot = &self.slots[index];
            if (slot.send_pending or slot.file != null or slot.directory_file != null or
                slot.token != null or
                slot.cancel_token != null)
            {
                return error.StateInvariant;
            }
            const connection_index = slot.connection_index;
            const request_index = slot.request_index;
            driver.storage.requests[request_index].live_static_slot = null;
            self.release(driver.storage, index);
            try ResponseTransport.completeAfterLive(driver, connection_index, now_ns);
        }

        pub fn finishAbort(self: anytype, driver: anytype, index: u16) void {
            const slot = &self.slots[index];
            std.debug.assert(!slot.send_pending);
            const connection_index = slot.connection_index;
            const request_index = slot.request_index;
            driver.storage.requests[request_index].live_static_slot = null;
            self.release(driver.storage, index);
            driver.maybeRelease(connection_index) catch {};
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
