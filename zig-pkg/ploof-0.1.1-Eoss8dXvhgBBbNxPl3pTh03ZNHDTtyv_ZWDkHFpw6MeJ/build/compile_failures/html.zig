const CompileFailureCase = @import("case.zig").CompileFailureCase;

pub const cases = [_]CompileFailureCase{
    .{
        .name = "html-format-text-function",
        .file = "html_format_text_not_function.zig",
        .message = "PLOOF-E3904 formatText must be a function",
    },
    .{
        .name = "html-format-text-signature",
        .file = "html_format_text_signature.zig",
        .message = "PLOOF-E3905 formatText requires one concrete self value",
    },
    .{
        .name = "html-format-text-comptime-self",
        .file = "html_format_text_comptime_self.zig",
        .message = "PLOOF-E3905 formatText requires one concrete self value",
    },
    .{
        .name = "html-format-text-capability",
        .file = "html_format_text_capability.zig",
        .message = "PLOOF-E3914 formatText self carries a mutable or framework capability",
    },
    .{
        .name = "html-format-text-error-set",
        .file = "html_format_text_anyerror.zig",
        .message = "PLOOF-E3907 formatText requires a finite error set",
    },
    .{
        .name = "html-format-text-return",
        .file = "html_format_text_return.zig",
        .message = "PLOOF-E3908 formatText must return InlineText(N)",
    },
    .{
        .name = "html-untrusted-raw",
        .file = "html_untrusted_raw.zig",
        .message = "PLOOF-E3909 raw HTML requires TrustedHtml(N)",
    },
    .{
        .name = "trusted-html-literal-directive",
        .file = "html_trusted_literal_directive.zig",
        .message = "PLOOF-E3910 TrustedHtml literal cannot contain directives",
    },
    .{
        .name = "html-browser-json-name-start",
        .file = "html_browser_json_name_start.zig",
        .message = "PLOOF-E3911 browser JSON name must start with an ASCII letter",
    },
    .{
        .name = "html-browser-json-name-byte",
        .file = "html_browser_json_name_byte.zig",
        .message = "PLOOF-E3912 browser JSON name contains an invalid byte",
    },
    .{
        .name = "html-static-svg-envelope",
        .file = "html_static_svg_envelope.zig",
        .message = "PLOOF-E3913 static SVG must be an svg element",
    },
    .{
        .name = "html-value-type",
        .file = "html_value_float.zig",
        .message = "PLOOF-E3915 unsupported template text type 'f64'",
    },
    .{
        .name = "html-trusted-html-spoof",
        .file = "html_trusted_html_spoof.zig",
        .message = "PLOOF-E3909 raw HTML requires TrustedHtml(N)",
    },
    .{
        .name = "html-template-anyerror-helper",
        .file = "html_template_anyerror_helper.zig",
        .message = "PLOOF-E4013 HTML template helper_anyerror",
    },
    .{
        .name = "html-template-allowzero-path",
        .file = "html_template_allowzero_path.zig",
        .message = "PLOOF-E4006 HTML template non_struct_path",
    },
    .{
        .name = "html-template-browser-json-limit",
        .file = "html_template_browser_json_limit.zig",
        .message = "PLOOF-E4029 HTML template browser_json_limit",
    },
    .{
        .name = "html-template-encoded-limit-type",
        .file = "html_template_encoded_limit_type.zig",
        .message = "PLOOF-E3960 template encoded byte limit must be an integer",
    },
    .{
        .name = "html-template-encoded-limit-zero",
        .file = "html_template_encoded_limit_zero.zig",
        .message = "PLOOF-E3961 template encoded byte limit must be nonzero",
    },
    .{
        .name = "html-template-encoded-limit-hard-max",
        .file = "html_template_encoded_limit_hard_max.zig",
        .message = "PLOOF-E3962 template encoded byte limit exceeds 64 MiB",
    },
    .{
        .name = "html-template-render-operations-type",
        .file = "html_template_render_operations_type.zig",
        .message = "PLOOF-E3963 template render operation limit must be an integer",
    },
    .{
        .name = "html-template-render-operations-zero",
        .file = "html_template_render_operations_zero.zig",
        .message = "PLOOF-E3964 template render operation limit must be nonzero",
    },
    .{
        .name = "html-template-render-operations-hard-max",
        .file = "html_template_render_operations_hard_max.zig",
        .message = "PLOOF-E3965 template render operation limit exceeds 64 Mi operations",
    },
    .{
        .name = "html-template-comptime-helper",
        .file = "html_template_comptime_helper.zig",
        .message = "PLOOF-E4011 HTML template invalid_helper",
    },
    .{
        .name = "html-template-comptime-writer",
        .file = "html_template_comptime_writer.zig",
        .message = "PLOOF-E4020 HTML template invalid_writer",
    },
    .{
        .name = "html-template-duplicate-partial-json",
        .file = "html_template_duplicate_partial_json.zig",
        .message = "PLOOF-E4025 HTML template duplicate_browser_json",
    },
    .{
        .name = "html-template-fake-layout-body",
        .file = "html_template_fake_layout_body.zig",
        .message = "PLOOF-E4022 HTML template invalid_layout_body",
    },
    .{
        .name = "html-template-format-text-capability",
        .file = "html_template_format_text_capability.zig",
        .message = "PLOOF-E4014 HTML template invalid_output_type",
    },
    .{
        .name = "html-template-each-bytes",
        .file = "html_template_each_bytes.zig",
        .message = "PLOOF-E4009 HTML template each_not_collection",
    },
    .{
        .name = "html-template-graph-source-limit",
        .file = "html_template_graph_source_limit.zig",
        .message = "PLOOF-E4023 HTML template graph_source_limit",
    },
    .{
        .name = "html-template-graph-edge-limit",
        .file = "html_template_graph_edge_limit.zig",
        .message = "PLOOF-E4028 HTML template graph_edge_limit",
    },
    .{
        .name = "html-template-helper-limit",
        .file = "html_template_helper_limit.zig",
        .message = "PLOOF-E4001 HTML template invalid_config",
    },
    .{
        .name = "html-template-helper-allocator",
        .file = "html_template_helper_allocator.zig",
        .message = "PLOOF-E4011 HTML template invalid_helper",
    },
    .{
        .name = "html-template-helper-anyopaque",
        .file = "html_template_helper_anyopaque.zig",
        .message = "PLOOF-E4011 HTML template invalid_helper",
    },
    .{
        .name = "html-template-helper-function-pointer",
        .file = "html_template_helper_function_pointer.zig",
        .message = "PLOOF-E4011 HTML template invalid_helper",
    },
    .{
        .name = "html-template-helper-request",
        .file = "html_template_helper_request.zig",
        .message = "PLOOF-E4011 HTML template invalid_helper",
    },
    .{
        .name = "html-template-helper-writer",
        .file = "html_template_helper_writer.zig",
        .message = "PLOOF-E4011 HTML template invalid_helper",
    },
    .{
        .name = "html-template-helper-file-handle",
        .file = "html_template_helper_file_handle.zig",
        .message = "PLOOF-E4011 HTML template invalid_helper",
    },
    .{
        .name = "html-template-helper-error-payload",
        .file = "html_template_helper_error_payload.zig",
        .message = "PLOOF-E4011 HTML template invalid_helper",
    },
    .{
        .name = "html-template-helper-upload-registry",
        .file = "html_template_helper_upload_registry.zig",
        .message = "PLOOF-E4011 HTML template invalid_helper",
    },
    .{
        .name = "html-template-helper-file",
        .file = "html_template_helper_file.zig",
        .message = "PLOOF-E4011 HTML template invalid_helper",
    },
    .{
        .name = "html-template-helper-volatile-pointer",
        .file = "html_template_helper_volatile_pointer.zig",
        .message = "PLOOF-E4011 HTML template invalid_helper",
    },
    .{
        .name = "html-format-text-volatile-pointer",
        .file = "html_format_text_volatile_pointer.zig",
        .message = "PLOOF-E3914 formatText self carries a mutable or framework capability",
    },
    .{
        .name = "html-template-format-text-volatile-pointer",
        .file = "html_template_format_text_volatile_pointer.zig",
        .message = "PLOOF-E4014 HTML template invalid_output_type",
    },
    .{
        .name = "html-template-if-type",
        .file = "html_template_if_type.zig",
        .message = "PLOOF-E4007 HTML template if_not_bool",
    },
    .{
        .name = "html-template-layout-duplicate-json",
        .file = "html_template_layout_duplicate_json.zig",
        .message = "PLOOF-E4025 HTML template duplicate_browser_json",
    },
    .{
        .name = "html-template-meta-refresh-dynamic",
        .file = "html_template_meta_refresh_dynamic.zig",
        .message = "PLOOF-E3847 HTML source ambiguous_url_context",
    },
    .{
        .name = "html-template-background-string",
        .file = "html_template_background_string.zig",
        .message = "PLOOF-E4014 HTML template invalid_output_type",
    },
    .{
        .name = "html-template-script-css-asset",
        .file = "html_template_script_css_asset.zig",
        .message = "PLOOF-E4014 HTML template invalid_output_type",
    },
    .{
        .name = "html-template-stylesheet-script-asset",
        .file = "html_template_stylesheet_script_asset.zig",
        .message = "PLOOF-E4014 HTML template invalid_output_type",
    },
    .{
        .name = "html-template-image-css-asset",
        .file = "html_template_image_css_asset.zig",
        .message = "PLOOF-E4014 HTML template invalid_output_type",
    },
    .{
        .name = "html-template-inline-css-closing",
        .file = "html_template_inline_css_closing.zig",
        .message = "PLOOF-E4032 HTML template invalid_inline_asset",
    },
    .{
        .name = "html-template-inline-javascript-closing",
        .file = "html_template_inline_javascript_closing.zig",
        .message = "PLOOF-E4032 HTML template invalid_inline_asset",
    },
    .{
        .name = "html-template-inline-kind",
        .file = "html_template_inline_kind.zig",
        .message = "PLOOF-E4032 HTML template invalid_inline_asset",
    },
    .{
        .name = "html-template-inline-unknown",
        .file = "html_template_inline_unknown.zig",
        .message = "PLOOF-E4032 HTML template invalid_inline_asset",
    },
    .{
        .name = "html-template-assets-tuple",
        .file = "html_template_assets_tuple.zig",
        .message = "PLOOF-E4031 HTML template invalid_assets",
    },
    .{
        .name = "html-template-base-dynamic",
        .file = "html_template_base_dynamic.zig",
        .message = "PLOOF-E3845 HTML source directive_context",
    },
    .{
        .name = "html-template-itemid-dynamic",
        .file = "html_template_itemid_dynamic.zig",
        .message = "PLOOF-E3845 HTML source directive_context",
    },
    .{
        .name = "html-template-itemtype-dynamic",
        .file = "html_template_itemtype_dynamic.zig",
        .message = "PLOOF-E3845 HTML source directive_context",
    },
    .{
        .name = "html-template-itemprop-dynamic",
        .file = "html_template_itemprop_dynamic.zig",
        .message = "PLOOF-E3845 HTML source directive_context",
    },
    .{
        .name = "html-template-iframe-sandbox-dynamic",
        .file = "html_template_iframe_sandbox_dynamic.zig",
        .message = "PLOOF-E3845 HTML source directive_context",
    },
    .{
        .name = "html-template-meta-csp-dynamic",
        .file = "html_template_meta_csp_dynamic.zig",
        .message = "PLOOF-E3847 HTML source ambiguous_url_context",
    },
    .{
        .name = "html-template-meta-referrer-dynamic",
        .file = "html_template_meta_referrer_dynamic.zig",
        .message = "PLOOF-E3847 HTML source ambiguous_url_context",
    },
    .{
        .name = "html-template-attribution-src-dynamic",
        .file = "html_template_attribution_src_dynamic.zig",
        .message = "PLOOF-E3845 HTML source directive_context",
    },
    .{
        .name = "html-template-script-language-dynamic",
        .file = "html_template_script_language_dynamic.zig",
        .message = "PLOOF-E3845 HTML source directive_context",
    },
    .{
        .name = "html-template-customized-builtin-dynamic",
        .file = "html_template_customized_builtin_dynamic.zig",
        .message = "PLOOF-E3845 HTML source directive_context",
    },
    .{
        .name = "html-template-anchor-rel-dynamic",
        .file = "html_template_anchor_rel_dynamic.zig",
        .message = "PLOOF-E3845 HTML source directive_context",
    },
    .{
        .name = "html-template-base-target-dynamic",
        .file = "html_template_base_target_dynamic.zig",
        .message = "PLOOF-E3845 HTML source directive_context",
    },
    .{
        .name = "html-template-link-manifest-url",
        .file = "html_template_link_manifest_url.zig",
        .message = "PLOOF-E4014 HTML template invalid_output_type",
    },
    .{
        .name = "html-template-link-unknown-rel",
        .file = "html_template_link_unknown_rel.zig",
        .message = "PLOOF-E3847 HTML source ambiguous_url_context",
    },
    .{
        .name = "html-template-link-conditional-rel",
        .file = "html_template_link_conditional_rel.zig",
        .message = "PLOOF-E3847 HTML source ambiguous_url_context",
    },
    .{
        .name = "html-template-link-conditional-as",
        .file = "html_template_link_conditional_as.zig",
        .message = "PLOOF-E3847 HTML source ambiguous_url_context",
    },
    .{
        .name = "html-template-link-static-href-dynamic-rel",
        .file = "html_template_link_static_href_dynamic_rel.zig",
        .message = "PLOOF-E3847 HTML source ambiguous_url_context",
    },
    .{
        .name = "html-template-link-static-href-dynamic-as",
        .file = "html_template_link_static_href_dynamic_as.zig",
        .message = "PLOOF-E3847 HTML source ambiguous_url_context",
    },
    .{
        .name = "html-template-link-encoded-rel",
        .file = "html_template_link_encoded_rel.zig",
        .message = "PLOOF-E3847 HTML source ambiguous_url_context",
    },
    .{
        .name = "html-template-link-encoded-as",
        .file = "html_template_link_encoded_as.zig",
        .message = "PLOOF-E3847 HTML source ambiguous_url_context",
    },
    .{
        .name = "html-template-meta-conditional-http-equiv",
        .file = "html_template_meta_conditional_http_equiv.zig",
        .message = "PLOOF-E3847 HTML source ambiguous_url_context",
    },
    .{
        .name = "html-template-meta-conditional-content",
        .file = "html_template_meta_conditional_content.zig",
        .message = "PLOOF-E3847 HTML source ambiguous_url_context",
    },
    .{
        .name = "html-template-meta-encoded-refresh",
        .file = "html_template_meta_encoded_refresh.zig",
        .message = "PLOOF-E3847 HTML source ambiguous_url_context",
    },
    .{
        .name = "html-template-partial-cycle",
        .file = "html_template_partial_cycle.zig",
        .message = "PLOOF-E4018 HTML template partial_cycle",
    },
    .{
        .name = "html-template-partial-depth",
        .file = "html_template_partial_depth.zig",
        .message = "PLOOF-E4019 HTML template partial_depth",
    },
    .{
        .name = "html-template-partial-helper-inheritance",
        .file = "html_template_partial_helper_inheritance.zig",
        .message = "PLOOF-E4010 HTML template unknown_helper",
    },
    .{
        .name = "html-template-partial-view",
        .file = "html_template_partial_view.zig",
        .message = "PLOOF-E4017 HTML template partial_view_mismatch",
    },
    .{
        .name = "html-template-repeated-partial-json",
        .file = "html_template_repeated_partial_json.zig",
        .message = "PLOOF-E4026 HTML template repeated_browser_json",
    },
    .{
        .name = "html-template-reserved-helper-error",
        .file = "html_template_reserved_helper_error.zig",
        .message = "PLOOF-E4030 HTML template reserved_application_error",
    },
    .{
        .name = "html-template-reserved-json-error",
        .file = "html_template_reserved_json_error.zig",
        .message = "PLOOF-E4030 HTML template reserved_application_error",
    },
    .{
        .name = "html-template-reserved-render-error",
        .file = "html_template_reserved_render_error.zig",
        .message = "PLOOF-E4030 HTML template reserved_application_error",
    },
    .{
        .name = "html-template-reserved-format-error",
        .file = "html_template_reserved_format_error.zig",
        .message = "PLOOF-E4030 HTML template reserved_application_error",
    },
    .{
        .name = "html-template-reserved-render-work-error",
        .file = "html_template_reserved_render_work_error.zig",
        .message = "PLOOF-E4030 HTML template reserved_application_error",
    },
    .{
        .name = "html-template-trusted-html-context",
        .file = "html_template_trusted_html_context.zig",
        .message = "PLOOF-E4014 HTML template invalid_output_type",
    },
    .{
        .name = "html-template-trusted-html-spoof",
        .file = "html_template_trusted_html_spoof.zig",
        .message = "PLOOF-E4014 HTML template invalid_output_type",
    },
    .{
        .name = "html-template-unknown-field",
        .file = "html_template_unknown_field.zig",
        .message = "PLOOF-E4005 HTML template unknown_field",
    },
    .{
        .name = "html-template-unknown-helper",
        .file = "html_template_unknown_helper.zig",
        .message = "PLOOF-E4010 HTML template unknown_helper",
    },
    .{
        .name = "html-template-unknown-partial",
        .file = "html_template_unknown_partial.zig",
        .message = "PLOOF-E4015 HTML template unknown_partial",
    },
    .{
        .name = "html-template-url-type",
        .file = "html_template_url_type.zig",
        .message = "PLOOF-E4014 HTML template invalid_output_type",
    },
    .{
        .name = "html-template-with-type",
        .file = "html_template_with_type.zig",
        .message = "PLOOF-E4008 HTML template with_not_optional",
    },
};
