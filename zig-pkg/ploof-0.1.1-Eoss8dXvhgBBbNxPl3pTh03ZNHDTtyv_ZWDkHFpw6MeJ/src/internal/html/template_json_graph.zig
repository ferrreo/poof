const diagnostic = @import("template_diagnostic.zig");

pub fn validate(comptime Current: type, comptime Resolver: type) void {
    const Source = Current.SourceType;
    inline for (Source.directives, 0..) |directive, left| {
        if (directive.kind == .partial and directive.repeating_depth != 0) {
            const Child = childNode(Current, Resolver, left);
            if (nodeContainsJson(Child, Resolver)) {
                diagnostic.fail(
                    .repeated_browser_json,
                    Source,
                    directive.name.start,
                    "partial containing browser JSON cannot render inside each",
                );
            }
        }
        if (!hasExpansion(directive.kind)) continue;
        inline for (Source.directives[left + 1 ..], left + 1..) |right_directive, right| {
            if (!hasExpansion(right_directive.kind)) continue;
            if (!directivesOverlap(Current, left, right)) continue;
            assertDirectivePair(Current, Resolver, left, right);
        }
    }
}

fn directivesOverlap(comptime Current: type, comptime left: usize, comptime right: usize) bool {
    const Source = Current.SourceType;
    inline for (Source.directives, 0..) |directive, open| {
        if (!control(directive.kind)) continue;
        const link = Current.links[open];
        const alternative = link.else_index orelse continue;
        const left_branch = branch(open, alternative, link.close_index, left);
        const right_branch = branch(open, alternative, link.close_index, right);
        if (left_branch != .outside and right_branch != .outside and
            left_branch != right_branch)
        {
            return false;
        }
    }
    return true;
}

const Branch = enum(u2) { outside, success, alternative };

fn branch(open: usize, alternative: usize, close: usize, index: usize) Branch {
    if (index <= open or index >= close) return .outside;
    return if (index < alternative) .success else .alternative;
}

pub fn validateDisjoint(
    comptime Left: type,
    comptime Right: type,
    comptime Resolver: type,
) void {
    assertNodeAgainstNode(Left, Right, Resolver);
}

fn assertDirectivePair(
    comptime Current: type,
    comptime Resolver: type,
    comptime left: usize,
    comptime right: usize,
) void {
    const Source = Current.SourceType;
    const directive = Source.directives[left];
    if (directive.kind == .json_data) {
        const name = directive.name.bytes(Source.source);
        if (directiveContainsName(Current, Resolver, right, name)) {
            duplicate(Current, right, name);
        }
        return;
    }
    assertNodeAgainstDirective(childNode(Current, Resolver, left), Current, Resolver, right);
}

fn assertNodeAgainstDirective(
    comptime Left: type,
    comptime Right: type,
    comptime Resolver: type,
    comptime right: usize,
) void {
    const Source = Left.SourceType;
    inline for (Source.directives, 0..) |directive, index| {
        if (directive.kind == .json_data) {
            const name = directive.name.bytes(Source.source);
            if (directiveContainsName(Right, Resolver, right, name)) {
                duplicate(Right, right, name);
            }
        } else if (directive.kind == .partial) {
            assertNodeAgainstDirective(childNode(Left, Resolver, index), Right, Resolver, right);
        }
    }
}

fn assertNodeAgainstNode(
    comptime Left: type,
    comptime Right: type,
    comptime Resolver: type,
) void {
    const Source = Left.SourceType;
    inline for (Source.directives, 0..) |directive, index| {
        if (directive.kind == .json_data) {
            const name = directive.name.bytes(Source.source);
            if (nodeContainsName(Right, Resolver, name)) duplicateNode(Right, Resolver, name);
        } else if (directive.kind == .partial) {
            assertNodeAgainstNode(childNode(Left, Resolver, index), Right, Resolver);
        }
    }
}

fn directiveContainsName(
    comptime Current: type,
    comptime Resolver: type,
    comptime index: usize,
    comptime name: []const u8,
) bool {
    const Source = Current.SourceType;
    const directive = Source.directives[index];
    if (directive.kind == .json_data) {
        return equal(name, directive.name.bytes(Source.source));
    }
    return nodeContainsName(childNode(Current, Resolver, index), Resolver, name);
}

fn nodeContainsName(
    comptime Current: type,
    comptime Resolver: type,
    comptime name: []const u8,
) bool {
    const Source = Current.SourceType;
    inline for (Source.directives, 0..) |directive, index| {
        if (directive.kind == .json_data and equal(name, directive.name.bytes(Source.source))) {
            return true;
        }
        if (directive.kind == .partial and
            nodeContainsName(childNode(Current, Resolver, index), Resolver, name))
        {
            return true;
        }
    }
    return false;
}

fn nodeContainsJson(comptime Current: type, comptime Resolver: type) bool {
    const Source = Current.SourceType;
    inline for (Source.directives, 0..) |directive, index| {
        if (directive.kind == .json_data) return true;
        if (directive.kind == .partial and
            nodeContainsJson(childNode(Current, Resolver, index), Resolver))
        {
            return true;
        }
    }
    return false;
}

fn childNode(comptime Parent: type, comptime Resolver: type, comptime index: usize) type {
    const Source = Parent.SourceType;
    const directive = Source.directives[index];
    return Resolver.child(
        Parent,
        directive.name.bytes(Source.source),
        Source,
        directive.name.start,
    );
}

fn duplicate(comptime Current: type, comptime index: usize, comptime name: []const u8) noreturn {
    const directive = Current.SourceType.directives[index];
    diagnostic.fail(
        .duplicate_browser_json,
        Current.SourceType,
        directive.name.start,
        "expanded template graph duplicates browser JSON id '" ++ name ++ "'",
    );
}

fn duplicateNode(
    comptime Current: type,
    comptime Resolver: type,
    comptime name: []const u8,
) noreturn {
    const Source = Current.SourceType;
    inline for (Source.directives, 0..) |directive, index| {
        if (directive.kind == .json_data and equal(name, directive.name.bytes(Source.source))) {
            duplicate(Current, index, name);
        }
        if (directive.kind == .partial and
            nodeContainsName(childNode(Current, Resolver, index), Resolver, name))
        {
            duplicateNode(childNode(Current, Resolver, index), Resolver, name);
        }
    }
    unreachable;
}

fn hasExpansion(kind: anytype) bool {
    return kind == .json_data or kind == .partial;
}

fn control(kind: anytype) bool {
    return kind == .if_open or kind == .with_open or kind == .each_open;
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}
