const CompileFailureCase = @import("case.zig").CompileFailureCase;

pub const cases = [_]CompileFailureCase{
    .{
        .name = "multipart-consumer-missing-complete",
        .file = "multipart_consumer_missing_complete.zig",
        .message = "PLOOF-E3454 multipart consumer must declare complete",
    },
    .{
        .name = "multipart-consumer-invalid-init",
        .file = "multipart_consumer_invalid_init.zig",
        .message = "PLOOF-E3455 invalid multipart consumer init signature",
    },
    .{
        .name = "multipart-consumer-invalid-field",
        .file = "multipart_consumer_invalid_field.zig",
        .message = "PLOOF-E3456 invalid multipart consumer field signature",
    },
    .{
        .name = "multipart-consumer-invalid-complete",
        .file = "multipart_consumer_invalid_complete.zig",
        .message = "PLOOF-E3457 invalid multipart consumer complete signature",
    },
    .{
        .name = "multipart-consumer-missing-file-start",
        .file = "multipart_consumer_missing_file_start.zig",
        .message = "PLOOF-E3458 multipart consumer must declare fileStart",
    },
    .{
        .name = "multipart-consumer-invalid-file-start",
        .file = "multipart_consumer_invalid_file_start.zig",
        .message = "PLOOF-E3459 invalid multipart consumer fileStart signature",
    },
    .{
        .name = "multipart-consumer-generic-file-start",
        .file = "multipart_consumer_generic_file_start.zig",
        .message = "PLOOF-E3459 invalid multipart consumer fileStart signature",
    },
    .{
        .name = "multipart-upload-runtime-generic-file-start",
        .file = "application_multipart_upload_runtime_invalid_fixture.zig",
        .message = "PLOOF-E3459 invalid multipart consumer fileStart signature",
    },
    .{
        .name = "multipart-runtime-sink-contract",
        .file = "application_multipart_runtime_sink_contract_invalid_fixture.zig",
        .message = "PLOOF-E3522 custom multipart sinks require the M9 sink contract",
    },
    .{
        .name = "multipart-consumer-custom-sink",
        .file = "multipart_consumer_custom_sink.zig",
        .message = "PLOOF-E3468 multipart sink must declare State",
    },
    .{
        .name = "reactor-invalid-io-requirements",
        .file = "io_uring_capabilities_invalid_fixture.zig",
        .message = "PLOOF-E3504 invalid reactor I/O requirements",
    },
    .{
        .name = "runtime-file-lease-capacity",
        .file = "runtime_capacity_file_lease_invalid_fixture.zig",
        .message = "PLOOF-E3505 runtime file lease capacity exceeds u32",
    },
    .{
        .name = "filesink-missing-durability",
        .file = "multipart_file_sink_config_invalid_fixture.zig",
        .message = "PLOOF-E3510 FileSink durability must be explicit",
    },
    .{
        .name = "filesink-storage-key-maximum",
        .file = "multipart_file_sink_config_key_max_invalid_fixture.zig",
        .message = "PLOOF-E3518 FileSink storage-key byte maximum exceeds 4095",
    },
    .{
        .name = "filesink-root-maximum",
        .file = "multipart_file_sink_config_root_max_invalid_fixture.zig",
        .message = "PLOOF-E3531 FileSink root exceeds 4095 bytes",
    },
    .{
        .name = "upload-capable-reactor-required",
        .file = "worker_upload_reactor_invalid_fixture.zig",
        .message = "PLOOF-E3523 upload application requires upload-capable reactor",
    },
    .{
        .name = "upload-target-capacity-positive",
        .file = "worker_upload_target_capacity_invalid_fixture.zig",
        .message = "PLOOF-E3524 upload reactor target capacity must be positive",
    },
    .{
        .name = "upload-window-positive",
        .file = "worker_upload_window_invalid_fixture.zig",
        .message = "PLOOF-E3525 async upload window must be positive",
    },
    .{
        .name = "startup-application-type",
        .file = "startup_application_invalid_fixture.zig",
        .message = "PLOOF-E3526 startup requires a Ploof Application type",
    },
    .{
        .name = "upload-route-metric-cell-bound",
        .file = "worker_upload_route_metric_cell_invalid_fixture.zig",
        .message = "PLOOF-E3532 upload route metric cell exceeds 640 bytes",
    },
    .{
        .name = "upload-route-profiles-required",
        .file = "worker_upload_route_profiles_empty_invalid_fixture.zig",
        .message = "PLOOF-E3533 async upload application has no route profiles",
    },
    .{
        .name = "upload-route-window-bound",
        .file = "worker_upload_route_window_invalid_fixture.zig",
        .message = "PLOOF-E3534 upload route window is outside application maximum",
    },
    .{
        .name = "upload-route-profile-unique",
        .file = "worker_upload_route_duplicate_invalid_fixture.zig",
        .message = "PLOOF-E3535 upload route profiles must be unique and strictly ascending",
    },
    .{
        .name = "csrf-origin-capacity",
        .file = "csrf_origin_capacity.zig",
        .message = "PLOOF-E3600 CSRF origin capacity must be between 1 and 64",
    },
    .{
        .name = "csrf-origin-host-limit",
        .file = "csrf_origin_host_limit.zig",
        .message = "PLOOF-E3601 CSRF origin host limit must be between 1 and 1024 bytes",
    },
    .{
        .name = "csrf-missing-load",
        .file = "csrf_missing_load.zig",
        .message = "PLOOF-E3602 CSRF synchronizer requires load",
    },
    .{
        .name = "csrf-missing-store",
        .file = "csrf_missing_store.zig",
        .message = "PLOOF-E3603 CSRF synchronizer requires store",
    },
    .{
        .name = "csrf-missing-clear",
        .file = "csrf_missing_clear.zig",
        .message = "PLOOF-E3604 CSRF synchronizer requires clear",
    },
    .{
        .name = "csrf-missing-keys",
        .file = "csrf_missing_keys.zig",
        .message = "PLOOF-E3605 signed CSRF requires keys",
    },
    .{
        .name = "csrf-missing-binding",
        .file = "csrf_missing_binding.zig",
        .message = "PLOOF-E3606 signed CSRF requires binding",
    },
    .{
        .name = "csrf-invalid-cookie-name",
        .file = "csrf_invalid_cookie_name.zig",
        .message = "PLOOF-E3607 invalid CSRF cookie name",
    },
    .{
        .name = "csrf-tuple-config",
        .file = "csrf_tuple_config.zig",
        .message = "PLOOF-E3608 CSRF configuration must be a named struct",
    },
    .{
        .name = "csrf-missing-origins",
        .file = "csrf_missing_origins.zig",
        .message = "PLOOF-E3609 CSRF requires origins",
    },
    .{
        .name = "csrf-invalid-header-name",
        .file = "csrf_invalid_header_name.zig",
        .message = "PLOOF-E3610 invalid CSRF header name",
    },
    .{
        .name = "csrf-invalid-form-name",
        .file = "csrf_invalid_form_name.zig",
        .message = "PLOOF-E3611 invalid CSRF form field name",
    },
    .{
        .name = "csrf-load-signature",
        .file = "csrf_load_signature.zig",
        .message = "PLOOF-E3612 CSRF load must be fn (*Context) ?SessionToken",
    },
    .{
        .name = "csrf-store-signature",
        .file = "csrf_store_signature.zig",
        .message = "PLOOF-E3613 CSRF store must be fn (*Context, SessionToken) void",
    },
    .{
        .name = "csrf-clear-signature",
        .file = "csrf_clear_signature.zig",
        .message = "PLOOF-E3614 CSRF clear must be fn (*Context) void",
    },
    .{
        .name = "csrf-keys-signature",
        .file = "csrf_keys_signature.zig",
        .message = "PLOOF-E3615 signed CSRF keys must be fn " ++
            "(*const ApplicationState) *const Keyring",
    },
    .{
        .name = "csrf-binding-signature",
        .file = "csrf_binding_signature.zig",
        .message = "PLOOF-E3616 signed CSRF binding must be fn (*Context) ?LoginBinding",
    },
    .{
        .name = "csrf-origins-signature",
        .file = "csrf_origins_signature.zig",
        .message = "PLOOF-E3617 CSRF origins must be fn " ++
            "(*const ApplicationState) *const OriginSet",
    },
    .{
        .name = "application-csrf-multiple-policy",
        .file = "application_csrf_multiple_policy.zig",
        .message = "PLOOF-E3618 route has more than one effective CSRF policy",
    },
    .{
        .name = "application-csrf-reserved-form",
        .file = "application_csrf_reserved_form.zig",
        .message = "PLOOF-E3619 typed form target declares reserved CSRF field",
    },
    .{
        .name = "application-csrf-multipart-no-policy",
        .file = "application_csrf_multipart_no_policy.zig",
        .message = "PLOOF-E3620 multipart CSRF field requires an effective CSRF policy",
    },
    .{
        .name = "application-csrf-multipart-name",
        .file = "application_csrf_multipart_name.zig",
        .message = "PLOOF-E3621 multipart CSRF field name must match CSRF policy form name",
    },
    .{
        .name = "application-csrf-head-capacity",
        .file = "application_csrf_head_capacity.zig",
        .message = "PLOOF-E3622 CSRF response head limit is below 39 bytes",
    },
    .{
        .name = "application-csrf-multipart-duplicate",
        .file = "application_csrf_multipart_duplicate.zig",
        .message = "PLOOF-E3623 multipart body declares more than one CSRF field",
    },
    .{
        .name = "application-csrf-body-order",
        .file = "application_csrf_body_order.zig",
        .message = "PLOOF-E3625 body middleware precedes CSRF policy; " ++
            "move CSRF earlier or split head and body middleware",
    },
    .{
        .name = "csrf-sync-unknown-field",
        .file = "csrf_sync_unknown_field.zig",
        .message = "PLOOF-E3626 unknown CSRF synchronizer configuration field",
    },
    .{
        .name = "csrf-signed-unknown-field",
        .file = "csrf_signed_unknown_field.zig",
        .message = "PLOOF-E3627 unknown signed CSRF configuration field",
    },
    .{
        .name = "csrf-header-name-type",
        .file = "csrf_header_name_type.zig",
        .message = "PLOOF-E3628 CSRF header_name must be a string",
    },
    .{
        .name = "csrf-form-name-type",
        .file = "csrf_form_name_type.zig",
        .message = "PLOOF-E3629 CSRF form_name must be a string",
    },
    .{
        .name = "csrf-cookie-name-type",
        .file = "csrf_cookie_name_type.zig",
        .message = "PLOOF-E3630 signed CSRF cookie_name must be a string",
    },
    .{
        .name = "csrf-source-origins-signature",
        .file = "csrf_source_origins_signature.zig",
        .message = "PLOOF-E3631 CSRF source_origins must be fn " ++
            "(*const ApplicationState) *const OriginSet",
    },
    .{
        .name = "url-limit-zero",
        .file = "url_limit_zero.zig",
        .message = "PLOOF-E3700 URL byte limit must be nonzero",
    },
    .{
        .name = "url-limit-hard-max",
        .file = "url_limit_above_hard.zig",
        .message = "PLOOF-E3701 URL byte limit exceeds 64 KiB",
    },
    .{
        .name = "url-policy-https",
        .file = "url_policy_no_https.zig",
        .message = "PLOOF-E3702 web URL policy must select HTTPS hosts",
    },
    .{
        .name = "url-policy-empty-hosts",
        .file = "url_policy_empty_hosts.zig",
        .message = "PLOOF-E3703 HTTPS host allowlist must contain 1 to 64 hosts",
    },
    .{
        .name = "url-policy-invalid-host",
        .file = "url_policy_invalid_host.zig",
        .message = "PLOOF-E3704 invalid HTTPS web URL host: bad_host",
    },
    .{
        .name = "inline-text-limit-zero",
        .file = "inline_text_zero.zig",
        .message = "PLOOF-E3705 InlineText byte limit must be nonzero",
    },
    .{
        .name = "inline-text-limit-hard-max",
        .file = "inline_text_above_hard.zig",
        .message = "PLOOF-E3706 InlineText byte limit exceeds 64 KiB",
    },
    .{
        .name = "trusted-resource-invalid-literal",
        .file = "trusted_resource_invalid_literal.zig",
        .message = "PLOOF-E3710 invalid trusted resource URL literal: UnsupportedScheme",
    },
    .{
        .name = "trusted-resource-http-literal",
        .file = "trusted_resource_http_literal.zig",
        .message = "PLOOF-E3711 trusted resource URL literal must use HTTPS",
    },
    .{
        .name = "trusted-resource-runtime-literal",
        .file = "trusted_resource_runtime_literal.zig",
        .message = "argument to comptime parameter must be comptime-known",
    },
    .{
        .name = "trusted-resource-key-type",
        .file = "trusted_resource_table_key_type.zig",
        .message = "PLOOF-E3712 trusted resource table key must be an enum",
    },
    .{
        .name = "trusted-resource-empty-keys",
        .file = "trusted_resource_table_empty_keys.zig",
        .message = "PLOOF-E3713 trusted resource table must have 1 to 256 exhaustive keys",
    },
    .{
        .name = "trusted-resource-limit-zero",
        .file = "trusted_resource_table_limit_zero.zig",
        .message = "PLOOF-E3714 trusted resource table URL limit must be 1 to 65536 bytes",
    },
    .{
        .name = "trusted-resource-empty-origins",
        .file = "trusted_resource_table_empty_origins.zig",
        .message = "PLOOF-E3715 trusted resource origin allowlist must contain 1 to 64 origins",
    },
    .{
        .name = "trusted-resource-invalid-origin",
        .file = "trusted_resource_invalid_origin.zig",
        .message = "PLOOF-E3716 invalid trusted resource origin at index 0: UnsupportedScheme",
    },
    .{
        .name = "url-for-group",
        .file = "url_for_group_descriptor.zig",
        .message = "PLOOF-E3720 urlFor requires a route descriptor",
    },
    .{
        .name = "url-for-catch-all",
        .file = "url_for_catch_all.zig",
        .message = "PLOOF-E3722 urlFor catch-all needs an explicit segment-list type",
    },
    .{
        .name = "url-for-missing-path",
        .file = "url_for_missing_path.zig",
        .message = "PLOOF-E3724 missing urlFor path parameter: id",
    },
    .{
        .name = "url-for-extra-path",
        .file = "url_for_extra_path.zig",
        .message = "PLOOF-E3725 extra urlFor path parameter: other",
    },
    .{
        .name = "url-for-path-type",
        .file = "url_for_wrong_path_type.zig",
        .message = "PLOOF-E3726 unsupported path parameter type: id",
    },
    .{
        .name = "url-for-query-tuple",
        .file = "url_for_query_tuple.zig",
        .message = "PLOOF-E3727 urlFor query must be a named struct",
    },
    .{
        .name = "url-for-query-type",
        .file = "url_for_query_wrong_type.zig",
        .message = "PLOOF-E3728 unsupported query field type: nested",
    },
    .{
        .name = "url-for-query-name",
        .file = "url_for_duplicate_query_name.zig",
        .message = "PLOOF-E3729 duplicate urlFor query wire name",
    },
    .{
        .name = "url-for-limit-zero",
        .file = "url_for_limit_zero.zig",
        .message = "PLOOF-E3730 urlFor byte limit must be 1 to 65536 bytes",
    },
    .{
        .name = "url-for-query-hard-max",
        .file = "url_for_query_limit_above_hard.zig",
        .message = "PLOOF-E3731 urlFor query pair limit must be 1 to 4096",
    },
    .{
        .name = "url-for-dot-literal",
        .file = "url_for_dot_literal.zig",
        .message = "PLOOF-E3732 route literal is unsafe for browser URL construction",
    },
    .{
        .name = "route-target-group",
        .file = "url_for_target_group_descriptor.zig",
        .message = "PLOOF-E3733 routeTarget requires a route descriptor",
    },
    .{
        .name = "route-target-unmounted",
        .file = "url_for_target_not_mounted.zig",
        .message = "PLOOF-E3734 routeTarget descriptor is not in Application routes",
    },
    .{
        .name = "route-target-altered-descriptor",
        .file = "url_for_target_altered_descriptor.zig",
        .message = "PLOOF-E3734 routeTarget descriptor is not in Application routes",
    },
    .{
        .name = "route-target-duplicate",
        .file = "url_for_target_duplicate_mount.zig",
        .message = "PLOOF-E3735 routeTarget descriptor is mounted more than once",
    },
    .{
        .name = "route-target-capture-conflict",
        .file = "url_for_target_capture_conflict.zig",
        .message = "PLOOF-E3028 route capture names must be unique",
    },
    .{
        .name = "route-target-internal-constructor",
        .file = "url_for_target_internal_constructor.zig",
        .message = "no member named '__target'",
    },
    .{
        .name = "html-source-duplicate-attribute",
        .file = "html_source_duplicate_attribute_invalid_fixture.zig",
        .message = "PLOOF-E3825 HTML source duplicate_attribute; graph 'fixture-graph', " ++
            "file 'views/duplicate.html', line 2, column 13; related line 2, column 6",
    },
    .{
        .name = "trusted-html-limit-zero",
        .file = "html_trusted_limit_zero.zig",
        .message = "PLOOF-E3901 TrustedHtml byte limit must be nonzero",
    },
    .{
        .name = "trusted-html-limit-hard-max",
        .file = "html_trusted_limit_above_hard.zig",
        .message = "PLOOF-E3902 TrustedHtml byte limit exceeds 1 MiB",
    },
    .{
        .name = "trusted-html-literal-bound",
        .file = "html_trusted_literal_bound.zig",
        .message = "PLOOF-E3903 TrustedHtml literal exceeds its byte limit",
    },
};
