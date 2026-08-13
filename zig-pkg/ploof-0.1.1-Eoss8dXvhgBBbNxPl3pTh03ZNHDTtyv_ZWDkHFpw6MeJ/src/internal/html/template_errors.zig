const expression = @import("template_expression.zig");
const types = @import("template_types.zig");
const json = @import("../../json.zig");

const Selection = enum(u2) { render, helper, application };

pub fn render(comptime Root: type, comptime Resolver: type) type {
    return types.ValueError || range(
        Root,
        types.EmptyScope,
        0,
        Root.SourceType.directives.len,
        .render,
        Resolver,
    );
}

pub fn helper(comptime Root: type, comptime Resolver: type) type {
    return range(
        Root,
        types.EmptyScope,
        0,
        Root.SourceType.directives.len,
        .helper,
        Resolver,
    );
}

pub fn application(comptime Root: type, comptime Resolver: type) type {
    return range(
        Root,
        types.EmptyScope,
        0,
        Root.SourceType.directives.len,
        .application,
        Resolver,
    );
}

fn range(
    comptime Current: type,
    comptime Scope: type,
    comptime start: usize,
    comptime end: usize,
    comptime selection: Selection,
    comptime Resolver: type,
) type {
    if (start >= end) return error{};
    const directive = Current.SourceType.directives[start];
    if (control(directive.kind)) {
        return controlErrors(Current, Scope, start, selection, Resolver) || range(
            Current,
            Scope,
            Current.links[start].close_index + 1,
            end,
            selection,
            Resolver,
        );
    }
    return directiveErrors(Current, Scope, start, selection, Resolver) ||
        range(Current, Scope, start + 1, end, selection, Resolver);
}

fn controlErrors(
    comptime Current: type,
    comptime Scope: type,
    comptime index: usize,
    comptime selection: Selection,
    comptime Resolver: type,
) type {
    const Source = Current.SourceType;
    const directive = Source.directives[index];
    const link = Current.links[index];
    const end = link.else_index orelse link.close_index;
    const Value = expression.resolveType(
        Current.ViewType,
        Scope,
        directive.expression.bytes(Source.source),
        Source,
        directive.expression.start,
    );
    const success = switch (directive.kind) {
        .if_open => range(Current, Scope, index + 1, end, selection, Resolver),
        .with_open => withErrors(Current, Scope, index, end, Value, selection, Resolver),
        .each_open => eachErrors(Current, Scope, index, end, Value, selection, Resolver),
        else => unreachable,
    };
    const alternative = if (link.else_index) |branch|
        range(Current, Scope, branch + 1, link.close_index, selection, Resolver)
    else
        error{};
    return success || alternative;
}

fn withErrors(
    comptime Current: type,
    comptime Scope: type,
    comptime index: usize,
    comptime end: usize,
    comptime Value: type,
    comptime selection: Selection,
    comptime Resolver: type,
) type {
    const directive = Current.SourceType.directives[index];
    const child = @typeInfo(Value).optional.child;
    const name = directive.name.bytes(Current.SourceType.source);
    return range(
        Current,
        types.Binding(name, child, Scope),
        index + 1,
        end,
        selection,
        Resolver,
    );
}

fn eachErrors(
    comptime Current: type,
    comptime Scope: type,
    comptime index: usize,
    comptime end: usize,
    comptime Value: type,
    comptime selection: Selection,
    comptime Resolver: type,
) type {
    const directive = Current.SourceType.directives[index];
    const Child = types.collectionChild(Value).?;
    const name = directive.name.bytes(Current.SourceType.source);
    const ItemScope = types.Binding(name, Child, Scope);
    const BoundScope = if (directive.auxiliary.start == directive.auxiliary.end)
        ItemScope
    else
        types.Binding(
            directive.auxiliary.bytes(Current.SourceType.source),
            usize,
            ItemScope,
        );
    return range(Current, BoundScope, index + 1, end, selection, Resolver);
}

fn directiveErrors(
    comptime Current: type,
    comptime Scope: type,
    comptime index: usize,
    comptime selection: Selection,
    comptime Resolver: type,
) type {
    const Source = Current.SourceType;
    const directive = Source.directives[index];
    return switch (directive.kind) {
        .interpolation => if (selection == .helper) error{} else outputError(
            expression.resolveType(
                Current.ViewType,
                Scope,
                directive.expression.bytes(Source.source),
                Source,
                directive.expression.start,
            ),
        ),
        .helper => helperErrors(Current, Scope, index, selection, Resolver),
        .partial => range(
            Resolver.resolvePartial(Current, index),
            types.EmptyScope,
            0,
            Resolver.resolvePartial(Current, index).SourceType.directives.len,
            selection,
            Resolver,
        ),
        .json_data => switch (selection) {
            .render => jsonErrors(Current, Scope, index),
            .application => jsonApplicationErrors(Current, Scope, index),
            .helper => error{},
        },
        else => error{},
    };
}

fn helperErrors(
    comptime Current: type,
    comptime Scope: type,
    comptime index: usize,
    comptime selection: Selection,
    comptime Resolver: type,
) type {
    const Return = Resolver.resolveHelperReturn(Current, Scope, index);
    const format_errors = if (selection == .helper)
        error{}
    else
        outputError(types.payloadType(Return));
    return types.errorSet(Return) || format_errors;
}

fn jsonErrors(comptime Current: type, comptime Scope: type, comptime index: usize) type {
    return json.EncodeError(jsonType(Current, Scope, index));
}

fn jsonApplicationErrors(
    comptime Current: type,
    comptime Scope: type,
    comptime index: usize,
) type {
    return json.CustomEncodeError(jsonType(Current, Scope, index));
}

fn jsonType(comptime Current: type, comptime Scope: type, comptime index: usize) type {
    const Source = Current.SourceType;
    const directive = Source.directives[index];
    return expression.resolveType(
        Current.ViewType,
        Scope,
        directive.expression.bytes(Source.source),
        Source,
        directive.expression.start,
    );
}

fn outputError(comptime T: type) type {
    if (!types.hasFormatText(T)) return error{};
    const Return = @typeInfo(@TypeOf(@field(T, "formatText"))).@"fn".return_type.?;
    return types.errorSet(Return);
}

fn control(kind: anytype) bool {
    return kind == .if_open or kind == .with_open or kind == .each_open;
}
