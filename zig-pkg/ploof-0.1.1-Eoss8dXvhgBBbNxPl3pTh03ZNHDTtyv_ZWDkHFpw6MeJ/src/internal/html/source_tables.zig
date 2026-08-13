const std = @import("std");
const types = @import("source_types.zig");

pub const Namespace = enum(u1) {
    html,
    svg,
};

pub const AttributeClass = enum(u4) {
    inert,
    static_only,
    navigation_url,
    asset_url,
    trusted_resource_url,
    link_url,
    url_set,
    event_handler,
    style,
    srcdoc,
};

const html_elements = [_][]const u8{
    "a",        "abbr",    "address",  "area",     "article",    "aside",
    "audio",    "b",       "base",     "bdi",      "bdo",        "blockquote",
    "body",     "br",      "button",   "canvas",   "caption",    "cite",
    "code",     "col",     "colgroup", "data",     "datalist",   "dd",
    "del",      "details", "dfn",      "dialog",   "div",        "dl",
    "dt",       "em",      "embed",    "fieldset", "figcaption", "figure",
    "footer",   "form",    "h1",       "h2",       "h3",         "h4",
    "h5",       "h6",      "head",     "header",   "hgroup",     "hr",
    "html",     "i",       "iframe",   "img",      "input",      "ins",
    "kbd",      "label",   "legend",   "li",       "link",       "main",
    "map",      "mark",    "menu",     "meta",     "meter",      "nav",
    "noscript", "object",  "ol",       "optgroup", "option",     "output",
    "p",        "picture", "pre",      "progress", "q",          "rp",
    "rt",       "ruby",    "s",        "samp",     "script",     "search",
    "section",  "select",  "slot",     "small",    "source",     "span",
    "strong",   "style",   "sub",      "summary",  "sup",        "table",
    "tbody",    "td",      "template", "textarea", "tfoot",      "th",
    "thead",    "time",    "title",    "tr",       "track",      "u",
    "ul",       "var",     "video",    "wbr",
};

const void_elements = [_][]const u8{
    "area",  "base", "br",   "col",    "embed", "hr",  "img",
    "input", "link", "meta", "source", "track", "wbr",
};

const forbidden_html_elements = [_][]const u8{
    "noscript", "template",
};

const boolean_attributes = [_][]const u8{
    "allowfullscreen", "async",          "autofocus", "autoplay",
    "checked",         "controls",       "default",   "defer",
    "disabled",        "formnovalidate", "inert",     "ismap",
    "itemscope",       "loop",           "multiple",  "muted",
    "nomodule",        "novalidate",     "open",      "playsinline",
    "readonly",        "required",       "reversed",  "selected",
    "credentialless",
};

const svg_elements = [_][]const u8{
    "svg",      "g",       "path",           "rect",           "circle", "ellipse", "line",
    "polyline", "polygon", "text",           "tspan",          "title",  "desc",    "defs",
    "clipPath", "mask",    "linearGradient", "radialGradient", "stop",   "symbol",
};

const svg_attributes = [_][]const u8{
    "aria-hidden",    "aria-label",          "class",             "clip-path",
    "clip-rule",      "clipPathUnits",       "cx",                "cy",
    "d",              "dominant-baseline",   "dx",                "dy",
    "fill",           "fill-opacity",        "fill-rule",         "focusable",
    "font-family",    "font-size",           "font-weight",       "fr",
    "fx",             "fy",                  "gradientTransform", "gradientUnits",
    "height",         "id",                  "letter-spacing",    "maskContentUnits",
    "maskUnits",      "offset",              "opacity",           "pathLength",
    "points",         "preserveAspectRatio", "r",                 "role",
    "rx",             "ry",                  "spreadMethod",      "stop-color",
    "stop-opacity",   "stroke",              "stroke-dasharray",  "stroke-dashoffset",
    "stroke-linecap", "stroke-linejoin",     "stroke-miterlimit", "stroke-opacity",
    "stroke-width",   "text-anchor",         "transform",         "viewBox",
    "width",          "x",                   "x1",                "x2",
    "xmlns",          "y",                   "y1",                "y2",
};

const reserved_custom_elements = [_][]const u8{
    "annotation-xml", "color-profile",    "font-face",      "font-face-src",
    "font-face-uri",  "font-face-format", "font-face-name", "missing-glyph",
};

pub fn isHtmlSpace(byte: u8) bool {
    return switch (byte) {
        '\t', '\n', '\x0c', '\r', ' ' => true,
        else => false,
    };
}

pub fn equalAsciiIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (lowerAscii(left) != lowerAscii(right)) return false;
    }
    return true;
}

pub fn isHtmlElement(name: []const u8) bool {
    return inTableIgnoreCase(name, &html_elements);
}

pub fn isForbiddenHtmlElement(name: []const u8) bool {
    return inTableIgnoreCase(name, &forbidden_html_elements);
}

pub fn isVoidElement(name: []const u8) bool {
    return inTableIgnoreCase(name, &void_elements);
}

pub fn isBooleanAttribute(name: []const u8) bool {
    return inTableIgnoreCase(name, &boolean_attributes);
}

pub fn isSvgElement(name: []const u8) bool {
    return inTableExact(name, &svg_elements);
}

pub fn isSvgElementIgnoreCase(name: []const u8) bool {
    return inTableIgnoreCase(name, &svg_elements);
}

pub fn isSvgAttribute(name: []const u8) bool {
    if (startsWith(name, "data-") or startsWith(name, "aria-")) return true;
    return inTableExact(name, &svg_attributes);
}

pub fn validCustomElementName(name: []const u8) bool {
    if (name.len < 3 or name[0] < 'a' or name[0] > 'z') return false;
    if (inTableExact(name, &reserved_custom_elements)) return false;
    var saw_hyphen = false;
    var index: usize = 0;
    while (index < name.len) {
        const decoded = decodeUtf8(name[index..]) orelse return false;
        if (!isCustomElementCodepoint(decoded.codepoint)) return false;
        saw_hyphen = saw_hyphen or decoded.codepoint == '-';
        index += decoded.length;
    }
    return saw_hyphen;
}

pub fn validHtmlAttributeName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
        if (isHtmlSpace(byte)) return false;
        switch (byte) {
            '"', '\'', '<', '>', '=', '/', '{', '}' => return false,
            else => {},
        }
    }
    return true;
}

pub fn attributeClass(element: []const u8, attribute: []const u8) AttributeClass {
    if (attribute.len > 2 and lowerAscii(attribute[0]) == 'o' and
        lowerAscii(attribute[1]) == 'n') return .event_handler;
    if (equalAsciiIgnoreCase(attribute, "style")) return .style;
    if (equalAsciiIgnoreCase(attribute, "srcdoc")) return .srcdoc;
    if (staticOnlyAttribute(element, attribute)) return .static_only;
    if (equalAsciiIgnoreCase(attribute, "srcset") or
        equalAsciiIgnoreCase(attribute, "imagesrcset") or
        equalAsciiIgnoreCase(attribute, "ping") or
        equalAsciiIgnoreCase(attribute, "attributionsrc")) return .url_set;
    if (urlPair(element, attribute, &navigation_pairs)) return .navigation_url;
    if (urlPair(element, attribute, &asset_pairs)) return .asset_url;
    if (urlPair(element, attribute, &trusted_pairs)) return .trusted_resource_url;
    if (equalAsciiIgnoreCase(element, "link") and
        equalAsciiIgnoreCase(attribute, "href")) return .link_url;
    return .inert;
}

pub fn contextForAttribute(
    element: []const u8,
    attribute: []const u8,
    parent: []const u8,
    class: AttributeClass,
) types.ParserContext {
    return switch (class) {
        .inert => .attribute_inert,
        .static_only => .attribute_url_set,
        .navigation_url => .attribute_navigation_url,
        .asset_url => assetContext(element, attribute, parent),
        .trusted_resource_url => resourceContext(element),
        .link_url => .attribute_ambiguous_url,
        .url_set => .attribute_url_set,
        .event_handler => .attribute_event_handler,
        .style => .attribute_style,
        .srcdoc => .attribute_srcdoc,
    };
}

pub fn resolveLinkContext(rel: []const u8, as_value: []const u8) ?types.ParserContext {
    var result: ?types.ParserContext = null;
    var iterator = TokenIterator{ .bytes = rel };
    while (iterator.next()) |token| {
        const next: types.ParserContext = if (trustedLinkContext(token)) |context|
            context
        else if (assetLinkContext(token)) |context|
            context
        else if (equalAsciiIgnoreCase(token, "preload"))
            preloadContext(as_value) orelse return null
        else if (isNavigationLinkRel(token))
            .attribute_navigation_url
        else
            return null;
        result = mergeLinkContext(result, next) orelse return null;
    }
    return result;
}

fn contextRank(context: types.ParserContext) u2 {
    return switch (context) {
        .attribute_navigation_url => 0,
        .attribute_asset_url,
        .attribute_image_url,
        .attribute_font_url,
        .attribute_media_url,
        .attribute_text_url,
        => 1,
        .attribute_trusted_resource_url,
        .attribute_script_url,
        .attribute_style_url,
        .attribute_document_url,
        .attribute_json_url,
        .attribute_xml_url,
        .attribute_any_resource_url,
        => 2,
        else => unreachable,
    };
}

fn mergeLinkContext(
    current: ?types.ParserContext,
    next: types.ParserContext,
) ?types.ParserContext {
    const existing = current orelse return next;
    if (existing == next) return existing;
    const existing_rank = contextRank(existing);
    const next_rank = contextRank(next);
    if (existing_rank != next_rank) return if (existing_rank > next_rank) existing else next;
    if (existing_rank == 2) return .attribute_trusted_resource_url;
    return null;
}

fn assetContext(
    element: []const u8,
    attribute: []const u8,
    parent: []const u8,
) types.ParserContext {
    if (equalAsciiIgnoreCase(element, "source")) {
        return if (equalAsciiIgnoreCase(parent, "picture"))
            .attribute_image_url
        else
            .attribute_media_url;
    }
    if (equalAsciiIgnoreCase(attribute, "background") or
        equalAsciiIgnoreCase(element, "img") or
        equalAsciiIgnoreCase(element, "input") or
        (equalAsciiIgnoreCase(element, "video") and
            equalAsciiIgnoreCase(attribute, "poster"))) return .attribute_image_url;
    if (equalAsciiIgnoreCase(element, "track")) return .attribute_text_url;
    if (equalAsciiIgnoreCase(element, "audio") or
        equalAsciiIgnoreCase(element, "video")) return .attribute_media_url;
    return .attribute_asset_url;
}

fn resourceContext(element: []const u8) types.ParserContext {
    if (equalAsciiIgnoreCase(element, "script")) return .attribute_script_url;
    if (equalAsciiIgnoreCase(element, "iframe")) return .attribute_document_url;
    if (equalAsciiIgnoreCase(element, "embed") or
        equalAsciiIgnoreCase(element, "object")) return .attribute_any_resource_url;
    return .attribute_trusted_resource_url;
}

pub fn isRawTextElement(name: []const u8) bool {
    return equalAsciiIgnoreCase(name, "script") or
        equalAsciiIgnoreCase(name, "style") or
        equalAsciiIgnoreCase(name, "iframe");
}

pub fn isRcDataElement(name: []const u8) bool {
    return equalAsciiIgnoreCase(name, "title") or
        equalAsciiIgnoreCase(name, "textarea");
}

pub fn isHeading(name: []const u8) bool {
    return name.len == 2 and lowerAscii(name[0]) == 'h' and
        name[1] >= '1' and name[1] <= '6';
}

pub fn closesParagraph(name: []const u8) bool {
    const names = [_][]const u8{
        "address", "article", "aside",  "blockquote", "div",   "dl",   "fieldset",
        "footer",  "form",    "h1",     "h2",         "h3",    "h4",   "h5",
        "h6",      "header",  "hgroup", "hr",         "main",  "menu", "nav",
        "ol",      "p",       "pre",    "section",    "table", "ul",
    };
    return inTableIgnoreCase(name, &names);
}

const UrlPair = struct {
    element: []const u8,
    attribute: []const u8,
};

const navigation_pairs = [_]UrlPair{
    .{ .element = "a", .attribute = "href" },
    .{ .element = "a", .attribute = "urn" },
    .{ .element = "area", .attribute = "href" },
    .{ .element = "blockquote", .attribute = "cite" },
    .{ .element = "button", .attribute = "formaction" },
    .{ .element = "del", .attribute = "cite" },
    .{ .element = "form", .attribute = "action" },
    .{ .element = "input", .attribute = "formaction" },
    .{ .element = "ins", .attribute = "cite" },
    .{ .element = "iframe", .attribute = "longdesc" },
    .{ .element = "img", .attribute = "longdesc" },
    .{ .element = "q", .attribute = "cite" },
};

const asset_pairs = [_]UrlPair{
    .{ .element = "audio", .attribute = "src" },
    .{ .element = "body", .attribute = "background" },
    .{ .element = "img", .attribute = "lowsrc" },
    .{ .element = "img", .attribute = "src" },
    .{ .element = "input", .attribute = "src" },
    .{ .element = "source", .attribute = "src" },
    .{ .element = "table", .attribute = "background" },
    .{ .element = "tbody", .attribute = "background" },
    .{ .element = "td", .attribute = "background" },
    .{ .element = "tfoot", .attribute = "background" },
    .{ .element = "th", .attribute = "background" },
    .{ .element = "thead", .attribute = "background" },
    .{ .element = "track", .attribute = "src" },
    .{ .element = "tr", .attribute = "background" },
    .{ .element = "video", .attribute = "poster" },
    .{ .element = "video", .attribute = "src" },
};

fn staticOnlyAttribute(element: []const u8, attribute: []const u8) bool {
    if (inTableIgnoreCase(attribute, &.{
        "crossorigin", "datasrc",        "integrity", "is", "itemid", "itemprop", "itemtype",
        "nonce",       "referrerpolicy",
    })) return true;
    if (equalAsciiIgnoreCase(element, "base") and
        inTableIgnoreCase(attribute, &.{ "href", "target" })) return true;
    if (inTableIgnoreCase(element, &.{ "a", "area", "form" }) and
        equalAsciiIgnoreCase(attribute, "rel")) return true;
    if (equalAsciiIgnoreCase(element, "head") and
        equalAsciiIgnoreCase(attribute, "profile")) return true;
    if (equalAsciiIgnoreCase(element, "html") and
        equalAsciiIgnoreCase(attribute, "manifest")) return true;
    if (equalAsciiIgnoreCase(element, "iframe") and
        inTableIgnoreCase(attribute, &.{ "allow", "csp", "sandbox" })) return true;
    if (equalAsciiIgnoreCase(element, "link") and
        equalAsciiIgnoreCase(attribute, "urn")) return true;
    if (equalAsciiIgnoreCase(element, "meta") and
        inTableIgnoreCase(attribute, &.{ "charset", "name" })) return true;
    if (equalAsciiIgnoreCase(element, "object") and
        inTableIgnoreCase(attribute, &.{ "archive", "classid", "code", "codebase" }))
    {
        return true;
    }
    if (equalAsciiIgnoreCase(element, "script") and
        inTableIgnoreCase(attribute, &.{ "charset", "language", "type" })) return true;
    return false;
}

const trusted_pairs = [_]UrlPair{
    .{ .element = "embed", .attribute = "src" },
    .{ .element = "iframe", .attribute = "src" },
    .{ .element = "object", .attribute = "data" },
    .{ .element = "script", .attribute = "src" },
};

fn urlPair(element: []const u8, attribute: []const u8, pairs: []const UrlPair) bool {
    for (pairs) |pair| {
        if (equalAsciiIgnoreCase(element, pair.element) and
            equalAsciiIgnoreCase(attribute, pair.attribute)) return true;
    }
    return false;
}

fn trustedLinkContext(token: []const u8) ?types.ParserContext {
    if (equalAsciiIgnoreCase(token, "stylesheet")) return .attribute_style_url;
    if (equalAsciiIgnoreCase(token, "modulepreload")) return .attribute_script_url;
    if (equalAsciiIgnoreCase(token, "manifest")) return .attribute_json_url;
    if (equalAsciiIgnoreCase(token, "search") or
        equalAsciiIgnoreCase(token, "pingback")) return .attribute_xml_url;
    if (equalAsciiIgnoreCase(token, "compression-dictionary")) {
        return .attribute_any_resource_url;
    }
    return null;
}

fn assetLinkContext(token: []const u8) ?types.ParserContext {
    if (equalAsciiIgnoreCase(token, "icon") or
        equalAsciiIgnoreCase(token, "apple-touch-icon") or
        equalAsciiIgnoreCase(token, "mask-icon")) return .attribute_image_url;
    if (equalAsciiIgnoreCase(token, "prefetch")) return .attribute_asset_url;
    if (equalAsciiIgnoreCase(token, "dns-prefetch") or
        equalAsciiIgnoreCase(token, "preconnect")) return .attribute_navigation_url;
    return null;
}

fn isNavigationLinkRel(token: []const u8) bool {
    const names = [_][]const u8{
        "alternate", "author",         "canonical", "external",
        "help",      "license",        "me",        "next",
        "prev",      "privacy-policy", "tag",       "terms-of-service",
    };
    return inTableIgnoreCase(token, &names);
}

fn preloadContext(as_value: []const u8) ?types.ParserContext {
    if (equalAsciiIgnoreCase(as_value, "script")) return .attribute_script_url;
    if (equalAsciiIgnoreCase(as_value, "style")) return .attribute_style_url;
    if (equalAsciiIgnoreCase(as_value, "font")) return .attribute_font_url;
    if (equalAsciiIgnoreCase(as_value, "image")) return .attribute_image_url;
    if (equalAsciiIgnoreCase(as_value, "track")) return .attribute_text_url;
    if (equalAsciiIgnoreCase(as_value, "audio") or
        equalAsciiIgnoreCase(as_value, "video")) return .attribute_media_url;
    if (equalAsciiIgnoreCase(as_value, "fetch")) return .attribute_asset_url;
    return null;
}

const TokenIterator = struct {
    bytes: []const u8,
    index: usize = 0,

    fn next(iterator: *TokenIterator) ?[]const u8 {
        while (iterator.index < iterator.bytes.len and
            isHtmlSpace(iterator.bytes[iterator.index])) iterator.index += 1;
        if (iterator.index == iterator.bytes.len) return null;
        const start = iterator.index;
        while (iterator.index < iterator.bytes.len and
            !isHtmlSpace(iterator.bytes[iterator.index])) iterator.index += 1;
        return iterator.bytes[start..iterator.index];
    }
};

const Decoded = struct {
    codepoint: u21,
    length: u3,
};

fn decodeUtf8(bytes: []const u8) ?Decoded {
    if (bytes.len == 0) return null;
    const sequence_length = utf8SequenceLength(bytes[0]) orelse return null;
    if (sequence_length > bytes.len) return null;
    var codepoint: u21 = switch (sequence_length) {
        1 => bytes[0],
        2 => bytes[0] & 0x1f,
        3 => bytes[0] & 0x0f,
        4 => bytes[0] & 0x07,
        else => unreachable,
    };
    var index: usize = 1;
    while (index < sequence_length) : (index += 1) {
        if (bytes[index] & 0xc0 != 0x80) return null;
        codepoint = (codepoint << 6) | @as(u21, bytes[index] & 0x3f);
    }
    return .{ .codepoint = codepoint, .length = @intCast(sequence_length) };
}

test "URL and static-only attribute tables classify every declared entry" {
    for (navigation_pairs) |pair| {
        try std.testing.expectEqual(
            AttributeClass.navigation_url,
            attributeClass(pair.element, pair.attribute),
        );
    }
    for (asset_pairs) |pair| {
        try std.testing.expectEqual(
            AttributeClass.asset_url,
            attributeClass(pair.element, pair.attribute),
        );
    }
    for (trusted_pairs) |pair| {
        try std.testing.expectEqual(
            AttributeClass.trusted_resource_url,
            attributeClass(pair.element, pair.attribute),
        );
    }
    const static_cases = [_]UrlPair{
        .{ .element = "div", .attribute = "crossorigin" },
        .{ .element = "div", .attribute = "datasrc" },
        .{ .element = "div", .attribute = "integrity" },
        .{ .element = "button", .attribute = "is" },
        .{ .element = "div", .attribute = "itemid" },
        .{ .element = "div", .attribute = "itemprop" },
        .{ .element = "div", .attribute = "itemtype" },
        .{ .element = "div", .attribute = "nonce" },
        .{ .element = "div", .attribute = "referrerpolicy" },
        .{ .element = "base", .attribute = "href" },
        .{ .element = "base", .attribute = "target" },
        .{ .element = "a", .attribute = "rel" },
        .{ .element = "area", .attribute = "rel" },
        .{ .element = "form", .attribute = "rel" },
        .{ .element = "head", .attribute = "profile" },
        .{ .element = "html", .attribute = "manifest" },
        .{ .element = "iframe", .attribute = "allow" },
        .{ .element = "iframe", .attribute = "csp" },
        .{ .element = "iframe", .attribute = "sandbox" },
        .{ .element = "link", .attribute = "urn" },
        .{ .element = "meta", .attribute = "charset" },
        .{ .element = "meta", .attribute = "name" },
        .{ .element = "object", .attribute = "archive" },
        .{ .element = "object", .attribute = "classid" },
        .{ .element = "object", .attribute = "code" },
        .{ .element = "object", .attribute = "codebase" },
        .{ .element = "script", .attribute = "charset" },
        .{ .element = "script", .attribute = "language" },
        .{ .element = "script", .attribute = "type" },
    };
    for (static_cases) |case| {
        try std.testing.expectEqual(
            AttributeClass.static_only,
            attributeClass(case.element, case.attribute),
        );
    }
}

test "link relations fail closed and retain explicit context classes" {
    try std.testing.expectEqual(
        types.ParserContext.attribute_navigation_url,
        resolveLinkContext("canonical", "").?,
    );
    try std.testing.expectEqual(
        types.ParserContext.attribute_asset_url,
        resolveLinkContext("prefetch", "").?,
    );
    try std.testing.expectEqual(
        types.ParserContext.attribute_style_url,
        resolveLinkContext("alternate stylesheet", "").?,
    );
    try std.testing.expectEqual(
        types.ParserContext.attribute_json_url,
        resolveLinkContext("manifest", "").?,
    );
    try std.testing.expect(resolveLinkContext("future-resource", "") == null);
}

fn utf8SequenceLength(first: u8) ?usize {
    if (first < 0x80) return 1;
    if (first >= 0xc2 and first <= 0xdf) return 2;
    if (first >= 0xe0 and first <= 0xef) return 3;
    if (first >= 0xf0 and first <= 0xf4) return 4;
    return null;
}

fn isCustomElementCodepoint(codepoint: u21) bool {
    if (codepoint == '-' or codepoint == '.' or codepoint == '_' or
        (codepoint >= '0' and codepoint <= '9') or
        (codepoint >= 'a' and codepoint <= 'z')) return true;
    return codepoint == 0x00b7 or
        (codepoint >= 0x00c0 and codepoint <= 0x00d6) or
        (codepoint >= 0x00d8 and codepoint <= 0x00f6) or
        (codepoint >= 0x00f8 and codepoint <= 0x037d) or
        (codepoint >= 0x037f and codepoint <= 0x1fff) or
        (codepoint >= 0x200c and codepoint <= 0x200d) or
        (codepoint >= 0x203f and codepoint <= 0x2040) or
        (codepoint >= 0x2070 and codepoint <= 0x218f) or
        (codepoint >= 0x2c00 and codepoint <= 0x2fef) or
        (codepoint >= 0x3001 and codepoint <= 0xd7ff) or
        (codepoint >= 0xf900 and codepoint <= 0xfdcf) or
        (codepoint >= 0xfdf0 and codepoint <= 0xfffd) or
        (codepoint >= 0x10000 and codepoint <= 0xeffff);
}

fn inTableIgnoreCase(name: []const u8, table: []const []const u8) bool {
    for (table) |entry| if (equalAsciiIgnoreCase(name, entry)) return true;
    return false;
}

fn inTableExact(name: []const u8, table: []const []const u8) bool {
    for (table) |entry| {
        if (entry.len != name.len) continue;
        var equal = true;
        for (entry, name) |left, right| equal = equal and left == right;
        if (equal) return true;
    }
    return false;
}

fn startsWith(bytes: []const u8, prefix: []const u8) bool {
    if (bytes.len < prefix.len) return false;
    for (bytes[0..prefix.len], prefix) |left, right| {
        if (left != right) return false;
    }
    return true;
}

fn lowerAscii(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}
