const std = @import("std");
const asset = @import("../../asset.zig");
const diagnostic = @import("template_diagnostic.zig");
const template_assets = @import("template_assets.zig");
const errors = @import("template_errors.zig");
const expression = @import("template_expression.zig");
const graph = @import("template_graph.zig");
const capability = @import("value_capability.zig");
const json_graph = @import("template_json_graph.zig");
const types = @import("template_types.zig");
const html_render = @import("../../html/render.zig");
const html_source = @import("../../html/source.zig");
const json = @import("../../json.zig");

pub const helper_arguments_hard_max: u32 = 8;
pub const helper_declarations_hard_max: u32 = 256;

const ReservedApplicationError = types.ValueError || json.FrameworkEncodeError || error{
    ResponseChunksExhausted,
    SourceAliasesPool,
    WriterTerminal,
};

const GraphResolver = struct {
    pub fn child(
        comptime Parent: type,
        comptime name: []const u8,
        comptime Source: type,
        comptime offset: usize,
    ) type {
        return partialNode(Parent, name, Source, offset);
    }
};

const ErrorResolver = struct {
    pub fn resolveHelperReturn(
        comptime Current: type,
        comptime Scope: type,
        comptime index: usize,
    ) type {
        return helperReturn(Current, Scope, index);
    }

    pub fn resolvePartial(comptime Current: type, comptime index: usize) type {
        const Source = Current.SourceType;
        const directive = Source.directives[index];
        return partialNode(
            Current,
            directive.name.bytes(Source.source),
            Source,
            directive.name.start,
        );
    }
};

pub fn Node(comptime config: anytype, comptime ancestors: anytype) type {
    const Config = @TypeOf(config);
    validateConfigShape(Config);
    const ResolvedView = @field(config, "View");
    if (@TypeOf(ResolvedView) != type or !types.runtimeType(ResolvedView)) {
        diagnostic.failConfig(.invalid_view, "View must be a concrete runtime type");
    }
    const spec = @field(config, "source");
    if (@TypeOf(spec) != html_source.SourceSpec) {
        diagnostic.failConfig(.invalid_config, "source must be html_source.SourceSpec");
    }
    const profile = configField(config, "profile", html_source.TemplateSourceProfile{});
    if (@TypeOf(profile) != html_source.TemplateSourceProfile) {
        diagnostic.failSpec(.invalid_config, spec, 0, "profile has the wrong type");
    }
    if (profile.helper_arguments_max > helper_arguments_hard_max) {
        diagnostic.failSpec(.invalid_config, spec, 0, "helper argument limit exceeds 8");
    }
    const Source = html_source.compile(spec, profile);
    graph.validateAncestry(Source, ancestors);
    const helpers = configField(config, "helpers", .{});
    const partials = configField(config, "partials", .{});
    const assets = configField(config, "assets", .{});
    const browser_json = configField(config, "browser_json", html_render.BrowserJsonOptions{});
    validateNamedStruct(@TypeOf(helpers), Source, .invalid_helpers, "helpers");
    validateNamedStruct(@TypeOf(partials), Source, .invalid_partials, "partials");
    validateNamedStruct(@TypeOf(assets), Source, .invalid_assets, "assets");
    if (@TypeOf(browser_json) != html_render.BrowserJsonOptions) {
        diagnostic.fail(.invalid_config, Source, 0, "browser_json has the wrong type");
    }
    return struct {
        pub const ploof_html_template_node = true;
        pub const ConfigValue = config;
        pub const ViewType = ResolvedView;
        pub const SourceType = Source;
        pub const profile_value = profile;
        pub const helpers_value = helpers;
        pub const partials_value = partials;
        pub const assets_value = assets;
        pub const browser_json_value = browser_json;
        pub const ancestor_types = ancestors;
        pub const links = graph.makeControlLinks(Source);
    };
}

pub fn validateGraph(comptime Root: type) void {
    @setEvalBranchQuota(100_000_000);
    graph.validateHardLimits(Root, GraphResolver);
    validateNode(Root);
}

pub fn validateCombinedJson(comptime Left: type, comptime Right: type) void {
    json_graph.validateDisjoint(Left, Right, GraphResolver);
}

pub fn TemplateError(comptime Root: type) type {
    return errors.render(Root, ErrorResolver);
}

pub fn TemplateHelperError(comptime Root: type) type {
    return errors.helper(Root, ErrorResolver);
}

pub fn TemplateApplicationError(comptime Root: type) type {
    return errors.application(Root, ErrorResolver);
}

pub fn browserJsonScratchBytes(comptime Root: type) usize {
    return graph.browserJsonScratchBytes(Root, GraphResolver);
}

pub fn partialNode(
    comptime Parent: type,
    comptime name: []const u8,
    comptime Source: type,
    comptime offset: usize,
) type {
    const Partials = @TypeOf(Parent.partials_value);
    if (!@hasField(Partials, name)) {
        diagnostic.fail(.unknown_partial, Source, offset, "unknown partial '" ++ name ++ "'");
    }
    return Node(
        @field(Parent.partials_value, name),
        Parent.ancestor_types ++ .{Parent},
    );
}

pub fn helperReturn(
    comptime NodeType: type,
    comptime Scope: type,
    comptime directive_index: usize,
) type {
    const Source = NodeType.SourceType;
    const directive = Source.directives[directive_index];
    const name = directive.name.bytes(Source.source);
    const Helpers = @TypeOf(NodeType.helpers_value);
    if (!@hasField(Helpers, name)) {
        diagnostic.fail(
            .unknown_helper,
            Source,
            directive.name.start,
            "unknown helper '" ++ name ++ "'",
        );
    }
    const Helper = @TypeOf(@field(NodeType.helpers_value, name));
    const info = helperInfo(Helper, Source, directive.name.start);
    if (info.params.len != directive.argument_count) {
        diagnostic.fail(
            .helper_argument_mismatch,
            Source,
            directive.name.start,
            std.fmt.comptimePrint(
                "helper '{s}' expects {d} arguments but source passes {d}",
                .{ name, info.params.len, directive.argument_count },
            ),
        );
    }
    validateHelperArguments(NodeType, Scope, directive_index, info);
    return info.return_type.?;
}

pub fn outputError(comptime T: type) type {
    if (!types.hasFormatText(T)) return error{};
    const Return = formatTextReturn(T);
    return types.errorSet(Return);
}

pub fn outputKind(comptime T: type) OutputKind {
    return types.outputKind(T);
}

pub const OutputKind = types.OutputKind;

fn validateNode(comptime Current: type) void {
    graph.validateSourceLimit(Current, GraphResolver);
    validateHelpers(Current);
    validateRange(Current, types.EmptyScope, 0, Current.SourceType.directives.len);
    const fields = @typeInfo(@TypeOf(Current.partials_value)).@"struct".fields;
    inline for (fields) |field| {
        const Child = partialNode(Current, field.name, Current.SourceType, 0);
        if (Child.SourceType.kind != .fragment) {
            diagnostic.fail(
                .invalid_partial,
                Child.SourceType,
                0,
                "partial source kind must be fragment",
            );
        }
        validateNode(Child);
    }
    json_graph.validate(Current, GraphResolver);
}

fn validateRange(
    comptime Current: type,
    comptime Scope: type,
    comptime start: usize,
    comptime end: usize,
) void {
    comptime var index = start;
    inline while (index < end) {
        const directive = Current.SourceType.directives[index];
        switch (directive.kind) {
            .interpolation => validateInterpolation(Current, Scope, index),
            .helper => validateHelper(Current, Scope, index),
            .if_open, .with_open, .each_open => {
                validateControl(Current, Scope, index);
                index = Current.links[index].close_index;
            },
            .partial => validatePartial(Current, Scope, index),
            .json_data => validateJson(Current, Scope, index),
            .inline_css, .inline_javascript => template_assets.validate(Current, index),
            .body_slot, .comment, .verbatim_open, .verbatim_close => {},
            .else_branch, .block_close => unreachable,
        }
        index += 1;
    }
}

fn validateControl(
    comptime Current: type,
    comptime Scope: type,
    comptime index: usize,
) void {
    const Source = Current.SourceType;
    const directive = Source.directives[index];
    const path = directive.expression.bytes(Source.source);
    const Value = expression.resolveType(
        View(Current),
        Scope,
        path,
        Source,
        directive.expression.start,
    );
    const link = Current.links[index];
    const true_end = link.else_index orelse link.close_index;
    switch (directive.kind) {
        .if_open => {
            if (Value != bool) typeFailure(.if_not_bool, Current, directive, Value);
            validateRange(Current, Scope, index + 1, true_end);
        },
        .with_open => validateWith(Current, Scope, index, true_end, Value),
        .each_open => validateEach(Current, Scope, index, true_end, Value),
        else => unreachable,
    }
    if (link.else_index) |alternative| {
        validateRange(Current, Scope, alternative + 1, link.close_index);
    }
}

fn validateWith(
    comptime Current: type,
    comptime Scope: type,
    comptime index: usize,
    comptime end: usize,
    comptime Value: type,
) void {
    const directive = Current.SourceType.directives[index];
    const optional = switch (@typeInfo(Value)) {
        .optional => |value| value,
        else => typeFailure(.with_not_optional, Current, directive, Value),
    };
    const name = directive.name.bytes(Current.SourceType.source);
    const ChildScope = types.Binding(name, optional.child, Scope);
    validateRange(Current, ChildScope, index + 1, end);
}

fn validateEach(
    comptime Current: type,
    comptime Scope: type,
    comptime index: usize,
    comptime end: usize,
    comptime Value: type,
) void {
    const directive = Current.SourceType.directives[index];
    const Child = types.collectionChild(Value) orelse {
        typeFailure(.each_not_collection, Current, directive, Value);
    };
    if (Child == u8) typeFailure(.each_not_collection, Current, directive, Value);
    const name = directive.name.bytes(Current.SourceType.source);
    const ItemScope = types.Binding(name, Child, Scope);
    if (directive.auxiliary.start == directive.auxiliary.end) {
        validateRange(Current, ItemScope, index + 1, end);
    } else {
        const index_name = directive.auxiliary.bytes(Current.SourceType.source);
        validateRange(Current, types.Binding(index_name, usize, ItemScope), index + 1, end);
    }
}

fn validateInterpolation(
    comptime Current: type,
    comptime Scope: type,
    comptime index: usize,
) void {
    const Source = Current.SourceType;
    const directive = Source.directives[index];
    const path = directive.expression.bytes(Source.source);
    const T = expression.resolveType(
        View(Current),
        Scope,
        path,
        Source,
        directive.expression.start,
    );
    validateOutput(T, directive.context, Source, directive.expression.start);
}

fn validateHelper(
    comptime Current: type,
    comptime Scope: type,
    comptime index: usize,
) void {
    const Source = Current.SourceType;
    const directive = Source.directives[index];
    const Return = helperReturn(Current, Scope, index);
    const Payload = types.payloadType(Return);
    validateOutput(Payload, directive.context, Source, directive.name.start);
}

fn validatePartial(
    comptime Current: type,
    comptime Scope: type,
    comptime index: usize,
) void {
    const Source = Current.SourceType;
    const directive = Source.directives[index];
    const name = directive.name.bytes(Source.source);
    const Child = partialNode(Current, name, Source, directive.name.start);
    if (Child.SourceType.kind != .fragment) {
        diagnostic.fail(
            .invalid_partial,
            Source,
            directive.name.start,
            "partial must be a fragment",
        );
    }
    const path = directive.expression.bytes(Source.source);
    const Actual = expression.resolveType(
        View(Current),
        Scope,
        path,
        Source,
        directive.expression.start,
    );
    if (Actual != Child.ViewType) {
        diagnostic.fail(
            .partial_view_mismatch,
            Source,
            directive.expression.start,
            "partial view is '" ++ @typeName(Child.ViewType) ++
                "' but expression is '" ++ @typeName(Actual) ++ "'",
        );
    }
}

fn validateJson(
    comptime Current: type,
    comptime Scope: type,
    comptime index: usize,
) void {
    const Source = Current.SourceType;
    const directive = Source.directives[index];
    const path = directive.expression.bytes(Source.source);
    const T = expression.resolveType(
        View(Current),
        Scope,
        path,
        Source,
        directive.expression.start,
    );
    _ = json.DeclaredEncodeError(T);
    validateApplicationErrorSet(
        json.CustomEncodeError(T),
        Source,
        directive.expression.start,
    );
}

fn validateOutput(
    comptime T: type,
    comptime context: html_source.ParserContext,
    comptime Source: type,
    comptime offset: usize,
) void {
    const kind = outputKind(T);
    const valid = switch (context) {
        .html_data => kind == .text or kind == .trusted_html,
        .title_text, .textarea_text, .attribute_inert => kind == .text,
        .attribute_navigation_url, .attribute_media_url => kind == .url,
        .attribute_asset_url => kind == .url or kind == .asset_ref,
        .attribute_image_url => kind == .url or assetKindIn(T, image_asset_kinds),
        .attribute_font_url => kind == .url or assetKindIn(T, font_asset_kinds),
        .attribute_text_url => kind == .url or assetKindIn(T, &.{.text}),
        .attribute_trusted_resource_url => kind == .trusted_resource_url,
        .attribute_script_url => kind == .trusted_resource_url or
            assetKindIn(T, &.{.javascript}),
        .attribute_style_url => kind == .trusted_resource_url or assetKindIn(T, &.{.css}),
        .attribute_document_url => kind == .trusted_resource_url or
            assetKindIn(T, &.{.html}),
        .attribute_json_url => kind == .trusted_resource_url or assetKindIn(T, &.{.json}),
        .attribute_xml_url => kind == .trusted_resource_url or assetKindIn(T, &.{.xml}),
        .attribute_any_resource_url => kind == .trusted_resource_url or kind == .asset_ref,
        else => false,
    };
    if (!valid) {
        diagnostic.fail(
            .invalid_output_type,
            Source,
            offset,
            "type '" ++ @typeName(T) ++ "' is invalid in " ++ @tagName(context),
        );
    }
    if (kind == .text and types.hasFormatText(T)) validateFormatText(T, Source, offset);
}

fn assetKindIn(comptime T: type, comptime allowed: []const asset.MediaKind) bool {
    const kind = asset.referenceKind(T) orelse return false;
    inline for (allowed) |candidate| if (kind == candidate) return true;
    return false;
}

const image_asset_kinds = &[_]asset.MediaKind{
    .svg,
    .png,
    .jpeg,
    .gif,
    .webp,
    .avif,
    .ico,
};

const font_asset_kinds = &[_]asset.MediaKind{
    .woff,
    .woff2,
    .ttf,
    .otf,
};

fn validateHelpers(comptime Current: type) void {
    const fields = @typeInfo(@TypeOf(Current.helpers_value)).@"struct".fields;
    if (fields.len > helper_declarations_hard_max) {
        diagnostic.fail(
            .invalid_helpers,
            Current.SourceType,
            0,
            "template declares more than 256 helpers",
        );
    }
    inline for (fields) |field| {
        const Helper = @TypeOf(@field(Current.helpers_value, field.name));
        const info = helperInfo(Helper, Current.SourceType, 0);
        const Return = info.return_type.?;
        const Payload = types.payloadType(Return);
        if (outputKind(Payload) == .unsupported) {
            diagnostic.fail(
                .invalid_output_type,
                Current.SourceType,
                0,
                "helper '" ++ field.name ++ "' has unsupported return type '" ++
                    @typeName(Payload) ++ "'",
            );
        }
        if (outputKind(Payload) == .text and types.hasFormatText(Payload)) {
            validateFormatText(Payload, Current.SourceType, 0);
        }
    }
}

fn helperInfo(
    comptime Helper: type,
    comptime Source: type,
    comptime offset: usize,
) std.builtin.Type.Fn {
    const info = switch (@typeInfo(Helper)) {
        .@"fn" => |value| value,
        else => diagnostic.fail(.invalid_helper, Source, offset, "helper must be a function"),
    };
    if (info.is_var_args) {
        diagnostic.fail(.invalid_helper, Source, offset, "helper cannot use variadic arguments");
    }
    if (types.hasComptimeParameter(Helper)) {
        diagnostic.fail(
            .invalid_helper,
            Source,
            offset,
            "helper parameters must be runtime values",
        );
    }
    for (info.params) |parameter| {
        if (parameter.type == null) {
            diagnostic.fail(
                .invalid_helper,
                Source,
                offset,
                "helper parameters must be concrete runtime values",
            );
        }
        const Parameter = parameter.type.?;
        if (capability.carries(Parameter)) {
            diagnostic.fail(
                .invalid_helper,
                Source,
                offset,
                "helper parameter '" ++ @typeName(Parameter) ++
                    "' carries a mutable or framework capability",
            );
        }
    }
    const Return = info.return_type orelse {
        diagnostic.fail(.invalid_helper, Source, offset, "helper requires an explicit return type");
    };
    if (@typeInfo(Return) == .error_union) {
        const ErrorSet = @typeInfo(Return).error_union.error_set;
        if (@typeInfo(ErrorSet).error_set == null) {
            diagnostic.fail(.helper_anyerror, Source, offset, "helper requires a finite error set");
        }
        validateApplicationErrors(Return, Source, offset);
    }
    return info;
}

fn validateHelperArguments(
    comptime Current: type,
    comptime Scope: type,
    comptime index: usize,
    comptime info: std.builtin.Type.Fn,
) void {
    const Source = Current.SourceType;
    const directive = Source.directives[index];
    const ranges = expression.helperArgumentRanges(
        Source.source,
        directive.expression.start,
        directive.expression.end,
        directive.argument_count,
    );
    inline for (ranges, 0..) |range, argument_index| {
        const path = Source.source[range.start..range.end];
        const Actual = expression.resolveType(View(Current), Scope, path, Source, range.start);
        const Expected = info.params[argument_index].type.?;
        if (Actual != Expected) {
            diagnostic.fail(
                .helper_argument_mismatch,
                Source,
                range.start,
                std.fmt.comptimePrint(
                    "helper argument {d} expects '{s}' but expression is '{s}'",
                    .{ argument_index + 1, @typeName(Expected), @typeName(Actual) },
                ),
            );
        }
    }
}

fn validateFormatText(
    comptime T: type,
    comptime Source: type,
    comptime offset: usize,
) void {
    if (capability.carries(T)) {
        diagnostic.fail(
            .invalid_output_type,
            Source,
            offset,
            "formatText self carries a mutable or framework capability",
        );
    }
    const function = @TypeOf(@field(T, "formatText"));
    const info = switch (@typeInfo(function)) {
        .@"fn" => |value| value,
        else => diagnostic.fail(
            .invalid_output_type,
            Source,
            offset,
            "formatText must be a function",
        ),
    };
    if (info.params.len != 1 or types.hasComptimeParameter(function) or
        info.params[0].type == null or info.params[0].type.? != T)
    {
        diagnostic.fail(
            .invalid_output_type,
            Source,
            offset,
            "formatText requires one concrete self value",
        );
    }
    const Return = info.return_type orelse {
        diagnostic.fail(.invalid_output_type, Source, offset, "formatText requires a return type");
    };
    if (@typeInfo(Return) == .error_union and
        @typeInfo(@typeInfo(Return).error_union.error_set).error_set == null)
    {
        diagnostic.fail(.invalid_output_type, Source, offset, "formatText requires finite errors");
    }
    validateApplicationErrors(Return, Source, offset);
    if (!types.isInlineText(types.payloadType(Return))) {
        diagnostic.fail(
            .invalid_output_type,
            Source,
            offset,
            "formatText must return InlineText(N)",
        );
    }
}

fn validateApplicationErrors(
    comptime Return: type,
    comptime Source: type,
    comptime offset: usize,
) void {
    if (@typeInfo(Return) != .error_union) return;
    const ErrorSet = @typeInfo(Return).error_union.error_set;
    validateApplicationErrorSet(ErrorSet, Source, offset);
}

fn validateApplicationErrorSet(
    comptime ErrorSet: type,
    comptime Source: type,
    comptime offset: usize,
) void {
    const declared = @typeInfo(ErrorSet).error_set orelse return;
    inline for (declared) |application_error| {
        if (!reservedApplicationError(application_error.name)) continue;
        diagnostic.fail(
            .reserved_application_error,
            Source,
            offset,
            "application error '" ++ application_error.name ++
                "' is reserved for framework rendering or transport",
        );
    }
}

fn reservedApplicationError(comptime name: []const u8) bool {
    const declared = @typeInfo(ReservedApplicationError).error_set orelse unreachable;
    inline for (declared) |framework_error| {
        if (std.mem.eql(u8, name, framework_error.name)) return true;
    }
    return false;
}

comptime {
    std.debug.assert(reservedApplicationError("ResponseChunksExhausted"));
    std.debug.assert(reservedApplicationError("ResponseBodyTooLarge"));
    std.debug.assert(reservedApplicationError("SourceAliasesPool"));
    std.debug.assert(reservedApplicationError("WriterTerminal"));
    std.debug.assert(reservedApplicationError("RenderWorkExhausted"));
    std.debug.assert(reservedApplicationError("InvalidUtf8"));
    std.debug.assert(reservedApplicationError("InvalidUrlKind"));
    std.debug.assert(reservedApplicationError("OriginNotAllowed"));
    std.debug.assert(reservedApplicationError("CircularReference"));
    std.debug.assert(!reservedApplicationError("UserError"));
}

fn formatTextReturn(comptime T: type) type {
    const info = @typeInfo(@TypeOf(@field(T, "formatText"))).@"fn";
    return info.return_type.?;
}

fn View(comptime Current: type) type {
    return Current.ViewType;
}

fn validateConfigShape(comptime Config: type) void {
    if (@typeInfo(Config) != .@"struct") {
        diagnostic.failConfig(.invalid_config, "Template config must be a struct value");
    }
    if (!@hasField(Config, "View") or !@hasField(Config, "source")) {
        diagnostic.failConfig(.invalid_config, "Template config requires View and source");
    }
}

fn validateNamedStruct(
    comptime T: type,
    comptime Source: type,
    comptime code: diagnostic.Code,
    comptime name: []const u8,
) void {
    if (@typeInfo(T) != .@"struct") {
        diagnostic.fail(code, Source, 0, name ++ " must be a named-field struct value");
    }
    if (@typeInfo(T).@"struct".is_tuple and @typeInfo(T).@"struct".fields.len != 0) {
        diagnostic.fail(code, Source, 0, name ++ " cannot be a tuple");
    }
}

fn configField(
    comptime config: anytype,
    comptime name: []const u8,
    comptime default: anytype,
) @TypeOf(
    if (@hasField(@TypeOf(config), name)) @field(config, name) else default,
) {
    return if (@hasField(@TypeOf(config), name)) @field(config, name) else default;
}

fn typeFailure(
    comptime code: diagnostic.Code,
    comptime Current: type,
    comptime directive: html_source.Directive,
    comptime Actual: type,
) noreturn {
    diagnostic.fail(
        code,
        Current.SourceType,
        directive.expression.start,
        "expression has type '" ++ @typeName(Actual) ++ "'",
    );
}
