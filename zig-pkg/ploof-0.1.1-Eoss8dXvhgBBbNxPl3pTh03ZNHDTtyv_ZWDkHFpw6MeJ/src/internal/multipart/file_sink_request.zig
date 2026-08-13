const std = @import("std");

const config = @import("../../multipart/file_sink_config.zig");
const upload = @import("../../multipart/upload.zig");

const invalid_handle = upload.FileHandle{ .token = 0 };
const collision_attempts_max: u4 = 8;
const abort_close_cancellations_max: u4 = 8;

pub fn Request(comptime supplied: config.FileSinkConfig) type {
    @setEvalBranchQuota(100_000);
    const C = config.Resolved(supplied);

    return struct {
        pub const ploof_multipart_request_sink = true;
        pub const BeginInput = C.Key;
        pub const Summary = struct {
            storage_key: []const u8,
            bytes: u64,
        };
        pub const Error = config.FileIoError || config.NameError || C.Key.Error || error{
            ByteCountMismatch,
            CloseCancellationExhausted,
            StagingNameExhausted,
        };
        pub const LifecycleFailureSource = enum(u1) { sink, invalid_request };
        pub const io_requirements = C.io_requirements;
        pub const request_handles_max = C.request_handles_max;

        pub const Runtime = struct {
            root: upload.FileHandle,
            staging: upload.FileHandle = invalid_handle,
            generator: C.NameGenerator,
            live_anonymous: u32 = 0,
            live_named: u32 = 0,
            stop_error: ?config.FileIoError = null,
            stop_closing_root: bool = false,
            stopped: bool = false,
        };

        const Phase = enum(u8) {
            idle,
            begin_parent,
            begin_stage,
            writing,
            finished,
            commit_sync_file,
            commit_publish,
            commit_sync_staging,
            commit_sync_parent,
            commit_close_stage,
            commit_close_parent,
            committed,
            failed,
            abort_reopen_parent,
            abort_unlink_destination,
            abort_sync_parent,
            abort_unlink_stage,
            abort_sync_staging,
            abort_close_stage,
            abort_close_parent,
            aborted,
        };

        pub const State = struct {
            key: C.Key = undefined,
            temp_name: config.Name = config.Name.empty,
            parent: upload.FileHandle = invalid_handle,
            stage: upload.FileHandle = invalid_handle,
            bytes: u64 = 0,
            first_cleanup_error: ?Error = null,
            phase: Phase = .idle,
            parent_separator: usize = 0,
            collision_attempts: u4 = 0,
            abort_close_cancellations: u4 = 0,
            key_valid: bool = false,
            nested: bool = false,
            separator_hidden: bool = false,
            parent_owned: bool = false,
            anonymous_stage_live: bool = false,
            named_stage_live: bool = false,
            published: bool = false,
            parent_sync_pending: bool = false,
            staging_sync_pending: bool = false,
            reopen_attempted: bool = false,
            destination_unlink_attempted: bool = false,
            stage_unlink_attempted: bool = false,
            parent_sync_attempted: bool = false,
            staging_sync_attempted: bool = false,
            stage_close_attempted: bool = false,
            parent_close_attempted: bool = false,
            abort_close_cancellation_exhausted: bool = false,
        };

        pub const WriteState = struct {
            expected: u32 = 0,
            active: bool = false,
        };

        pub const initial_state: State = .{};
        pub const initial_write_state: WriteState = .{};

        pub fn report(runtime: *const Runtime) config.FileSinkReport {
            return .{
                .staging = C.startup_report.staging,
                .durability = C.startup_report.durability,
                .live_anonymous = runtime.live_anonymous,
                .live_named = runtime.live_named,
            };
        }

        pub fn lifecycleStateFailureSource(state: *const State) LifecycleFailureSource {
            return if (state.abort_close_cancellation_exhausted)
                .invalid_request
            else
                .sink;
        }

        pub fn begin(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(BeginInput),
        ) Error!upload.Poll(void) {
            return switch (event) {
                .start => |input| beginStart(runtime, state, input),
                .completion => |completion| beginComplete(runtime, state, completion),
            };
        }

        fn beginStart(
            runtime: *Runtime,
            state: *State,
            input: BeginInput,
        ) Error!upload.Poll(void) {
            std.debug.assert(state.phase == .idle);
            state.* = initial_state;
            state.key = try input.validatedCopy();
            state.key_valid = true;
            if (std.mem.lastIndexOfScalar(u8, state.key.bytes(), '/')) |slash| {
                state.nested = true;
                state.parent_separator = slash;
                state.phase = .begin_parent;
                return .{ .request = parentOpen(state, runtime.root) };
            }
            state.parent = runtime.root;
            return openStage(runtime, state);
        }

        fn beginComplete(
            runtime: *Runtime,
            state: *State,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(void) {
            return switch (state.phase) {
                .begin_parent => completeParentOpen(runtime, state, completion),
                .begin_stage => completeStageOpen(runtime, state, completion),
                else => unreachable,
            };
        }

        fn completeParentOpen(
            runtime: *Runtime,
            state: *State,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(void) {
            restoreParentSeparator(state);
            state.parent = openResult(completion) catch |problem| {
                state.phase = .failed;
                return problem;
            };
            state.parent_owned = true;
            return openStage(runtime, state);
        }

        fn openStage(runtime: *Runtime, state: *State) Error!upload.Poll(void) {
            state.phase = .begin_stage;
            if (comptime C.named) return openNamedStage(runtime, state);
            return .{ .request = .{ .open = .{
                .base = .{ .handle = state.parent },
                .path = ".",
                .access = .read_write,
                .create = .anonymous,
                .mode = C.config.mode,
            } } };
        }

        fn openNamedStage(runtime: *Runtime, state: *State) Error!upload.Poll(void) {
            if (state.collision_attempts == collision_attempts_max) {
                state.phase = .failed;
                return error.StagingNameExhausted;
            }
            state.temp_name = try runtime.generator.next(.stage);
            state.collision_attempts += 1;
            return .{ .request = .{ .open = .{
                .base = .{ .handle = runtime.staging },
                .path = state.temp_name.sentinel(),
                .access = .read_write,
                .create = .exclusive,
                .mode = C.config.mode,
            } } };
        }

        fn completeStageOpen(
            runtime: *Runtime,
            state: *State,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(void) {
            state.stage = openResult(completion) catch |problem| {
                if (comptime C.named) {
                    if (problem == error.AlreadyExists) return openNamedStage(runtime, state);
                }
                state.phase = .failed;
                return problem;
            };
            if (comptime C.named) {
                std.debug.assert(runtime.live_named != std.math.maxInt(u32));
                runtime.live_named += 1;
                state.named_stage_live = true;
            } else {
                std.debug.assert(runtime.live_anonymous != std.math.maxInt(u32));
                runtime.live_anonymous += 1;
                state.anonymous_stage_live = true;
            }
            state.phase = .writing;
            return .{ .done = {} };
        }

        pub fn write(
            _: *Runtime,
            state: *State,
            write_state: *WriteState,
            event: upload.PollEvent(upload.WriteInput),
        ) Error!upload.Poll(void) {
            return switch (event) {
                .start => |input| writeStart(state, write_state, input),
                .completion => |completion| writeComplete(write_state, completion),
            };
        }

        fn writeStart(
            state: *State,
            write_state: *WriteState,
            input: upload.WriteInput,
        ) upload.Poll(void) {
            std.debug.assert(state.phase == .writing);
            std.debug.assert(!write_state.active);
            std.debug.assert(input.bytes.len > 0 and input.bytes.len <= std.math.maxInt(u32));
            write_state.expected = @intCast(input.bytes.len);
            write_state.active = true;
            return .{ .request = .{ .write = .{
                .file = state.stage,
                .bytes = input.bytes,
                .offset = input.offset,
            } } };
        }

        fn writeComplete(
            write_state: *WriteState,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(void) {
            std.debug.assert(write_state.active);
            const written = writeResult(completion) catch |problem| {
                write_state.active = false;
                return problem;
            };
            write_state.active = false;
            if (written != write_state.expected) return error.ByteCountMismatch;
            return .{ .done = {} };
        }

        pub fn finish(
            _: *Runtime,
            state: *State,
            event: upload.PollEvent(upload.FinishInput),
        ) Error!upload.Poll(Summary) {
            return switch (event) {
                .start => |input| finishStart(state, input),
                .completion => unreachable,
            };
        }

        fn finishStart(state: *State, input: upload.FinishInput) upload.Poll(Summary) {
            std.debug.assert(state.phase == .writing);
            state.bytes = input.bytes;
            state.phase = .finished;
            return .{ .done = .{
                .storage_key = state.key.bytes(),
                .bytes = state.bytes,
            } };
        }

        pub fn commit(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            return switch (event) {
                .start => commitStart(runtime, state),
                .completion => |completion| commitComplete(runtime, state, completion),
            };
        }

        fn commitStart(runtime: *Runtime, state: *State) upload.Poll(void) {
            std.debug.assert(state.phase == .finished);
            if (comptime C.durable) {
                state.phase = .commit_sync_file;
                return syncRequest(state.stage);
            }
            return publishRequest(runtime, state);
        }

        fn commitComplete(
            runtime: *Runtime,
            state: *State,
            completion: upload.IoCompletion,
        ) Error!upload.Poll(void) {
            plainResult(completion, phaseIoKind(state.phase)) catch |problem| {
                state.phase = .failed;
                return problem;
            };
            return switch (state.phase) {
                .commit_sync_file => publishRequest(runtime, state),
                .commit_publish => afterPublish(runtime, state),
                .commit_sync_staging => afterStagingSync(state),
                .commit_sync_parent => afterParentSync(state),
                .commit_close_stage => afterStageClose(state),
                .commit_close_parent => afterParentClose(state),
                else => unreachable,
            };
        }

        fn publishRequest(runtime: *Runtime, state: *State) upload.Poll(void) {
            state.phase = .commit_publish;
            if (comptime C.named) return .{ .request = .{ .rename_no_replace = .{
                .source = state.stage,
                .source_directory = runtime.staging,
                .source_path = state.temp_name.sentinel(),
                .target_directory = state.parent,
                .target_path = basename(state),
            } } };
            return .{ .request = .{ .link = .{
                .source = state.stage,
                .target_directory = state.parent,
                .target_path = basename(state),
            } } };
        }

        fn afterPublish(runtime: *Runtime, state: *State) upload.Poll(void) {
            state.published = true;
            state.parent_sync_pending = C.durable;
            if (comptime C.named) {
                releaseNamed(runtime, state);
                state.staging_sync_pending = C.durable;
                if (comptime C.durable) {
                    state.phase = .commit_sync_staging;
                    return syncRequest(runtime.staging);
                }
            } else {
                releaseAnonymous(runtime, state);
            }
            if (comptime C.durable) {
                state.phase = .commit_sync_parent;
                return syncRequest(state.parent);
            }
            return closeStageRequest(state);
        }

        fn afterStagingSync(state: *State) upload.Poll(void) {
            state.staging_sync_pending = false;
            state.phase = .commit_sync_parent;
            return syncRequest(state.parent);
        }

        fn afterParentSync(state: *State) upload.Poll(void) {
            state.parent_sync_pending = false;
            return closeStageRequest(state);
        }

        fn closeStageRequest(state: *State) upload.Poll(void) {
            state.phase = .commit_close_stage;
            return closeRequest(state.stage);
        }

        fn afterStageClose(state: *State) upload.Poll(void) {
            state.stage = invalid_handle;
            if (state.parent_owned) {
                state.phase = .commit_close_parent;
                return closeRequest(state.parent);
            }
            state.phase = .committed;
            return .{ .done = {} };
        }

        fn afterParentClose(state: *State) upload.Poll(void) {
            state.parent = invalid_handle;
            state.parent_owned = false;
            state.phase = .committed;
            return .{ .done = {} };
        }

        pub fn abort(
            runtime: *Runtime,
            state: *State,
            event: upload.PollEvent(void),
        ) Error!upload.Poll(void) {
            switch (event) {
                .start => {
                    if (state.phase == .aborted) return .{ .done = {} };
                    beginAbort(state);
                },
                .completion => |completion| completeAbort(runtime, state, completion),
            }
            return nextAbort(runtime, state);
        }

        fn beginAbort(state: *State) void {
            restoreParentSeparator(state);
            state.first_cleanup_error = null;
            state.reopen_attempted = false;
            state.destination_unlink_attempted = false;
            state.stage_unlink_attempted = false;
            state.parent_sync_attempted = false;
            state.staging_sync_attempted = false;
            state.stage_close_attempted = false;
            state.parent_close_attempted = false;
        }

        fn nextAbort(runtime: *Runtime, state: *State) Error!upload.Poll(void) {
            if (state.abort_close_cancellation_exhausted) {
                state.phase = .failed;
                return error.CloseCancellationExhausted;
            }
            if ((state.published or (C.durable and state.parent_sync_pending)) and
                state.nested and !state.parent.valid() and !state.reopen_attempted)
            {
                state.phase = .abort_reopen_parent;
                state.reopen_attempted = true;
                return .{ .request = parentOpen(state, runtime.root) };
            }
            if (state.published and state.parent.valid() and
                !state.destination_unlink_attempted)
            {
                state.phase = .abort_unlink_destination;
                state.destination_unlink_attempted = true;
                return unlinkRequest(state.parent, basename(state));
            }
            if (comptime C.durable) if (state.parent_sync_pending and
                state.parent.valid() and !state.parent_sync_attempted)
            {
                state.phase = .abort_sync_parent;
                state.parent_sync_attempted = true;
                return syncRequest(state.parent);
            };
            if (comptime C.named) if (state.named_stage_live and
                !state.stage_unlink_attempted)
            {
                state.phase = .abort_unlink_stage;
                state.stage_unlink_attempted = true;
                return unlinkRequest(runtime.staging, state.temp_name.sentinel());
            };
            if (comptime C.durable) if (state.staging_sync_pending and
                !state.staging_sync_attempted)
            {
                state.phase = .abort_sync_staging;
                state.staging_sync_attempted = true;
                return syncRequest(runtime.staging);
            };
            if (state.stage.valid() and !state.stage_close_attempted) {
                state.phase = .abort_close_stage;
                state.stage_close_attempted = true;
                return closeRequest(state.stage);
            }
            if (state.parent_owned and state.parent.valid() and
                !state.parent_close_attempted)
            {
                state.phase = .abort_close_parent;
                state.parent_close_attempted = true;
                return closeRequest(state.parent);
            }
            if (state.first_cleanup_error) |problem| {
                state.phase = .failed;
                return problem;
            }
            state.phase = .aborted;
            return .{ .done = {} };
        }

        fn completeAbort(
            runtime: *Runtime,
            state: *State,
            completion: upload.IoCompletion,
        ) void {
            switch (state.phase) {
                .abort_reopen_parent => abortReopenComplete(state, completion),
                .abort_unlink_destination => abortDestinationComplete(state, completion),
                .abort_sync_parent => abortParentSyncComplete(state, completion),
                .abort_unlink_stage => abortStageComplete(runtime, state, completion),
                .abort_sync_staging => abortStagingSyncComplete(state, completion),
                .abort_close_stage => abortStageCloseComplete(runtime, state, completion),
                .abort_close_parent => abortParentCloseComplete(state, completion),
                else => unreachable,
            }
        }

        fn abortReopenComplete(state: *State, completion: upload.IoCompletion) void {
            restoreParentSeparator(state);
            state.parent = openResult(completion) catch |problem| {
                recordCleanupError(state, problem);
                return;
            };
            state.parent_owned = true;
        }

        fn abortDestinationComplete(state: *State, completion: upload.IoCompletion) void {
            if (cleanupResult(completion, .unlink, true)) |problem| {
                recordCleanupError(state, problem);
                return;
            }
            state.published = false;
            state.parent_sync_pending = C.durable;
        }

        fn abortParentSyncComplete(state: *State, completion: upload.IoCompletion) void {
            if (cleanupResult(completion, .sync, false)) |problem| {
                recordCleanupError(state, problem);
                return;
            }
            state.parent_sync_pending = false;
        }

        fn abortStageComplete(
            runtime: *Runtime,
            state: *State,
            completion: upload.IoCompletion,
        ) void {
            if (cleanupResult(completion, .unlink, true)) |problem| {
                recordCleanupError(state, problem);
                return;
            }
            releaseNamed(runtime, state);
            state.staging_sync_pending = C.durable;
        }

        fn abortStagingSyncComplete(state: *State, completion: upload.IoCompletion) void {
            if (cleanupResult(completion, .sync, false)) |problem| {
                recordCleanupError(state, problem);
                return;
            }
            state.staging_sync_pending = false;
        }

        fn abortStageCloseComplete(
            runtime: *Runtime,
            state: *State,
            completion: upload.IoCompletion,
        ) void {
            if (cleanupResult(completion, .close, false)) |problem| {
                abortCloseFailed(state, &state.stage_close_attempted, problem);
                return;
            }
            state.stage = invalid_handle;
            if (comptime !C.named) {
                if (state.anonymous_stage_live) releaseAnonymous(runtime, state);
            }
        }

        fn abortParentCloseComplete(state: *State, completion: upload.IoCompletion) void {
            if (cleanupResult(completion, .close, false)) |problem| {
                abortCloseFailed(state, &state.parent_close_attempted, problem);
                return;
            }
            state.parent = invalid_handle;
            state.parent_owned = false;
        }

        fn abortCloseFailed(
            state: *State,
            attempted: *bool,
            problem: config.FileIoError,
        ) void {
            recordCleanupError(state, problem);
            if (problem != error.Canceled) return;
            std.debug.assert(state.abort_close_cancellations < abort_close_cancellations_max);
            state.abort_close_cancellations += 1;
            if (state.abort_close_cancellations == abort_close_cancellations_max) {
                state.abort_close_cancellation_exhausted = true;
            } else {
                attempted.* = false;
            }
        }

        fn recordCleanupError(state: *State, problem: config.FileIoError) void {
            if (state.first_cleanup_error == null) state.first_cleanup_error = problem;
        }

        fn releaseNamed(runtime: *Runtime, state: *State) void {
            std.debug.assert(C.named and state.named_stage_live);
            std.debug.assert(runtime.live_named > 0);
            runtime.live_named -= 1;
            state.named_stage_live = false;
        }

        fn releaseAnonymous(runtime: *Runtime, state: *State) void {
            std.debug.assert(!C.named and state.anonymous_stage_live);
            std.debug.assert(runtime.live_anonymous > 0);
            runtime.live_anonymous -= 1;
            state.anonymous_stage_live = false;
        }

        fn parentOpen(state: *State, root: upload.FileHandle) upload.IoRequest {
            std.debug.assert(state.nested and !state.separator_hidden);
            state.key.storage[state.parent_separator] = 0;
            state.separator_hidden = true;
            const path = state.key.storage[0..state.parent_separator :0];
            return .{ .open = .{
                .base = .{ .handle = root },
                .path = path,
                .access = .read_only,
                .kind = .directory,
                .resolve = .{
                    .beneath = true,
                    .no_symlinks = true,
                    .no_magic_links = true,
                    .no_mount_crossing = true,
                },
            } };
        }

        fn restoreParentSeparator(state: *State) void {
            if (!state.separator_hidden) return;
            state.key.storage[state.parent_separator] = '/';
            state.separator_hidden = false;
        }

        fn basename(state: *State) [:0]const u8 {
            std.debug.assert(state.key_valid and !state.separator_hidden);
            const bytes = state.key.bytes();
            const start = if (state.nested) state.parent_separator + 1 else 0;
            return state.key.storage[start..bytes.len :0];
        }

        fn openResult(completion: upload.IoCompletion) config.FileIoError!upload.FileHandle {
            return switch (completion) {
                .failure => |problem| config.mapIoError(problem),
                .success => |success| switch (success) {
                    .open => |handle| handle,
                    else => unreachable,
                },
            };
        }

        fn writeResult(completion: upload.IoCompletion) config.FileIoError!u32 {
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
        ) config.FileIoError!void {
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
        ) ?config.FileIoError {
            return switch (completion) {
                .failure => |problem| if (not_found_ok and problem == .not_found)
                    null
                else
                    config.mapIoError(problem),
                .success => |success| success: {
                    std.debug.assert(std.meta.activeTag(success) == expected);
                    break :success null;
                },
            };
        }

        fn phaseIoKind(phase: Phase) upload.IoKind {
            return switch (phase) {
                .commit_sync_file, .commit_sync_staging, .commit_sync_parent => .sync,
                .commit_publish => if (C.named) .rename_no_replace else .link,
                .commit_close_stage, .commit_close_parent => .close,
                else => unreachable,
            };
        }

        fn syncRequest(handle: upload.FileHandle) upload.Poll(void) {
            return .{ .request = .{ .sync = .{ .file = handle } } };
        }

        fn closeRequest(handle: upload.FileHandle) upload.Poll(void) {
            return .{ .request = .{ .close = .{ .file = handle } } };
        }

        fn unlinkRequest(
            directory: upload.FileHandle,
            path: [:0]const u8,
        ) upload.Poll(void) {
            return .{ .request = .{ .unlink = .{
                .directory = directory,
                .path = path,
            } } };
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
