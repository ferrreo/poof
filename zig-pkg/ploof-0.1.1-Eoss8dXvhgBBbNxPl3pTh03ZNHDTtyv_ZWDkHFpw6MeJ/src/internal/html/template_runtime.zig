const compile = @import("template_compile.zig");
const template_assets = @import("template_assets.zig");
const expression = @import("template_expression.zig");
const attribute_quote = @import("template_quote.zig");
const support = @import("template_runtime_support.zig");
const types = @import("template_types.zig");
const html_render = @import("../../html/render.zig");
const html_source = @import("../../html/source.zig");

pub fn render(
    comptime Root: type,
    comptime Errors: type,
    comptime operations_max: u32,
    writer: anytype,
    view: Root.ViewType,
    json_scratch: []u8,
) Errors!void {
    var operations_remaining = operations_max;
    return renderNode(
        Root,
        Errors,
        writer,
        view,
        json_scratch,
        NoBody{},
        &operations_remaining,
    );
}

pub fn renderLayout(
    comptime Layout: type,
    comptime Body: type,
    comptime Errors: type,
    comptime operations_max: u32,
    writer: anytype,
    layout_view: Layout.ViewType,
    body_view: Body.ViewType,
    json_scratch: []u8,
) Errors!void {
    const slot = BodySlot(Body){ .view = body_view };
    var operations_remaining = operations_max;
    return renderNode(
        Layout,
        Errors,
        writer,
        layout_view,
        json_scratch,
        slot,
        &operations_remaining,
    );
}

const NoBody = struct {};

fn BodySlot(comptime Body: type) type {
    return struct {
        pub const BodyNode = Body;
        view: Body.ViewType,
    };
}

fn renderNode(
    comptime Current: type,
    comptime Errors: type,
    writer: anytype,
    view: Current.ViewType,
    scratch: []u8,
    body: anytype,
    operations_remaining: *u32,
) Errors!void {
    return renderSegment(
        Current,
        Errors,
        writer,
        view,
        types.EmptyScope{},
        scratch,
        body,
        operations_remaining,
        0,
        Current.SourceType.directives.len,
        0,
        Current.SourceType.source.len,
    );
}

fn renderSegment(
    comptime Current: type,
    comptime Errors: type,
    writer: anytype,
    view: Current.ViewType,
    scope: anytype,
    scratch: []u8,
    body: anytype,
    operations_remaining: *u32,
    comptime start: usize,
    comptime end: usize,
    comptime byte_start: usize,
    comptime byte_end: usize,
) Errors!void {
    const Source = Current.SourceType;
    comptime var index = start;
    comptime var cursor = byte_start;
    inline while (index < end) {
        const directive = comptime Source.directives[index];
        const static_end = comptime trimBefore(Source, cursor, index);
        try support.spendOperation(operations_remaining);
        try support.writeStatic(writer, Source.source[cursor..static_end]);
        if (comptime support.isControl(directive.kind)) {
            try renderControl(
                Current,
                Errors,
                writer,
                view,
                scope,
                scratch,
                body,
                operations_remaining,
                index,
            );
            index = comptime Current.links[index].close_index;
            cursor = comptime trimAfter(Source, index);
        } else {
            try renderLeaf(
                Current,
                Errors,
                writer,
                view,
                scope,
                scratch,
                body,
                operations_remaining,
                index,
            );
            cursor = comptime trimAfter(Source, index);
        }
        index += 1;
    }
    try support.writeStatic(writer, Source.source[cursor..byte_end]);
}

fn renderControl(
    comptime Current: type,
    comptime Errors: type,
    writer: anytype,
    view: Current.ViewType,
    scope: anytype,
    scratch: []u8,
    body: anytype,
    operations_remaining: *u32,
    comptime index: usize,
) Errors!void {
    const Source = Current.SourceType;
    const directive = comptime Source.directives[index];
    const path = comptime directive.expression.bytes(Source.source);
    const value = expression.resolve(view, scope, path, Source, directive.expression.start);
    switch (comptime directive.kind) {
        .if_open => return renderIf(
            Current,
            Errors,
            writer,
            view,
            scope,
            scratch,
            body,
            operations_remaining,
            index,
            value,
        ),
        .with_open => return renderWith(
            Current,
            Errors,
            writer,
            view,
            scope,
            scratch,
            body,
            operations_remaining,
            index,
            value,
        ),
        .each_open => return renderEach(
            Current,
            Errors,
            writer,
            view,
            scope,
            scratch,
            body,
            operations_remaining,
            index,
            value,
        ),
        else => unreachable,
    }
}

fn renderIf(
    comptime Current: type,
    comptime Errors: type,
    writer: anytype,
    view: Current.ViewType,
    scope: anytype,
    scratch: []u8,
    body: anytype,
    operations_remaining: *u32,
    comptime index: usize,
    condition: bool,
) Errors!void {
    if (condition) {
        return renderTrue(
            Current,
            Errors,
            writer,
            view,
            scope,
            scratch,
            body,
            operations_remaining,
            index,
        );
    }
    return renderFalse(
        Current,
        Errors,
        writer,
        view,
        scope,
        scratch,
        body,
        operations_remaining,
        index,
    );
}

fn renderWith(
    comptime Current: type,
    comptime Errors: type,
    writer: anytype,
    view: Current.ViewType,
    scope: anytype,
    scratch: []u8,
    body: anytype,
    operations_remaining: *u32,
    comptime index: usize,
    optional: anytype,
) Errors!void {
    if (optional) |value| {
        const directive = comptime Current.SourceType.directives[index];
        const name = comptime directive.name.bytes(Current.SourceType.source);
        const child_scope = types.Binding(name, @TypeOf(value), @TypeOf(scope)){
            .value = value,
            .parent = scope,
        };
        return renderTrue(
            Current,
            Errors,
            writer,
            view,
            child_scope,
            scratch,
            body,
            operations_remaining,
            index,
        );
    }
    return renderFalse(
        Current,
        Errors,
        writer,
        view,
        scope,
        scratch,
        body,
        operations_remaining,
        index,
    );
}

fn renderEach(
    comptime Current: type,
    comptime Errors: type,
    writer: anytype,
    view: Current.ViewType,
    scope: anytype,
    scratch: []u8,
    body: anytype,
    operations_remaining: *u32,
    comptime index: usize,
    collection: anytype,
) Errors!void {
    if (collection.len == 0) {
        return renderFalse(
            Current,
            Errors,
            writer,
            view,
            scope,
            scratch,
            body,
            operations_remaining,
            index,
        );
    }
    const directive = comptime Current.SourceType.directives[index];
    const name = comptime directive.name.bytes(Current.SourceType.source);
    for (collection, 0..) |item, item_index| {
        try support.spendOperation(operations_remaining);
        const item_scope = types.Binding(name, @TypeOf(item), @TypeOf(scope)){
            .value = item,
            .parent = scope,
        };
        if (comptime directive.auxiliary.start == directive.auxiliary.end) {
            try renderTrue(
                Current,
                Errors,
                writer,
                view,
                item_scope,
                scratch,
                body,
                operations_remaining,
                index,
            );
        } else {
            const index_name = comptime directive.auxiliary.bytes(Current.SourceType.source);
            const child_scope = types.Binding(index_name, usize, @TypeOf(item_scope)){
                .value = item_index,
                .parent = item_scope,
            };
            try renderTrue(
                Current,
                Errors,
                writer,
                view,
                child_scope,
                scratch,
                body,
                operations_remaining,
                index,
            );
        }
    }
}

fn renderTrue(
    comptime Current: type,
    comptime Errors: type,
    writer: anytype,
    view: Current.ViewType,
    scope: anytype,
    scratch: []u8,
    body: anytype,
    operations_remaining: *u32,
    comptime index: usize,
) Errors!void {
    const link = comptime Current.links[index];
    const end = comptime link.else_index orelse link.close_index;
    const start_byte = comptime trimAfter(Current.SourceType, index);
    const end_byte = comptime trimBefore(Current.SourceType, start_byte, end);
    return renderSegment(
        Current,
        Errors,
        writer,
        view,
        scope,
        scratch,
        body,
        operations_remaining,
        index + 1,
        end,
        start_byte,
        end_byte,
    );
}

fn renderFalse(
    comptime Current: type,
    comptime Errors: type,
    writer: anytype,
    view: Current.ViewType,
    scope: anytype,
    scratch: []u8,
    body: anytype,
    operations_remaining: *u32,
    comptime index: usize,
) Errors!void {
    const link = comptime Current.links[index];
    if (comptime link.else_index) |alternative| {
        const start_byte = comptime trimAfter(Current.SourceType, alternative);
        const end_byte = comptime trimBefore(Current.SourceType, start_byte, link.close_index);
        return renderSegment(
            Current,
            Errors,
            writer,
            view,
            scope,
            scratch,
            body,
            operations_remaining,
            alternative + 1,
            link.close_index,
            start_byte,
            end_byte,
        );
    }
}

fn renderLeaf(
    comptime Current: type,
    comptime Errors: type,
    writer: anytype,
    view: Current.ViewType,
    scope: anytype,
    scratch: []u8,
    body: anytype,
    operations_remaining: *u32,
    comptime index: usize,
) Errors!void {
    const Source = Current.SourceType;
    const directive = comptime Source.directives[index];
    switch (comptime directive.kind) {
        .interpolation => {
            const path = comptime directive.expression.bytes(Source.source);
            const value = expression.resolve(view, scope, path, Source, directive.expression.start);
            return writeOutput(Errors, writer, value, directive.context, Source, index);
        },
        .helper => {
            const value = try callHelper(Current, Errors, view, scope, index);
            return writeOutput(Errors, writer, value, directive.context, Source, index);
        },
        .partial => return renderPartial(
            Current,
            Errors,
            writer,
            view,
            scope,
            scratch,
            operations_remaining,
            index,
        ),
        .json_data => return renderJson(Current, Errors, writer, view, scope, scratch, index),
        .inline_css, .inline_javascript => {
            return support.writeStatic(writer, template_assets.bytes(Current, index));
        },
        .body_slot => return renderBody(Errors, writer, scratch, body, operations_remaining),
        .comment, .verbatim_open, .verbatim_close => return,
        else => unreachable,
    }
}

fn renderPartial(
    comptime Current: type,
    comptime Errors: type,
    writer: anytype,
    view: Current.ViewType,
    scope: anytype,
    scratch: []u8,
    operations_remaining: *u32,
    comptime index: usize,
) Errors!void {
    const Source = Current.SourceType;
    const directive = comptime Source.directives[index];
    const name = comptime directive.name.bytes(Source.source);
    const Child = compile.partialNode(Current, name, Source, directive.name.start);
    const path = comptime directive.expression.bytes(Source.source);
    const child_view = expression.resolve(view, scope, path, Source, directive.expression.start);
    return renderNode(
        Child,
        Errors,
        writer,
        child_view,
        scratch,
        NoBody{},
        operations_remaining,
    );
}

fn renderJson(
    comptime Current: type,
    comptime Errors: type,
    writer: anytype,
    view: Current.ViewType,
    scope: anytype,
    scratch: []u8,
    comptime index: usize,
) Errors!void {
    const Source = Current.SourceType;
    const directive = comptime Source.directives[index];
    const path = comptime directive.expression.bytes(Source.source);
    const value = expression.resolve(view, scope, path, Source, directive.expression.start);
    return html_render.writeBrowserJson(
        Current.browser_json_value,
        writer,
        directive.name.bytes(Source.source),
        value,
        scratch,
    );
}

fn renderBody(
    comptime Errors: type,
    writer: anytype,
    scratch: []u8,
    body: anytype,
    operations_remaining: *u32,
) Errors!void {
    const Slot = @TypeOf(body);
    if (Slot == NoBody) unreachable;
    return renderNode(
        Slot.BodyNode,
        Errors,
        writer,
        body.view,
        scratch,
        NoBody{},
        operations_remaining,
    );
}

fn callHelper(
    comptime Current: type,
    comptime Errors: type,
    view: Current.ViewType,
    scope: anytype,
    comptime index: usize,
) Errors!types.payloadType(compile.helperReturn(Current, @TypeOf(scope), index)) {
    const Source = Current.SourceType;
    const directive = comptime Source.directives[index];
    const helper = @field(Current.helpers_value, directive.name.bytes(Source.source));
    const ranges = comptime expression.helperArgumentRanges(
        Source.source,
        directive.expression.start,
        directive.expression.end,
        directive.argument_count,
    );
    const result = if (comptime directive.argument_count <= 4)
        callHelperLow(Current, view, scope, index, helper, ranges)
    else
        callHelperHigh(Current, view, scope, index, helper, ranges);
    return unwrapHelper(result);
}

fn callHelperLow(
    comptime Current: type,
    view: Current.ViewType,
    scope: anytype,
    comptime index: usize,
    helper: anytype,
    comptime ranges: anytype,
) compile.helperReturn(Current, @TypeOf(scope), index) {
    return switch (ranges.len) {
        1 => @call(.auto, helper, .{argument(Current, view, scope, ranges[0])}),
        2 => @call(.auto, helper, .{
            argument(Current, view, scope, ranges[0]),
            argument(Current, view, scope, ranges[1]),
        }),
        3 => @call(.auto, helper, .{
            argument(Current, view, scope, ranges[0]),
            argument(Current, view, scope, ranges[1]),
            argument(Current, view, scope, ranges[2]),
        }),
        4 => @call(.auto, helper, .{
            argument(Current, view, scope, ranges[0]),
            argument(Current, view, scope, ranges[1]),
            argument(Current, view, scope, ranges[2]),
            argument(Current, view, scope, ranges[3]),
        }),
        else => unreachable,
    };
}

fn callHelperHigh(
    comptime Current: type,
    view: Current.ViewType,
    scope: anytype,
    comptime index: usize,
    helper: anytype,
    comptime ranges: anytype,
) compile.helperReturn(Current, @TypeOf(scope), index) {
    return switch (ranges.len) {
        5 => @call(.auto, helper, .{
            argument(Current, view, scope, ranges[0]),
            argument(Current, view, scope, ranges[1]),
            argument(Current, view, scope, ranges[2]),
            argument(Current, view, scope, ranges[3]),
            argument(Current, view, scope, ranges[4]),
        }),
        6 => @call(.auto, helper, .{
            argument(Current, view, scope, ranges[0]),
            argument(Current, view, scope, ranges[1]),
            argument(Current, view, scope, ranges[2]),
            argument(Current, view, scope, ranges[3]),
            argument(Current, view, scope, ranges[4]),
            argument(Current, view, scope, ranges[5]),
        }),
        7 => @call(.auto, helper, .{
            argument(Current, view, scope, ranges[0]),
            argument(Current, view, scope, ranges[1]),
            argument(Current, view, scope, ranges[2]),
            argument(Current, view, scope, ranges[3]),
            argument(Current, view, scope, ranges[4]),
            argument(Current, view, scope, ranges[5]),
            argument(Current, view, scope, ranges[6]),
        }),
        8 => @call(.auto, helper, .{
            argument(Current, view, scope, ranges[0]),
            argument(Current, view, scope, ranges[1]),
            argument(Current, view, scope, ranges[2]),
            argument(Current, view, scope, ranges[3]),
            argument(Current, view, scope, ranges[4]),
            argument(Current, view, scope, ranges[5]),
            argument(Current, view, scope, ranges[6]),
            argument(Current, view, scope, ranges[7]),
        }),
        else => unreachable,
    };
}

fn argument(
    comptime Current: type,
    view: Current.ViewType,
    scope: anytype,
    comptime range: expression.Range,
) expression.resolveType(
    Current.ViewType,
    @TypeOf(scope),
    Current.SourceType.source[range.start..range.end],
    Current.SourceType,
    range.start,
) {
    const path = Current.SourceType.source[range.start..range.end];
    return expression.resolve(view, scope, path, Current.SourceType, range.start);
}

fn unwrapHelper(
    result: anytype,
) types.errorSet(@TypeOf(result))!types.payloadType(@TypeOf(result)) {
    return switch (@typeInfo(@TypeOf(result))) {
        .error_union => try result,
        else => result,
    };
}

fn writeOutput(
    comptime Errors: type,
    writer: anytype,
    value: anytype,
    comptime context: html_source.ParserContext,
    comptime Source: type,
    comptime index: usize,
) Errors!void {
    const kind = comptime compile.outputKind(@TypeOf(value));
    switch (comptime context) {
        .html_data => if (comptime kind == .trusted_html)
            return html_render.writeTrustedHtml(writer, value)
        else
            return html_render.writeValue(writer, .html_data, value),
        .title_text, .textarea_text => return html_render.writeValue(writer, .rcdata, value),
        .attribute_inert => {
            return html_render.writeValue(writer, quoteContext(Source, index), value);
        },
        .attribute_navigation_url => return writeUrl(Errors, writer, value, Source, index, false),
        .attribute_media_url => return writeUrl(Errors, writer, value, Source, index, true),
        .attribute_asset_url,
        .attribute_image_url,
        .attribute_font_url,
        .attribute_text_url,
        => if (comptime kind == .asset_ref)
            return writeAsset(Errors, writer, value, Source, index)
        else
            return writeUrl(Errors, writer, value, Source, index, true),
        .attribute_trusted_resource_url => {
            const bytes = try value.validatedBytes();
            return html_render.writeAttribute(writer, quote(Source, index), bytes);
        },
        .attribute_script_url,
        .attribute_style_url,
        .attribute_document_url,
        .attribute_json_url,
        .attribute_xml_url,
        .attribute_any_resource_url,
        => if (comptime kind == .asset_ref)
            return writeAsset(Errors, writer, value, Source, index)
        else {
            const bytes = try value.validatedBytes();
            return html_render.writeAttribute(writer, quote(Source, index), bytes);
        },
        else => unreachable,
    }
}

fn writeAsset(
    comptime Errors: type,
    writer: anytype,
    value: anytype,
    comptime Source: type,
    comptime index: usize,
) Errors!void {
    const parts = try value.url();
    const attribute_quote_value = comptime quote(Source, index);
    if (parts.base.len != 0) {
        try html_render.writeAttribute(writer, attribute_quote_value, parts.base);
    }
    return html_render.writeAttribute(writer, attribute_quote_value, parts.path);
}

fn writeUrl(
    comptime Errors: type,
    writer: anytype,
    value: anytype,
    comptime Source: type,
    comptime index: usize,
    comptime asset_only: bool,
) Errors!void {
    const checked = try value.validatedCopy();
    if (asset_only and (checked.kind() == .mailto or checked.kind() == .tel)) {
        return error.InvalidUrlKind;
    }
    return html_render.writeAttribute(writer, quote(Source, index), checked.bytes());
}

fn quoteContext(comptime Source: type, comptime index: usize) html_render.EscapeContext {
    return switch (quote(Source, index)) {
        .double => .attribute_double_quoted,
        .single => .attribute_single_quoted,
    };
}

fn quote(comptime Source: type, comptime index: usize) html_render.AttributeQuote {
    return attribute_quote.resolve(Source, index);
}

fn trimBefore(comptime Source: type, comptime lower: usize, comptime index: usize) usize {
    const directive = Source.directives[index];
    if (!directive.trim_before) return directive.source.start;
    var end: usize = directive.source.start;
    while (end > lower and support.htmlSpace(Source.source[end - 1])) end -= 1;
    return end;
}

fn trimAfter(comptime Source: type, comptime index: usize) usize {
    const directive = Source.directives[index];
    var start: usize = directive.source.end;
    if (!directive.trim_after) return start;
    while (start < Source.source.len and support.htmlSpace(Source.source[start])) start += 1;
    return start;
}
