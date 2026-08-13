const std = @import("std");

pub const SourceKind = enum(u2) {
    document,
    fragment,
    layout,
};

pub const TemplateSourceProfile = struct {
    source_bytes_max: u32 = 256 * 1024,
    graph_source_bytes_max: u32 = 2 * 1024 * 1024,
    html_element_depth_max: u32 = 128,
    template_control_depth_max: u32 = 32,
    partial_call_depth_max: u32 = 32,
    directives_max: u32 = 16_384,
    field_path_components_max: u32 = 16,
    helper_arguments_max: u32 = 8,
};

pub const SourceSpec = struct {
    kind: SourceKind,
    graph_name: []const u8,
    file_path: []const u8,
    bytes: []const u8,
};

pub const Position = struct {
    byte_offset: u32,
    line: u32,
    column: u32,
};

pub const SourceRange = struct {
    start: u32,
    end: u32,

    pub fn bytes(range: SourceRange, source: []const u8) []const u8 {
        return source[range.start..range.end];
    }
};

pub const Region = enum(u2) {
    fragment,
    document_root,
    head,
    body,
};

pub const ParserContext = enum(u5) {
    html_data,
    title_text,
    textarea_text,
    before_attribute,
    attribute_inert,
    attribute_navigation_url,
    attribute_asset_url,
    attribute_trusted_resource_url,
    attribute_image_url,
    attribute_font_url,
    attribute_media_url,
    attribute_text_url,
    attribute_script_url,
    attribute_style_url,
    attribute_document_url,
    attribute_json_url,
    attribute_xml_url,
    attribute_any_resource_url,
    attribute_ambiguous_url,
    attribute_url_set,
    attribute_event_handler,
    attribute_style,
    attribute_srcdoc,
    script_text,
    style_text,
    svg,
};

pub const DirectiveKind = enum(u4) {
    interpolation,
    helper,
    if_open,
    with_open,
    each_open,
    else_branch,
    block_close,
    partial,
    json_data,
    inline_css,
    inline_javascript,
    body_slot,
    comment,
    verbatim_open,
    verbatim_close,
};

pub const BlockKind = enum(u2) {
    if_block,
    with_block,
    each_block,
    verbatim,
};

pub const Directive = struct {
    source: SourceRange,
    name: SourceRange,
    expression: SourceRange,
    auxiliary: SourceRange,
    context: ParserContext,
    kind: DirectiveKind,
    region: Region,
    argument_count: u32,
    control_depth: u32,
    repeating_depth: u32,
    trim_before: bool,
    trim_after: bool,
};

pub const ProblemCode = enum(u8) {
    profile_limit_zero,
    source_too_long,
    graph_source_too_long,
    source_offset_overflow,
    invalid_utf8,
    byte_order_mark,
    nul_byte,
    missing_document_doctype,
    fragment_doctype,
    malformed_declaration,
    malformed_comment,
    invalid_tag_name,
    unknown_html_element,
    forbidden_html_element,
    fragment_document_element,
    document_structure,
    html_depth_limit,
    unexpected_end_tag,
    mismatched_end_tag,
    void_end_tag,
    html_self_closing,
    repair_dependent_structure,
    foster_parenting,
    invalid_attribute_name,
    missing_attribute_separator,
    duplicate_attribute,
    unquoted_attribute,
    non_boolean_bare_attribute,
    forbidden_svg_element,
    forbidden_svg_attribute,
    svg_name_case,
    unclosed_element,
    unclosed_attribute,
    malformed_directive,
    unsupported_directive,
    directive_limit,
    control_depth_limit,
    field_path,
    field_path_limit,
    unknown_local,
    reserved_local,
    helper_argument_limit,
    block_mismatch,
    duplicate_else,
    control_context,
    directive_context,
    mixed_url_value,
    ambiguous_url_context,
    each_between_attributes,
    repeated_json_data,
    duplicate_json_data,
    invalid_json_data_name,
    invalid_body_slot,
    missing_body_slot,
    unexpected_body_slot,
    nested_verbatim,
    unclosed_verbatim,
};

pub const Problem = struct {
    code: ProblemCode,
    at: Position,
    related_at: ?Position = null,
    actual: u32 = 0,
    limit: u32 = 0,
};

pub fn Analysis(comptime directive_capacity: usize) type {
    return struct {
        directives: [directive_capacity]Directive = undefined,
        directive_count: u32 = 0,
        element_count: u32 = 0,
        maximum_element_depth: u32 = 0,
        maximum_control_depth: u32 = 0,
        problem: ?Problem = null,
    };
}

pub fn profileValid(profile: TemplateSourceProfile) bool {
    return profile.source_bytes_max != 0 and
        profile.graph_source_bytes_max != 0 and
        profile.html_element_depth_max != 0 and
        profile.template_control_depth_max != 0 and
        profile.partial_call_depth_max != 0 and
        profile.directives_max != 0 and
        profile.field_path_components_max != 0 and
        profile.helper_arguments_max != 0;
}

pub fn position(source: []const u8, requested_offset: usize) Position {
    const offset = @min(requested_offset, source.len);
    var line: u32 = 1;
    var column: u32 = 1;
    var index: usize = 0;
    while (index < offset) {
        if (source[index] == '\r') {
            if (index + 1 < offset and source[index + 1] == '\n') index += 1;
            line += 1;
            column = 1;
        } else if (source[index] == '\n') {
            line += 1;
            column = 1;
        } else if (source[index] & 0xc0 != 0x80) {
            column += 1;
        }
        index += 1;
    }
    return .{ .byte_offset = @intCast(offset), .line = line, .column = column };
}

pub fn invalidUtf8Offset(source: []const u8) ?usize {
    var index: usize = 0;
    while (index < source.len) {
        const length = std.unicode.utf8ByteSequenceLength(source[index]) catch return index;
        if (length > source.len - index) return index;
        _ = std.unicode.utf8Decode(source[index .. index + length]) catch return index;
        index += length;
    }
    return null;
}
