const state = @import("source_parser_state.zig");
const tables = @import("source_tables.zig");
const types = @import("source_types.zig");

const empty_range = types.SourceRange{ .start = 0, .end = 0 };

pub fn parseStartTag(parser: anytype) bool {
    const open_at = parser.index;
    parser.index += 1;
    const name = takeTagName(parser);
    if (name.start == name.end) return parser.stop(.invalid_tag_name, open_at + 1);
    const namespace = startNamespace(parser, name);
    if (!validateElementName(parser, name, namespace)) return false;
    if (!validateStartStructure(parser, name, namespace)) return false;
    beginStartTag(parser, name, namespace);
    const self_closing = parseAttributes(parser) orelse return false;
    return finishStartTag(parser, open_at, name, namespace, self_closing);
}

pub fn parseEndTag(parser: anytype) bool {
    const source = @TypeOf(parser.*).source_bytes;
    const close_at = parser.index;
    parser.index += 2;
    const name = takeTagName(parser);
    if (name.start == name.end) return parser.stop(.invalid_tag_name, close_at + 2);
    while (parser.index < source.len and tables.isHtmlSpace(source[parser.index])) {
        parser.index += 1;
    }
    if (parser.index == source.len or source[parser.index] != '>') {
        return parser.stop(.malformed_declaration, parser.index);
    }
    parser.index += 1;
    if (parser.element_depth == 0) return parser.stop(.unexpected_end_tag, close_at);
    const top = parser.elements[parser.element_depth - 1];
    if (top.namespace == .html and tables.isVoidElement(name.bytes(source))) {
        return parser.stop(.void_end_tag, close_at);
    }
    const matched = if (top.namespace == .html)
        tables.equalAsciiIgnoreCase(name.bytes(source), top.name.bytes(source))
    else
        equal(name.bytes(source), top.name.bytes(source));
    if (!matched) return parser.stopRelated(.mismatched_end_tag, close_at, top.open_at);
    if (parser.closingCrossesControl()) return parser.stop(.control_context, close_at);
    applyDocumentEnd(parser, top.name);
    parser.element_depth -= 1;
    parser.refreshContext();
    return true;
}

fn beginStartTag(
    parser: anytype,
    name: types.SourceRange,
    namespace: tables.Namespace,
) void {
    parser.tag_name = name;
    parser.tag_namespace = namespace;
    parser.attribute_count = 0;
    parser.tag_separator = false;
    parser.context = .before_attribute;
}

fn parseAttributes(parser: anytype) ?bool {
    const source = @TypeOf(parser.*).source_bytes;
    while (parser.index < source.len) {
        if (tables.isHtmlSpace(source[parser.index])) {
            parser.tag_separator = true;
            parser.index += 1;
            continue;
        }
        if (parser.startsDirective() and parser.shouldParseDirective()) {
            if (!parser.parseDirective()) return null;
            continue;
        }
        if (source[parser.index] == '>') {
            parser.index += 1;
            return false;
        }
        if (startsWithAt(source, parser.index, "/>")) {
            parser.index += 2;
            return true;
        }
        if (!parser.tag_separator) {
            _ = parser.stop(.missing_attribute_separator, parser.index);
            return null;
        }
        if (!parseAttribute(parser)) return null;
    }
    _ = parser.stop(.document_structure, source.len);
    return null;
}

fn parseAttribute(parser: anytype) bool {
    const source = @TypeOf(parser.*).source_bytes;
    const name = takeAttributeName(parser);
    if (!tables.validHtmlAttributeName(name.bytes(source))) {
        return parser.stop(.invalid_attribute_name, name.start);
    }
    if (parser.tag_namespace == .svg and !tables.isSvgAttribute(name.bytes(source))) {
        return parser.stop(.forbidden_svg_attribute, name.start);
    }
    if (!checkDuplicateAttribute(parser, name)) return false;
    const value_start = parser.index;
    var cursor = parser.index;
    while (cursor < source.len and tables.isHtmlSpace(source[cursor])) cursor += 1;
    const has_value = cursor < source.len and source[cursor] == '=';
    if (!has_value) {
        if (parser.tag_namespace == .svg or !tables.isBooleanAttribute(name.bytes(source))) {
            return parser.stop(.non_boolean_bare_attribute, name.start);
        }
        recordAttribute(parser, name, false, empty_range, 0, 0);
        parser.index = value_start;
        parser.tag_separator = false;
        return true;
    }
    parser.index = cursor + 1;
    while (parser.index < source.len and tables.isHtmlSpace(source[parser.index])) {
        parser.index += 1;
    }
    return parseAttributeValue(parser, name);
}

fn parseAttributeValue(parser: anytype, name: types.SourceRange) bool {
    const source = @TypeOf(parser.*).source_bytes;
    if (parser.index == source.len or
        (source[parser.index] != '"' and source[parser.index] != '\''))
    {
        return parser.stop(.unquoted_attribute, parser.index);
    }
    const quote = source[parser.index];
    parser.index += 1;
    const value_start = parser.index;
    const directive_start = parser.analysis.directive_count;
    const saved_context = parser.context;
    parser.current_attribute = name;
    const class = tables.attributeClass(parser.tag_name.bytes(source), name.bytes(source));
    const parent = if (parser.element_depth == 0) "" else parser.topName();
    parser.context = if (parser.tag_namespace == .svg)
        .svg
    else
        tables.contextForAttribute(
            parser.tag_name.bytes(source),
            name.bytes(source),
            parent,
            class,
        );
    while (parser.index < source.len and source[parser.index] != quote) {
        if (parser.startsDirective() and parser.shouldParseDirective()) {
            if (!parser.parseDirective()) return false;
        } else {
            parser.index += 1;
        }
    }
    if (parser.index == source.len) return parser.stop(.unclosed_attribute, value_start - 1);
    if (parser.controlStartedInContext(parser.context)) {
        return parser.stop(.control_context, parser.index);
    }
    const value = makeRange(value_start, parser.index);
    const count = parser.analysis.directive_count - directive_start;
    if (!validateDynamicAttribute(parser, value, directive_start, count)) return false;
    parser.index += 1;
    parser.context = saved_context;
    parser.current_attribute = empty_range;
    recordAttribute(parser, name, true, value, directive_start, count);
    parser.tag_separator = false;
    return true;
}

fn validateDynamicAttribute(
    parser: anytype,
    value: types.SourceRange,
    first_directive: u32,
    directive_count: u32,
) bool {
    if (directive_count == 0) return true;
    if (parser.context == .attribute_event_handler or
        parser.context == .attribute_style or
        parser.context == .attribute_srcdoc or
        parser.context == .attribute_url_set or parser.context == .svg)
    {
        return parser.stop(.directive_context, value.start);
    }
    if (!isUrlContext(parser.context)) return true;
    if (directive_count != 1) return parser.stop(.mixed_url_value, value.start);
    const directive = parser.analysis.directives[first_directive];
    if (directive.kind != .interpolation and directive.kind != .helper) {
        return parser.stop(.mixed_url_value, value.start);
    }
    if (directive.source.start != value.start or directive.source.end != value.end) {
        return parser.stop(.mixed_url_value, value.start);
    }
    return true;
}

fn finishStartTag(
    parser: anytype,
    open_at: usize,
    name: types.SourceRange,
    namespace: tables.Namespace,
    self_closing: bool,
) bool {
    const source = @TypeOf(parser.*).source_bytes;
    const profile = @TypeOf(parser.*).source_profile;
    if (parser.controlStartedInContext(.before_attribute)) {
        return parser.stop(.control_context, open_at);
    }
    if (!resolveLinkDirectives(parser)) return false;
    if (!validateMetaDirectives(parser)) return false;
    if (namespace == .html and self_closing) {
        return parser.stop(.html_self_closing, open_at);
    }
    parser.analysis.element_count += 1;
    applyDocumentStart(parser, name);
    if ((namespace == .html and tables.isVoidElement(name.bytes(source))) or self_closing) {
        parser.refreshContext();
        return true;
    }
    if (parser.element_depth == @TypeOf(parser.*).element_capacity_max) {
        return parser.stopWith(
            .html_depth_limit,
            open_at,
            @intCast(parser.element_depth + 1),
            profile.html_element_depth_max,
        );
    }
    parser.elements[parser.element_depth] = .{
        .name = name,
        .namespace = namespace,
        .open_at = @intCast(open_at),
    };
    parser.element_depth += 1;
    parser.analysis.maximum_element_depth = @max(
        parser.analysis.maximum_element_depth,
        @as(u32, @intCast(parser.element_depth)),
    );
    parser.refreshContext();
    return true;
}

fn resolveLinkDirectives(parser: anytype) bool {
    const source = @TypeOf(parser.*).source_bytes;
    if (!tables.equalAsciiIgnoreCase(parser.tag_name.bytes(source), "link")) return true;
    const rel = findAttribute(parser, "rel");
    if (rel) |value| {
        if (!validLinkDiscriminator(parser, value, "rel")) return false;
    }
    const as_attribute = findAttribute(parser, "as");
    if (as_attribute) |value| {
        if (!validLinkDiscriminator(parser, value, "as")) return false;
    }
    var href: ?@TypeOf(parser.attributes[0]) = null;
    var href_count: usize = 0;
    for (parser.attributes[0..parser.attribute_count]) |attribute| {
        if (!tables.equalAsciiIgnoreCase(attribute.name.bytes(source), "href")) continue;
        href_count += 1;
        if (attribute.directive_count != 0) href = attribute;
    }
    const dynamic_href = href orelse return true;
    if (href_count != 1 or dynamic_href.path != state.no_path) {
        return parser.stop(.ambiguous_url_context, dynamic_href.name.start);
    }
    const static_rel = rel orelse {
        return parser.stop(.ambiguous_url_context, dynamic_href.name.start);
    };
    const as_bytes = if (as_attribute) |value| value.value.bytes(source) else "";
    const rel_bytes = static_rel.value.bytes(source);
    const context = tables.resolveLinkContext(rel_bytes, as_bytes) orelse {
        return parser.stop(.ambiguous_url_context, dynamic_href.name.start);
    };
    var offset = dynamic_href.first_directive;
    const end = offset + dynamic_href.directive_count;
    while (offset < end) : (offset += 1) parser.analysis.directives[offset].context = context;
    return true;
}

fn validLinkDiscriminator(parser: anytype, attribute: anytype, name: []const u8) bool {
    const source = @TypeOf(parser.*).source_bytes;
    if (attributeCount(parser, name) != 1 or attribute.path != state.no_path or
        !attribute.has_value or attribute.directive_count != 0 or
        !staticDiscriminator(attribute.value.bytes(source)))
    {
        return parser.stop(.ambiguous_url_context, attribute.name.start);
    }
    return true;
}

fn validateMetaDirectives(parser: anytype) bool {
    const source = @TypeOf(parser.*).source_bytes;
    if (!tables.equalAsciiIgnoreCase(parser.tag_name.bytes(source), "meta")) return true;
    if (findAttribute(parser, "http-equiv")) |http_equiv| {
        if (!validMetaDiscriminator(parser, http_equiv, "http-equiv")) return false;
        if (findAttribute(parser, "content")) |content| {
            if (!validMetaContent(parser, content)) return false;
        }
    }
    if (findAttribute(parser, "name")) |name| {
        if (!validMetaDiscriminator(parser, name, "name")) return false;
        if (tables.equalAsciiIgnoreCase(name.value.bytes(source), "referrer")) {
            if (findAttribute(parser, "content")) |content| {
                if (!validMetaContent(parser, content)) return false;
            }
        }
    }
    return true;
}

fn validMetaDiscriminator(parser: anytype, attribute: anytype, name: []const u8) bool {
    const source = @TypeOf(parser.*).source_bytes;
    if (attributeCount(parser, name) != 1 or attribute.path != state.no_path or
        !attribute.has_value or attribute.directive_count != 0 or
        !staticDiscriminator(attribute.value.bytes(source)))
    {
        return parser.stop(.ambiguous_url_context, attribute.name.start);
    }
    return true;
}

fn validMetaContent(parser: anytype, content: anytype) bool {
    if (attributeCount(parser, "content") != 1 or content.path != state.no_path or
        !content.has_value or content.directive_count != 0)
    {
        return parser.stop(.ambiguous_url_context, content.name.start);
    }
    return true;
}

fn checkDuplicateAttribute(parser: anytype, name: types.SourceRange) bool {
    const source = @TypeOf(parser.*).source_bytes;
    for (parser.attributes[0..parser.attribute_count]) |attribute| {
        if (!tables.equalAsciiIgnoreCase(
            name.bytes(source),
            attribute.name.bytes(source),
        )) continue;
        if (state.pathsOverlap(
            attribute.path,
            parser.current_path,
            parser.paths[0..parser.path_count],
        )) return parser.stopRelated(.duplicate_attribute, name.start, attribute.name.start);
    }
    return true;
}

fn recordAttribute(
    parser: anytype,
    name: types.SourceRange,
    has_value: bool,
    value: types.SourceRange,
    first_directive: u32,
    directive_count: u32,
) void {
    const Attribute = @TypeOf(parser.attributes[0]);
    const attribute = Attribute{
        .name = name,
        .value = value,
        .has_value = has_value,
        .first_directive = first_directive,
        .directive_count = directive_count,
        .path = parser.current_path,
    };
    parser.attributes[parser.attribute_count] = attribute;
    parser.attribute_count += 1;
}

fn findAttribute(parser: anytype, name: []const u8) ?@TypeOf(parser.attributes[0]) {
    const source = @TypeOf(parser.*).source_bytes;
    for (parser.attributes[0..parser.attribute_count]) |attribute| {
        if (tables.equalAsciiIgnoreCase(attribute.name.bytes(source), name)) return attribute;
    }
    return null;
}

fn attributeCount(parser: anytype, name: []const u8) usize {
    const source = @TypeOf(parser.*).source_bytes;
    var count: usize = 0;
    for (parser.attributes[0..parser.attribute_count]) |attribute| {
        if (tables.equalAsciiIgnoreCase(attribute.name.bytes(source), name)) count += 1;
    }
    return count;
}

fn staticDiscriminator(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte >= 0x7f or byte == '&' or (byte < 0x20 and !tables.isHtmlSpace(byte))) {
            return false;
        }
    }
    return true;
}

fn validateElementName(
    parser: anytype,
    name: types.SourceRange,
    namespace: tables.Namespace,
) bool {
    const source = @TypeOf(parser.*).source_bytes;
    const bytes = name.bytes(source);
    if (namespace == .svg) {
        if (!tables.isSvgElement(bytes)) {
            if (tables.isSvgElementIgnoreCase(bytes)) {
                return parser.stop(.svg_name_case, name.start);
            }
            return parser.stop(.forbidden_svg_element, name.start);
        }
        return true;
    }
    if (tables.equalAsciiIgnoreCase(bytes, "math")) {
        return parser.stop(.forbidden_html_element, name.start);
    }
    if (!tables.isHtmlElement(bytes) and !tables.validCustomElementName(bytes)) {
        return parser.stop(.unknown_html_element, name.start);
    }
    if (tables.isForbiddenHtmlElement(bytes)) {
        return parser.stop(.forbidden_html_element, name.start);
    }
    return true;
}

fn validateStartStructure(
    parser: anytype,
    name: types.SourceRange,
    namespace: tables.Namespace,
) bool {
    const source = @TypeOf(parser.*).source_bytes;
    if (namespace == .svg) return true;
    const bytes = name.bytes(source);
    if (@TypeOf(parser.*).source_kind == .fragment and isDocumentElement(bytes)) {
        return parser.stop(.fragment_document_element, name.start);
    }
    if (@TypeOf(parser.*).source_kind != .fragment and
        !documentStartAllowed(parser, bytes)) return parser.stop(.document_structure, name.start);
    if (repairHazard(parser, bytes)) {
        return parser.stop(.repair_dependent_structure, name.start);
    }
    return true;
}

fn documentStartAllowed(parser: anytype, name: []const u8) bool {
    if (tables.equalAsciiIgnoreCase(name, "html")) {
        return parser.document_stage == .need_html and parser.element_depth == 0;
    }
    if (tables.equalAsciiIgnoreCase(name, "head")) {
        return parser.document_stage == .need_head and parser.topIs("html");
    }
    if (tables.equalAsciiIgnoreCase(name, "body")) {
        return parser.document_stage == .need_body and parser.topIs("html");
    }
    if (isDocumentElement(name)) return false;
    if (parser.document_stage == .in_head) return headElementAllowed(parser, name);
    return parser.document_stage == .in_body;
}

fn headElementAllowed(parser: anytype, name: []const u8) bool {
    if (!parser.ancestorIs("head")) return false;
    return nameIn(name, &.{ "base", "link", "meta", "script", "style", "title" });
}

fn repairHazard(parser: anytype, name: []const u8) bool {
    if (parser.ancestorIs("p") and tables.closesParagraph(name)) return true;
    if (tables.equalAsciiIgnoreCase(name, "li") and
        ancestorInScope(parser, "li", &.{ "ol", "ul" })) return true;
    if ((tables.equalAsciiIgnoreCase(name, "dt") or
        tables.equalAsciiIgnoreCase(name, "dd")) and
        (ancestorInScope(parser, "dt", &.{"dl"}) or
            ancestorInScope(parser, "dd", &.{"dl"}))) return true;
    if (tables.isHeading(name) and parser.hasHeadingAncestor()) return true;
    if (tables.equalAsciiIgnoreCase(name, "a") and parser.ancestorIs("a")) return true;
    if (tables.equalAsciiIgnoreCase(name, "button") and parser.ancestorIs("button")) return true;
    if (tables.equalAsciiIgnoreCase(name, "form") and parser.ancestorIs("form")) return true;
    return parentRepairHazard(parser, name);
}

fn ancestorInScope(
    parser: anytype,
    target: []const u8,
    boundaries: []const []const u8,
) bool {
    const source = @TypeOf(parser.*).source_bytes;
    var depth = parser.element_depth;
    while (depth > 0) {
        depth -= 1;
        const element = parser.elements[depth];
        if (element.namespace != .html) continue;
        const name = element.name.bytes(source);
        if (tables.equalAsciiIgnoreCase(name, target)) return true;
        if (nameIn(name, boundaries)) return false;
    }
    return false;
}

fn parentRepairHazard(parser: anytype, name: []const u8) bool {
    if (parser.element_depth == 0 or parser.elements[parser.element_depth - 1].namespace == .svg) {
        return false;
    }
    const parent = parser.topName();
    if (tables.equalAsciiIgnoreCase(parent, "table")) {
        return !nameIn(name, &.{ "caption", "colgroup", "thead", "tbody", "tfoot" });
    }
    if (tables.equalAsciiIgnoreCase(parent, "colgroup")) return !nameIn(name, &.{"col"});
    if (nameIn(parent, &.{ "thead", "tbody", "tfoot" })) return !nameIn(name, &.{"tr"});
    if (tables.equalAsciiIgnoreCase(parent, "tr")) return !nameIn(name, &.{ "td", "th" });
    if (tables.equalAsciiIgnoreCase(parent, "select")) {
        return !nameIn(name, &.{ "option", "optgroup" });
    }
    if (tables.equalAsciiIgnoreCase(parent, "optgroup")) return !nameIn(name, &.{"option"});
    if (tables.equalAsciiIgnoreCase(parent, "option")) return true;
    return nameIn(parent, &.{ "rp", "rt" }) and nameIn(name, &.{ "rp", "rt" });
}

fn applyDocumentStart(parser: anytype, name: types.SourceRange) void {
    if (@TypeOf(parser.*).source_kind == .fragment) return;
    const source = @TypeOf(parser.*).source_bytes;
    const bytes = name.bytes(source);
    if (tables.equalAsciiIgnoreCase(bytes, "html")) {
        parser.document_stage = .need_head;
    } else if (tables.equalAsciiIgnoreCase(bytes, "head")) {
        parser.document_stage = .in_head;
        parser.region = .head;
    } else if (tables.equalAsciiIgnoreCase(bytes, "body")) {
        parser.document_stage = .in_body;
        parser.region = .body;
    }
}

fn applyDocumentEnd(parser: anytype, name: types.SourceRange) void {
    if (@TypeOf(parser.*).source_kind == .fragment) return;
    const source = @TypeOf(parser.*).source_bytes;
    const bytes = name.bytes(source);
    if (tables.equalAsciiIgnoreCase(bytes, "head")) {
        parser.document_stage = .need_body;
        parser.region = .document_root;
    } else if (tables.equalAsciiIgnoreCase(bytes, "body")) {
        parser.document_stage = .need_html_close;
        parser.region = .document_root;
    } else if (tables.equalAsciiIgnoreCase(bytes, "html")) {
        parser.document_stage = .closed;
    }
}

fn startNamespace(parser: anytype, name: types.SourceRange) tables.Namespace {
    const source = @TypeOf(parser.*).source_bytes;
    if (parser.element_depth != 0 and
        parser.elements[parser.element_depth - 1].namespace == .svg) return .svg;
    if (tables.equalAsciiIgnoreCase(name.bytes(source), "svg")) return .svg;
    return .html;
}

fn takeTagName(parser: anytype) types.SourceRange {
    const source = @TypeOf(parser.*).source_bytes;
    const start = parser.index;
    while (parser.index < source.len and !tables.isHtmlSpace(source[parser.index]) and
        source[parser.index] != '>' and source[parser.index] != '/' and
        !startsWithAt(source, parser.index, "{{")) parser.index += 1;
    return makeRange(start, parser.index);
}

fn takeAttributeName(parser: anytype) types.SourceRange {
    const source = @TypeOf(parser.*).source_bytes;
    const start = parser.index;
    while (parser.index < source.len and !tables.isHtmlSpace(source[parser.index]) and
        source[parser.index] != '=' and source[parser.index] != '>' and
        source[parser.index] != '/' and
        !startsWithAt(source, parser.index, "{{")) parser.index += 1;
    return makeRange(start, parser.index);
}

fn isUrlContext(context: types.ParserContext) bool {
    return switch (context) {
        .attribute_navigation_url,
        .attribute_asset_url,
        .attribute_trusted_resource_url,
        .attribute_image_url,
        .attribute_font_url,
        .attribute_media_url,
        .attribute_text_url,
        .attribute_script_url,
        .attribute_style_url,
        .attribute_document_url,
        .attribute_json_url,
        .attribute_xml_url,
        .attribute_any_resource_url,
        .attribute_ambiguous_url,
        => true,
        else => false,
    };
}

fn isDocumentElement(name: []const u8) bool {
    return tables.equalAsciiIgnoreCase(name, "html") or
        tables.equalAsciiIgnoreCase(name, "head") or
        tables.equalAsciiIgnoreCase(name, "body");
}

fn nameIn(name: []const u8, names: []const []const u8) bool {
    for (names) |candidate| {
        if (tables.equalAsciiIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn startsWithAt(bytes: []const u8, index: usize, prefix: []const u8) bool {
    if (index > bytes.len or prefix.len > bytes.len - index) return false;
    return equal(bytes[index .. index + prefix.len], prefix);
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

fn makeRange(start: usize, end: usize) types.SourceRange {
    return .{ .start = @intCast(start), .end = @intCast(end) };
}
