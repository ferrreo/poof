const std = @import("std");
const address = @import("../../../address.zig");
const application_finite_output = @import("../../application/finite_output.zig");
const body_api = @import("../../../body.zig");
const forwarding = @import("../../../forwarding.zig");
const http1_limits = @import("../../http1/limits.zig");
const request_head = @import("../../http1/request_head.zig");
const connection_chunked_body = @import("../connection/chunked_body.zig");
const connection_proxy_protocol = @import("../connection/proxy_protocol.zig");
const config = @import("../config.zig");
const reactor = @import("../reactor.zig");
const slot_pool = @import("../slot_pool.zig");
const body_storage = @import("body_storage.zig");
const worker_body_pool = @import("body_pool.zig");
const worker_chunked_pool = @import("chunked_pool.zig");
const worker_response_gzip = @import("response_gzip.zig");
const worker_html_storage = @import("html_storage.zig");
const worker_metrics_lease = @import("metrics_lease.zig");
const worker_response_storage = @import("response_storage.zig");
const worker_stream_lifecycle = @import("stream_lifecycle.zig");
const worker_storage_release = @import("storage_release.zig");
const worker_storage_pools = @import("storage_pools.zig");
const worker_storage_init = @import("storage_init.zig");
const worker_storage_chunked = @import("storage_chunked.zig");
const worker_storage_records = @import("storage_records.zig");
const worker_storage_regions = @import("storage_regions.zig");
const worker_storage_types = @import("storage_types.zig");
const storage_slab = @import("storage_slab.zig");
pub const InitError = worker_storage_init.Error;
pub const ConnectionPhase = worker_storage_types.ConnectionPhase;
pub const RequestPhase = worker_storage_types.RequestPhase;
pub const AcquireResult = worker_storage_types.AcquireResult;
pub const BodyAcquireResult = worker_body_pool.AcquireResult;

pub const BodyAccessError = body_storage.AccessError;
pub const ResponseSource = worker_response_storage.Source;
pub const ChunkedAccessError = worker_storage_types.ChunkedAccessError;
pub const BodyResetIssue = worker_storage_types.BodyResetIssue;
pub const ConnectionReleaseIssue = worker_storage_release.ConnectionReleaseIssue;
pub const RequestReleaseIssue = worker_storage_release.RequestReleaseIssue;
pub fn Storage(comptime App: type, comptime requested_limits: config.Limits) type {
    const limits = config.Limits.validate(requested_limits);
    if (!@hasDecl(App, "Workspace")) {
        @compileError("worker storage application must expose Workspace");
    }
    const Workspace = App.Workspace;
    const RouteSearchWorkspace = if (@hasDecl(App, "RouteSearchWorkspace"))
        App.RouteSearchWorkspace
    else
        struct {};
    const UploadRegistry = if (@hasDecl(App, "UploadRegistry"))
        App.UploadRegistry
    else
        struct {};
    const body_workspace_bytes_unaligned: u64 = if (@hasDecl(App, "body_workspace_bytes_max"))
        App.body_workspace_bytes_max
    else
        0;
    const body_workspace_alignment: u32 = if (@hasDecl(App, "body_workspace_alignment"))
        App.body_workspace_alignment
    else
        1;
    if (!std.math.isPowerOfTwo(body_workspace_alignment)) {
        @compileError("body workspace alignment must be a power of two");
    }
    const body_workspace_bytes_u64 = std.mem.alignForward(
        u64,
        body_workspace_bytes_unaligned,
        body_workspace_alignment,
    );
    if (body_workspace_bytes_u64 > std.math.maxInt(u32)) {
        @compileError(
            "PLOOF-E3082 buffered decoded body limit exceeds u32; use streaming body API",
        );
    }
    const body_workspace_bytes: u32 = @intCast(body_workspace_bytes_u64);
    const body_enabled = body_workspace_bytes != 0;
    const stream_enabled = if (@hasDecl(App, "stream_enabled")) App.stream_enabled else false;
    const metrics_enabled = @hasDecl(App, "open_metrics_enabled") and App.open_metrics_enabled;
    const finite_output_enabled = if (@hasDecl(App, "finite_response_chunks_enabled"))
        App.finite_response_chunks_enabled
    else
        false;
    const FiniteOutput = if (finite_output_enabled) application_finite_output.Plan else struct {};
    const Html = worker_html_storage.Configuration(App, limits);
    const html_json_scratch_bytes = Html.json_scratch_bytes_max;
    const HtmlJsonScratchStorage = if (html_json_scratch_bytes != 0) []u8 else struct {};
    const upload_async_sink_present = if (@hasDecl(App, "upload_async_sink_present"))
        App.upload_async_sink_present
    else
        false;
    const live_static_slots: u16 = if (@hasDecl(App, "live_static_slots_per_worker"))
        App.live_static_slots_per_worker
    else
        0;
    const live_static_path_bytes: u32 = if (live_static_slots == 0)
        0
    else
        @as(u32, App.live_static_path_bytes_max) + 257;
    const live_static_read_bytes: u32 = if (live_static_slots == 0)
        0
    else
        App.live_static_read_bytes_per_slot;
    const LiveStaticPathStorage = if (live_static_slots != 0) []u8 else struct {};
    const LiveStaticReadStorage = if (live_static_slots != 0) []u8 else struct {};
    const Gzip = body_storage.GzipStorage(body_storage.gzipEnabled(App, body_enabled), limits);
    const HeadDecoder = request_head.Decoder(http1_limits.standard_request_head_limits);
    const decoded_path_bytes: u32 =
        http1_limits.standard_request_head_limits.request_line_bytes_max;
    const ReceiveFlags = worker_storage_records.ReceiveFlags;
    const ConnectionRecord = struct {
        receive_token: ?reactor.OperationToken = null,
        send_token: ?reactor.OperationToken = null,
        timeout_token: ?reactor.OperationToken = null,
        close_token: ?reactor.OperationToken = null,
        generation: u16 = 1,
        sequence: u16 = 1,
        inflight_operations: u16 = 0,
        continue_cursor: u8 = 0,
        receive_flags: ReceiveFlags = .{},
        socket: reactor.Socket = .{ .value = 0 },
        transport_peer: address.Endpoint = .{
            .address = .{ .ipv4 = .{ 0, 0, 0, 0 } },
            .port = 0,
        },
        connection_peer: address.Endpoint = .{
            .address = .{ .ipv4 = .{ 0, 0, 0, 0 } },
            .port = 0,
        },
        connection_source: forwarding.ConnectionSource = .transport,
        proxy_destination: ?address.Endpoint = null,
        proxy_protocol: connection_proxy_protocol.State = .{},
        socket_closed: bool = false,
        timeout_deadline_ns: u64 = 0,
        active_request: ?u16 = null,
        decoded_path_used: u32 = 0,
        pipeline_read: u32 = 0,
        pipeline_write: u32 = 0,
        pipeline_high_water: u32 = 0,
        phase: ConnectionPhase = .free,
        close_after_response: bool = false,
        receive_terminal_reaped: bool = false,
        head_decoder: HeadDecoder = HeadDecoder.init(),
    };
    const BodyLease = body_storage.Lease(body_enabled);
    const StreamTransport = worker_storage_records.StreamTransport(
        App,
        stream_enabled,
    );
    const RequestFlags = worker_storage_records.RequestFlags;
    const MetricsLease = worker_metrics_lease.Lease(metrics_enabled);
    const RequestRecord = struct {
        phase: RequestPhase = .free,
        generation: u16 = 1,
        sequence: u16 = 1,
        connection_index: u16 = 0,
        chunked_workspace_index: ?u16 = null,
        gzip_lease: Gzip.LeaseField = if (Gzip.thread_count != 0) null else {},
        /// Committed length for either response source.
        response_used: u32 = 0,
        response_sent: u32 = 0,
        response_high_water: u32 = 0,
        response_chain: worker_response_storage.Chain = .{},
        response_chunk_index: u16 = worker_response_storage.chunk_none,
        response_chunk_offset: u16 = 0,
        response_static_body: ?[*]const u8 = null,
        finite_output: FiniteOutput = if (finite_output_enabled) .contiguous else .{},
        flags: RequestFlags = .{},
        workspace: Workspace = .{},
        body: BodyLease = .{},
        stream_transport: StreamTransport = .{},
        metrics: MetricsLease = .{},
        live_static_slot: if (live_static_slots != 0) ?u16 else struct {} =
            if (live_static_slots != 0) null else .{},
    };
    const BodyPool = body_storage.Pool(body_enabled);

    const ChunkedState = connection_chunked_body.Receiver(limits.chunked);
    const ChunkedPool = worker_chunked_pool.Pool(ChunkedState, body_enabled);
    const ResponseChunkPool = worker_response_storage.ChunkPool;
    const ResponseGzip = worker_response_gzip.Configuration(App, limits.response_bytes_per_request);
    const ResponseHelpers = worker_response_storage.Helpers(
        limits.response_bytes_per_request,
        body_enabled,
        body_workspace_bytes,
        limits.body_workspace_slots,
    );
    const StreamWakes = worker_stream_lifecycle.Lifecycle(
        stream_enabled or metrics_enabled,
        limits.request_slots,
    );
    const BodyHelpers = body_storage.Helpers(
        body_enabled,
        body_workspace_bytes,
        limits.body_workspace_slots,
        limits.chunked_workspace_slots,
        ChunkedState,
    );
    const ReleaseActions = worker_storage_release.Actions(
        body_enabled,
        BodyHelpers,
        ChunkedState,
    );

    const layout = comptime storage_slab.make(
        ConnectionRecord,
        RequestRecord,
        worker_response_storage.ChunkNode,
        ChunkedState,
        Gzip.PoolType,
        Gzip.SlotType,
        limits,
        decoded_path_bytes,
        body_workspace_bytes,
        body_workspace_alignment,
        html_json_scratch_bytes,
        storage_slab.checkedMultiply(live_static_slots, live_static_path_bytes),
        storage_slab.checkedMultiply(live_static_slots, live_static_read_bytes),
    );
    const alignment = storage_slab.slabAlignment(
        ConnectionRecord,
        RequestRecord,
        worker_response_storage.ChunkNode,
        ChunkedState,
        Gzip.PoolType,
        Gzip.SlotType,
        body_enabled,
        body_workspace_alignment,
    );
    const decoded_path_storage_bytes = comptime storage_slab.checkedMultiply(
        limits.connection_slots,
        decoded_path_bytes,
    );
    const pipeline_storage_bytes = comptime storage_slab.checkedMultiply(
        limits.connection_slots,
        limits.pipeline_bytes_per_connection,
    );
    const response_storage_bytes = comptime storage_slab.checkedMultiply(
        limits.request_slots,
        limits.response_bytes_per_request,
    );
    const body_storage_bytes = comptime storage_slab.checkedMultiply(
        limits.body_workspace_slots,
        body_workspace_bytes,
    );
    const live_static_path_storage_bytes = comptime storage_slab.checkedMultiply(
        live_static_slots,
        live_static_path_bytes,
    );
    const live_static_read_storage_bytes = comptime storage_slab.checkedMultiply(
        live_static_slots,
        live_static_read_bytes,
    );
    const PoolInit = worker_storage_pools.Builder(
        body_enabled,
        limits,
        body_storage_bytes,
        layout,
        worker_response_storage.ChunkNode,
        ResponseChunkPool,
        ChunkedState,
        Gzip,
    );
    const init_context = .{
        .required_bytes = layout.bytes,
        .slab_alignment = alignment,
        .layout = layout,
        .limits = limits,
        .Connection = ConnectionRecord,
        .Request = RequestRecord,
        .HtmlJsonScratchStorage = HtmlJsonScratchStorage,
        .LiveStaticPathStorage = LiveStaticPathStorage,
        .LiveStaticReadStorage = LiveStaticReadStorage,
        .ResponseChunkPool = ResponseChunkPool,
        .BodyPool = BodyPool,
        .ChunkedPool = ChunkedPool,
        .GzipField = Gzip.Field,
        .decoded_path_storage_bytes = decoded_path_storage_bytes,
        .pipeline_storage_bytes = pipeline_storage_bytes,
        .response_storage_bytes = response_storage_bytes,
        .html_json_scratch_bytes = html_json_scratch_bytes,
        .live_static_slots = live_static_slots,
        .live_static_path_storage_bytes = live_static_path_storage_bytes,
        .live_static_read_storage_bytes = live_static_read_storage_bytes,
        .PoolInit = PoolInit,
    };
    return struct {
        const Self = @This();

        pub const Connection = ConnectionRecord;
        pub const Request = RequestRecord;
        pub const StreamWakeLifecycle = StreamWakes;
        pub const GzipDecoderPool = Gzip.PoolType;
        pub const runtime_limits = limits;
        pub const workspace_class_count: u16 = if (body_enabled) 2 else 1;
        pub const route_search_workspace_bytes: u64 = @sizeOf(RouteSearchWorkspace);
        pub const body_workspace_bytes_per_slot = body_workspace_bytes;
        pub const body_workspace_alignment_bytes = body_workspace_alignment;
        pub const chunked_workspace_bytes_per_slot: usize = if (body_enabled)
            @sizeOf(ChunkedState)
        else
            0;
        pub const decoded_path_bytes_per_connection = decoded_path_bytes;
        pub const response_chunk_bytes = config.response_chunk_bytes;
        pub const response_chunk_count = limits.response_chunk_count;
        pub const html_json_scratch_bytes_max = html_json_scratch_bytes;
        pub const gzip_decoder_thread_count = Gzip.thread_count;
        pub const upload_async_enabled = upload_async_sink_present;
        pub const live_static_slot_count = live_static_slots;
        pub const live_static_path_bytes_per_slot = live_static_path_bytes;
        pub const live_static_read_bytes_per_slot = live_static_read_bytes;
        pub const gzip_input_queue_bytes_per_slot = Gzip.input_queue_bytes_per_slot;
        pub const gzip_output_mailbox_capacity_bytes_per_slot =
            Gzip.output_mailbox_capacity_bytes_per_slot;
        pub const gzip_output_mailbox_bytes_per_slot = Gzip.output_mailbox_bytes_per_slot;
        pub const gzip_decoder_control_bytes = Gzip.control_bytes;
        pub const gzip_decoder_slot_bytes = Gzip.slot_bytes;
        pub const gzip_decoder_slots_bytes = Gzip.slots_bytes;
        pub const gzip_decoder_requested_stack_bytes = Gzip.requested_stack_bytes;
        pub const required_bytes = layout.bytes;
        pub const slab_alignment = alignment;
        upload_registry: UploadRegistry = .{},
        route_search_workspace: RouteSearchWorkspace = undefined,
        connections: []Connection,
        requests: []Request,
        connection_free_indices: []u16,
        request_free_indices: []u16,
        decoded_path_storage: []u8,
        pipeline_storage: []u8,
        response_storage: []u8,
        html_json_scratch: HtmlJsonScratchStorage,
        live_static_paths: LiveStaticPathStorage,
        live_static_reads: LiveStaticReadStorage,
        response_chunks: ResponseChunkPool,
        body_workspaces: BodyPool,
        chunked_workspaces: ChunkedPool,
        gzip_decoders: Gzip.Field,
        response_gzip_workspace: ResponseGzip.Workspace = undefined,
        stream_wakes: StreamWakes = undefined,
        json_hash_key: [16]u8,
        connection_pool: slot_pool.SlotPool,
        request_pool: slot_pool.SlotPool,

        pub fn init(self: *Self, slab: []u8) InitError!void {
            return worker_storage_init.init(init_context, self, slab);
        }

        pub fn acquireConnection(self: *Self, socket: reactor.Socket) ?u16 {
            return self.acquireAcceptedConnection(.{
                .socket = socket,
                .peer = address.Endpoint.initIpv4(.{ 127, 0, 0, 1 }, 0),
            });
        }

        pub fn acquireAcceptedConnection(self: *Self, accepted: reactor.Accepted) ?u16 {
            const index = self.connection_pool.acquire() orelse return null;
            const connection = &self.connections[index];
            std.debug.assert(connection.phase == .free);
            std.debug.assert(connection.generation != 0);
            std.debug.assert(connection.sequence != 0);
            std.debug.assert(!connection.receive_flags.gzip_rejecting);
            ReleaseActions.resetHead(connection);
            connection.phase = .first_head;
            connection.socket = accepted.socket;
            connection.transport_peer = accepted.peer.normalized();
            connection.connection_peer = connection.transport_peer;
            connection.connection_source = .transport;
            connection.proxy_destination = null;
            return index;
        }

        /// Starts another keep-alive request while preserving pipelined bytes.
        pub fn reuseConnection(self: *Self, connection_index: u16) void {
            std.debug.assert(connection_index < self.connections.len);
            const connection = &self.connections[connection_index];
            std.debug.assert(connection.phase == .responding);
            std.debug.assert(connection.active_request == null);
            std.debug.assert(!connection.close_after_response);
            std.debug.assert(connection.decoded_path_used == 0);
            std.debug.assert(connection.send_token == null);
            std.debug.assert(connection.close_token == null);
            std.debug.assert(!connection.receive_terminal_reaped);
            std.debug.assert(!connection.receive_flags.paused);
            std.debug.assert(!connection.receive_flags.gzip_paused);
            std.debug.assert(!connection.receive_flags.gzip_rejecting);
            ReleaseActions.resetHead(connection);
            connection.phase = .keepalive_idle;
        }

        pub fn acquireRequest(self: *Self, connection_index: u16) ?u16 {
            return worker_storage_types.acquiredIndex(
                self.acquireRequestClassified(connection_index, 0, false),
            );
        }
        pub fn acquireRequestClassified(
            self: *Self,
            connection_index: u16,
            workspace_class: u16,
            requires_chunked: bool,
        ) AcquireResult {
            std.debug.assert(connection_index < self.connections.len);
            std.debug.assert(workspace_class < workspace_class_count);
            const connection = &self.connections[connection_index];
            std.debug.assert(switch (connection.phase) {
                .first_head, .reused_head => true,
                else => false,
            });
            std.debug.assert(connection.active_request == null);

            const index = self.request_pool.acquire() orelse {
                return .request_slots_exhausted;
            };
            const request = &self.requests[index];
            std.debug.assert(request.phase == .free);
            std.debug.assert(request.generation != 0);
            std.debug.assert(request.sequence != 0);
            request.phase = .live;
            request.connection_index = connection_index;
            connection.active_request = index;
            const lease_failure: AcquireResult = switch (self.acquireBodyClassified(
                index,
                workspace_class,
                requires_chunked,
            )) {
                .acquired => return .{ .acquired = index },
                .body_workspace_exhausted => .body_workspace_exhausted,
                .chunked_workspace_exhausted => .chunked_workspace_exhausted,
                .invalid_request => unreachable,
            };
            request.phase = .free;
            request.connection_index = 0;
            connection.active_request = null;
            self.request_pool.release(index);
            return lease_failure;
        }
        pub fn acquireBodyClassified(
            self: *Self,
            request_index: u16,
            workspace_class: u16,
            requires_chunked: bool,
        ) BodyAcquireResult {
            return worker_body_pool.acquire(self, request_index, workspace_class, requires_chunked);
        }

        pub fn acquireChunkedForBody(self: *Self, request_index: u16) BodyAcquireResult {
            return worker_body_pool.acquireChunked(self, request_index);
        }

        pub fn acquireBodyForPlan(
            self: *Self,
            request_index: u16,
            plan: anytype,
            requires_chunked: bool,
        ) BodyAcquireResult {
            if (plan.headWorkspaceClass() == 0) return self.acquireBodyClassified(
                request_index,
                plan.workspace_class,
                requires_chunked,
            );
            if (requires_chunked) return self.acquireChunkedForBody(request_index);
            return .acquired;
        }
        pub fn acquireRequestForClass(
            self: *Self,
            connection_index: u16,
            workspace_class: u16,
            requires_chunked: bool,
        ) ?u16 {
            return worker_storage_types.acquiredIndex(self.acquireRequestClassified(
                connection_index,
                workspace_class,
                requires_chunked,
            ));
        }

        pub fn connectionReleaseIssue(
            self: *const Self,
            connection_index: u16,
        ) ?ConnectionReleaseIssue {
            return worker_storage_release.connectionIssue(
                ConnectionReleaseIssue,
                self,
                connection_index,
                limits.pipeline_bytes_per_connection,
            );
        }

        pub fn requestReleaseIssue(
            self: *const Self,
            connection_index: u16,
            request_index: u16,
        ) ?RequestReleaseIssue {
            return worker_storage_release.requestIssue(
                RequestReleaseIssue,
                self,
                connection_index,
                request_index,
                .{
                    .body_enabled = body_enabled,
                    .stream_enabled = stream_enabled,
                    .metrics_enabled = metrics_enabled,
                    .decoded_path_bytes = decoded_path_bytes,
                    .response_internal_bytes = limits.response_bytes_per_request,
                    .response_external_bytes = body_workspace_bytes,
                    .body_bytes = body_workspace_bytes,
                    .body_slots = limits.body_workspace_slots,
                    .chunked_slots = limits.chunked_workspace_slots,
                },
            );
        }

        pub fn releaseRequest(
            self: *Self,
            connection_index: u16,
            request_index: u16,
        ) void {
            ReleaseActions.request(self, connection_index, request_index);
        }
        pub fn releaseConnection(self: *Self, connection_index: u16) void {
            ReleaseActions.connection(self, connection_index);
        }
        pub fn decodedPath(self: *Self, connection_index: u16) []u8 {
            std.debug.assert(connection_index < self.connections.len);
            return storage_slab.region(
                self.decoded_path_storage,
                connection_index,
                decoded_path_bytes,
            );
        }

        pub fn pipeline(self: *Self, connection_index: u16) []u8 {
            std.debug.assert(connection_index < self.connections.len);
            return storage_slab.region(
                self.pipeline_storage,
                connection_index,
                limits.pipeline_bytes_per_connection,
            );
        }

        const RH = ResponseHelpers;
        pub const responseWritable = RH.writable;
        pub const responseReadable = RH.readable;
        pub const responseRegion = RH.region;
        pub const responseChunkWriter = RH.chunkWriter;
        pub fn responseSource(self: *const Self, index: u16) ResponseSource {
            return worker_response_storage.source(&self.requests[index]);
        }
        pub fn htmlJsonScratch(self: *Self, limit: u32) []u8 {
            return worker_storage_regions.htmlJsonScratch(
                self,
                limit,
                html_json_scratch_bytes,
            );
        }
        pub fn liveStaticPath(self: *Self, index: u16) []u8 {
            return worker_storage_regions.liveStaticPath(
                self,
                index,
                live_static_slots,
                live_static_path_bytes,
            );
        }
        pub fn liveStaticRead(self: *Self, index: u16) []u8 {
            return worker_storage_regions.liveStaticRead(
                self,
                index,
                live_static_slots,
                live_static_read_bytes,
            );
        }
        pub fn setFiniteOutput(
            self: *Self,
            index: u16,
            plan: application_finite_output.Plan,
        ) void {
            std.debug.assert(index < self.requests.len);
            if (comptime finite_output_enabled) {
                self.requests[index].finite_output = plan;
            } else {
                std.debug.assert(plan == .contiguous);
            }
        }
        pub fn finiteOutput(self: *const Self, index: u16) application_finite_output.Plan {
            std.debug.assert(index < self.requests.len);
            if (comptime finite_output_enabled) return self.requests[index].finite_output;
            return .contiguous;
        }
        pub const commitResponse = RH.commit;
        pub fn commitResponsePreservingFullDirty(
            self: *Self,
            index: u16,
            bytes: []const u8,
        ) bool {
            return RH.commitPreservingFullDirty(self, index, bytes);
        }
        pub fn commitExternalResponse(self: *Self, i: u16, bytes: []const u8) bool {
            return RH.commitExternal(self, i, bytes);
        }
        pub fn commitStaticResponse(
            self: *Self,
            index: u16,
            head: []const u8,
            body: []const u8,
        ) bool {
            return RH.commitStatic(self, index, head, body);
        }
        pub fn commitBorrowedResponseBody(
            self: *Self,
            index: u16,
            body: []const u8,
        ) bool {
            return RH.commitBorrowedBody(self, index, body);
        }
        pub fn commitResponseChunks(
            self: *Self,
            i: u16,
            head: []const u8,
            chain: anytype,
        ) bool {
            return RH.commitChunks(self, i, head, chain);
        }
        pub fn discardResponseChunks(self: *Self, chain: anytype) void {
            RH.discardChunks(self, chain);
        }
        pub fn responseSendReadable(self: *const Self, i: u16) ![]const u8 {
            return RH.sendReadable(self, i);
        }
        pub fn planResponseProgress(
            self: *const Self,
            index: u16,
            sent: usize,
        ) !worker_response_storage.SendProgress {
            return RH.planSendProgress(self, index, sent);
        }
        pub fn commitResponseProgress(
            self: *Self,
            index: u16,
            progress: worker_response_storage.SendProgress,
        ) void {
            RH.commitSendProgress(self, index, progress);
        }
        pub fn responseChunkStateValid(self: *const Self, i: u16) bool {
            return RH.chunkStateValid(self, i);
        }
        pub fn clearResponse(self: *Self, i: u16) void {
            RH.clear(self, i);
        }
        pub fn resetResponseChunks(self: *Self) void {
            self.response_chunks.reset();
        }

        pub fn bodyWorkspaceAvailable(self: *const Self) u16 {
            if (body_enabled) return self.body_workspaces.pool.available();
            return 0;
        }

        pub fn chunkedWorkspaceAvailable(self: *const Self) u16 {
            if (body_enabled) return self.chunked_workspaces.pool.available();
            return 0;
        }

        pub fn gzipPool(self: *Self) ?*Gzip.PoolType {
            if (comptime Gzip.thread_count != 0) return self.gzip_decoders;
            return null;
        }

        pub fn chunkedState(
            self: *Self,
            request_index: u16,
        ) ChunkedAccessError!*ChunkedState {
            return worker_storage_chunked.state(
                self,
                request_index,
                body_enabled,
                limits.chunked_workspace_slots,
                ChunkedState,
            );
        }

        pub fn releaseUnusedBody(self: *Self, request_index: u16) BodyAccessError!bool {
            if (request_index < self.requests.len) {
                const request = &self.requests[request_index];
                if (request.phase == .live and
                    worker_response_storage.source(request) == .body_workspace)
                {
                    return error.BodyWorkspaceNotEmpty;
                }
            }
            return BodyHelpers.releaseUnused(self, request_index);
        }

        pub fn bodyWritable(self: *Self, request_index: u16) BodyAccessError![]u8 {
            return BodyHelpers.writable(self, request_index);
        }

        pub fn bodyReadable(self: *const Self, request_index: u16) BodyAccessError![]const u8 {
            return BodyHelpers.readable(self, request_index);
        }

        pub fn bodyWorkspace(
            self: *Self,
            request_index: u16,
        ) BodyAccessError![]u8 {
            return BodyHelpers.workspace(self, request_index);
        }

        pub fn markBodyWorkspaceDirty(
            self: *Self,
            request_index: u16,
        ) BodyAccessError!void {
            return BodyHelpers.markDirty(self, request_index);
        }

        pub fn commitBody(
            self: *Self,
            request_index: u16,
            byte_count: usize,
        ) BodyAccessError!void {
            return BodyHelpers.commit(self, request_index, byte_count);
        }

        pub fn finishBody(
            self: *Self,
            request_index: u16,
            kind: body_api.Kind,
        ) BodyAccessError!body_api.Decoded {
            return BodyHelpers.finish(self, request_index, kind);
        }

        pub fn resetBodyWorkspaces(self: *Self) void {
            if (self.bodyResetIssue() != null) {
                @panic("worker body reset while gzip decoder pool is active");
            }
            BodyHelpers.resetAll(self);
        }

        pub fn bodyResetIssue(self: *const Self) ?BodyResetIssue {
            if (comptime Gzip.thread_count != 0) {
                const lifecycle = self.gzip_decoders.lifecycleStatus();
                if (lifecycle == .running or lifecycle == .quiesced) {
                    return .gzip_decoder_active;
                }
            }
            return null;
        }
    };
}
