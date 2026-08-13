const std = @import("std");
const body = @import("body.zig");
const cors = @import("cors.zig");
const response = @import("response.zig");
const response_gzip = @import("response/gzip.zig");
const route = @import("route.zig");
const application_context = @import("application/context.zig");
const application_asset_runtime = @import("internal/application/asset_runtime.zig");
const application_assets = @import("internal/application/assets.zig");
const application_compile = @import("internal/application/compile.zig");
const application_chunk_output = @import("internal/application/chunk_output.zig");
const application_csrf = @import("internal/application/csrf.zig");
const app_cors = @import("internal/application/cors.zig");
const application_body = @import("internal/application/body.zig");
const application_endpoint_output = @import("internal/application/endpoint_output.zig");
const application_head = @import("internal/application/head.zig");
const application_head_setup = @import("internal/application/head_setup.zig");
const application_json_response = @import("internal/application/json_response.zig");
const application_lifecycle_bridge = @import("internal/application/lifecycle_bridge.zig");
const application_multipart_lifecycle = @import("internal/application/multipart_lifecycle.zig");
const application_metrics_binding = @import("internal/application/metrics_binding.zig");
const application_pipeline = @import("internal/application/pipeline.zig");
const application_prepare_binding = @import("internal/application/prepare_binding.zig");
const application_prepare_direct = @import("internal/application/prepare_direct.zig");
const application_response_output = @import("internal/application/response_output.zig");
const application_response_body = @import("internal/application/response_body.zig");
const application_runtime = @import("internal/application/runtime.zig");
const application_selected_body = @import("internal/application/selected_body.zig");
const application_serve_bridge = @import("internal/application/serve_bridge.zig");
const application_static = @import("internal/application/static.zig");
const application_static_response = @import("internal/application/static_response.zig");
const application_types = @import("internal/application/types.zig");
const application_upload_catalog = @import("internal/application/upload_catalog.zig");
const route_graph = @import("internal/route_graph.zig");
const response_head = @import("internal/http1/response_head.zig");
const static_file = @import("static_file.zig");
pub const Status = response.Status;
pub const HeadLimits = response.HeadLimits;
pub const Bodyless = application_context.Bodyless;
pub const Input = application_context.Input;
pub const Request = application_context.Request;
pub const RequestTrailers = application_context.RequestTrailers;
pub const RequestHeaders = application_context.RequestHeaders;
pub const ResponseBodyError = application_context.ResponseBodyError;
pub const Context = application_context.Context;
pub const ResponseGzip = response_gzip.ResponseGzip;
pub const Cors = cors;
pub const Forwarding = @import("forwarding.zig");
pub const TransportOutcome = application_types.TransportOutcome;
pub const Outcome = application_types.Outcome;
pub const LifecycleError = application_types.LifecycleError;
pub const PrepareError = response_head.WriteError || response.HeaderMutationError ||
    application_runtime.RedirectError || application_body.Error || LifecycleError ||
    error{
        HtmlRequiresTransport,
        LiveStaticRequiresTransport,
        MetricsRequiresTransport,
        InvalidRoutePlan,
    };
pub const ServeError = PrepareError || error{StreamingRequiresTransport};

pub const Prepared = application_types.Prepared;
pub const BodyPlan = application_types.BodyPlan;
pub const HeadResult = application_types.HeadResult;
pub const DeferredMetrics = application_types.DeferredMetrics;
pub const MetricsResult = application_types.MetricsResult;
pub const HeadPolicy = application_types.HeadPolicy;
pub const ServeResult = application_types.ServeResult;
pub const CodingOutcome = application_types.CodingOutcome;
pub const MultipartError = application_multipart_lifecycle.Error;
pub const LiveStaticResolution = static_file.RuntimeResolution;

pub fn Application(comptime config: anytype) type {
    @setEvalBranchQuota(application_upload_catalog.route_evaluation_quota);
    const Config = @TypeOf(config);
    if (!@hasField(Config, "State")) @compileError("PLOOF-E3050 Application requires State");
    if (!@hasField(Config, "routes")) @compileError("PLOOF-E3051 Application requires routes");
    const gzip_enabled = @hasField(Config, "response_gzip");
    const gzip_options = if (gzip_enabled) blk: {
        if (@TypeOf(config.response_gzip) != ResponseGzip) {
            @compileError("PLOOF-E3083 response_gzip must be ploof.ResponseGzip");
        }
        break :blk config.response_gzip;
    } else ResponseGzip{};
    const State = config.State;
    if (@TypeOf(State) != type) @compileError("PLOOF-E3052 Application State must be a type");
    const AppError = if (@hasField(Config, "Error")) config.Error else error{};
    application_compile.validateApplicationError(AppError);
    const graph_limits = if (@hasField(Config, "graph_limits"))
        config.graph_limits
    else
        route.standard_graph_limits;
    const maximum = if (@hasField(Config, "response_workspace_limits"))
        config.response_workspace_limits
    else
        response.standard_head_limits;
    const logical = if (@hasField(Config, "response_head_limits"))
        config.response_head_limits
    else
        maximum;
    const app_middleware = if (@hasField(Config, "middleware")) config.middleware else .{};
    application_compile.validateTuple(
        app_middleware,
        "PLOOF-E3053 Application middleware must be a tuple",
    );
    application_compile.validateTuple(
        config.routes,
        "PLOOF-E3054 Application routes must be a tuple",
    );
    application_compile.validateDescriptorShapes(config.routes);

    const response_body_bytes_max = comptime application_response_body.bytesMax(config);
    const application_route_count = comptime application_compile.countRoutes(config.routes);
    if (application_route_count > std.math.maxInt(u16)) {
        @compileError("PLOOF-E3055 Application route count exceeds u16");
    }
    const asset_count = comptime application_assets.count(config);
    if (asset_count > std.math.maxInt(u16) - application_route_count) {
        @compileError("PLOOF-E3055 Application route count exceeds u16");
    }
    const live_static_count = comptime application_static.count(config.routes);
    const live_static_enabled = live_static_count != 0;
    const live_static_roots = comptime application_static.roots(config.routes);
    if (live_static_roots.len > 64) {
        @compileError("PLOOF-E4112 live static roots per application exceed 64");
    }
    const configured_live_static_slots = if (@hasField(Config, "live_static_slots_per_worker"))
        config.live_static_slots_per_worker
    else
        8;
    const live_static_slots: u16 = if (live_static_enabled) blk: {
        if (configured_live_static_slots == 0 or configured_live_static_slots > 64) {
            @compileError("PLOOF-E4110 live static slots per worker must be 1...64");
        }
        break :blk @intCast(configured_live_static_slots);
    } else 0;
    const configured_live_static_read_bytes = if (@hasField(Config, "live_static_read_bytes"))
        config.live_static_read_bytes
    else
        64 * 1024;
    const live_static_read_bytes: u32 = if (live_static_enabled) blk: {
        if (configured_live_static_read_bytes < 4096 or
            configured_live_static_read_bytes > 1024 * 1024)
        {
            @compileError("PLOOF-E4111 live static read bytes must be 4096...1048576");
        }
        break :blk @intCast(configured_live_static_read_bytes);
    } else 0;
    const Uploads = application_upload_catalog.Catalog(config.routes);
    const application_definitions = comptime application_compile.makeDefinitions(
        config.routes,
        application_route_count,
    );
    const definitions = comptime application_assets.definitions(
        config,
        application_definitions,
    );
    const application_body_plans = comptime application_compile.makeBodyPlans(
        config.routes,
        application_route_count,
    );
    const body_plans = comptime application_assets.appendRepeated(
        config,
        application_body_plans,
        application_body.none_plan,
    );
    const application_output_plans = comptime application_compile.makeFiniteOutputPlans(
        config.routes,
        application_route_count,
    );
    const output_plans = comptime application_assets.appendRepeated(
        config,
        application_output_plans,
        @import("internal/application/finite_output.zig").Plan.contiguous,
    );
    const Router = route_graph.Graph(definitions, graph_limits);
    const Planner = app_cors.Planner(config, Router, &body_plans, &output_plans, Input, logical);
    const ContextType = Context(State, maximum);
    const ResponseWorkspace = response.Workspace(maximum);
    const Response = response.Response(maximum);
    const stream_layout = comptime application_compile.streamLayout(
        config.routes,
        ContextType,
        Response,
        AppError,
    );
    const finite_chunks_enabled = stream_layout.output == .chunks;
    const mapper = comptime application_compile.errorMapper(
        config,
        ContextType,
        Response,
        AppError,
    );
    const server_identity = if (@hasField(Config, "server_identity"))
        response_head.ServerIdentity.init(config.server_identity)
    else
        null;
    const gzip_framework_bytes = if (gzip_enabled)
        application_response_output.frameworkBytesRequired(maximum, server_identity) orelse
            @compileError("PLOOF-E3084 response gzip framework fallback exceeds application limits")
    else
        0;
    const ResponseOutput = application_response_output.Configured(
        gzip_enabled,
        maximum,
        gzip_options,
    );
    const CorsRun = app_cors.Responder(Planner, Response, ResponseOutput, logical, server_identity);
    const Pipeline = application_pipeline.Pipeline(
        ContextType,
        Response,
        AppError,
        mapper,
        Outcome,
        ResponseOutput,
    );
    application_compile.validateLogicalMaximum(maximum, logical);
    application_compile.validateMiddlewareTuple(
        app_middleware,
        ContextType,
        Response,
        AppError,
        Bodyless,
        Outcome,
    );
    application_compile.validateMiddlewareBounds(app_middleware, graph_limits);
    application_compile.validateDescriptors(
        config.routes,
        .{},
        app_middleware,
        ContextType,
        Response,
        AppError,
        maximum,
        graph_limits,
        Outcome,
    );
    application_csrf.validateApplication(
        config.routes,
        app_middleware,
        logical,
        maximum,
    );
    const middleware_state_bytes = comptime application_compile.maximumStateBytes(
        config.routes,
        .{},
        app_middleware,
    );
    const middleware_state_alignment = comptime application_compile.maximumStateAlignment(
        config.routes,
        .{},
        app_middleware,
    );
    const body_enabled = comptime application_compile.hasBodyEndpoint(config.routes);
    const request_body_enabled = comptime application_compile.hasRequestBodyEndpoint(config.routes);
    const multipart_enabled = comptime application_compile.hasMultipartEndpoint(config.routes);
    const metrics_route_count = comptime application_compile.countOpenMetrics(config.routes);
    const metrics_enabled = metrics_route_count != 0;
    const ApplicationHeadResult = application_types.HeadResultFor(metrics_enabled);
    const MetricsState = application_metrics_binding.State(metrics_enabled, Input);
    const body_alignment = comptime application_compile.maximumWorkspaceAlignment(
        config.routes,
    );
    const body_bytes_unaligned = comptime application_endpoint_output.maximumWorkspaceBytes(
        config.routes,
        maximum,
        gzip_enabled,
    );
    const body_bytes = comptime std.mem.alignForward(
        u64,
        body_bytes_unaligned,
        body_alignment,
    );
    if (body_bytes > std.math.maxInt(u32)) {
        @compileError(
            "PLOOF-E3082 buffered decoded body limit exceeds u32; " ++
                "use streaming body API",
        );
    }

    return struct {
        const Self = @This();

        pub const StateType = State;
        pub const Error = AppError;
        pub const Context = ContextType;
        pub const ResponseType = Response;
        pub const MultipartTerminalSource = MultipartLifecycle.TerminalSource;
        pub const MultipartUpstreamFailure = MultipartLifecycle.UpstreamFailure;
        pub const MultipartFinalization = MultipartLifecycle.Finalization;
        pub const UploadCatalog = Uploads;
        pub const UploadRegistry = Uploads.Registry;
        pub const UploadRouteProfile = application_upload_catalog.UploadRouteProfile;
        pub const upload_io_requirements = Uploads.io_requirements;
        pub const upload_window_max = Uploads.upload_window_max;
        pub const upload_route_profiles = Uploads.upload_route_profiles;
        pub const upload_request_handles_max = Uploads.request_handles_max;
        pub const upload_runtime_handles_max = Uploads.runtime_handles_max;
        pub const upload_finalization_instances_max = Uploads.finalization_instances_max;
        pub const upload_sink_present = Uploads.sink_present;
        pub const upload_async_sink_present = Uploads.async_sink_present;
        pub const upload_file_sink_configurations = Uploads.file_sink_configurations;
        pub const Plan = Planner.Plan;
        pub const RouteSearchWorkspace = Router.SearchWorkspace;
        pub const route_definitions = definitions;
        pub const route_index_static_bytes = Router.index_static_bytes;
        pub const route_search_workspace_bytes = Router.search_workspace_bytes;
        pub const route_search_visits_bound = Router.search_visits_bound;
        pub const route_search_compare_bytes_bound = Router.search_compare_bytes_bound;
        pub const route_select_visits_bound = Router.select_visits_bound;
        pub const route_select_compare_bytes_bound =
            Router.select_compare_bytes_bound;
        pub const embedded_asset_count = asset_count;
        pub const live_static_route_count = live_static_count;
        pub const live_static_root_paths = live_static_roots;
        pub const live_static_root_count = live_static_roots.len;
        pub const live_static_path_bytes_max = application_static.maximumPathBytes(config.routes);
        pub const live_static_slots_per_worker = live_static_slots;
        pub const live_static_read_bytes_per_slot = live_static_read_bytes;
        pub const runtime_server_identity = server_identity;
        pub const finite_response_chunks_enabled = finite_chunks_enabled;
        pub const response_gzip_enabled = gzip_enabled;
        pub const open_metrics_route_count = metrics_route_count;
        pub const open_metrics_enabled = metrics_enabled;
        pub const HeadResultType = ApplicationHeadResult;
        pub const cors_policy_enabled = Planner.cors_enabled;
        pub const response_gzip_framework_bytes_required = gzip_framework_bytes;
        pub const ResponseGzipWorkspace = ResponseOutput.Workspace;
        pub const workspace_class_count: u16 = if (body_enabled) 2 else 1;
        pub const body_workspace_bytes_max: u64 = body_bytes;
        pub const request_body_decoding_enabled = request_body_enabled;
        pub const body_workspace_alignment: u32 = body_alignment;
        pub const stream_enabled = stream_layout.stream_enabled;
        pub const stream_producer_bytes_max = stream_layout.producer_bytes_max;
        pub const stream_producer_alignment_max = stream_layout.producer_alignment_max;
        pub const html_encoded_bytes_max: u32 = switch (stream_layout.output) {
            .contiguous => 0,
            .chunks => |chunks| chunks.encoded_bytes_max,
        };
        pub const html_json_scratch_bytes_max: u32 = switch (stream_layout.output) {
            .contiguous => 0,
            .chunks => |chunks| chunks.json_scratch_bytes_max,
        };

        pub fn routeTarget(comptime descriptor: anytype) *const route.RouteTarget {
            return application_compile.makeRouteTarget(config.routes, descriptor);
        }

        pub fn __csrfStartupFailure(state: *const State) ?application_csrf.StartupFailure {
            return application_csrf.startupFailure(config.routes, app_middleware, state);
        }

        const RequestData = application_multipart_lifecycle.RequestData(
            body_enabled,
            Input,
            application_json_response.Binding,
        );
        pub const Workspace = struct {
            response: ResponseWorkspace = .{},
            response_body: [response_body_bytes_max]u8 = undefined,
            response_gzip: ResponseOutput.Binding = .{},
            finite_output: application_chunk_output.Binding(finite_chunks_enabled) = .{},
            cors_fields: application_context.CorsStorage(Planner.cors_enabled) = .{},
            stream: application_compile.StreamStorage(stream_layout) = undefined,
            captures: Router.CaptureBuffer = undefined,
            response_head_bytes: [maximum.head_bytes_max]u8 = undefined,
            redirect_location: [maximum.field_line_bytes_max]u8 = undefined,
            allow: [64]u8 = undefined,
            middleware_state: [middleware_state_bytes]u8 align(middleware_state_alignment) =
                undefined,
            initialized_middleware: u64 = 0,
            json_response_binding: if (body_enabled)
                application_json_response.Binding
            else
                struct {} = undefined,
            json_response_written: bool = false,
            multipart_commit: if (multipart_enabled) bool else struct {} =
                if (multipart_enabled) false else .{},
            multipart_finalization: if (multipart_enabled)
                application_types.MultipartFinalization
            else
                struct {} = if (multipart_enabled) .not_required else .{},
            multipart_abort_mapped_error: if (multipart_enabled) bool else struct {} =
                if (multipart_enabled) false else .{},
            multipart_abort_cause: if (multipart_enabled)
                ?MultipartLifecycle.UpstreamFailure
            else
                struct {} = if (multipart_enabled) null else .{},
            context: ContextType = undefined,
            request_data: RequestData = undefined,
            pending: application_types.PendingFor(stream_enabled) = undefined,
            live_static_route_id: if (live_static_enabled) u16 else struct {} =
                if (live_static_enabled) 0 else .{},
            metrics: MetricsState = .{},
            lifecycle: application_types.Lifecycle = .idle,
        };
        const AssetRuntime = application_asset_runtime.Runtime(
            config,
            logical,
            app_middleware,
            application_route_count,
            asset_count,
            ContextType,
            Workspace,
            Input,
            Pipeline,
            Bodyless,
            server_identity,
            PrepareError,
        );
        const SelectedBody = application_selected_body.Configured(
            config.routes,
            app_middleware,
            ContextType,
            Workspace,
            AppError,
            mapper,
            Uploads.Registry,
            Input,
            Pipeline,
            Outcome,
            PrepareError,
            Prepared,
            ApplicationHeadResult,
            BodyPlan,
            logical,
            maximum,
            gzip_enabled,
            server_identity,
        );
        const Head = application_head.Configured(
            config.routes,
            definitions,
            app_middleware,
            ContextType,
            Response,
            ApplicationHeadResult,
            Workspace,
            Input,
            Pipeline,
            SelectedBody,
            logical,
            server_identity,
            PrepareError,
        );
        const StaticResponse = application_static_response.Configured(
            config.routes,
            app_middleware,
            Workspace,
            Response,
            Pipeline,
            logical,
            server_identity,
            PrepareError,
        );
        const MetricsBinding = application_metrics_binding.Configured(
            metrics_enabled,
            Workspace,
            DeferredMetrics,
            MetricsResult,
            Prepared,
            PrepareError,
            Head.resumeMetrics,
        );
        const MultipartLifecycle = application_multipart_lifecycle.Configured(
            body_enabled,
            multipart_enabled,
            config.routes,
            ContextType,
            Workspace,
            AppError,
            Uploads.Registry,
        );
        const PrepareBinding = application_prepare_binding.Configured(
            State,
            Workspace,
            RequestTrailers,
            Plan,
            ResponseGzipWorkspace,
            PrepareError,
            ApplicationHeadResult,
            Prepared,
            prepareHeadPlannedIn,
            prepareBodyIn,
        );
        const DirectPrepare = application_prepare_direct.Configured(
            metrics_enabled,
            State,
            Workspace,
            RouteSearchWorkspace,
            Input,
            Plan,
            PrepareError,
            Prepared,
            ApplicationHeadResult,
            plan,
            prepareHeadPlanned,
            prepareHeadPlannedIn,
            prepareBody,
        );
        const LifecycleBridge = application_lifecycle_bridge.Configured(
            config.routes,
            app_middleware,
            body_enabled,
            live_static_enabled,
            metrics_enabled,
            multipart_enabled,
            stream_enabled,
            Outcome,
            LifecycleError,
            TransportOutcome,
        );
        const ServeBridge = application_serve_bridge.Configured(
            Self,
            AssetRuntime,
            Head,
            ServeError,
            ServeResult,
            PrepareError,
            ApplicationHeadResult,
        );
        const HeadSetup = application_head_setup.Configured(
            multipart_enabled,
            logical,
            Planner,
            CorsRun,
            State,
            Input,
            Plan,
            Prepared,
            PrepareError,
        );
        pub const __prepareHeadPlannedWithResponseGzip = PrepareBinding.headGzip;
        pub const __prepareBodyWithResponseGzip = PrepareBinding.bodyGzip;
        pub const __prepareHeadPlannedWithChunks = PrepareBinding.headChunks;
        pub const __prepareBodyWithChunks = PrepareBinding.bodyChunks;
        pub const __scrubPreparedHead = application_prepare_binding.scrubHead;
        pub const __resumeMetrics = MetricsBinding.resumeMetrics;

        pub fn __prepareLiveStatic(
            workspace: *Workspace,
            intent: application_types.LiveStaticIntent,
            resolution: LiveStaticResolution,
            output: []u8,
        ) PrepareError!Prepared {
            if (comptime !live_static_enabled) unreachable;
            return StaticResponse.prepare(workspace, intent, resolution, output);
        }

        pub const plan = Planner.make;
        pub const __refinePlanBody = Planner.refineBody;
        pub const prepare = DirectPrepare.prepare;
        pub const preparePlanned = DirectPrepare.preparePlanned;
        pub const prepareHead = DirectPrepare.head;
        pub const prepareHeadIn = DirectPrepare.headIn;

        /// Planned variant without typed-endpoint request storage.
        /// Use `prepareHeadPlannedIn` for production-equivalent endpoint phases.
        pub fn prepareHeadPlanned(
            state: *State,
            workspace: *Workspace,
            output: []u8,
            request_plan: *const Plan,
            policy: HeadPolicy,
        ) PrepareError!ApplicationHeadResult {
            return prepareHeadPlannedIn(
                state,
                workspace,
                &.{},
                output,
                request_plan,
                policy,
            );
        }

        pub fn prepareHeadPlannedIn(
            state: *State,
            workspace: *Workspace,
            request_workspace: []u8,
            output: []u8,
            request_plan: *const Plan,
            policy: HeadPolicy,
        ) PrepareError!ApplicationHeadResult {
            const input = request_plan.input;
            const setup = try HeadSetup.run(
                state,
                workspace,
                input,
                request_plan,
                output,
                policy.close_if_prepared,
            );
            if (setup.preflight) |prepared| return .{ .prepared = prepared };
            const head_input = setup.input;
            const selection = setup.selection;
            return switch (selection) {
                .selected => |matched| if (application_assets.index(
                    matched.route_id,
                    application_route_count,
                    asset_count,
                )) |asset_index| .{ .prepared = try AssetRuntime.prepare(
                    asset_index,
                    workspace,
                    head_input,
                    output,
                    policy.close_if_prepared,
                ) } else ServeBridge.selectedHead(
                    matched,
                    request_plan.body,
                    &workspace.context,
                    workspace,
                    head_input,
                    request_workspace,
                    output,
                    policy,
                ),
                else => .{ .prepared = try if (AssetRuntime.generatedResponse(
                    selection,
                    head_input.path,
                )) AssetRuntime.prepareGenerated(
                    true,
                    selection,
                    &workspace.context,
                    workspace,
                    head_input,
                    output,
                    policy.close_if_prepared,
                ) else AssetRuntime.prepareGenerated(
                    false,
                    selection,
                    &workspace.context,
                    workspace,
                    head_input,
                    output,
                    policy.close_if_prepared,
                ) },
            };
        }

        pub fn prepareBody(
            workspace: *Workspace,
            decoded: body.Decoded,
            trailers: RequestTrailers,
            output: []u8,
        ) PrepareError!Prepared {
            return prepareBodyIn(
                workspace,
                decoded,
                trailers,
                &.{},
                [_]u8{0} ** 16,
                output,
            );
        }

        pub const __beginMultipart = MultipartLifecycle.begin;
        pub const __feedMultipart = MultipartLifecycle.feed;
        pub const __finishMultipart = MultipartLifecycle.finish;
        pub const __feedMultipartProgress = MultipartLifecycle.feedProgress;
        pub const __finishMultipartProgress = MultipartLifecycle.finishProgress;
        pub const __resumeMultipart = MultipartLifecycle.resumeParser;
        pub const __multipartParserFinished = MultipartLifecycle.parserFinished;
        pub const __peekUploadSubmission = MultipartLifecycle.peekSubmission;
        pub const __markUploadSubmitted = MultipartLifecycle.markSubmitted;
        pub const __completeUploadSubmission = MultipartLifecycle.completeSubmission;
        pub const __completeCanceledUploadSubmission =
            MultipartLifecycle.completeCanceledSubmission;
        pub const __startMultipartFinalization = MultipartLifecycle.startFinalization;
        pub const __cancelMultipart = MultipartLifecycle.cancel;
        pub const __multipartFinalizationFlow = MultipartLifecycle.finalizationFlow;
        pub const __multipartFinalizationOutcome = MultipartLifecycle.finalizationOutcome;
        pub const __multipartFinalizationReport = MultipartLifecycle.finalizationReport;
        pub const __multipartFinalizationCleanupFailure =
            MultipartLifecycle.finalizationCleanupFailure;
        pub const __multipartTerminalSource = MultipartLifecycle.terminalSource;
        pub const __multipartRejection = MultipartLifecycle.rejection;
        pub const __multipartApplicationFailure = MultipartLifecycle.applicationFailure;
        pub const __multipartUploadRouteId = MultipartLifecycle.uploadRouteId;
        fn prepareBodyIn(
            workspace: *Workspace,
            decoded: body.Decoded,
            trailers: RequestTrailers,
            request_workspace: []u8,
            json_hash_key: [16]u8,
            output: []u8,
        ) PrepareError!Prepared {
            if (comptime body_enabled) {
                try MultipartLifecycle.validateCompletion(workspace, decoded);
                var awaiting = workspace.request_data.awaiting;
                awaiting.input.trailers = trailers;
                workspace.context.request.trailers = trailers;
                workspace.lifecycle = .preparing;
                return SelectedBody.dispatch(
                    awaiting.route_id,
                    awaiting.selected_decoder,
                    request_workspace,
                    json_hash_key,
                    &workspace.context,
                    workspace,
                    decoded,
                    awaiting.input,
                    output,
                ) orelse {
                    if (comptime multipart_enabled) {
                        if (application_types.multipartCleanupPending(workspace)) {
                            workspace.multipart_commit = false;
                            workspace.multipart_abort_cause = .verification;
                        } else workspace.lifecycle = .idle;
                    } else workspace.lifecycle = .idle;
                    return error.InvalidBodyInput;
                };
            }
            return error.NoPendingBody;
        }

        pub fn rejectBody(workspace: *Workspace, status: Status) LifecycleError!void {
            if (comptime body_enabled) {
                if (workspace.lifecycle != .awaiting_body) return error.NoPendingBody;
                workspace.pending = .{
                    .route = .{ .selected = workspace.request_data.awaiting.route_id },
                    .status = status,
                    .mapped_error = false,
                    .success_transport = .completed,
                };
                workspace.lifecycle = .pending;
                return;
            }
            return error.NoPendingBody;
        }

        pub const complete = LifecycleBridge.complete;
        pub const abort = LifecycleBridge.abort;
        pub const __abortWithTransport = LifecycleBridge.abortWithTransport;
        pub const serve = ServeBridge.serve;
    };
}
