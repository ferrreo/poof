const std = @import("std");
const directives = @import("source_directives.zig");
const support = @import("source_parser_support.zig");
const state = @import("source_parser_state.zig");
const tags = @import("source_parser_tags.zig");
const tables = @import("source_tables.zig");
const types = @import("source_types.zig");

const doctype = "<!doctype html>";
const equal = support.equal;
const isAsciiLetter = support.isAsciiLetter;
const makeRange = support.makeRange;
const startsWith = support.startsWith;
const startsWithAt = support.startsWithAt;

pub fn analyze(
    comptime spec: types.SourceSpec,
    comptime profile: types.TemplateSourceProfile,
) AnalysisType(spec, profile) {
    var parser = Parser(spec, profile).init();
    parser.run();
    return parser.analysis;
}

pub fn AnalysisType(
    comptime spec: types.SourceSpec,
    comptime profile: types.TemplateSourceProfile,
) type {
    return types.Analysis(directiveCapacity(spec.bytes.len, profile));
}

fn directiveCapacity(length: usize, profile: types.TemplateSourceProfile) usize {
    return @max(1, @min(length / 4 + 1, @as(usize, profile.directives_max)));
}

fn Parser(
    comptime spec: types.SourceSpec,
    comptime profile: types.TemplateSourceProfile,
) type {
    const source = spec.bytes;
    const directive_capacity = directiveCapacity(source.len, profile);
    const element_capacity = @max(1, @min(
        source.len / 3 + 1,
        @as(usize, profile.html_element_depth_max),
    ));
    const control_capacity = @max(1, @min(
        source.len / 4 + 1,
        @as(usize, profile.template_control_depth_max),
    ));
    const attribute_capacity = source.len / 4 + 1;
    const Analysis = types.Analysis(directive_capacity);
    const Attribute = state.AttributeSeen;

    return struct {
        analysis: Analysis = .{},
        elements: [element_capacity]state.ElementFrame = undefined,
        controls: [control_capacity]state.ControlFrame = undefined,
        attributes: [attribute_capacity]Attribute = undefined,
        paths: [directive_capacity]state.PathNode = undefined,
        json_names: [directive_capacity]types.SourceRange = undefined,
        index: usize = 0,
        element_depth: usize = 0,
        control_depth: usize = 0,
        attribute_count: usize = 0,
        json_name_count: usize = 0,
        path_count: usize = 0,
        current_path: u32 = state.no_path,
        repeating_depth: u32 = 0,
        body_slot_count: u32 = 0,
        context: types.ParserContext = .html_data,
        region: types.Region = if (spec.kind == .fragment) .fragment else .document_root,
        document_stage: state.DocumentStage = if (spec.kind == .fragment)
            .fragment
        else
            .need_doctype,
        tag_name: types.SourceRange = empty_range,
        tag_namespace: tables.Namespace = .html,
        tag_separator: bool = false,
        current_attribute: types.SourceRange = empty_range,

        const Self = @This();
        pub const source_bytes = source;
        pub const source_kind = spec.kind;
        pub const source_profile = profile;
        pub const element_capacity_max = element_capacity;

        fn init() Self {
            return .{};
        }

        fn run(self: *Self) void {
            if (!self.preflight()) return;
            while (self.index < source.len and self.analysis.problem == null) {
                if (self.inRawText()) {
                    self.parseRawText();
                } else if (self.inRcData()) {
                    self.parseRcData();
                } else {
                    self.parseData();
                }
            }
            if (self.analysis.problem != null) return;
            self.finish();
        }

        fn preflight(self: *Self) bool {
            if (!types.profileValid(profile)) return self.stop(.profile_limit_zero, 0);
            if (source.len > std.math.maxInt(u32)) {
                return self.stopWith(.source_offset_overflow, 0, 0, 0);
            }
            if (source.len > profile.source_bytes_max) {
                return self.stopWith(
                    .source_too_long,
                    profile.source_bytes_max,
                    @intCast(source.len),
                    profile.source_bytes_max,
                );
            }
            if (source.len > profile.graph_source_bytes_max) {
                return self.stopWith(
                    .graph_source_too_long,
                    profile.graph_source_bytes_max,
                    @intCast(source.len),
                    profile.graph_source_bytes_max,
                );
            }
            if (startsWith(source, "\xef\xbb\xbf")) return self.stop(.byte_order_mark, 0);
            if (types.invalidUtf8Offset(source)) |offset| {
                return self.stop(.invalid_utf8, offset);
            }
            for (source, 0..) |byte, offset| {
                if (byte == 0) return self.stop(.nul_byte, offset);
            }
            if (spec.kind != .fragment and !startsWith(source, doctype)) {
                return self.stop(.missing_document_doctype, 0);
            }
            return true;
        }

        fn finish(self: *Self) void {
            if (self.control_depth != 0) {
                const frame = self.controls[self.control_depth - 1];
                const code: types.ProblemCode = if (frame.kind == .verbatim)
                    .unclosed_verbatim
                else
                    .block_mismatch;
                _ = self.stop(code, frame.open_at);
                return;
            }
            if (self.element_depth != 0) {
                _ = self.stop(.unclosed_element, self.elements[self.element_depth - 1].open_at);
                return;
            }
            if (spec.kind != .fragment and self.document_stage != .closed) {
                _ = self.stop(.document_structure, source.len);
                return;
            }
            if (spec.kind == .layout and self.body_slot_count != 1) {
                _ = self.stopWith(.missing_body_slot, source.len, self.body_slot_count, 1);
            }
        }

        fn parseData(self: *Self) void {
            if (self.startsDirective() and self.shouldParseDirective()) {
                _ = self.parseDirective();
                return;
            }
            if (source[self.index] != '<') {
                if (!self.textByteAllowed(source[self.index])) {
                    _ = self.stop(.foster_parenting, self.index);
                    return;
                }
                self.index += 1;
                return;
            }
            if (startsWithAt(source, self.index, "<!--")) {
                _ = self.parseComment();
            } else if (startsWithAt(source, self.index, doctype)) {
                _ = self.parseDoctype();
            } else if (startsWithAt(source, self.index, "</")) {
                _ = tags.parseEndTag(self);
            } else if (self.index + 1 < source.len and
                isTagNameLead(source[self.index + 1]))
            {
                _ = tags.parseStartTag(self);
            } else {
                _ = self.stop(.malformed_declaration, self.index);
            }
        }

        fn parseRawText(self: *Self) void {
            const name = self.topName();
            if (startsEndTag(source, self.index, name)) {
                _ = tags.parseEndTag(self);
                return;
            }
            if (self.startsDirective() and self.shouldParseDirective()) {
                _ = self.parseDirective();
                return;
            }
            self.index += 1;
        }

        fn parseRcData(self: *Self) void {
            const name = self.topName();
            if (startsEndTag(source, self.index, name)) {
                _ = tags.parseEndTag(self);
                return;
            }
            if (self.startsDirective() and self.shouldParseDirective()) {
                _ = self.parseDirective();
                return;
            }
            self.index += 1;
        }

        fn parseDoctype(self: *Self) bool {
            if (spec.kind == .fragment) return self.stop(.fragment_doctype, self.index);
            if (self.index != 0 or self.document_stage != .need_doctype) {
                return self.stop(.malformed_declaration, self.index);
            }
            self.index += doctype.len;
            self.document_stage = .need_html;
            return true;
        }

        fn parseComment(self: *Self) bool {
            const start = self.index;
            var cursor = start + 4;
            while (cursor + 2 < source.len) : (cursor += 1) {
                if (startsWithAt(source, cursor, "{{")) {
                    return self.stop(.directive_context, cursor);
                }
                if (!startsWithAt(source, cursor, "-->")) {
                    if (startsWithAt(source, cursor, "--")) {
                        return self.stop(.malformed_comment, cursor);
                    }
                    continue;
                }
                self.index = cursor + 3;
                return true;
            }
            return self.stop(.malformed_comment, start);
        }

        pub fn parseDirective(self: *Self) bool {
            const result = directives.lex(source, self.index, profile);
            const lexed = switch (result) {
                .failure => |problem| return self.stopLex(problem),
                .directive => |value| value,
            };
            if (self.analysis.directive_count == profile.directives_max) {
                return self.stopWith(
                    .directive_limit,
                    self.index,
                    self.analysis.directive_count + 1,
                    profile.directives_max,
                );
            }
            if (lexed.trim_before and self.context == .before_attribute) {
                self.tag_separator = false;
            }
            if (!self.applyDirective(lexed)) return false;
            self.recordDirective(lexed);
            self.index = lexed.source.end;
            if (lexed.trim_after) {
                while (self.index < source.len and tables.isHtmlSpace(source[self.index])) {
                    self.index += 1;
                }
            }
            return true;
        }

        fn applyDirective(self: *Self, lexed: directives.Lexed) bool {
            if (!self.directiveContextAllowed(lexed.kind)) {
                return self.stop(.directive_context, lexed.source.start);
            }
            if (!self.validateDirectiveExpressions(lexed)) return false;
            return switch (lexed.kind) {
                .if_open, .with_open, .each_open, .verbatim_open => self.openBlock(lexed),
                .else_branch => self.branchElse(lexed),
                .block_close, .verbatim_close => self.closeBlock(lexed),
                .json_data => self.registerJsonData(lexed),
                .body_slot => self.registerBodySlot(lexed),
                .inline_css, .inline_javascript => true,
                else => true,
            };
        }

        fn openBlock(self: *Self, lexed: directives.Lexed) bool {
            if (lexed.kind == .each_open and self.context == .before_attribute) {
                return self.stop(.each_between_attributes, lexed.source.start);
            }
            if (self.control_depth == control_capacity) {
                return self.stopWith(
                    .control_depth_limit,
                    lexed.source.start,
                    @intCast(self.control_depth + 1),
                    profile.template_control_depth_max,
                );
            }
            const kind = lexed.block_kind orelse unreachable;
            self.controls[self.control_depth] = .{
                .kind = kind,
                .name = lexed.name,
                .auxiliary = lexed.auxiliary,
                .snapshot = self.snapshot(),
                .id = self.analysis.directive_count,
                .open_at = lexed.source.start,
                .parent_path = self.current_path,
            };
            self.current_path = state.appendPath(
                &self.paths,
                &self.path_count,
                self.current_path,
                self.analysis.directive_count,
                false,
            );
            self.control_depth += 1;
            if (kind == .each_block) self.repeating_depth += 1;
            self.analysis.maximum_control_depth = @max(
                self.analysis.maximum_control_depth,
                @as(u32, @intCast(self.control_depth)),
            );
            return true;
        }

        fn branchElse(self: *Self, lexed: directives.Lexed) bool {
            if (self.control_depth == 0) return self.stop(.block_mismatch, lexed.source.start);
            var frame = &self.controls[self.control_depth - 1];
            if (frame.kind == .verbatim) return self.stop(.block_mismatch, lexed.source.start);
            if (frame.had_else) return self.stop(.duplicate_else, lexed.source.start);
            if (!self.contextMatches(frame.snapshot)) {
                return self.stopRelated(.control_context, lexed.source.start, frame.open_at);
            }
            frame.first_branch_separator = self.tag_separator;
            frame.had_else = true;
            frame.else_branch = true;
            self.current_path = state.appendPath(
                &self.paths,
                &self.path_count,
                frame.parent_path,
                frame.id,
                true,
            );
            self.tag_separator = frame.snapshot.tag_separator;
            return true;
        }

        fn closeBlock(self: *Self, lexed: directives.Lexed) bool {
            if (self.control_depth == 0) return self.stop(.block_mismatch, lexed.source.start);
            const frame = self.controls[self.control_depth - 1];
            if (!blockNameMatches(frame.kind, lexed.name.bytes(source))) {
                return self.stopRelated(.block_mismatch, lexed.source.start, frame.open_at);
            }
            if (!self.contextMatches(frame.snapshot)) {
                return self.stopRelated(.control_context, lexed.source.start, frame.open_at);
            }
            if (self.context == .before_attribute) {
                const other = if (frame.had_else)
                    frame.first_branch_separator
                else
                    frame.snapshot.tag_separator;
                self.tag_separator = self.tag_separator and other;
            }
            self.control_depth -= 1;
            self.current_path = frame.parent_path;
            if (frame.kind == .each_block) self.repeating_depth -= 1;
            return true;
        }

        fn registerJsonData(self: *Self, lexed: directives.Lexed) bool {
            if (self.repeating_depth != 0) {
                return self.stop(.repeated_json_data, lexed.source.start);
            }
            if (!directives.validStaticName(lexed.name.bytes(source))) {
                return self.stop(.invalid_json_data_name, lexed.name.start);
            }
            for (self.json_names[0..self.json_name_count]) |name| {
                if (equal(name.bytes(source), lexed.name.bytes(source))) {
                    return self.stopRelated(.duplicate_json_data, lexed.name.start, name.start);
                }
            }
            self.json_names[self.json_name_count] = lexed.name;
            self.json_name_count += 1;
            return true;
        }

        fn registerBodySlot(self: *Self, lexed: directives.Lexed) bool {
            if (spec.kind != .layout) return self.stop(.unexpected_body_slot, lexed.source.start);
            if (self.region != .body or self.context != .html_data or self.control_depth != 0) {
                return self.stop(.invalid_body_slot, lexed.source.start);
            }
            self.body_slot_count += 1;
            if (self.body_slot_count > 1) {
                return self.stopWith(
                    .invalid_body_slot,
                    lexed.source.start,
                    self.body_slot_count,
                    1,
                );
            }
            return true;
        }

        fn validateDirectiveExpressions(self: *Self, lexed: directives.Lexed) bool {
            switch (lexed.kind) {
                .interpolation, .if_open, .with_open, .each_open, .partial, .json_data => {
                    return self.validateFieldRoot(lexed.expression);
                },
                .helper => {
                    if (reservedHelperName(lexed.name.bytes(source))) {
                        return self.stop(.unsupported_directive, lexed.name.start);
                    }
                    var cursor: usize = lexed.expression.start;
                    while (cursor < lexed.expression.end) {
                        while (cursor < lexed.expression.end and
                            tables.isHtmlSpace(source[cursor])) cursor += 1;
                        const start = cursor;
                        while (cursor < lexed.expression.end and
                            !tables.isHtmlSpace(source[cursor])) cursor += 1;
                        if (start < cursor and !self.validateFieldRoot(makeRange(start, cursor))) {
                            return false;
                        }
                    }
                },
                else => {},
            }
            return true;
        }

        fn validateFieldRoot(self: *Self, expression: types.SourceRange) bool {
            const root = directives.fieldRoot(expression, source);
            if (equal(root.bytes(source), "view")) return true;
            var depth = self.control_depth;
            while (depth > 0) {
                depth -= 1;
                const frame = self.controls[depth];
                if (frame.else_branch) continue;
                if (frame.kind != .with_block and frame.kind != .each_block) continue;
                if (equal(frame.name.bytes(source), root.bytes(source))) return true;
                if (frame.auxiliary.start != frame.auxiliary.end and
                    equal(frame.auxiliary.bytes(source), root.bytes(source))) return true;
            }
            return self.stop(.unknown_local, root.start);
        }

        fn directiveContextAllowed(self: *Self, kind: types.DirectiveKind) bool {
            if (self.context == .svg) return false;
            if (kind == .verbatim_open or kind == .verbatim_close) return true;
            if (kind == .inline_css) return self.context == .style_text and self.topIs("style");
            if (kind == .inline_javascript) {
                return self.context == .script_text and self.topIs("script");
            }
            if (self.context == .script_text or self.context == .style_text) return false;
            return switch (kind) {
                .comment => true,
                .interpolation, .helper => self.valueDirectiveContext(),
                .if_open, .with_open => self.controlDirectiveContext(),
                .each_open => self.controlDirectiveContext(),
                .else_branch, .block_close => true,
                .partial => self.context == .html_data and self.bodyLikeRegion() and
                    !self.textPlacementRestricted(),
                .json_data => self.context == .html_data and self.bodyLikeRegion() and
                    !self.textPlacementRestricted(),
                .body_slot => self.context == .html_data and self.region == .body and
                    !self.textPlacementRestricted(),
                .inline_css, .inline_javascript => unreachable,
                .verbatim_open, .verbatim_close => unreachable,
            };
        }

        fn valueDirectiveContext(self: *Self) bool {
            if (self.context == .html_data and self.textPlacementRestricted()) return false;
            return switch (self.context) {
                .html_data,
                .title_text,
                .textarea_text,
                .attribute_inert,
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

        fn controlDirectiveContext(self: *Self) bool {
            return switch (self.context) {
                .html_data,
                .title_text,
                .textarea_text,
                .before_attribute,
                .attribute_inert,
                => true,
                else => false,
            };
        }

        fn recordDirective(self: *Self, lexed: directives.Lexed) void {
            self.analysis.directives[self.analysis.directive_count] = .{
                .source = lexed.source,
                .name = lexed.name,
                .expression = lexed.expression,
                .auxiliary = lexed.auxiliary,
                .context = self.context,
                .kind = lexed.kind,
                .region = self.region,
                .argument_count = lexed.argument_count,
                .control_depth = @intCast(self.control_depth),
                .repeating_depth = self.repeating_depth,
                .trim_before = lexed.trim_before,
                .trim_after = lexed.trim_after,
            };
            self.analysis.directive_count += 1;
        }

        fn textByteAllowed(self: *const Self, byte: u8) bool {
            if (spec.kind != .fragment and self.region == .document_root) {
                return tables.isHtmlSpace(byte);
            }
            if (!self.textPlacementRestricted()) return true;
            return tables.isHtmlSpace(byte);
        }

        fn textPlacementRestricted(self: *const Self) bool {
            if (self.region == .document_root) return true;
            if (self.element_depth == 0 or
                self.elements[self.element_depth - 1].namespace == .svg)
            {
                return false;
            }
            if (self.region == .head and self.topIs("head")) return true;
            return nameIn(
                self.topName(),
                &.{ "table", "colgroup", "thead", "tbody", "tfoot", "tr", "select", "optgroup" },
            );
        }

        pub fn refreshContext(self: *Self) void {
            if (self.element_depth == 0) {
                self.context = .html_data;
                return;
            }
            const top = self.elements[self.element_depth - 1];
            if (top.namespace == .svg) {
                self.context = .svg;
            } else if (tables.equalAsciiIgnoreCase(top.name.bytes(source), "title")) {
                self.context = .title_text;
            } else if (tables.equalAsciiIgnoreCase(top.name.bytes(source), "textarea")) {
                self.context = .textarea_text;
            } else if (tables.equalAsciiIgnoreCase(top.name.bytes(source), "style")) {
                self.context = .style_text;
            } else if (tables.isRawTextElement(top.name.bytes(source))) {
                self.context = .script_text;
            } else {
                self.context = .html_data;
            }
        }

        fn inRawText(self: *const Self) bool {
            return self.element_depth != 0 and
                self.elements[self.element_depth - 1].namespace == .html and
                tables.isRawTextElement(self.topName());
        }

        fn inRcData(self: *const Self) bool {
            return self.element_depth != 0 and
                self.elements[self.element_depth - 1].namespace == .html and
                tables.isRcDataElement(self.topName());
        }

        pub fn startsDirective(self: *const Self) bool {
            return startsWithAt(source, self.index, "{{");
        }

        pub fn shouldParseDirective(self: *Self) bool {
            if (!self.verbatimActive()) return true;
            if (directives.isExactVerbatimOpen(source, self.index)) {
                _ = self.stop(.nested_verbatim, self.index);
                return false;
            }
            return directives.isExactVerbatimClose(source, self.index);
        }

        fn verbatimActive(self: *const Self) bool {
            return self.control_depth != 0 and
                self.controls[self.control_depth - 1].kind == .verbatim;
        }

        fn snapshot(self: *const Self) state.ContextSnapshot {
            return .{
                .context = self.context,
                .region = self.region,
                .document_stage = self.document_stage,
                .element_depth = self.element_depth,
                .tag_separator = self.tag_separator,
            };
        }

        fn contextMatches(self: *const Self, snapshot_value: state.ContextSnapshot) bool {
            return self.context == snapshot_value.context and
                self.region == snapshot_value.region and
                self.document_stage == snapshot_value.document_stage and
                self.element_depth == snapshot_value.element_depth;
        }

        pub fn closingCrossesControl(self: *const Self) bool {
            const next_depth = self.element_depth - 1;
            for (self.controls[0..self.control_depth]) |frame| {
                if (next_depth < frame.snapshot.element_depth) return true;
            }
            return false;
        }

        pub fn controlStartedInContext(
            self: *const Self,
            context: types.ParserContext,
        ) bool {
            for (self.controls[0..self.control_depth]) |frame| {
                if (frame.snapshot.context == context and
                    frame.snapshot.element_depth == self.element_depth) return true;
            }
            return false;
        }

        fn bodyLikeRegion(self: *const Self) bool {
            return self.region == .body or self.region == .fragment;
        }

        pub fn topName(self: *const Self) []const u8 {
            return self.elements[self.element_depth - 1].name.bytes(source);
        }

        pub fn topIs(self: *const Self, name: []const u8) bool {
            return self.element_depth != 0 and tables.equalAsciiIgnoreCase(self.topName(), name);
        }

        pub fn ancestorIs(self: *const Self, name: []const u8) bool {
            for (self.elements[0..self.element_depth]) |element| {
                if (element.namespace == .html and
                    tables.equalAsciiIgnoreCase(element.name.bytes(source), name)) return true;
            }
            return false;
        }

        pub fn hasHeadingAncestor(self: *const Self) bool {
            for (self.elements[0..self.element_depth]) |element| {
                if (element.namespace == .html and
                    tables.isHeading(element.name.bytes(source))) return true;
            }
            return false;
        }

        pub fn stop(self: *Self, code: types.ProblemCode, offset: usize) bool {
            return self.stopWith(code, offset, 0, 0);
        }

        pub fn stopRelated(
            self: *Self,
            code: types.ProblemCode,
            offset: usize,
            related: usize,
        ) bool {
            self.analysis.problem = .{
                .code = code,
                .at = types.position(source, offset),
                .related_at = types.position(source, related),
            };
            return false;
        }

        pub fn stopWith(
            self: *Self,
            code: types.ProblemCode,
            offset: usize,
            actual: u32,
            limit: u32,
        ) bool {
            self.analysis.problem = .{
                .code = code,
                .at = types.position(source, @min(offset, source.len)),
                .actual = actual,
                .limit = limit,
            };
            return false;
        }

        fn stopLex(self: *Self, problem: directives.Failure) bool {
            return self.stopWith(
                problem.code,
                problem.offset,
                problem.actual,
                problem.limit,
            );
        }
    };
}

fn blockNameMatches(kind: types.BlockKind, name: []const u8) bool {
    return switch (kind) {
        .if_block => equal(name, "if"),
        .with_block => equal(name, "with"),
        .each_block => equal(name, "each"),
        .verbatim => equal(name, "verbatim"),
    };
}

fn reservedHelperName(name: []const u8) bool {
    return equal(name, "if") or equal(name, "with") or equal(name, "each") or
        equal(name, "else") or equal(name, "verbatim");
}

fn nameIn(name: []const u8, names: []const []const u8) bool {
    for (names) |candidate| {
        if (tables.equalAsciiIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn startsEndTag(source: []const u8, index: usize, name: []const u8) bool {
    if (!startsWithAt(source, index, "</") or index + 2 + name.len >= source.len) return false;
    if (!tables.equalAsciiIgnoreCase(source[index + 2 .. index + 2 + name.len], name)) return false;
    const next = source[index + 2 + name.len];
    return next == '>' or tables.isHtmlSpace(next);
}

fn isTagNameLead(byte: u8) bool {
    return isAsciiLetter(byte) or byte >= 0x80;
}

const empty_range = types.SourceRange{ .start = 0, .end = 0 };
