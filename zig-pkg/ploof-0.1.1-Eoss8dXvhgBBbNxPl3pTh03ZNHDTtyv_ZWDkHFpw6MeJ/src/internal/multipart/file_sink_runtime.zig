const std = @import("std");

const config = @import("../../multipart/file_sink_config.zig");
const request_module = @import("file_sink_request.zig");
const upload = @import("../../multipart/upload.zig");

const invalid_handle = upload.FileHandle{ .token = 0 };
const collision_attempts_max: u4 = 8;
const probe_payload = [_]u8{0xa5};

pub const startup_failure_code = "PLOOF-E3519";

pub const StartupPhase = enum(u8) {
    idle,
    open_root,
    open_staging,
    open_probe,
    write_probe,
    sync_probe,
    publish_probe,
    sync_published_staging,
    sync_published_root,
    unlink_published,
    sync_unlinked_root,
    close_probe,
    rollback_unlink_destination,
    rollback_unlink_source,
    rollback_sync_staging,
    rollback_sync_root,
    rollback_close_probe,
    rollback_close_staging,
    rollback_close_root,
    complete,
    failed,
};

pub const CleanupAction = enum(u2) {
    not_needed,
    pending,
    succeeded,
    failed,
};

pub const CleanupStatus = struct {
    destination_unlink: CleanupAction = .not_needed,
    source_unlink: CleanupAction = .not_needed,
    staging_sync: CleanupAction = .not_needed,
    root_sync: CleanupAction = .not_needed,
    probe_close: CleanupAction = .not_needed,
    staging_close: CleanupAction = .not_needed,
    root_close: CleanupAction = .not_needed,
    generator_cleared: bool = false,
};

pub fn Lifecycle(comptime supplied: config.FileSinkConfig) type {
    const C = config.Resolved(supplied);
    const RequestType = request_module.Request(supplied);

    return struct {
        const Self = @This();

        pub const Request = RequestType;
        pub const Runtime = Request.Runtime;
        pub const Error = Request.Error || error{
            LiveAnonymousStaging,
            LiveNamedStaging,
        };

        pub const StartupFailure = struct {
            code: []const u8,
            root: []const u8,
            mode: u16,
            durability: config.FileDurability,
            phase: StartupPhase,
            operation: upload.IoKind,
            cause: Error,
            cleanup: CleanupStatus,
            anonymous_compatibility_hint: bool,
        };

        pub const StartupState = struct {
            generator: C.NameGenerator = undefined,
            root: upload.FileHandle = invalid_handle,
            staging: upload.FileHandle = invalid_handle,
            probe: upload.FileHandle = invalid_handle,
            stage_name: config.Name = config.Name.empty,
            final_name: config.Name = config.Name.empty,
            cleanup: CleanupStatus = .{},
            primary: ?Error = null,
            phase: StartupPhase = .idle,
            primary_phase: StartupPhase = .idle,
            primary_operation: upload.IoKind = .open,
            stage_attempts: u4 = 0,
            final_attempts: u4 = 0,
            generator_live: bool = false,
            source_live: bool = false,
            destination_live: bool = false,
            staging_dirty: bool = false,
            root_dirty: bool = false,
        };

        pub const initial_startup_state: StartupState = .{};

        pub fn runtimeStart(
            state: *StartupState,
            event: upload.PollEvent(upload.RuntimeStartInput),
        ) Error!upload.Poll(Runtime) {
            return switch (event) {
                .start => |input| start(state, input),
                .completion => |completion| resumeStart(state, completion),
            };
        }

        fn start(
            state: *StartupState,
            input: upload.RuntimeStartInput,
        ) upload.Poll(Runtime) {
            std.debug.assert(state.phase == .idle);
            state.* = initial_startup_state;
            state.generator = C.NameGenerator.init(input.entropy, input.worker_index);
            state.generator_live = true;
            state.phase = .open_root;
            return request(.{ .open = .{
                .base = .working_directory,
                .path = C.root_z,
                .access = .read_only,
                .kind = .directory,
                .no_follow = true,
            } });
        }

        fn resumeStart(
            state: *StartupState,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(Runtime) {
            if (isRollback(state.phase)) {
                completeRollback(state, completion);
                return nextRollback(state);
            }
            return completeProbe(state, completion) catch |problem| {
                return beginFailure(state, problem);
            };
        }

        fn completeProbe(
            state: *StartupState,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(Runtime) {
            return switch (state.phase) {
                .open_root => afterRootOpen(state, completion),
                .open_staging => afterStagingOpen(state, completion),
                .open_probe => afterProbeOpen(state, completion),
                .write_probe => afterProbeWrite(state, completion),
                .sync_probe => afterProbeSync(state, completion),
                .publish_probe => afterPublish(state, completion),
                .sync_published_staging => afterPublishedStagingSync(state, completion),
                .sync_published_root => afterPublishedRootSync(state, completion),
                .unlink_published => afterPublishedUnlink(state, completion),
                .sync_unlinked_root => afterUnlinkedRootSync(state, completion),
                .close_probe => afterProbeClose(state, completion),
                else => unreachable,
            };
        }

        fn afterRootOpen(
            state: *StartupState,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(Runtime) {
            state.root = try openResult(completion);
            if (comptime C.named) {
                state.phase = .open_staging;
                return request(.{ .open = .{
                    .base = .{ .handle = state.root },
                    .path = C.staging_z.?,
                    .access = .read_only,
                    .kind = .directory,
                    .resolve = secureResolve(),
                } });
            }
            return openProbe(state);
        }

        fn afterStagingOpen(
            state: *StartupState,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(Runtime) {
            state.staging = try openResult(completion);
            return openProbe(state);
        }

        fn openProbe(state: *StartupState) Error!upload.Poll(Runtime) {
            state.phase = .open_probe;
            if (comptime !C.named) return request(.{ .open = .{
                .base = .{ .handle = state.root },
                .path = ".",
                .access = .read_write,
                .create = .anonymous,
                .mode = C.config.mode,
            } });
            if (state.stage_attempts == collision_attempts_max) {
                return error.StagingNameExhausted;
            }
            state.stage_name = try state.generator.next(.probe_stage);
            state.stage_attempts += 1;
            return request(.{ .open = .{
                .base = .{ .handle = state.staging },
                .path = state.stage_name.sentinel(),
                .access = .read_write,
                .create = .exclusive,
                .mode = C.config.mode,
            } });
        }

        fn afterProbeOpen(
            state: *StartupState,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(Runtime) {
            state.probe = openResult(completion) catch |problem| {
                if (comptime C.named) {
                    if (problem == error.AlreadyExists) return openProbe(state);
                }
                return problem;
            };
            state.source_live = C.named;
            state.phase = .write_probe;
            return request(.{ .write = .{
                .file = state.probe,
                .bytes = &probe_payload,
                .offset = 0,
            } });
        }

        fn afterProbeWrite(
            state: *StartupState,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(Runtime) {
            const written = try writeResult(completion);
            if (written != probe_payload.len) return error.ByteCountMismatch;
            if (comptime C.durable) {
                state.phase = .sync_probe;
                return sync(state.probe);
            }
            return publish(state);
        }

        fn afterProbeSync(
            state: *StartupState,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(Runtime) {
            try plainResult(completion, .sync);
            return publish(state);
        }

        fn publish(state: *StartupState) Error!upload.Poll(Runtime) {
            state.phase = .publish_probe;
            if (state.final_attempts == collision_attempts_max) {
                return error.NameSequenceExhausted;
            }
            state.final_name = try state.generator.next(.probe_final);
            state.final_attempts += 1;
            if (comptime C.named) return request(.{ .rename_no_replace = .{
                .source = state.probe,
                .source_directory = state.staging,
                .source_path = state.stage_name.sentinel(),
                .target_directory = state.root,
                .target_path = state.final_name.sentinel(),
            } });
            return request(.{ .link = .{
                .source = state.probe,
                .target_directory = state.root,
                .target_path = state.final_name.sentinel(),
            } });
        }

        fn afterPublish(
            state: *StartupState,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(Runtime) {
            plainResult(completion, if (C.named) .rename_no_replace else .link) catch |problem| {
                if (problem == error.AlreadyExists) return publish(state);
                return problem;
            };
            state.destination_live = true;
            state.root_dirty = C.durable;
            if (comptime C.named) {
                state.source_live = false;
                state.staging_dirty = C.durable;
                if (comptime C.durable) {
                    state.phase = .sync_published_staging;
                    return sync(state.staging);
                }
            }
            if (comptime C.durable) {
                state.phase = .sync_published_root;
                return sync(state.root);
            }
            return unlinkPublished(state);
        }

        fn afterPublishedStagingSync(
            state: *StartupState,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(Runtime) {
            try plainResult(completion, .sync);
            state.staging_dirty = false;
            state.phase = .sync_published_root;
            return sync(state.root);
        }

        fn afterPublishedRootSync(
            state: *StartupState,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(Runtime) {
            try plainResult(completion, .sync);
            state.root_dirty = false;
            return unlinkPublished(state);
        }

        fn unlinkPublished(state: *StartupState) upload.Poll(Runtime) {
            state.phase = .unlink_published;
            return request(.{ .unlink = .{
                .directory = state.root,
                .path = state.final_name.sentinel(),
            } });
        }

        fn afterPublishedUnlink(
            state: *StartupState,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(Runtime) {
            try plainResult(completion, .unlink);
            state.destination_live = false;
            state.root_dirty = C.durable;
            if (comptime C.durable) {
                state.phase = .sync_unlinked_root;
                return sync(state.root);
            }
            return closeProbe(state);
        }

        fn afterUnlinkedRootSync(
            state: *StartupState,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(Runtime) {
            try plainResult(completion, .sync);
            state.root_dirty = false;
            return closeProbe(state);
        }

        fn closeProbe(state: *StartupState) upload.Poll(Runtime) {
            state.phase = .close_probe;
            return request(.{ .close = .{ .file = state.probe } });
        }

        fn afterProbeClose(
            state: *StartupState,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(Runtime) {
            try plainResult(completion, .close);
            state.probe = invalid_handle;
            state.phase = .complete;
            const runtime = Runtime{
                .root = state.root,
                .staging = state.staging,
                .generator = state.generator,
            };
            state.generator.deinit();
            state.root = invalid_handle;
            state.staging = invalid_handle;
            state.generator_live = false;
            return .{ .done = runtime };
        }

        fn beginFailure(
            state: *StartupState,
            problem: Error,
        ) Error!upload.Poll(Runtime) {
            std.debug.assert(state.primary == null);
            state.primary = problem;
            state.primary_phase = state.phase;
            state.primary_operation = phaseOperation(state.phase);
            return nextRollback(state);
        }

        fn nextRollback(state: *StartupState) Error!upload.Poll(Runtime) {
            if (state.destination_live and state.cleanup.destination_unlink == .not_needed) {
                state.phase = .rollback_unlink_destination;
                state.cleanup.destination_unlink = .pending;
                return request(.{ .unlink = .{
                    .directory = state.root,
                    .path = state.final_name.sentinel(),
                } });
            }
            if (state.source_live and state.cleanup.source_unlink == .not_needed) {
                state.phase = .rollback_unlink_source;
                state.cleanup.source_unlink = .pending;
                return request(.{ .unlink = .{
                    .directory = state.staging,
                    .path = state.stage_name.sentinel(),
                } });
            }
            if (C.durable and state.staging_dirty and
                state.cleanup.staging_sync == .not_needed)
            {
                state.phase = .rollback_sync_staging;
                state.cleanup.staging_sync = .pending;
                return sync(state.staging);
            }
            if (C.durable and state.root_dirty and state.cleanup.root_sync == .not_needed) {
                state.phase = .rollback_sync_root;
                state.cleanup.root_sync = .pending;
                return sync(state.root);
            }
            if (state.probe.valid() and state.cleanup.probe_close == .not_needed) {
                state.phase = .rollback_close_probe;
                state.cleanup.probe_close = .pending;
                return request(.{ .close = .{ .file = state.probe } });
            }
            if (state.staging.valid() and state.cleanup.staging_close == .not_needed) {
                state.phase = .rollback_close_staging;
                state.cleanup.staging_close = .pending;
                return request(.{ .close = .{ .file = state.staging } });
            }
            if (state.root.valid() and state.cleanup.root_close == .not_needed) {
                state.phase = .rollback_close_root;
                state.cleanup.root_close = .pending;
                return request(.{ .close = .{ .file = state.root } });
            }
            clearGenerator(state);
            state.phase = .failed;
            return state.primary.?;
        }

        fn completeRollback(state: *StartupState, completion: upload.IoCompletion) void {
            switch (state.phase) {
                .rollback_unlink_destination => cleanupUnlink(
                    completion,
                    &state.cleanup.destination_unlink,
                    &state.destination_live,
                    &state.root_dirty,
                ),
                .rollback_unlink_source => cleanupUnlink(
                    completion,
                    &state.cleanup.source_unlink,
                    &state.source_live,
                    &state.staging_dirty,
                ),
                .rollback_sync_staging => cleanupSync(
                    completion,
                    &state.cleanup.staging_sync,
                    &state.staging_dirty,
                ),
                .rollback_sync_root => cleanupSync(
                    completion,
                    &state.cleanup.root_sync,
                    &state.root_dirty,
                ),
                .rollback_close_probe => cleanupClose(
                    completion,
                    &state.cleanup.probe_close,
                    &state.probe,
                ),
                .rollback_close_staging => cleanupClose(
                    completion,
                    &state.cleanup.staging_close,
                    &state.staging,
                ),
                .rollback_close_root => cleanupClose(
                    completion,
                    &state.cleanup.root_close,
                    &state.root,
                ),
                else => unreachable,
            }
        }

        fn cleanupUnlink(
            completion: upload.IoCompletion,
            status: *CleanupAction,
            live: *bool,
            dirty: *bool,
        ) void {
            if (cleanupResult(completion, .unlink, true)) {
                status.* = .failed;
            } else {
                status.* = .succeeded;
                live.* = false;
            }
            dirty.* = C.durable;
        }

        fn cleanupSync(
            completion: upload.IoCompletion,
            status: *CleanupAction,
            dirty: *bool,
        ) void {
            if (cleanupResult(completion, .sync, false)) {
                status.* = .failed;
            } else {
                status.* = .succeeded;
                dirty.* = false;
            }
        }

        fn cleanupClose(
            completion: upload.IoCompletion,
            status: *CleanupAction,
            handle: *upload.FileHandle,
        ) void {
            status.* = if (cleanupResult(completion, .close, false)) .failed else .succeeded;
            handle.* = invalid_handle;
        }

        pub fn startupFailure(state: *const StartupState) ?StartupFailure {
            const cause = state.primary orelse return null;
            return .{
                .code = startup_failure_code,
                .root = C.config.root,
                .mode = C.config.mode,
                .durability = C.config.durability.?,
                .phase = state.primary_phase,
                .operation = state.primary_operation,
                .cause = cause,
                .cleanup = state.cleanup,
                .anonymous_compatibility_hint = compatibilityHint(
                    state.primary_phase,
                    cause,
                ),
            };
        }

        pub fn runtimeStop(
            runtime: *Runtime,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            return switch (event) {
                .start => stopStart(runtime),
                .completion => |completion| stopComplete(runtime, completion),
            };
        }

        pub fn abandonRuntimeStart(state: *StartupState) void {
            clearGenerator(state);
        }

        pub fn abandonRuntimeStop(runtime: *Runtime) void {
            runtime.generator.deinit();
        }

        fn stopStart(runtime: *Runtime) Error!upload.Poll(void) {
            if (runtime.stopped) return .{ .done = {} };
            if (runtime.live_anonymous != 0) return error.LiveAnonymousStaging;
            if (runtime.live_named != 0) return error.LiveNamedStaging;
            runtime.stop_error = null;
            if (runtime.staging.valid()) {
                const handle = runtime.staging;
                runtime.staging = invalid_handle;
                runtime.stop_closing_root = false;
                return .{ .request = .{ .close = .{ .file = handle } } };
            }
            return stopRoot(runtime);
        }

        fn stopComplete(
            runtime: *Runtime,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(void) {
            if (stopResult(completion)) |_| {} else |problem| {
                if (runtime.stop_error == null) runtime.stop_error = problem;
            }
            if (!runtime.stop_closing_root) return stopRoot(runtime);
            runtime.generator.deinit();
            runtime.stopped = true;
            if (runtime.stop_error) |problem| return problem;
            return .{ .done = {} };
        }

        fn stopRoot(runtime: *Runtime) upload.Poll(void) {
            std.debug.assert(runtime.root.valid());
            const handle = runtime.root;
            runtime.root = invalid_handle;
            runtime.stop_closing_root = true;
            return .{ .request = .{ .close = .{ .file = handle } } };
        }

        fn compatibilityHint(phase: StartupPhase, cause: Error) bool {
            if (C.named) return false;
            if (phase != .open_probe and phase != .publish_probe) return false;
            return cause == error.Unsupported or cause == error.PermissionDenied or
                cause == error.InvalidResource or cause == error.CrossDevice;
        }

        fn clearGenerator(state: *StartupState) void {
            if (state.generator_live) {
                state.generator.deinit();
                state.generator_live = false;
            }
            state.cleanup.generator_cleared = true;
        }

        fn isRollback(phase: StartupPhase) bool {
            return switch (phase) {
                .rollback_unlink_destination,
                .rollback_unlink_source,
                .rollback_sync_staging,
                .rollback_sync_root,
                .rollback_close_probe,
                .rollback_close_staging,
                .rollback_close_root,
                => true,
                else => false,
            };
        }

        fn phaseOperation(phase: StartupPhase) upload.IoKind {
            return switch (phase) {
                .open_root, .open_staging, .open_probe => .open,
                .write_probe => .write,
                .sync_probe,
                .sync_published_staging,
                .sync_published_root,
                .sync_unlinked_root,
                => .sync,
                .publish_probe => if (C.named) .rename_no_replace else .link,
                .unlink_published => .unlink,
                .close_probe => .close,
                else => unreachable,
            };
        }

        fn secureResolve() upload.Resolve {
            return .{
                .beneath = true,
                .no_symlinks = true,
                .no_magic_links = true,
                .no_mount_crossing = true,
            };
        }

        fn request(io: upload.IoRequest) upload.Poll(Runtime) {
            return .{ .request = io };
        }

        fn sync(handle: upload.FileHandle) upload.Poll(Runtime) {
            return request(.{ .sync = .{ .file = handle } });
        }

        fn openResult(completion: upload.IoCompletion) Error!upload.FileHandle {
            return switch (completion) {
                .failure => |problem| config.mapIoError(problem),
                .success => |success| switch (success) {
                    .open => |handle| handle,
                    else => unreachable,
                },
            };
        }

        fn writeResult(completion: upload.IoCompletion) Error!u32 {
            return switch (completion) {
                .failure => |problem| config.mapIoError(problem),
                .success => |success| switch (success) {
                    .write => |written| written,
                    else => unreachable,
                },
            };
        }

        fn plainResult(
            completion: upload.IoCompletion,
            expected: upload.IoKind,
        ) Error!void {
            return switch (completion) {
                .failure => |problem| config.mapIoError(problem),
                .success => |success| {
                    std.debug.assert(std.meta.activeTag(success) == expected);
                },
            };
        }

        fn cleanupResult(
            completion: upload.IoCompletion,
            expected: upload.IoKind,
            not_found_ok: bool,
        ) bool {
            return switch (completion) {
                .failure => |problem| !(not_found_ok and problem == .not_found),
                .success => |success| success: {
                    std.debug.assert(std.meta.activeTag(success) == expected);
                    break :success false;
                },
            };
        }

        fn stopResult(completion: upload.IoCompletion) config.FileIoError!void {
            return switch (completion) {
                .failure => |problem| config.mapIoError(problem),
                .success => |success| {
                    std.debug.assert(std.meta.activeTag(success) == .close);
                },
            };
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
