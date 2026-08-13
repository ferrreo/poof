const std = @import("std");
const http1 = @import("internal/http1.zig");
const platform = @import("internal/platform.zig");
const route_graph = @import("internal/route_graph.zig");
const route_module = @import("route.zig");
const server_module = @import("server.zig");
const server_runner_module = @import("server/runner.zig");

comptime {
    platform.requireSupported();
}

pub const version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
};

pub const startup = @import("startup.zig");
pub const address = @import("address.zig");
pub const application = @import("application.zig");
pub const Asset = @import("asset.zig");
pub const AssetRef = Asset.AssetRef;
pub const AssetOrigin = Asset.AssetOrigin;
pub const Body = @import("body.zig");
pub const Cors = @import("cors.zig");
pub const Csrf = @import("csrf.zig");
pub const Endpoint = @import("endpoint.zig").Endpoint;
pub const IpAddress = address.Address;
pub const SocketAddress = address.Endpoint;
pub const Cidr = address.Cidr;
pub const Form = @import("form.zig");
pub const Forwarding = @import("forwarding.zig");
pub const Json = @import("json.zig");
pub const Html = @import("html/render.zig");
pub const HtmlResponse = @import("html/response.zig");
pub const HtmlSource = @import("html/source.zig");
pub const HtmlTemplate = @import("html/template.zig");
pub const Lifecycle = @import("lifecycle.zig");
pub const Metrics = @import("metrics.zig");
pub const OpenMetrics = @import("open_metrics.zig");
pub const Health = @import("health.zig");
pub const AccessLog = @import("access_log.zig");
pub const Server = server_module.Server;
pub const ServerRunner = server_runner_module.Runner;
pub const ServerRunResult = server_runner_module.Result;
pub const ServerRunError = server_runner_module.Error;
pub const ServerExit = server_runner_module.exit;
pub const ServerOptions = server_module.Options;
pub const ServerStartConfig = server_module.StartConfig;
pub const ServerShutdownResult = server_module.ShutdownResult;
pub const ServerShutdownError = server_module.ShutdownError;
pub const ServerSignalShutdownError = server_module.SignalShutdownError;
pub const InlineText = @import("inline_text.zig").InlineText;
pub const Multipart = @import("multipart.zig");
pub const Query = @import("query.zig");
pub const response = @import("response.zig");
pub const response_stream = @import("response/stream.zig");
pub const Static = @import("static_file.zig");
pub const StaticDir = Static.StaticDir;
pub const StaticFile = Static.StaticFile;
pub const route = struct {
    pub const Method = route_module.Method;
    pub const GraphLimits = route_module.GraphLimits;
    pub const standard_graph_limits = route_module.standard_graph_limits;
    pub const configured = route_module.configured;
    pub const get = route_module.get;
    pub const openMetrics = route_module.openMetrics;
    pub const openMetricsConfigured = route_module.openMetricsConfigured;
    pub const head = route_module.head;
    pub const post = route_module.post;
    pub const put = route_module.put;
    pub const patch = route_module.patch;
    pub const delete = route_module.delete;
    pub const group = route_module.group;
};
pub const url = @import("url.zig");
pub const Url = url.Url;
pub const WebPolicy = url.WebPolicy;
pub const TrustedResourceUrl = @import("trusted_resource_url.zig").TrustedResourceUrl;
pub const ResourceTable = @import("trusted_resource_url.zig").ResourceTable;
pub const TrustedResourceTable = ResourceTable;
pub const urlFor = @import("url_for.zig").urlFor;
pub const urlForWith = @import("url_for.zig").urlForWith;

pub const Application = application.Application;
pub const Context = application.Context;
pub const Input = application.Input;
pub const Request = application.Request;
pub const RequestHeaders = application.RequestHeaders;
pub const RequestTrailers = application.RequestTrailers;
pub const ResponseBodyError = application.ResponseBodyError;
pub const Bodyless = application.Bodyless;
pub const ResponseGzip = application.ResponseGzip;
pub const CodingOutcome = application.CodingOutcome;
pub const Outcome = application.Outcome;
pub const TransportOutcome = application.TransportOutcome;
pub const ServeError = application.ServeError;
pub const ServeResult = application.ServeResult;

pub const Method = route_module.Method;
pub const GraphLimits = route_module.GraphLimits;
pub const RouteTarget = route_module.RouteTarget;
pub const standard_graph_limits = route_module.standard_graph_limits;

pub const configured = route_module.configured;
pub const get = route_module.get;
pub const openMetrics = route_module.openMetrics;
pub const openMetricsConfigured = route_module.openMetricsConfigured;
pub const head = route_module.head;
pub const post = route_module.post;
pub const put = route_module.put;
pub const patch = route_module.patch;
pub const delete = route_module.delete;
pub const group = route_module.group;

/// Implementation seam for the separately imported `ploof_testing` module.
/// It is not part of the documented production API compatibility surface.
pub fn __testingOptions() type {
    return @import("testing.zig").Options;
}

pub fn __testingRequest() type {
    return @import("testing.zig").Request;
}

pub fn __testingClientError() type {
    return @import("testing.zig").ClientError;
}

pub fn __testingResponse() type {
    return @import("testing.zig").Response;
}

pub fn __testingClient(comptime App: type) type {
    return @import("testing.zig").Client(App);
}

pub fn __testingConfiguredClient(comptime App: type, comptime options: anytype) type {
    return @import("testing.zig").ConfiguredClient(App, options);
}

/// Implementation seam used by compile-failure fixtures until application composition owns it.
pub fn __responseStreamErased(comptime bytes_max: usize, comptime alignment_max: u29) type {
    return @import("internal/response/stream_erasure.zig").Erased(bytes_max, alignment_max);
}

test "package version starts at 0.1.0" {
    try std.testing.expectEqual(@as(usize, 0), version.major);
    try std.testing.expectEqual(@as(usize, 1), version.minor);
    try std.testing.expectEqual(@as(usize, 0), version.patch);
    _ = http1;
    _ = address;
    _ = route_graph;
    _ = application;
    _ = Asset;
    _ = Body;
    _ = Cors;
    _ = Csrf;
    _ = Forwarding;
    _ = Html;
    _ = HtmlResponse;
    _ = HtmlSource;
    _ = HtmlTemplate;
    _ = Lifecycle;
    _ = Metrics;
    _ = OpenMetrics;
    _ = Health;
    _ = AccessLog;
    _ = Server;
    _ = InlineText;
    _ = Multipart;
    _ = response;
    _ = response_stream;
    _ = Static;
    _ = route;
    _ = Url;
    _ = TrustedResourceUrl;
    _ = startup;
    _ = @import("internal/application/endpoint_output.zig");
    _ = @import("internal/application/json_response.zig");
    _ = @import("internal/application/multipart_upload_runtime.zig");
    _ = @import("internal/application/multipart_upload_dispatch.zig");
    _ = @import("internal/runtime/accept_controller.zig");
    _ = @import("internal/proxy/protocol_v2.zig");
    _ = @import("internal/runtime/allocation_guard.zig");
    _ = @import("internal/runtime/application_adapter.zig");
    _ = @import("internal/runtime/buffer_ring.zig");
    _ = @import("internal/runtime/config.zig");
    _ = @import("internal/runtime/connection/body.zig");
    _ = @import("internal/runtime/connection/chunked_body.zig");
    _ = @import("internal/runtime/connection/driver.zig");
    _ = @import("internal/runtime/deterministic_reactor.zig");
    _ = @import("internal/runtime/gzip/decoder.zig");
    _ = @import("internal/runtime/gzip/encoder.zig");
    _ = @import("internal/runtime/gzip/input_queue.zig");
    _ = @import("internal/runtime/gzip/output_mailbox.zig");
    _ = @import("internal/runtime/gzip/decoder_pool.zig");
    _ = @import("internal/runtime/gzip/request_jobs.zig");
    _ = @import("internal/runtime/io_uring/backend.zig");
    _ = @import("internal/runtime/listener.zig");
    _ = @import("internal/runtime/memory_budget.zig");
    _ = @import("internal/runtime/socket.zig");
    _ = @import("internal/runtime/slot_pool.zig");
    _ = @import("internal/runtime/time.zig");
    _ = @import("internal/runtime/worker.zig");
    _ = @import("internal/runtime/worker/loop.zig");
    _ = @import("internal/runtime/worker/storage.zig");
    _ = @import("internal/runtime/worker/response_chunks.zig");
    _ = @import("internal/response/stream_erasure.zig");
}

test "upload metrics primitives" {
    _ = @import("internal/runtime/worker/upload_metrics.zig");
    _ = @import("internal/runtime/worker/upload_metrics_record.zig");
    _ = @import("internal/runtime/worker/upload_route_metrics.zig");
    _ = @import("internal/runtime/worker/upload_request_route.zig");
}
