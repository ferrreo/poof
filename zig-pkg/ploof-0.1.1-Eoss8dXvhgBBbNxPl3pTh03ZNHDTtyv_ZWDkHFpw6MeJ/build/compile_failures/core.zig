const CompileFailureCase = @import("case.zig").CompileFailureCase;

pub const cases = [_]CompileFailureCase{
    .{
        .name = "server-worker-stack-minimum",
        .file = "server_worker_stack_minimum.zig",
        .message = "PLOOF-E6003 worker thread stack must be at least 65536 bytes",
    },
    .{
        .name = "server-worker-stack-maximum",
        .file = "server_worker_stack_maximum.zig",
        .message = "PLOOF-E6004 worker thread stack must not exceed 8388608 bytes",
    },
    .{
        .name = "server-worker-stack-alignment",
        .file = "server_worker_stack_alignment.zig",
        .message = "PLOOF-E6005 worker thread stack must be aligned to 4096 bytes",
    },
    .{
        .name = "response-static-bodyless",
        .file = "response_static_bodyless.zig",
        .message = "PLOOF-E3040 invalid static response status/body combination",
    },
    .{
        .name = "response-static-media",
        .file = "response_static_media.zig",
        .message = "PLOOF-E3041 invalid static response media type",
    },
    .{
        .name = "response-stream-static-bodyless",
        .file = "response_stream_static_bodyless.zig",
        .message = "PLOOF-E3040 invalid static response status/body combination",
    },
    .{
        .name = "response-stream-static-media",
        .file = "response_stream_static_media.zig",
        .message = "PLOOF-E3041 invalid static response media type",
    },
    .{
        .name = "response-static-header",
        .file = "response_static_header.zig",
        .message = "PLOOF-E3042 invalid static response header",
    },
    .{
        .name = "response-static-reserved",
        .file = "response_static_reserved.zig",
        .message = "PLOOF-E3043 static response header uses a reserved field",
    },
    .{
        .name = "response-static-singleton-append",
        .file = "response_static_singleton_append.zig",
        .message = "PLOOF-E3044 static response header cannot append a singleton field",
    },
    .{
        .name = "response-logical-limits",
        .file = "response_logical_limits.zig",
        .message = "PLOOF-E3045 logical response-head limits exceed workspace maximum",
    },
    .{
        .name = "response-static-server",
        .file = "response_static_server.zig",
        .message = "PLOOF-E3047 invalid static Server identity",
    },
    .{
        .name = "static-dir-mount",
        .file = "static_dir_mount.zig",
        .message = "PLOOF-E4102 invalid static URL mount",
    },
    .{
        .name = "static-file-relative-path",
        .file = "static_file_relative_path.zig",
        .message = "PLOOF-E4106 invalid static-file relative path",
    },
    .{
        .name = "static-cache-control",
        .file = "static_cache_control.zig",
        .message = "PLOOF-E4105 invalid static Cache-Control policy",
    },
    .{
        .name = "static-limits",
        .file = "static_limits.zig",
        .message = "PLOOF-E4101 invalid static-file limits",
    },
    .{
        .name = "application-mid-catch-all",
        .file = "application_mid_catch_all.zig",
        .message = "PLOOF-E3027 route catch-all must be terminal",
    },
    .{
        .name = "application-structural-conflict",
        .file = "application_structural_conflict.zig",
        .message = "PLOOF-E3030 structurally equivalent routes conflict",
    },
    .{
        .name = "application-route-segments-total",
        .file = "application_route_segments_total.zig",
        .message = "PLOOF-E3120 route graph segments exceed configured aggregate limit",
    },
    .{
        .name = "application-route-pattern-bytes-total",
        .file = "application_route_pattern_bytes_total.zig",
        .message = "PLOOF-E3121 route graph pattern bytes exceed configured aggregate limit",
    },
    .{
        .name = "application-route-index-nodes",
        .file = "application_route_index_nodes.zig",
        .message = "PLOOF-E3122 route graph index nodes exceed configured limit",
    },
    .{
        .name = "application-route-search-visits",
        .file = "application_route_search_visits.zig",
        .message = "PLOOF-E3123 route graph search visits exceed configured limit",
    },
    .{
        .name = "application-route-search-compare-bytes",
        .file = "application_route_search_compare_bytes.zig",
        .message = "PLOOF-E3124 route graph search compared bytes exceed configured limit",
    },
    .{
        .name = "application-missing-state",
        .file = "application_missing_state.zig",
        .message = "PLOOF-E3050 Application requires State",
    },
    .{
        .name = "application-missing-routes",
        .file = "application_missing_routes.zig",
        .message = "PLOOF-E3051 Application requires routes",
    },
    .{
        .name = "application-invalid-state",
        .file = "application_invalid_state.zig",
        .message = "PLOOF-E3052 Application State must be a type",
    },
    .{
        .name = "application-middleware-not-tuple",
        .file = "application_middleware_not_tuple.zig",
        .message = "PLOOF-E3053 Application middleware must be a tuple",
    },
    .{
        .name = "application-routes-not-tuple",
        .file = "application_routes_not_tuple.zig",
        .message = "PLOOF-E3054 Application routes must be a tuple",
    },
    .{
        .name = "application-assets-type",
        .file = "application_assets_type.zig",
        .message = "PLOOF-E5120 Application assets must be an Asset.Bundle type",
    },
    .{
        .name = "application-asset-route-conflict",
        .file = "application_asset_route_conflict.zig",
        .message = "PLOOF-E3030 structurally equivalent routes conflict",
    },
    .{
        .name = "application-cors-type",
        .file = "application_cors_type.zig",
        .message = "PLOOF-E3308 cors must be ploof.Cors.Policy",
    },
    .{
        .name = "cors-invalid-origin",
        .file = "cors_invalid_origin.zig",
        .message = "PLOOF-E3302 invalid exact CORS origin",
    },
    .{
        .name = "application-cors-field-line",
        .file = "application_cors_field_line.zig",
        .message = "PLOOF-E3309 CORS application field line limit is below 77 bytes",
    },
    .{
        .name = "application-route-cors-field-line",
        .file = "application_route_cors_field_line.zig",
        .message = "PLOOF-E3310 CORS route field line limit is below 77 bytes",
    },
    .{
        .name = "application-route-count",
        .file = "application_route_count.zig",
        .message = "PLOOF-E3055 Application route count exceeds u16",
    },
    .{
        .name = "application-multipart-file-route-count",
        .file = "application_multipart_file_route_count.zig",
        .message = "PLOOF-E3536 multipart file route count exceeds 512",
    },
    .{
        .name = "application-error-not-error-set",
        .file = "application_error_not_error_set.zig",
        .message = "PLOOF-E3056 Application Error must be an error set",
    },
    .{
        .name = "application-anyerror",
        .file = "application_anyerror.zig",
        .message = "PLOOF-E3057 Application Error must be finite",
    },
    .{
        .name = "application-response-limits",
        .file = "application_response_limits.zig",
        .message = "PLOOF-E3058 response limits exceed Application workspace maximum",
    },
    .{
        .name = "application-response-body-type",
        .file = "application_response_body_type.zig",
        .message = "PLOOF-E3090 response_body_bytes_max must be an integer",
    },
    .{
        .name = "application-response-body-limit",
        .file = "application_response_body_limit.zig",
        .message = "PLOOF-E3091 response_body_bytes_max must be between zero and 16 MiB",
    },
    .{
        .name = "application-invalid-mapper",
        .file = "application_invalid_mapper.zig",
        .message = "PLOOF-E3059 map_error must be fn (*Context, Error) Response",
    },
    .{
        .name = "application-group-prefix-start",
        .file = "application_group_prefix_start.zig",
        .message = "PLOOF-E3060 group prefix must begin with '/'",
    },
    .{
        .name = "application-group-prefix-end",
        .file = "application_group_prefix_end.zig",
        .message = "PLOOF-E3061 group prefix must not end with '/'",
    },
    .{
        .name = "application-middleware-count",
        .file = "application_middleware_count.zig",
        .message = "PLOOF-E3062 route middleware chain exceeds configured limit",
    },
    .{
        .name = "application-middleware-state",
        .file = "application_middleware_state.zig",
        .message = "PLOOF-E3063 route middleware state exceeds configured byte limit",
    },
    .{
        .name = "application-route-middleware-not-tuple",
        .file = "application_route_middleware_not_tuple.zig",
        .message = "PLOOF-E3064 middleware chain must be a tuple",
    },
    .{
        .name = "application-middleware-missing-state",
        .file = "application_middleware_missing_state.zig",
        .message = "PLOOF-E3065 middleware must declare State",
    },
    .{
        .name = "application-middleware-invalid-state",
        .file = "application_middleware_invalid_state.zig",
        .message = "PLOOF-E3066 middleware State must be a type",
    },
    .{
        .name = "application-middleware-missing-init",
        .file = "application_middleware_missing_init.zig",
        .message = "PLOOF-E3067 non-void middleware State requires init",
    },
    .{
        .name = "application-middleware-invalid-init",
        .file = "application_middleware_invalid_init.zig",
        .message = "PLOOF-E3068 invalid init signature",
    },
    .{
        .name = "application-middleware-invalid-head",
        .file = "application_middleware_invalid_head.zig",
        .message = "PLOOF-E3069 invalid head signature",
    },
    .{
        .name = "application-middleware-invalid-body",
        .file = "application_middleware_invalid_body.zig",
        .message = "PLOOF-E3070 invalid body signature",
    },
    .{
        .name = "application-middleware-invalid-response",
        .file = "application_middleware_invalid_response.zig",
        .message = "PLOOF-E3071 invalid response signature",
    },
    .{
        .name = "application-middleware-invalid-after",
        .file = "application_middleware_invalid_after.zig",
        .message = "PLOOF-E3072 invalid after signature",
    },
    .{
        .name = "application-invalid-handler",
        .file = "application_invalid_handler.zig",
        .message = "PLOOF-E3073 invalid handler signature",
    },
    .{
        .name = "application-anyerror-handler",
        .file = "application_anyerror_handler.zig",
        .message = "PLOOF-E3074 middleware and handler errors must be finite",
    },
    .{
        .name = "application-undeclared-error",
        .file = "application_undeclared_error.zig",
        .message = "PLOOF-E3075 undeclared Application error",
    },
    .{
        .name = "application-html-undeclared-error",
        .file = "application_html_undeclared_error.zig",
        .message = "PLOOF-E3075 undeclared Application error",
    },
    .{
        .name = "application-child-path",
        .file = "application_child_path.zig",
        .message = "PLOOF-E3076 child route path must begin with '/'",
    },
    .{
        .name = "body-encoded-limit-zero",
        .file = "body_encoded_limit_zero.zig",
        .message = "PLOOF-E3077 encoded-wire body byte limit must be nonzero",
    },
    .{
        .name = "body-decoded-limit-zero",
        .file = "body_decoded_limit_zero.zig",
        .message = "PLOOF-E3078 decoded body byte limit must be nonzero",
    },
    .{
        .name = "body-media-count",
        .file = "body_media_count.zig",
        .message = "PLOOF-E3079 body decoder must accept one to four media patterns",
    },
    .{
        .name = "body-invalid-exact-media",
        .file = "body_invalid_exact_media.zig",
        .message = "PLOOF-E3080 invalid exact body media pattern",
    },
    .{
        .name = "body-invalid-media-wildcard",
        .file = "body_invalid_media_wildcard.zig",
        .message = "PLOOF-E3081 invalid body media type wildcard",
    },
    .{
        .name = "body-decoded-limit-u32",
        .file = "body_decoded_limit_u32.zig",
        .message = "PLOOF-E3082 buffered decoded body limit exceeds u32; use streaming body API",
    },
    .{
        .name = "endpoint-overlapping-media",
        .file = "endpoint_overlapping_media.zig",
        .message = "PLOOF-E3257 overlapping body decoder media patterns",
    },
    .{
        .name = "endpoint-response-json-limit-zero",
        .file = "endpoint_response_json_limit_zero.zig",
        .message = "PLOOF-E3248 Endpoint response_json_bytes_max must fit a positive usize",
    },
    .{
        .name = "endpoint-response-json-limit-type",
        .file = "endpoint_response_json_limit_type.zig",
        .message = "PLOOF-E3530 Endpoint response_json_bytes_max must be a positive integer",
    },
    .{
        .name = "body-alternatives-not-struct",
        .file = "body_alternatives_not_struct.zig",
        .message = "PLOOF-E3240 body decoders must be a named struct literal",
    },
    .{
        .name = "body-alternatives-tuple",
        .file = "body_alternatives_tuple.zig",
        .message = "PLOOF-E3528 body decoders must use named tags",
    },
    .{
        .name = "endpoint-config-not-struct",
        .file = "endpoint_config_not_struct.zig",
        .message = "PLOOF-E3244 Endpoint config must be a struct literal",
    },
    .{
        .name = "endpoint-config-tuple",
        .file = "endpoint_config_tuple.zig",
        .message = "PLOOF-E3529 Endpoint config must use named fields",
    },
    .{
        .name = "json-parse-memory-root",
        .file = "json_parse_memory_root.zig",
        .message = "PLOOF-E3269 JSON parse memory limit cannot hold root and required plans",
    },
    .{
        .name = "json-parse-memory-plan",
        .file = "json_parse_memory_plan.zig",
        .message = "PLOOF-E3269 JSON parse memory limit cannot hold root and required plans",
    },
    .{
        .name = "json-parse-non-function",
        .file = "json_parse_non_function.zig",
        .message = "PLOOF-E3218 jsonParse must be fn (anytype) json.ParseError!Self",
    },
    .{
        .name = "json-parse-parameter",
        .file = "json_parse_parameter.zig",
        .message = "PLOOF-E3218 jsonParse must be fn (anytype) json.ParseError!Self",
    },
    .{
        .name = "json-parse-comptime-parameter",
        .file = "json_parse_comptime_parameter.zig",
        .message = "PLOOF-E3218 jsonParse must be fn (anytype) json.ParseError!Self",
    },
    .{
        .name = "json-parse-payload",
        .file = "json_parse_payload.zig",
        .message = "PLOOF-E3219 jsonParse must return exactly json.ParseError!Self",
    },
    .{
        .name = "json-parse-error-set",
        .file = "json_parse_error_set.zig",
        .message = "PLOOF-E3219 jsonParse must return exactly json.ParseError!Self",
    },
    .{
        .name = "json-decode-packed-struct",
        .file = "json_decode_packed_struct.zig",
        .message = "PLOOF-E3272 packed structs are unsupported by JSON decode",
    },
    .{
        .name = "json-decode-comptime-field",
        .file = "json_decode_comptime_field.zig",
        .message = "PLOOF-E3273 comptime fields are unsupported by JSON decode",
    },
    .{
        .name = "json-stringify-undeclared-error",
        .file = "json_stringify_undeclared_error.zig",
        .message = "PLOOF-E3228 jsonStringify must return exactly " ++
            "json.Error || JsonApplicationError",
    },
    .{
        .name = "json-stringify-framework-collision",
        .file = "json_stringify_framework_collision.zig",
        .message = "PLOOF-E3227 JsonApplicationError collides with json.Error",
    },
    .{
        .name = "json-stringify-application-anyerror",
        .file = "json_stringify_application_anyerror.zig",
        .message = "PLOOF-E3229 JsonApplicationError must be a finite error set",
    },
    .{
        .name = "application-response-gzip-type",
        .file = "application_response_gzip_type.zig",
        .message = "PLOOF-E3083 response_gzip must be ploof.ResponseGzip",
    },
    .{
        .name = "application-response-gzip-capacity",
        .file = "application_response_gzip_capacity.zig",
        .message = "PLOOF-E3084 response gzip framework fallback exceeds application limits",
    },
    .{
        .name = "runtime-response-gzip-capacity",
        .file = "runtime_response_gzip_capacity.zig",
        .message = "PLOOF-E3085 response staging cannot hold response gzip framework fallback",
    },
    .{
        .name = "runtime-startup-io-timeout-zero",
        .file = "runtime_startup_io_timeout_zero.zig",
        .message = "startup I/O timeout must be nonzero",
    },
    .{
        .name = "response-stream-poll-signature",
        .file = "response_stream_poll_signature.zig",
        .message = "PLOOF-E3106 invalid stream producer poll signature",
    },
    .{
        .name = "response-stream-lifecycle-signature",
        .file = "response_stream_lifecycle_signature.zig",
        .message = "PLOOF-E3527 invalid stream producer lifecycle signature",
    },
    .{
        .name = "response-stream-join-signature",
        .file = "response_stream_join_signature.zig",
        .message = "PLOOF-E3527 invalid stream producer lifecycle signature",
    },
    .{
        .name = "response-stream-workspace-size",
        .file = "response_stream_workspace_size.zig",
        .message = "PLOOF-E3104 stream producer exceeds workspace byte limit",
    },
    .{
        .name = "response-stream-workspace-alignment",
        .file = "response_stream_workspace_alignment.zig",
        .message = "PLOOF-E3105 stream producer exceeds workspace alignment limit",
    },
    .{
        .name = "application-invalid-body-handler",
        .file = "application_invalid_body_handler.zig",
        .message = "PLOOF-E3073 invalid handler signature",
    },
    .{
        .name = "application-body-middleware-type",
        .file = "application_body_middleware_type.zig",
        .message = "PLOOF-E3070 invalid body signature",
    },
    .{
        .name = "multipart-consumer-not-struct",
        .file = "multipart_consumer_not_struct.zig",
        .message = "PLOOF-E3450 multipart endpoint handler must be a consumer struct",
    },
    .{
        .name = "multipart-consumer-missing-state",
        .file = "multipart_consumer_missing_state.zig",
        .message = "PLOOF-E3451 multipart consumer must declare State",
    },
    .{
        .name = "multipart-consumer-missing-init",
        .file = "multipart_consumer_missing_init.zig",
        .message = "PLOOF-E3452 non-void multipart consumer State requires init",
    },
    .{
        .name = "multipart-consumer-missing-field",
        .file = "multipart_consumer_missing_field.zig",
        .message = "PLOOF-E3453 multipart consumer must handle declared fields",
    },
};
