const reactor = @import("../reactor.zig");
const worker_live_static = @import("../worker/live_static.zig");

pub fn Bridge(comptime Error: type) type {
    return struct {
        pub fn beginRoots(driver: anytype, now_ns: u64) Error!worker_live_static.Start {
            return driver.live_static.beginRoots(driver.operations.io, now_ns);
        }

        pub fn beginStop(driver: anytype) Error!worker_live_static.Start {
            return driver.live_static.beginStop(driver.operations.io);
        }

        pub fn handle(
            driver: anytype,
            completion: reactor.Completion,
            epoch_second: i64,
            now_ns: u64,
        ) Error!worker_live_static.Event {
            return driver.live_static.handle(driver, completion, epoch_second, now_ns);
        }

        pub fn rootsReady(driver: anytype) bool {
            return driver.live_static.rootsReady();
        }

        pub fn stopped(driver: anytype) bool {
            return driver.live_static.isStopped();
        }

        pub fn pending(driver: anytype) u16 {
            return driver.live_static.pendingOperations();
        }

        pub fn requests(driver: anytype) u16 {
            return driver.live_static.activeRequests();
        }

        pub fn startupDiagnostic(
            driver: anytype,
        ) ?worker_live_static.StartupDiagnostic {
            return driver.live_static.startupDiagnostic();
        }

        pub fn abort(driver: anytype) bool {
            return driver.live_static.abort(driver.storage);
        }
    };
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}
