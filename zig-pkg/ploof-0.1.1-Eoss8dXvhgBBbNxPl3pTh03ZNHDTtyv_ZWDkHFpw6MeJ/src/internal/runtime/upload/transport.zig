const std = @import("std");
const linux = std.os.linux;

const token_table = @import("../io_uring/token_table.zig");
const completion_normalization = @import("transport_completion.zig");
const upload_file_table = @import("file_table.zig");
const validation = @import("transport_validation.zig");
const upload_io = @import("../../../upload_io.zig");
const reactor = @import("../reactor.zig");

const descriptor = validation.descriptor;
const target_leases_max = upload_file_table.operation_leases_max;
pub const Owner = upload_file_table.Owner;
pub const Error = upload_file_table.Error || token_table.InsertError || error{
    CancellationAlreadyPending,
    InvalidPhase,
    InvalidRequest,
    NotCancelable,
    TokenKindMismatch,
    TokenOwnerMismatch,
    TransportFatal,
    UnknownToken,
    WorkingDirectoryDenied,
};

const Phase = enum(u8) {
    prepared,
    submitted,
    terminal,
};

const Terminal = completion_normalization.Terminal;

pub fn Transport(
    comptime Cookie: type,
    comptime file_handle_capacity: usize,
    comptime target_capacity: u32,
) type {
    if (target_capacity == 0) {
        @compileError("PLOOF-E3498 upload transport target capacity must be positive");
    }
    if (target_capacity > std.math.maxInt(u32) / target_leases_max) {
        @compileError("PLOOF-E3499 upload transport lease capacity exceeds u32");
    }

    return struct {
        const Self = @This();
        const FileTable = upload_file_table.Table(
            file_handle_capacity,
            @as(usize, target_capacity) * target_leases_max,
        );

        pub const Delivery = struct {
            cookie: Cookie,
            completion: upload_io.IoCompletion,
        };

        const Target = struct {
            owner: Owner,
            cookie: Cookie,
            kind: upload_io.IoKind,
            handle: upload_io.FileHandle = .{ .token = 0 },
            open_kind: upload_io.OpenKind = .file,
            open_access: upload_io.Access = .read_only,
            open_create: upload_io.Create = .none,
            leases: [target_leases_max]FileTable.Lease = undefined,
            borrow_count: u2 = 0,
            phase: Phase = .prepared,
            cancel_token: u64 = 0,
            terminal: ?Terminal = null,
        };

        const Cancellation = struct {
            target_token: u64,
            phase: Phase = .prepared,
        };

        const TargetMap = token_table.Table(Target, target_capacity);
        const CancelMap = token_table.Table(Cancellation, target_capacity);

        pub const target_bytes = @sizeOf(Target);

        files: FileTable = .{},
        targets: TargetMap = TargetMap.init(),
        cancellations: CancelMap = CancelMap.init(),
        fatal_latched: bool = false,
        ownership_proven: bool = true,

        pub fn init() Self {
            return .{};
        }

        pub fn fatal(self: *const Self) bool {
            return self.fatal_latched;
        }

        pub fn ownershipProven(self: *const Self) bool {
            return self.ownership_proven and self.files.ownershipProven();
        }

        pub fn table(self: *Self) *FileTable {
            return &self.files;
        }

        pub fn tableConst(self: *const Self) *const FileTable {
            return &self.files;
        }

        pub fn nextCleanup(
            self: *const Self,
            cursor: *upload_file_table.CleanupCursor,
        ) ?upload_file_table.CleanupEntry {
            return self.files.nextCleanup(cursor);
        }

        pub fn pendingTargets(self: *const Self) u32 {
            return self.targets.count;
        }

        pub fn pendingCancellations(self: *const Self) u32 {
            return self.cancellations.count;
        }

        pub fn targetOwner(
            self: *const Self,
            token: reactor.OperationToken,
        ) ?Owner {
            const fields = token.fields() catch return null;
            const target_raw = if (fields.kind == .upload_cancel) blk: {
                const cancellation = self.cancellations.get(token.raw()) orelse return null;
                break :blk cancellation.target_token;
            } else token.raw();
            const target = self.targets.get(target_raw) orelse return null;
            return target.owner;
        }

        pub fn prepareTarget(
            self: *Self,
            owner: Owner,
            token: reactor.OperationToken,
            cookie: Cookie,
            request: upload_io.IoRequest,
        ) Error!reactor.Submission {
            if (self.fatal_latched) return error.TransportFatal;
            if (request.validate() != null) return error.InvalidRequest;
            try validation.validateTargetToken(
                owner,
                token,
                std.meta.activeTag(request),
            );
            if (self.targets.contains(token.raw())) return error.DuplicateToken;
            if (self.targets.count == target_capacity) return error.Full;

            var target = Target{
                .owner = owner,
                .cookie = cookie,
                .kind = std.meta.activeTag(request),
            };
            const operation = self.prepareOperation(owner, request, &target) catch |problem| {
                if (!self.cleanupPrepared(&target)) return error.TransportFatal;
                return problem;
            };
            const submission = reactor.Submission{ .token = token, .operation = operation };
            if (submission.validate() != null) {
                _ = self.cleanupPrepared(&target);
                self.latchFatal();
                return error.TransportFatal;
            }
            self.targets.insert(token.raw(), target) catch |problem| {
                if (!self.cleanupPrepared(&target)) return error.TransportFatal;
                return problem;
            };
            return submission;
        }

        pub fn prepareCancel(
            self: *Self,
            target_token: reactor.OperationToken,
            cancel_token: reactor.OperationToken,
        ) Error!reactor.Submission {
            if (self.fatal_latched) return error.TransportFatal;
            const cancel_fields = cancel_token.fields() catch return error.InvalidToken;
            if (cancel_fields.kind != .upload_cancel) return error.TokenKindMismatch;
            const target = self.targets.getPtr(target_token.raw()) orelse {
                return error.UnknownToken;
            };
            if (target.phase != .submitted) return error.NotCancelable;
            if (target.cancel_token != 0) return error.CancellationAlreadyPending;
            const submission = reactor.Submission{
                .token = cancel_token,
                .operation = .{ .upload_cancel = .{ .target = target_token } },
            };
            if (submission.validate() != null) return error.TokenOwnerMismatch;
            try self.cancellations.insert(cancel_token.raw(), .{
                .target_token = target_token.raw(),
            });
            target.cancel_token = cancel_token.raw();
            return submission;
        }

        pub fn markSubmitted(self: *Self, token: reactor.OperationToken) Error!void {
            const fields = token.fields() catch return error.InvalidToken;
            if (fields.kind == .upload_cancel) {
                const cancellation = self.cancellations.getPtr(token.raw()) orelse {
                    return error.UnknownToken;
                };
                if (cancellation.phase != .prepared) return error.InvalidPhase;
                cancellation.phase = .submitted;
                return;
            }
            if (!reactor.isUploadFileOperation(fields.kind)) return error.TokenKindMismatch;
            const target = self.targets.getPtr(token.raw()) orelse return error.UnknownToken;
            if (target.phase != .prepared) return error.InvalidPhase;
            target.phase = .submitted;
        }

        pub fn rollback(
            self: *Self,
            token: reactor.OperationToken,
        ) Error!?Delivery {
            const fields = token.fields() catch return error.InvalidToken;
            if (fields.kind == .upload_cancel) return self.rollbackCancel(token.raw());
            if (!reactor.isUploadFileOperation(fields.kind)) return error.TokenKindMismatch;
            const target = self.targets.get(token.raw()) orelse return error.UnknownToken;
            if (target.phase != .prepared or target.cancel_token != 0) {
                return error.InvalidPhase;
            }
            var mutable = target;
            if (!self.cleanupPrepared(&mutable)) return error.TransportFatal;
            _ = self.targets.remove(token.raw()) orelse {
                self.latchFatal();
                return error.TransportFatal;
            };
            return null;
        }

        fn rollbackCancel(self: *Self, token: u64) Error!?Delivery {
            const cancellation = self.cancellations.get(token) orelse return error.UnknownToken;
            if (cancellation.phase != .prepared) return error.InvalidPhase;
            const target = self.targets.getPtr(cancellation.target_token) orelse {
                self.latchFatal();
                return error.TransportFatal;
            };
            if (target.cancel_token != token) {
                self.latchFatal();
                return error.TransportFatal;
            }
            target.cancel_token = 0;
            _ = self.cancellations.remove(token) orelse {
                self.latchFatal();
                return error.TransportFatal;
            };
            return if (target.phase == .terminal)
                self.finishTarget(cancellation.target_token)
            else
                null;
        }

        fn prepareOperation(
            self: *Self,
            owner: Owner,
            request: upload_io.IoRequest,
            target: *Target,
        ) Error!reactor.Operation {
            return switch (request) {
                .open => |operation| .{ .file_open = try self.prepareOpen(
                    owner,
                    operation,
                    target,
                ) },
                .write => |operation| .{ .file_write = .{
                    .file = descriptor(try self.borrow(
                        operation.file,
                        owner,
                        .{ .kind = .file, .access = .write_only },
                        target,
                    )),
                    .bytes = operation.bytes,
                    .offset = operation.offset,
                } },
                .close => |operation| .{ .file_close = try self.prepareClose(
                    owner,
                    operation,
                    target,
                ) },
                .link => |operation| .{ .file_link = try self.prepareLink(
                    owner,
                    operation,
                    target,
                ) },
                .unlink => |operation| .{ .file_unlink = .{
                    .directory = descriptor(try self.borrow(
                        operation.directory,
                        owner,
                        .{ .kind = .directory, .access = .read_only },
                        target,
                    )),
                    .path = operation.path,
                } },
                .rename_no_replace => |operation| .{
                    .file_rename_no_replace = try self.prepareRename(owner, operation, target),
                },
                .sync => |operation| .{ .file_sync = .{
                    .file = descriptor(try self.borrowSync(operation.file, owner, target)),
                } },
            };
        }

        fn prepareOpen(
            self: *Self,
            owner: Owner,
            operation: upload_io.Open,
            target: *Target,
        ) Error!reactor.FileOpen {
            const base: reactor.FileOpenBase = switch (operation.base) {
                .working_directory => blk: {
                    if (owner.scope != .runtime or
                        owner.slot.index != reactor.upload_runtime_control_slot or
                        operation.access != .read_only or operation.kind != .directory or
                        operation.create != .none)
                    {
                        return error.WorkingDirectoryDenied;
                    }
                    break :blk .working_directory;
                },
                .handle => |handle| .{ .directory = descriptor(try self.borrow(
                    handle,
                    owner,
                    .{ .kind = .directory, .access = .read_only },
                    target,
                )) },
            };
            target.handle = if (operation.create == .exclusive)
                try self.files.reserveOpenAt(owner, operation.base, operation.path)
            else
                try self.files.reserveOpen(owner);
            target.open_kind = operation.kind;
            target.open_access = operation.access;
            target.open_create = operation.create;
            return .{
                .base = base,
                .path = operation.path,
                .access = operation.access,
                .create = operation.create,
                .kind = operation.kind,
                .no_follow = operation.no_follow,
                .mode = operation.mode,
                .resolve = operation.resolve,
            };
        }

        fn prepareClose(
            self: *Self,
            owner: Owner,
            operation: upload_io.Close,
            target: *Target,
        ) Error!reactor.FileClose {
            const value = try self.files.beginClose(operation.file, owner);
            target.handle = operation.file;
            return .{ .file = descriptor(value) };
        }

        fn prepareLink(
            self: *Self,
            owner: Owner,
            operation: upload_io.Link,
            target: *Target,
        ) Error!reactor.FileLink {
            const source = try self.borrow(
                operation.source,
                owner,
                .{ .kind = .file, .access = .read_only, .create = .anonymous },
                target,
            );
            const destination = try self.borrow(
                operation.target_directory,
                owner,
                .{ .kind = .directory, .access = .read_only },
                target,
            );
            return .{
                .source = descriptor(source),
                .target_directory = descriptor(destination),
                .target_path = operation.target_path,
            };
        }

        fn prepareRename(
            self: *Self,
            owner: Owner,
            operation: upload_io.RenameNoReplace,
            target: *Target,
        ) Error!reactor.FileRenameNoReplace {
            _ = try self.borrowOpenedAt(
                operation.source,
                owner,
                .{ .kind = .file, .access = .write_only, .create = .exclusive },
                .{ .handle = operation.source_directory },
                operation.source_path,
                target,
            );
            const source = try self.borrow(
                operation.source_directory,
                owner,
                .{ .kind = .directory, .access = .read_only },
                target,
            );
            const destination = try self.borrow(
                operation.target_directory,
                owner,
                .{ .kind = .directory, .access = .read_only },
                target,
            );
            return .{
                .source_directory = descriptor(source),
                .source_path = operation.source_path,
                .target_directory = descriptor(destination),
                .target_path = operation.target_path,
            };
        }

        fn borrow(
            self: *Self,
            handle: upload_io.FileHandle,
            owner: Owner,
            requirement: upload_file_table.Requirement,
            target: *Target,
        ) Error!upload_file_table.Descriptor {
            if (target.borrow_count == target.leases.len) {
                self.latchFatal();
                return error.TransportFatal;
            }
            const value = try self.files.borrow(handle, owner, requirement);
            target.leases[target.borrow_count] = value.lease;
            target.borrow_count += 1;
            return value.descriptor;
        }

        fn borrowOpenedAt(
            self: *Self,
            handle: upload_io.FileHandle,
            owner: Owner,
            requirement: upload_file_table.Requirement,
            base: upload_io.OpenBase,
            path: []const u8,
            target: *Target,
        ) Error!upload_file_table.Descriptor {
            if (target.borrow_count == target.leases.len) {
                self.latchFatal();
                return error.TransportFatal;
            }
            const value = try self.files.borrowOpenedAt(
                handle,
                owner,
                requirement,
                base,
                path,
            );
            target.leases[target.borrow_count] = value.lease;
            target.borrow_count += 1;
            return value.descriptor;
        }

        fn borrowSync(
            self: *Self,
            handle: upload_io.FileHandle,
            owner: Owner,
            target: *Target,
        ) Error!upload_file_table.Descriptor {
            return self.borrow(
                handle,
                owner,
                .{ .kind = .file, .access = .write_only },
                target,
            ) catch |problem| switch (problem) {
                error.WrongKind => self.borrow(
                    handle,
                    owner,
                    .{ .kind = .directory, .access = .read_only },
                    target,
                ),
                else => problem,
            };
        }

        pub fn complete(
            self: *Self,
            completion: reactor.Completion,
        ) Error!?Delivery {
            if (completion.validate() != null) {
                self.latchFatal();
                return error.TransportFatal;
            }
            const fields = completion.token.fields() catch {
                self.latchFatal();
                return error.TransportFatal;
            };
            if (fields.kind == .upload_cancel) return self.completeCancel(completion);
            if (!reactor.isUploadFileOperation(fields.kind)) {
                self.latchFatal();
                return error.TransportFatal;
            }
            return self.completeTarget(completion, fields.kind);
        }

        fn completeTarget(
            self: *Self,
            completion: reactor.Completion,
            kind: reactor.OperationKind,
        ) Error!?Delivery {
            const raw = completion.token.raw();
            const target = self.targets.getPtr(raw) orelse {
                self.latchFatal();
                return error.TransportFatal;
            };
            if (target.phase != .submitted or validation.expectedKind(target.kind) != kind) {
                self.latchFatal();
                return error.TransportFatal;
            }
            if (target.cancel_token != 0) {
                const cancellation = self.cancellations.get(target.cancel_token) orelse {
                    self.latchFatal();
                    return error.TransportFatal;
                };
                if (cancellation.target_token != raw) {
                    self.latchFatal();
                    return error.TransportFatal;
                }
            }
            target.terminal = self.normalizeTarget(target, completion.result);
            target.phase = .terminal;
            return self.finishTarget(raw);
        }

        fn completeCancel(
            self: *Self,
            completion: reactor.Completion,
        ) Error!?Delivery {
            const raw = completion.token.raw();
            const cancellation = self.cancellations.getPtr(raw) orelse {
                self.latchFatal();
                return error.TransportFatal;
            };
            const target = self.targets.getPtr(cancellation.target_token) orelse {
                self.latchFatal();
                return error.TransportFatal;
            };
            if (target.cancel_token != raw or target.phase == .prepared or
                cancellation.phase == .terminal)
            {
                self.latchFatal();
                return error.TransportFatal;
            }
            if (cancellation.phase == .prepared or completion.result == .failure) {
                self.latchFatal();
            }
            cancellation.phase = .terminal;
            return self.finishTarget(cancellation.target_token);
        }

        fn finishTarget(self: *Self, raw: u64) Error!?Delivery {
            const target = self.targets.get(raw) orelse {
                self.latchFatal();
                return error.TransportFatal;
            };
            if (target.phase != .terminal) return null;
            if (target.cancel_token != 0) {
                const cancellation = self.cancellations.get(target.cancel_token) orelse {
                    self.latchFatal();
                    return error.TransportFatal;
                };
                if (cancellation.phase != .terminal) return null;
                _ = self.cancellations.remove(target.cancel_token) orelse {
                    self.latchFatal();
                    return error.TransportFatal;
                };
            }
            _ = self.targets.remove(raw) orelse {
                self.latchFatal();
                return error.TransportFatal;
            };
            if (self.fatal_latched) return error.TransportFatal;
            return switch (target.terminal.?) {
                .completion => |value| .{ .cookie = target.cookie, .completion = value },
                .fatal => error.TransportFatal,
            };
        }

        fn normalizeTarget(
            self: *Self,
            target: *Target,
            result: reactor.CompletionResult,
        ) Terminal {
            const borrows_clean = self.releaseBorrows(target);
            const terminal = switch (target.kind) {
                .open => self.normalizeOpen(target, result),
                .close => self.normalizeClose(target, result),
                .write, .link, .unlink, .rename_no_replace, .sync => self.normalizePlain(result),
            };
            return if (borrows_clean) terminal else .fatal;
        }

        fn normalizeOpen(
            self: *Self,
            target: *Target,
            result: reactor.CompletionResult,
        ) Terminal {
            switch (result) {
                .failure => |failure| {
                    self.files.completeOpenFailure(target.handle, target.owner) catch {
                        self.latchFatal();
                        return .fatal;
                    };
                    return self.normalizeFailure(failure);
                },
                .success => |success| {
                    const raw_fd = switch (success) {
                        .file_open => |value| value.value,
                        else => unreachable,
                    };
                    self.files.completeOpenPositive(
                        target.handle,
                        target.owner,
                        raw_fd,
                        target.open_kind,
                        target.open_access,
                        target.open_create,
                    ) catch {
                        self.closeRejectedOpen(raw_fd, target);
                        return .fatal;
                    };
                    return .{ .completion = .{ .success = .{ .open = target.handle } } };
                },
            }
        }

        fn closeRejectedOpen(self: *Self, raw_fd: i32, target: *Target) void {
            if (linux.errno(linux.close(raw_fd)) != .SUCCESS) self.ownership_proven = false;
            self.files.completeOpenFailure(target.handle, target.owner) catch {
                self.ownership_proven = false;
            };
            self.latchFatal();
        }

        fn normalizeClose(
            self: *Self,
            target: *Target,
            result: reactor.CompletionResult,
        ) Terminal {
            switch (result) {
                .success => {
                    self.files.completeClose(target.handle, target.owner, .closed) catch {
                        self.latchFatal();
                        return .fatal;
                    };
                    return .{ .completion = .{ .success = .{ .close = {} } } };
                },
                .failure => |failure| {
                    if (failure == .canceled) {
                        self.files.completeClose(target.handle, target.owner, .canceled) catch {
                            self.latchFatal();
                            return .fatal;
                        };
                        return .{ .completion = .{ .failure = .canceled } };
                    }
                    self.files.completeClose(target.handle, target.owner, .uncertain) catch {};
                    self.latchFatal();
                    return .fatal;
                },
            }
        }

        fn normalizePlain(
            self: *Self,
            result: reactor.CompletionResult,
        ) Terminal {
            return self.normalizeTerminal(completion_normalization.normalizePlain(result));
        }

        fn normalizeFailure(self: *Self, failure: reactor.CompletionError) Terminal {
            return self.normalizeTerminal(completion_normalization.normalizeFailure(failure));
        }

        fn normalizeTerminal(self: *Self, terminal: Terminal) Terminal {
            if (std.meta.activeTag(terminal) == .fatal) self.latchFatal();
            return terminal;
        }

        fn releaseBorrows(self: *Self, target: *Target) bool {
            var clean = true;
            while (target.borrow_count != 0) {
                target.borrow_count -= 1;
                const lease = target.leases[target.borrow_count];
                self.files.releaseBorrow(lease, target.owner) catch {
                    clean = false;
                };
            }
            if (!clean) self.latchFatal();
            return clean;
        }

        fn cleanupPrepared(self: *Self, target: *Target) bool {
            var clean = self.releaseBorrows(target);
            if (target.handle.valid()) switch (target.kind) {
                .open => self.files.rollbackOpen(target.handle, target.owner) catch {
                    clean = false;
                },
                .close => self.files.completeClose(target.handle, target.owner, .canceled) catch {
                    clean = false;
                },
                else => {},
            };
            if (!clean) self.latchFatal();
            return clean;
        }

        fn latchFatal(self: *Self) void {
            self.fatal_latched = true;
            self.ownership_proven = false;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
