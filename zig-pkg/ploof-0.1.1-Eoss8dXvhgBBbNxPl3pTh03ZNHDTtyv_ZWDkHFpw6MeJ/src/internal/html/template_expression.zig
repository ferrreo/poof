const std = @import("std");
const diagnostic = @import("template_diagnostic.zig");
const types = @import("template_types.zig");

pub fn resolveType(
    comptime View: type,
    comptime Scope: type,
    comptime path: []const u8,
    comptime Source: type,
    comptime offset: usize,
) type {
    const split = comptime component(path);
    const Root = if (std.mem.eql(u8, split.head, "view"))
        View
    else
        scopeType(Scope, split.head, Source, offset);
    return resolveTailType(Root, split.tail, Source, offset + split.next_offset);
}

pub fn resolve(
    view: anytype,
    scope: anytype,
    comptime path: []const u8,
    comptime Source: type,
    comptime offset: usize,
) resolveType(@TypeOf(view), @TypeOf(scope), path, Source, offset) {
    const split = comptime component(path);
    if (comptime std.mem.eql(u8, split.head, "view")) {
        return resolveTail(view, split.tail, Source, offset + split.next_offset);
    }
    const root = scopeValue(scope, split.head, Source, offset);
    return resolveTail(root, split.tail, Source, offset + split.next_offset);
}

pub fn helperArgumentRanges(
    comptime source: []const u8,
    comptime start: usize,
    comptime end: usize,
    comptime count: usize,
) [count]Range {
    var ranges: [count]Range = undefined;
    var found: usize = 0;
    var cursor = start;
    while (cursor < end) {
        while (cursor < end and htmlSpace(source[cursor])) cursor += 1;
        if (cursor == end) break;
        const token_start = cursor;
        while (cursor < end and !htmlSpace(source[cursor])) cursor += 1;
        if (found >= count) unreachable;
        ranges[found] = .{ .start = token_start, .end = cursor };
        found += 1;
    }
    if (found != count) unreachable;
    return ranges;
}

pub const Range = struct {
    start: usize,
    end: usize,
};

const Component = struct {
    head: []const u8,
    tail: []const u8,
    next_offset: usize,
};

fn component(comptime path: []const u8) Component {
    const separator = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
    return .{
        .head = path[0..separator],
        .tail = if (separator == path.len) "" else path[separator + 1 ..],
        .next_offset = if (separator == path.len) separator else separator + 1,
    };
}

fn scopeType(
    comptime Scope: type,
    comptime name: []const u8,
    comptime Source: type,
    comptime offset: usize,
) type {
    if (Scope == types.EmptyScope) {
        diagnostic.fail(.unknown_field, Source, offset, "unknown expression root '" ++ name ++ "'");
    }
    if (std.mem.eql(u8, Scope.name, name)) return Scope.ValueType;
    return scopeType(Scope.ParentType, name, Source, offset);
}

fn scopeValue(
    scope: anytype,
    comptime name: []const u8,
    comptime Source: type,
    comptime offset: usize,
) scopeType(@TypeOf(scope), name, Source, offset) {
    const Scope = @TypeOf(scope);
    if (comptime std.mem.eql(u8, Scope.name, name)) return scope.value;
    return scopeValue(scope.parent, name, Source, offset);
}

fn resolveTailType(
    comptime Requested: type,
    comptime tail: []const u8,
    comptime Source: type,
    comptime offset: usize,
) type {
    if (tail.len == 0) return Requested;
    const T = dereferenceType(Requested, Source, offset);
    if (@typeInfo(T) != .@"struct") {
        diagnostic.fail(
            .non_struct_path,
            Source,
            offset,
            "cannot select a field from type '" ++ @typeName(T) ++ "'",
        );
    }
    const split = comptime component(tail);
    if (!@hasField(T, split.head)) {
        diagnostic.fail(
            .unknown_field,
            Source,
            offset,
            "type '" ++ @typeName(T) ++ "' has no field '" ++ split.head ++ "'",
        );
    }
    const Field = @FieldType(T, split.head);
    return resolveTailType(Field, split.tail, Source, offset + split.next_offset);
}

fn resolveTail(
    requested: anytype,
    comptime tail: []const u8,
    comptime Source: type,
    comptime offset: usize,
) resolveTailType(@TypeOf(requested), tail, Source, offset) {
    if (comptime tail.len == 0) return requested;
    const value = dereference(requested, Source, offset);
    const split = comptime component(tail);
    return resolveTail(@field(value, split.head), split.tail, Source, offset + split.next_offset);
}

fn dereferenceType(
    comptime Requested: type,
    comptime Source: type,
    comptime offset: usize,
) type {
    return switch (@typeInfo(Requested)) {
        .pointer => |pointer| if (pointer.size == .one and !pointer.is_allowzero)
            pointer.child
        else
            diagnostic.fail(
                .non_struct_path,
                Source,
                offset,
                "cannot select a field through type '" ++ @typeName(Requested) ++ "'",
            ),
        else => Requested,
    };
}

fn dereference(
    requested: anytype,
    comptime Source: type,
    comptime offset: usize,
) dereferenceType(@TypeOf(requested), Source, offset) {
    return switch (@typeInfo(@TypeOf(requested))) {
        .pointer => requested.*,
        else => requested,
    };
}

fn htmlSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == '\x0c';
}
