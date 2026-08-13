const std = @import("std");

pub fn select(comptime target: []const u8) type {
    if (select0(target)) |selected| return selected;
    if (select1(target)) |selected| return selected;
    if (select2(target)) |selected| return selected;
    if (select3(target)) |selected| return selected;
    if (select4(target)) |selected| return selected;
    if (select5(target)) |selected| return selected;
    @compileError("unknown fuzz target");
}

fn select0(comptime target: []const u8) ?type {
    if (eql(target, "fuzz/application_response_gzip_fuzz_check.zig")) return @import(
        "../fuzz/application_response_gzip_fuzz_check.zig",
    );
    if (eql(target, "fuzz/application_stream_output_fuzz_check.zig")) return @import(
        "../fuzz/application_stream_output_fuzz_check.zig",
    );
    if (eql(target, "fuzz/asset_http_fuzz_check.zig")) return @import(
        "../fuzz/asset_http_fuzz_check.zig",
    );
    if (eql(target, "fuzz/authority_fuzz_check.zig")) return @import(
        "../fuzz/authority_fuzz_check.zig",
    );
    if (eql(target, "fuzz/body_driver_fuzz_check.zig")) return @import(
        "../fuzz/body_driver_fuzz_check.zig",
    );
    if (eql(target, "fuzz/chunked_body_fuzz_check.zig")) return @import(
        "../fuzz/chunked_body_fuzz_check.zig",
    );
    if (eql(target, "fuzz/cors_fuzz_check.zig")) return @import(
        "../fuzz/cors_fuzz_check.zig",
    );
    if (eql(target, "fuzz/csrf_fuzz_check.zig")) return @import(
        "../fuzz/csrf_fuzz_check.zig",
    );
    if (eql(target, "fuzz/forwarding_resolver_fuzz_check.zig")) return @import(
        "../fuzz/forwarding_resolver_fuzz_check.zig",
    );
    if (eql(target, "fuzz/gzip_encoder_fuzz_check.zig")) return @import(
        "../fuzz/gzip_encoder_fuzz_check.zig",
    );
    return null;
}

fn select1(comptime target: []const u8) ?type {
    if (eql(target, "fuzz/gzip_schedule_fuzz_check.zig")) return @import(
        "../fuzz/gzip_schedule_fuzz_check.zig",
    );
    if (eql(target, "fuzz/gzip_transport_fuzz_check.zig")) return @import(
        "../fuzz/gzip_transport_fuzz_check.zig",
    );
    if (eql(target, "fuzz/html_render_fuzz_check.zig")) return @import(
        "../fuzz/html_render_fuzz_check.zig",
    );
    if (eql(target, "fuzz/html_template_fuzz_check.zig")) return @import(
        "../fuzz/html_template_fuzz_check.zig",
    );
    if (eql(target, "fuzz/internal/http1/request_trailers_fuzz.zig")) return @import(
        "../fuzz/internal/http1/request_trailers_fuzz.zig",
    );
    if (eql(target, "fuzz/internal/http1/response_fuzz.zig")) return @import(
        "../fuzz/internal/http1/response_fuzz.zig",
    );
    if (eql(target, "fuzz/internal/runtime/gzip_decoder_fuzz_check.zig")) return @import(
        "../fuzz/internal/runtime/gzip_decoder_fuzz_check.zig",
    );
    if (eql(target, "fuzz/internal/runtime/gzip_decoder_pool_fuzz_check.zig")) return @import(
        "../fuzz/internal/runtime/gzip_decoder_pool_fuzz_check.zig",
    );
    if (eql(target, "fuzz/json_encode_fuzz_check.zig")) return @import(
        "../fuzz/json_encode_fuzz_check.zig",
    );
    if (eql(target, "fuzz/json_parse_fuzz_check.zig")) return @import(
        "../fuzz/json_parse_fuzz_check.zig",
    );
    return null;
}

fn select2(comptime target: []const u8) ?type {
    if (eql(target, "fuzz/live_static_schedule_fuzz_check.zig")) return @import(
        "../fuzz/live_static_schedule_fuzz_check.zig",
    );
    if (eql(target, "fuzz/multipart_csrf_fuzz_check.zig")) return @import(
        "../fuzz/multipart_csrf_fuzz_check.zig",
    );
    if (eql(target, "fuzz/multipart_fuzz_check.zig")) return @import(
        "../fuzz/multipart_fuzz_check.zig",
    );
    if (eql(target, "fuzz/multipart_storage_key_fuzz_check.zig")) return @import(
        "../fuzz/multipart_storage_key_fuzz_check.zig",
    );
    if (eql(target, "fuzz/multipart_upload_transaction_fuzz_check.zig")) return @import(
        "../fuzz/multipart_upload_transaction_fuzz_check.zig",
    );
    if (eql(target, "fuzz/observability_fuzz_check.zig")) return @import(
        "../fuzz/observability_fuzz_check.zig",
    );
    if (eql(target, "fuzz/proxy_protocol_v2_fuzz_check.zig")) return @import(
        "../fuzz/proxy_protocol_v2_fuzz_check.zig",
    );
    if (eql(target, "fuzz/request_forwarded_fuzz_check.zig")) return @import(
        "../fuzz/request_forwarded_fuzz_check.zig",
    );
    if (eql(target, "fuzz/request_x_forwarded_fuzz_check.zig")) return @import(
        "../fuzz/request_x_forwarded_fuzz_check.zig",
    );
    if (eql(target, "fuzz/route_graph_check.zig")) return @import(
        "../fuzz/route_graph_check.zig",
    );
    return null;
}

fn select3(comptime target: []const u8) ?type {
    if (eql(target, "fuzz/runtime_fuzz_check.zig")) return @import(
        "../fuzz/runtime_fuzz_check.zig",
    );
    if (eql(target, "fuzz/server_lifecycle_fuzz_check.zig")) return @import(
        "../fuzz/server_lifecycle_fuzz_check.zig",
    );
    if (eql(target, "fuzz/static_file_fuzz_check.zig")) return @import(
        "../fuzz/static_file_fuzz_check.zig",
    );
    if (eql(target, "fuzz/stream_driver_fuzz_check.zig")) return @import(
        "../fuzz/stream_driver_fuzz_check.zig",
    );
    if (eql(target, "fuzz/stream_lifecycle_fuzz_check.zig")) return @import(
        "../fuzz/stream_lifecycle_fuzz_check.zig",
    );
    if (eql(target, "fuzz/stream_wake_fuzz_check.zig")) return @import(
        "../fuzz/stream_wake_fuzz_check.zig",
    );
    if (eql(target, "fuzz/url_for_fuzz_check.zig")) return @import(
        "../fuzz/url_for_fuzz_check.zig",
    );
    if (eql(target, "fuzz/url_fuzz_check.zig")) return @import(
        "../fuzz/url_fuzz_check.zig",
    );
    if (eql(target, "fuzz/worker_response_chunks_fuzz_check.zig")) return @import(
        "../fuzz/worker_response_chunks_fuzz_check.zig",
    );
    if (eql(target, "fuzz/worker_upload_transport_fuzz_check.zig")) return @import(
        "../fuzz/worker_upload_transport_fuzz_check.zig",
    );
    return null;
}

fn select4(comptime target: []const u8) ?type {
    if (eql(target, "src/body.zig")) return @import(
        "../src/body.zig",
    );
    if (eql(target, "src/internal/http1/chunked.zig")) return @import(
        "../src/internal/http1/chunked.zig",
    );
    if (eql(target, "src/internal/http1/query.zig")) return @import(
        "../src/internal/http1/query.zig",
    );
    if (eql(target, "src/internal/http1/request_accept_encoding.zig")) return @import(
        "../src/internal/http1/request_accept_encoding.zig",
    );
    if (eql(target, "src/internal/http1/request_content.zig")) return @import(
        "../src/internal/http1/request_content.zig",
    );
    if (eql(target, "src/internal/http1/request_expect.zig")) return @import(
        "../src/internal/http1/request_expect.zig",
    );
    if (eql(target, "src/internal/http1/request_head.zig")) return @import(
        "../src/internal/http1/request_head.zig",
    );
    if (eql(target, "src/internal/http1/request_target.zig")) return @import(
        "../src/internal/http1/request_target.zig",
    );
    if (eql(target, "src/internal/http1/request_te.zig")) return @import(
        "../src/internal/http1/request_te.zig",
    );
    if (eql(target, "src/internal/http1/response_coding_fields.zig")) return @import(
        "../src/internal/http1/response_coding_fields.zig",
    );
    return null;
}

fn select5(comptime target: []const u8) ?type {
    if (eql(target, "src/internal/http1/response_content_coding.zig")) return @import(
        "../src/internal/http1/response_content_coding.zig",
    );
    if (eql(target, "src/internal/runtime/connection/body.zig")) return @import(
        "../src/internal/runtime/connection/body.zig",
    );
    if (eql(target, "src/internal/runtime/gzip/input_queue.zig")) return @import(
        "../src/internal/runtime/gzip/input_queue.zig",
    );
    if (eql(target, "tests/unit/flat_binding_test.zig")) return @import(
        "../tests/unit/flat_binding_test.zig",
    );
    if (eql(target, "tests/unit/json_decode_test.zig")) return @import(
        "../tests/unit/json_decode_test.zig",
    );
    if (eql(target, "tests/unit/json_validate_test.zig")) return @import(
        "../tests/unit/json_validate_test.zig",
    );
    return null;
}

fn eql(comptime left: []const u8, comptime right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
