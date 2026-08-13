const std = @import("std");

const multipart = @import("../../../multipart/upload.zig");
const support = @import("upload_runtime_registry_support.zig");

pub fn start(
    comptime App: type,
    comptime Error: type,
    self: anytype,
    storage: anytype,
    index: u16,
) Error!multipart.Poll(void) {
    inline for (App.UploadCatalog.sink_types, 0..) |Sink, sink_index| {
        if (index == sink_index) {
            var entropy: [32]u8 = undefined;
            defer std.crypto.secureZero(u8, &entropy);
            support.deriveEntropy(&self.runtime_entropy, index, &entropy);
            return storage.upload_registry.driver(Sink).startRuntime(.{
                .worker_index = self.worker_index,
                .entropy = &entropy,
            }) catch {
                capture(self, storage, Sink, index);
                return error.ApplicationFailure;
            };
        }
    }
    return error.StateInvariant;
}

pub fn resumeStart(
    comptime App: type,
    comptime Error: type,
    self: anytype,
    storage: anytype,
    index: u16,
    completion: multipart.IoCompletion,
) Error!multipart.Poll(void) {
    inline for (App.UploadCatalog.sink_types, 0..) |Sink, sink_index| {
        if (index == sink_index) {
            const poll = storage.upload_registry.driver(Sink).resumeStart(
                completion,
            ) catch {
                if (captureAllowed(self)) capture(self, storage, Sink, index);
                return error.ApplicationFailure;
            };
            if (captureAllowed(self)) capture(self, storage, Sink, index);
            return poll;
        }
    }
    return error.StateInvariant;
}

pub fn abandonStart(
    comptime App: type,
    self: anytype,
    storage: anytype,
    index: u16,
) bool {
    inline for (App.UploadCatalog.sink_types, 0..) |Sink, sink_index| {
        if (index == sink_index) {
            const abandoned = storage.upload_registry.driver(Sink).abandonStartRequest();
            if (abandoned and self.startup_diagnostic != null) {
                capture(self, storage, Sink, index);
            }
            return abandoned;
        }
    }
    return false;
}

pub fn stop(
    comptime App: type,
    comptime Error: type,
    storage: anytype,
    index: u16,
) Error!multipart.Poll(void) {
    inline for (App.UploadCatalog.sink_types, 0..) |Sink, sink_index| {
        if (index == sink_index) {
            return storage.upload_registry.driver(Sink).startStop() catch
                error.ApplicationFailure;
        }
    }
    return error.StateInvariant;
}

pub fn resumeStop(
    comptime App: type,
    comptime Error: type,
    storage: anytype,
    index: u16,
    completion: multipart.IoCompletion,
) Error!multipart.Poll(void) {
    inline for (App.UploadCatalog.sink_types, 0..) |Sink, sink_index| {
        if (index == sink_index) {
            return storage.upload_registry.driver(Sink).resumeStop(completion) catch
                error.ApplicationFailure;
        }
    }
    return error.StateInvariant;
}

pub fn abandonStop(comptime App: type, storage: anytype, index: u16) bool {
    inline for (App.UploadCatalog.sink_types, 0..) |Sink, sink_index| {
        if (index == sink_index) {
            return storage.upload_registry.driver(Sink).abandonStopRequest();
        }
    }
    return false;
}

fn capture(
    self: anytype,
    storage: anytype,
    comptime Sink: type,
    index: u16,
) void {
    const failure = storage.upload_registry.driver(Sink).startupFailure() orelse return;
    self.startup_diagnostic = .{
        .sink_registry_index = index,
        .failure = failure,
    };
    if (self.runtime_deadline_diagnostic) |deadline| {
        if (deadline.registry_index == index) {
            self.startup_diagnostic.?.failure.deadline = deadline.failure;
        }
    }
}

fn captureAllowed(self: anytype) bool {
    return !self.startup_cleanup_active or self.startup_diagnostic != null or
        self.runtime_deadline_diagnostic != null;
}

test {
    std.testing.refAllDecls(@This());
}
